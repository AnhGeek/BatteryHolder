// BatteryHolder reference firmware for ESP32.
// Implements the BLE GATT contract AND the Wi-Fi HTTP API the iOS app expects.
//
// Libraries: ArduinoJson (v6). BLE/WebServer/mDNS/Update ship with the ESP32 core.

#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Update.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---- Wi-Fi ----
static const char* WIFI_SSID = "your-ssid";
static const char* WIFI_PASS = "your-password";
static const char* HOSTNAME  = "batteryholder";

// ---- GATT UUIDs (must match the app) ----
#define SVC_UUID  "A1B2C3D4-0001-4A5B-8C6D-000000000000"
#define CH_VOLT   "A1B2C3D4-0002-4A5B-8C6D-000000000000"
#define CH_RAW    "A1B2C3D4-0003-4A5B-8C6D-000000000000"
#define CH_CFG    "A1B2C3D4-0004-4A5B-8C6D-000000000000"
#define CH_OTACTL "A1B2C3D4-0005-4A5B-8C6D-000000000000"
#define CH_OTADAT "A1B2C3D4-0006-4A5B-8C6D-000000000000"

// ---- Configurable pin/divider (persisted) ----
struct Config {
  int   adcPin        = 34;     // GPIO number
  int   adcResBits    = 12;
  float adcRefVoltage = 3.3f;
  float r1KOhm        = 100.0f;
  float r2KOhm        = 100.0f;
  float calibration   = 1.0f;
  int   sampleMs      = 1000;
} cfg;

Preferences prefs;
WebServer server(80);

BLECharacteristic *chVolt, *chRaw, *chCtl;
bool bleConnected = false;

// OTA-over-BLE state
bool otaActive = false;
uint32_t otaExpected = 0, otaReceived = 0;

// ---- Helpers ----
float dividerRatio() { return (cfg.r1KOhm + cfg.r2KOhm) / cfg.r2KOhm; }
int   adcMaxCount()  { return (1 << cfg.adcResBits) - 1; }

int readRaw() { return analogRead(cfg.adcPin); }

float rawToVolts(int raw) {
  float pinV = (float)raw / adcMaxCount() * cfg.adcRefVoltage;
  return pinV * dividerRatio() * cfg.calibration;
}

void loadConfig() {
  prefs.begin("bh", true);
  cfg.adcPin        = prefs.getInt("pin", cfg.adcPin);
  cfg.adcResBits    = prefs.getInt("res", cfg.adcResBits);
  cfg.adcRefVoltage = prefs.getFloat("ref", cfg.adcRefVoltage);
  cfg.r1KOhm        = prefs.getFloat("r1", cfg.r1KOhm);
  cfg.r2KOhm        = prefs.getFloat("r2", cfg.r2KOhm);
  cfg.calibration   = prefs.getFloat("cal", cfg.calibration);
  cfg.sampleMs      = prefs.getInt("ms", cfg.sampleMs);
  prefs.end();
  analogReadResolution(cfg.adcResBits);
}

void saveConfig() {
  prefs.begin("bh", false);
  prefs.putInt("pin", cfg.adcPin);
  prefs.putInt("res", cfg.adcResBits);
  prefs.putFloat("ref", cfg.adcRefVoltage);
  prefs.putFloat("r1", cfg.r1KOhm);
  prefs.putFloat("r2", cfg.r2KOhm);
  prefs.putFloat("cal", cfg.calibration);
  prefs.putInt("ms", cfg.sampleMs);
  prefs.end();
  analogReadResolution(cfg.adcResBits);
}

// Apply a JSON PinConfiguration payload (from BLE or HTTP).
bool applyConfigJson(const String& body) {
  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, body)) return false;
  if (doc.containsKey("adcResolutionBits")) cfg.adcResBits    = doc["adcResolutionBits"];
  if (doc.containsKey("adcRefVoltage"))     cfg.adcRefVoltage = doc["adcRefVoltage"];
  if (doc.containsKey("dividerR1KOhm"))     cfg.r1KOhm        = doc["dividerR1KOhm"];
  if (doc.containsKey("dividerR2KOhm"))     cfg.r2KOhm        = doc["dividerR2KOhm"];
  if (doc.containsKey("calibrationFactor")) cfg.calibration   = doc["calibrationFactor"];
  if (doc.containsKey("sampleIntervalMs"))  cfg.sampleMs      = doc["sampleIntervalMs"];
  // batteryPinId like "gpio34" -> pin number.
  if (doc.containsKey("batteryPinId")) {
    String pid = doc["batteryPinId"].as<String>();
    if (pid.startsWith("gpio")) cfg.adcPin = pid.substring(4).toInt();
  }
  saveConfig();
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
  String out; serializeJson(doc, out); return out;
}

