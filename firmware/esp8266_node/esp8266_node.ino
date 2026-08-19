// BatteryHolder reference firmware for ESP8266 (Wi-Fi only).
//
// The ESP8266 has no Bluetooth, so it cannot be provisioned over BLE like the
// ESP32 node. It reaches the same end state through a SoftAP portal instead:
//
//   PAIRING  unprovisioned / button-forced. The board hosts an open AP named
//            BH-XXXX; the app joins it and POSTs the same provisioning JSON the
//            ESP32 takes over its BLE provisioning characteristic.
//   WIFI     joins the stored network on every wake, POSTs telemetry to the
//            backend, applies the commands it gets back, then deep sleeps for
//            cfg.reportSec.
//
// Deep sleep needs GPIO16 (D0) wired to RST, otherwise the board never wakes.
// Set SLEEP_WIRED to 0 if that link is absent and the board should stay awake.
//
// Libraries: ArduinoJson (v6). WebServer / mDNS / Update / HTTPClient ship with
// the ESP8266 core.

#include <ESP8266WiFi.h>
#include <WiFiClientSecure.h>
#include <ESP8266HTTPClient.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <ESP8266httpUpdate.h>
#include <ArduinoJson.h>
#include <EEPROM.h>

static const char* FW_VERSION = "2.0.0";
static const char* HOSTNAME   = "batteryholder";

// D0 (GPIO16) tied to RST? Deep sleep only works if it is.
#ifndef SLEEP_WIRED
#define SLEEP_WIRED 1
#endif
// Hold this pin LOW at boot to force the pairing AP back up. -1 disables it.
#ifndef PAIR_BUTTON_PIN
#define PAIR_BUTTON_PIN 0   // D3 / GPIO0 (FLASH button on most dev boards)
#endif

// Status LED for IDENTIFY. The ESP8266's on-board LED sinks through the pin,
// so it is active low unless a discrete one is wired the other way round.
#ifndef STATUS_LED_PIN
#if defined(LED_BUILTIN)
#define STATUS_LED_PIN LED_BUILTIN
#else
#define STATUS_LED_PIN -1
#endif
#endif
#ifndef STATUS_LED_ACTIVE_LOW
#define STATUS_LED_ACTIVE_LOW 1
#endif

enum Mode : uint8_t { MODE_PAIRING = 0, MODE_BLE = 1 /* unused here */, MODE_WIFI = 2 };

// ---- Persisted configuration (EEPROM blob) ----
struct Config {
  uint32_t magic = 0x42484C44;   // "BHLD"
  uint8_t  version = 2;

  int   adcResBits    = 10;      // ESP8266 ADC is 10-bit
  float adcRefVoltage = 3.3f;    // NodeMCU onboard divider -> ~3.3V full scale
  float r1KOhm        = 100.0f;
  float r2KOhm        = 100.0f;
  float calibration   = 1.0f;
  int   sampleMs      = 1000;
  int   cellCount     = 1;
  float cellMinV      = 3.3f;
  float cellMaxV      = 4.2f;

  uint8_t  mode         = MODE_PAIRING;
  bool     sleepEnabled = true;
  uint32_t reportSec    = 900;    // deep sleep between cloud reports
  uint32_t awakeWindowMs = 15000; // stay awake after a report (local OTA)

  char ssid[33]       = {0};
  char pass[65]       = {0};
  char backendUrl[97] = {0};
  char token[97]      = {0};
} cfg;

static const uint32_t PAIRING_WINDOW_MS = 300000;   // 5 min AP window

ESP8266WebServer server(80);

uint8_t  runMode = MODE_PAIRING;
uint32_t stayAwakeUntil = 0;
bool     sleepBlocked = false;
bool     sleepRequested = false;
bool     otaActive = false;
bool     wifiOnline = false;
int      lastRaw = 0;
float    lastVolts = 0.0f;

// IDENTIFY blink, driven from loop() so the HTTP handler can answer at once.
static const int kStatusLedPin = STATUS_LED_PIN;
static const uint32_t BLINK_MS = 150;
uint8_t  blinkEdgesLeft = 0;
uint32_t blinkNextAt = 0;
bool     blinkOn = false;

