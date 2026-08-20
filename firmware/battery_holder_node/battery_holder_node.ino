// BatteryHolder reference firmware for ESP32 (WROOM / C3 / S3).
//
// Three run modes, selected by what the phone provisions over BLE:
//
//   PAIRING  factory / button-forced. BLE advertises continuously for
//            PAIRING_WINDOW_MS so the app can find and claim the board.
//   BLE      low-power local mode. Each wake: sample -> advertise -> serve the
//            app if it connects -> deep sleep for cfg.bleWakeSec.
//   WIFI     cloud mode, Tuya style. Credentials + a device token arrive over
//            BLE once; after that the board joins Wi-Fi on every wake, POSTs
//            telemetry to the backend, obeys the commands it gets back, then
//            deep sleeps for cfg.wifiReportSec.
//
// A board that has never been provisioned is reached over the USB cable
// instead: the phone flashes this sketch over UART, drops the calibration into
// a dedicated flash region outside the program image, and can then drive the
// same commands over a JSON-per-line serial console that Bluetooth exposes.
//
// Libraries: ArduinoJson (v6). BLE / WebServer / mDNS / Update / HTTPClient
// ship with the ESP32 core.

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Update.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_sleep.h>
#include <soc/soc_caps.h>
#include <esp_system.h>
#include <esp_partition.h>
#include <esp_flash.h>
#include <driver/rtc_io.h>

// A build with CDC-on-boot puts Serial on the chip's native USB port and moves
// UART0 to Serial0. The phone may be plugged into either, so the console reads
// and answers on both. Parts without native USB (classic ESP32) only have the
// one, and BH_ALT_SERIAL simply does not exist there.
#if defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
#define BH_USB_CONSOLE 1
#define BH_ALT_SERIAL Serial0
#else
#define BH_USB_CONSOLE 0
#endif

// ---- Identity ----
static const char* FW_VERSION = "2.1.0";
static const char* HOSTNAME   = "batteryholder";

// ---- Hardware ----
// Pairing button: hold LOW at boot, or press while asleep, to force PAIRING
// mode. Must be an RTC-capable GPIO (ESP32: 0,2,4,12-15,25-27,32-39;
// C3/S3: 0-5). Set to -1 to disable the button entirely.
//
// The default is deliberately off on C3/S3: those pads keep no internal
// pull-up across deep sleep, so an unwired GPIO floats and wakes the board on
// every cycle. Wire a button plus a 10k pull-up to an RTC GPIO, then build with
// -DWAKE_BUTTON_PIN=<n> to enable it. Timer wake works either way; a
// factory-fresh board still comes up in pairing mode without a button.
#ifndef WAKE_BUTTON_PIN
#if SOC_PM_SUPPORT_EXT0_WAKEUP
#define WAKE_BUTTON_PIN 0
#else
#define WAKE_BUTTON_PIN -1
#endif
#endif

// The two pins below are *defaults*. Both are settable at runtime and travel in
// the calibration region, because a compiled-in guess about somebody else's dev
// board is exactly the kind of thing that is wrong in the field: an LED on a
// different GPIO, one that sinks instead of sources, a pairing button wired
// somewhere else or not at all. The app can correct all of that without a
// rebuild (DEVICE_PROTOCOL.md §6).

// Status LED for IDENTIFY. Take whatever the board definition says it has:
// RGB_BUILTIN is the addressable LED on the C3/S3 DevKitM family, which core
// 3.x drives through digitalWrite like any other LED; LED_BUILTIN is the plain
// one on classic dev boards. Only fall back to "no LED" when the variant
// declares neither. Override with -DSTATUS_LED_PIN=<n> for a discrete LED, and
// add -DSTATUS_LED_ACTIVE_LOW=1 if it sinks through the pin.
#ifndef STATUS_LED_PIN
#if defined(RGB_BUILTIN)
#define STATUS_LED_PIN RGB_BUILTIN
#elif defined(LED_BUILTIN)
#define STATUS_LED_PIN LED_BUILTIN
#elif defined(CONFIG_IDF_TARGET_ESP32)
// The "ESP32 Dev Module" variant declares no LED macro at all, but the DevKitC
// family all put one on GPIO2. Assume it, and pass -DSTATUS_LED_PIN=-1 for a
// bare module that has none.
#define STATUS_LED_PIN 2
#else
#define STATUS_LED_PIN -1
#endif
#endif
#ifndef STATUS_LED_ACTIVE_LOW
#define STATUS_LED_ACTIVE_LOW 0
#endif

// How long a board stays reachable after a person physically wakes it — a
// button press, a reset, or plugging it in. Long enough to open the app,
// find the board and connect.
static const uint32_t USER_WAKE_WINDOW_MS = 120000;

// Default battery sense pin, per chip. Overridden by whatever the app pushes;
// this only decides what a factory-fresh board samples on its first wake, so
// it has to be a pin that actually exists on the part. Matches the
// recommendedBatteryPinId values in the apps' boards.json.
#ifndef DEFAULT_ADC_PIN
#if CONFIG_IDF_TARGET_ESP32
#define DEFAULT_ADC_PIN 34          // ADC1_CH6, input-only
#else
#define DEFAULT_ADC_PIN 4           // C3: ADC1_CH4 · S3: ADC1_CH3
#endif
#endif

// ---- GATT UUIDs (must match the apps) ----
#define SVC_UUID   "A1B2C3D4-0001-4A5B-8C6D-000000000000"
#define CH_VOLT    "A1B2C3D4-0002-4A5B-8C6D-000000000000"
#define CH_RAW     "A1B2C3D4-0003-4A5B-8C6D-000000000000"
#define CH_CFG     "A1B2C3D4-0004-4A5B-8C6D-000000000000"
#define CH_OTACTL  "A1B2C3D4-0005-4A5B-8C6D-000000000000"
#define CH_OTADAT  "A1B2C3D4-0006-4A5B-8C6D-000000000000"
#define CH_PROV    "A1B2C3D4-0007-4A5B-8C6D-000000000000"  // Wi-Fi provisioning
#define CH_STATUS  "A1B2C3D4-0008-4A5B-8C6D-000000000000"  // status + events
#define CH_SESSION "A1B2C3D4-0009-4A5B-8C6D-000000000000"  // sleep/session ctl

// Manufacturer-data company id in the advertisement (0xFFFF is reserved for
// testing; swap for your own Bluetooth SIG id before shipping).
#define ADV_COMPANY_ID 0xFFFF

// ---- Modes ----
enum Mode : uint8_t { MODE_PAIRING = 0, MODE_BLE = 1, MODE_WIFI = 2 };

// Where the region lives. Normally the `calib` partition; a board built on a
// stock partition table can still point at a raw sector with
// -DCALIB_FLASH_OFFSET=0x3D0000.
struct CalibRegion {
  uint32_t offset = 0;
  uint32_t size   = 0;
  bool     found  = false;
};

// ---- Persisted configuration ----
struct Config {
  // Board wiring. Seeded from the build-time defaults above, then overridden by
  // whatever the app has told this particular board about itself.
  int  ledPin       = STATUS_LED_PIN;
  bool ledActiveLow = STATUS_LED_ACTIVE_LOW;
  int  buttonPin    = WAKE_BUTTON_PIN;

  // Sensing.
  int   adcPin        = DEFAULT_ADC_PIN;
  int   adcResBits    = 12;
  float adcRefVoltage = 3.3f;
  float r1KOhm        = 100.0f;
  float r2KOhm        = 100.0f;
  float calibration   = 1.0f;
  int   sampleMs      = 1000;

  // Battery pack, so the board can report a percentage on its own.
  int   cellCount     = 1;
  float cellMinV      = 3.3f;   // LiPo empty
  float cellMaxV      = 4.2f;   // LiPo full

  // Power / mode.
  uint8_t  mode          = MODE_PAIRING;
  bool     sleepEnabled  = true;
  uint32_t bleWakeSec    = 300;    // deep sleep between BLE wakeups
  uint32_t bleWindowMs   = 20000;  // advertise window per wake
  uint32_t bleIdleMs     = 60000;  // drop a silent BLE session after this
  uint32_t wifiReportSec = 900;    // deep sleep between cloud reports
  uint32_t wifiWindowMs  = 15000;  // stay awake after a report (local OTA)
  bool     bleInWifi     = false;  // keep BLE up in Wi-Fi mode (costs power)

