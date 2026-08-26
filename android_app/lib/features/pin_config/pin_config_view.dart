// `Chip` here is the board's chip family, not the Material widget.
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../design_system/components.dart';
import '../../design_system/theme.dart';
import '../../models/board.dart';
import '../../models/device_status.dart';
import '../../models/pin_configuration.dart';
import '../../services/firmware_flasher.dart';

enum _BuildStatus { idle, building, success, failure }

/// Let the user pick the ADC pin intuitively and dial in the divider math.
class PinConfigView extends StatefulWidget {
  const PinConfigView({super.key});

  @override
  State<PinConfigView> createState() => _PinConfigViewState();
}

class _PinConfigViewState extends State<PinConfigView> {
  _BuildStatus _generateStatus = _BuildStatus.idle;
  String? _generateError;

  /// Wi-Fi credentials for a board being built in Wi-Fi mode. Held here rather
  /// than in [AppState] because they are text being typed; the trimmed result
  /// is what lands in the setup.
  final _ssid = TextEditingController();
  final _password = TextEditingController();

  /// Whether the millisecond-level window settings are on screen. Folded away
  /// by default: three people in a hundred want them, and the interval above
  /// is the setting that actually decides how long the pack lasts.
  bool _showPowerAdvanced = false;

  /// Which of [_buildStages] is on screen while the image is assembled.
  int _buildStage = 0;

  /// The narration shown while an image set is built, and how long each line
  /// is held.
  ///
  /// Assembling the set is fast — the firmware is already on the phone and the
  /// calibration is a few hundred bytes — but a button that goes from tap to
  /// "done" inside one frame reads as though it did nothing at all. These are
  /// the steps that really happen, paced so the work is legible, and the whole
  /// sequence is over well before a wait turns into wondering whether it hung.
  static const _buildStages = <(String, Duration)>[
    ('Reading the calibration…', Duration(milliseconds: 900)),
    ('Loading the firmware bundle…', Duration(milliseconds: 1500)),
    ('Merging the calibration image…', Duration(milliseconds: 1700)),
    ('Laying out the flash map…', Duration(milliseconds: 1400)),
    ('Verifying the image set…', Duration(milliseconds: 1100)),
  ];

