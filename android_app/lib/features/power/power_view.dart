import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/device_status.dart';
import '../../services/ble_manager.dart';
import '../../services/firmware_flasher.dart';

/// Reads and writes the power block — DEVICE_PROTOCOL.md §4, handoff §7.
///
/// Everything here is phrased in terms of what the user gets (how often the
/// board reports, how long the pack lasts) rather than the raw field names.
///
/// Named for the block it writes; presented as "Board settings", because from
/// the Devices list this is simply the screen behind the gear on a row.
class PowerView extends StatefulWidget {
  const PowerView({super.key});

  @override
  State<PowerView> createState() => _PowerViewState();
}

class _PowerViewState extends State<PowerView> {
  PowerConfig _power = const PowerConfig();
  bool _showAdvanced = false;
  bool _saving = false;
  String? _error;
  bool _saved = false;

  /// True once this screen is on its way back to the Devices list, so the
  /// action that sent it there cannot be fired again on the way out.
  bool _leaving = false;

  /// What the confirmation says. A write that the board acknowledged can claim
  /// more than one that was merely sent, so the two do not share a sentence.
  String _savedText = _sentText;
  static const _sentText = 'Sent to the board.';

  /// Result of the last board action, when it deserves more than a checkmark
  /// (an identify on a board with no LED is a success the user cannot see).
  String? _note;

  /// Intervals offered as a picker, in seconds (handoff §7).
  ///
  /// The same list the Configuration screen bakes into an image, for the
  /// obvious reason: a board must never hold an interval its own settings
  /// screen cannot show back.
  static const _intervals = PowerConfig.intervalOptions;

  BLEManager get _ble => context.read<AppState>().ble;

  @override
  void initState() {
    super.initState();
    // Seed from whatever the board last reported, so the picker opens on the
    // board's real interval rather than a guess.
    final status = context.read<AppState>().ble.status;
    if (status?.nextWakeSec != null) {
      _power = status!.mode == RunMode.wifi
          ? _power.copyWith(wifiReportSec: status.nextWakeSec)
          : _power.copyWith(bleWakeSec: status.nextWakeSec);
    }
  }

  RunMode get _mode => _ble.status?.mode ?? RunMode.ble;

  int get _interval => _power.intervalSecFor(_mode);

