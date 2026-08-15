# Architecture

BatteryHolder is a SwiftUI application organized in clean, testable layers. The
UI never talks to Bluetooth or sockets directly — every side effect goes through
a service with a small, mockable surface, and services publish state through
Combine so SwiftUI views stay declarative.

```
┌──────────────────────────────────────────────────────────────┐
│                          SwiftUI Views                        │
│   Devices · BoardSetup · PinConfig · Monitor · Flash          │
└───────────────▲───────────────────────────────▲──────────────┘
                │ @EnvironmentObject            │ @Published
┌───────────────┴───────────────────────────────┴──────────────┐
│                          AppState                             │
│   owns services, selected board, active PinConfiguration      │
└───────▲───────────────▲───────────────▲──────────────▲───────┘
        │               │               │              │
┌───────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐ ┌─────┴───────┐
│ BLEManager   │ │ WiFiOTA     │ │ Firmware    │ │ Firmware    │
│ CoreBluetooth│ │ Service     │ │ Flasher     │ │ Repository  │
│              │ │ Network fx  │ │ (transport  │ │ (AWS REST + │
│              │ │ mDNS + HTTP │ │  orchestr.) │ │  S3 blobs)  │
└──────┬───────┘ └──────┬──────┘ └─────────────┘ └─────────────┘
       │                │
   ┌───┴────────────────┴───┐
   │   ESP32 / ESP8266 node │  (BLE GATT + HTTP OTA contract)
   └────────────────────────┘
```

## Layers

### 1. Models (`Models/`)
Value types only — `Board`, `Pin`, `PinConfiguration`, `BatteryReading`,
`FirmwareImage`. They are `Codable`/`Equatable` and carry the domain math (e.g.
`PinConfiguration.voltage(fromRawADC:)` turns raw counts into battery volts).
The board catalog ships as `Resources/boards.json` and is decoded into `[Board]`
at launch, so adding a new board is a data change, not a code change.

### 2. Services (`Services/`)
Each service is an `ObservableObject` with a narrow protocol:

- **BLEManager** — wraps `CBCentralManager`. Scans for the BatteryHolder GATT
  service, connects, subscribes to the voltage characteristic (notify), writes
  the pin configuration, and implements chunked OTA writes.
- **WiFiOTAService** — uses `NWBrowser` to discover `_batteryholder._tcp`
  nodes via Bonjour, then `URLSession` to poll voltage and POST firmware to the
  board's `/update` endpoint.
- **FirmwareFlasher** — transport-agnostic orchestrator. Given a
  `FirmwareImage` and a chosen transport, it drives either BLEManager or
  WiFiOTAService and publishes a single `FlashProgress` stream.
- **FirmwareRepository** — talks to the AWS REST API to list available builds
  and download the selected `.bin` to a temporary file.

### 3. AppState (`App/AppState.swift`)
The composition root. It instantiates the services, holds the currently selected
`Board` and the working `PinConfiguration`, and exposes intent methods
(`startScan()`, `connect(_:)`, `applyPinConfiguration()`, `flash(_:over:)`).
Injected once via `.environmentObject`.

### 4. Views (`Features/`)
Each feature is a folder of SwiftUI views bound to `AppState`. Views hold no
business logic beyond formatting.

## The device transport contract

Both transports expose the same three capabilities. The reference firmware in
`firmware/` implements exactly this contract.

### Bluetooth LE (GATT)

| Role | UUID | Properties | Payload |
|---|---|---|---|
| Service | `A1B2C3D4-0001-4A5B-8C6D-000000000000` | — | BatteryHolder service |
| Battery voltage | `…-0002-…` | Read, Notify | `float32` volts, little‑endian |
| Raw ADC | `…-0003-…` | Read, Notify | `uint16` raw counts |
| Pin config | `…-0004-…` | Read, Write | UTF‑8 JSON of `PinConfiguration` |
| OTA control | `…-0005-…` | Write, Notify | 1 byte cmd + status codes |
| OTA data | `…-0006-…` | Write w/o response | firmware chunk (≤ MTU‑3) |

OTA sequence: write `START|totalSize` to control → stream chunks to data →
write `END|crc32` to control → firmware verifies, replies `OK`/`ERR` on the
control notify, then reboots.

### Wi‑Fi (HTTP over local network)

Discovered via Bonjour service `_batteryholder._tcp`. Endpoints on the board:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/voltage` | JSON `{ "raw": 2731, "volts": 3.94, "pin": "GPIO34" }` |
| `GET` | `/api/config` | current `PinConfiguration` JSON |
| `POST` | `/api/config` | apply a new `PinConfiguration` |
| `POST` | `/update` | multipart firmware upload (ArduinoOTA‑style), streams progress |

## Data flow: reading a battery

1. `MonitorView` appears → `AppState.startMonitoring()`.
2. Transport delivers a raw ADC sample (BLE notify or Wi‑Fi poll).
3. `PinConfiguration.voltage(fromRawADC:)` applies
   `raw / adcMaxCount * adcRefVoltage * (R1+R2)/R2 * calibration`.
4. A `BatteryReading` is appended to a ring buffer and published.
5. `MonitorView` re-renders the gauge, percentage, and sparkline.

## Threading

- CoreBluetooth callbacks arrive on a dedicated serial queue; state is hopped to
  the main actor before mutating `@Published` properties.
- `URLSession` and `NWBrowser` work is async/await; UI updates run on
  `@MainActor`.
- All `ObservableObject`s are annotated `@MainActor` so view bindings are safe.

## Testability

Services are referenced through protocols (`BatteryTransport`,
`FirmwareCatalog`). `AppState` accepts injected implementations, so unit tests
swap in mocks that replay canned readings and OTA progress without hardware.

## Security notes

- BLE pairing uses Just‑Works by default; enable LE Secure Connections in
  firmware for production and gate the pin‑config characteristic behind pairing.
- Wi‑Fi OTA should run over the board's SoftAP or a trusted LAN; the AWS catalog
  serves firmware over HTTPS with short‑lived S3 presigned URLs and an optional
  SHA‑256 that the app verifies before flashing.
