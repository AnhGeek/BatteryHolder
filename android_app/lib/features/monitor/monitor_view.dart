import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/beacon_log.dart';
import '../../services/beacon_scan_service_client.dart';
import 'device_monitor_view.dart';

/// Lists every board the app has ever heard from, newest first.
///
/// Boards are only reachable during short wake windows, so the list is built
/// from the persisted beacon log rather than from whatever a live scan happens
/// to catch. Tapping a row opens that board's readings and history.
class MonitorView extends StatefulWidget {
  const MonitorView({super.key});

  @override
  State<MonitorView> createState() => _MonitorViewState();
}

class _MonitorViewState extends State<MonitorView> with WidgetsBindingObserver {
  Timer? _poll;

  /// True while a hand-tapped reload is in flight. The periodic poll does not
  /// set it — a spinner that blinks every ten seconds on its own is noise.
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pick up anything the background service logged while we were away, then
    // keep re-reading: the service is the writer, so nothing notifies us.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.beaconLog.reload();
      appState.beaconScan.refresh();
    });
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) context.read<AppState>().beaconLog.reload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android can kill the service while we are away, so neither the switch nor
    // the log can be trusted until both are asked again.
    if (state != AppLifecycleState.resumed || !mounted) return;
    final appState = context.read<AppState>();
    appState.beaconScan.refresh();
    appState.beaconLog.reload();
  }

  /// Re-read the log and say what came back.
  ///
  /// The button used to call [BeaconLogStore.reload] and show nothing at all,
  /// which is indistinguishable from a dead button when the log is empty — and
  /// an empty log is exactly the case people press it in.
  Future<void> _reload(AppState appState) async {
    setState(() => _reloading = true);
    await appState.beaconLog.reload();
    if (!mounted) return;
    setState(() => _reloading = false);

    final devices = appState.beaconLog.devices.length;
    final readings = appState.beaconLog.entries.length;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(readings == 0
            ? 'Nothing logged yet. Switch background logging on and leave it '
                'running — boards wake every few minutes.'
            : 'Reloaded · $readings reading${readings == 1 ? '' : 's'} from '
                '$devices board${devices == 1 ? '' : 's'}.'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: const Text('Monitor'),
        actions: [
          IconButton(
            icon: _reloading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: c.brand),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Reload log',
            onPressed: _reloading ? null : () => _reload(appState),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          appState.beaconLog,
          appState.beaconScan,
          appState.ble,
        ]),
        builder: (context, _) {
          final devices = appState.beaconLog.devices;
          return SingleChildScrollView(
            padding: EdgeInsets.all(AppTheme.spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BackgroundLoggingCard(scan: appState.beaconScan),
                SizedBox(height: AppTheme.spacing.xl),
                SectionHeader(
                  title: 'Boards',
                  subtitle: devices.isEmpty
                      ? 'Nothing logged yet.'
                      : '${devices.length} board${devices.length == 1 ? '' : 's'} seen',
                ),
                SizedBox(height: AppTheme.spacing.md),
                if (devices.isEmpty)
                  Callout(
                    text: 'No readings logged yet. Boards broadcast for about '
                        '20 seconds each time they wake — leave background '
                        'logging on and readings will appear here on their own.',
                    tint: c.brand,
                  )
                else
                  for (final device in devices) ...[
                    _DeviceRow(device: device),
                    SizedBox(height: AppTheme.spacing.md),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Switch for the foreground service that keeps logging while the app is shut.
///
/// Takes the client as a field and listens to it directly. As a `const` widget
/// reading `AppState`, this never rebuilt: the client is what changes, the
/// element was identical across parent rebuilds, and the switch sat frozen on
/// whatever it was first built with.
class _BackgroundLoggingCard extends StatelessWidget {
  final BeaconScanServiceClient scan;

  const _BackgroundLoggingCard({required this.scan});

  Future<void> _set(BuildContext context, bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!on) {
      await scan.stop();
      return;
    }

    final ok = await scan.start();
    if (!ok) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Bluetooth and notification permissions are needed to '
              'log in the background.'),
        ));
      return;
    }
    // Started, but the service bails out quietly when the radio is off — say so
    // rather than leaving a switch that claims to be logging nothing.
    if (!scan.isScanning) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Logging is on, but no scan is running. Turn Bluetooth '
              'on and it starts by itself.'),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return ListenableBuilder(
      listenable: scan,
      builder: (context, _) => AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Background logging',
                      style: AppTheme.font.headline
                          .copyWith(color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle,
                    style: AppTheme.font.footnote.copyWith(
                        color: _isStalled ? c.warning : c.textSecondary),
                  ),
                ],
              ),
            ),
            SizedBox(width: AppTheme.spacing.sm),
            if (scan.isBusy)
              SizedBox(
                width: 24,
                height: 24,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: c.brand),
              )
            else
              Switch(
                value: scan.isEnabled,
                activeThumbColor: c.brand,
                onChanged: scan.isAvailable
                    ? (on) => _set(context, on)
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Enabled but not scanning: the feature is on and nothing is being recorded.
  bool get _isStalled => scan.isEnabled && !scan.isScanning;

  String get _subtitle {
    if (!scan.isAvailable) return 'Not available on this platform.';
    if (!scan.isEnabled) {
      return 'Off. Boards are only awake for ~20 s at a time, so readings are '
          'missed while this is off.';
    }
    return scan.isScanning
        ? 'Logging now — keeps recording each wake even when the app is closed.'
        : 'On, but no scan is running. Check that Bluetooth is on and the app '
            'is allowed to run in the background.';
  }
}