  // What to call this board. Empty means "use the MAC-derived one", which is
  // what a board that nobody has named answers to.
  char name[25]       = {0};

  // Cloud.
  char ssid[33]       = {0};
  char pass[65]       = {0};
  char backendUrl[97] = {0};
  char token[97]      = {0};
} cfg;

static const uint32_t PAIRING_WINDOW_MS = 180000;   // 3 min claim window
// An unclaimed board wakes far more often than a claimed one: the user is
// standing in front of it with the app open, and 20 s of advertising every
// 5 min would be almost impossible to catch.
static const uint32_t UNCLAIMED_SLEEP_SEC = 60;

Preferences prefs;
WebServer server(80);

BLECharacteristic *chVolt = nullptr, *chRaw = nullptr, *chCtl = nullptr,
                  *chStatus = nullptr;
BLEAdvertising* advertising = nullptr;
bool bleActive = false, bleConnected = false;

// Runtime state.
uint8_t  runMode = MODE_PAIRING;
uint32_t stayAwakeUntil = 0;      // millis deadline for the current wake
uint32_t lastBleActivity = 0;
bool     otaActive = false;
uint32_t otaExpected = 0, otaReceived = 0;
bool     wifiOnline = false;
bool     httpStarted = false;
volatile bool sleepBlocked = false;    // app asked us to stay up indefinitely
volatile bool sleepRequested = false;  // app asked us to sleep right now
volatile bool notifySubscribed = false; // an app is watching the live stream
int      lastRaw = 0;
float    lastVolts = 0.0f;

// IDENTIFY blink, driven from loop() rather than from the BLE callback: the
// old version slept 720 ms inside the GATT write handler, which stalled the
// stack long enough for the app's write to time out.
// Slow enough to count from across a room: IDENTIFY answers "which of these
// boards is the one I am looking at", and anything quicker reads as a flicker
// rather than as this board deliberately signalling.
static const uint32_t BLINK_MS = 700;
volatile uint8_t blinkEdgesLeft = 0;   // on/off transitions still to make
uint32_t blinkNextAt = 0;
bool     blinkOn = false;

// Survives deep sleep.
RTC_DATA_ATTR uint32_t bootCount = 0;
RTC_DATA_ATTR uint8_t  wifiFailStreak = 0;

// ---------------------------------------------------------------- helpers ---

String deviceId() {
  uint64_t mac = ESP.getEfuseMac();
  char buf[20];
  snprintf(buf, sizeof(buf), "bh-%04x%08x",
           (uint16_t)(mac >> 32), (uint32_t)mac);
  return String(buf);
}

// The automatic name: BH- plus the last four hex digits of the MAC. Unique
// enough to tell two boards on a bench apart, and it needs no configuration.
String autoName() {
  String id = deviceId();
  return "BH-" + id.substring(id.length() - 4);
}

// What this board calls itself: whatever it was named, otherwise [autoName].
// This is the name it advertises, so it is what shows up in the app's list.
String deviceName() {
  return cfg.name[0] ? String(cfg.name) : autoName();
}

float dividerRatio() { return (cfg.r1KOhm + cfg.r2KOhm) / cfg.r2KOhm; }
int   adcMaxCount()  { return (1 << cfg.adcResBits) - 1; }
int   readRaw()      { return analogRead(cfg.adcPin); }

float rawToVolts(int raw) {
  float pinV = (float)raw / adcMaxCount() * cfg.adcRefVoltage;
  return pinV * dividerRatio() * cfg.calibration;
}

// 0...1 state of charge for the configured pack.
float stateOfCharge(float volts) {
  int cells = cfg.cellCount < 1 ? 1 : cfg.cellCount;
  float span = cfg.cellMaxV - cfg.cellMinV;
  if (span <= 0) return 0;
  float pct = ((volts / cells) - cfg.cellMinV) / span;
  return pct < 0 ? 0 : (pct > 1 ? 1 : pct);
}

void sampleBattery() {
  lastRaw = readRaw();
  lastVolts = rawToVolts(lastRaw);
}

bool provisioned()  { return cfg.mode != MODE_PAIRING; }
bool hasWifiCreds() { return cfg.ssid[0] != 0; }
bool hasCloud()     { return cfg.backendUrl[0] != 0 && cfg.token[0] != 0; }

bool hasStatusLed() { return cfg.ledPin >= 0; }

void ledWrite(bool on) {
  if (!hasStatusLed()) return;
  bool level = cfg.ledActiveLow ? !on : on;
  digitalWrite(cfg.ledPin, level ? HIGH : LOW);
}

// A pin the chip can actually wake from deep sleep on. Anything else would be
// accepted silently and then simply never wake the board, which is worse than
// refusing it.
bool isWakeCapable(int pin) {
  if (pin < 0 || pin > 48) return false;
  return rtc_gpio_is_valid_gpio((gpio_num_t)pin);
}

void extendWake(uint32_t ms) {
  uint32_t deadline = millis() + ms;
  if ((int32_t)(deadline - stayAwakeUntil) > 0) stayAwakeUntil = deadline;
}

// ----------------------------------------------------------------- config ---

void loadConfig() {
  prefs.begin("bh", true);
  cfg.adcPin        = prefs.getInt("pin", cfg.adcPin);
  cfg.adcResBits    = prefs.getInt("res", cfg.adcResBits);
  cfg.adcRefVoltage = prefs.getFloat("ref", cfg.adcRefVoltage);
  cfg.r1KOhm        = prefs.getFloat("r1", cfg.r1KOhm);
  cfg.r2KOhm        = prefs.getFloat("r2", cfg.r2KOhm);
  cfg.calibration   = prefs.getFloat("cal", cfg.calibration);
  cfg.sampleMs      = prefs.getInt("ms", cfg.sampleMs);
  cfg.cellCount     = prefs.getInt("cells", cfg.cellCount);
  cfg.cellMinV      = prefs.getFloat("vmin", cfg.cellMinV);
  cfg.cellMaxV      = prefs.getFloat("vmax", cfg.cellMaxV);

  prefs.getString("name", cfg.name, sizeof(cfg.name));

  cfg.ledPin        = prefs.getInt("ledpin", cfg.ledPin);
  cfg.ledActiveLow  = prefs.getBool("ledlow", cfg.ledActiveLow);
  cfg.buttonPin     = prefs.getInt("btnpin", cfg.buttonPin);

  cfg.mode          = prefs.getUChar("mode", cfg.mode);
  cfg.sleepEnabled  = prefs.getBool("sleep", cfg.sleepEnabled);
  cfg.bleWakeSec    = prefs.getULong("blewake", cfg.bleWakeSec);
  cfg.bleWindowMs   = prefs.getULong("blewin", cfg.bleWindowMs);
  cfg.bleIdleMs     = prefs.getULong("bleidle", cfg.bleIdleMs);
  cfg.wifiReportSec = prefs.getULong("wifirep", cfg.wifiReportSec);
  cfg.wifiWindowMs  = prefs.getULong("wifiwin", cfg.wifiWindowMs);
  cfg.bleInWifi     = prefs.getBool("blewifi", cfg.bleInWifi);

  prefs.getString("ssid", cfg.ssid, sizeof(cfg.ssid));
  prefs.getString("pass", cfg.pass, sizeof(cfg.pass));
  prefs.getString("url", cfg.backendUrl, sizeof(cfg.backendUrl));
  prefs.getString("token", cfg.token, sizeof(cfg.token));
  prefs.end();

  analogReadResolution(cfg.adcResBits);
}

void saveSensing() {
  prefs.begin("bh", false);
  prefs.putInt("pin", cfg.adcPin);
  prefs.putInt("res", cfg.adcResBits);
  prefs.putFloat("ref", cfg.adcRefVoltage);
  prefs.putFloat("r1", cfg.r1KOhm);
  prefs.putFloat("r2", cfg.r2KOhm);
  prefs.putFloat("cal", cfg.calibration);
  prefs.putInt("ms", cfg.sampleMs);
  prefs.putInt("cells", cfg.cellCount);
  prefs.putFloat("vmin", cfg.cellMinV);
  prefs.putFloat("vmax", cfg.cellMaxV);
  prefs.putString("name", cfg.name);
  prefs.putInt("ledpin", cfg.ledPin);
  prefs.putBool("ledlow", cfg.ledActiveLow);
  prefs.putInt("btnpin", cfg.buttonPin);
  prefs.end();
  analogReadResolution(cfg.adcResBits);
}

