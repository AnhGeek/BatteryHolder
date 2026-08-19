/// Run mode the board is in — DEVICE_PROTOCOL.md §1.
enum RunMode {
  pairing,
  ble,
  wifi;

  static RunMode fromJson(String? raw) =>
      RunMode.values.firstWhere((m) => m.name == raw, orElse: () => RunMode.pairing);

  /// Wire value for session command `0x04 SET_MODE`.
  int get wireValue => index;

  String get displayName => switch (this) {
        RunMode.pairing => 'Pairing',
        RunMode.ble => 'Bluetooth',
        RunMode.wifi => 'Wi-Fi + cloud',
      };
}

/// The board's status object, read from `…-0008-…` and pushed on every state
/// change — DEVICE_PROTOCOL.md §2.3.
///
/// Every field is optional: the board only includes what is meaningful for the
/// current mode, and `ev`/`detail` appear on event pushes only.
class DeviceStatus {
  /// Event name on a push (`boot`, `ready`, `wifi`, `sleeping`, `prov`, …).
  final String? event;

  /// Event qualifier (`connecting`, `connected`, `failed`, `done`, …).
  final String? detail;

  final String? id;
  final String? fw;
  final RunMode mode;
  final bool provisioned;

  final int? raw;
  final double? volts;

  /// State of charge, 0–100.
  final int? soc;
  final int? boot;

  final String? wifi;
  final String? ip;
  final int? rssi;
  final String? ssid;
  final bool cloud;

  /// Whether the board has a status LED that IDENTIFY can blink. Boards whose
  /// variant declares neither `LED_BUILTIN` nor `RGB_BUILTIN` report false —
  /// firmware that predates the field is assumed to have one.
  final bool hasLed;

  /// Milliseconds left in this wake, or -1 when sleeping is disabled/blocked.
  final int? sleepInMs;
  final int? nextWakeSec;

  const DeviceStatus({
    this.event,
    this.detail,
    this.id,
    this.fw,
    this.mode = RunMode.pairing,
    this.provisioned = false,
    this.raw,
    this.volts,
    this.soc,
    this.boot,
    this.wifi,
    this.ip,
    this.rssi,
    this.ssid,
    this.cloud = false,
    this.hasLed = true,
    this.sleepInMs,
    this.nextWakeSec,
  });

  /// `ev == "sleeping"` — the board is about to drop the link on purpose.
  bool get isSleeping => event == 'sleeping';

  /// True while sleeping is suppressed (STAY_AWAKE held, or disabled in config).
  bool get sleepHeld => sleepInMs != null && sleepInMs! < 0;

  /// `"$event/$detail"`, for matching the provisioning sequence.
  String get eventPath =>
      detail == null ? (event ?? '') : '${event ?? ''}/$detail';

  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
        event: json['ev'] as String?,
        detail: json['detail'] as String?,
        id: json['id'] as String?,
        fw: json['fw'] as String?,
        mode: RunMode.fromJson(json['mode'] as String?),
        provisioned: json['prov'] as bool? ?? false,
        raw: (json['raw'] as num?)?.toInt(),
        volts: (json['volts'] as num?)?.toDouble(),
        soc: (json['soc'] as num?)?.toInt(),
        boot: (json['boot'] as num?)?.toInt(),
        wifi: json['wifi'] as String?,
        ip: json['ip'] as String?,
        rssi: (json['rssi'] as num?)?.toInt(),
        ssid: json['ssid'] as String?,
        cloud: json['cloud'] as bool? ?? false,
        hasLed: json['led'] as bool? ?? true,
        sleepInMs: (json['sleepInMs'] as num?)?.toInt(),
        nextWakeSec: (json['nextWakeSec'] as num?)?.toInt(),
      );
}

/// The power block — DEVICE_PROTOCOL.md §4. Shared by the provisioning payload's
/// `power` field, the local `/api/power` route, and the cloud `setPower` command.
class PowerConfig {
  final bool sleepEnabled;
  final int bleWakeSec;
  final int bleWindowMs;
  final int bleIdleMs;
  final int wifiReportSec;
  final int wifiWindowMs;
  final bool bleInWifi;

  const PowerConfig({
    this.sleepEnabled = true,
    this.bleWakeSec = 300,
    this.bleWindowMs = 20000,
    this.bleIdleMs = 60000,
    this.wifiReportSec = 900,
    this.wifiWindowMs = 15000,
    this.bleInWifi = false,
  });

  factory PowerConfig.fromJson(Map<String, dynamic> json) => PowerConfig(
        sleepEnabled: json['sleepEnabled'] as bool? ?? true,
        bleWakeSec: (json['bleWakeSec'] as num?)?.toInt() ?? 300,
        bleWindowMs: (json['bleWindowMs'] as num?)?.toInt() ?? 20000,
        bleIdleMs: (json['bleIdleMs'] as num?)?.toInt() ?? 60000,
        wifiReportSec: (json['wifiReportSec'] as num?)?.toInt() ?? 900,
        wifiWindowMs: (json['wifiWindowMs'] as num?)?.toInt() ?? 15000,
        bleInWifi: json['bleInWifi'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'sleepEnabled': sleepEnabled,
        'bleWakeSec': bleWakeSec,
        'bleWindowMs': bleWindowMs,
        'bleIdleMs': bleIdleMs,
        'wifiReportSec': wifiReportSec,
        'wifiWindowMs': wifiWindowMs,
        'bleInWifi': bleInWifi,
      };

  PowerConfig copyWith({
    bool? sleepEnabled,
    int? bleWakeSec,
    int? bleWindowMs,
    int? bleIdleMs,
    int? wifiReportSec,
    int? wifiWindowMs,
    bool? bleInWifi,
  }) =>
      PowerConfig(
        sleepEnabled: sleepEnabled ?? this.sleepEnabled,
        bleWakeSec: bleWakeSec ?? this.bleWakeSec,
        bleWindowMs: bleWindowMs ?? this.bleWindowMs,
        bleIdleMs: bleIdleMs ?? this.bleIdleMs,
        wifiReportSec: wifiReportSec ?? this.wifiReportSec,
        wifiWindowMs: wifiWindowMs ?? this.wifiWindowMs,
        bleInWifi: bleInWifi ?? this.bleInWifi,
      );

  /// The reporting interval that actually applies in [mode].
  int intervalSecFor(RunMode mode) =>
      mode == RunMode.wifi ? wifiReportSec : bleWakeSec;
}
