# Reference Firmware

Firmware that implements the BatteryHolder device contract so the apps have a
real board to talk to. Flash it once over USB; after that the app — or the
backend — can update it over the air.

Current version: **2.0.0**. The full contract lives in
[../docs/DEVICE_PROTOCOL.md](../docs/DEVICE_PROTOCOL.md).

## Sketches

| Folder | Board | Transports | Provisioned via |
|---|---|---|---|
| `battery_holder_node/` | ESP32 (WROOM / C3 / S3) | Bluetooth LE **and** Wi-Fi | BLE |
| `esp8266_node/` | ESP8266 (NodeMCU / D1 mini) | Wi-Fi only | SoftAP portal |

## How it behaves

A board is asleep most of its life. It runs in one of three modes:

- **pairing** — factory-fresh or pairing-button forced. Advertises (ESP32) or
  hosts an open `BH-XXXX` AP (ESP8266) so the app can claim it. Does not sleep
  during the pairing window.
- **ble** — wake → sample → advertise ~20 s → serve the app if it connects →
  deep sleep for `bleWakeSec` (default 5 min).
- **wifi** — wake → join the provisioned network → POST telemetry to the
  backend → apply any commands it gets back → deep sleep for `wifiReportSec`
  (default 15 min).

You never type Wi-Fi credentials into the sketch. The app sends them once over
Bluetooth (ESP32) or the pairing AP (ESP8266), together with the backend URL and
a device token minted by `POST /devices/claim`. The board verifies the
credentials before committing to Wi-Fi mode, so a wrong password leaves it
reachable.

## Libraries

Install via the Arduino Library Manager:

- **ArduinoJson** (v6 API; v7 works, it still provides the v6 names)
- **ESP32 core 3.x** (Espressif) for the ESP32 sketch — the BLE callbacks use
  the core 3 `String` value API and will not compile on core 2.x
- ESP8266 core for the ESP8266 sketch

BLE, WebServer, mDNS, HTTPClient and Update come with the ESP cores.

## Partition scheme

BLE + Wi-Fi + WebServer + mDNS + Update in one image is ~1.5 MB, which does not
fit the Arduino default (1.2 MB app). Pick **Minimal SPIFFS (1.9MB APP with
OTA/128KB SPIFFS)** — the "No OTA" and "Huge APP" schemes are the wrong trade
here because the firmware's own OTA needs two app slots.

```bash
arduino-cli compile   --fqbn "esp32:esp32:esp32c3:PartitionScheme=min_spiffs"   firmware/battery_holder_node
```

## Board-specific pins

The sketch picks defaults per chip; override any of them with a `-D` build flag.

| Macro | Classic ESP32 | C3 / S3 | Why |
|---|---|---|---|
| `DEFAULT_ADC_PIN` | 34 | 4 | GPIO34 does not exist on C3/S3. Matches `recommendedBatteryPinId` in `boards.json`. |
| `WAKE_BUTTON_PIN` | 0 | *disabled* | C3/S3 pads keep no internal pull-up across deep sleep, so an unwired GPIO floats and wakes the board every cycle. Wire a button **and a 10k pull-up** to an RTC GPIO (0–5), then pass `-DWAKE_BUTTON_PIN=<n>`. |
| `STATUS_LED_PIN` | 2 | `RGB_BUILTIN` | Taken from the board variant where there is one: core 3.x drives the C3/S3 DevKitM addressable LED through `digitalWrite(RGB_BUILTIN, …)`, so IDENTIFY works there out of the box. The "ESP32 Dev Module" variant declares no LED macro, so the classic build assumes the DevKitC's GPIO2 — pass `-DSTATUS_LED_PIN=-1` on a bare module, or `-DSTATUS_LED_PIN=<n>` (plus `-DSTATUS_LED_ACTIVE_LOW=1` if it sinks) for a discrete one. A board with no LED reports `led: false` and the app says so instead of pretending to blink. |

With the button disabled, timer wake still works and a factory-fresh board still
comes up in pairing mode — you just cannot force pairing on a board that is
already provisioned without a factory reset from the app.

## Waking a sleeping board

A board in `ble` mode advertises for ~20 s every 5 minutes, and a `wifi` board
is on air for a few seconds every 15. Waiting that out to change a setting is
not the intended workflow — **tap RESET**. The firmware can tell a reset or
power-on (`ESP_SLEEP_WAKEUP_UNDEFINED`) from a timer wake, treats it as the
user asking for attention, and stays reachable for two minutes: BLE up, and in
Wi-Fi mode BLE comes up as well for that window only.

That is the escape hatch that needs no wiring. The pairing button does the same
thing *and* forces pairing mode, which is what you want when the board's Wi-Fi
network is gone for good.

## Wiring (voltage divider)

```
  battery + ----[ R1 ]----+----[ R2 ]---- GND
                          |
                        ADC pin (e.g. GPIO34 on ESP32, A0 on ESP8266)
```

With R1 = R2 = 100 kΩ the divider halves the voltage, so a 1S LiPo (max 4.2 V)
reaches ~2.1 V at the pin — safely under the 3.3 V ADC limit. Enter your real R1
and R2 in the app's Pin configuration screen.

## Wiring (power features)

| Feature | ESP32 | ESP8266 |
|---|---|---|
| Pairing button | `WAKE_BUTTON_PIN` (GPIO0), to GND, active low | `PAIR_BUTTON_PIN` (GPIO0) |
| Status LED | `STATUS_LED_PIN` (GPIO2) | — |
| Deep-sleep wake | internal RTC timer | **GPIO16 (D0) must be wired to RST** |

The button must be an RTC-capable GPIO (ESP32: 0, 2, 4, 12–15, 25–27, 32–39;
C3/S3: 0–5) — it wakes the board out of deep sleep *and* forces pairing mode, so
a board whose Wi-Fi network disappeared is always recoverable. Set the define to
`-1` to build without a button.

On the ESP8266, deep sleep is a reset: without the D0–RST link the board never
wakes. Build with `-DSLEEP_WIRED=0` to keep it permanently awake instead.

## Power budget, roughly

| Mode | Duty cycle | Rough average |
|---|---|---|
| `ble`, 5 min interval | ~20 s advertising per wake | ~2 mA |
| `wifi`, 15 min interval | ~5 s radio per wake | ~1 mA |
| Always awake (v1 behaviour) | 100 % | 80–150 mA |

Deep sleep itself is ~10 µA (ESP32) / ~20 µA (ESP8266) plus whatever your
divider draws — 100 kΩ + 100 kΩ across a 4.2 V pack is another ~21 µA, so use
larger resistors or gate the divider with a MOSFET if you are chasing months.

## Contract summary

See [../docs/DEVICE_PROTOCOL.md](../docs/DEVICE_PROTOCOL.md) for the full GATT,
HTTP and cloud contract, and [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
for how the app is layered on top of it. The UUIDs and endpoints in these
sketches match the apps exactly.
