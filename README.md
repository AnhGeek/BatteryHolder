# BatteryHolder

An iOS app for provisioning, monitoring, and flashing **ESP32 / ESP8266** battery-sensing boards.

BatteryHolder connects to your board over **Bluetooth LE** or **Wi‑Fi**, reads battery voltage from an **ADC pin you choose**, lets you configure the pin mapping and voltage divider for *your* specific board, and pushes new firmware over the air — no USB cable required.

---

## Features

- **Discover & connect** — scan for nearby boards over BLE, or find them on the local network over Wi‑Fi (Bonjour/mDNS).
- **Pick your board** — choose ESP32 (WROOM/DevKitC), ESP32‑C3, or ESP8266 (NodeMCU / Wemos D1 mini) from a catalog with accurate pin maps.
- **Intuitive pin configuration** — tap the ADC pin you wired the battery to. The app only offers pins that can actually do ADC, and warns when a pin is unusable while Wi‑Fi is active (ESP32 ADC2 limitation).
- **Voltage divider & calibration** — enter your R1/R2 resistor values and a calibration factor; the app converts raw ADC counts to real battery volts.
- **Live monitoring** — real‑time voltage, percentage estimate, and history sparkline via BLE notifications or Wi‑Fi polling.
- **OTA flashing** — flash a `.bin` firmware image to the board over **BLE** (chunked GATT writes) or **Wi‑Fi** (HTTP upload), with progress and verification.
- **Cloud firmware catalog** — browse and download signed firmware builds hosted on AWS (S3 + API Gateway + Lambda).

## Project layout

```
BatteryHolder/
├── project.yml                 # XcodeGen project definition
├── ios/BatteryHolder/          # SwiftUI app sources
│   ├── App/                    # App entry, global state, Info.plist
│   ├── DesignSystem/           # Design tokens + reusable components
│   ├── Models/                 # Board, Pin, PinConfiguration, readings, firmware
│   ├── Services/               # BLE, Wi‑Fi OTA, flasher, AWS repository
│   ├── Features/               # Devices, BoardSetup, PinConfig, Monitor, Flash
│   └── Resources/              # boards.json pin catalog
├── firmware/                   # Reference ESP32/ESP8266 Arduino sketch
├── backend/                    # AWS SAM template for firmware distribution
└── docs/                       # Architecture, design tokens, AWS backend
```

## Getting started

### Requirements

- Xcode 15 or newer, iOS 16 SDK
- An iPhone (BLE and Local Network permissions do not work in the Simulator)
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`)

### Generate the Xcode project

```bash
brew install xcodegen        # one time
cd BatteryHolder
xcodegen generate            # reads project.yml -> BatteryHolder.xcodeproj
open BatteryHolder.xcodeproj
```

Set your development team in **Signing & Capabilities**, plug in a device, and run.

> Don't want XcodeGen? The sources under `ios/BatteryHolder` are a plain SwiftUI
> app — create a new iOS App target in Xcode, drag the folders in, and copy the
> keys from `ios/BatteryHolder/App/Info.plist`.

### Point the app at your backend

Edit `AppConfig` in `ios/BatteryHolder/App/AppState.swift` and set
`firmwareApiBaseURL` to your deployed API Gateway stage (see
[docs/AWS_BACKEND.md](docs/AWS_BACKEND.md)).

### Flash the reference firmware first

The app talks to a small contract (a BLE GATT service + a Wi‑Fi HTTP OTA
endpoint). Flash [`firmware/battery_holder_node`](firmware/) to your board once
over USB so the app has something to connect to; after that, all updates can go
over the air.

## Documentation

| Document | What's inside |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, data flow, the device transport contract, threading model |
| [docs/DESIGN_TOKENS.md](docs/DESIGN_TOKENS.md) | Color, typography, spacing, radius, elevation tokens (light + dark) |
| [docs/AWS_BACKEND.md](docs/AWS_BACKEND.md) | Serverless firmware distribution: S3, DynamoDB, Lambda, API Gateway, Cognito |

## License

MIT — see below. Reference firmware is provided as-is for evaluation.
