# Changelog

Releases of the BatteryHolder Android app. Each version here becomes a GitHub
release carrying the signed APK, built by `.github/workflows/release.yml` from
the matching `v*` tag.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-24

First release.

### Added

- **Board setup.** Pick a board (ESP32 DevKitC, ESP32-C3 DevKitM, NodeMCU,
  Wemos D1 mini), choose the ADC pin the battery divider is wired to, and dial
  in the divider, calibration and pack chemistry.
- **Flash over USB.** Bring up a bare board straight from the phone's OTG port.
  The firmware images ship inside the app; the calibration and the board's run
  mode travel with them, so a board wakes up on its first boot already set up
  rather than waiting to be provisioned over Bluetooth.
- **Run mode and timers before the flash.** Wi-Fi or Bluetooth reporting, wake
  interval, sleep windows and Wi-Fi credentials are all baked into the image.
- **Board wiring overrides.** The status LED pin, its polarity and the pairing
  button pin are settings rather than compiled-in guesses, so a board wired
  differently from the reference does not need a rebuild.
- **Background beacon logging.** A foreground service keeps recording every
  board wake while the app is closed or swiped away — boards advertise for only
  ~20 s every few minutes, so an in-app-only scan would miss nearly every one.
  The log survives restarts and reboots.
- **Devices and Monitor.** Live readings over Bluetooth while a board is awake,
  the recorded wake history the rest of the time, and a per-board page with its
  gauge, chart and full log.
- **Low battery alerts.** Per board: a switch, a voltage to warn below, and how
  often it may remind you (default every 2 hours). It warns after five readings
  in a row below the line — one dip under load is not a flat pack — and keeps
  working while the app is closed. New boards start switched on, at the
  threshold their pack's chemistry implies.
- **Wi-Fi OTA.** Discover boards over mDNS and push firmware to them over the
  local network.

[Unreleased]: https://github.com/AnhGeek/BatteryHolder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AnhGeek/BatteryHolder/releases/tag/v0.1.0