  @override
  void initState() {
    super.initState();
    final setup = context.read<AppState>().boardSetup;
    _ssid.text = setup.ssid;
    _password.text = setup.password;
  }

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final c = AppTheme.colorOf(context);
    final board = appState.selectedBoard;
    final config = appState.pinConfiguration;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(title: const Text('Configuration')),
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
          _nameSection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _pinPicker(context, appState, board, config),
          SizedBox(height: AppTheme.spacing.xl),
          _dividerSection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _batterySection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _wiringSection(context, appState, config),
          SizedBox(height: AppTheme.spacing.xl),
          _rangeSummary(context, config),
          SizedBox(height: AppTheme.spacing.xl),
          _reportingSection(context, appState, board),
          SizedBox(height: AppTheme.spacing.xl),
          _generateSection(context, appState),
        ],
      ),
    );
  }

  // MARK: Name

  /// What this board will be called.
  ///
  /// Left empty, the board names itself from the last four hex digits of its
  /// MAC — which is unique, needs no input, and is the right answer for a board
  /// that is one of many. A name typed here replaces it, and is what the board
  /// advertises, so it is what the Devices list shows.
  Widget _nameSection(
    BuildContext context,
    AppState appState,
    PinConfiguration config,
  ) {
    final c = AppTheme.colorOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Board name',
          subtitle: 'What this board calls itself when the app finds it.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: _NameRow(
            value: config.deviceName,
            onChanged: (name) => appState.pinConfiguration =
                config.copyWith(deviceName: (value: name)),
          ),
        ),
        SizedBox(height: AppTheme.spacing.xs),
        Text(
          'Leave it empty and the board names itself BH-xxxx after the last '
          'four digits of its MAC address.',
          style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
        ),
      ],
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
          // The board's run mode is what decides this, not the transport the
          // app happens to be talking over: ADC2 is dead while the board's own
          // Wi-Fi radio is up.
          if (!selectedPin.wifiSafeADC &&
              appState.boardSetup.mode == RunMode.wifi)
            Callout(
              text: '${selectedPin.name} uses ADC2, which is unavailable while '
                  'Wi-Fi is active. Pick an ADC1 pin, or set this board to '
                  'Bluetooth mode below.',
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
              NumberRow(
                label: 'R1 (kΩ)',
                value: config.dividerR1KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR1KOhm: v),
              ),
              const Divider(),
              NumberRow(
                label: 'R2 (kΩ)',
                value: config.dividerR2KOhm,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(dividerR2KOhm: v),
              ),
              const Divider(),
              NumberRow(
                label: 'Calibration',
                value: config.calibrationFactor,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(calibrationFactor: v),
              ),
              const Divider(),
              NumberRow(
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
          subtitle: 'Used for the percentage estimate, and for where a new '
              'board starts warning that it is low.',
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
        SizedBox(height: AppTheme.spacing.xs),
        Text(
          'A board first seen with this pack starts warning below '
          '${config.defaultLowBatteryVolts.toStringAsFixed(2)} V. Each board '
          'keeps its own switch and its own threshold, on its page under '
          'Monitor.',
          style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
        ),
      ],
    );
  }

  // MARK: Board wiring

  /// The status LED and pairing button.
  ///
  /// These used to be compiled into the firmware, which meant a board wired
  /// differently from the reference dev board simply behaved wrongly — IDENTIFY
  /// blinking nothing, or a pin that was never a button. They are settings now,
  /// they ride along in the calibration, and the board takes them on its next
  /// boot.
  Widget _wiringSection(
    BuildContext context,
    AppState appState,
    PinConfiguration config,
  ) {
    final c = AppTheme.colorOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Board wiring',
          subtitle: 'Where the status LED and pairing button actually are.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        AppCard(
          child: Column(
            children: [
              _PinRow(
                label: 'Status LED pin',
                value: config.statusLedPin,
                onChanged: (v) => appState.pinConfiguration = config.copyWith(
                  statusLedPin: (value: v),
                  // A pin without a polarity is only half an answer, so commit
                  // to one as soon as the pin becomes explicit.
                  statusLedActiveLow: v == null || v < 0
                      ? const (value: null)
                      : (value: config.statusLedActiveLow ?? false),
                ),
              ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text('LED sinks current (active low)',
                        style: AppTheme.font.body
                            .copyWith(color: c.textPrimary)),
                  ),
                  Switch(
                    value: config.statusLedActiveLow ?? false,
                    activeThumbColor: c.brand,
                    onChanged: (config.statusLedPin ?? -1) < 0
                        ? null
                        : (v) => appState.pinConfiguration =
                            config.copyWith(statusLedActiveLow: (value: v)),
                  ),
                ],
              ),
              const Divider(),
              _PinRow(
                label: 'Pairing button pin',
                value: config.wakeButtonPin,
                onChanged: (v) => appState.pinConfiguration =
                    config.copyWith(wakeButtonPin: (value: v)),
              ),
            ],
          ),
        ),
        SizedBox(height: AppTheme.spacing.xs),
        Text(
          'Leave a field empty to keep whatever the firmware was built with, '
          'or enter -1 for "this board has none". The pairing button has to be '
          'an RTC-capable GPIO to wake the board from deep sleep — the board '
          'refuses one that cannot.',
          style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
        ),
        if (appState.selectedBoard?.chip == Chip.esp32c3) ...[
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: 'The C3 DevKitM drives an addressable LED through a pin '
                'number the core reserves, so leaving the LED field empty is '
                'usually right on this board.',
            tint: c.brand,
            icon: Icons.info,
          ),
        ],
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

  // MARK: Reporting & timers

  /// What the board does once it boots: how it reports, and how often.
  ///
  /// This is the half of setup that used to be asked over Bluetooth *after*
  /// the flash, which left a freshly flashed board sitting unclaimed in pairing
  /// mode until someone caught it awake and answered the same question again.
  /// Answered here it travels in the calibration region, so the board wakes up
  /// on its very first boot already in the mode it was built for
  /// (DEVICE_PROTOCOL.md §6).
  Widget _reportingSection(
    BuildContext context,
    AppState appState,
    Board board,
  ) {
    final c = AppTheme.colorOf(context);
    final setup = appState.boardSetup.forBoard(board);
    final modes = _modesFor(board);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'How it reports',
          subtitle: 'Baked into the image, so the board is set up the moment '
              'it boots.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        if (modes.length > 1)
          SegmentedPicker<RunMode>(
            options: modes,
            selection: modes.contains(setup.mode) ? setup.mode : modes.first,
            labelOf: _modeLabel,
            onChanged: (mode) =>
                appState.boardSetup = setup.copyWith(mode: mode),
          ),
        SizedBox(height: AppTheme.spacing.sm),
        Callout(text: _modeHint(setup.mode), tint: c.brand, icon: Icons.info),

        if (setup.mode == RunMode.wifi) ...[
          SizedBox(height: AppTheme.spacing.md),
          AppCard(
            child: Column(
              children: [
                _TextRow(
                  label: 'Network (SSID)',
                  controller: _ssid,
                  hint: 'Your 2.4 GHz network',
                  onChanged: (value) =>
                      appState.boardSetup = setup.copyWith(ssid: value),
                ),
                const Divider(),
                _TextRow(
                  label: 'Password',
                  controller: _password,
                  hint: 'Wi-Fi password',
                  obscure: true,
                  onChanged: (value) =>
                      appState.boardSetup = setup.copyWith(password: value),
                ),
              ],
            ),
          ),
          SizedBox(height: AppTheme.spacing.xs),
          Callout(
            // The single most common provisioning failure, and after the fact
            // it costs a reflash to discover.
            text: 'ESP32 and ESP8266 boards only join 2.4 GHz networks. The '
                'password is written into the board’s flash along with the '
                'firmware.',
            tint: c.warning,
            icon: Icons.warning_amber_rounded,
          ),
        ],

        SizedBox(height: AppTheme.spacing.xl),
        SectionHeader(
          title: 'Wake timer',
          subtitle: setup.mode == RunMode.wifi
              ? 'How often the board wakes, joins Wi-Fi and reports.'
              : 'How often the board wakes, samples the pack and advertises.',
        ),
        SizedBox(height: AppTheme.spacing.sm),
        Wrap(
          spacing: AppTheme.spacing.sm,
          runSpacing: AppTheme.spacing.sm,
          children: [
            for (final seconds in PowerConfig.intervalOptions)
              _IntervalChip(
                label: PowerConfig.intervalLabel(seconds),
                isSelected: setup.intervalSec == seconds,
                onTap: () => appState.boardSetup = setup.withInterval(seconds),
              ),
          ],
        ),
        SizedBox(height: AppTheme.spacing.sm),
        Callout(
            text: PowerConfig.batteryHint(setup.intervalSec), tint: c.brand),

        SizedBox(height: AppTheme.spacing.md),
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: Text('Sleep between readings',
                    style: AppTheme.font.body.copyWith(color: c.textPrimary)),
              ),
              Switch(
                value: setup.power.sleepEnabled,
                activeThumbColor: c.brand,
                onChanged: (value) => appState.boardSetup = setup.copyWith(
                    power: setup.power.copyWith(sleepEnabled: value)),
              ),
            ],
          ),
        ),
        if (!setup.power.sleepEnabled) ...[
          SizedBox(height: AppTheme.spacing.xs),
          Callout(
            text: 'A board that never sleeps is reachable all the time and '
                'flattens the pack in hours rather than weeks. Right for a '
                'board on a bench supply, wrong for one on a battery.',
            tint: c.warning,
            icon: Icons.warning_amber_rounded,
          ),
        ],

        SizedBox(height: AppTheme.spacing.md),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showPowerAdvanced = !_showPowerAdvanced),
          child: Row(
            children: [
              Expanded(
                child: SectionHeader(
                  title: 'Advanced timers',
                  subtitle: _showPowerAdvanced
                      ? 'Windows and timeouts, in milliseconds.'
                      : 'Wake windows, idle timeout, BLE during Wi-Fi.',
                ),
              ),
              Icon(_showPowerAdvanced ? Icons.expand_less : Icons.expand_more,
                  color: c.textSecondary),
            ],
          ),
        ),
        if (_showPowerAdvanced) ...[
          SizedBox(height: AppTheme.spacing.sm),
          AppCard(
            child: Column(
              children: [
                NumberRow(
                  label: 'BLE window (ms)',
                  value: setup.power.bleWindowMs.toDouble(),
                  isInteger: true,
                  onChanged: (v) => appState.boardSetup = setup.copyWith(
                      power: setup.power.copyWith(bleWindowMs: v.round())),
                ),
                const Divider(),
                NumberRow(
                  label: 'BLE idle timeout (ms)',
                  value: setup.power.bleIdleMs.toDouble(),
                  isInteger: true,
                  onChanged: (v) => appState.boardSetup = setup.copyWith(
                      power: setup.power.copyWith(bleIdleMs: v.round())),
                ),
                const Divider(),
                NumberRow(
                  label: 'Wi-Fi window (ms)',
                  value: setup.power.wifiWindowMs.toDouble(),
                  isInteger: true,
                  onChanged: (v) => appState.boardSetup = setup.copyWith(
                      power: setup.power.copyWith(wifiWindowMs: v.round())),
                ),
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: Text('Bluetooth while in Wi-Fi mode',
                          style: AppTheme.font.body
                              .copyWith(color: c.textPrimary)),
                    ),
                    Switch(
                      value: setup.power.bleInWifi,
                      activeThumbColor: c.brand,
                      onChanged: (v) => appState.boardSetup = setup.copyWith(
                          power: setup.power.copyWith(bleInWifi: v)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The modes this board's radios can actually deliver. An ESP8266 has no BLE
  /// at all, so offering "Bluetooth" on one would be offering a mode it could
  /// never enter.
  static List<RunMode> _modesFor(Board board) => [
        if (board.supportedTransports.contains(FlashTransport.ble)) RunMode.ble,
        if (board.supportedTransports.contains(FlashTransport.wifi))
          RunMode.wifi,
        RunMode.pairing,
      ];

  static String _modeLabel(RunMode mode) => switch (mode) {
        RunMode.ble => 'Bluetooth',
        RunMode.wifi => 'Wi-Fi',
        RunMode.pairing => 'Decide later',
      };

  static String _modeHint(RunMode mode) => switch (mode) {
        RunMode.ble => 'Readings when your phone is nearby. Longest battery '
            'life, and nothing else to configure.',
        RunMode.wifi =>
          'The board joins this network on every wake and reports over it. '
              'Needs the password below.',
        RunMode.pairing =>
          'The board comes up unclaimed and waits, advertising every minute, '
              'until you set it up from the Devices tab. Pick this only if you '
              'do not know yet how this board should report.',
      };

  // MARK: Generate

  /// Builds the flashable image set for this board: the firmware `.bin` files
  /// bundled with the app plus a calibration image generated from the settings
  /// above. Nothing is compiled on the phone — this assembles what ships.
  Widget _generateSection(BuildContext context, AppState appState) {
    final c = AppTheme.colorOf(context);
    final busy = _generateStatus == _BuildStatus.building;
    final plan = appState.flashPlan;
    final board = appState.selectedBoard;
    final setup = board == null
        ? appState.boardSetup
        : appState.boardSetup.forBoard(board);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Firmware image',
          subtitle: 'Bundle the firmware, this calibration and the settings '
              'above into a .bin set you can flash over USB.',
        ),
        SizedBox(height: AppTheme.spacing.md),
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Erase saved settings first',
                  style: AppTheme.font.body.copyWith(color: c.textPrimary),
                ),
              ),
              Switch(
                value: appState.eraseSavedSettings,
                activeThumbColor: c.brand,
                onChanged: busy
                    ? null
                    : (value) => appState.eraseSavedSettings = value,
              ),
            ],
          ),
        ),
        SizedBox(height: AppTheme.spacing.xs),
        Text(
          "Clears the board's stored run mode and wake interval so it takes "
          'the settings above instead of whatever was on it before.',
          style: AppTheme.font.footnote.copyWith(color: c.textSecondary),
        ),
        SizedBox(height: AppTheme.spacing.md),
        if (!setup.isComplete) ...[
          Callout(
            text: 'Name the Wi-Fi network this board should join, or set it '
                'back to Bluetooth. A board flashed with no network would come '
                'up, fail to join, and sit there advertising.',
            tint: c.warning,
            icon: Icons.warning_amber_rounded,
          ),
          SizedBox(height: AppTheme.spacing.md),
        ],
        PrimaryButton(
          onPressed: busy || !setup.isComplete ? null : () => _generate(appState),
          child: busy
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.textOnBrand),
                )
              : const Text('Generate BIN file'),
        ),
        if (busy) ...[
          SizedBox(height: AppTheme.spacing.sm),
          _BuildProgress(
            label: _buildStages[_buildStage].$1,
            step: _buildStage + 1,
            of: _buildStages.length,
          ),
        ] else if (_generateStatus == _BuildStatus.failure) ...[
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: _generateError ?? 'Could not generate the image.',
            tint: c.danger,
            icon: Icons.cancel,
          ),
        ] else if (_generateStatus == _BuildStatus.success && plan != null) ...[
          SizedBox(height: AppTheme.spacing.sm),
          Callout(
            text: 'Built ${plan.segments.length} images for '
                '${plan.bundle.name}, set to ${_modeLabel(plan.bootMode)} '
                'mode — opening the Flash screen.',
            tint: c.success,
            icon: Icons.check_circle,
          ),
        ],
      ],
    );
  }

  Future<void> _generate(AppState appState) async {
    setState(() {
      _generateStatus = _BuildStatus.building;
      _generateError = null;
      _buildStage = 0;
    });

    // Started before the narration so the two overlap: the stages are a floor
    // on how long the button stays busy, never a cap on the real work. The
    // outcome is held rather than thrown, because nothing awaits this future
    // until the stages finish and a failure in between would surface as an
    // unhandled async error.
    final build = _build(appState);
    await _runBuildStages();
    final failure = await build;

    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _generateStatus = _BuildStatus.failure;
        _generateError = describeError(failure);
      });
      return;
    }

    setState(() => _generateStatus = _BuildStatus.success);

    // The image is ready, so the next thing the user wants is the Flash
    // screen. Pop back to the tab root first so returning to Setup does not
    // land them back on this form.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    appState.selectedTab = AppState.flashTab;
  }

  Future<Object?> _build(AppState appState) async {
    try {
      await appState.generateFlashImage();
      return null;
    } catch (e) {
      return e;
    }
  }

  Future<void> _runBuildStages() async {
    for (var i = 0; i < _buildStages.length; i++) {
      if (!mounted) return;
      setState(() => _buildStage = i);
      await Future<void>.delayed(_buildStages[i].$2);
    }
  }
}

