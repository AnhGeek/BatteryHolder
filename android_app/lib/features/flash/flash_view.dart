import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import 'usb_flash_card.dart';

/// Flash firmware to the board over the cable.
///
/// The cable is the whole screen. Over-the-air builds and picking a `.bin` off
/// the phone both used to live here; neither survived contact with how these
/// boards are actually brought up, which is: generate an image from the
/// Configuration screen, write it over USB, verify it, reboot it.
class FlashView extends StatelessWidget {
  const FlashView({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final board = appState.selectedBoard;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Flash')),
      body: board == null
          ? const ContentUnavailable(
              title: 'No board selected',
              message: 'Choose a board on the Setup tab first.',
              icon: Icons.arrow_circle_down,
            )
          : SingleChildScrollView(
              padding: EdgeInsets.all(AppTheme.spacing.lg),
              child: const UsbFlashCard(),
            ),
    );
  }
}
