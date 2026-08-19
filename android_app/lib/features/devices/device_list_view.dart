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
                width: 96,
                child: SecondaryButton(
                  onPressed: ble.isPoweredOn
                      ? () => ble.isScanning || ble.keepLooking
                          ? ble.stopScan()
                          : ble.startScan(keepLooking: true)
                      : null,
                  child: Text(
                      ble.isScanning || ble.keepLooking ? 'Stop' : 'Scan'),
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

          // Power screen is only meaningful on a connected v2 board.
          if (ble.connection.isConnected && ble.supportsV2) ...[
            SecondaryButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PowerView()),
              ),
              child: const LabelRow(
                  text: 'Power & sleep', icon: Icons.battery_saver),
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
      ConnectionStatus.failed => ble.connection.message ?? 'Failed',
    };
  }
}

class _BLEDeviceRow extends StatelessWidget {
  final BLEManager ble;
  final DiscoveredDevice device;

  const _BLEDeviceRow({required this.ble, required this.device});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final volts = device.volts;
    final soc = device.soc;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // A board that has never been provisioned goes straight into the wizard;
        // anything else just connects.
        if (device.needsSetup) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BoardSetupWizard(device: device),
          ));
        } else {
          ble.connect(device);
        }
      },
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
                      if (device.needsSetup) ...[
                        SizedBox(width: AppTheme.spacing.sm),
                        _Badge(text: 'Needs setup', tint: c.warning),
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
                      'Nearby',
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
            Icon(Icons.chevron_right, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
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
                      Icon(
                        connected?.id == device.id
                            ? Icons.check_circle
                            : Icons.chevron_right,
                        color: connected?.id == device.id
                            ? c.brand
                            : c.textSecondary,
                      ),
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
