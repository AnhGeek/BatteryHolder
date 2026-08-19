import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../board_awake_mixin.dart';

/// Live battery voltage from the connected board.
class MonitorView extends StatefulWidget {
  const MonitorView({super.key});

  @override
  State<MonitorView> createState() => _MonitorViewState();
}

class _MonitorViewState extends State<MonitorView>
    with BoardAwakeWhileMounted {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Monitor')),
      body: appState.pinConfiguration == null
          ? const ContentUnavailable(
              title: 'Not configured',
              message: 'Select a board and battery pin on the Setup tab.',
              icon: Icons.bolt_outlined,
            )
          : _MonitorContent(appState: appState),
    );
  }
}

class _MonitorContent extends StatelessWidget {
  final AppState appState;

  const _MonitorContent({required this.appState});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final reading = appState.latestReading;
    final pct = reading?.percentage ?? 0;
    final batteryColor = c.battery(pct);

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
                  BatteryGauge(fraction: pct, color: batteryColor),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        reading != null
                            ? reading.voltage.toStringAsFixed(2)
                            : '–––',
                        style: AppTheme.font.monoLarge
                            .copyWith(color: c.textPrimary),
                      ),
                      SizedBox(height: AppTheme.spacing.xs),
                      Text('volts',
                          style: AppTheme.font.footnote
                              .copyWith(color: c.textSecondary)),
                      SizedBox(height: AppTheme.spacing.xs),
                      Text('${(pct * 100).toStringAsFixed(0)}%',
                          style: AppTheme.font.headline
                              .copyWith(color: batteryColor)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          // Stats — IntrinsicHeight bounds the Row so `stretch` can equalize the
          // pill heights inside the unbounded scroll view.
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
                    label: 'Pin',
                    value: _pinName,
                    tint: c.accent,
                  ),
                ),
                SizedBox(width: AppTheme.spacing.sm),
                Expanded(
                  child: StatPill(
                    label: 'Transport',
                    value: appState.activeTransport.displayName,
                    tint: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          // History
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                    title: 'History', subtitle: 'Recent voltage'),
                SizedBox(height: AppTheme.spacing.sm),
                SizedBox(
                  height: 80,
                  width: double.infinity,
                  child: Sparkline(
                    values: [
                      for (final r in appState.readings) r.voltage,
                    ],
                    color: batteryColor,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          // Controls
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
          ),
        ],
      ),
    );
  }

  String get _pinName {
    final id = appState.pinConfiguration?.batteryPinId;
    if (id == null) return '–';
    return appState.selectedBoard?.pinWithId(id)?.name ?? '–';
  }
}
