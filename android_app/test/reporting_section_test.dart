import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/pin_config/pin_config_view.dart';
import 'package:battery_holder/models/board_setup.dart';
import 'package:battery_holder/models/device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

/// The Configuration screen is where a board is set up, so everything the
/// firmware needs has to be answerable here — including the wake timer, which
/// used to be offered only on a screen that needs a live Bluetooth link to a
/// board that sleeps for minutes at a time.
Future<AppState> _pumpConfig(WidgetTester tester) async {
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
  return state;
}

void main() {
  testWidgets('every wake interval is offered, not just a handful',
      (tester) async {
    await _pumpConfig(tester);

    final timer = find.text('Wake timer');
    await tester.ensureVisible(timer);
    await tester.pump();

    for (final seconds in PowerConfig.intervalOptions) {
      expect(find.text(PowerConfig.intervalLabel(seconds)), findsWidgets,
          reason: '${PowerConfig.intervalLabel(seconds)} is missing');
    }
  });

  testWidgets('picking an interval lands in the field for the chosen mode',
      (tester) async {
    final state = await _pumpConfig(tester);
    expect(state.boardSetup.mode, RunMode.ble);

    final hour = find.text('1 h');
    await tester.ensureVisible(hour.first);
    await tester.tap(hour.first);
    await tester.pump();

    expect(state.boardSetup.power.bleWakeSec, 3600);
    // The Wi-Fi interval is a separate field and must not be dragged along.
    expect(state.boardSetup.power.wifiReportSec, 900);
  });

  testWidgets('the run mode is chosen here, before the flash', (tester) async {
    final state = await _pumpConfig(tester);

    final header = find.text('How it reports');
    await tester.ensureVisible(header);
    await tester.pump();

    final wifi = find.text('Wi-Fi');
    await tester.ensureVisible(wifi.first);
    await tester.tap(wifi.first);
    await tester.pump();

    expect(state.boardSetup.mode, RunMode.wifi);
    // Wi-Fi means credentials, and they are asked for right here rather than
    // after the flash over a radio the board has not been set up for.
    expect(find.text('Network (SSID)'), findsOneWidget);
  });

  testWidgets('a Wi-Fi board with no network cannot be flashed',
      (tester) async {
    final state = await _pumpConfig(tester);
    state.boardSetup = const BoardSetup(mode: RunMode.wifi);
    await tester.pump();

    final generate = find.text('Generate BIN file');
    await tester.ensureVisible(generate);
    await tester.pump();

    expect(find.textContaining('Name the Wi-Fi network'), findsOneWidget);
  });

  testWidgets('"Decide later" is offered but is not the default',
      (tester) async {
    final state = await _pumpConfig(tester);

    // The default claims the board, because leaving it unclaimed is the answer
    // that costs the user a second trip through the Devices tab.
    expect(state.boardSetup.isProvisioned, isTrue);

    final later = find.text('Decide later');
    await tester.ensureVisible(later);
    await tester.tap(later);
    await tester.pump();

    expect(state.boardSetup.mode, RunMode.pairing);
    expect(state.boardSetup.isProvisioned, isFalse);
  });
}
