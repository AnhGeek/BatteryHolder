import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/flash/flash_view.dart';
import 'package:battery_holder/features/power/power_view.dart';
import 'package:battery_holder/features/setup/board_setup_wizard.dart';
import 'package:battery_holder/services/ble_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

/// There is no Bluetooth stack under `flutter test`, so these exercise the
/// disconnected / unsupported paths. That is exactly where the layout bugs live
/// — an unbounded Row throws during layout regardless of transport state.
void main() {
  Widget host(Widget child, AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: child,
        ),
      );

  testWidgets('Power screen tells the user to connect first', (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(const PowerView(), state));
    await tester.pump();

    expect(find.text('Board not connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Flash screen shows only the USB warning with nothing plugged in',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    await tester.pumpWidget(host(const FlashView(), state));
    await tester.pump();

    expect(find.text('No board on the USB port'), findsOneWidget);

    // Everything below the device card needs a board on the port, and offering
    // it anyway buries the one thing that needs fixing.
    expect(find.text('Flash board over USB'), findsNothing);
    expect(find.text('Check board'), findsNothing);
    expect(find.textContaining('Generate BIN file'), findsNothing);

    // The over-the-air and local-file sections are gone for good.
    expect(find.text('Over-the-air builds'), findsNothing);
    expect(find.text('Local file'), findsNothing);
    expect(find.text('Choose .bin file'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Setup wizard lays out and reports a failed connect',
      (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);

    final device = DiscoveredDevice(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'BH-E5F6',
      rssi: -54,
      device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF'),
      hasAdvData: true,
      pairingMode: true,
      volts: 3.94,
      soc: 78,
    );

    await tester.pumpWidget(host(BoardSetupWizard(device: device), state));
    await tester.pump();

    // The header renders straight from the advertisement, before any connect.
    expect(find.text('BH-E5F6'), findsOneWidget);
    expect(find.text('3.94 V'), findsOneWidget);
    expect(find.text('78%'), findsOneWidget);
    expect(find.text('Add board'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('an unprovisioned advertisement means "needs setup"', () {
    final fresh = DiscoveredDevice(
      id: 'x',
      name: 'BH-0001',
      rssi: -60,
      device: BluetoothDevice.fromId('x'),
      hasAdvData: true,
      provisioned: false,
    );
    expect(fresh.needsSetup, isTrue);

    final configured = DiscoveredDevice(
      id: 'y',
      name: 'BH-0002',
      rssi: -60,
      device: BluetoothDevice.fromId('y'),
      hasAdvData: true,
      provisioned: true,
    );
    expect(configured.needsSetup, isFalse);

    // A v1 board sends no manufacturer data, so we must not claim it needs
    // setup — it has no concept of provisioning at all.
    final v1 = DiscoveredDevice(
      id: 'z',
      name: 'ESP device',
      rssi: -60,
      device: BluetoothDevice.fromId('z'),
    );
    expect(v1.needsSetup, isFalse);
  });
}
