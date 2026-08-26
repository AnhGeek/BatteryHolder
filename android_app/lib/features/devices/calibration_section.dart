import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/pin_configuration.dart';
import '../../services/ble_manager.dart';

/// Dialling in what a board's raw ADC count means, and pushing the answer back
/// to it.
///
/// Lives where a board is in hand: on the Board settings screen once a board
/// is linked, and on a board's own page while the BLE link is up. Not on the
/// Configuration screen, for the same reason the low-battery threshold is not —
/// the divider soldered to *this* board is a fact about this board, and the
/// reading it produces sits right above it to check the arithmetic against.
///
/// Edits land in the working configuration immediately, so the pills below move
/// as the numbers are typed — the app can already read the board differently
/// without asking it anything. "Send to device" is the separate, slower half:
/// making the board itself agree, so its own beacons and its own percentage
/// carry the same numbers when the phone is not listening.
class CalibrationSection extends StatefulWidget {
  final String deviceId;

  /// True when the app's BLE link belongs to this board. Nothing can be sent
  /// otherwise, and there is no live count to calibrate against.
  final bool isLive;

  /// The board's most recent raw ADC count — live only.
  final int? rawADC;

  /// False when a parent screen sends the configuration itself and shows its
  /// own feedback — the board settings screen's "Apply to board". The section
  /// then hides its own send button and the sent / not-sent callouts.
  final bool showSendButton;

  const CalibrationSection({
    super.key,
    required this.deviceId,
    required this.isLive,
    required this.rawADC,
    this.showSendButton = true,
  });

  @override
  State<CalibrationSection> createState() => _CalibrationSectionState();
}

class _CalibrationSectionState extends State<CalibrationSection> {
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A board being calibrated is a board in hand — the section must work
    // without a trip through Setup first. When nothing has been configured,
    // seed a generic default; edits then land in AppState as usual and travel
    // with the board. Deferred a frame so the notification happens outside the
    // build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.pinConfiguration ??= PinConfiguration.standalone();
    });
  }

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

        if (widget.showSendButton) ...[
          PrimaryButton(
            onPressed:
                widget.isLive && !_sending ? () => _send(appState) : null,
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
                  'change how the app reads it; sending is what makes the '
                  'board itself use them.',
              tint: c.brand,
            )
          else if (unsent)
            Callout(
              text: 'Not sent yet — the board is still working from whatever '
                  'it was last given.',
              tint: c.warning,
              icon: Icons.warning_amber_rounded,
            )
          else
            Callout(
              text: 'Sent. The board stored these and reports through them '
                  'from its next reading on.',
              tint: c.success,
              icon: Icons.check_circle_outline,
            ),
        ],
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