// ---------------------------------------------------------------- helpers ---

String deviceId() {
  char buf[20];
  snprintf(buf, sizeof(buf), "bh-%08x", ESP.getChipId());
  return String(buf);
}

String shortName() {
  String id = deviceId();
  return "BH-" + id.substring(id.length() - 4);
}

float dividerRatio() { return (cfg.r1KOhm + cfg.r2KOhm) / cfg.r2KOhm; }
int   adcMaxCount()  { return (1 << cfg.adcResBits) - 1; }
int   readRaw()      { return analogRead(A0); }

float rawToVolts(int raw) {
  float pinV = (float)raw / adcMaxCount() * cfg.adcRefVoltage;
  return pinV * dividerRatio() * cfg.calibration;
}

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

bool provisioned()  { return cfg.mode == MODE_WIFI; }
bool hasWifiCreds() { return cfg.ssid[0] != 0; }
bool hasCloud()     { return cfg.backendUrl[0] != 0 && cfg.token[0] != 0; }

bool hasStatusLed() { return kStatusLedPin >= 0; }

void ledWrite(bool on) {
  if (!hasStatusLed()) return;
  bool level = STATUS_LED_ACTIVE_LOW ? !on : on;
  digitalWrite(kStatusLedPin, level ? HIGH : LOW);
}

void extendWake(uint32_t ms) {
  uint32_t deadline = millis() + ms;
  if ((int32_t)(deadline - stayAwakeUntil) > 0) stayAwakeUntil = deadline;
}

void startIdentify(uint8_t pulses = 6) {
  if (!hasStatusLed()) return;
  pinMode(kStatusLedPin, OUTPUT);
  blinkEdgesLeft = pulses * 2;
  blinkNextAt = millis();
  blinkOn = false;
  extendWake(pulses * 2 * BLINK_MS + 2000);
}

void serviceIdentify() {
  if (blinkEdgesLeft == 0) return;
  if ((int32_t)(millis() - blinkNextAt) < 0) return;
  blinkOn = !blinkOn;
  ledWrite(blinkOn);
  blinkNextAt = millis() + BLINK_MS;
  if (--blinkEdgesLeft == 0) ledWrite(false);
}

// ----------------------------------------------------------------- config ---

void loadConfig() {
  EEPROM.begin(sizeof(Config) + 8);
  Config stored;
  EEPROM.get(0, stored);
  if (stored.magic == 0x42484C44 && stored.version == cfg.version) cfg = stored;
  EEPROM.end();
}

void saveConfig() {
  EEPROM.begin(sizeof(Config) + 8);
  EEPROM.put(0, cfg);
  EEPROM.commit();
  EEPROM.end();
}

void factoryReset() {
  Config fresh;
  cfg = fresh;
  saveConfig();
}

void applyChemistry(const String& name) {
  if      (name == "liion") { cfg.cellMinV = 3.00f; cfg.cellMaxV = 4.20f; }
  else if (name == "nimh")  { cfg.cellMinV = 1.00f; cfg.cellMaxV = 1.45f; }
  else if (name == "lead")  { cfg.cellMinV = 1.75f; cfg.cellMaxV = 2.10f; }
  else if (name == "lipo")  { cfg.cellMinV = 3.30f; cfg.cellMaxV = 4.20f; }
}

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
  saveConfig();
  return true;
}

String configJson() {
  StaticJsonDocument<512> doc;
  doc["batteryPinId"]      = "a0";
  doc["adcResolutionBits"] = cfg.adcResBits;
  doc["adcRefVoltage"]     = cfg.adcRefVoltage;
  doc["dividerR1KOhm"]     = cfg.r1KOhm;
  doc["dividerR2KOhm"]     = cfg.r2KOhm;
  doc["calibrationFactor"] = cfg.calibration;
  doc["sampleIntervalMs"]  = cfg.sampleMs;
  doc["cellCount"]         = cfg.cellCount;
  String out; serializeJson(doc, out); return out;
}

bool applyPowerJson(JsonObjectConst o) {
  if (o.isNull()) return false;
  if (o.containsKey("sleepEnabled"))  cfg.sleepEnabled = o["sleepEnabled"];
  if (o.containsKey("wifiReportSec")) cfg.reportSec    = o["wifiReportSec"];
  if (o.containsKey("wifiWindowMs"))  cfg.awakeWindowMs = o["wifiWindowMs"];
  saveConfig();
  return true;
}

