import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/device_status.dart';
import '../../services/ble_manager.dart';
import '../../services/firmware_flasher.dart';

/// The setup flow from DEVICE_PROTOCOL.md §1 / FLUTTER_APP_HANDOFF.md §4:
/// connect → choose how the board reports → (Wi-Fi credentials) → done.
///
/// Entered with a board already picked from the scan, so step 1 of the handoff's
/// five steps is the device list itself.
enum _Step { connecting, chooseMode, wifiCredentials, provisioning, done }

class BoardSetupWizard extends StatefulWidget {
  final DiscoveredDevice device;

  const BoardSetupWizard({super.key, required this.device});

  @override
  State<BoardSetupWizard> createState() => _BoardSetupWizardState();
}

class _BoardSetupWizardState extends State<BoardSetupWizard> {
  _Step _step = _Step.connecting;
  String? _error;

  RunMode _chosenMode = RunMode.ble;
  final _ssid = TextEditingController();
  final _password = TextEditingController();

  /// Status events, newest last, shown as a live log during provisioning.
  final List<DeviceStatus> _events = [];
  StreamSubscription<DeviceStatus>? _statusSub;
  Timer? _timeout;

  /// Polls the status characteristic while the board is answering.
  ///
  /// Notifications are capped at MTU-3 bytes and vanish silently when the
  /// status object does not fit — which is exactly how this screen used to hang
  /// on "Saving Bluetooth mode…" while the board had in fact already done it.
  /// Reads have no such cap, so this is the belt to the notification's braces.
  Timer? _statusPoll;

  /// The handshake is over. Guards against the poll and the notification both
  /// delivering the same event.
  bool _settled = false;

  BLEManager get _ble => context.read<AppState>().ble;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _timeout?.cancel();
    _statusPoll?.cancel();
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  // MARK: Steps

  Future<void> _connect() async {
    final ble = _ble;
    await ble.connect(widget.device);
    if (!mounted) return;

    if (!ble.connection.isConnected) {
      setState(() => _error = ble.connection.message ??
          'Could not connect. The board may have gone back to sleep — '
              'try again when it next wakes.');
      return;
    }

    // Setup must not race the sleep window (handoff §4 step 2).
    try {
      await ble.stayAwake();
    } on BLEException {
      // v1 board: no session characteristic, and it never sleeps anyway.
    }
    if (!mounted) return;

    if (!ble.supportsProvisioning) {
      setState(() => _error =
          'This board runs firmware 1.x, which has no provisioning support. '
          'Update it from the Flash tab first.');
      return;
    }
    setState(() => _step = _Step.chooseMode);
  }

  void _chooseMode(RunMode mode) {
    setState(() {
      _chosenMode = mode;
      _step = mode == RunMode.wifi ? _Step.wifiCredentials : _Step.provisioning;
    });
    if (mode == RunMode.ble) _provision();
  }

