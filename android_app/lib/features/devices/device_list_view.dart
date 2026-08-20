import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/board.dart';
import '../../services/ble_manager.dart';
import '../../services/wifi_ota_service.dart';
import '../power/power_view.dart';
import '../setup/board_setup_wizard.dart';

/// Discover and connect to a board over the active transport.
class DeviceListView extends StatefulWidget {
  const DeviceListView({super.key});

  @override
  State<DeviceListView> createState() => _DeviceListViewState();
}

class _DeviceListViewState extends State<DeviceListView> {
  @override
  void deactivate() {
    // The SwiftUI `.onDisappear { appState.stopDiscovery() }` equivalent.
    context.read<AppState>().stopDiscovery();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final transports =
        appState.selectedBoard?.supportedTransports ?? FlashTransport.values;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Devices')),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(AppTheme.spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedPicker<FlashTransport>(
              options: transports,
              selection: transports.contains(appState.activeTransport)
                  ? appState.activeTransport
                  : transports.first,
              labelOf: (t) => t.displayName,
              onChanged: (t) => appState.activeTransport = t,
            ),
            SizedBox(height: AppTheme.spacing.md),
            // Setting a board up is not what this screen is for any more: a
            // board is configured before it is flashed, and arrives here
            // running. Scanning is how you find one again to change it.
            Callout(
              text: 'Boards arrive here already set up — the mode and the wake '
                  'timer come from the image they were flashed with. Scan to '
                  'find one and change how it reports.',
              tint: c.brand,
              icon: Icons.info,
            ),
            SizedBox(height: AppTheme.spacing.lg),
            if (appState.activeTransport == FlashTransport.ble)
              _BLEDeviceList(ble: appState.ble)
            else
              _WiFiDeviceList(wifi: appState.wifi),
          ],
        ),
      ),
    );
  }
}

// MARK: - BLE

class _BLEDeviceList extends StatelessWidget {
  final BLEManager ble;

  const _BLEDeviceList({required this.ble});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return ListenableBuilder(
      listenable: ble,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SectionHeader(
                    title: 'Bluetooth', subtitle: _statusText(ble)),
              ),
              SizedBox(
                width: 108,
                child: SecondaryButton(
                  onPressed: ble.isPoweredOn
                      ? () => ble.isScanning || ble.keepLooking
                          ? ble.stopScan()
                          : ble.startScan(keepLooking: true)
                      : null,
                  child: ble.isScanning || ble.keepLooking
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: c.brand),
                            ),
                            SizedBox(width: AppTheme.spacing.sm),
                            const Text('Stop'),
                          ],
                        )
                      : const Text('Scan'),
                ),
              ),
            ],
          ),
          SizedBox(height: AppTheme.spacing.md),

          if (!ble.isPoweredOn) ...[
            Callout(
              text: 'Turn on Bluetooth to scan for boards.',
              tint: c.warning,
              icon: Icons.warning_amber_rounded,
            ),
            SizedBox(height: AppTheme.spacing.md),
          ],

          for (final device in ble.discovered) ...[
            _BLEDeviceRow(ble: ble, device: device),
            SizedBox(height: AppTheme.spacing.md),
          ],

          // A scan that finds nothing is normal: the board sleeps for minutes at
          // a time (DEVICE_PROTOCOL.md §1). Never call this a Bluetooth error.
          if (ble.discovered.isEmpty && ble.isPoweredOn)
            Callout(
              text: ble.isScanning || ble.keepLooking
                  ? 'Looking for boards. They wake up every few minutes — this '
                      'can take a moment.'
                  : 'No board found. Boards sleep between wakes — tap the '
                      'RESET button on the board and it stays connectable for '
                      'two minutes.',
              tint: c.brand,
            ),
        ],
      ),
    );
  }

  String _statusText(BLEManager ble) {
    final status = ble.status;
    return switch (ble.connection.status) {
      ConnectionStatus.disconnected => 'Not connected',
      ConnectionStatus.connecting => 'Connecting…',
      ConnectionStatus.discovering => 'Discovering services…',
      ConnectionStatus.connected => status?.mode != null
          ? 'Connected · ${status!.mode.displayName} mode'
          : 'Connected',
      // Expected, not a failure.
      ConnectionStatus.sleeping => 'Board went to sleep',
      // Scanning and connecting to a board that sleeps for minutes at a time
      // fails routinely, so this screen never dresses it up as an error. The
      // reason still reaches the screens where the user asked for a specific
      // action (the setup wizard, power, flashing).
      ConnectionStatus.failed => 'Not connected',
    };
  }
}

class _BLEDeviceRow extends StatelessWidget {
  final BLEManager ble;
  final DiscoveredDevice device;

  const _BLEDeviceRow({required this.ble, required this.device});

  bool get _isConnectedToThis =>
      ble.connection.isConnected && ble.connectedDeviceId == device.id;

  /// Reachable means the board advertised in the last few seconds, i.e. it is
  /// awake right now. Outside its wake window a connect attempt just times out.
  bool get _canConnect => device.isReachable || _isConnectedToThis;

