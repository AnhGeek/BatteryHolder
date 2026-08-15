// BatteryHolder reference firmware for ESP8266 (Wi-Fi only).
// ESP8266 has no Bluetooth, so the app flashes it over Wi-Fi.
//
// Libraries: ArduinoJson (v6). WebServer/mDNS/Update ship with the ESP8266 core.

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <ArduinoJson.h>
#include <EEPROM.h>

static const char* WIFI_SSID = "your-ssid";
static const char* WIFI_PASS = "your-password";
static const char* HOSTNAME  = "batteryholder";

struct Config {
  int   adcResBits    = 10;      // ESP8266 ADC is 10-bit
  float adcRefVoltage = 3.3f;    // NodeMCU onboard divider -> ~3.3V full scale
  float r1KOhm        = 100.0f;
  float r2KOhm        = 100.0f;
  float calibration   = 1.0f;
  int   sampleMs      = 1000;
} cfg;

ESP8266WebServer server(80);

float dividerRatio() { return (cfg.r1KOhm + cfg.r2KOhm) / cfg.r2KOhm; }
int   adcMaxCount()  { return (1 << cfg.adcResBits) - 1; }
int   readRaw()      { return analogRead(A0); }
float rawToVolts(int raw) {
  float pinV = (float)raw / adcMaxCount() * cfg.adcRefVoltage;
  return pinV * dividerRatio() * cfg.calibration;
}

bool applyConfigJson(const String& body) {
  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, body)) return false;
  if (doc.containsKey("adcResolutionBits")) cfg.adcResBits    = doc["adcResolutionBits"];
  if (doc.containsKey("adcRefVoltage"))     cfg.adcRefVoltage = doc["adcRefVoltage"];
  if (doc.containsKey("dividerR1KOhm"))     cfg.r1KOhm        = doc["dividerR1KOhm"];
  if (doc.containsKey("dividerR2KOhm"))     cfg.r2KOhm        = doc["dividerR2KOhm"];
  if (doc.containsKey("calibrationFactor")) cfg.calibration   = doc["calibrationFactor"];
  if (doc.containsKey("sampleIntervalMs"))  cfg.sampleMs      = doc["sampleIntervalMs"];
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
  String out; serializeJson(doc, out); return out;
}

void handleVoltage() {
  int raw = readRaw();
  StaticJsonDocument<128> doc;
  doc["raw"]   = raw;
  doc["volts"] = rawToVolts(raw);
  doc["pin"]   = "a0";
  String out; serializeJson(doc, out);
  server.send(200, "application/json", out);
}

void setup() {
  Serial.begin(115200);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) delay(250);

  if (MDNS.begin(HOSTNAME)) MDNS.addService("batteryholder", "tcp", 80);

  server.on("/api/voltage", HTTP_GET, handleVoltage);
  server.on("/api/config", HTTP_GET, [] { server.send(200, "application/json", configJson()); });
  server.on("/api/config", HTTP_POST, [] {
    bool ok = applyConfigJson(server.arg("plain"));
    server.send(ok ? 200 : 400, "application/json", ok ? "{\"ok\":true}" : "{\"ok\":false}");
  });
  server.on("/update", HTTP_POST,
    [] { server.send(Update.hasError() ? 500 : 200, "text/plain", Update.hasError() ? "FAIL" : "OK"); delay(200); ESP.restart(); },
    [] {
      HTTPUpload& up = server.upload();
      if (up.status == UPLOAD_FILE_START) {
        uint32_t maxSpace = (ESP.getFreeSketchSpace() - 0x1000) & 0xFFFFF000;
        Update.begin(maxSpace);
      } else if (up.status == UPLOAD_FILE_WRITE) {
        Update.write(up.buf, up.currentSize);
      } else if (up.status == UPLOAD_FILE_END) {
        Update.end(true);
      }
    });
  server.begin();
}

void loop() {
  server.handleClient();
  MDNS.update();
}
