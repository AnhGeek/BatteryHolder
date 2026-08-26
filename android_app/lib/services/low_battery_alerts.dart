import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/device_alert_setting.dart';

/// One warning, ready to be posted.
class LowBatteryAlert {
  /// BLE address of the board the readings came from.
  final String deviceId;

  /// What to call it in the notification.
  final String deviceName;

  /// The reading that tripped the warning.
  final double volts;

  /// The threshold it fell below.
  final double thresholdVolts;

  /// How long this board waits before it may warn again — passed along so the
  /// native side, which owns the clock, can hold the window.
  final Duration repeatAfter;

  const LowBatteryAlert({
    required this.deviceId,
    required this.deviceName,
    required this.volts,
    required this.thresholdVolts,
    this.repeatAfter = DeviceAlertSetting.defaultRepeatAfter,
  });

  String get title => 'Battery low';

  String get body => '$deviceName is at ${volts.toStringAsFixed(2)} V — '
      '${LowBatteryAlerts.samplesBeforeAlert} readings in a row below '
      '${thresholdVolts.toStringAsFixed(2)} V.';
}

/// Per-board low-battery warnings: who is watched, below what, and the rule
/// that decides when a run of low readings is really a flat pack.
///
/// Settings are held per board and persisted, because the boards outlive
/// everything else here — one is on a boat, one is on the bench, and the app
/// forgets the working configuration between launches but must not forget that
/// the bench one was muted.
///
/// The rule is deliberately not "one reading below the line". A pack under load
/// dips, an ADC is noisy, and a board that has just woken reads low for a
/// moment before its rail settles — any of which would warn about a battery
/// that is fine. [samplesBeforeAlert] consecutive low readings is the cheapest
/// test that ignores all three, because none of them persist that long.
///
/// The same rule runs natively inside `BeaconScanService` for sightings that
/// arrive while the app is closed, which is where the warning usually has to
/// come from: a board sleeps most of its life, and nobody is watching the
/// Monitor screen at the moment its pack gives out. Every change here is
/// mirrored into the prefs that service reads.
class LowBatteryAlerts extends ChangeNotifier {
  /// How many consecutive readings below the threshold it takes to warn.
  static const samplesBeforeAlert = 5;


  /// Fallback for a phone that has never had a board configured: a 1S LiPo,
  /// which is what nearly every one of these boards is running.
  static const fallbackThresholdVolts = 3.5;

  /// Must match `LowBatteryAlerts.SETTINGS_FILE_NAME` on the Android side.
  static const fileName = 'alerts.json';

  static const _channel =
      MethodChannel('com.batteryholder/alerts');

  /// Posts the notification. Swapped out in tests, which have no platform.
  final Future<void> Function(LowBatteryAlert alert) post;

  LowBatteryAlerts({Future<void> Function(LowBatteryAlert alert)? post})
      : post = post ?? _postNative;

  /// Boards the user has given an answer for. A board that is not in here is
  /// not unwatched — it is on [DeviceAlertSetting.defaults].
  final Map<String, DeviceAlertSetting> _settings = {};

  double _defaultThresholdVolts = fallbackThresholdVolts;

  /// Consecutive sub-threshold readings, per board.
  final Map<String, int> _belowCounts = {};

  /// When each board was last warned about, so a flat pack reminds rather than
  /// repeats. Kept in memory only; the native side holds the copy that has to
  /// survive the app being closed, and has the last word on whether a warning
  /// is due (see [post]).
  final Map<String, DateTime> _lastWarned = {};

  /// Where a board starts, taken from the configured pack's chemistry.
  double get defaultThresholdVolts => _defaultThresholdVolts;

  /// What one board does, whether or not it has ever been touched.
  DeviceAlertSetting settingFor(String deviceId) =>
      _settings[deviceId] ??
      DeviceAlertSetting.defaults(_defaultThresholdVolts);