// Same shape as the ESP32's BLE status characteristic, so the app can reuse
// one parser for both transports.
String statusJson(const char* event = nullptr, const char* detail = nullptr) {
  StaticJsonDocument<384> doc;
  if (event)  doc["ev"] = event;
  if (detail) doc["detail"] = detail;
  doc["id"]    = deviceId();
  doc["fw"]    = FW_VERSION;
  doc["mode"]  = runMode == MODE_WIFI ? "wifi" : "pairing";
  doc["prov"]  = provisioned();
  doc["raw"]   = lastRaw;
  doc["volts"] = lastVolts;
  doc["soc"]   = (int)(stateOfCharge(lastVolts) * 100);
  doc["wifi"]  = wifiOnline ? "online" : (hasWifiCreds() ? "offline" : "none");
  if (wifiOnline) {
    doc["ip"]   = WiFi.localIP().toString();
    doc["rssi"] = WiFi.RSSI();
  }
  if (hasWifiCreds()) doc["ssid"] = cfg.ssid;
  doc["cloud"] = hasCloud();
  doc["led"]   = hasStatusLed();
  int32_t left = (int32_t)(stayAwakeUntil - millis());
  doc["sleepInMs"]   = (!cfg.sleepEnabled || sleepBlocked) ? -1 : (left < 0 ? 0 : left);
  doc["nextWakeSec"] = cfg.reportSec;
  String out; serializeJson(doc, out); return out;
}

// ---------------------------------------------------------------- Wi-Fi -----

bool connectWiFi(uint32_t timeoutMs) {
  if (!hasWifiCreds()) return false;
  if (WiFi.status() == WL_CONNECTED) { wifiOnline = true; return true; }

  WiFi.mode(WIFI_STA);
  WiFi.hostname(HOSTNAME);
  WiFi.begin(cfg.ssid, cfg.pass);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < timeoutMs) delay(100);
  wifiOnline = WiFi.status() == WL_CONNECTED;
  if (wifiOnline && MDNS.begin(HOSTNAME)) MDNS.addService("batteryholder", "tcp", 80);
  return wifiOnline;
}

static WiFiClient plainClient;
static WiFiClientSecure tlsClient;

bool beginHttp(HTTPClient& http, const String& url) {
  if (url.startsWith("https://")) {
    tlsClient.setInsecure();   // pin the backend root CA in production
    return http.begin(tlsClient, url);
  }
  return http.begin(plainClient, url);
}

void pullOTA(const String& url) {
  otaActive = true;
  if (url.startsWith("https://")) {
    tlsClient.setInsecure();
    ESPhttpUpdate.update(tlsClient, url);
  } else {
    ESPhttpUpdate.update(plainClient, url);
  }
  otaActive = false;   // only reached when the update failed; success reboots
}

bool applyCommand(JsonObjectConst cmd) {
  String type = cmd["type"] | "";
  if (type == "setConfig") {
    String body; serializeJson(cmd["config"], body);
    applyConfigJson(body);
  } else if (type == "setPower") {
    applyPowerJson(cmd["power"].as<JsonObjectConst>());
  } else if (type == "setMode") {
    String m = cmd["mode"] | "";
    if (m == "pairing") { cfg.mode = MODE_PAIRING; saveConfig(); }
  } else if (type == "identify") {
    startIdentify();
    return true;
  } else if (type == "stayAwake") {
    extendWake(min((uint32_t)(cmd["seconds"] | 60), (uint32_t)3600) * 1000UL);
    return true;
  } else if (type == "ota") {
    String url = cmd["url"] | "";
    if (url.length()) { pullOTA(url); return true; }
  }
  return false;
}