void savePower() {
  prefs.begin("bh", false);
  prefs.putUChar("mode", cfg.mode);
  prefs.putBool("sleep", cfg.sleepEnabled);
  prefs.putULong("blewake", cfg.bleWakeSec);
  prefs.putULong("blewin", cfg.bleWindowMs);
  prefs.putULong("bleidle", cfg.bleIdleMs);
  prefs.putULong("wifirep", cfg.wifiReportSec);
  prefs.putULong("wifiwin", cfg.wifiWindowMs);
  prefs.putBool("blewifi", cfg.bleInWifi);
  prefs.end();
}

void saveCloud() {
  prefs.begin("bh", false);
  prefs.putString("ssid", cfg.ssid);
  prefs.putString("pass", cfg.pass);
  prefs.putString("url", cfg.backendUrl);
  prefs.putString("token", cfg.token);
  prefs.end();
}

void factoryReset() {
  prefs.begin("bh", false);
  prefs.clear();
  prefs.end();
}

// Map a chemistry name from PinConfiguration onto per-cell limits.
void applyChemistry(const String& name) {
  if      (name == "liion") { cfg.cellMinV = 3.00f; cfg.cellMaxV = 4.20f; }
  else if (name == "nimh")  { cfg.cellMinV = 1.00f; cfg.cellMaxV = 1.45f; }
  else if (name == "lead")  { cfg.cellMinV = 1.75f; cfg.cellMaxV = 2.10f; }
  else if (name == "lipo")  { cfg.cellMinV = 3.30f; cfg.cellMaxV = 4.20f; }
  // "custom" keeps whatever is stored.
}

// Apply a JSON PinConfiguration payload (from BLE, HTTP or the cloud).
bool applyConfigJson(const String& body) {
  StaticJsonDocument<640> doc;
  if (deserializeJson(doc, body)) return false;
  if (doc.containsKey("adcResolutionBits")) cfg.adcResBits    = doc["adcResolutionBits"];
  if (doc.containsKey("adcRefVoltage"))     cfg.adcRefVoltage = doc["adcRefVoltage"];
  if (doc.containsKey("dividerR1KOhm"))     cfg.r1KOhm        = doc["dividerR1KOhm"];
  if (doc.containsKey("dividerR2KOhm"))     cfg.r2KOhm        = doc["dividerR2KOhm"];
  if (doc.containsKey("calibrationFactor")) cfg.calibration   = doc["calibrationFactor"];
  if (doc.containsKey("sampleIntervalMs"))  cfg.sampleMs      = doc["sampleIntervalMs"];
  if (doc.containsKey("cellCount"))         cfg.cellCount     = doc["cellCount"];
  if (doc.containsKey("chemistry"))         applyChemistry(doc["chemistry"].as<String>());
  if (doc.containsKey("batteryPinId")) {
    String pid = doc["batteryPinId"].as<String>();
    if (pid.startsWith("gpio")) cfg.adcPin = pid.substring(4).toInt();
  }

  // An empty name is a real value: it hands the board back to its automatic
  // MAC-derived one rather than being ignored.
  if (doc.containsKey("deviceName")) {
    strlcpy(cfg.name, doc["deviceName"] | "", sizeof(cfg.name));
  }

  // Board wiring. -1 means "this board has none", which is a real answer for
  // both of these and has to survive the round trip.
  if (doc.containsKey("statusLedPin")) {
    int pin = doc["statusLedPin"];
    if (pin >= -1 && pin <= 48) cfg.ledPin = pin;
  }
  if (doc.containsKey("statusLedActiveLow")) cfg.ledActiveLow = doc["statusLedActiveLow"];
  if (doc.containsKey("wakeButtonPin")) {
    int pin = doc["wakeButtonPin"];
    // Refuse a button the chip could never wake on rather than pretending.
    if (pin == -1 || isWakeCapable(pin)) cfg.buttonPin = pin;
  }

  saveSensing();
  return true;
}

String configJson() {
  StaticJsonDocument<512> doc;
  doc["batteryPinId"]      = String("gpio") + cfg.adcPin;
  doc["adcResolutionBits"] = cfg.adcResBits;
  doc["adcRefVoltage"]     = cfg.adcRefVoltage;
  doc["dividerR1KOhm"]     = cfg.r1KOhm;
  doc["dividerR2KOhm"]     = cfg.r2KOhm;
  doc["calibrationFactor"] = cfg.calibration;
  doc["sampleIntervalMs"]  = cfg.sampleMs;
  doc["cellCount"]         = cfg.cellCount;
  doc["deviceName"]         = String(cfg.name);
  doc["statusLedPin"]       = cfg.ledPin;
  doc["statusLedActiveLow"] = cfg.ledActiveLow;
  doc["wakeButtonPin"]      = cfg.buttonPin;
  String out; serializeJson(doc, out); return out;
}

// ------------------------------------------------------ calibration region ---
//
// A factory-fresh board has never met the phone: no Bluetooth pairing, no
// Wi-Fi, nothing in NVS. So the phone writes the calibration straight into
// flash while it is flashing the firmware over USB — into a 4 KB region that
// lives *outside* the program image (`calib` in partitions.csv). Reflashing
// the app never disturbs it, and it is readable on the very first boot.
//
//   offset  size  field
//        0     4  magic "BHCB"
//        4     2  format version (1)
//        6     2  flags (reserved, 0)
//        8     4  payload length
//       12     4  CRC-32 (IEEE) of the payload
//       16     N  UTF-8 JSON: a PinConfiguration plus "stamp"
//
// The region wins exactly once per stamp: the applied stamp is mirrored into
// NVS, so a board reconfigured later over Bluetooth keeps the newer settings
// instead of being dragged back to whatever was flashed months ago.

static const uint32_t CALIB_MAGIC       = 0x42434842UL;  // "BHCB", LE
static const uint16_t CALIB_VERSION     = 1;
static const size_t   CALIB_HEADER_SIZE = 16;
static const size_t   CALIB_MAX_PAYLOAD = 2048;

// Data-partition subtype in the user-defined range (0x40-0xFE).
static const esp_partition_subtype_t CALIB_SUBTYPE = (esp_partition_subtype_t)0x40;

uint32_t crc32Buf(const uint8_t* data, size_t len) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) {
      crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320UL : 0);
    }
  }
  return ~crc;
}

CalibRegion calibRegion() {
  CalibRegion r;
  const esp_partition_t* p =
      esp_partition_find_first(ESP_PARTITION_TYPE_DATA, CALIB_SUBTYPE, "calib");
  if (p) {
    r.offset = p->address;
    r.size   = p->size;
    r.found  = true;
    return r;
  }
#ifdef CALIB_FLASH_OFFSET
  r.offset = CALIB_FLASH_OFFSET;
  r.size   = 0x1000;
  r.found  = true;
#endif
  return r;
}

// Reads and validates the region. `payload` gets the JSON, `stamp` the value
// the phone tagged it with.
bool readCalibRegion(String& payload) {
  CalibRegion r = calibRegion();
  if (!r.found) return false;

  uint8_t head[CALIB_HEADER_SIZE];
  if (esp_flash_read(esp_flash_default_chip, head, r.offset, sizeof(head)) != ESP_OK)
    return false;

  uint32_t magic = (uint32_t)head[0] | ((uint32_t)head[1] << 8) |
                   ((uint32_t)head[2] << 16) | ((uint32_t)head[3] << 24);
  uint16_t ver   = (uint16_t)head[4] | ((uint16_t)head[5] << 8);
  uint32_t len   = (uint32_t)head[8] | ((uint32_t)head[9] << 8) |
                   ((uint32_t)head[10] << 16) | ((uint32_t)head[11] << 24);
  uint32_t crc   = (uint32_t)head[12] | ((uint32_t)head[13] << 8) |
                   ((uint32_t)head[14] << 16) | ((uint32_t)head[15] << 24);

  if (magic != CALIB_MAGIC || ver != CALIB_VERSION) return false;
  if (len == 0 || len > CALIB_MAX_PAYLOAD || len > r.size - CALIB_HEADER_SIZE)
    return false;

  uint8_t* buf = (uint8_t*)malloc(len + 1);
  if (!buf) return false;
  bool ok = esp_flash_read(esp_flash_default_chip, buf, r.offset + CALIB_HEADER_SIZE,
                           len) == ESP_OK &&
            crc32Buf(buf, len) == crc;
  if (ok) {
    buf[len] = 0;
    payload = String((const char*)buf);
  }
  free(buf);
  return ok;
}

