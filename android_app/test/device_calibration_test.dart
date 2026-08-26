import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/components.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/monitor/device_monitor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

/// Calibrating a board from its own page.
///
/// There is no Bluetooth stack under `flutter test`, so these run the
/// disconnected path — which is most of what the section has to get right
/// anyway: the arithmetic is the app's, and only the last step needs a board.
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
    final state = AppState();
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
    final state = AppState();
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

  testWidgets('sending needs a live link to this board', (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(state));
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
