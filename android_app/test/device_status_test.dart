import 'package:battery_holder/models/device_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceStatus', () {
    // The example object from DEVICE_PROTOCOL.md §2.3, verbatim.
    const sample = {
      'ev': 'wifi',
      'detail': 'connected',
      'id': 'bh-a1b2c3d4e5f6',
      'fw': '2.0.0',
      'mode': 'wifi',
      'prov': true,
      'raw': 2731,
      'volts': 3.94,
      'soc': 78,
      'boot': 42,
      'wifi': 'online',
      'ip': '192.168.1.42',
      'rssi': -56,
      'ssid': 'home-2g',
      'cloud': true,
      'sleepInMs': 12400,
      'nextWakeSec': 900,
    };

    test('decodes the documented payload', () {
      final s = DeviceStatus.fromJson(sample);
      expect(s.id, 'bh-a1b2c3d4e5f6');
      expect(s.fw, '2.0.0');
      expect(s.mode, RunMode.wifi);
      expect(s.provisioned, isTrue);
      expect(s.volts, 3.94);
      expect(s.soc, 78);
      expect(s.ip, '192.168.1.42');
      expect(s.cloud, isTrue);
      expect(s.nextWakeSec, 900);
    });

    test('eventPath joins ev and detail for sequence matching', () {
      expect(DeviceStatus.fromJson(sample).eventPath, 'wifi/connected');
      expect(
        DeviceStatus.fromJson({'ev': 'sleeping'}).eventPath,
        'sleeping',
      );
    });

    test('a sleeping push is recognised, not treated as an error', () {
      final s = DeviceStatus.fromJson({'ev': 'sleeping', 'mode': 'ble'});
      expect(s.isSleeping, isTrue);
    });

    test('negative sleepInMs means sleeping is held off', () {
      expect(DeviceStatus.fromJson({'sleepInMs': -1}).sleepHeld, isTrue);
      expect(DeviceStatus.fromJson({'sleepInMs': 5000}).sleepHeld, isFalse);
    });

    test('an empty object is safe — every field is optional', () {
      final s = DeviceStatus.fromJson({});
      expect(s.mode, RunMode.pairing);
      expect(s.provisioned, isFalse);
      expect(s.volts, isNull);
      expect(s.isSleeping, isFalse);
    });

    test('an unknown mode falls back to pairing rather than throwing', () {
      expect(DeviceStatus.fromJson({'mode': 'banana'}).mode, RunMode.pairing);
    });

    test('led capability drives what Identify is allowed to promise', () {
      expect(DeviceStatus.fromJson({'led': false}).hasLed, isFalse);
      expect(DeviceStatus.fromJson({'led': true}).hasLed, isTrue);
      // Firmware that predates the field is assumed to have an LED, so the
      // button keeps working rather than being wrongly greyed out.
      expect(DeviceStatus.fromJson({}).hasLed, isTrue);
    });
  });

  group('RunMode', () {
    test('wire values match SET_MODE (0=pairing 1=ble 2=wifi)', () {
      expect(RunMode.pairing.wireValue, 0);
      expect(RunMode.ble.wireValue, 1);
      expect(RunMode.wifi.wireValue, 2);
    });

    test('names match the provisioning payload', () {
      expect(RunMode.ble.name, 'ble');
      expect(RunMode.wifi.name, 'wifi');
    });
  });

  group('PowerConfig', () {
    test('defaults match the documented power block', () {
      const p = PowerConfig();
      expect(p.sleepEnabled, isTrue);
      expect(p.bleWakeSec, 300);
      expect(p.bleWindowMs, 20000);
      expect(p.bleIdleMs, 60000);
      expect(p.wifiReportSec, 900);
      expect(p.wifiWindowMs, 15000);
      expect(p.bleInWifi, isFalse);
    });

    test('round-trips through JSON', () {
      const p = PowerConfig(bleWakeSec: 60, sleepEnabled: false);
      expect(PowerConfig.fromJson(p.toJson()).bleWakeSec, 60);
      expect(PowerConfig.fromJson(p.toJson()).sleepEnabled, isFalse);
    });

    test('the applicable interval depends on the mode', () {
      const p = PowerConfig(bleWakeSec: 300, wifiReportSec: 900);
      expect(p.intervalSecFor(RunMode.ble), 300);
      expect(p.intervalSecFor(RunMode.wifi), 900);
    });
  });
}