  void _setInterval(int seconds) => setState(() {
        _power = _mode == RunMode.wifi
            ? _power.copyWith(wifiReportSec: seconds)
            : _power.copyWith(bleWakeSec: seconds);
        _saved = false;
      });

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _saved = false;
      _note = null;
    });
    try {
      // Acked, not just written: the confirmation below is a promise that the
      // board stored this, so it has to come from the board (§2.5).
      await _ble.withAwakeBoard(() => _ble.writePowerAcked(_power));
      if (!mounted) return;
      setState(() {
        _saving = false;
        _leaving = true;
        _saved = true;
        _savedText = 'The board confirmed the new settings. Back to Devices…';
      });
      // The board has it and there is nothing left to do here, so go back to
      // the list. The pause is just long enough to read the confirmation.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      _leaveToDevices();
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeError(e));
    }
    if (mounted) setState(() => _saving = false);
  }

  /// Back to the Devices list this screen was pushed from.
  void _leaveToDevices() {
    context.read<AppState>().selectedTab = AppState.devicesTab;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Hand the board back to its sleep cycle and drop the link.
  ///
  /// Without this the only ways out are the board's idle timeout and walking
  /// out of range, neither of which the user can see happen.
  Future<void> _disconnect() async {
    try {
      await _ble.sleepNow();
    } catch (_) {
      // v1 board, or the link is already gone — disconnecting is still right.
    }
    if (mounted) _leaveToDevices();
    await _ble.disconnect();
  }

  /// [leaves] marks an action that ends the session it runs in — a factory
  /// reset reboots the board, so staying on a screen bound to a link that no
  /// longer exists only leaves the user somewhere to be confused.
  Future<void> _session(
    String label,
    Future<void> Function() action, {
    String? confirm,
    bool leaves = false,
  }) async {
    if (confirm != null && !await _confirm(confirm)) return;
    setState(() {
      _error = null;
      _saved = false;
      _savedText = _sentText;
      _note = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() => _saved = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$label failed: ${describeError(e)}');
      return;
    }
    if (!leaves) return;
    setState(() => _leaving = true);
    // Short: the board is rebooting as we wait, so there is nothing to be
    // gained by lingering on a screen whose link is already going away.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    _leaveToDevices();
    // After the pop, so the screen never flashes its "not connected" state on
    // the way out.
    await _ble.disconnect();
  }

  /// Identify reports back whether anything actually lit up, so a board with
  /// no status LED says so instead of pretending it blinked.
  Future<void> _identify() async {
    setState(() {
      _error = null;
      _saved = false;
      _note = null;
    });
    try {
      final blinked = await _ble.identify();
      if (!mounted) return;
      setState(() => _note = blinked
          ? 'The board is blinking its LED now.'
          : 'This board has no status LED, so nothing will blink. Wire one and '
              'reflash with -DSTATUS_LED_PIN=<gpio> to use Identify.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Identify failed: ${describeError(e)}');
    }
  }

  Future<bool> _confirm(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Are you sure?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Board settings')),
      body: ListenableBuilder(
        listenable: _ble,
        builder: (context, _) {
          if (!_ble.connection.isConnected) {
            return const ContentUnavailable(
              title: 'Board not connected',
              message:
                  'Connect to a board on the Devices tab to change how it sleeps.',
              icon: Icons.settings,
            );
          }
          if (!_ble.supportsV2) {
            return const ContentUnavailable(
              title: 'Not supported',
              message:
                  'This board runs firmware 1.x, which has no sleep control.',
              icon: Icons.battery_saver,
            );
          }
          return _body(context);
        },
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return SingleChildScrollView(
      padding: EdgeInsets.all(AppTheme.spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Reporting interval',
            subtitle: 'How often the board wakes in ${_mode.displayName} mode.',
          ),
          SizedBox(height: AppTheme.spacing.sm),
          Wrap(
            spacing: AppTheme.spacing.sm,
            runSpacing: AppTheme.spacing.sm,
            children: [
              for (final seconds in _intervals)
                _IntervalChip(
                  label: PowerConfig.intervalLabel(seconds),
                  isSelected: _interval == seconds,
                  onTap: () => _setInterval(seconds),
                ),
            ],
          ),
          SizedBox(height: AppTheme.spacing.sm),
          Callout(text: PowerConfig.batteryHint(_interval), tint: c.brand),
          SizedBox(height: AppTheme.spacing.xl),

          const SectionHeader(
            title: 'Sleep',
            subtitle: 'Turning this off keeps the board awake — and flattens '
                'the pack in hours rather than weeks.',
          ),
          SizedBox(height: AppTheme.spacing.sm),
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('Sleep between readings',
                      style:
                          AppTheme.font.body.copyWith(color: c.textPrimary)),
                ),
                Switch(
                  value: _power.sleepEnabled,
                  onChanged: (v) => setState(() {
                    _power = _power.copyWith(sleepEnabled: v);
                    _saved = false;
                  }),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xl),

          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Expanded(
                  child: SectionHeader(
                    title: 'Advanced',
                    subtitle: _showAdvanced
                        ? 'Windows and timeouts, in milliseconds.'
                        : 'Wake windows, idle timeout, BLE during Wi-Fi.',
                  ),
                ),
                Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more,
                    color: c.textSecondary),
              ],
            ),
          ),
          if (_showAdvanced) ...[
            SizedBox(height: AppTheme.spacing.sm),
            AppCard(
              child: Column(
                children: [
                  _NumberRow(
                    label: 'BLE window (ms)',
                    value: _power.bleWindowMs,
                    onChanged: (v) => setState(() {
                      _power = _power.copyWith(bleWindowMs: v);
                      _saved = false;
                    }),
                  ),
                  const Divider(),
                  _NumberRow(
                    label: 'BLE idle timeout (ms)',
                    value: _power.bleIdleMs,
                    onChanged: (v) => setState(() {
                      _power = _power.copyWith(bleIdleMs: v);
                      _saved = false;
                    }),
                  ),
                  const Divider(),
                  _NumberRow(
                    label: 'Wi-Fi window (ms)',
                    value: _power.wifiWindowMs,
                    onChanged: (v) => setState(() {
                      _power = _power.copyWith(wifiWindowMs: v);
                      _saved = false;
                    }),
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text('BLE while in Wi-Fi mode',
                            style: AppTheme.font.body
                                .copyWith(color: c.textPrimary)),
                      ),
                      Switch(
                        value: _power.bleInWifi,
                        onChanged: (v) => setState(() {
                          _power = _power.copyWith(bleInWifi: v);
                          _saved = false;
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: AppTheme.spacing.xl),

          PrimaryButton(
            onPressed: _saving || _leaving ? null : _save,
            child: _saving
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.textOnBrand),
                  )
                : const Text('Apply to board'),
          ),
          if (_saved) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Callout(
                text: _savedText, tint: c.success, icon: Icons.check_circle),
          ],
          if (_error != null) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Callout(text: _error!, tint: c.danger, icon: Icons.cancel),
          ],
          SizedBox(height: AppTheme.spacing.xxl),

          const SectionHeader(
            title: 'Board actions',
            subtitle: 'These take effect immediately.',
          ),
          SizedBox(height: AppTheme.spacing.sm),
          SecondaryButton(
            onPressed: _identify,
            child: const LabelRow(
                text: 'Identify (blink the LED)', icon: Icons.lightbulb),
          ),
          if (_note != null) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Callout(text: _note!, tint: c.brand, icon: Icons.info),
          ],
          SizedBox(height: AppTheme.spacing.sm),
          SecondaryButton(
            onPressed: () => _session('Forget Wi-Fi', _ble.forgetWifi,
                confirm: 'The board will drop its Wi-Fi credentials and fall '
                    'back to Bluetooth mode.'),
            child: const LabelRow(text: 'Forget Wi-Fi', icon: Icons.wifi_off),
          ),
          SizedBox(height: AppTheme.spacing.sm),
          SecondaryButton(
            onPressed: _disconnect,
            child: const LabelRow(
                text: 'Disconnect Bluetooth', icon: Icons.bluetooth_disabled),
          ),
          SizedBox(height: AppTheme.spacing.sm),
          _DangerButton(
            label: 'Factory reset',
            icon: Icons.restart_alt,
            onPressed: () => _session('Factory reset', _ble.factoryReset,
                confirm: 'This wipes the board’s settings and reboots it '
                    'into pairing mode. You will have to set it up again.',
                leaves: true),
          ),
        ],
      ),
    );
  }

}