class _DeviceRow extends StatelessWidget {
  final KnownDevice device;

  const _DeviceRow({required this.device});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);

    // A board is reachable only while it is advertising, which the live scan
    // knows about and the log does not.
    final live = appState.ble.discovered
        .where((d) => d.id == device.deviceId)
        .firstOrNull;
    final awake = live?.isReachable ?? false;
    final soc = device.soc;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DeviceMonitorView(
          deviceId: device.deviceId,
          name: device.name,
        ),
      )),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.font.headline
                          .copyWith(color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      awake ? 'Awake' : 'Last seen ${relativeTime(device.lastSeen)}',
                      if (device.volts != null)
                        '${device.volts!.toStringAsFixed(2)} V',
                      '${device.entryCount} reading'
                          '${device.entryCount == 1 ? '' : 's'}',
                    ].join(' · '),
                    style:
                        AppTheme.font.caption.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            if (soc != null) ...[
              SizedBox(width: AppTheme.spacing.sm),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: AppTheme.spacing.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: c.battery(soc / 100).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radius.pill),
                ),
                child: Text('$soc%',
                    style: AppTheme.font.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: c.battery(soc / 100))),
              ),
            ],
            SizedBox(width: AppTheme.spacing.xs),
            Tooltip(
              message: 'Delete this board’s log',
              child: IconButton(
                icon: Icon(Icons.delete_outline, color: c.textSecondary),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: () => confirmDeleteLog(
                  context,
                  name: device.name,
                  entryCount: device.entryCount,
                  onConfirmed: () =>
                      appState.forgetDevice(device.deviceId),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "4 min ago" — boards report minutes apart, so this is the useful precision.
String relativeTime(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) return '${delta.inHours} h ago';
  return '${delta.inDays} d ago';
}

/// Ask before dropping a board's history, then do it.
///
/// Shared by the list row and the board's own screen: deleting a log is not
/// undoable and there is no reason for the two entry points to word it
/// differently.
Future<void> confirmDeleteLog(
  BuildContext context, {
  required String name,
  required int entryCount,
  required Future<void> Function() onConfirmed,
}) async {
  final c = AppTheme.colorOf(context);
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: c.surfaceElevated,
      title: Text('Delete log for $name?',
          style: AppTheme.font.headline.copyWith(color: c.textPrimary)),
      content: Text(
        '$entryCount reading${entryCount == 1 ? '' : 's'} will be removed from '
        'this phone. The board keeps reporting, so the log starts filling '
        'again on its next wake.',
        style: AppTheme.font.body.copyWith(color: c.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel',
              style: AppTheme.font.body.copyWith(color: c.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Delete',
              style: AppTheme.font.body.copyWith(color: c.danger)),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await onConfirmed();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text('Deleted the log for $name.'),
    ));
}