// MARK: - Build progress

/// What the app is doing to the image right now, and how far along it is.
class _BuildProgress extends StatelessWidget {
  final String label;
  final int step;
  final int of;

  const _BuildProgress({
    required this.label,
    required this.step,
    required this.of,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style:
                      AppTheme.font.footnote.copyWith(color: c.textPrimary)),
            ),
            Text('$step/$of',
                style: AppTheme.font.caption.copyWith(color: c.textSecondary)),
          ],
        ),
        SizedBox(height: AppTheme.spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radius.pill),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: step / of),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(c.brand),
            ),
          ),
        ),
      ],
    );
  }
}

// MARK: - Rows

/// One wake interval, offered as a tappable pill.
///
/// A picker rather than a free number: the twelve options span half a minute
/// to a day, which is the entire useful range, and every one of them is a
/// value the board's own settings screen can show back later.
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

/// Label on the left, right-aligned free text on the right.
class _TextRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final ValueChanged<String> onChanged;

  const _TextRow({
    required this.label,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.obscure = false,
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
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: AppTheme.font.mono.copyWith(color: c.textSecondary),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// Label on the left, right-aligned monospaced numeric field on the right.
/// The board's name, or nothing at all — which is a real choice, not a blank.
class _NameRow extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const _NameRow({required this.value, required this.onChanged});

  @override
  State<_NameRow> createState() => _NameRowState();
}

class _NameRowState extends State<_NameRow> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value ?? '');

  @override
  void didUpdateWidget(_NameRow old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && _controller.text != (widget.value ?? '')) {
      _controller.text = widget.value ?? '';
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
        SizedBox(
          width: 96,
          child:
              Text('Name', style: AppTheme.font.body.copyWith(color: c.textPrimary)),
        ),
        Expanded(
          child: TextField(
            controller: _controller,
            textAlign: TextAlign.right,
            autocorrect: false,
            enableSuggestions: false,
            // The board advertises this, and a scan response has 31 bytes for
            // the whole packet.
            maxLength: 24,
            style: AppTheme.font.body.copyWith(color: c.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              counterText: '',
              hintText: 'Auto — BH-xxxx',
              hintStyle: AppTheme.font.body.copyWith(color: c.textSecondary),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (text) {
              final trimmed = text.trim();
              widget.onChanged(trimmed.isEmpty ? null : trimmed);
            },
          ),
        ),
      ],
    );
  }
}