// Rewrites the region from the board itself, so a calibration that arrived
// over Bluetooth also survives a later app reflash.
bool writeCalibRegion(const String& payload) {
  CalibRegion r = calibRegion();
  if (!r.found) return false;
  size_t len = payload.length();
  if (len == 0 || len > CALIB_MAX_PAYLOAD || len + CALIB_HEADER_SIZE > r.size)
    return false;

  uint32_t crc = crc32Buf((const uint8_t*)payload.c_str(), len);
  uint8_t head[CALIB_HEADER_SIZE] = {0};
  head[0] = (uint8_t)(CALIB_MAGIC);       head[1] = (uint8_t)(CALIB_MAGIC >> 8);
  head[2] = (uint8_t)(CALIB_MAGIC >> 16); head[3] = (uint8_t)(CALIB_MAGIC >> 24);
  head[4] = (uint8_t)(CALIB_VERSION);     head[5] = (uint8_t)(CALIB_VERSION >> 8);
  head[8] = (uint8_t)(len);        head[9]  = (uint8_t)(len >> 8);
  head[10] = (uint8_t)(len >> 16); head[11] = (uint8_t)(len >> 24);
  head[12] = (uint8_t)(crc);       head[13] = (uint8_t)(crc >> 8);
  head[14] = (uint8_t)(crc >> 16); head[15] = (uint8_t)(crc >> 24);

  if (esp_flash_erase_region(esp_flash_default_chip, r.offset, r.size) != ESP_OK)
    return false;
  if (esp_flash_write(esp_flash_default_chip, head, r.offset, sizeof(head)) != ESP_OK)
    return false;
  return esp_flash_write(esp_flash_default_chip, (const void*)payload.c_str(),
                         r.offset + CALIB_HEADER_SIZE, len) == ESP_OK;
}

// Applied at boot, before the first sample: the region is how a board that has
// never been provisioned knows which pin the battery is even on.
void applyCalibRegion() {
  String payload;
  if (!readCalibRegion(payload)) return;

  StaticJsonDocument<768> doc;
  if (deserializeJson(doc, payload)) return;
  uint32_t stamp = doc["stamp"] | 0UL;

  prefs.begin("bh", true);
  uint32_t applied = prefs.getULong("calstamp", 0);
  prefs.end();
  if (stamp != 0 && stamp == applied) return;   // already in NVS

  if (!applyConfigJson(payload)) return;
  if (doc.containsKey("power")) applyPowerJson(doc["power"].as<JsonObjectConst>());

  prefs.begin("bh", false);
  prefs.putULong("calstamp", stamp);
  prefs.end();
  Serial.printf("[calib] applied stamp=%u pin=%d\n", stamp, cfg.adcPin);
}

// Power/mode block, mirrored by the app's "Power" screen.
void fillPowerJson(JsonObject o) {
  o["mode"]          = runMode == MODE_WIFI ? "wifi"
                       : (runMode == MODE_BLE ? "ble" : "pairing");
  o["sleepEnabled"]  = cfg.sleepEnabled;
  o["bleWakeSec"]    = cfg.bleWakeSec;
  o["bleWindowMs"]   = cfg.bleWindowMs;
  o["bleIdleMs"]     = cfg.bleIdleMs;
  o["wifiReportSec"] = cfg.wifiReportSec;
  o["wifiWindowMs"]  = cfg.wifiWindowMs;
  o["bleInWifi"]     = cfg.bleInWifi;
}

bool applyPowerJson(JsonObjectConst o) {
  if (o.isNull()) return false;
  if (o.containsKey("sleepEnabled"))  cfg.sleepEnabled  = o["sleepEnabled"];
  if (o.containsKey("bleWakeSec"))    cfg.bleWakeSec    = o["bleWakeSec"];
  if (o.containsKey("bleWindowMs"))   cfg.bleWindowMs   = o["bleWindowMs"];
  if (o.containsKey("bleIdleMs"))     cfg.bleIdleMs     = o["bleIdleMs"];
  if (o.containsKey("wifiReportSec")) cfg.wifiReportSec = o["wifiReportSec"];
  if (o.containsKey("wifiWindowMs"))  cfg.wifiWindowMs  = o["wifiWindowMs"];
  if (o.containsKey("bleInWifi"))     cfg.bleInWifi     = o["bleInWifi"];
  savePower();
  return true;
}

// ----------------------------------------------------------------- status ---

// Compact device status.
//
// This has to fit in a single notification, which carries MTU-3 bytes — and
// nothing tells you when it does not: the notification is simply truncated, the
// app's JSON parse fails, and an event the whole provisioning handshake waits
// on never arrives. So: only fields that change, kept short. Anything static
// about the board (its pins, its wiring) belongs in configJson, which is read
// rather than notified and has no such limit.
bool usbConsoleAttached();

void fillStatus(JsonObject doc, const char* event, const char* detail) {
  // Marks every line the board addresses to the app, so the serial console can
  // be shared with a human staring at the boot log.
  doc["bh"] = 1;
  if (event)  doc["ev"] = event;
  if (detail) doc["detail"] = detail;
  doc["id"]    = deviceId();
  doc["name"]  = deviceName();      // the automatic one is derivable from id
  doc["fw"]    = FW_VERSION;
  doc["mode"]  = runMode == MODE_WIFI ? "wifi"
                 : (runMode == MODE_BLE ? "ble" : "pairing");
  doc["prov"]  = provisioned();
  doc["raw"]   = lastRaw;
  doc["volts"] = lastVolts;
  doc["soc"]   = (int)(stateOfCharge(lastVolts) * 100);
  doc["boot"]  = bootCount;
  doc["wifi"]  = wifiOnline ? "online" : (hasWifiCreds() ? "offline" : "none");
  if (wifiOnline) {
    doc["ip"]   = WiFi.localIP().toString();
    doc["rssi"] = WiFi.RSSI();
  }
  if (hasWifiCreds()) doc["ssid"] = cfg.ssid;
  doc["cloud"] = hasCloud();
  doc["led"]   = hasStatusLed();     // which pin is in configJson
  doc["usb"]   = usbConsoleAttached();
  // How long before this wake ends, so the app knows whether to hurry.
  int32_t left = (int32_t)(stayAwakeUntil - millis());
  doc["sleepInMs"]   = (!cfg.sleepEnabled || sleepBlocked) ? -1 : (left < 0 ? 0 : left);
  doc["nextWakeSec"] = runMode == MODE_WIFI ? cfg.wifiReportSec : cfg.bleWakeSec;
}

String statusJson(const char* event = nullptr, const char* detail = nullptr) {
  StaticJsonDocument<480> doc;
  fillStatus(doc.to<JsonObject>(), event, detail);
  String out; serializeJson(doc, out); return out;
}

bool serialAttached();

void pushStatus(const char* event = nullptr, const char* detail = nullptr) {
  String s = statusJson(event, detail);
  if (chStatus) {
    chStatus->setValue(s.c_str());
    if (bleConnected) chStatus->notify();
  }
  // The USB console sees the same event stream the app gets over BLE.
  if (serialAttached()) serialWriteLine(s);
}

// Arm the blink and return immediately. The board reports which of the two
// things happened, so the app can say "no LED on this board" instead of
// leaving the user staring at hardware that was never going to light up.
void startIdentify(uint8_t pulses = 6) {
  if (!hasStatusLed()) {
    pushStatus("identify", "no-led");
    return;
  }
  pinMode(cfg.ledPin, OUTPUT);
  blinkEdgesLeft = pulses * 2;
  blinkNextAt = millis();
  blinkOn = false;
  extendWake(pulses * 2 * BLINK_MS + 2000);
  pushStatus("identify", "blinking");
}

void serviceIdentify() {
  if (blinkEdgesLeft == 0) return;
  if ((int32_t)(millis() - blinkNextAt) < 0) return;
  blinkOn = !blinkOn;
  ledWrite(blinkOn);
  blinkNextAt = millis() + BLINK_MS;
  if (--blinkEdgesLeft == 0) ledWrite(false);
}

// ------------------------------------------------------------ advertising ---

