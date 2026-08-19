# Device Protocol v2 — BLE provisioning, deep sleep, cloud check-in

This is the authoritative contract between the firmware in [`firmware/`](../firmware),
the mobile apps (iOS + Flutter), and the backend in [`backend/`](../backend).
Firmware `2.0.0` implements all of it.

The shape is deliberately the same as a Tuya-style device: **Bluetooth is how
you set the device up and how you talk to it locally; Wi-Fi is how the cloud
talks to it.** The board is asleep most of the time in both modes.

## 1. Run modes

| Mode | When | Radio | Sleep behaviour |
|---|---|---|---|
| `pairing` | factory-fresh, or the pairing button was pressed | BLE advertising, continuous | Stays awake for the 3-minute pairing window |
| `ble` | the app provisioned `mode: "ble"` | BLE, windowed | Wake → sample → advertise `bleWindowMs` → **deep sleep `bleWakeSec`** |
| `wifi` | the app provisioned `mode: "wifi"` with credentials | Wi-Fi STA (BLE off) | Wake → join Wi-Fi → POST telemetry → stay up `wifiWindowMs` → **deep sleep `wifiReportSec`** |

Mode is persisted in NVS, so it survives deep sleep and power loss.

The board never sleeps while:

- an app is connected over BLE **and** subscribed to the voltage/raw
  notifications (watching the stream counts as engagement),
- an app is connected and has written something within `bleIdleMs`,
- an OTA is in flight (BLE, local HTTP, or cloud pull),
- the app has written `STAY_AWAKE(0)` on the session characteristic,
- `sleepEnabled` is `false`.

A connected app that neither subscribes nor writes is dropped after
`bleIdleMs`, so a forgotten connection cannot flatten the pack.

### Waking a board on demand

Waiting out a 5- or 15-minute sleep to change a setting is not acceptable, so
there are two ways to make a board reachable right now. Both are physical —
a sleeping radio cannot be woken over the air.

- **RESET / power-on** — works on every board, wired or not, because every dev
  board has an RST button. The firmware treats a reset wake
  (`ESP_SLEEP_WAKEUP_UNDEFINED`) as *a person is standing here* and stays
  reachable for `USER_WAKE_WINDOW_MS` (2 min) in its configured mode. A
  `wifi`-mode board also brings BLE up for that window, even though it normally
  keeps the radio off. Only the timer wake is treated as unattended.
- **Pairing button** (`WAKE_BUTTON_PIN`) — additionally forces `pairing` mode
  for that wake, so a board whose Wi-Fi network no longer exists can be
  re-provisioned. It must be wired to an RTC-capable GPIO with a pull-up;
  it is enabled by default only on the classic ESP32 (GPIO0), because the
  C3/S3 pads keep no internal pull-up across deep sleep and a floating pin
  would wake the board every cycle.

### Recovering a board
- **Wi-Fi failure streak** — after 3 consecutive failed joins, a `wifi`-mode
  board also opens a BLE window on every wake so the app can re-provision.
- **Factory reset** — session command `0x03`, or the cloud command
  `{"type":"setMode","mode":"pairing"}`.

## 2. Bluetooth LE

Service `A1B2C3D4-0001-4A5B-8C6D-000000000000`.

| Role | UUID | Properties | Payload |
|---|---|---|---|
| Battery voltage | `…-0002-…` | Read, Notify | `float32` volts, little-endian |
| Raw ADC | `…-0003-…` | Read, Notify | `uint16` raw counts |
| Pin config | `…-0004-…` | Read, Write | UTF-8 JSON `PinConfiguration` |
| OTA control | `…-0005-…` | Write, Notify | 1 byte cmd + status codes |
| OTA data | `…-0006-…` | Write w/o response | firmware chunk (≤ MTU−3) |
| **Wi-Fi provisioning** | `…-0007-…` | Read, Write | UTF-8 JSON, see §2.2 |
| **Status / events** | `…-0008-…` | Read, Notify | UTF-8 JSON, see §2.3 |
| **Session control** | `…-0009-…` | Write | 1 byte cmd + args, see §2.4 |

`0002`–`0006` are unchanged from v1, so an existing app keeps working — it just
never learns the mode or the sleep deadline.

### 2.1 Advertisement

- Advertising packet: flags + the 128-bit service UUID.
- Scan response: local name `BH-XXXX` (last 4 hex of the device id) +
  manufacturer data, company id `0xFFFF`:

