import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/device_status.dart';
import '../../models/firmware_bundle.dart';
import '../../services/usb_flash_service.dart';

/// Bringing a brand-new board to life, over the cable.
///
/// This is the only path that works on hardware nobody has configured yet: no
/// Bluetooth pairing, no Wi-Fi credentials, nothing in NVS. The app writes the
/// firmware it ships with and drops the whole configuration — sensing chain,
/// run mode, wake timers, credentials — into the board's own flash region, all
/// through the OTG port. The board applies it on the next boot, so it comes off
/// the cable set up rather than waiting to be asked over Bluetooth.
class UsbFlashCard extends StatefulWidget {
  const UsbFlashCard({super.key});

  @override
  State<UsbFlashCard> createState() => _UsbFlashCardState();
}

class _UsbFlashCardState extends State<UsbFlashCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().usbFlasher.refreshDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final plan = appState.flashPlan;

    return ListenableBuilder(
      listenable: appState.usbFlasher,
      builder: (context, _) {
        final usb = appState.usbFlasher;

        final attached = usb.selectedDevice != null;
        // A session that has already said something keeps its console even
        // after the port goes away: a board with native USB drops off the bus
        // the moment it reboots, and that is precisely when the log matters.
        final session =
            usb.phase != UsbFlashPhase.idle || usb.log.isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              title: 'New board over USB',
              subtitle: 'Flash and calibrate a board that has never been set up.',
            ),
            SizedBox(height: AppTheme.spacing.lg),
            _deviceCard(context, usb),

            // Nothing below here can do anything without a board on the port,
            // and offering it anyway just buries the one thing that needs
            // fixing.
            if (attached) ...[
              SizedBox(height: AppTheme.spacing.lg),
              if (plan == null) ...[
                _noPlan(context, appState),
                // "Check board" follows straight after "Open Setup"; without
                // this the two tinted buttons touch and read as one block.
                SizedBox(height: AppTheme.spacing.sm),
              ] else ...[
                _planCard(context, plan, appState),
                SizedBox(height: AppTheme.spacing.lg),
              ],
              ..._actions(context, appState, usb, plan),
            ],
            if (session) ...[
              SizedBox(height: AppTheme.spacing.lg),
              _progressCard(context, usb),
            ],
          ],
        );
      },
    );
  }

  // MARK: Pieces

  /// Buttons for where the session is.
  ///
  /// A verified board is sitting in its bootloader waiting to be told to run
  /// what was written, so that is the only thing offered until it has been —
  /// flashing again from there is safe, and rebooting is the one step that
  /// cannot be taken back.
  List<Widget> _actions(
    BuildContext context,
    AppState appState,
    UsbFlashService usb,
    FlashPlan? plan,
  ) {
    final c = AppTheme.colorOf(context);
    final busy = usb.isBusy;

    if (usb.awaitingReboot) {
      return [
        PrimaryButton(
          onPressed: busy ? null : () => _reboot(appState),
          child: busy
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.textOnBrand),
                )
              : const LabelRow(
                  text: 'Reboot and confirm', icon: Icons.play_circle),
        ),
        SizedBox(height: AppTheme.spacing.sm),
        SecondaryButton(
          onPressed: busy || plan == null ? null : () => _flash(appState, plan),
          child: const LabelRow(text: 'Write again', icon: Icons.usb),
        ),
      ];
    }

    return [
      if (plan != null) ...[
        PrimaryButton(
          onPressed: busy ? null : () => _flash(appState, plan),
          child: busy
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.textOnBrand),
                )
              : const LabelRow(text: 'Flash board over USB', icon: Icons.usb),
        ),
        SizedBox(height: AppTheme.spacing.sm),
        SecondaryButton(
          onPressed: busy ? null : () => _verify(appState, plan),
          child: const LabelRow(
              text: 'Verify what is on the board', icon: Icons.verified),
        ),
        SizedBox(height: AppTheme.spacing.sm),
        SecondaryButton(
          onPressed: busy ? null : () => _calibrateOnly(appState, plan),
          child:
              const LabelRow(text: 'Send calibration only', icon: Icons.tune),
        ),
        SizedBox(height: AppTheme.spacing.sm),
      ],
      // Always available: it writes nothing and resets nothing, so it is the
      // safe way to find out what a board is actually running.
      SecondaryButton(
        onPressed: busy ? null : () => _check(appState),
        child: const LabelRow(text: 'Check board', icon: Icons.fact_check),
      ),
    ];
  }

  Widget _noPlan(BuildContext context, AppState appState) {
    final c = AppTheme.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Callout(
          text: 'Set the ADC pin and divider on the Configuration screen, then '
              'tap "Generate BIN file". The image lands here, ready to flash.',
          tint: c.brand,
          icon: Icons.info,
        ),
        SizedBox(height: AppTheme.spacing.md),
        SecondaryButton(
          onPressed: () => appState.selectedTab = AppState.setupTab,
          child: const LabelRow(text: 'Open Setup', icon: Icons.memory),
        ),
      ],
    );
  }

  Widget _planCard(BuildContext context, FlashPlan plan, AppState appState) {
    final c = AppTheme.colorOf(context);
    final calibration = plan.calibrationPayload;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(plan.bundle.name,
                    style:
                        AppTheme.font.headline.copyWith(color: c.textPrimary)),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: AppTheme.spacing.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radius.pill),
                ),
                child: Text('image ready',
                    style: AppTheme.font.caption.copyWith(color: c.success)),
              ),
            ],
          ),
          SizedBox(height: AppTheme.spacing.sm),
          _row(context, 'Images',
              '${plan.segments.length} · ${_kb(plan.totalBytes)}'),
          const Divider(),
          _row(context, 'Battery pin', '${calibration['batteryPinId']}'),
          const Divider(),
          _row(
            context,
            'Divider',
            '${calibration['dividerR1KOhm']}k / ${calibration['dividerR2KOhm']}k '
                '· ×${calibration['calibrationFactor']}',
          ),
          const Divider(),
          // The reason this screen no longer hands the user off to a setup
          // wizard: the mode and the timer are in the bytes about to be
          // written, so the board is set up as soon as it boots.
          _row(context, 'Runs as', plan.bootMode.displayName),
          const Divider(),
          _row(
            context,
            'Wakes every',
            PowerConfig.intervalLabel(
                plan.setup?.intervalSec ?? const PowerConfig().bleWakeSec),
          ),
          if (plan.setup?.mode == RunMode.wifi &&
              (plan.setup?.ssid ?? '').isNotEmpty) ...[
            const Divider(),
            _row(context, 'Joins', plan.setup!.ssid),
          ],
          const Divider(),
          _row(context, 'Calibration at',
              '0x${plan.bundle.calibration.offset.toRadixString(16)}'),
          if (appState.generatedImagePath != null) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Text(
              'Saved ${appState.generatedImagePath!.split('/').last}',
              style: AppTheme.font.caption.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deviceCard(BuildContext context, UsbFlashService usb) {
    final c = AppTheme.colorOf(context);
    final device = usb.selectedDevice;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(device == null ? Icons.usb_off : Icons.usb,
                  color: device == null ? c.textSecondary : c.brand),
              SizedBox(width: AppTheme.spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device?.title ?? 'No board on the USB port',
                      style:
                          AppTheme.font.body.copyWith(color: c.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device == null
                          ? 'Connect it with an OTG adapter and a data cable.'
                          : '${device.idsDisplay} · ${device.driver}',
                      style: AppTheme.font.caption
                          .copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: usb.isBusy ? null : () => usb.refreshDevices(),
                child: Text('Rescan',
                    style: AppTheme.font.footnote.copyWith(color: c.brand)),
              ),
            ],
          ),
          if (usb.devices.length > 1) ...[
            const Divider(),
            for (final option in usb.devices)
              RadioListTile<int>(
                value: option.deviceId,
                // ignore: deprecated_member_use
                groupValue: device?.deviceId,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(option.title,
                    style:
                        AppTheme.font.footnote.copyWith(color: c.textPrimary)),
                // ignore: deprecated_member_use
                onChanged: usb.isBusy
                    ? null
                    : (_) => usb.selectedDevice = option,
              ),
          ],
        ],
      ),
    );
  }

  Widget _progressCard(BuildContext context, UsbFlashService usb) {
    final c = AppTheme.colorOf(context);
    final failed = usb.phase == UsbFlashPhase.failed;
    final done = usb.phase == UsbFlashPhase.done;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(usb.phase.displayName,
                    style:
                        AppTheme.font.headline.copyWith(color: c.textPrimary)),
              ),
              if (done)
                Icon(Icons.check_circle, color: c.success, size: 20)
              else if (failed)
                Icon(Icons.cancel, color: c.danger, size: 20),
            ],
          ),
          if (usb.phase == UsbFlashPhase.writing) ...[
            SizedBox(height: AppTheme.spacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radius.pill),
              child: LinearProgressIndicator(
                value: usb.progress,
                minHeight: 4,
                color: c.brand,
                backgroundColor: c.border,
              ),
            ),
            SizedBox(height: AppTheme.spacing.xs),
            Text('${(usb.progress * 100).round()}%',
                style: AppTheme.font.caption.copyWith(color: c.textSecondary)),
          ],
          if (usb.log.isNotEmpty) ...[
            SizedBox(height: AppTheme.spacing.sm),
            _ConsoleLog(entries: usb.log),
          ],
          if (usb.phase == UsbFlashPhase.verified) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Callout(
              text: usb.firmwareVerified
                  ? 'Every image was read back off the board and matches. '
                      'Nothing has rebooted: the board is still in its '
                      'bootloader, so you can write again from here. Tap '
                      '"Reboot and confirm" to run it — or just unplug it, '
                      'which starts the new firmware too.'
                  : 'Writing finished. This chip cannot checksum its own '
                      'flash, so the write acknowledgements are all the '
                      'confirmation there is.',
              tint: usb.firmwareVerified ? c.success : c.warning,
              icon: usb.firmwareVerified
                  ? Icons.verified
                  : Icons.warning_amber_rounded,
            ),
          ],
          if (usb.boardStatus != null) ...[
            SizedBox(height: AppTheme.spacing.sm),
            _boardCard(context, usb),
          ],
          if (done) ...[
            SizedBox(height: AppTheme.spacing.sm),
            Callout(
              text: usb.boardStatus?['mode'] == 'pairing'
                  ? 'The board is running the new firmware and waiting to be '
                      'claimed, because the image was built with "Decide '
                      'later". Find it on the Devices tab to set it up.'
                  : 'The board is running the new firmware with the settings '
                      'from the image. Unplug it — there is nothing left to set '
                      'up. The Devices tab is where you change it later.',
              tint: c.success,
              icon: Icons.check_circle,
            ),
          ],
        ],
      ),
    );
  }

  /// The board's own account of itself, straight off the serial console.
  Widget _boardCard(BuildContext context, UsbFlashService usb) {
    final c = AppTheme.colorOf(context);
    final status = usb.boardStatus!;
    final calibration = usb.boardCalibration;

    return Container(
      padding: EdgeInsets.all(AppTheme.spacing.md),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        borderRadius: BorderRadius.circular(AppTheme.radius.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('On the board',
              style: AppTheme.font.footnote.copyWith(color: c.textSecondary)),
          SizedBox(height: AppTheme.spacing.xs),
          if (status['name'] != null) ...[
            _row(context, 'Name', '${status['name']}'),
            const Divider(),
          ],
          _row(context, 'Firmware', '${status['fw']}'),
          const Divider(),
          _row(context, 'Device id', '${status['id']}'),
          const Divider(),
          _row(context, 'Mode', '${status['mode']}'),
          if (calibration != null) ...[
            const Divider(),
            _row(context, 'Stored pin', '${calibration['batteryPinId']}'),
            const Divider(),
            _row(
              context,
              'Stored divider',
              '${calibration['dividerR1KOhm']}k / '
                  '${calibration['dividerR2KOhm']}k',
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final c = AppTheme.colorOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: AppTheme.font.body.copyWith(color: c.textPrimary)),
          ),
          Text(value,
              style: AppTheme.font.mono.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }

  // MARK: Actions

  Future<void> _flash(AppState appState, FlashPlan plan) async {
    try {
      await appState.usbFlasher.flash(plan);
    } catch (_) {
      // The service already logged it and moved to the failed phase.
    }
  }

  Future<void> _calibrateOnly(AppState appState, FlashPlan plan) async {
    try {
      await appState.usbFlasher.sendCalibration(plan);
    } catch (_) {
      // Same: the log on screen is the report.
    }
    await _offerNextStep(appState);
  }

  Future<void> _verify(AppState appState, FlashPlan plan) =>
      appState.usbFlasher.verifyFlash(plan);

  Future<void> _reboot(AppState appState) async {
    await appState.usbFlasher.rebootAndConfirm();
    await _offerNextStep(appState);
  }

  /// Asked once the board is flashed, calibrated and running.
  ///
  /// The board is finished at this point, and there are exactly two things
  /// anyone wants next: read it back one more time to be sure, or get on with
  /// pairing it. Anything else is on the screen behind this.
  Future<void> _offerNextStep(AppState appState) async {
    final usb = appState.usbFlasher;
    if (!mounted || usb.phase != UsbFlashPhase.done) return;

    final name = usb.boardStatus?['name'] ?? usb.boardStatus?['id'];
    final again = await showDialog<bool>(
      context: context,
      builder: (context) {
        final c = AppTheme.colorOf(context);
        return AlertDialog(
          backgroundColor: c.surfaceElevated,
          title: Text(
            name == null ? 'Board ready' : 'Board ready — $name',
            style: AppTheme.font.headline.copyWith(color: c.textPrimary),
          ),
          content: Text(
            usb.boardStatus?['mode'] == 'pairing'
                ? 'The firmware and the calibration are both on the board and '
                    'it is running them, but the image left the run mode open. '
                    'Read it back once more, or set it up from Devices.'
                : 'The board is flashed, calibrated and already running in '
                    '${usb.boardStatus?['mode'] ?? 'its configured'} mode — '
                    'nothing left to set up. Read it back once more, or go and '
                    'watch it report.',
            style: AppTheme.font.body.copyWith(color: c.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Verify again',
                  style: AppTheme.font.body.copyWith(color: c.brand)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Go to Devices',
                  style: AppTheme.font.body.copyWith(color: c.brand)),
            ),
          ],
        );
      },
    );
    if (!mounted) return;

    if (again == true) {
      // Reads the running board back over the console — no reset, no writing.
      await usb.checkBoard();
    } else if (again == false) {
      appState.selectedTab = AppState.devicesTab;
    }
  }

  Future<void> _check(AppState appState) => appState.usbFlasher.checkBoard();

  static String _kb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// A fixed-height serial console, in the spirit of the Arduino IDE's.
///
/// The log used to be rendered as a plain column of rows, so the card grew a
/// line at a time and pushed the buttons off the bottom of the screen while a
/// flash was running. A window of its own keeps the page still: the box is
/// always the same size, older lines scroll up inside it, and the newest line
/// is the one you are looking at. The service clears the log at the start of
/// every action, so what is in the box always belongs to the run in progress.
class _ConsoleLog extends StatefulWidget {
  final List<UsbFlashLogEntry> entries;

  const _ConsoleLog({required this.entries});

  @override
  State<_ConsoleLog> createState() => _ConsoleLogState();
}

class _ConsoleLogState extends State<_ConsoleLog> {
  final _controller = ScrollController();

  /// Tall enough for a dozen lines, short enough to leave the buttons on
  /// screen on a phone held in one hand.
  static const _height = 190.0;

  @override
  void didUpdateWidget(_ConsoleLog old) {
    super.didUpdateWidget(old);
    if (widget.entries.length != old.entries.length) _stickToBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Follow the newest line, the way a terminal does. Jumps rather than
  /// animates: lines can arrive faster than an animation can finish, and a
  /// half-finished scroll that keeps getting retargeted just judders.
  void _stickToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final style = AppTheme.font.mono.copyWith(fontSize: 12, height: 1.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Console',
                  style:
                      AppTheme.font.footnote.copyWith(color: c.textSecondary)),
            ),
            Text('${widget.entries.length} line'
                '${widget.entries.length == 1 ? '' : 's'}',
                style:
                    AppTheme.font.caption.copyWith(color: c.textSecondary)),
          ],
        ),
        SizedBox(height: AppTheme.spacing.xs),
        Container(
          height: _height,
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: AppTheme.spacing.md, vertical: AppTheme.spacing.sm),
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            borderRadius: BorderRadius.circular(AppTheme.radius.md),
            border: Border.all(color: c.border),
          ),
          child: Scrollbar(
            controller: _controller,
            child: ListView.builder(
              controller: _controller,
              padding: EdgeInsets.zero,
              itemCount: widget.entries.length,
              itemBuilder: (context, i) {
                final entry = widget.entries[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: SelectableText(
                    entry.message,
                    style: style.copyWith(
                        color: entry.isError ? c.danger : c.textSecondary),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
