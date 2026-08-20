import 'board.dart';
import 'device_status.dart';

/// How a board should behave once it is running — decided before the board has
/// ever been switched on.
///
/// This used to be asked over Bluetooth *after* the flash, which meant a board
/// came off the cable unclaimed (`pairing` mode, an empty NVS) and the app had
/// to catch it awake and ask it the same question again. The answers ride in
/// the calibration region instead (DEVICE_PROTOCOL.md §6), so the image the
/// phone writes already says what the board is for: flash it, reset it, done.
///
/// [PinConfiguration] is the other half — that one describes the *hardware*
/// (which pin, what divider), this one describes the *behaviour*.
class BoardSetup {
  /// What the board does on every wake once it boots.
  final RunMode mode;

  /// Wake intervals, windows and the sleep switch — the §4 power block.
  final PowerConfig power;

  /// Credentials for [RunMode.wifi]. Ignored in any other mode.
  final String ssid;
  final String password;

  const BoardSetup({
    this.mode = RunMode.ble,
    this.power = const PowerConfig(),
    this.ssid = '',
    this.password = '',
  });

  /// The interval that actually applies in the chosen mode.
  int get intervalSec => power.intervalSecFor(mode);

  /// A Wi-Fi board with no network named cannot be flashed ready to run: it
  /// would boot, fail to join, and fall back to advertising — which is a worse
  /// outcome than being asked for the password here.
  bool get isComplete => mode != RunMode.wifi || ssid.trim().isNotEmpty;

  /// Whether a board that boots with this setup is already claimed, i.e. needs
  /// nothing from the Devices tab.
  bool get isProvisioned => mode != RunMode.pairing;

  BoardSetup copyWith({
    RunMode? mode,
    PowerConfig? power,
    String? ssid,
    String? password,
  }) =>
      BoardSetup(
        mode: mode ?? this.mode,
        power: power ?? this.power,
        ssid: ssid ?? this.ssid,
        password: password ?? this.password,
      );

  /// The same setup with [seconds] applied to whichever interval [mode] uses.
  BoardSetup withInterval(int seconds) =>
      copyWith(power: power.withIntervalFor(mode, seconds));

  /// Clamped to what [board] can actually do.
  ///
  /// An ESP8266 has no BLE radio at all, so "Bluetooth mode" on one is not a
  /// preference the app should quietly keep holding — it is a mode the board
  /// could never enter.
  BoardSetup forBoard(Board board) {
    final canBle = board.supportedTransports.contains(FlashTransport.ble);
    final canWifi = board.supportedTransports.contains(FlashTransport.wifi);
    if (mode == RunMode.ble && !canBle) {
      return copyWith(mode: canWifi ? RunMode.wifi : RunMode.pairing);
    }
    if (mode == RunMode.wifi && !canWifi) {
      return copyWith(mode: canBle ? RunMode.ble : RunMode.pairing);
    }
    return this;
  }

  /// The keys the firmware reads out of the calibration region alongside the
  /// [PinConfiguration] — `power` (with `mode` folded in, exactly as the board
  /// itself reports it in `getpower`) and, for a Wi-Fi board, the credentials.
  ///
  /// The password is written into the board's flash the same way the firmware
  /// is: whoever holds the cable already holds the board.
  Map<String, dynamic> toCalibrationJson() => {
        'power': {...power.toJson(), 'mode': mode.name},
        if (mode == RunMode.wifi) 'ssid': ssid.trim(),
        if (mode == RunMode.wifi) 'password': password,
      };

  @override
  bool operator ==(Object other) =>
      other is BoardSetup &&
      other.mode == mode &&
      other.power == power &&
      other.ssid == ssid &&
      other.password == password;

  @override
  int get hashCode => Object.hash(mode, power, ssid, password);
}
