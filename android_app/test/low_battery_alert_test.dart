import 'package:battery_holder/models/board.dart';
import 'package:battery_holder/models/device_alert_setting.dart';
import 'package:battery_holder/models/pin.dart';
import 'package:battery_holder/models/pin_configuration.dart';
import 'package:battery_holder/services/low_battery_alerts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pin = Pin(
  id: 'gpio34',
  name: 'GPIO34',
  gpio: 34,
  inputOnly: true,
  wifiSafeADC: true,
  capabilities: [PinCapability.adc],
);

final _board = Board(
  id: 'esp32-wroom',
  name: 'ESP32 WROOM',
  chip: Chip.esp32,
  summary: 'test board',
  adcResolutionBits: 12,
  adcRefVoltage: 3.3,
  supportedTransports: const [FlashTransport.ble],
  pins: const [_pin],
);

PinConfiguration _config() =>
    PinConfiguration.makeDefault(board: _board, pin: _pin);

/// Records what would have been posted, so the rule can be tested without a
/// platform to post to.
class _Recorder {
  final posted = <LowBatteryAlert>[];
  Future<void> call(LowBatteryAlert alert) async => posted.add(alert);
}

/// A monitor with the default threshold the shipped 1S LiPo config implies.
({LowBatteryAlerts alerts, _Recorder recorder}) _monitor() {
  final recorder = _Recorder();
  final alerts = LowBatteryAlerts(post: recorder.call)
    ..setDefaultThreshold(_config().defaultLowBatteryVolts);
  return (alerts: alerts, recorder: recorder);
}

