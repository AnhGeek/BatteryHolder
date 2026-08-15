# Reference Firmware

Minimal firmware that implements the BatteryHolder device contract so the iOS
app has a real board to talk to. Flash it once over USB; after that the app can
update it over the air.

## Sketches

| Folder | Board | Transports |
|---|---|---|
| `battery_holder_node/` | ESP32 (WROOM / C3) | Bluetooth LE **and** Wi-Fi |
| `esp8266_node/` | ESP8266 (NodeMCU / D1 mini) | Wi-Fi only |

## Libraries

Install via the Arduino Library Manager:

- **ArduinoJson** (v6)
- ESP32 core (Espressif) for the ESP32 sketch
- ESP8266 core for the ESP8266 sketch

BLE, WebServer, mDNS and Update come with the ESP cores.

## Wiring (voltage divider)

```
  battery + ----[ R1 ]----+----[ R2 ]---- GND
                          |
                        ADC pin (e.g. GPIO34 on ESP32, A0 on ESP8266)
```

With R1 = R2 = 100 kΩ the divider halves the voltage, so a 1S LiPo (max 4.2 V)
reaches ~2.1 V at the pin — safely under the 3.3 V ADC limit. Enter your real R1
and R2 in the app's Pin configuration screen.

## Configure Wi-Fi

Set `WIFI_SSID` / `WIFI_PASS` at the top of the sketch (or extend it to use
WiFiManager / SoftAP provisioning). On boot the board advertises itself as a
Bonjour service `_batteryholder._tcp`, which the app discovers automatically.

## Contract summary

See [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full GATT and HTTP
contract. The UUIDs and endpoints in these sketches match the app exactly.
