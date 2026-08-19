# BatteryHolder — Android (Flutter)

A Flutter port of the iOS SwiftUI app in [`../ios/BatteryHolder`](../ios/BatteryHolder).
Every screen, token, and service has a 1:1 counterpart on the Swift side; the
file layout below mirrors it deliberately so the two stay easy to diff.

> **Protocol note.** The screens and design system match the iOS app. The
> **Bluetooth** half of [device protocol v2](../docs/DEVICE_PROTOCOL.md) is
> implemented here and goes beyond the iOS app, which still speaks v1:
> sleep-aware connection states, advertisement decoding, the status/session/
> provisioning characteristics, the setup wizard, and the Power screen. The
> **cloud** half (`CloudService`, the merged device list, cloud OTA) is not
> built — see the checklist in
> [../docs/FLUTTER_APP_HANDOFF.md](../docs/FLUTTER_APP_HANDOFF.md).

## Layout

```
android_app/
├── lib/
│   ├── main.dart               # App entry + splash/tab crossfade (BatteryHolderApp.swift)
│   ├── app/app_state.dart      # Composition root & state (AppState.swift)
│   ├── design_system/          # Tokens, brand mark, components (DesignSystem/)
│   ├── models/                 # Board, Pin, PinConfiguration, readings, firmware
│   ├── services/               # BLE, Wi-Fi OTA, flasher, AWS repository
│   └── features/               # Splash, RootTab, BoardSetup, Devices, Monitor,
│                               #   PinConfig, Flash, Setup wizard, Power
├── assets/boards.json          # Copy of ios/BatteryHolder/Resources/boards.json
├── test/                       # Model math, token, and layout tests
└── tool/generate_launcher_icons.py
```

## How the platforms map

| iOS (SwiftUI) | Android (Flutter) |
|---|---|
| `@EnvironmentObject AppState` | `provider` + `ChangeNotifier` |
| Dynamic `UIColor` light/dark | `AppColor(isDark)` resolved via `AppTheme.colorOf(context)` |
| `CoreBluetooth` | `flutter_blue_plus` |
| `NWBrowser` (Bonjour) | `nsd` (Android `NsdManager`) |
| `URLSession` | `package:http` |
| `CryptoKit.SHA256` | `package:crypto` |
| `.fileImporter` | `file_picker` |
| Info.plist usage strings | `AndroidManifest.xml` permissions + `permission_handler` |
| SF Symbols | Material icons (closest equivalent per symbol) |
| SF Pro / SF Mono | Roboto / platform monospace |

## Device protocol v2 (Bluetooth)

The board is asleep most of the time, so the app treats a fruitless scan and a
self-initiated disconnect as normal rather than as errors
([DEVICE_PROTOCOL.md](../docs/DEVICE_PROTOCOL.md) §1).

| Piece | Where |
|---|---|
| `provisioning` / `status` / `session` characteristics | [ble_manager.dart](lib/services/ble_manager.dart) `BLEUUID` |
| Advertisement decode (battery, flags, "needs setup") | `DiscoveredDevice.fromScan` |
| `DeviceStatus`, `RunMode`, `PowerConfig` | [device_status.dart](lib/models/device_status.dart) |
| `ConnectionStatus.sleeping` | `BLEManager._handleStatusPayload` |
| `stayAwake` / `sleepNow` / `factoryReset` / `setMode` / `forgetWifi` / `identify` | `BLEManager` §2.4 block |
| `withAwakeBoard` wrapper (wraps OTA, config writes, Power writes) | `BLEManager.withAwakeBoard` |
| Screen-scoped awake contract | [board_awake_mixin.dart](lib/features/board_awake_mixin.dart) |
| Setup wizard (connect → mode → Wi-Fi → done) | [board_setup_wizard.dart](lib/features/setup/board_setup_wizard.dart) |
| Power & sleep screen | [power_view.dart](lib/features/power/power_view.dart) |
| Poll-failure backoff / "asleep" inference | `WiFiOTAService.reachability` |

**v1 compatibility** — firmware 1.x has no `0007`/`0008`/`0009` characteristics.
`BLEManager.supportsV2` is false for those boards, `withAwakeBoard` becomes a
pass-through, and the Power screen and mode picker hide themselves rather than
throwing.

**Wi-Fi without a backend** — a board can be provisioned onto Wi-Fi with no
cloud token; the firmware skips check-in and just serves readings locally over
mDNS. The wizard says so when `AppConfig` is still unconfigured.

Sizes, weights, spacing, radii, and colors are ported verbatim from
[`../docs/DESIGN_TOKENS.md`](../docs/DESIGN_TOKENS.md); `lib/design_system/theme.dart`
is the single source of truth, exactly as `Theme.swift` is on iOS.

## Getting started

```bash
cd android_app
flutter pub get
flutter run
```

Requires the Flutter SDK (built against 3.44) and an Android device or emulator.
BLE scanning needs a physical device or an emulator with Bluetooth support, and
the app requests `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` at runtime on Android 12+.

### Point the app at your backend

Edit `AppConfig` in [`lib/app/app_state.dart`](lib/app/app_state.dart) and set
`firmwareApiBaseURL` to your deployed API Gateway stage — the counterpart of
`AppConfig` in `AppState.swift`. Until then the Flash tab shows its
catalog-unreachable callout, which is the expected pre-configuration state.

## Tests

```bash
flutter test
```

Covers the divider/percentage math, the battery color scale, `ByteCountFormatter`
-equivalent size formatting, component rendering, and the scroll-layout
regressions that unbounded-height rows would reintroduce.

## Launcher icon

`tool/generate_launcher_icons.py` imports `render_master()` from
[`../tools/generate_appicon.py`](../tools/generate_appicon.py), so the Android
launcher icon is rendered from the same artwork as the iOS app icon rather than a
copy that can drift.

```bash
python tool/generate_launcher_icons.py
```

It writes the legacy mipmaps, the adaptive icon layers, and the
`ic_launcher_background` color that the native launch window also uses — which is
why there is no white flash or Flutter branding before `SplashView` appears.