bool reportTelemetry() {
  if (!hasCloud() || !wifiOnline) return false;

  String url = String(cfg.backendUrl);
  if (!url.endsWith("/")) url += "/";
  url += "devices/" + deviceId() + "/telemetry";

  StaticJsonDocument<448> doc;
  doc["deviceId"]  = deviceId();
  doc["fw"]        = FW_VERSION;
  doc["raw"]       = lastRaw;
  doc["volts"]     = lastVolts;
  doc["soc"]       = stateOfCharge(lastVolts);
  doc["pin"]       = "a0";
  doc["rssi"]      = WiFi.RSSI();
  doc["ip"]        = WiFi.localIP().toString();
  doc["uptimeMs"]  = millis();
  doc["reportSec"] = cfg.reportSec;
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
  if (err) return true;

  if (res.containsKey("nextReportSec")) {
    uint32_t next = res["nextReportSec"];
    if (next >= 10 && next != cfg.reportSec) { cfg.reportSec = next; saveConfig(); }
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

// ------------------------------------------------------------------ HTTP ----

void startPairingAP();

void handleVoltage() {
  sampleBattery();
  StaticJsonDocument<192> doc;
  doc["raw"]   = lastRaw;
  doc["volts"] = lastVolts;
  doc["soc"]   = stateOfCharge(lastVolts);
  doc["pin"]   = "a0";
  String out; serializeJson(doc, out);
  server.send(200, "application/json", out);
}

// The SoftAP twin of the ESP32's BLE provisioning characteristic. Same JSON.
void handleProvision() {
  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, server.arg("plain"))) {
    server.send(400, "application/json", "{\"ok\":false,\"error\":\"bad json\"}");
    return;
  }
  sleepBlocked = true;

  if (doc.containsKey("ssid"))        strlcpy(cfg.ssid, doc["ssid"] | "", sizeof(cfg.ssid));
  if (doc.containsKey("password"))    strlcpy(cfg.pass, doc["password"] | "", sizeof(cfg.pass));
  if (doc.containsKey("backendUrl"))  strlcpy(cfg.backendUrl, doc["backendUrl"] | "", sizeof(cfg.backendUrl));
  if (doc.containsKey("deviceToken")) strlcpy(cfg.token, doc["deviceToken"] | "", sizeof(cfg.token));
  if (doc.containsKey("reportIntervalSec")) cfg.reportSec = doc["reportIntervalSec"];
  if (doc.containsKey("power")) applyPowerJson(doc["power"].as<JsonObjectConst>());
  saveConfig();

  // Answer before switching networks — the client is on our AP right now and
  // loses the socket the moment the radio flips to station mode.
  StaticJsonDocument<256> res;
  res["ok"] = true;
  res["deviceId"] = deviceId();
  res["next"] = "connecting";
  String out; serializeJson(res, out);
  server.send(200, "application/json", out);
  delay(200);

  WiFi.softAPdisconnect(true);
  if (connectWiFi(20000)) {
    cfg.mode = MODE_WIFI;
    runMode = MODE_WIFI;
    saveConfig();
    reportTelemetry();
    extendWake(cfg.awakeWindowMs);
  } else {
    // Bad credentials: come back up as an AP so the app can try again.
    startPairingAP();
  }
  sleepBlocked = false;
}

void handleSession() {
  StaticJsonDocument<192> doc;
  deserializeJson(doc, server.arg("plain"));
  String cmd = doc["cmd"] | "";
  if (cmd == "stayAwake") {
    uint32_t sec = doc["seconds"] | 0;
    if (sec == 0) sleepBlocked = true;
    else { sleepBlocked = false; extendWake(min(sec, (uint32_t)3600) * 1000UL); }
  } else if (cmd == "sleepNow") {
    uint32_t sec = doc["seconds"] | 0;
    if (sec >= 10) { cfg.reportSec = sec; saveConfig(); }
    sleepBlocked = false;
    sleepRequested = true;
  } else if (cmd == "factoryReset") {
    server.send(200, "application/json", "{\"ok\":true}");
    delay(100);
    factoryReset();
    ESP.restart();
    return;
  } else if (cmd == "identify") {
    startIdentify();
  } else if (cmd == "forgetWifi") {
    cfg.ssid[0] = 0; cfg.pass[0] = 0; cfg.mode = MODE_PAIRING;
    saveConfig();
  }
  server.send(200, "application/json", statusJson());
}