// Six bytes of manufacturer data let the app show battery + pairing state
// straight from the scan result, without connecting:
//   [0] 0x42 marker  [1] proto version  [2] flags  [3..4] mV LE  [5] soc %
void refreshAdvertisementData() {
  if (!advertising) return;
  uint8_t flags = 0;
  if (provisioned())           flags |= 0x01;
  if (runMode == MODE_WIFI)    flags |= 0x02;
  if (runMode == MODE_PAIRING) flags |= 0x04;
  if (wifiOnline)              flags |= 0x08;

  uint16_t mv = (uint16_t)(lastVolts * 1000.0f);
  uint8_t soc = (uint8_t)(stateOfCharge(lastVolts) * 100);

  uint8_t payload[8] = {
    (uint8_t)(ADV_COMPANY_ID & 0xFF), (uint8_t)(ADV_COMPANY_ID >> 8),
    0x42, 0x01, flags,
    (uint8_t)(mv & 0xFF), (uint8_t)(mv >> 8), soc,
  };

  BLEAdvertisementData adv;
  adv.setFlags(0x06);  // LE General Discoverable | BR/EDR not supported
  adv.setCompleteServices(BLEUUID(SVC_UUID));

  BLEAdvertisementData scan;
  // Cap it: the scan response has 31 bytes to hold the whole thing.
  scan.setName(deviceName().substring(0, 24).c_str());
  scan.setManufacturerData(String((const char*)payload, sizeof(payload)));

  advertising->setAdvertisementData(adv);
  advertising->setScanResponseData(scan);
}

// ---------------------------------------------------------- BLE callbacks ---

void notifyCtl(uint8_t status, const char* msg = nullptr) {
  uint8_t buf[24]; buf[0] = status; size_t n = 1;
  if (msg) { size_t m = strlen(msg); if (m > 22) m = 22; memcpy(buf + 1, msg, m); n += m; }
  chCtl->setValue(buf, n); chCtl->notify();
}

// CCCD writes tell us whether an app is actually watching the sample stream.
class SubscribeCB : public BLEDescriptorCallbacks {
  void onWrite(BLEDescriptor* d) override {
    uint8_t* v = d->getValue();
    notifySubscribed = d->getLength() >= 1 && (v[0] & 0x01);
    lastBleActivity = millis();
    if (notifySubscribed) extendWake(cfg.bleIdleMs);
  }
};

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleConnected = true;
    lastBleActivity = millis();
    // A connected app owns the session: never sleep out from under it.
    extendWake(cfg.bleIdleMs);
  }
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    notifySubscribed = false;
    lastBleActivity = millis();
    refreshAdvertisementData();
    s->startAdvertising();
    // Nothing left to say — in a sleeping mode, wrap this wake up quickly.
    if (runMode != MODE_PAIRING && cfg.sleepEnabled && !sleepBlocked) {
      stayAwakeUntil = millis() + 1500;
    }
  }
};

class CfgCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    lastBleActivity = millis();
    extendWake(cfg.bleIdleMs);
    applyConfigJson(String(c->getValue().c_str()));
    refreshAdvertisementData();     // the name may have just changed
    pushStatus("config");
  }
  void onRead(BLECharacteristic* c) override { c->setValue(configJson().c_str()); }
};

class OtaCtlCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    if (v.isEmpty()) return;
    lastBleActivity = millis();
    uint8_t cmd = (uint8_t)v[0];
    if (cmd == 0x01 && v.length() >= 5) {                 // START | size(LE)
      otaExpected = (uint32_t)(uint8_t)v[1] | ((uint32_t)(uint8_t)v[2] << 8) |
                    ((uint32_t)(uint8_t)v[3] << 16) | ((uint32_t)(uint8_t)v[4] << 24);
      otaReceived = 0;
      otaActive = Update.begin(otaExpected);
      notifyCtl(otaActive ? 0x00 : 0x1F, otaActive ? nullptr : "begin failed");
    } else if (cmd == 0x02) {                            // END | crc32
      bool ok = otaActive && Update.end(true) && otaReceived == otaExpected;
      notifyCtl(ok ? 0x10 : 0x1F, ok ? nullptr : "verify failed");
      otaActive = false;
      if (ok) { delay(200); ESP.restart(); }
    }
  }
};

class OtaDatCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (!otaActive) return;
    lastBleActivity = millis();
    String v = c->getValue();
    otaReceived += Update.write((uint8_t*)v.c_str(), v.length());
  }
};

bool connectWiFi(uint32_t timeoutMs);
bool reportTelemetry();
void setupHTTP();

// Set by the provisioning callback, executed in loop(): joining Wi-Fi takes
// seconds and must not block the BLE stack's callback thread.
volatile bool provPending = false;

void beginProvisioning(const String& body);

// Provisioning: the app writes SSID + password + backend token here, once,
// over an already-connected BLE link. The board tries the credentials
// immediately and reports the result as status events, so the app can show
// "connecting / connected / wrong password" without disconnecting.
class ProvCB : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* c) override {
    StaticJsonDocument<256> doc;
    doc["prov"]  = provisioned();
    doc["ssid"]  = cfg.ssid;          // never the password
    doc["cloud"] = hasCloud();
    doc["mode"]  = cfg.mode == MODE_WIFI ? "wifi"
                   : (cfg.mode == MODE_BLE ? "ble" : "pairing");
    String out; serializeJson(doc, out);
    c->setValue(out.c_str());
  }

  void onWrite(BLECharacteristic* c) override {
    lastBleActivity = millis();
    beginProvisioning(String(c->getValue().c_str()));
  }
};

// Shared by the BLE provisioning characteristic and the serial console, so a
// board set up over the cable ends up in exactly the same state as one set up
// over the air (DEVICE_PROTOCOL.md §2.2).
void beginProvisioning(const String& body) {
  sleepBlocked = true;             // hold the board up for the whole handshake
  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, body)) {
    sleepBlocked = false;
    pushStatus("prov", "bad json");
    return;
  }

  String mode = doc["mode"] | "wifi";
  if (doc.containsKey("ssid"))
    strlcpy(cfg.ssid, doc["ssid"] | "", sizeof(cfg.ssid));
  if (doc.containsKey("password"))
    strlcpy(cfg.pass, doc["password"] | "", sizeof(cfg.pass));
  if (doc.containsKey("backendUrl"))
    strlcpy(cfg.backendUrl, doc["backendUrl"] | "", sizeof(cfg.backendUrl));
  if (doc.containsKey("deviceToken"))
    strlcpy(cfg.token, doc["deviceToken"] | "", sizeof(cfg.token));
  saveCloud();

  if (doc.containsKey("power")) applyPowerJson(doc["power"].as<JsonObjectConst>());
  if (doc.containsKey("reportIntervalSec")) {
    cfg.wifiReportSec = doc["reportIntervalSec"];
    savePower();
  }

  if (mode == "ble") {
    cfg.mode = MODE_BLE; runMode = MODE_BLE; savePower();
    refreshAdvertisementData();
    pushStatus("prov", "ble mode");
    sleepBlocked = false;
    extendWake(cfg.bleIdleMs);
    return;
  }

  // Wi-Fi mode: the join is verified before the mode is committed, so a typo
  // can never strand the board somewhere the app cannot reach it. The work
  // itself happens in loop() — see finishProvisioning().
  pushStatus("wifi", "connecting");
  provPending = true;
}

// Second half of provisioning, on the main task.
void finishProvisioning() {
  if (!connectWiFi(20000)) {
    pushStatus("wifi", "failed");
    sleepBlocked = false;
    extendWake(cfg.bleIdleMs);
    return;
  }
  pushStatus("wifi", "connected");

  cfg.mode = MODE_WIFI; runMode = MODE_WIFI; savePower();
  refreshAdvertisementData();
  setupHTTP();

  if (hasCloud()) {
    pushStatus("cloud", reportTelemetry() ? "registered" : "unreachable");
  }
  pushStatus("prov", "done");
  sleepBlocked = false;
  extendWake(cfg.bleIdleMs);
}

// Session control: who decides when the board sleeps. The BLE session
// characteristic and the serial console both drive these helpers, so the two
// transports can never drift apart.
void sessionStayAwake(uint32_t sec) {
  if (sec == 0) {
    sleepBlocked = true;             // until the app disconnects
  } else {
    sleepBlocked = false;
    extendWake(min(sec, (uint32_t)3600) * 1000UL);
  }
  pushStatus("awake");
}

void sessionSleep(uint32_t sec) {
  if (sec > 0) {
    if (runMode == MODE_WIFI) cfg.wifiReportSec = sec; else cfg.bleWakeSec = sec;
    savePower();
  }
  sleepBlocked = false;
  sleepRequested = true;
  pushStatus("sleeping");
}

