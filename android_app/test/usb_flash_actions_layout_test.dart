import 'package:battery_holder/app/app_state.dart';
import 'package:battery_holder/design_system/theme.dart';
import 'package:battery_holder/features/flash/usb_flash_card.dart';
import 'package:battery_holder/services/usb_serial_port.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart' show previewESP32;

void main() {
  testWidgets('Open Setup and Check board do not touch', (tester) async {
    final state = AppState();
    state.selectBoard(previewESP32);
    // A board on the port with nothing generated yet: the branch that shows
    // "Open Setup" straight above the always-available "Check board".
    state.usbFlasher.selectedDevice = const UsbSerialDevice(
      deviceId: 1,
      vendorId: 0x303a,
      productId: 0x1001,
      driver: 'cdc',
      hasPermission: true,
      product: 'USB JTAG/serial debug unit',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: UsbFlashCard()),
          ),
        ),
      ),
    );
    await tester.pump();

    final openSetup = tester.getRect(
        find.ancestor(of: find.text('Open Setup'), matching: find.byType(Opacity)).first);
    final checkBoard = tester.getRect(
        find.ancestor(of: find.text('Check board'), matching: find.byType(Opacity)).first);

    // Two tinted buttons flush against each other read as one block, so the
    // stack keeps the same gap it uses between every other pair of actions.
    expect(checkBoard.top - openSetup.bottom,
        closeTo(AppTheme.spacing.sm, 0.5),
        reason: 'the two buttons need the standard gap between them');
  });
}