void setupHTTP() {
  server.on("/api/voltage", HTTP_GET, handleVoltage);
  server.on("/api/status", HTTP_GET, [] { server.send(200, "application/json", statusJson()); });
  server.on("/api/config", HTTP_GET, [] { server.send(200, "application/json", configJson()); });
  server.on("/api/config", HTTP_POST, [] {
    bool ok = applyConfigJson(server.arg("plain"));
    server.send(ok ? 200 : 400, "application/json", ok ? "{\"ok\":true}" : "{\"ok\":false}");
  });
  server.on("/api/provision", HTTP_POST, handleProvision);
  server.on("/api/session", HTTP_POST, handleSession);
  server.on("/update", HTTP_POST,
    [] { server.send(Update.hasError() ? 500 : 200, "text/plain", Update.hasError() ? "FAIL" : "OK"); delay(200); ESP.restart(); },
    [] {
      HTTPUpload& up = server.upload();
      if (up.status == UPLOAD_FILE_START) {
        otaActive = true;
        uint32_t maxSpace = (ESP.getFreeSketchSpace() - 0x1000) & 0xFFFFF000;
        Update.begin(maxSpace);
      } else if (up.status == UPLOAD_FILE_WRITE) {
        Update.write(up.buf, up.currentSize);
      } else if (up.status == UPLOAD_FILE_END) {
        Update.end(true);
        otaActive = false;
      }
    });
  server.begin();
}

void startPairingAP() {
  runMode = MODE_PAIRING;
  WiFi.mode(WIFI_AP);
  WiFi.softAP(shortName().c_str());          // open AP, claim window only
  wifiOnline = false;
  stayAwakeUntil = millis() + PAIRING_WINDOW_MS;
}

// ------------------------------------------------------------- deep sleep ---

bool pairButtonPressed() {
#if PAIR_BUTTON_PIN >= 0
  pinMode(PAIR_BUTTON_PIN, INPUT_PULLUP);
  return digitalRead(PAIR_BUTTON_PIN) == LOW;
#else
  return false;
#endif
}

void goToSleep(uint32_t seconds) {
#if SLEEP_WIRED
  if (seconds < 1) seconds = 1;
  Serial.printf("[sleep] %u s\n", seconds);
  Serial.flush();
  server.stop();
  WiFi.disconnect(true);
  ESP.deepSleep((uint64_t)seconds * 1000000ULL);
  delay(100);            // deepSleep returns immediately; wait for the reset
#else
  // No D0-RST link: emulate the duty cycle by idling instead of sleeping.
  extendWake(seconds * 1000UL);
#endif
}

void maybeSleep() {
  if (sleepRequested) { goToSleep(cfg.reportSec); return; }
  if (!cfg.sleepEnabled || sleepBlocked) return;
  if (otaActive) { extendWake(30000); return; }
  if (blinkEdgesLeft > 0) return;   // finish identifying first
  // An unclaimed board keeps its AP up: nobody can provision a radio that is
  // off, and it is only ever unclaimed while a user is standing over it.
  if (runMode == MODE_PAIRING) return;
  if ((int32_t)(millis() - stayAwakeUntil) >= 0) goToSleep(cfg.reportSec);
}

// ------------------------------------------------------------------ setup ---

void setup() {
  Serial.begin(115200);
  loadConfig();
  sampleBattery();

  bool forcePairing = pairButtonPressed();
  Serial.printf("[boot] %s fw=%s mode=%u\n", deviceId().c_str(), FW_VERSION, cfg.mode);

  if (!provisioned() || forcePairing) {
    startPairingAP();
  } else {
    runMode = MODE_WIFI;
    stayAwakeUntil = millis() + cfg.awakeWindowMs;
    if (connectWiFi(20000)) {
      reportTelemetry();
    } else {
      // Credentials no longer work — fall back to the pairing AP so the app can
      // re-provision without a USB cable.
      startPairingAP();
    }
  }
  setupHTTP();
}

unsigned long lastSample = 0;

void loop() {
  server.handleClient();
  if (wifiOnline) MDNS.update();
  serviceIdentify();

  if (millis() - lastSample >= (unsigned long)cfg.sampleMs) {
    lastSample = millis();
    sampleBattery();
  }

  maybeSleep();
  delay(5);
}
