import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_holder/models/calibration_image.dart';
import 'package:battery_holder/models/pin_configuration.dart';
import 'package:battery_holder/services/firmware_bundle_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show previewESP32;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = PinConfiguration.makeDefault(
    board: previewESP32,
    pin: previewESP32.recommendedBatteryPin!,
  );

  group('CalibrationImage', () {
    test('round-trips through the on-flash layout', () {
      final image = CalibrationImage(config: config, stamp: 1755600000);
      final bytes = image.build();

      final view = ByteData.view(bytes.buffer);
      expect(view.getUint32(0, Endian.little), CalibrationImage.magic);
      expect(view.getUint16(4, Endian.little), CalibrationImage.formatVersion);
      expect(view.getUint32(8, Endian.little), bytes.length - 16);

      final parsed = CalibrationImage.parse(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.batteryPinId, 'gpio34');
      expect(parsed.stamp, 1755600000);
    });

    test('the CRC is the standard one the firmware computes', () {
      // Checked against zlib.crc32(b"123456789") — the canonical CRC-32 check
      // value, which is the polynomial `crc32Buf()` uses in both sketches.
      expect(CalibrationImage.crc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('a corrupted payload is rejected rather than half-applied', () {
      final bytes = CalibrationImage(config: config, stamp: 42).build();
      bytes[20] = bytes[20] ^ 0xFF; // flip a byte inside the JSON
      expect(CalibrationImage.parse(bytes), isNull);
    });

    test('a board with no name given keeps its MAC-derived one', () {
      // An absent key is how the firmware is told to name itself BH-xxxx; an
      // empty string would be a name, and a wrong one.
      final unnamed = CalibrationImage(config: config, stamp: 1).payload;
      expect(unnamed.containsKey('deviceName'), isFalse);

      final named = CalibrationImage(
        config: config.copyWith(deviceName: (value: 'Garage pack')),
        stamp: 1,
      ).payload;
      expect(named['deviceName'], 'Garage pack');

      final cleared = config
          .copyWith(deviceName: (value: 'Garage pack'))
          .copyWith(deviceName: const (value: null));
      expect(cleared.deviceName, isNull,
          reason: 'clearing the name has to hand it back to the automatic one');
    });

    test('carries the board wiring only when it has been set', () {
      // An absent key means "keep the firmware's own default", which is not the
      // same as sending -1 ("this board has none").
      final plain = CalibrationImage(config: config, stamp: 1).payload;
      expect(plain.containsKey('statusLedPin'), isFalse);
      expect(plain.containsKey('wakeButtonPin'), isFalse);

      final wired = CalibrationImage(
        config: config.copyWith(
          statusLedPin: (value: 19),
          statusLedActiveLow: (value: true),
          wakeButtonPin: (value: -1),
        ),
        stamp: 1,
      ).payload;
      expect(wired['statusLedPin'], 19);
      expect(wired['statusLedActiveLow'], isTrue);
      expect(wired['wakeButtonPin'], -1);
    });

    test('wiring overrides can be cleared back to the board default', () {
      final wired = config.copyWith(statusLedPin: (value: 19));
      expect(wired.statusLedPin, 19);

      final cleared = wired.copyWith(statusLedPin: const (value: null));
      expect(cleared.statusLedPin, isNull,
          reason: 'clearing has to be expressible, not just overwriting');
    });

    test('carries the settings the board needs to read its own battery', () {
      final payload = CalibrationImage(config: config, stamp: 1).payload;
      expect(payload['batteryPinId'], 'gpio34');
      expect(payload['dividerR1KOhm'], 100);
      expect(payload['dividerR2KOhm'], 100);
      expect(payload['calibrationFactor'], 1.0);
      expect(payload['chemistry'], 'lipo');
      expect(payload['stamp'], 1);
    });
  });

  group('bundled firmware', () {
    final repo = FirmwareBundleRepository();

    test('ships an image set for every board in the catalog', () async {
      final manifest = await repo.manifest();

      expect(manifest.bundles, isNotEmpty,
          reason: 'run tools/build_firmware.py to stage assets/firmware/');
      expect(manifest.firmwareVersion, isNotEmpty);
      for (final id in const [
        'esp32-wroom',
        'esp32c3-devkit',
        'esp8266-nodemcu',
        'esp8266-d1mini',
      ]) {
        expect(manifest.bundleFor(id), isNotNull, reason: 'missing $id');
      }
    });

    test('every ESP32 bundle reserves a calibration region outside the app',
        () async {
      final manifest = await repo.manifest();
      final board = manifest.bundleFor('esp32-wroom')!;

      final app = board.parts.firstWhere((p) => p.file == 'firmware.bin');
      expect(board.calibration.size, greaterThanOrEqualTo(4096));
      expect(board.calibration.offset, greaterThan(app.offset + app.size),
          reason: 'the calibration must not overlap the program image');
      expect(board.eraseRegions, isNotEmpty,
          reason: 'flashing has to be able to blank the saved settings');
    });

    test('builds a plan whose bytes match the shipped images', () async {
      final plan = await repo.buildPlan(
        boardId: 'esp32-wroom',
        config: config,
      );

      final labels = plan.segments.map((s) => s.label).toList();
      // Settings are blanked first and the calibration lands last, once the
      // firmware that reads it is already in place.
      expect(labels.first, 'nvs');
      expect(labels.last, 'calibration');
      expect(labels, contains('bootloader'));
      expect(labels, contains('app'));

      final app = plan.segments.firstWhere((s) => s.label == 'app');
      final manifestPart = plan.bundle.parts
          .firstWhere((p) => p.file == 'firmware.bin');
      expect(app.size, manifestPart.size);
      expect(app.offset, manifestPart.offset);
      expect(app.md5, manifestPart.md5);

      final calibration =
          plan.segments.firstWhere((s) => s.label == 'calibration');
      expect(calibration.offset, plan.bundle.calibration.offset);
      expect(CalibrationImage.parse(calibration.data)?.batteryPinId, 'gpio34');
    });

    test('blanked regions are marked, so an audit can skip them', () async {
      // NVS stops reading back as 0xFF the moment the board runs, so checking
      // it against the plan would fail on any board that has been up.
      final plan =
          await repo.buildPlan(boardId: 'esp32-wroom', config: config);
      final blank = plan.segments.where((s) => s.blank).map((s) => s.label);
      expect(blank, ['nvs']);
      expect(
          plan.segments
              .firstWhere((s) => s.label == 'calibration')
              .blank,
          isFalse);
    });

    test('leaves the settings alone when asked to', () async {
      final plan = await repo.buildPlan(
        boardId: 'esp32-wroom',
        config: config,
        eraseSavedSettings: false,
      );
      expect(plan.segments.map((s) => s.label), isNot(contains('nvs')));
    });

    test('no two segments overlap in flash', () async {
      final plan =
          await repo.buildPlan(boardId: 'esp32-wroom', config: config);
      final sorted = [...plan.segments]
        ..sort((a, b) => a.offset.compareTo(b.offset));
      for (var i = 1; i < sorted.length; i++) {
        expect(sorted[i].offset,
            greaterThanOrEqualTo(sorted[i - 1].offset + sorted[i - 1].size),
            reason: '${sorted[i].label} overlaps ${sorted[i - 1].label}');
      }
    });

    test('a board with no bundled firmware says so plainly', () async {
      await expectLater(
        repo.buildPlan(boardId: 'not-a-board', config: config),
        throwsA(isA<FirmwareBundleException>().having(
            (e) => e.message, 'message', contains('build_firmware.py'))),
      );
    });
  });
}
