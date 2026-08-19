import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/board.dart';
import '../../models/pin_configuration.dart';
import '../../services/firmware_flasher.dart';
import '../board_awake_mixin.dart';

enum _ApplyStatus { idle, applying, success, failure }

/// Let the user pick the ADC pin intuitively and dial in the divider math.
class PinConfigView extends StatefulWidget {
  const PinConfigView({super.key});

  @override
  State<PinConfigView> createState() => _PinConfigViewState();
}

class _PinConfigViewState extends State<PinConfigView>
    with BoardAwakeWhileMounted {
  _ApplyStatus _applyStatus = _ApplyStatus.idle;
  String? _applyError;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final board = appState.selectedBoard;
    final config = appState.pinConfiguration;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Pins')),
      body: (board == null || config == null)
          ? const ContentUnavailable(
              title: 'No board selected',
              message: 'Choose a board on the Setup tab first.',
              icon: Icons.memory,
            )
          : _content(context, appState, board, config),
    );
  }

  Widget _content(
    BuildContext context,
    AppState appState,
    Board board,
    PinConfiguration config,
  ) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pinPicker(context, appState, board, config),
          SizedBox(height: AppTheme.spacing.xl),
          _dividerSection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _batterySection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _rangeSummary(context, config),
          SizedBox(height: AppTheme.spacing.xl),
          _applyButton(context, appState),
        ],
      ),
    );
  }

  // MARK: Pin picker

  Widget _pinPicker(
    BuildContext context,
    AppState appState,
    Board board,
    PinConfiguration config,
  ) {
    final c = AppTheme.colorOf(context);
    final selectedPin = board.pinWithId(config.batteryPinId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Battery ADC pin',
          subtitle: 'Tap the pin you connected the battery divider to.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        Wrap(
          spacing: AppTheme.spacing.sm,
          runSpacing: AppTheme.spacing.sm,
          children: [
            for (final pin in board.adcCapablePins)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => appState.setBatteryPin(pin),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 84),
                  child: PinChip(
                    pin: pin,
                    isSelected: config.batteryPinId == pin.id,
                  ),
                ),
              ),
          ],
        ),
        if (selectedPin != null) ...[
          SizedBox(height: AppTheme.spacing.sm),
          if (!selectedPin.wifiSafeADC &&
              appState.activeTransport == FlashTransport.wifi)
            Callout(
              text: '${selectedPin.name} uses ADC2, which is unavailable while '
                  'Wi-Fi is active. Pick an ADC1 pin or use Bluetooth.',
              tint: c.warning,
              icon: Icons.warning_amber_rounded,
            )
          else if (selectedPin.note != null)
            Callout(text: selectedPin.note!, tint: c.brand, icon: Icons.info),
        ],
      ],
    );
  }

  // MARK: Divider

  Widget _dividerSection(
    BuildContext context,
    AppState appState,
    PinConfiguration config,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Voltage divider',
          subtitle: 'battery+ → R1 → (ADC pin) → R2 → GND',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: Column(
            children: [
              _NumberRow(
                label: 'R1 (kΩ)',
                value: config.dividerR1KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR1KOhm: v),
              ),
              const Divider(),
              _NumberRow(
                label: 'R2 (kΩ)',
                value: config.dividerR2KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR2KOhm: v),
              ),
              const Divider(),
              _NumberRow(
                label: 'Calibration',
                value: config.calibrationFactor,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(calibrationFactor: v),
              ),
              const Divider(),
              _NumberRow(
                label: 'Sample interval (ms)',
                value: config.sampleIntervalMs.toDouble(),
                isInteger: true,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(sampleIntervalMs: v.round()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // MARK: Battery

  Widget _batterySection(
    BuildContext context,
    AppState appState,
    PinConfiguration config,
  ) {
    final c = AppTheme.colorOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Battery pack',
          subtitle: 'Used for the percentage estimate.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: Column(
            children: [
              Row(
                children: [
                  Text('Chemistry',
                      style:
                          AppTheme.font.body.copyWith(color: c.textPrimary)),
                  const Spacer(),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<BatteryChemistry>(
                      value: config.chemistry,
                      isDense: true,
                      borderRadius:
                          BorderRadius.circular(AppTheme.radius.md),
                      style: AppTheme.font.body.copyWith(color: c.brand),
                      items: [
                        for (final chem in BatteryChemistry.values)
                          DropdownMenuItem(
                            value: chem,
                            child: Text(chem.displayName),
                          ),
                      ],
                      onChanged: (chem) {
                        if (chem == null) return;
                        appState.pinConfiguration =
                            config.copyWith(chemistry: chem);
                      },
                    ),
                  ),
                ],
              ),
              const Divider(),
              // The SwiftUI `Stepper`, clamped to the same 1...12 range.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Cells in series: ${config.cellCount}',
                      style: AppTheme.font.body.copyWith(color: c.textPrimary),
                    ),
                  ),
                  _StepperButton(
                    icon: Icons.remove,
                    onPressed: config.cellCount > 1
                        ? () => appState.pinConfiguration =
                            config.copyWith(cellCount: config.cellCount - 1)
                        : null,
                  ),
                  SizedBox(width: AppTheme.spacing.xs),
                  _StepperButton(
                    icon: Icons.add,
                    onPressed: config.cellCount < 12
                        ? () => appState.pinConfiguration =
                            config.copyWith(cellCount: config.cellCount + 1)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // MARK: Range summary

  Widget _rangeSummary(BuildContext context, PinConfiguration config) {
    final c = AppTheme.colorOf(context);
    final maxMeasurable = config.voltageFromRawADC(config.adcMaxCount);

    // IntrinsicHeight gives the Row a bounded height so `stretch` can size the
    // pills to the tallest one, the way SwiftUI's HStack does.
    return IntrinsicHeight(
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
              label: 'Max measurable',
              value: '${maxMeasurable.toStringAsFixed(2)} V',
              tint: c.accent,
            ),
          ),
          SizedBox(width: AppTheme.spacing.sm),
          Expanded(
            child: StatPill(
              label: 'ADC max',
              value: '${config.adcMaxCount}',
              tint: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // MARK: Apply

  Widget _applyButton(BuildContext context, AppState appState) {
    final c = AppTheme.colorOf(context);
    final applying = _applyStatus == _ApplyStatus.applying;

    return Column(
      children: [
        PrimaryButton(
          onPressed: applying ? null : () => _apply(appState),
          child: applying
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.textOnBrand,
                  ),
                )
              : const Text('Apply to board'),
        ),
        if (_applyStatus == _ApplyStatus.success) ...[
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: 'Configuration sent to the board.',
            tint: c.success,
            icon: Icons.check_circle,
          ),
        ] else if (_applyStatus == _ApplyStatus.failure) ...[
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: _applyError ?? 'Failed to apply configuration.',
            tint: c.danger,
            icon: Icons.cancel,
          ),
        ],
      ],
    );
  }

  Future<void> _apply(AppState appState) async {
    setState(() {
      _applyStatus = _ApplyStatus.applying;
      _applyError = null;
    });
    try {
      await appState.applyPinConfiguration();
      if (!mounted) return;
      setState(() => _applyStatus = _ApplyStatus.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applyStatus = _ApplyStatus.failure;
        _applyError = describeError(e);
      });
    }
  }
}