  /// True once this board has an answer of its own, rather than the default.
  bool hasOwnSetting(String deviceId) => _settings.containsKey(deviceId);

  /// How many consecutive low readings a board is currently on.
  @visibleForTesting
  int belowCount(String deviceId) => _belowCounts[deviceId] ?? 0;

  // MARK: Editing

  /// Turn the warning on or off for one board.
  ///
  /// Asks for the notification permission on the way on, because a switch that
  /// says "on" while Android silently drops every notification is worse than
  /// one that never moved.
  Future<void> setEnabled(String deviceId, bool enabled) async {
    _write(deviceId, settingFor(deviceId).copyWith(enabled: enabled));
    if (enabled) await requestPermission();
  }

  /// Set the voltage one board warns below.
  void setThreshold(String deviceId, double volts) {
    if (volts <= 0) return;
    _write(deviceId, settingFor(deviceId).copyWith(thresholdVolts: volts));
  }

  /// Set how long this board waits before it may warn again.
  void setRepeatAfter(String deviceId, Duration repeatAfter) {
    if (repeatAfter <= Duration.zero) return;
    _write(deviceId, settingFor(deviceId).copyWith(repeatAfter: repeatAfter));
  }

  /// Hand a board back to the default for the configured pack.
  void useDefault(String deviceId) {
    if (_settings.remove(deviceId) == null) return;
    _forget(deviceId);
    notifyListeners();
    _persist();
  }

  /// Take the starting threshold from the working configuration.
  ///
  /// Only ever moves boards that have no answer of their own, so a board that
  /// was set to 3.2 V stays at 3.2 V when the chemistry dropdown changes.
  void setDefaultThreshold(double volts) {
    if (volts <= 0 || volts == _defaultThresholdVolts) return;
    _defaultThresholdVolts = volts;
    // Readings counted against the old line say nothing about the new one.
    for (final id in _belowCounts.keys.toList()) {
      if (!_settings.containsKey(id)) _forget(id);
    }
    notifyListeners();
    _persist();
  }

  /// Stop tracking a board — used when its log is deleted, so a board the user
  /// has thrown away stops warning about a pack nobody has any more.
  void forgetDevice(String deviceId) {
    _settings.remove(deviceId);
    _forget(deviceId);
    notifyListeners();
    _persist();
  }