/// One wake interval, offered as a tappable pill. Twelve options do not fit a
/// segmented control, and they are the whole useful range.
class _IntervalChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _IntervalChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.quick,
        constraints: const BoxConstraints(minWidth: 64),
        padding: EdgeInsets.symmetric(
            horizontal: AppTheme.spacing.md, vertical: AppTheme.spacing.sm),
        decoration: BoxDecoration(
          color: isSelected ? c.brand.withValues(alpha: 0.16) : c.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius.pill),
          border: Border.all(color: isSelected ? c.brand : c.border),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppTheme.font.subheadline.copyWith(
            color: isSelected ? c.brand : c.textPrimary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _NumberRow extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_NumberRow> createState() => _NumberRowState();
}

class _NumberRowState extends State<_NumberRow> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value.toString());

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
          width: 110,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.right,
            style: AppTheme.font.mono.copyWith(color: c.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (text) {
              final parsed = int.tryParse(text);
              if (parsed != null) widget.onChanged(parsed);
            },
          ),
        ),
      ],
    );
  }
}

class _DangerButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _DangerButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.md),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radius.md),
        ),
        child: DefaultTextStyle(
          style: AppTheme.font.headline.copyWith(color: c.danger),
          child: IconTheme(
            data: IconThemeData(color: c.danger, size: 20),
            child: Center(child: LabelRow(text: label, icon: icon)),
          ),
        ),
      ),
    );
  }
}