| Byte | Meaning |
|---|---|
| 0 | `0x42` marker |
| 1 | protocol version (`0x01`) |
| 2 | flags: `0x01` provisioned · `0x02` wifi mode · `0x04` pairing mode · `0x08` Wi-Fi online |
| 3–4 | battery millivolts, `uint16` LE |
| 5 | state of charge, 0–100 |

The app can therefore render battery level and "needs setup" state straight
from the scan result, without connecting.

### 2.2 Provisioning characteristic (`…-0007-…`)

**Write** (UTF-8 JSON, one shot):

```json
{
  "mode": "wifi",
  "ssid": "home-2g",
  "password": "hunter2",
  "backendUrl": "https://abc123.execute-api.eu-west-1.amazonaws.com/prod",
  "deviceToken": "9f2c…",
  "reportIntervalSec": 900,
  "power": { "sleepEnabled": true, "wifiWindowMs": 15000 }
}
```

- `mode: "ble"` — no credentials needed; the board persists BLE mode and starts
  its sleep cycle. Everything else in the payload is optional.
- `mode: "wifi"` — the board saves the credentials, then **tries them
  immediately while the BLE link is still open** and streams the result as
  status events. The mode only flips to `wifi` after the join succeeds, so a
  typo can never strand the board.

**Read** returns provisioning state without secrets:

```json
{ "prov": true, "ssid": "home-2g", "cloud": true, "mode": "wifi" }
```

### 2.3 Status characteristic (`…-0008-…`)

One JSON object, readable at any time and notified on every state change:

```json
{
  "ev": "wifi", "detail": "connected",
  "id": "bh-a1b2c3d4e5f6", "fw": "2.0.0", "mode": "wifi", "prov": true,
  "raw": 2731, "volts": 3.94, "soc": 78, "boot": 42,
  "wifi": "online", "ip": "192.168.1.42", "rssi": -56,
  "ssid": "home-2g", "cloud": true, "led": true,
  "sleepInMs": 12400, "nextWakeSec": 900
}
```

- `ev` is present only on event pushes. Sequence during provisioning:
  `prov` → `wifi/connecting` → `wifi/connected` (or `wifi/failed`) →
  `cloud/registered` (or `cloud/unreachable`) → `prov/done`.
- Other events: `boot`, `ready`, `config`, `mode`, `awake`, `sleeping`,
  `reset`, `wifi/forgotten`, `identify/blinking`, `identify/no-led`.
- `sleepInMs` is the milliseconds left in this wake, or `-1` when sleeping is
  disabled/blocked. **The app should treat `sleeping` as an expected
  disconnect, not an error.**

### 2.4 Session characteristic (`…-0009-…`)

| Cmd | Args | Effect |
|---|---|---|
| `0x01` STAY_AWAKE | `uint16` seconds LE, `0` = until disconnect | Extend/suspend this wake |
| `0x02` SLEEP_NOW | optional `uint32` seconds LE | Sleep now; the argument also updates the interval |
| `0x03` FACTORY_RESET | — | Wipe NVS and reboot into pairing |
| `0x04` SET_MODE | `uint8` 0=pairing 1=ble 2=wifi | Switch mode |
| `0x05` FORGET_WIFI | — | Drop credentials, fall back to BLE mode |
| `0x06` IDENTIFY | — | Blink the status LED |

`IDENTIFY` answers on the status characteristic: `identify/blinking` when the
LED is flashing, `identify/no-led` when the board has none to flash. `led` in
the status object says the same thing up front. The firmware picks
`RGB_BUILTIN`, then `LED_BUILTIN`, from the board variant; a board that
declares neither needs `-DSTATUS_LED_PIN=<gpio>` (plus
`-DSTATUS_LED_ACTIVE_LOW=1` if it sinks). The blink is driven from the main
loop, so the write is acknowledged immediately and the board will not sleep
mid-blink.

Write `STAY_AWAKE(0)` right after connecting whenever the user is on a screen
that needs a live link (monitor, pin config, OTA), and `SLEEP_NOW` when leaving
it. That is the difference between a board that lasts weeks and one that dies
in a day.

## 3. Local HTTP (Wi-Fi mode)

