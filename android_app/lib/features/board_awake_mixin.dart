import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../models/board.dart';
import '../services/ble_manager.dart';

/// Holds a BLE board awake for as long as the screen is mounted.
///
/// DEVICE_PROTOCOL.md §2.4: any screen that needs a live board writes
/// `STAY_AWAKE(0)` on entry and `SLEEP_NOW` on exit. Forgetting the second half
/// leaves the board burning current until its idle timeout — correct, but
/// wasteful. Mix this into the screen's [State] and it happens automatically.
///
/// No-ops on v1 boards (no session characteristic) and in Wi-Fi mode.
mixin BoardAwakeWhileMounted<T extends StatefulWidget> on State<T> {
  BLEManager? _heldBy;

  @override
  void initState() {
    super.initState();
    // Provider is not available during initState, so defer a frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      if (appState.activeTransport != FlashTransport.ble) return;
      final ble = appState.ble;
      if (!ble.connection.isConnected || !ble.supportsV2) return;

      _heldBy = ble;
      ble.stayAwake().catchError((_) {
        // Link may have dropped between the check and the write; the board's
        // own idle timeout covers us.
        _heldBy = null;
      });
    });
  }

  @override
  void dispose() {
    // Fire-and-forget: dispose cannot await, and the board sleeps on its own if
    // this never lands.
    _heldBy?.sleepNow().catchError((_) {});
    _heldBy = null;
    super.dispose();
  }
}
