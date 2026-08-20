import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/monitor/device_monitor_view.dart';
import 'package:battery_holder/features/pin_config/pin_config_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

void main() {
  testWidgets('Generate is the single action below the scrolled content',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PinConfigView(),
        ),
      ),
    );
    await tester.pump();

    final header = tester.getRect(find.text('Battery ADC pin'));
    final generate = tester.getRect(find.text('Generate BIN file'));
    final appBar = tester.getRect(find.byType(AppBar));

    expect(header.top, greaterThan(appBar.bottom),
        reason: 'section header must start below the app bar');
    expect(generate.top, greaterThan(header.top),
        reason: 'generating the image is the primary action, below the form');

    // Configuration reaches the board by being flashed with the image, not by
    // being pushed over the air from this screen.
    expect(find.textContaining('Apply over'), findsNothing);
  });

  testWidgets('Generating narrates the build on a bounded schedule',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PinConfigView(),
        ),
      ),
    );
    await tester.pump();

    final generate = find.text('Generate BIN file');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pump();

    // Busy: the label gives way to a spinner and the first stage is named.
    expect(generate, findsNothing);
    expect(find.textContaining('Reading the calibration'), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);

    // The stages are a floor on how long the button stays busy — long enough
    // that assembling an image looks like work, and over well before a wait
    // starts reading as a hang. (The build itself needs real I/O, which the
    // fake-async test zone never resolves, so the schedule is what this
    // pins down.)
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('3/5'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('5/5'), findsOneWidget);
    expect(find.textContaining('Verifying the image set'), findsOneWidget);
  });

  testWidgets('Device monitor lays out gauge, stats, history and log in order',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const DeviceMonitorView(
            deviceId: 'AA:BB:CC:DD:EE:FF',
            name: 'BH-d08c',
          ),
        ),
      ),
    );
    await tester.pump();

    // A stats Row without a bounded height throws during layout, so simply
    // reaching this point proves the pills got real constraints.
    final gauge = tester.getRect(find.text('volts'));
    final stats = tester.getRect(find.text('Raw ADC'));
    final history = tester.getRect(find.text('History'));
    final log = tester.getRect(find.text('Log'));

    expect(stats.top, greaterThan(gauge.top));
    expect(history.top, greaterThan(stats.top));
    expect(log.top, greaterThan(history.top));
    expect(tester.takeException(), isNull);
  });
}
