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
│   ├── models/                 # Board, Pin, PinConfiguration, readings, firmware,
│   │                           #   firmware bundle, calibration image
│   ├── services/               # BLE, Wi-Fi OTA, flasher, AWS repository,
│   │                           #   USB serial + ESP ROM loader + serial console
│   └── features/               # Splash, RootTab, BoardSetup, Devices, Monitor,
│                               #   Configuration, Flash, Setup wizard, Power
├── android/…/UsbSerialBridge.kt # USB-host serial (CDC, CP210x, CH34x, FTDI)
├── assets/boards.json          # Copy of ios/BatteryHolder/Resources/boards.json
├── assets/firmware/            # Prebuilt .bin images + manifest, staged by
│                               #   tools/build_firmware.py (never built on device)
├── test/                       # Model math, tokens, layout, ROM protocol,
│                               #   bundled-firmware integrity
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

## Flashing a new board over USB

A board nobody has set up yet has no Bluetooth pairing, no Wi-Fi credentials and
an empty NVS, so the OTG cable is the only way in. The app carries prebuilt
firmware for every catalog board in `assets/firmware/` (staged by
`tools/build_firmware.py` — nothing is compiled on the phone) and writes it with
the chip's own ROM bootloader.

The flow, end to end:

1. **Setup → Configure** — pick the ADC pin, divider and pack.
2. **Generate BIN file** — assembles the bundled images plus a calibration image
   built from those settings, writes the calibration out as a real `.bin`, and
   opens the Flash tab.
3. **Flash board over USB** — resets the board into download mode, blanks its
   saved settings, writes bootloader / partition table / boot select / app, and
   drops the calibration into its own flash region (DEVICE_PROTOCOL.md §6).
   Then it reads every image back off the board and compares checksums, and
   **stops there**, with the board still parked in its ROM bootloader.
4. **Reboot and confirm** — an explicit second step, offered only after every
   image verified. It pulses EN, then hands the same calibration over the serial
   console (§7) and reads it back.
5. With **Set to Bluetooth mode** left on, the same console call the BLE
   provisioning characteristic uses claims the board there and then, so it
   leaves the cable already set up. Turn it off for a Wi-Fi board: those need
   the Devices tab, which is where the network password is asked for.

Why the split: a reset is the only irreversible step. Nothing is allowed to run
until the flash has been proven correct, so a run that goes wrong leaves a board
that is still in the bootloader and still re-flashable rather than one that has
rebooted into a half-written image. Unplugging a verified board also starts the
new firmware — the reboot button is just the way to stay connected and confirm.

**Check board** is available at any time and writes nothing: it opens the
console and reports the firmware version, device id, run mode and the
calibration the board is holding. **Verify what is on the board** is the
stronger version: it enters the ROM bootloader — where the chip runs nothing at
all — and compares checksums of every image against the current build, which
works whether or not the firmware boots.

### Boards with native USB (ESP32-C3/S3/C6)

These enumerate as `303a:1001`, "USB JTAG/serial debug unit": the USB port is
the chip, not a bridge. That changes the workflow in two ways, and both are
handled:

- **A sleeping board has no USB port.** Deep sleep powers the peripheral down,
  so the device detaches from the phone and reappears on the next wake. Every
  USB action therefore waits up to 90 s for the board to turn up and grabs it
  the moment it does — the ROM bootloader never sleeps, so catching it once is
  enough. Tapping RESET on the board makes it appear immediately. Firmware 2.1.0
  onwards will not sleep at all while a USB host holds the port open.
- **The console lives on that port.** The C3 build enables `CDCOnBoot`, so the
  sketch's `Serial` is the native USB port (UART0 moves to `Serial0`, and both
  are serviced). A board flashed with an older image answers nothing over its
  USB socket even while awake — reflash it, and it will.

| Piece | What it does |
|---|---|
| `android/…/UsbSerialBridge.kt` | USB-host serial spoken straight to `UsbManager`: CDC-ACM, CP210x, CH34x and FTDI, with direct control of DTR/RTS |
| `lib/services/usb_serial_port.dart` | The Dart side of that channel |
| `lib/services/esp_loader.dart` | The ESP ROM bootloader protocol — SLIP framing, sync, chip detect, compressed writes, MD5 verify |
| `lib/services/serial_console.dart` | The JSON-per-line console the sketch exposes |
| `lib/services/usb_flash_service.dart` | Drives the whole sequence and publishes the progress log |
| `lib/services/firmware_bundle_repository.dart` | Loads the embedded images and assembles a `FlashPlan` |

The loader is written from the published serial protocol rather than ported from
esptool, which is GPL-2.0; the app is MIT. That also means no flasher stub, so
writes use the ROM's 1 KB blocks — compressed, at 460800 baud, an ESP32 image
takes well under a minute.

**Why the calibration goes into flash rather than over the wire.** The region is
what a board reads on its *first* boot, before anything has ever talked to it.
The console hand-off in step 4 is confirmation, not the delivery mechanism: on a
board whose console cannot be reached the app says the confirmation is missing
and the board is still correctly calibrated.

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
| Board settings screen (the power block, §4) | [power_view.dart](lib/features/power/power_view.dart) |
| Poll-failure backoff / "asleep" inference | `WiFiOTAService.reachability` |

## Beacon logging (works with the app closed)

A board is only reachable for ~20 s every few minutes, so a scan that ran only
while a screen was open would miss nearly every wake. A native Android
foreground service does the scanning instead and appends every advertisement to
a JSON-lines file; the UI reads the same file back.

| Piece | Where |
|---|---|
| Foreground scan service (the writer) | [BeaconScanService.kt](android/app/src/main/kotlin/store/lyhoanganh/battery_holder/BeaconScanService.kt) |
| Restart after reboot | [BootReceiver.kt](android/app/src/main/kotlin/store/lyhoanganh/battery_holder/BootReceiver.kt) |
| Start/stop bridge | [MainActivity.kt](android/app/src/main/kotlin/store/lyhoanganh/battery_holder/MainActivity.kt) ↔ [beacon_scan_service_client.dart](lib/services/beacon_scan_service_client.dart) |
| Log file reader + rollup | [beacon_log_store.dart](lib/services/beacon_log_store.dart), [beacon_log.dart](lib/models/beacon_log.dart) |
| Board list + per-board history | [monitor_view.dart](lib/features/monitor/monitor_view.dart), [device_monitor_view.dart](lib/features/monitor/device_monitor_view.dart) |
| Per-board delete | `BeaconLogStore.clearDevice` (rewrites the file from what is left) |

The file is `beacons.jsonl` in the app's private files directory —
`context.getFilesDir()` on the Kotlin side, `getApplicationSupportDirectory()`
on the Dart side, which resolve to the same path. The service is the only
writer, so there is no cross-process locking to get wrong.

A row is written when a board is sighted more than 25 s after the last time it
was seen — i.e. when it slept in between — so a wake yields one row rather than
one per advertising packet. The board rebuilds its advertisement every 10 s
while awake and the ADC never repeats a reading, so collapsing on the *payload*
does not work; only the gap does. A mode change (the §2.1 flags) is logged
immediately, and a board that never sleeps is recorded every 15 minutes so the
row count still tracks something. The file is trimmed to the newest 4000 rows.

Logging is **off until switched on** from the Monitor tab; the choice persists
and is honoured on reboot. It defaults to off because a switch that reads "on"
while no service is running is worse than one that reads "off" — the flag alone
cannot promise a scan, so the card reports `isEnabled` and `isScanning`
separately and says so when they disagree. Android requires the ongoing
notification that comes with a foreground service — there is no way to scan
indefinitely without it.

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
