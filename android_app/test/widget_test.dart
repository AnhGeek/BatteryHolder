import 'package:battery_holder/design_system/components.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/models/board.dart';
import 'package:battery_holder/models/firmware_image.dart';
import 'package:battery_holder/models/pin.dart';
import 'package:battery_holder/models/pin_configuration.dart';
// `Chip` here is the board's chip family, not the Material widget.
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_test/flutter_test.dart';

/// Stand-in catalog entry so tests never depend on the bundled JSON — the
/// counterpart of `Board.previewESP32` on iOS.
final previewESP32 = Board(
  id: 'esp32-wroom',
  name: 'ESP32 DevKitC (WROOM-32)',
  chip: Chip.esp32,
  summary: 'Classic dual-core ESP32 with Wi-Fi and Bluetooth LE.',
  adcResolutionBits: 12,
  adcRefVoltage: 3.3,
  recommendedBatteryPinId: 'gpio34',
  supportedTransports: const [FlashTransport.ble, FlashTransport.wifi],
  pins: const [
    Pin(
      id: 'gpio34',
      name: 'GPIO34',
      gpio: 34,
      adcChannel: 'ADC1_CH6',
      adcUnit: 1,
      inputOnly: true,
      wifiSafeADC: true,
      capabilities: [PinCapability.adc, PinCapability.digitalIn],
      note: 'Input-only pin — ideal for battery sensing.',
    ),
    Pin(
      id: 'gpio25',
      name: 'GPIO25',
      gpio: 25,
      adcChannel: 'ADC2_CH8',
      adcUnit: 2,
      inputOnly: false,
      wifiSafeADC: false,
      capabilities: [PinCapability.adc, PinCapability.dac],
      note: 'ADC2 is unavailable while Wi-Fi is active.',
    ),
    Pin(
      id: 'gpio21',
      name: 'GPIO21 (SDA)',
      gpio: 21,
      inputOnly: false,
      wifiSafeADC: false,
      capabilities: [PinCapability.i2c],
    ),
  ],
);

void main() {
  group('Board', () {
    test('adcMaxCount follows the resolution', () {
      expect(previewESP32.adcMaxCount, 4095);
    });

    test('only ADC-capable pins are offered for battery sensing', () {
      expect(previewESP32.adcCapablePins.map((p) => p.id),
          ['gpio34', 'gpio25']);
    });

    test('resolves the recommended battery pin', () {
      expect(previewESP32.recommendedBatteryPin?.name, 'GPIO34');
    });
  });

  group('PinConfiguration', () {
    final config = PinConfiguration.makeDefault(
      board: previewESP32,
      pin: previewESP32.recommendedBatteryPin!,
    );

    test('a 100k/100k divider halves the measured voltage', () {
      expect(config.dividerRatio, 2.0);
    });

    test('full scale maps to twice the reference voltage', () {
      expect(config.voltageFromRawADC(4095), closeTo(6.6, 0.001));
    });

    test('percentage clamps to the chemistry range', () {
      // LiPo: 3.3 V empty, 4.2 V full, one cell.
      expect(config.percentageForVoltage(4.2), 1.0);
      expect(config.percentageForVoltage(3.3), 0.0);
      expect(config.percentageForVoltage(2.0), 0.0);
      expect(config.percentageForVoltage(3.75), closeTo(0.5, 0.001));
    });

    test('cell count scales the pack range', () {
      final twoCell = config.copyWith(cellCount: 2);
      expect(twoCell.percentageForVoltage(8.4), 1.0);
    });

    test('a meter reading back-solves the trim that matches it', () {
      // Half scale on a 2x divider reads 3.3 V uncalibrated; the meter says
      // the pack is really at 3.63, so the trim has to be 1.1.
      final factor =
          config.calibrationFactorForMeasured(raw: 2048, measuredVolts: 3.63);
      expect(factor, isNotNull);
      expect(factor!, closeTo(1.1, 0.001));

      final trimmed = config.copyWith(calibrationFactor: factor);
      expect(trimmed.voltageFromRawADC(2048), closeTo(3.63, 0.001));
    });

    test('a sample that says nothing yields no trim at all', () {
      // Any factor satisfies these, so inventing one would look like a
      // calibration that never happened.
      expect(config.calibrationFactorForMeasured(raw: 0, measuredVolts: 3.7),
          isNull);
      expect(config.calibrationFactorForMeasured(raw: 2048, measuredVolts: 0),
          isNull);
    });

    test('serializes with the keys the firmware expects', () {
      final json = config.toJson();
      expect(json['batteryPinId'], 'gpio34');
      expect(json['chemistry'], 'lipo');
      expect(json['adcResolutionBits'], 12);
    });
  });

  group('Battery color scale', () {
    const c = AppColor(false);

    test('maps percentage to the documented status color', () {
      expect(c.battery(0.92), c.batteryGood);
      expect(c.battery(0.45), c.batteryMedium);
      expect(c.battery(0.18), c.batteryLow);
      expect(c.battery(0.05), c.batteryCritical);
    });
  });

  group('FirmwareImage', () {
    test('formats sizes the way ByteCountFormatter does', () {
      FirmwareImage sized(int bytes) => FirmwareImage(
            buildId: 'b',
            boardId: 'esp32-wroom',
            version: '1.0.0',
            channel: FirmwareChannel.stable,
            sizeBytes: bytes,
            sha256: '',
            releaseNotes: '',
            createdAt: DateTime(2026),
          );

      expect(sized(512).sizeDisplay, '512 bytes');
      expect(sized(64000).sizeDisplay, '64 KB');
      expect(sized(1_200_000).sizeDisplay, '1.2 MB');
    });
  });

  group('Widgets', () {
    Widget host(Widget child) => MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(body: child),
        );

    testWidgets('SectionHeader renders title and subtitle', (tester) async {
      await tester.pumpWidget(
        host(const SectionHeader(title: 'Transport', subtitle: 'How it talks')),
      );
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('How it talks'), findsOneWidget);
    });

    testWidgets('PinChip shows the pin name and ADC channel', (tester) async {
      await tester.pumpWidget(
        host(PinChip(pin: previewESP32.pins.first, isSelected: true)),
      );
      expect(find.text('GPIO34'), findsOneWidget);
      expect(find.text('ADC1_CH6'), findsOneWidget);
    });

    testWidgets('SegmentedPicker reports the tapped option', (tester) async {
      FlashTransport? picked;
      await tester.pumpWidget(host(
        SegmentedPicker<FlashTransport>(
          options: FlashTransport.values,
          selection: FlashTransport.ble,
          labelOf: (t) => t.displayName,
          onChanged: (t) => picked = t,
        ),
      ));
      await tester.tap(find.text('Wi-Fi'));
      expect(picked, FlashTransport.wifi);
    });

    testWidgets('PrimaryButton stays inert when disabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(
        PrimaryButton(
          onPressed: () => taps++,
          enabled: false,
          child: const Text('Apply to board'),
        ),
      ));
      await tester.tap(find.text('Apply to board'));
      expect(taps, 0);
    });

    testWidgets('ContentUnavailable renders the empty state', (tester) async {
      await tester.pumpWidget(host(const ContentUnavailable(
        title: 'Not configured',
        message: 'Select a board and battery pin on the Setup tab.',
        icon: Icons.bolt_outlined,
      )));
      expect(find.text('Not configured'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
    });
  });
}
