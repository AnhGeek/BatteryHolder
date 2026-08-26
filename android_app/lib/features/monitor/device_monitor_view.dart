import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/beacon_log.dart';
import '../../models/device_alert_setting.dart';
import '../../services/low_battery_alerts.dart';
import '../board_awake_mixin.dart';
import '../devices/calibration_section.dart';
import 'monitor_view.dart' show confirmDeleteLog, relativeTime;

/// One board's readings: live over BLE while it is awake and connected, and the
/// persisted advertisement log the rest of the time.
///
/// The log is the point — a board is only reachable for ~20 s every few minutes,
/// so history has to come from beacons recorded in the background rather than
/// from a connection the user happens to be holding.
class DeviceMonitorView extends StatefulWidget {
  final String deviceId;
  final String name;

  const DeviceMonitorView({
    super.key,
    required this.deviceId,
    required this.name,
  });

  @override
  State<DeviceMonitorView> createState() => _DeviceMonitorViewState();
}

class _DeviceMonitorViewState extends State<DeviceMonitorView>
    with BoardAwakeWhileMounted {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().beaconLog.reload();
    });
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) context.read<AppState>().beaconLog.reload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// True when the app's live BLE link belongs to *this* board.
  bool _isLive(AppState appState) =>
      appState.ble.connection.isConnected &&
      appState.ble.connectedDeviceId == widget.deviceId;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          ListenableBuilder(
            listenable: appState.beaconLog,
            builder: (context, _) {
              final count =
                  appState.beaconLog.entriesFor(widget.deviceId).length;
              return IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete this board’s log',
                onPressed:
                    count == 0 ? null : () => _deleteLog(context, count),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [appState.beaconLog, appState.ble, appState.alerts]),
        builder: (context, _) {
          final entries = appState.beaconLog.entriesFor(widget.deviceId);
          return _body(context, appState, entries);
        },
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppState appState,
    List<BeaconLogEntry> entries,
  ) {
    final c = AppTheme.colorOf(context);
    final live = _isLive(appState);
    final reading = live ? appState.latestReading : null;
    final latestBeacon = entries.isEmpty ? null : entries.first;

    // Prefer the connected board's own reading; fall back to the last beacon.
    final volts = reading?.voltage ?? latestBeacon?.volts;
    final pct = reading?.percentage ??
        (latestBeacon?.soc != null ? latestBeacon!.soc! / 100 : null);
    final batteryColor = c.battery(pct ?? 0);

    return SingleChildScrollView(
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      child: Column(
        children: [
          // Gauge
          Padding(
            padding: EdgeInsets.only(top: AppTheme.spacing.md),
            child: SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  BatteryGauge(fraction: pct ?? 0, color: batteryColor),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        volts != null ? volts.toStringAsFixed(2) : '–––',
                        style: AppTheme.font.monoLarge
                            .copyWith(color: c.textPrimary),
                      ),
                      SizedBox(height: AppTheme.spacing.xs),
                      Text('volts',
                          style: AppTheme.font.footnote
                              .copyWith(color: c.textSecondary)),
                      SizedBox(height: AppTheme.spacing.xs),
                      Text(pct != null ? '${(pct * 100).round()}%' : '–',
                          style: AppTheme.font.headline
                              .copyWith(color: batteryColor)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: AppTheme.spacing.sm),
          Text(
            live
                ? 'Live over Bluetooth'
                : latestBeacon != null
                    ? 'From the last beacon · ${relativeTime(latestBeacon.timestamp)}'
                    : 'No readings yet',
            style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          // Stats
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: StatPill(
                    label: 'Raw ADC',
                    value: reading != null ? '${reading.rawADC}' : '–',
                  ),
                ),
                SizedBox(width: AppTheme.spacing.sm),
                Expanded(
                  child: StatPill(
                    label: 'RSSI',
                    value: latestBeacon != null
                        ? '${latestBeacon.rssi}'
                        : '–',
                    tint: c.accent,
                  ),
                ),
                SizedBox(width: AppTheme.spacing.sm),
                Expanded(
                  child: StatPill(
                    label: 'Readings',
                    value: '${entries.length}',
                    tint: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          // History — live samples when streaming, logged beacons otherwise.
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title: 'History',
                  subtitle: live && appState.readings.isNotEmpty
                      ? 'Live voltage'
                      : 'Logged beacons, oldest first',
                ),
                SizedBox(height: AppTheme.spacing.sm),
                SizedBox(
                  height: 80,
                  width: double.infinity,
                  child: Sparkline(
                    values: _historyValues(appState, entries, live),
                    color: batteryColor,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          if (live)
            PrimaryButton(
              onPressed: () => appState.isMonitoring
                  ? appState.stopMonitoring()
                  : appState.startMonitoring(),
              child: LabelRow(
                text: appState.isMonitoring
                    ? 'Stop monitoring'
                    : 'Start monitoring',
                icon: appState.isMonitoring ? Icons.stop : Icons.play_arrow,
              ),
            )
          else
            Callout(
              text: 'This board is asleep. Connect to it from the Devices tab '
                  'while it is awake for live readings — the log below keeps '
                  'filling either way.',
              tint: c.brand,
            ),
          SizedBox(height: AppTheme.spacing.xl),

          // Calibration is only live while the app's BLE link belongs to this
          // board — offline, the Devices tab owns the section instead.
          if (live) ...[
            CalibrationSection(
              deviceId: widget.deviceId,
              isLive: true,
              rawADC: reading?.rawADC,
            ),
            SizedBox(height: AppTheme.spacing.xl),
          ],

          _AlertSection(deviceId: widget.deviceId, latestVolts: volts),
          SizedBox(height: AppTheme.spacing.xl),

          _LogSection(entries: entries),
          if (entries.isNotEmpty) ...[
            SizedBox(height: AppTheme.spacing.md),
            SecondaryButton(
              onPressed: () => _deleteLog(context, entries.length),
              child: LabelRow(
                text: 'Delete log (${entries.length} reading'
                    '${entries.length == 1 ? '' : 's'})',
                icon: Icons.delete_outline,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteLog(BuildContext context, int count) => confirmDeleteLog(
        context,
        name: widget.name,
        entryCount: count,
        onConfirmed: () =>
            context.read<AppState>().forgetDevice(widget.deviceId),
      );

  List<double> _historyValues(
    AppState appState,
    List<BeaconLogEntry> entries,
    bool live,
  ) {
    if (live && appState.readings.isNotEmpty) {
      return [for (final r in appState.readings) r.voltage];
    }
    // entriesFor is newest-first; a chart reads left-to-right in time.
    return [
      for (final e in entries.reversed)
        if (e.volts != null) e.volts!,
    ];
  }
}

/// Whether this board warns when its pack runs low, and below what.
///
/// Lives here, on the board's own page, rather than with the calibration: the
/// question is about one board in one place — the shed, the boat, the bench —
/// and two boards flashed from the same image routinely deserve different
/// answers. The log underneath is the other reason it belongs on this screen:
/// the readings that will trip it are right there to look at.
class _AlertSection extends StatelessWidget {
  final String deviceId;

  /// The board's most recent voltage, if it has ever reported one.
  final double? latestVolts;

  const _AlertSection({
    required this.deviceId,
    required this.latestVolts,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final alerts = context.read<AppState>().alerts;
    final setting = alerts.settingFor(deviceId);
    final low = latestVolts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Low battery alert',
          subtitle: 'A notification when this board is running out.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Notify me',
                        style:
                            AppTheme.font.body.copyWith(color: c.textPrimary)),
                  ),
                  Switch(
                    value: setting.enabled,
                    activeThumbColor: c.brand,
                    onChanged: (v) => alerts.setEnabled(deviceId, v),
                  ),
                ],
              ),
              if (setting.enabled) ...[
                const Divider(),
                NumberRow(
                  label: 'Warn below (V)',
                  hintText: 'Volts',
                  value: setting.thresholdVolts,
                  onChanged: (v) => alerts.setThreshold(deviceId, v),
                ),
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: Text('Remind me at most every',
                          style: AppTheme.font.body
                              .copyWith(color: c.textPrimary)),
                    ),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<Duration>(
                        value: setting.repeatAfter,
                        isDense: true,
                        borderRadius: BorderRadius.circular(AppTheme.radius.md),
                        style: AppTheme.font.body.copyWith(color: c.brand),
                        items: [
                          for (final choice
                              in DeviceAlertSetting.repeatChoices)
                            DropdownMenuItem(
                              value: choice,
                              child:
                                  Text(DeviceAlertSetting.describe(choice)),
                            ),
                        ],
                        onChanged: (choice) {
                          if (choice == null) return;
                          alerts.setRepeatAfter(deviceId, choice);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (setting.enabled) ...[
          SizedBox(height: AppTheme.spacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Warns once ${LowBatteryAlerts.samplesBeforeAlert} readings '
                  'in a row come in below this — one dip under load is not a '
                  'flat pack — then again every '
                  '${DeviceAlertSetting.describe(setting.repeatAfter)} while '
                  'it stays low. Keeps working while the app is closed, as '
                  'long as background logging is on.',
                  style:
                      AppTheme.font.footnote.copyWith(color: c.textSecondary),
                ),
              ),
              // Only worth offering once this board has an answer of its own.
              if (alerts.hasOwnSetting(deviceId))
                TextButton(
                  onPressed: () => alerts.useDefault(deviceId),
                  child: const Text('Use default'),
                ),
            ],
          ),
          if (low != null && low < setting.thresholdVolts)
            Padding(
              padding: EdgeInsets.only(top: AppTheme.spacing.sm),
              child: Callout(
                text: 'The last reading, ${low.toStringAsFixed(2)} V, is '
                    'already below this.',
                tint: c.warning,
                icon: Icons.warning_amber,
              ),
            ),
        ],
      ],
    );
  }
}

class _LogSection extends StatelessWidget {
  final List<BeaconLogEntry> entries;

  /// Long logs are the normal case; show a window rather than thousands of rows.
  static const _visible = 60;

  const _LogSection({required this.entries});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final shown = entries.take(_visible).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Log',
          subtitle: entries.isEmpty
              ? 'Every beacon this board sends is recorded here.'
              : 'Newest first'
                  '${entries.length > _visible ? ' · showing $_visible of ${entries.length}' : ''}',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        if (shown.isEmpty)
          Callout(
            text: 'Nothing logged for this board yet.',
            tint: c.textSecondary,
          )
        else
          AppCard(
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const Divider(),
                  _LogRow(entry: shown[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  final BeaconLogEntry entry;

  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final soc = entry.soc;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 116,
            child: Text(
              _stamp(entry.timestamp),
              style: AppTheme.font.caption.copyWith(color: c.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              entry.volts != null
                  ? '${entry.volts!.toStringAsFixed(2)} V'
                  : '—',
              style: AppTheme.font.mono.copyWith(
                  color: soc != null ? c.battery(soc / 100) : c.textPrimary),
            ),
          ),
          if (soc != null)
            SizedBox(
              width: 44,
              child: Text('$soc%',
                  textAlign: TextAlign.right,
                  style: AppTheme.font.caption
                      .copyWith(color: c.textSecondary)),
            ),
          SizedBox(
            width: 56,
            child: Text('${entry.rssi} dBm',
                textAlign: TextAlign.right,
                style: AppTheme.font.caption.copyWith(color: c.textSecondary)),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return sameDay ? time : '${two(t.day)}/${two(t.month)} $time';
  }
}
