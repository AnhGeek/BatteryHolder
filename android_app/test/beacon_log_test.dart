import 'package:battery_holder/models/beacon_log.dart';
import 'package:battery_holder/services/beacon_log_store.dart';
import 'package:flutter_test/flutter_test.dart';

BeaconLogEntry entry(
  String id,
  DateTime t, {
  double? volts,
  int? soc,
  int flags = 0,
  String name = 'BH-d08c',
  int rssi = -70,
}) =>
    BeaconLogEntry(
      timestamp: t,
      deviceId: id,
      name: name,
      rssi: rssi,
      volts: volts,
      soc: soc,
      flags: flags,
    );

void main() {
  group('BeaconLogEntry', () {
    test('round-trips through the compact JSON the service writes', () {
      final original = entry(
        'AA:BB:CC:DD:EE:FF',
        DateTime.fromMillisecondsSinceEpoch(1755000000000),
        volts: 3.94,
        soc: 78,
        flags: 0x03,
      );
      final decoded = BeaconLogEntry.fromJson(original.toJson());

      expect(decoded.deviceId, original.deviceId);
      expect(decoded.timestamp, original.timestamp);
      expect(decoded.volts, 3.94);
      expect(decoded.soc, 78);
      expect(decoded.rssi, -70);
      expect(decoded.flags, 0x03);
    });

    test('decodes the documented flag bits', () {
      final e = entry('x', DateTime(2026), flags: 0x0B); // 1011
      expect(e.provisioned, isTrue); // 0x01
      expect(e.wifiMode, isTrue); // 0x02
      expect(e.pairingMode, isFalse); // 0x04
      expect(e.wifiOnline, isTrue); // 0x08
    });

    test('omits absent volts and soc rather than writing nulls', () {
      final json = entry('x', DateTime(2026)).toJson();
      expect(json.containsKey('v'), isFalse);
      expect(json.containsKey('s'), isFalse);
    });

    test('a row written before a board reported volts still parses', () {
      final decoded = BeaconLogEntry.fromJson({
        't': 1755000000000,
        'id': 'AA:BB',
        'n': 'BH-0001',
        'r': -80,
        'f': 0,
      });
      expect(decoded.volts, isNull);
      expect(decoded.soc, isNull);
      expect(decoded.deviceId, 'AA:BB');
    });
  });

  group('KnownDevice.rollUp', () {
    final t0 = DateTime(2026, 8, 19, 12, 0);

    test('one row per board, carrying the newest reading', () {
      final devices = KnownDevice.rollUp([
        entry('a', t0, volts: 3.9, soc: 70),
        entry('a', t0.add(const Duration(minutes: 5)), volts: 3.8, soc: 66),
        entry('b', t0.add(const Duration(minutes: 1)), volts: 4.1, soc: 95),
      ]);

      expect(devices.length, 2);
      final a = devices.firstWhere((d) => d.deviceId == 'a');
      expect(a.volts, 3.8, reason: 'newest entry wins');
      expect(a.soc, 66);
      expect(a.entryCount, 2);
    });

    test('sorts most recently seen first', () {
      final devices = KnownDevice.rollUp([
        entry('old', t0),
        entry('new', t0.add(const Duration(hours: 1))),
      ]);
      expect(devices.first.deviceId, 'new');
    });

    test('input order does not matter', () {
      final ordered = KnownDevice.rollUp([
        entry('a', t0),
        entry('a', t0.add(const Duration(minutes: 5)), volts: 3.5),
      ]);
      final reversed = KnownDevice.rollUp([
        entry('a', t0.add(const Duration(minutes: 5)), volts: 3.5),
        entry('a', t0),
      ]);
      expect(ordered.single.volts, reversed.single.volts);
      expect(ordered.single.lastSeen, reversed.single.lastSeen);
    });

    test('falls back to the address when a board advertised no name', () {
      final devices = KnownDevice.rollUp([entry('AA:BB', t0, name: '')]);
      expect(devices.single.name, 'AA:BB');
    });

    test('an empty log yields no devices', () {
      expect(KnownDevice.rollUp([]), isEmpty);
    });
  });

  group('BeaconLogStore.clearDevice', () {
    test('drops one board and leaves the others alone', () async {
      // No path_provider under `flutter test`, so the file write fails and is
      // swallowed; the in-memory list is what the UI reads either way.
      final store = BeaconLogStore();
      final t = DateTime.fromMillisecondsSinceEpoch(1755000000000);
      await store.append(entry('AA:BB:CC:DD:EE:FF', t, volts: 3.9));
      await store.append(entry('11:22:33:44:55:66', t, volts: 4.1));
      await store.append(entry('AA:BB:CC:DD:EE:FF', t, volts: 3.8));
      expect(store.entries, hasLength(3));

      await store.clearDevice('AA:BB:CC:DD:EE:FF');

      expect(store.entriesFor('AA:BB:CC:DD:EE:FF'), isEmpty);
      expect(store.entriesFor('11:22:33:44:55:66'), hasLength(1));
      expect(store.entries, hasLength(1));
    });
  });
}