/// Feeds [count] readings of [volts] through the monitor, all at [at].
Future<void> _feed(
  LowBatteryAlerts alerts,
  double volts,
  int count, {
  String deviceId = 'aa:bb',
  DateTime? at,
}) async {
  for (var i = 0; i < count; i++) {
    await alerts.ingest(
      deviceId: deviceId,
      deviceName: 'BH-test',
      volts: volts,
      now: at,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('store.lyhoanganh.battery_holder/alerts');
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('defaults', () {
    test('a board nobody has touched is watched, at the pack default', () {
      final (:alerts, :recorder) = _monitor();
      final setting = alerts.settingFor('never-seen');

      expect(setting.enabled, isTrue);
      expect(setting.thresholdVolts, closeTo(3.50, 0.001)); // 1S LiPo
      expect(setting.repeatAfter, const Duration(hours: 2));
      expect(alerts.hasOwnSetting('never-seen'), isFalse);
      expect(recorder.posted, isEmpty);
    });

    test('the default follows the pack it describes', () {
      final pack = _config().copyWith(
        chemistry: BatteryChemistry.lead,
        cellCount: 6,
      );
      // A 12 V lead-acid pack must not inherit the 3.5 V a 1S LiPo implies.
      expect(pack.defaultLowBatteryVolts, closeTo(11.10, 0.001));
    });

    test('a board with its own threshold ignores a moved default', () {
      final (:alerts, :recorder) = _monitor();
      alerts.setThreshold('aa:bb', 3.2);

      alerts.setDefaultThreshold(11.10);

      expect(alerts.settingFor('aa:bb').thresholdVolts, 3.2);
      expect(alerts.settingFor('cc:dd').thresholdVolts, 11.10);
    });

    test('"use default" hands a board back', () {
      final (:alerts, :recorder) = _monitor();
      alerts.setThreshold('aa:bb', 3.2);
      expect(alerts.hasOwnSetting('aa:bb'), isTrue);

      alerts.useDefault('aa:bb');
      expect(alerts.hasOwnSetting('aa:bb'), isFalse);
      expect(alerts.settingFor('aa:bb').thresholdVolts, closeTo(3.50, 0.001));
    });

    test('the setting stays out of the wire format the board parses', () {
      // Nothing about warnings reaches the firmware; this is a phone feature.
      final json = _config().toJson();
      expect(json.keys, isNot(contains('lowBatteryAlertEnabled')));
      expect(json.keys, isNot(contains('lowBatteryVolts')));
    });
  });

  group('the five-sample rule', () {
    test('four low readings are not enough to warn', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 4);
      expect(recorder.posted, isEmpty);
    });

    test('the fifth low reading in a row warns', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5);

      expect(recorder.posted, hasLength(1));
      expect(recorder.posted.single.volts, 3.4);
      expect(recorder.posted.single.thresholdVolts, closeTo(3.50, 0.001));
      expect(recorder.posted.single.repeatAfter, const Duration(hours: 2));
      expect(recorder.posted.single.body, contains('BH-test'));
    });

    // A pack under load dips and an ADC is noisy, so a run broken by a healthy
    // reading was never a flat pack.
    test('one healthy reading resets the run', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 4);
      await _feed(alerts, 3.9, 1);
      expect(alerts.belowCount('aa:bb'), 0);

      await _feed(alerts, 3.4, 4);
      expect(recorder.posted, isEmpty);
    });

    test('two boards are counted, and warned about, separately', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 3, deviceId: 'aa');
      await _feed(alerts, 3.4, 5, deviceId: 'bb');
      expect(recorder.posted.map((a) => a.deviceId), ['bb']);

      await _feed(alerts, 3.4, 2, deviceId: 'aa');
      expect(recorder.posted.map((a) => a.deviceId), ['bb', 'aa']);
    });

    test('a board switched off never warns', () async {
      final (:alerts, :recorder) = _monitor();
      await alerts.setEnabled('aa:bb', false);

      await _feed(alerts, 3.0, 20);
      expect(recorder.posted, isEmpty);

      // ...and its neighbour is untouched.
      await _feed(alerts, 3.0, 5, deviceId: 'cc:dd');
      expect(recorder.posted, hasLength(1));
    });

    test('a moved threshold starts the count over', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 4);

      // Readings counted against 3.50 V say nothing about 3.45 V.
      alerts.setThreshold('aa:bb', 3.45);
      expect(alerts.belowCount('aa:bb'), 0);

      await _feed(alerts, 3.4, 4);
      expect(recorder.posted, isEmpty);
      await _feed(alerts, 3.4, 1);
      expect(recorder.posted, hasLength(1));
      expect(recorder.posted.single.thresholdVolts, 3.45);
    });
  });

  group('the repeat window', () {
    final start = DateTime(2026, 8, 24, 9);

    test('a pack that stays flat is not warned about again inside it',
        () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5, at: start);
      expect(recorder.posted, hasLength(1));

      // Still flat an hour later is not news yet.
      await _feed(alerts, 3.4, 20,
          at: start.add(const Duration(hours: 1, minutes: 59)));
      expect(recorder.posted, hasLength(1));
    });

    test('once the window passes, the next low reading warns again', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5, at: start);

      // One reading is enough now — the run was never broken, so the board is
      // still five-deep; only the clock was holding it back.
      await _feed(alerts, 3.4, 1, at: start.add(const Duration(hours: 2)));
      expect(recorder.posted, hasLength(2));
    });

    test('a shorter window is honoured', () async {
      final (:alerts, :recorder) = _monitor();
      alerts.setRepeatAfter('aa:bb', const Duration(minutes: 30));

      await _feed(alerts, 3.4, 5, at: start);
      await _feed(alerts, 3.4, 1, at: start.add(const Duration(minutes: 29)));
      expect(recorder.posted, hasLength(1));

      await _feed(alerts, 3.4, 1, at: start.add(const Duration(minutes: 31)));
      expect(recorder.posted, hasLength(2));
    });

    // Reopening the board's page must not be a way to make it warn again.
    test('resetting the runs leaves the window standing', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5, at: start);

      alerts.reset();
      await _feed(alerts, 3.4, 5, at: start.add(const Duration(minutes: 5)));
      expect(recorder.posted, hasLength(1));
    });

    test('a pack that recovers still waits out its window', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5, at: start);

      await _feed(alerts, 4.1, 1, at: start.add(const Duration(minutes: 10)));
      await _feed(alerts, 3.4, 5, at: start.add(const Duration(minutes: 20)));
      expect(recorder.posted, hasLength(1));
    });

    test('changing a board’s settings lets it warn without waiting', () async {
      final (:alerts, :recorder) = _monitor();
      await _feed(alerts, 3.4, 5, at: start);

      // The user just moved the line; the pack should be judged against it now.
      alerts.setThreshold('aa:bb', 3.6);
      await _feed(alerts, 3.4, 5, at: start.add(const Duration(minutes: 1)));
      expect(recorder.posted, hasLength(2));
      expect(
        nativeCalls.where((c) => c.method == 'clearLowBatteryWindow'),
        isNotEmpty,
      );
    });
  });

  group('the native mirror', () {
    test('the background scan is given the per-board settings', () async {
      final alerts = LowBatteryAlerts(post: (_) async {})
        ..setDefaultThreshold(3.5);
      alerts.setThreshold('aa:bb', 3.2);
      await alerts.setEnabled('cc:dd', false);

      final push =
          nativeCalls.lastWhere((c) => c.method == 'setLowBatteryAlerts');
      final args = push.arguments as Map;
      expect(args['samples'], LowBatteryAlerts.samplesBeforeAlert);

      final settings = args['settings'] as String;
      expect(settings, contains('"default":3.5'));
      expect(settings, contains('"aa:bb"'));
      expect(settings, contains('3.2'));
      expect(settings, contains('"enabled":false'));
      expect(settings, contains('"repeatMinutes":120'));
    });

    test('a forgotten board is dropped from the mirror', () async {
      final alerts = LowBatteryAlerts(post: (_) async {})
        ..setDefaultThreshold(3.5);
      alerts.setThreshold('aa:bb', 3.2);

      alerts.forgetDevice('aa:bb');

      final push =
          nativeCalls.lastWhere((c) => c.method == 'setLowBatteryAlerts');
      expect((push.arguments as Map)['settings'], isNot(contains('aa:bb')));
    });
  });

  group('DeviceAlertSetting', () {
    test('survives a round trip through JSON', () {
      const setting = DeviceAlertSetting(
        enabled: false,
        thresholdVolts: 3.2,
        repeatAfter: Duration(hours: 6),
      );
      expect(
        DeviceAlertSetting.fromJson(setting.toJson()),
        setting,
      );
    });

    test('an older row with no window takes the default', () {
      final setting =
          DeviceAlertSetting.fromJson({'enabled': true, 'volts': 3.4});
      expect(setting.repeatAfter, DeviceAlertSetting.defaultRepeatAfter);
    });

    test('intervals read the way the row shows them', () {
      expect(DeviceAlertSetting.describe(const Duration(minutes: 30)), '30 min');
      expect(DeviceAlertSetting.describe(const Duration(hours: 2)), '2 h');
      expect(DeviceAlertSetting.describe(const Duration(days: 1)), '1 d');
    });
  });
}
