import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/beacon_log.dart';
import '../../models/device_alert_setting.dart';
import '../../models/pin_configuration.dart';
import '../../services/ble_manager.dart';
import '../../services/low_battery_alerts.dart';
import '../board_awake_mixin.dart';
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

          _CalibrationSection(
            deviceId: widget.deviceId,
            isLive: live,
            rawADC: reading?.rawADC,
          ),
          SizedBox(height: AppTheme.spacing.xl),

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

/// Dialling in what this board's raw ADC count means, and pushing the answer
/// back to it.
///
/// On the board's own page rather than the Configuration screen for the same
/// reason the low-battery threshold is: the divider soldered to *this* board is
/// a fact about this board, and the reading it produces is right above it to
/// check the arithmetic against. Configuration is where a board is described
/// before it exists; this is where a board on the bench is corrected.
///
/// Edits land in the working configuration immediately, so the pill below moves
/// as the numbers are typed — the app can already read the board differently
/// without asking it anything. "Send to device" is the separate, slower half:
/// making the board itself agree, so its own beacons and its own percentage
/// carry the same numbers when the phone is not listening.
class _CalibrationSection extends StatefulWidget {
  final String deviceId;

  /// True when the app's BLE link belongs to this board. Nothing can be sent
  /// otherwise, and there is no live count to calibrate against.
  final bool isLive;

  /// The board's most recent raw ADC count — live only.
  final int? rawADC;

  const _CalibrationSection({
    required this.deviceId,
    required this.isLive,
    required this.rawADC,
  });

  @override
  State<_CalibrationSection> createState() => _CalibrationSectionState();
}

class _CalibrationSectionState extends State<_CalibrationSection> {
  bool _sending = false;
  String? _error;

  /// The configuration as this board last accepted it, so the screen can say
  /// whether what is on it has actually reached the hardware. Null means "never
  /// sent from here", which is not the same as "matches" — the board's own
  /// stored numbers are unknown until we write them.
  PinConfiguration? _sent;

  /// A meter reading, typed in to set the trim from. Not part of the
  /// configuration: it is the evidence, not the setting.
  double? _measured;

  /// Digits kept on a back-solved trim.
  ///
  /// Dividing two floats gives something like 1.0234567890123 — true, unusable
  /// as a number to read or retype, and false precision besides: it comes from
  /// one noisy ADC sample and a meter with three digits.
  static double _round(double factor) =>
      (factor * 10000).roundToDouble() / 10000;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final appState = context.watch<AppState>();
    final config = appState.pinConfiguration;

