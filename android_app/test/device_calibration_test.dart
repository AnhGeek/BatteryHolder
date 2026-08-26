import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/components.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/devices/calibration_section.dart';
import 'package:battery_holder/features/monitor/device_monitor_view.dart';
import 'package:battery_holder/features/power/power_view.dart';
import 'package:battery_holder/models/pin_configuration.dart';
import 'package:battery_holder/services/ble_manager.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

/// Calibrating a board from its own page.
///
/// There is no Bluetooth stack under `flutter test`, so the live link is a
/// [BLEManager] subclass whose getters simply report connected. Calibration
/// only renders while that link exists — offline, the board settings screen
/// owns the section — so the disconnected path is asserted separately.
class _LiveLinkBLE extends BLEManager {
  final String deviceId;

  _LiveLinkBLE(this.deviceId);

  /// What [readPinConfiguration] answers; null mirrors a v1 board.
  PinConfiguration? readConfig;

  @override
  ConnectionState get connection => ConnectionState.connected;

  @override
  String? get connectedDeviceId => deviceId;

  @override
  bool get supportsV2 => true;

  @override
  Future<void> stayAwake({int seconds = 0}) async {}

  @override
  Future<void> sleepNow({int? intervalSec}) async {}

  @override
  Future<PinConfiguration?> readPinConfiguration() async => readConfig;
}
void main() {
  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const DeviceMonitorView(
            deviceId: 'AA:BB:CC:DD:EE:FF',
            name: 'BH-d08c',
          ),
        ),
      );

  /// The editable field on the row labelled [label].
  Finder fieldFor(String label) => find.descendant(
        of: find.ancestor(
            of: find.text(label), matching: find.byType(NumberRow)),
        matching: find.byType(TextField),
      );

  testWidgets('the board page carries the calibration, above its log',
      (tester) async {
    final state = AppState(ble: _LiveLinkBLE('AA:BB:CC:DD:EE:FF'));
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(state));
    await tester.pump();

    await tester.ensureVisible(find.text('R1 (kΩ)'));
    await tester.pump();

    expect(find.text('R1 (kΩ)'), findsOneWidget);
    expect(find.text('R2 (kΩ)'), findsOneWidget);
    expect(find.text('Measured (V)'), findsOneWidget);
    // Once as the section title, once as the trim's own row.
    expect(find.text('Calibration'), findsNWidgets(2));

    // Calibration decides what the volts mean, so it comes before the
    // threshold expressed in them — and both sit above the log.
    final calibration = tester.getRect(find.text('R1 (kΩ)'));
    final alert = tester.getRect(find.text('Low battery alert'));
    expect(alert.top, greaterThan(calibration.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing a resistor moves the voltage as it is typed',
      (tester) async {
    final state = AppState(ble: _LiveLinkBLE('AA:BB:CC:DD:EE:FF'));
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.ensureVisible(find.text('R1 (kΩ)'));
    await tester.pump();

    // 100k/100k: half the pack reaches the pin, so 3.3 V of reference covers
    // 6.6 V of battery.
    expect(find.text('2.00×'), findsOneWidget);
    expect(find.text('6.60 V'), findsOneWidget);

    await tester.enterText(fieldFor('R1 (kΩ)'), '300');
    await tester.pump();

    // 300k/100k is a quarter, and the range moves with it — before anything
    // has been sent anywhere.
    expect(state.pinConfiguration!.dividerR1KOhm, 300);
    expect(find.text('4.00×'), findsOneWidget);
    expect(find.text('13.20 V'), findsOneWidget);
  });

  testWidgets('the board page hides calibration until it is connected',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(state));
    await tester.pump();

    // Offline, the board page says nothing about calibration — the Devices
    // tab owns the section while there is no live link.
    expect(find.text('Calibration'), findsNothing);
    expect(find.text('R1 (kΩ)'), findsNothing);
    expect(find.text('Low battery alert'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('board settings carries the calibration section', (tester) async {
    final state = AppState(ble: _LiveLinkBLE('AA:BB:CC:DD:EE:FF'));
    state.selectBoard(previewESP32);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PowerView(),
        ),
      ),
    );
    await tester.pump();

    // The connected board's settings screen shows the calibration block next
    // to Advanced — header plus the trim's own row — and has no send button of
    // its own: "Apply to board" carries it.
    expect(find.text('Reporting interval'), findsOneWidget);
    expect(find.text('Calibration'), findsNWidgets(2));
    expect(find.text('R1 (kΩ)'), findsOneWidget);
    expect(find.text('Send to device'), findsNothing);
    expect(find.text('Apply to board'), findsOneWidget);
    expect(tester.getRect(find.text('R1 (kΩ)')).top,
        greaterThan(tester.getRect(find.text('Advanced')).top));
    expect(tester.getRect(find.text('R1 (kΩ)')).top,
        lessThan(tester.getRect(find.text('Board actions')).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('board settings reads the calibration back from the board',
      (tester) async {
    final ble = _LiveLinkBLE('AA:BB:CC:DD:EE:FF')
      ..readConfig = PinConfiguration.standalone()
          .copyWith(dividerR1KOhm: 220, dividerR2KOhm: 47);
    final state = AppState(ble: ble);
    state.selectBoard(previewESP32); // 100k/100k — the read must replace it.

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PowerView(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The rows now show what the board holds, not what Setup seeded.
    expect(state.pinConfiguration!.dividerR1KOhm, 220);
    expect(state.pinConfiguration!.dividerR2KOhm, 47);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calibration needs no board chosen in Setup first',
      (tester) async {
    final state = AppState(ble: _LiveLinkBLE('AA:BB:CC:DD:EE:FF'));
    // No selectBoard — the working configuration starts empty.

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PowerView(),
        ),
      ),
    );
    await tester.pump();
    // The section seeds a generic configuration instead of demanding a trip
    // through Setup.
    await tester.pump();

    expect(state.pinConfiguration, isNotNull);
    expect(find.text('Calibration'), findsNWidgets(2));
    expect(find.text('R1 (kΩ)'), findsOneWidget);
    expect(find.textContaining('Pick this board on the Configuration screen'),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending needs a live link to this board', (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    // The section itself still knows both halves of the link, so pump it
    // directly — no board page wraps it without one.
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(AppTheme.spacing.lg),
              child: const CalibrationSection(
                deviceId: 'AA:BB:CC:DD:EE:FF',
                isLive: false,
                rawADC: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final send = find.text('Send to device');
    await tester.ensureVisible(send);
    await tester.pump();

    // Offered, but inert, and the callout says which half is missing.
    expect(send, findsOneWidget);
    final button = tester.widget<PrimaryButton>(
        find.ancestor(of: send, matching: find.byType(PrimaryButton)));
    expect(button.onPressed, isNull);
    expect(find.textContaining('This board is not connected'), findsOneWidget);

    // A meter reading needs a live count to solve against, so that row is out
    // of reach rather than quietly doing nothing.
    expect(tester.widget<TextField>(find.byWidgetPredicate((w) =>
            w is TextField && w.decoration?.hintText == 'Meter')).enabled,
        isFalse);
    expect(tester.takeException(), isNull);
  });
}