  Future<bool> requestPermission() async {
    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  // MARK: The rule

  /// Feed one reading. Returns true when this reading asked for a warning.
  ///
  /// "Asked for", not "showed": the native side owns the repeat window that
  /// both this and the background scan are judged against, because it is the
  /// only copy that survives the app being closed. This gate is the same rule
  /// applied early, so a run of low readings inside one session does not make
  /// a channel call per sample.
  Future<bool> ingest({
    required String deviceId,
    required String deviceName,
    required double volts,
    DateTime? now,
  }) async {
    final setting = settingFor(deviceId);
    if (!setting.enabled || setting.thresholdVolts <= 0) return false;

    if (volts >= setting.thresholdVolts) {
      // A run only counts while it is unbroken; the repeat window is not
      // touched, so a pack that dips, recovers and sags again still waits.
      _belowCounts.remove(deviceId);
      return false;
    }

    // Clamped rather than counted upwards: once a board is over the line, the
    // question is only whether the window has passed, and an unbounded counter
    // on a board that has been flat for a week means nothing extra.
    final count = _belowCounts[deviceId] ?? 0;
    if (count < samplesBeforeAlert) {
      _belowCounts[deviceId] = count + 1;
      if (count + 1 < samplesBeforeAlert) return false;
    }

    final at = now ?? DateTime.now();
    final last = _lastWarned[deviceId];
    if (last != null && at.difference(last) < setting.repeatAfter) return false;

    _lastWarned[deviceId] = at;
    await post(LowBatteryAlert(
      deviceId: deviceId,
      deviceName: deviceName,
      volts: volts,
      thresholdVolts: setting.thresholdVolts,
      repeatAfter: setting.repeatAfter,
    ));
    return true;
  }

  /// Forget what every board was doing — when a monitoring session ends, say.
  /// A run of low readings means nothing once the readings stop.
  ///
  /// Leaves the repeat windows alone: reopening a screen must not be a way to
  /// make an already-warned board warn again.
  void reset() {
    _belowCounts.clear();
  }

  // MARK: Persistence

  /// Bring back what the user chose, and re-push it to the native side in case
  /// the app was reinstalled over a service that had stale settings.
  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final defaultVolts = (decoded['default'] as num?)?.toDouble();
          if (defaultVolts != null && defaultVolts > 0) {
            _defaultThresholdVolts = defaultVolts;
          }
          final devices = decoded['devices'];
          if (devices is Map<String, dynamic>) {
            for (final entry in devices.entries) {
              final value = entry.value;
              if (value is Map<String, dynamic>) {
                _settings[entry.key] = DeviceAlertSetting.fromJson(value);
              }
            }
          }
        }
      }
    } catch (_) {
      // A corrupt file costs the user their choices, not their app.
    }
    notifyListeners();
    await _pushSettings();
  }

  void _write(String deviceId, DeviceAlertSetting setting) {
    if (_settings[deviceId] == setting) return;
    _settings[deviceId] = setting;
    _forget(deviceId);
    notifyListeners();
    _persist();
  }

  /// Drop a board's run and its repeat window, so the next reading starts a
  /// fresh count against whatever the threshold now is — and a board just
  /// switched on, or moved to a new threshold, can warn without waiting out a
  /// window it earned under the old one.
  void _forget(String deviceId) {
    _belowCounts.remove(deviceId);
    _lastWarned.remove(deviceId);
    _clearNativeWindow(deviceId);
  }

  Future<void> _clearNativeWindow(String deviceId) async {
    try {
      await _channel.invokeMethod('clearLowBatteryWindow', {
        'deviceId': deviceId,
      });
    } on MissingPluginException {
      // No native side; the in-memory window above is all there is.
    } catch (_) {
      // Worst case the board waits out the rest of its old window.
    }
  }

  Map<String, dynamic> _asJson() => {
        'default': _defaultThresholdVolts,
        'devices': {
          for (final entry in _settings.entries) entry.key: entry.value.toJson(),
        },
      };

  Future<void> _persist() async {
    final encoded = jsonEncode(_asJson());
    await _pushSettings(encoded);
    try {
      final file = await _file();
      await file.writeAsString(encoded, flush: true);
    } catch (_) {
      // The in-memory map is what the UI reads; a failed write costs the
      // choice on the next launch, nothing sooner.
    }
  }

  Future<File> _file() async {
    // Same directory the native side writes its beacon log to
    // (context.getFilesDir()).
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  /// Hand the settings to the native side, so a sighting logged while the app
  /// is closed is judged exactly the way a live sample is.
  Future<void> _pushSettings([String? encoded]) async {
    try {
      await _channel.invokeMethod('setLowBatteryAlerts', {
        'settings': encoded ?? jsonEncode(_asJson()),
        'samples': samplesBeforeAlert,
      });
    } on MissingPluginException {
      // No native side (tests, desktop): the foreground path still works.
    } catch (_) {
      // Never let a settings push break a switch the user just tapped.
    }
  }

  static Future<void> _postNative(LowBatteryAlert alert) async {
    try {
      await _channel.invokeMethod('postLowBatteryAlert', {
        'deviceId': alert.deviceId,
        'deviceName': alert.deviceName,
        'title': alert.title,
        'body': alert.body,
        'repeatMinutes': alert.repeatAfter.inMinutes,
      });
    } on MissingPluginException {
      // Nothing to post to.
    } catch (_) {
      // A dropped notification must not take the reading pipeline with it.
    }
  }
}
