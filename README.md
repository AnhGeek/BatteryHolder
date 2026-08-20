# BatteryHolder

An **iOS** and **Android** app for provisioning, monitoring, and flashing **ESP32 / ESP8266** battery-sensing boards.

BatteryHolder connects to your board over **Bluetooth LE** or **Wi‑Fi**, reads battery voltage from an **ADC pin you choose**, lets you configure the pin mapping and voltage divider for *your* specific board, and pushes new firmware over the air — no USB cable required.

---

## Features

- **Discover & connect** — scan for nearby boards over BLE, or find them on the local network over Wi‑Fi (Bonjour/mDNS).
- **Pick your board** — choose ESP32 (WROOM/DevKitC), ESP32‑C3, or ESP8266 (NodeMCU / Wemos D1 mini) from a catalog with accurate pin maps.
- **Intuitive pin configuration** — tap the ADC pin you wired the battery to. The app only offers pins that can actually do ADC, and warns when a pin is unusable while Wi‑Fi is active (ESP32 ADC2 limitation).
- **Voltage divider & calibration** — enter your R1/R2 resistor values and a calibration factor; the app converts raw ADC counts to real battery volts.
- **Live monitoring** — real‑time voltage, percentage estimate, and history sparkline via BLE notifications or Wi‑Fi polling.
- **USB flashing for new boards** — the Android app carries prebuilt firmware for every board in the catalog and flashes a bare ESP over the phone's OTG port, writing your calibration into a flash region the firmware reads on its first boot. No workstation, no Arduino IDE.
- **OTA flashing** — flash a `.bin` firmware image to the board over **BLE** (chunked GATT writes) or **Wi‑Fi** (HTTP upload), with progress and verification.
- **Cloud firmware catalog** — browse and download signed firmware builds hosted on AWS (S3 + API Gateway + Lambda).
- **Bluetooth setup, Wi‑Fi afterwards** — pair a new board over BLE and hand it your Wi‑Fi password once; from then on it reports to the cloud on its own and you can reach it from anywhere.
- **Battery-first firmware** — boards deep sleep between wakes (weeks of runtime instead of hours) and the app holds them awake only while a screen needs live data.

## Project layout

```
BatteryHolder/
├── BatteryHolder.xcodeproj/    # Ready-to-open Xcode project (Xcode 16+)
├── project.yml                 # XcodeGen definition (alternative to the above)
├── ios/BatteryHolder/          # SwiftUI app sources
│   ├── App/                    # App entry, global state, Info.plist
│   ├── DesignSystem/           # Design tokens + reusable components
│   ├── Models/                 # Board, Pin, PinConfiguration, readings, firmware
│   ├── Services/               # BLE, Wi‑Fi OTA, flasher, AWS repository
│   ├── Features/               # Devices, BoardSetup, PinConfig, Monitor, Flash
│   └── Resources/              # boards.json pin catalog
├── android_app/                # Flutter port of the iOS app (Android)
│   ├── lib/                    # Mirrors ios/BatteryHolder/ file-for-file
│   ├── assets/                 # boards.json (copy of the iOS resource)
│   └── tool/                   # Launcher icons, rendered from the iOS artwork
├── firmware/                   # Reference ESP32/ESP8266 Arduino sketch
├── tools/build_firmware.py     # Builds the .bin images the Android app embeds
├── backend/                    # AWS SAM template for firmware distribution
└── docs/                       # Architecture, design tokens, AWS backend
```

## Getting started

### Requirements

- **Xcode 16 or newer** (the committed project uses file-system-synchronized groups), iOS 16 SDK
- An iPhone (BLE and Local Network permissions do not work in the Simulator)

### Open the project

The Xcode project is committed — just open it:

```bash
cd BatteryHolder
open BatteryHolder.xcodeproj
```

Because the project uses synchronized folders, any file you add under
`ios/BatteryHolder/` is picked up automatically — no manual "Add Files" step.
Set your development team in **Signing & Capabilities**, plug in a device, and run.

> **On Xcode 15 or earlier?** Use XcodeGen instead:
> `brew install xcodegen && xcodegen generate` regenerates
> `BatteryHolder.xcodeproj` from `project.yml`.

### Point the app at your backend

Edit `AppConfig` in `ios/BatteryHolder/App/AppState.swift` and set
`firmwareApiBaseURL` to your deployed API Gateway stage (see
[docs/AWS_BACKEND.md](docs/AWS_BACKEND.md)).

### Run the Android app

The Flutter port lives in [`android_app/`](android_app/) and mirrors the iOS
sources file-for-file — same screens, same design tokens, same transports:

```bash
cd android_app
flutter pub get
flutter run
```

Its backend endpoint is the `AppConfig` in `android_app/lib/app/app_state.dart`.
See [android_app/README.md](android_app/README.md) for the iOS↔Flutter API
mapping. Note the port targets **protocol v1**, matching today's iOS app;
[docs/FLUTTER_APP_HANDOFF.md](docs/FLUTTER_APP_HANDOFF.md) tracks the v2 work.

### Flash the reference firmware first

The app talks to a small contract (a BLE GATT service, a Wi‑Fi HTTP API, and a
cloud check-in), so a board needs [`firmware/battery_holder_node`](firmware/) on
it before there is anything to connect to. Two ways to get it there:

- **From the Android app, over USB** — pick your board, set the pins, tap
  **Generate BIN file** and then **Flash board over USB** with the board on an
  OTG cable. The app ships the images and writes your calibration into flash at
  the same time. Re-run [`tools/build_firmware.py`](tools/build_firmware.py)
  whenever you change a sketch.
- **From a workstation** — `arduino-cli compile` / `upload` as usual.

After either route, all further updates can go over the air.

A freshly flashed board comes up in **pairing mode** — no Wi‑Fi credentials are
compiled in. The app finds it over Bluetooth, asks how it should report
(Bluetooth-only or Wi‑Fi + cloud), and sends the Wi‑Fi password over the BLE
link. See [docs/DEVICE_PROTOCOL.md](docs/DEVICE_PROTOCOL.md).

## Documentation

| Document | What's inside |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, data flow, the device transport contract, threading model |
| [docs/DEVICE_PROTOCOL.md](docs/DEVICE_PROTOCOL.md) | Run modes, BLE provisioning, deep sleep rules, cloud check-in — the firmware/app/backend contract |
| [docs/DESIGN_TOKENS.md](docs/DESIGN_TOKENS.md) | Color, typography, spacing, radius, elevation tokens (light + dark) |
| [docs/AWS_BACKEND.md](docs/AWS_BACKEND.md) | Serverless firmware distribution + device fleet: S3, DynamoDB, Lambda, API Gateway, Cognito |
| [docs/FLUTTER_APP_HANDOFF.md](docs/FLUTTER_APP_HANDOFF.md) | What the Android/Flutter app has to change to speak protocol v2 |
| [android_app/README.md](android_app/README.md) | The Flutter port: layout, iOS↔Flutter API mapping, how to run it |

## License

MIT. Reference firmware is provided as-is for evaluation.
