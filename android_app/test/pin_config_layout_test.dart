import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/monitor/monitor_view.dart';
import 'package:battery_holder/features/pin_config/pin_config_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

void main() {
  testWidgets('Apply button sits below the scrolled content', (tester) async {
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
    final button = tester.getRect(find.text('Apply to board'));
    final appBar = tester.getRect(find.byType(AppBar));

    expect(header.top, greaterThan(appBar.bottom),
        reason: 'section header must start below the app bar');
    expect(button.top, greaterThan(header.top),
        reason: 'the apply button is the last item in the scroll column');
  });

  testWidgets('Monitor lays out gauge, stats and history in order',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const MonitorView(),
        ),
      ),
    );
    await tester.pump();

    // A stats Row without a bounded height throws during layout, so simply
    // reaching this point proves the pills got real constraints.
    final gauge = tester.getRect(find.text('volts'));
    final stats = tester.getRect(find.text('Raw ADC'));
    final history = tester.getRect(find.text('History'));

    expect(stats.top, greaterThan(gauge.top));
    expect(history.top, greaterThan(stats.top));
  });
}