/// A GPIO number that can also be empty ("leave the board's default") or -1
/// ("this board has none").
class _PinRow extends StatefulWidget {
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  const _PinRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_PinRow> createState() => _PinRowState();
}

class _PinRowState extends State<_PinRow> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value?.toString() ?? '');

  @override
  void didUpdateWidget(_PinRow old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value &&
        int.tryParse(_controller.text) != widget.value) {
      _controller.text = widget.value?.toString() ?? '';
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
    final value = widget.value;

    return Row(
      children: [
        Expanded(
          child: Text(widget.label,
              style: AppTheme.font.body.copyWith(color: c.textPrimary)),
        ),
        if (value != null && value < 0)
          Padding(
            padding: EdgeInsets.only(right: AppTheme.spacing.sm),
            child: Text('none',
                style: AppTheme.font.caption.copyWith(color: c.textSecondary)),
          ),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _controller,
            textAlign: TextAlign.right,
            style: AppTheme.font.mono.copyWith(color: c.textPrimary),
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
            ],
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'default',
              hintStyle:
                  AppTheme.font.mono.copyWith(color: c.textSecondary),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (text) {
              final trimmed = text.trim();
              if (trimmed.isEmpty) {
                widget.onChanged(null);
                return;
              }
              // "-" on its own is a half-typed -1, not a value yet.
              final parsed = int.tryParse(trimmed);
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