Discovered via Bonjour `_batteryholder._tcp` while the board is awake.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/voltage` | `{ "raw": 2731, "volts": 3.94, "soc": 0.78, "pin": "gpio34" }` |
| `GET` | `/api/status` | the §2.3 status object |
| `GET` `POST` | `/api/config` | read / apply `PinConfiguration` |
| `GET` `POST` | `/api/power` | read / apply the power block (§4) |
| `POST` | `/update` | multipart firmware upload |

The ESP8266 (no BLE) exposes the same surface plus `POST /api/provision` and
`POST /api/session` on its pairing SoftAP, which stand in for the provisioning
and session characteristics.

## 4. Power block

Shared by `/api/power`, the provisioning payload's `power` field, and the cloud
`setPower` command:

```json
{
  "mode": "wifi",
  "sleepEnabled": true,
  "bleWakeSec": 300,
  "bleWindowMs": 20000,
  "bleIdleMs": 60000,
  "wifiReportSec": 900,
  "wifiWindowMs": 15000,
  "bleInWifi": false
}
```

## 5. Cloud API

Base URL comes from the claim response and is stored on the device.

### App routes (Cognito JWT)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/devices/claim` | Claim a board, mint its device token |
| `GET` | `/devices` | The user's devices + latest reading + `online` |
| `GET` | `/devices/{deviceId}` | One device + recent readings |
| `POST` | `/devices/{deviceId}/commands` | Queue work for the next check-in |
| `DELETE` | `/devices/{deviceId}` | Release the board |

`POST /devices/claim` with `{ "deviceId": "bh-…", "name": "Garage pack" }`
returns:

```json
{
  "deviceId": "bh-a1b2c3d4e5f6",
  "deviceToken": "9f2c…",
  "backendUrl": "https://…/prod",
  "reportIntervalSec": 900
}
```

The token is returned **once** — only its SHA-256 is stored. The app forwards
`deviceToken` + `backendUrl` to the board over BLE and does not keep them.

### Device route (`X-Device-Token`, no JWT)

`POST /devices/{deviceId}/telemetry`

```json
{ "deviceId": "bh-…", "fw": "2.0.0", "boot": 42, "raw": 2731, "volts": 3.94,
  "soc": 0.78, "pin": "gpio34", "rssi": -56, "ip": "192.168.1.42",
  "uptimeMs": 8123, "wake": 4, "reportSec": 900 }
```

Response:

```json
{
  "ack": true,
  "serverTime": "2026-08-18T09:14:02.113Z",
  "nextReportSec": 900,
  "stayAwakeMs": 60000,
  "commands": [ { "type": "ota", "url": "https://…", "sha256": "…" } ]
}
```

The board applies `nextReportSec` (persisted), honours `stayAwakeMs`, then runs
each command:

| Command | Payload | Effect |
|---|---|---|
| `setConfig` | `{ "config": { …PinConfiguration } }` | Apply and persist sensing config |
| `setPower` | `{ "power": { … } }` | Apply and persist the power block |
| `setMode` | `{ "mode": "ble" \| "wifi" \| "pairing" }` | Switch mode on the next boot |
| `identify` | — | Blink the LED |
| `stayAwake` | `{ "seconds": 120 }` | Hold this wake open |
| `ble` | `{ "seconds": 120 }` | Start BLE now so a phone can connect |
| `ota` | `{ "buildId": "…" }` or `{ "url": "…" }` | Pull firmware and reboot |

Queueing `{"type":"ota","buildId":"esp32-wroom_1.4.2_stable"}` makes the backend
mint the presigned S3 URL itself, so the app never handles firmware bytes in
cloud mode.

### Online-ness

Sleeping boards are offline most of the time by design. `GET /devices` reports
`online: true` when the last check-in is younger than **two** report intervals,
and always returns `lastSeen`. The UI should say "last seen 6 min ago", not
"disconnected".

## 6. Security notes

- The device token is a bearer credential on a single device path; it is
  transported over an encrypted BLE link only during provisioning and stored
  hashed server-side. Rotate it by re-claiming the board.
- The Wi-Fi password is written once over BLE and never read back — the
  provisioning characteristic's read path deliberately omits it.
- Firmware pulls use `setInsecure()` in the reference sketches. Pin the backend
  root CA before shipping hardware.
- BLE pairing is Just-Works by default. Enable LE Secure Connections and gate
  the provisioning + session characteristics behind pairing for production.