  /// Tapping a row is "I want to change this board".
  ///
  /// A board flashed from the Configuration screen arrives here already set up
  /// — the run mode and the timers came out of the image — so the wizard is no
  /// longer the front door. It is the fallback for the one board that genuinely
  /// has no mode yet: one flashed with "Decide later", or one whose pairing
  /// button was held down. Everything else opens its settings.
  Future<void> _open(BuildContext context) async {
    if (device.needsSetup) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BoardSetupWizard(device: device),
      ));
      return;
    }
    await _openSettings(context);
  }

  /// Settings need a live link, so connect on the way in if necessary.
  Future<void> _openSettings(BuildContext context) async {
    if (!_isConnectedToThis) await ble.connect(device);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PowerView()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final volts = device.volts;
    final soc = device.soc;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _canConnect ? () => _open(context) : null,
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(device.name,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.font.headline
                                .copyWith(color: c.textPrimary)),
                      ),
                      // "Unclaimed", not "Needs setup": a board flashed from
                      // the Configuration screen is set up before it ever
                      // advertises, so this badge now means the rarer thing —
                      // an image built with no run mode, or a pairing-button
                      // wake. Tapping it still opens the wizard.
                      if (device.needsSetup) ...[
                        SizedBox(width: AppTheme.spacing.sm),
                        _Badge(text: 'Unclaimed', tint: c.warning),
                      ] else if (device.wifiMode) ...[
                        SizedBox(width: AppTheme.spacing.sm),
                        _Badge(
                          text: device.wifiOnline ? 'Wi-Fi online' : 'Wi-Fi',
                          tint: device.wifiOnline ? c.success : c.textSecondary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      _canConnect ? 'Awake' : 'Asleep',
                      if (volts != null) '${volts.toStringAsFixed(2)} V',
                      'RSSI ${device.rssi} dBm',
                    ].join(' · '),
                    style:
                        AppTheme.font.caption.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),

            // Battery pill straight from the advertisement — no connect needed.
            if (soc != null) ...[
              SizedBox(width: AppTheme.spacing.sm),
              _Badge(text: '$soc%', tint: c.battery(soc / 100)),
            ],

            // Settings live on the board they configure, rather than as one
            // button for whatever happens to be connected. A gear, not a
            // battery: the screen behind it is where every board setting is,
            // and the row already says what the battery is doing.
            SizedBox(width: AppTheme.spacing.xs),
            _IconAction(
              icon: Icons.settings,
              tooltip: 'Board settings',
              tint: _canConnect ? c.brand : c.textSecondary.withValues(alpha: 0.5),
              onPressed: _canConnect ? () => _openSettings(context) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color tint;
  final VoidCallback? onPressed;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.tint,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: IconButton(
          icon: Icon(icon, color: tint),
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color tint;

  const _Badge({required this.text, required this.tint});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: AppTheme.spacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppTheme.radius.pill),
        ),
        child: Text(text,
            style: AppTheme.font.caption
                .copyWith(fontWeight: FontWeight.w600, color: tint)),
      );
}

// MARK: - Wi-Fi

class _WiFiDeviceList extends StatelessWidget {
  final WiFiOTAService wifi;

  const _WiFiDeviceList({required this.wifi});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return ListenableBuilder(
      listenable: wifi,
      builder: (context, _) {
        final connected = wifi.connected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SectionHeader(
                    title: 'Wi-Fi',
                    subtitle: connected != null
                        ? _wifiSubtitle(connected)
                        : 'Not connected',
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: SecondaryButton(
                    onPressed: () => wifi.isBrowsing
                        ? wifi.stopBrowsing()
                        : wifi.startBrowsing(),
                    child: Text(wifi.isBrowsing ? 'Stop' : 'Find'),
                  ),
                ),
              ],
            ),
            SizedBox(height: AppTheme.spacing.md),
            if (wifi.discovered.isEmpty) ...[
              Callout(
                text: 'Boards only answer while they are awake, and they are '
                    'discoverable on the same Wi-Fi network as your phone.',
                tint: c.brand,
              ),
              SizedBox(height: AppTheme.spacing.md),
            ],
            for (final device in wifi.discovered) ...[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => wifi.connect(device),
                child: AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(device.name,
                                style: AppTheme.font.headline
                                    .copyWith(color: c.textPrimary)),
                            const SizedBox(height: 2),
                            Text('${device.host}:${device.port}',
                                style: AppTheme.font.caption
                                    .copyWith(color: c.textSecondary)),
                          ],
                        ),
                      ),
                      if (connected?.id == device.id)
                        Icon(Icons.check_circle, color: c.brand),
                    ],
                  ),
                ),
              ),
              SizedBox(height: AppTheme.spacing.md),
            ],
          ],
        );
      },
    );
  }

  String _wifiSubtitle(WiFiDevice device) => switch (wifi.reachability) {
        WiFiReachability.live => 'Connected to ${device.name}',
        WiFiReachability.asleep => '${device.name} · asleep',
        WiFiReachability.unreachable => '${device.name} · not answering',
      };
}