// MARK: - Rows

/// Label on the left, right-aligned monospaced numeric field on the right.
class _NumberRow extends StatefulWidget {
  final String label;
  final double value;
  final bool isInteger;
  final ValueChanged<double> onChanged;

  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.isInteger = false,
  });

  @override
  State<_NumberRow> createState() => _NumberRowState();
}

class _NumberRowState extends State<_NumberRow> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));

  String _format(double v) =>
      widget.isInteger ? v.round().toString() : _trimZeros(v);

  /// Matches SwiftUI's `.number` format: no trailing ".0" on whole values.
  static String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  void didUpdateWidget(_NumberRow old) {
    super.didUpdateWidget(old);
    // Reflect changes made elsewhere without fighting the user's cursor.
    final formatted = _format(widget.value);
    if (widget.value != old.value &&
        double.tryParse(_controller.text) != widget.value) {
      _controller.text = formatted;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return Row(
      children: [
        Expanded(
          child: Text(widget.label,
              style: AppTheme.font.body.copyWith(color: c.textPrimary)),
        ),
        SizedBox(
          width: 120,
          child: TextField(
            controller: _controller,
            textAlign: TextAlign.right,
            style: AppTheme.font.mono.copyWith(color: c.textPrimary),
            keyboardType: TextInputType.numberWithOptions(
                decimal: !widget.isInteger),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                widget.isInteger ? RegExp(r'[0-9]') : RegExp(r'[0-9.]'),
              ),
            ],
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: widget.label,
              hintStyle: AppTheme.font.mono.copyWith(color: c.textSecondary),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (text) {
              final parsed = double.tryParse(text);
              if (parsed != null) widget.onChanged(parsed);
            },
          ),
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _StepperButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final enabled = onPressed != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          width: 44,
          height: 32,
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            borderRadius: BorderRadius.circular(AppTheme.radius.sm),
            border: Border.all(color: c.border),
          ),
          child: Icon(icon, size: 18, color: c.textPrimary),
        ),
      ),
    );
  }
}