// ---- BLE callbacks ----
class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { bleConnected = true; }
  void onDisconnect(BLEServer* s) override { bleConnected = false; s->startAdvertising(); }
};

void notifyCtl(uint8_t status, const char* msg = nullptr) {
  uint8_t buf[24]; buf[0] = status; size_t n = 1;
  if (msg) { size_t m = strlen(msg); if (m > 22) m = 22; memcpy(buf + 1, msg, m); n += m; }
  chCtl->setValue(buf, n); chCtl->notify();
}

class CfgCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    applyConfigJson(String(c->getValue().c_str()));
  }
  void onRead(BLECharacteristic* c) override { c->setValue(configJson().c_str()); }
};

class OtaCtlCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    uint8_t cmd = (uint8_t)v[0];
    if (cmd == 0x01 && v.size() >= 5) {                 // START | size(LE)
      otaExpected = (uint32_t)(uint8_t)v[1] | ((uint32_t)(uint8_t)v[2] << 8) |
                    ((uint32_t)(uint8_t)v[3] << 16) | ((uint32_t)(uint8_t)v[4] << 24);
      otaReceived = 0;
      otaActive = Update.begin(otaExpected);
      notifyCtl(otaActive ? 0x00 : 0x1F, otaActive ? nullptr : "begin failed");
    } else if (cmd == 0x02) {                            // END | crc32 (crc checked by app)
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
    std::string v = c->getValue();
    size_t w = Update.write((uint8_t*)v.data(), v.size());
    otaReceived += w;
  }
};

void setupBLE() {
  BLEDevice::init("BatteryHolder-ESP32");
  BLEServer* srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerCB());
  BLEService* svc = srv->createService(SVC_UUID);

  chVolt = svc->createCharacteristic(CH_VOLT, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chVolt->addDescriptor(new BLE2902());
  chRaw = svc->createCharacteristic(CH_RAW, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chRaw->addDescriptor(new BLE2902());

  BLECharacteristic* chCfg = svc->createCharacteristic(CH_CFG, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  chCfg->setCallbacks(new CfgCB());

  chCtl = svc->createCharacteristic(CH_OTACTL, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  chCtl->addDescriptor(new BLE2902());
  chCtl->setCallbacks(new OtaCtlCB());

  BLECharacteristic* chDat = svc->createCharacteristic(CH_OTADAT, BLECharacteristic::PROPERTY_WRITE_NR);
  chDat->setCallbacks(new OtaDatCB());

  svc->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SVC_UUID);
  adv->start();
}

// ---- Wi-Fi HTTP API ----
void handleVoltage() {
  int raw = readRaw();
  StaticJsonDocument<128> doc;
  doc["raw"]   = raw;
  doc["volts"] = rawToVolts(raw);
  doc["pin"]   = String("gpio") + cfg.adcPin;
  String out; serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void setupHTTP() {
  server.on("/api/voltage", HTTP_GET, handleVoltage);
  server.on("/api/config", HTTP_GET, [] { server.send(200, "application/json", configJson()); });
  server.on("/api/config", HTTP_POST, [] {
    bool ok = applyConfigJson(server.arg("plain"));
    server.send(ok ? 200 : 400, "application/json", ok ? "{\"ok\":true}" : "{\"ok\":false}");
  });
  // Multipart OTA upload.
  server.on("/update", HTTP_POST,
    [] { server.send(Update.hasError() ? 500 : 200, "text/plain", Update.hasError() ? "FAIL" : "OK"); delay(200); ESP.restart(); },
    [] {
      HTTPUpload& up = server.upload();
      if (up.status == UPLOAD_FILE_START)      Update.begin(UPDATE_SIZE_UNKNOWN);
      else if (up.status == UPLOAD_FILE_WRITE) Update.write(up.buf, up.currentSize);
      else if (up.status == UPLOAD_FILE_END)   Update.end(true);
    });
  server.begin();
}

void setup() {
  Serial.begin(115200);
  loadConfig();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) delay(250);
  if (MDNS.begin(HOSTNAME)) MDNS.addService("batteryholder", "tcp", 80);

  setupHTTP();
  setupBLE();
}

unsigned long lastSample = 0;
void loop() {
  server.handleClient();

  if (millis() - lastSample >= (unsigned long)cfg.sampleMs) {
    lastSample = millis();
    int raw = readRaw();
    float volts = rawToVolts(raw);
    if (bleConnected && !otaActive) {
      uint16_t r16 = (uint16_t)raw;
      chRaw->setValue((uint8_t*)&r16, 2); chRaw->notify();
      chVolt->setValue((uint8_t*)&volts, 4); chVolt->notify();
    }
  }
}
