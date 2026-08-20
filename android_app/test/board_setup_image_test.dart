import 'package:battery_holder/models/board_setup.dart';
import 'package:battery_holder/models/calibration_image.dart';
import 'package:battery_holder/models/device_status.dart';
import 'package:battery_holder/models/pin_configuration.dart';
import 'package:battery_holder/services/firmware_bundle_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show previewESP32;

/// The image is the whole setup.
///
/// A board used to come off the cable in `pairing` mode: the calibration region
/// described the hardware but said nothing about behaviour, so the run mode was
/// set afterwards by a serial command that a native-USB board routinely never
/// received. The board then advertised itself as unprovisioned and the app
/// asked, over Bluetooth, the same question the user had already answered.
/// These tests pin the fix — everything the firmware needs to claim itself is
/// in the bytes that get written.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = PinConfiguration.makeDefault(
    board: previewESP32,
    pin: previewESP32.recommendedBatteryPin!,
  );

  group('BoardSetup in the calibration payload', () {
    test('carries the run mode the firmware reads out of the power block', () {
      final image = CalibrationImage(
        config: config,
        stamp: 1755600000,
        setup: const BoardSetup(mode: RunMode.ble),
      );

      final power = image.payload['power'] as Map<String, dynamic>;
      expect(power['mode'], 'ble');
      // applyPowerJson() persists the whole block, so the interval has to be in
      // there too or the board would take the compiled-in default.
      expect(power['bleWakeSec'], 300);
    });

    test('carries the interval the user picked, in the field for its mode', () {
      const bluetooth = BoardSetup(mode: RunMode.ble);
      const cloud = BoardSetup(mode: RunMode.wifi, ssid: 'home-2g');

      final bleImage = CalibrationImage(
        config: config,
        stamp: 1,
        setup: bluetooth.withInterval(3600),
      );
      final wifiImage = CalibrationImage(
        config: config,
        stamp: 1,
        setup: cloud.withInterval(30),
      );

      expect((bleImage.payload['power'] as Map)['bleWakeSec'], 3600);
      expect((wifiImage.payload['power'] as Map)['wifiReportSec'], 30);
    });

    test('every offered interval survives the round trip through flash', () {
      // The picker is a menu, not a constraint — but an option the region
      // cannot carry would be a lie on screen.
      for (final seconds in PowerConfig.intervalOptions) {
        final image = CalibrationImage(
          config: config,
          stamp: 1755600000,
          setup: const BoardSetup(mode: RunMode.ble).withInterval(seconds),
        );
        final parsed = CalibrationImage.parse(image.build());
        expect(parsed, isNotNull, reason: '$seconds s failed to parse back');
        expect((parsed!.json['power'] as Map)['bleWakeSec'], seconds);
      }
    });

    test('Wi-Fi credentials ride along, and only in Wi-Fi mode', () {
      final cloud = CalibrationImage(
        config: config,
        stamp: 1,
        setup: const BoardSetup(
            mode: RunMode.wifi, ssid: '  home-2g  ', password: 'hunter2'),
      ).payload;
      expect(cloud['ssid'], 'home-2g'); // trimmed, or the board joins nothing
      expect(cloud['password'], 'hunter2');

      final bluetooth = CalibrationImage(
        config: config,
        stamp: 1,
        setup: const BoardSetup(mode: RunMode.ble, ssid: 'home-2g'),
      ).payload;
      expect(bluetooth.containsKey('ssid'), isFalse);
      expect(bluetooth.containsKey('password'), isFalse);
    });

    test('a board with no setup stays unclaimed rather than guessing', () {
      final payload = CalibrationImage(config: config, stamp: 1).payload;
      expect(payload.containsKey('power'), isFalse);
    });

    test('the sensing chain is untouched by any of this', () {
      final image = CalibrationImage(
        config: config,
        stamp: 1755600000,
        setup: const BoardSetup(mode: RunMode.wifi, ssid: 'home-2g'),
      );
      final parsed = CalibrationImage.parse(image.build());
      expect(parsed!.batteryPinId, 'gpio34');
      expect(parsed.stamp, 1755600000);
    });
  });

  group('BoardSetup', () {
    test('a Wi-Fi board with no network named is not flashable', () {
      expect(const BoardSetup(mode: RunMode.wifi).isComplete, isFalse);
      expect(const BoardSetup(mode: RunMode.wifi, ssid: '   ').isComplete,
          isFalse);
      expect(const BoardSetup(mode: RunMode.wifi, ssid: 'home-2g').isComplete,
          isTrue);
      // Bluetooth needs nothing typed at all — that is the whole point of it.
      expect(const BoardSetup(mode: RunMode.ble).isComplete, isTrue);
    });

    test('a mode the board has no radio for is corrected, not kept', () {
      // previewESP32 speaks both; an 8266 has no BLE at all, and offering it
      // would offer a mode the board could never enter.
      expect(const BoardSetup(mode: RunMode.ble).forBoard(previewESP32).mode,
          RunMode.ble);
    });

    test('only pairing mode means the board still needs the wizard', () {
      expect(const BoardSetup(mode: RunMode.ble).isProvisioned, isTrue);
      expect(const BoardSetup(mode: RunMode.wifi).isProvisioned, isTrue);
      expect(const BoardSetup(mode: RunMode.pairing).isProvisioned, isFalse);
    });
  });

  group('FlashPlan', () {
    late FirmwareBundleRepository repo;

    setUp(() => repo = FirmwareBundleRepository());

    test('reports the mode the board will boot into', () async {
      final plan = await repo.buildPlan(
        boardId: 'esp32-wroom',
        config: config,
        setup: const BoardSetup(mode: RunMode.ble),
      );
      expect(plan.bootMode, RunMode.ble);
      expect((plan.calibrationPayload['power'] as Map)['mode'], 'ble');
    });

    test('a plan built without a setup boots unclaimed', () async {
      final plan =
          await repo.buildPlan(boardId: 'esp32-wroom', config: config);
      expect(plan.bootMode, RunMode.pairing);
    });
  });

  group('Wake intervals', () {
    test('read as a person would say them', () {
      expect(PowerConfig.intervalLabel(30), '30 s');
      expect(PowerConfig.intervalLabel(60), '1 min');
      expect(PowerConfig.intervalLabel(900), '15 min');
      expect(PowerConfig.intervalLabel(3600), '1 h');
      expect(PowerConfig.intervalLabel(86400), '1 d');
    });

    test('the list is sorted and free of duplicates', () {
      final options = PowerConfig.intervalOptions;
      expect(options, options.toSet().toList());
      for (var i = 1; i < options.length; i++) {
        expect(options[i], greaterThan(options[i - 1]));
      }
      // The firmware refuses anything under a second and the app should never
      // be able to ask for it.
      expect(options.first, greaterThanOrEqualTo(1));
    });
  });
}