void sessionSetMode(uint8_t m) {
  if (m > MODE_WIFI) return;
  cfg.mode = m; runMode = m; savePower();
  refreshAdvertisementData();
  pushStatus("mode");
}

void sessionForgetWifi() {
  cfg.ssid[0] = 0; cfg.pass[0] = 0;
  cfg.mode = MODE_BLE; runMode = MODE_BLE;
  saveCloud(); savePower();
  pushStatus("wifi", "forgotten");
}

void sessionFactoryReset() {
  pushStatus("reset");
  delay(100);
  factoryReset();
  ESP.restart();
}

// The GATT wrapper around them (DEVICE_PROTOCOL.md §2.4):
//   0x01 STAY_AWAKE  [uint16 sec]  extend this wake (0 = until disconnect)
//   0x02 SLEEP_NOW   [uint32 sec]  sleep immediately, optional interval override
//   0x03 FACTORY_RESET
//   0x04 SET_MODE    [uint8 mode]
//   0x05 FORGET_WIFI
//   0x06 IDENTIFY
class SessionCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    if (v.isEmpty()) return;
    lastBleActivity = millis();

    switch ((uint8_t)v[0]) {
      case 0x01:
        sessionStayAwake(v.length() >= 3
            ? ((uint32_t)(uint8_t)v[1] | ((uint32_t)(uint8_t)v[2] << 8)) : 0);
        break;
      case 0x02:
        sessionSleep(v.length() >= 5
            ? ((uint32_t)(uint8_t)v[1] | ((uint32_t)(uint8_t)v[2] << 8) |
               ((uint32_t)(uint8_t)v[3] << 16) | ((uint32_t)(uint8_t)v[4] << 24)) : 0);
        break;
      case 0x03: sessionFactoryReset(); break;
      case 0x04: if (v.length() >= 2) sessionSetMode((uint8_t)v[1]); break;
      case 0x05: sessionForgetWifi(); break;
      case 0x06: startIdentify(); break;
      default: break;
    }
  }
};

// ------------------------------------------------------------ serial link ---
//
// Everything the phone can do over Bluetooth it can also do over the USB
// cable. That matters for a board fresh off the reel: the phone has just
// flashed it over UART and there is no radio session yet, but the calibration
// still has to get in. Framing is one JSON object per line at 115200 baud:
//
//   phone -> board   {"cmd":"config","config":{ …PinConfiguration }}
//   board -> phone   {"bh":1,"re":"config","ok":true}
//   board -> phone   {"bh":1,"ev":"config", …status fields}   (unsolicited)
//
// Every line meant for the phone carries "bh":1; the human-readable boot log
// does not, so a serial terminal and the app can share the same port. The full
// command list is in DEVICE_PROTOCOL.md §7.

static const uint32_t SERIAL_SESSION_MS = 60000;
String   serialLine;
uint32_t serialActiveUntil = 0;
#if BH_USB_CONSOLE
String   altSerialLine;
#endif

// The phone does not tell us which port it is on, so answers go to both.
void serialWriteLine(const String& line) {
  Serial.println(line);
#if BH_USB_CONSOLE
  BH_ALT_SERIAL.println(line);
#endif
}

// True while a phone is talking to us over the cable. Sleeping mid-conversation
// would look exactly like a failed flash from the app's side.
bool serialAttached() { return (int32_t)(serialActiveUntil - millis()) > 0; }

// True while a USB host has this board's native port open.
//
// Deep sleep powers the USB-Serial-JTAG peripheral down, so a board that sleeps
// while plugged into a phone *disappears from the phone* — the app loses its
// session mid-sentence and cannot get it back until the next wake. A board on a
// USB host is also a board someone is working on, and it is running on that
// host's power, so it stays up for as long as the cable is in. A plain charger
// never enumerates, so this does not keep a field board awake.
bool usbConsoleAttached() {
#if BH_USB_CONSOLE
  return (bool)Serial;
#else
  return false;
#endif
}

void serialSend(JsonDocument& doc) {
  doc["bh"] = 1;
  String out;
  serializeJson(doc, out);
  serialWriteLine(out);
}

void serialReply(const char* re, bool ok, const char* detail = nullptr) {
  StaticJsonDocument<192> doc;
  doc["re"] = re;
  doc["ok"] = ok;
  if (detail) doc["detail"] = detail;
  serialSend(doc);
}

void serialStatus(const char* re) {
  StaticJsonDocument<512> doc;
  JsonObject o = doc.to<JsonObject>();
  fillStatus(o, nullptr, nullptr);
  o["re"] = re;
  o["ok"] = true;
  serialSend(doc);
}

void handleSerialLine(const String& line) {
  StaticJsonDocument<768> req;
  if (deserializeJson(req, line)) { serialReply("?", false, "bad json"); return; }
  String cmd = req["cmd"] | "";
  if (cmd.isEmpty()) return;          // somebody else's JSON, not a command

  // A phone on the wire owns the board for the next minute.
  serialActiveUntil = millis() + SERIAL_SESSION_MS;
  extendWake(SERIAL_SESSION_MS);

  if (cmd == "hello" || cmd == "status") {
    serialStatus(cmd.c_str());
    return;
  }

  if (cmd == "getconfig") {
    StaticJsonDocument<512> doc;
    deserializeJson(doc, configJson());
    doc["re"] = "getconfig";
    doc["ok"] = true;
    serialSend(doc);
    return;
  }

  // "config" applies the settings for this session; "calib" also burns them
  // into the flash region, so they survive a later reflash of the app.
  if (cmd == "config" || cmd == "calib") {
    String body;
    if (req.containsKey("config")) serializeJson(req["config"], body);
    else body = line;               // a bare PinConfiguration with "cmd" added

    if (!applyConfigJson(body)) { serialReply(cmd.c_str(), false, "bad config"); return; }

    if (cmd == "calib") {
      StaticJsonDocument<768> doc;
      deserializeJson(doc, body);
      doc.remove("cmd");
      doc["stamp"] = (uint32_t)(req["stamp"] | 0UL);
      String stored;
      serializeJson(doc, stored);
      if (!writeCalibRegion(stored)) {
        serialReply("calib", false, "no calib region");
        pushStatus("config");
        return;
      }
      prefs.begin("bh", false);
      prefs.putULong("calstamp", (uint32_t)(req["stamp"] | 0UL));
      prefs.end();
    }
    serialReply(cmd.c_str(), true);
    pushStatus("config");
    return;
  }

  if (cmd == "getcalib") {
    String payload;
    bool ok = readCalibRegion(payload);
    CalibRegion r = calibRegion();
    StaticJsonDocument<1024> doc;
    doc["re"]     = "getcalib";
    doc["ok"]     = ok;
    doc["region"] = r.offset;
    doc["size"]   = r.size;
    if (ok) {
      StaticJsonDocument<768> stored;
      if (!deserializeJson(stored, payload)) doc["calib"] = stored;
    }
    serialSend(doc);
    return;
  }

  if (cmd == "getpower") {
    StaticJsonDocument<384> doc;
    fillPowerJson(doc.to<JsonObject>());
    doc["re"] = "getpower";
    doc["ok"] = true;
    serialSend(doc);
    return;
  }

  if (cmd == "power") {
    serialReply("power", applyPowerJson(req["power"].as<JsonObjectConst>()));
    return;
  }

  // Same handler the BLE provisioning characteristic uses, so a board set up
  // over the cable lands in exactly the same state as one set up over the air.
  if (cmd == "prov") {
    serialReply("prov", true, "started");
    beginProvisioning(line);
    return;
  }

  if (cmd == "session") {
    String op = req["op"] | "";
    if (op == "stayAwake") {
      sessionStayAwake((uint32_t)(req["seconds"] | 0UL));
      serialReply("session", true, "awake");
    } else if (op == "sleep") {
      sessionSleep((uint32_t)(req["seconds"] | 0UL));
      serialReply("session", true, "sleeping");
    } else if (op == "identify") {
      startIdentify();
      serialReply("session", true, "identify");
    } else if (op == "setMode") {
      sessionSetMode((uint8_t)(req["mode"] | 0));
      serialReply("session", true, "mode");
    } else if (op == "forgetWifi") {
      sessionForgetWifi();
      serialReply("session", true, "wifi forgotten");
    } else if (op == "factoryReset") {
      serialReply("session", true, "reset");
      Serial.flush();
      delay(100);
      sessionFactoryReset();          // wipes NVS and reboots
    } else {
      serialReply("session", false, "unknown op");
    }
    return;
  }

  serialReply(cmd.c_str(), false, "unknown cmd");
}