  Future<void> _provision() async {
    setState(() {
      _step = _Step.provisioning;
      _error = null;
      _events.clear();
      _settled = false;
    });

    // The board answers on the status characteristic, not on the write — drive
    // the UI off the event stream (§2.5).
    _statusSub?.cancel();
    _statusSub = _ble.statusEvents.listen(_onStatusEvent);

    // Ask the board directly as well, rather than only waiting to be told.
    _statusPoll?.cancel();
    _statusPoll = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted || _settled) return;
      _ble.readStatus();
    });

    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 40), () {
      if (!mounted || _step != _Step.provisioning) return;
      _statusPoll?.cancel();
      setState(() => _error = _chosenMode == RunMode.wifi
          ? 'The board stopped responding. Check the Wi-Fi password and try '
              'again.'
          : 'The board stopped responding. It may have gone back to sleep — '
              'tap RESET on it and try again.');
    });

    try {
      await _ble.provision(
        mode: _chosenMode,
        ssid: _chosenMode == RunMode.wifi ? _ssid.text.trim() : null,
        password: _chosenMode == RunMode.wifi ? _password.text : null,
        // Cloud check-in needs a deployed backend; without one the board still
        // joins Wi-Fi and serves readings locally over mDNS.
        reportIntervalSec: _chosenMode == RunMode.wifi ? 900 : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeError(e));
    }
  }

  void _onStatusEvent(DeviceStatus status) {
    if (!mounted || status.event == null || _settled) return;
    // The poll re-reads the same value until something changes, so only the
    // first sighting of an event is news.
    if (_events.isNotEmpty && _events.last.eventPath == status.eventPath) return;
    setState(() => _events.add(status));

    switch (status.eventPath) {
      case 'prov/ble mode':
      case 'prov/done':
        _settled = true;
        _timeout?.cancel();
        _statusPoll?.cancel();
        _finish();
      case 'wifi/failed':
        _settled = true;
        _timeout?.cancel();
        _statusPoll?.cancel();
        // Keep the BLE link open so the user can retype the password; the board
        // stays in its previous mode, so nothing is lost (§4 step 4).
        setState(() {
          _error = 'The board could not join "${_ssid.text.trim()}". '
              'Check the password — and that this is a 2.4 GHz network.';
          _step = _Step.wifiCredentials;
        });
      case 'prov/bad json':
        _settled = true;
        _timeout?.cancel();
        _statusPoll?.cancel();
        setState(() => _error = 'The board rejected the setup payload.');
    }
  }

  /// Push the pin configuration, then hand the board back to its sleep cycle.
  Future<void> _finish() async {
    final appState = context.read<AppState>();
    // The scan list still holds the pre-provisioning advertisement.
    _ble.markProvisioned(widget.device.id, _chosenMode);
    try {
      await appState.applyPinConfiguration();
    } catch (_) {
      // A board that is set up but not yet configured is still a success; the
      // Pins screen can retry.
    }
    if (!mounted) return;
    setState(() => _step = _Step.done);
  }

  Future<void> _close({required bool sleep}) async {
    if (sleep) {
      try {
        await _ble.sleepNow();
      } on BLEException {
        // v1 board, or link already gone.
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  // MARK: Build

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: const Text('Add board'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => _close(sleep: _step != _Step.connecting),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(AppTheme.spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BoardHeader(device: widget.device, status: _ble.status),
            SizedBox(height: AppTheme.spacing.xl),
            if (_error != null) ...[
              Callout(
                  text: _error!, tint: c.danger, icon: Icons.warning_amber_rounded),
              SizedBox(height: AppTheme.spacing.lg),
            ],
            ..._stepBody(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _stepBody(BuildContext context) => switch (_step) {
        _Step.connecting => [
            if (_error == null)
              const _Waiting(label: 'Connecting to the board…')
            else
              PrimaryButton(
                onPressed: () {
                  setState(() => _error = null);
                  _connect();
                },
                child: const Text('Try again'),
              ),
          ],
        _Step.chooseMode => _modeStep(context),
        _Step.wifiCredentials => _wifiStep(context),
        _Step.provisioning => [
            if (_error == null)
              _Waiting(
                  label: _chosenMode == RunMode.wifi
                      ? 'Joining Wi-Fi…'
                      : 'Saving Bluetooth mode…'),
            if (_events.isNotEmpty) ...[
              SizedBox(height: AppTheme.spacing.lg),
              _EventLog(events: _events),
            ],
            if (_error != null) ...[
              SizedBox(height: AppTheme.spacing.lg),
              PrimaryButton(
                onPressed: () => setState(() {
                  _error = null;
                  _step = _chosenMode == RunMode.wifi
                      ? _Step.wifiCredentials
                      : _Step.chooseMode;
                }),
                child: const Text('Back'),
              ),
            ],
          ],
        _Step.done => _doneStep(context),
      };

  List<Widget> _modeStep(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return [
      const SectionHeader(
        title: 'How should it report?',
        subtitle: 'You can change this later from the Power screen.',
      ),
      SizedBox(height: AppTheme.spacing.md),
      _ModeCard(
        title: 'Bluetooth',
        body: 'Readings when your phone is nearby. Longest battery life.',
        icon: Icons.bluetooth,
        onTap: () => _chooseMode(RunMode.ble),
      ),
      SizedBox(height: AppTheme.spacing.md),
      _ModeCard(
        title: 'Wi-Fi',
        body: AppConfig.isBackendConfigured
            ? 'Readings even when you are away. Needs your Wi-Fi password.'
            : 'Readings from anywhere on your Wi-Fi. Needs your Wi-Fi password.',
        icon: Icons.wifi,
        onTap: () => _chooseMode(RunMode.wifi),
      ),
      if (!AppConfig.isBackendConfigured) ...[
        SizedBox(height: AppTheme.spacing.md),
        Callout(
          text: 'No cloud backend is configured, so a Wi-Fi board will report on '
              'your local network only — reachable from this app at home, not '
              'from away. Set AppConfig.firmwareApiBaseURL to enable check-in.',
          tint: c.brand,
        ),
      ],
    ];
  }

  List<Widget> _wifiStep(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return [
      const SectionHeader(
        title: 'Wi-Fi network',
        subtitle: 'The board joins this network on every wake.',
      ),
      SizedBox(height: AppTheme.spacing.md),
      AppCard(
        child: Column(
          children: [
            _Field(
              label: 'Network (SSID)',
              controller: _ssid,
              onChanged: (_) => setState(() {}),
            ),
            const Divider(),
            _Field(label: 'Password', controller: _password, obscure: true),
          ],
        ),
      ),
      SizedBox(height: AppTheme.spacing.md),
      Callout(
        // The single most common provisioning failure (handoff §4).
        text: 'ESP32 and ESP8266 boards only join 2.4 GHz networks. If your '
            'phone is on a 5 GHz band, the board will not find this network.',
        tint: c.warning,
        icon: Icons.warning_amber_rounded,
      ),
      SizedBox(height: AppTheme.spacing.lg),
      PrimaryButton(
        onPressed: _ssid.text.trim().isEmpty ? null : _provision,
        child: const Text('Join network'),
      ),
    ];
  }

  List<Widget> _doneStep(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final status = _ble.status;
    final interval = _chosenMode == RunMode.wifi ? 'every 15 min' : 'every 5 min';

    return [
      Callout(
        text: 'Board is set up in ${_chosenMode.displayName} mode.',
        tint: c.success,
        icon: Icons.check_circle,
      ),
      SizedBox(height: AppTheme.spacing.lg),
      const SectionHeader(
        title: 'What happens now',
        subtitle: 'The board sleeps between readings to save the pack.',
      ),
      SizedBox(height: AppTheme.spacing.md),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(label: 'Mode', value: _chosenMode.displayName),
            const Divider(),
            _Row(label: 'Wakes', value: interval),
            if (status?.ip != null) ...[
              const Divider(),
              _Row(label: 'Address', value: status!.ip!),
            ],
          ],
        ),
      ),
      SizedBox(height: AppTheme.spacing.xl),
      PrimaryButton(
        onPressed: () => _close(sleep: true),
        child: const Text('Done'),
      ),
    ];
  }
}

// MARK: - Pieces

class _BoardHeader extends StatelessWidget {
  final DiscoveredDevice device;
  final DeviceStatus? status;

  const _BoardHeader({required this.device, this.status});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    final volts = status?.volts ?? device.volts;
    final soc = status?.soc ?? device.soc;

    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name,
                    style:
                        AppTheme.font.headline.copyWith(color: c.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  [
                    status?.id ?? device.id,
                    if (status?.fw != null) 'fw ${status!.fw}',
                  ].join(' · '),
                  style: AppTheme.font.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          if (volts != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${volts.toStringAsFixed(2)} V',
                    style: AppTheme.font.mono.copyWith(
                        color: c.battery((soc ?? 0) / 100))),
                if (soc != null)
                  Text('$soc%',
                      style: AppTheme.font.caption
                          .copyWith(color: c.textSecondary)),
              ],
            ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  final VoidCallback onTap;

  const _ModeCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AppCard(
        child: Row(
          children: [
            Icon(icon, color: c.brand, size: 28),
            SizedBox(width: AppTheme.spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTheme.font.headline
                          .copyWith(color: c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: AppTheme.font.footnote
                          .copyWith(color: c.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _EventLog extends StatelessWidget {
  final List<DeviceStatus> events;

  const _EventLog({required this.events});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in events)
            Padding(
              padding: EdgeInsets.symmetric(vertical: AppTheme.spacing.xxs),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 6, color: c.accent),
                  SizedBox(width: AppTheme.spacing.sm),
                  Expanded(
                    child: Text(_label(e),
                        style: AppTheme.font.footnote
                            .copyWith(color: c.textPrimary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _label(DeviceStatus e) => switch (e.eventPath) {
        'wifi/connecting' => 'Joining Wi-Fi…',
        'wifi/connected' => 'Wi-Fi connected',
        'wifi/failed' => 'Wi-Fi join failed',
        'cloud/registered' => 'Registered with the cloud',
        'cloud/unreachable' => 'Cloud unreachable — reporting locally',
        'prov/done' => 'Setup complete',
        'prov/ble mode' => 'Bluetooth mode saved',
        _ => e.eventPath,
      };
}

class _Waiting extends StatelessWidget {
  final String label;

  const _Waiting({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: c.brand),
        ),
        SizedBox(width: AppTheme.spacing.md),
        Text(label, style: AppTheme.font.body.copyWith(color: c.textPrimary)),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    this.obscure = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Row(
      children: [
        SizedBox(
          width: 132,
          child: Text(label,
              style: AppTheme.font.body.copyWith(color: c.textPrimary)),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            textAlign: TextAlign.right,
            style: AppTheme.font.mono.copyWith(color: c.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
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
}