    if (config == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Calibration'),
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: 'Pick this board on the Configuration screen first — the '
                'divider and the trim hang off the board they are wired to.',
            tint: c.textSecondary,
          ),
        ],
      );
    }

    final raw = widget.rawADC;
    final reads = raw == null ? null : config.voltageFromRawADC(raw);
    final maxMeasurable = config.voltageFromRawADC(config.adcMaxCount);
    final unsent = _sent != config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Calibration',
          subtitle: 'battery+ → R1 → (ADC pin) → R2 → GND, times a trim.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: Column(
            children: [
              NumberRow(
                label: 'R1 (kΩ)',
                hintText: 'kΩ',
                value: config.dividerR1KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR1KOhm: v),
              ),
              const Divider(),
              NumberRow(
                label: 'R2 (kΩ)',
                hintText: 'kΩ',
                value: config.dividerR2KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR2KOhm: v),
              ),
              const Divider(),
              NumberRow(
                label: 'Calibration',
                hintText: 'Factor',
                value: config.calibrationFactor,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(calibrationFactor: v),
              ),
              const Divider(),
              _MeasuredRow(
                volts: _measured,
                // Without a live count there is nothing to solve against, and a
                // field that silently does nothing is worse than a greyed one.
                enabled: raw != null,
                onChanged: (v) => _setMeasured(appState, config, v),
              ),
            ],
          ),
        ),
        SizedBox(height: AppTheme.spacing.xs),
        Text(
          raw != null
              ? 'Put a meter across the pack, type what it says, and the trim '
                  'moves to make the board agree.'
              : 'Connect to this board while it is awake to calibrate against '
                  'a meter reading.',
          style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
        ),
        SizedBox(height: AppTheme.spacing.md),

        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: StatPill(
                  label: 'Divider ratio',
                  value: '${config.dividerRatio.toStringAsFixed(2)}×',
                ),
              ),
              SizedBox(width: AppTheme.spacing.sm),
              Expanded(
                child: StatPill(
                  label: 'Reads now',
                  value: reads != null ? '${reads.toStringAsFixed(2)} V' : '–',
                  tint: c.accent,
                ),
              ),
              SizedBox(width: AppTheme.spacing.sm),
              Expanded(
                child: StatPill(
                  label: 'Max measurable',
                  value: '${maxMeasurable.toStringAsFixed(2)} V',
                  tint: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: AppTheme.spacing.md),

        PrimaryButton(
          onPressed: widget.isLive && !_sending ? () => _send(appState) : null,
          child: _sending
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.textOnBrand),
                )
              : const LabelRow(
                  text: 'Send to device', icon: Icons.arrow_upward),
        ),
        SizedBox(height: AppTheme.spacing.sm),
        if (_error != null)
          Callout(text: _error!, tint: c.danger, icon: Icons.error_outline)
        else if (!widget.isLive)
          Callout(
            text: 'This board is not connected. The numbers above already '
                'change how the app reads it; sending is what makes the board '
                'itself use them.',
            tint: c.brand,
          )
        else if (unsent)
          Callout(
            text: 'Not sent yet — the board is still working from whatever it '
                'was last given.',
            tint: c.warning,
            icon: Icons.warning_amber_rounded,
          )
        else
          Callout(
            text: 'Sent. The board stored these and reports through them from '
                'its next reading on.',
            tint: c.success,
            icon: Icons.check_circle_outline,
          ),
      ],
    );
  }

  /// Take a meter reading and trim the configuration until the board matches.
  ///
  /// Deliberately one-shot: it moves the trim at the moment it is typed and
  /// then leaves it alone. Re-solving on every later edit to R1 or R2 would
  /// make the Calibration row above unusable, since anything typed into it
  /// would be overwritten by the next keystroke somewhere else.
  void _setMeasured(
      AppState appState, PinConfiguration config, double? volts) {
    setState(() => _measured = volts);
    final raw = widget.rawADC;
    if (raw == null || volts == null) return;
    final factor =
        config.calibrationFactorForMeasured(raw: raw, measuredVolts: volts);
    if (factor == null) return;
    appState.pinConfiguration =
        config.copyWith(calibrationFactor: _round(factor));
  }

  Future<void> _send(AppState appState) async {
    // Captured before the await so a keystroke landing mid-write cannot be
    // recorded as sent; `sendPinConfigurationTo` reads the same object.
    final sending = appState.pinConfiguration;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await appState.sendPinConfigurationTo(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _sent = sending;
        _sending = false;
      });
    } on BLEException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'The board did not take the calibration. It may have gone '
            'back to sleep — wake it and try again.';
        _sending = false;
      });
    }
  }
}

/// A meter reading, or nothing at all — which is the resting state, because it
/// is evidence somebody fetches rather than a setting with a sensible default.
class _MeasuredRow extends StatefulWidget {
  final double? volts;
  final bool enabled;
  final ValueChanged<double?> onChanged;

  const _MeasuredRow({
    required this.volts,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_MeasuredRow> createState() => _MeasuredRowState();
}

class _MeasuredRowState extends State<_MeasuredRow> {
  late final TextEditingController _controller = TextEditingController(
      text: widget.volts == null ? '' : widget.volts!.toStringAsFixed(2));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final color = widget.enabled ? c.textPrimary : c.textSecondary;

    return Row(
      children: [
        Expanded(
          child: Text('Measured (V)',
              style: AppTheme.font.body.copyWith(color: color)),
        ),
        SizedBox(
          width: 120,
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            textAlign: TextAlign.right,
            style: AppTheme.font.mono.copyWith(color: color),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              disabledBorder: InputBorder.none,
              hintText: 'Meter',
              hintStyle: AppTheme.font.mono.copyWith(color: c.textSecondary),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (text) => widget.onChanged(double.tryParse(text)),
          ),
        ),
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