void drainSerial(Stream& stream, String& buffer) {
  while (stream.available()) {
    char ch = (char)stream.read();
    if (ch == '\r') continue;
    if (ch != '\n') {
      if (buffer.length() < 1024) buffer += ch;
      else buffer = "";               // runaway line: drop it and resync
      continue;
    }
    String line = buffer;
    buffer = "";
    line.trim();
    if (line.startsWith("{")) handleSerialLine(line);
  }
}

void serviceSerial() {
  drainSerial(Serial, serialLine);
#if BH_USB_CONSOLE
  drainSerial(BH_ALT_SERIAL, altSerialLine);
#endif
}

void setupBLE() {
  if (bleActive) return;
  // Ask for the largest MTU the stack will take *before* init: the core leaves
  // the local MTU at the 23-byte default otherwise, which caps notifications at
  // 20 bytes and silently truncates every status push.
  BLEDevice::setMTU(517);
  BLEDevice::init(deviceName().substring(0, 24).c_str());
  BLEServer* srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerCB());
  BLEService* svc = srv->createService(BLEUUID(SVC_UUID), 30);

  BLE2902* volt2902 = new BLE2902();
  volt2902->setCallbacks(new SubscribeCB());
  chVolt = svc->createCharacteristic(CH_VOLT, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chVolt->addDescriptor(volt2902);

  BLE2902* raw2902 = new BLE2902();
  raw2902->setCallbacks(new SubscribeCB());
  chRaw = svc->createCharacteristic(CH_RAW, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chRaw->addDescriptor(raw2902);

  BLECharacteristic* chCfg = svc->createCharacteristic(CH_CFG, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  chCfg->setCallbacks(new CfgCB());

  chCtl = svc->createCharacteristic(CH_OTACTL, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  chCtl->addDescriptor(new BLE2902());
  chCtl->setCallbacks(new OtaCtlCB());

  BLECharacteristic* chDat = svc->createCharacteristic(CH_OTADAT, BLECharacteristic::PROPERTY_WRITE_NR);
  chDat->setCallbacks(new OtaDatCB());

  BLECharacteristic* chProv = svc->createCharacteristic(CH_PROV, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  chProv->setCallbacks(new ProvCB());

  chStatus = svc->createCharacteristic(CH_STATUS, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chStatus->addDescriptor(new BLE2902());

  BLECharacteristic* chSess = svc->createCharacteristic(CH_SESSION, BLECharacteristic::PROPERTY_WRITE);
  chSess->setCallbacks(new SessionCB());

  svc->start();
  advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SVC_UUID);
  refreshAdvertisementData();
  advertising->start();
  bleActive = true;
  pushStatus("boot");
}

void stopBLE() {
  if (!bleActive) return;
  BLEDevice::deinit(true);
  bleActive = false;
  bleConnected = false;
  chVolt = chRaw = chCtl = chStatus = nullptr;
  advertising = nullptr;
}

// ------------------------------------------------------------- Wi-Fi/HTTP ---

bool connectWiFi(uint32_t timeoutMs) {
  if (!hasWifiCreds()) return false;
  if (WiFi.status() == WL_CONNECTED) { wifiOnline = true; return true; }

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(true);          // modem sleep between beacons
  WiFi.begin(cfg.ssid, cfg.pass);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < timeoutMs) {
    delay(100);
  }
  wifiOnline = WiFi.status() == WL_CONNECTED;
  if (wifiOnline) {
    wifiFailStreak = 0;
    if (MDNS.begin(HOSTNAME)) MDNS.addService("batteryholder", "tcp", 80);
  } else if (wifiFailStreak < 255) {
    wifiFailStreak++;
  }
  return wifiOnline;
}

// One HTTP client factory so http:// and https:// backends behave the same.
static WiFiClient plainClient;
static WiFiClientSecure tlsClient;

bool beginHttp(HTTPClient& http, const String& url) {
  if (url.startsWith("https://")) {
    // Production builds should pin the backend root CA here instead.
    tlsClient.setInsecure();
    return http.begin(tlsClient, url);
  }
  return http.begin(plainClient, url);
}

void pullOTA(const String& url);

// Applies one command from the backend. Returns true if the board should stay
// awake longer (e.g. an OTA is coming).
bool applyCommand(JsonObjectConst cmd) {
  String type = cmd["type"] | "";
  if (type == "setConfig") {
    String body; serializeJson(cmd["config"], body);
    applyConfigJson(body);
  } else if (type == "setPower") {
    applyPowerJson(cmd["power"].as<JsonObjectConst>());
  } else if (type == "setMode") {
    String m = cmd["mode"] | "";
    if      (m == "ble")     cfg.mode = MODE_BLE;
    else if (m == "wifi")    cfg.mode = MODE_WIFI;
    else if (m == "pairing") cfg.mode = MODE_PAIRING;
    savePower();
  } else if (type == "identify") {
    startIdentify();
    return true;   // hold the wake open long enough to finish blinking
  } else if (type == "stayAwake") {
    uint32_t sec = cmd["seconds"] | 60;
    extendWake(min(sec, (uint32_t)3600) * 1000UL);
    return true;
  } else if (type == "ble") {
    // Cloud asks the board to open a BLE window so the phone can connect.
    setupBLE();
    extendWake((uint32_t)(cmd["seconds"] | 60) * 1000UL);
    return true;
  } else if (type == "ota") {
    String url = cmd["url"] | "";
    if (url.length()) { pullOTA(url); return true; }
  }
  return false;
}

// POST one telemetry frame; apply whatever the backend answers with.
bool reportTelemetry() {
  if (!hasCloud() || !wifiOnline) return false;

  String url = String(cfg.backendUrl);
  if (!url.endsWith("/")) url += "/";
  url += "devices/" + deviceId() + "/telemetry";

  StaticJsonDocument<448> doc;
  doc["deviceId"]  = deviceId();
  doc["fw"]        = FW_VERSION;
  doc["boot"]      = bootCount;
  doc["raw"]       = lastRaw;
  doc["volts"]     = lastVolts;
  doc["soc"]       = stateOfCharge(lastVolts);
  doc["pin"]       = String("gpio") + cfg.adcPin;
  doc["rssi"]      = WiFi.RSSI();
  doc["ip"]        = WiFi.localIP().toString();
  doc["uptimeMs"]  = millis();
  doc["wake"]      = (int)esp_sleep_get_wakeup_cause();
  doc["reportSec"] = cfg.wifiReportSec;
  String body; serializeJson(doc, body);

  HTTPClient http;
  if (!beginHttp(http, url)) return false;
  http.setTimeout(8000);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Device-Token", cfg.token);
  int code = http.POST(body);
  if (code != 200) { http.end(); return false; }

  DynamicJsonDocument res(2048);
  DeserializationError err = deserializeJson(res, http.getString());
  http.end();
  if (err) return true;   // delivered; we just cannot act on the reply

  if (res.containsKey("nextReportSec")) {
    uint32_t next = res["nextReportSec"];
    if (next >= 10 && next != cfg.wifiReportSec) { cfg.wifiReportSec = next; savePower(); }
  }
  if (res.containsKey("stayAwakeMs")) {
    uint32_t ms = res["stayAwakeMs"];
    if (ms > 0) extendWake(min(ms, (uint32_t)600000));
  }
  for (JsonObjectConst cmd : res["commands"].as<JsonArrayConst>()) {
    if (applyCommand(cmd)) extendWake(30000);
  }
  return true;
}

// Firmware pulled straight from the backend's presigned URL — the path the
// cloud uses when the phone is nowhere near the board.
void pullOTA(const String& url) {
  HTTPClient http;
  if (!beginHttp(http, url)) return;
  http.setTimeout(15000);
  int code = http.GET();
  if (code != 200) { http.end(); return; }

  int len = http.getSize();
  if (len <= 0 || !Update.begin(len)) { http.end(); return; }
  otaActive = true;
  size_t written = Update.writeStream(*http.getStreamPtr());
  bool ok = written == (size_t)len && Update.end(true);
  otaActive = false;
  http.end();
  if (ok) { delay(200); ESP.restart(); }
}

void handleVoltage() {
  sampleBattery();
  StaticJsonDocument<192> doc;
  doc["raw"]   = lastRaw;
  doc["volts"] = lastVolts;
  doc["soc"]   = stateOfCharge(lastVolts);
  doc["pin"]   = String("gpio") + cfg.adcPin;
  String out; serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void setupHTTP() {
  if (httpStarted) return;
  httpStarted = true;
  server.on("/api/voltage", HTTP_GET, handleVoltage);
  // Local twin of the BLE status characteristic.
  server.on("/api/status", HTTP_GET, [] { server.send(200, "application/json", statusJson()); });
  server.on("/api/config", HTTP_GET, [] { server.send(200, "application/json", configJson()); });
  server.on("/api/config", HTTP_POST, [] {
    bool ok = applyConfigJson(server.arg("plain"));
    server.send(ok ? 200 : 400, "application/json", ok ? "{\"ok\":true}" : "{\"ok\":false}");
  });
  server.on("/api/power", HTTP_GET, [] {
    StaticJsonDocument<320> doc;
    fillPowerJson(doc.to<JsonObject>());
    String out; serializeJson(doc, out);
    server.send(200, "application/json", out);
  });
  server.on("/api/power", HTTP_POST, [] {
    StaticJsonDocument<320> doc;
    bool ok = !deserializeJson(doc, server.arg("plain")) &&
              applyPowerJson(doc.as<JsonObjectConst>());
    // A local client that is actively configuring should not be cut off.
    extendWake(cfg.wifiWindowMs);
    server.send(ok ? 200 : 400, "application/json", ok ? "{\"ok\":true}" : "{\"ok\":false}");
  });
  // Multipart OTA upload. Holds the board awake for the whole transfer.
  server.on("/update", HTTP_POST,
    [] { server.send(Update.hasError() ? 500 : 200, "text/plain", Update.hasError() ? "FAIL" : "OK"); delay(200); ESP.restart(); },
    [] {
      HTTPUpload& up = server.upload();
      if (up.status == UPLOAD_FILE_START)      { otaActive = true; Update.begin(UPDATE_SIZE_UNKNOWN); }
      else if (up.status == UPLOAD_FILE_WRITE) { Update.write(up.buf, up.currentSize); }
      else if (up.status == UPLOAD_FILE_END)   { Update.end(true); otaActive = false; }
    });
  server.begin();
}

// ------------------------------------------------------------- deep sleep ---

bool buttonPressed() {
  if (cfg.buttonPin < 0) return false;
  pinMode(cfg.buttonPin, INPUT_PULLUP);
  return digitalRead(cfg.buttonPin) == LOW;
}

uint32_t sleepSeconds() {
  if (runMode == MODE_WIFI) return cfg.wifiReportSec;
  if (!provisioned())       return UNCLAIMED_SLEEP_SEC;
  return cfg.bleWakeSec;
}

void goToSleep(uint32_t seconds) {
  if (seconds < 1) seconds = 1;
  pushStatus("sleeping");
  delay(60);                       // let the last notification drain

  stopBLE();
  server.stop();
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);

  esp_sleep_enable_timer_wakeup((uint64_t)seconds * 1000000ULL);
  if (isWakeCapable(cfg.buttonPin)) {
#if SOC_PM_SUPPORT_EXT0_WAKEUP
    esp_sleep_enable_ext0_wakeup((gpio_num_t)cfg.buttonPin, 0);
#else
    // C3/S3: the pad keeps no internal pull-up across deep sleep, so the button
    // needs an external one (or it will wake the board continuously).
    esp_deep_sleep_enable_gpio_wakeup(1ULL << cfg.buttonPin, ESP_GPIO_WAKEUP_GPIO_LOW);
#endif
  }
  Serial.printf("[sleep] %u s\n", seconds);
  Serial.flush();
  esp_deep_sleep_start();          // never returns; setup() runs again on wake
}

// The single place that decides whether this wake is over.
void maybeSleep() {
  if (sleepRequested) { goToSleep(sleepSeconds()); return; }
  if (!cfg.sleepEnabled || sleepBlocked) return;
  if (serialAttached()) return;     // a phone is mid-conversation on the cable
  // Sleeping would take the native USB port down with it, so a board on a USB
  // host stays up until the cable comes out.
  if (usbConsoleAttached()) return;
  if (otaActive) { extendWake(30000); return; }
  if (blinkEdgesLeft > 0) return;   // finish identifying first

  if (bleConnected) {
    // An app watching the stream keeps the board up; a silent one does not.
    if (!notifySubscribed && millis() - lastBleActivity > cfg.bleIdleMs) {
      goToSleep(sleepSeconds());
    }
    return;
  }
  if ((int32_t)(millis() - stayAwakeUntil) >= 0) goToSleep(sleepSeconds());
}

// ------------------------------------------------------------------ setup ---

void setup() {
  Serial.begin(115200);
#if BH_USB_CONSOLE
  BH_ALT_SERIAL.begin(115200);      // the UART, when Serial is the USB port
#endif
  bootCount++;
  loadConfig();
  // Whatever the phone burned in over USB outranks the compiled-in defaults,
  // and it is the only thing a board that has never been provisioned has.
  applyCalibRegion();
  sampleBattery();

  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  bool buttonWake = cause == ESP_SLEEP_WAKEUP_EXT0 ||
                    cause == ESP_SLEEP_WAKEUP_GPIO ||
                    (cause == ESP_SLEEP_WAKEUP_UNDEFINED && buttonPressed());

  // A reset or a power-on is a person: the timer is the only wake source that
  // is not. Every dev board has an RST button even when it has no pairing
  // button wired, so treat that press as "I want to talk to this board now"
  // and stay reachable for a couple of minutes instead of the usual seconds.
  bool userPresent = buttonWake || cause == ESP_SLEEP_WAKEUP_UNDEFINED;

  runMode = provisioned() ? cfg.mode : MODE_PAIRING;
  if (buttonWake) runMode = MODE_PAIRING;   // always reachable by the phone

  Serial.printf("[boot] %s fw=%s mode=%u boot=%u wake=%d\n",
                deviceId().c_str(), FW_VERSION, runMode, bootCount, (int)cause);

  switch (runMode) {
    case MODE_PAIRING:
      setupBLE();
      // The long window is for the boot the user is present for. Timer wakes
      // just advertise briefly and sleep again.
      stayAwakeUntil = millis() + (userPresent ? PAIRING_WINDOW_MS : cfg.bleWindowMs);
      break;

    case MODE_BLE:
      setupBLE();
      stayAwakeUntil = millis() +
          (userPresent ? USER_WAKE_WINDOW_MS : cfg.bleWindowMs);
      break;

    case MODE_WIFI: {
      stayAwakeUntil = millis() + cfg.wifiWindowMs;
      if (connectWiFi(20000)) {
        setupHTTP();
        reportTelemetry();
      } else if (wifiFailStreak >= 3) {
        // The network moved or the password changed: open a BLE window every
        // wake so the app can re-provision without a USB cable.
        setupBLE();
        extendWake(cfg.bleWindowMs);
      }
      // Somebody just pressed reset on a cloud board — they want the phone,
      // not the cloud. Bring BLE up for this wake even though Wi-Fi mode
      // normally keeps the radio off.
      if (cfg.bleInWifi || userPresent) {
        setupBLE();
        if (userPresent) extendWake(USER_WAKE_WINDOW_MS);
      }
      break;
    }
  }
  pushStatus("ready");
}

unsigned long lastSample = 0;
unsigned long lastAdvRefresh = 0;

void loop() {
  serviceSerial();

  if (runMode == MODE_WIFI && wifiOnline) server.handleClient();

  if (provPending) {
    provPending = false;
    finishProvisioning();
  }

  serviceIdentify();

  if (millis() - lastSample >= (unsigned long)cfg.sampleMs) {
    lastSample = millis();
    sampleBattery();

    if (bleConnected && !otaActive) {
      uint16_t r16 = (uint16_t)lastRaw;
      chRaw->setValue((uint8_t*)&r16, 2); chRaw->notify();
      chVolt->setValue((uint8_t*)&lastVolts, 4); chVolt->notify();
    }
  }

  // The advertised battery level only needs to be roughly current.
  if (bleActive && !bleConnected && millis() - lastAdvRefresh >= 10000) {
    lastAdvRefresh = millis();
    refreshAdvertisementData();
  }

  maybeSleep();
  delay(10);
}
