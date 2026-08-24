import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/battery_reading.dart';
import '../models/board.dart';
import '../models/board_setup.dart';
import '../models/calibration_image.dart';
import '../models/firmware_bundle.dart';
import '../models/firmware_image.dart';
import '../models/pin.dart';
import '../models/pin_configuration.dart';
import '../services/beacon_log_store.dart';
import '../services/beacon_scan_service_client.dart';
import '../services/ble_manager.dart';
import '../services/firmware_bundle_repository.dart';
import '../services/firmware_flasher.dart';
import '../services/firmware_repository.dart';
import '../services/low_battery_alerts.dart';
import '../services/usb_flash_service.dart';
import '../services/wifi_ota_service.dart';

/// Backend + integration configuration. Fill these in after deploying
/// `backend/template.yaml` (see docs/AWS_BACKEND.md).
class AppConfig {
  static final firmwareApiBaseURL = Uri.parse(
      'https://REPLACE_ME.execute-api.ap-southeast-1.amazonaws.com/prod/');
  static const cognitoUserPoolId = 'REPLACE_ME';
  static const cognitoClientId = 'REPLACE_ME';

  /// False while the placeholders above are untouched. Gates the cloud half of
  /// setup: a board can still be provisioned onto Wi-Fi without a backend, it
  /// just reports locally instead of checking in (DEVICE_PROTOCOL.md §2.2).
  static bool get isBackendConfigured =>
      !firmwareApiBaseURL.host.toLowerCase().contains('replace_me');
}

/// Composition root and single source of truth for the UI.
///
/// Owns the services, the board catalog, the working [PinConfiguration], and
/// the live reading buffer. Widgets observe it via `context.watch<AppState>()`,
/// the Provider equivalent of SwiftUI's `@EnvironmentObject`.
class AppState extends ChangeNotifier {
  // MARK: Catalog & configuration
  List<Board> _boards = [];
  Board? _selectedBoard;
  PinConfiguration? _pinConfiguration;

  List<Board> get boards => List.unmodifiable(_boards);
  Board? get selectedBoard => _selectedBoard;
  PinConfiguration? get pinConfiguration => _pinConfiguration;

  set pinConfiguration(PinConfiguration? value) {
    _pinConfiguration = value;
    // Chemistry and cell count decide where a newly seen board starts warning,
    // so any edit here moves that default — never a board that has been given
    // a threshold of its own.
    if (value != null) alerts.setDefaultThreshold(value.defaultLowBatteryVolts);
    notifyListeners();
  }

  // MARK: Tab selection
  //
  // The shell keeps one navigator per tab, so a screen pushed inside Setup
  // cannot reach the Flash tab through its own Navigator. Routing the index
  // through the shared state is what lets "Generate BIN file" hand the user
  // straight to the flash screen.
  static const int setupTab = 0;
  static const int devicesTab = 1;
  static const int monitorTab = 2;
  static const int flashTab = 3;

  int _selectedTab = setupTab;
  int get selectedTab => _selectedTab;

  set selectedTab(int value) {
    if (_selectedTab == value) return;
    _selectedTab = value;
    notifyListeners();
  }

  // MARK: Transport selection
  FlashTransport _activeTransport = FlashTransport.ble;
  FlashTransport get activeTransport => _activeTransport;

  set activeTransport(FlashTransport value) {
    _activeTransport = value;
    notifyListeners();
  }

  // MARK: Live monitoring
  final List<BatteryReading> _readings = [];
  bool _isMonitoring = false;

  List<BatteryReading> get readings => List.unmodifiable(_readings);
  bool get isMonitoring => _isMonitoring;
  BatteryReading? get latestReading => _readings.isEmpty ? null : _readings.last;

  // MARK: Startup / splash
  /// True while the app is warming up; drives the splash screen.
  bool _isBootstrapping = true;
  bool get isBootstrapping => _isBootstrapping;

  /// Human-readable status shown on the splash.
  String _bootstrapStatus = 'Starting up…';
  String get bootstrapStatus => _bootstrapStatus;

  // MARK: Services
  final BLEManager ble;
  final WiFiOTAService wifi;
  late final FirmwareFlasher flasher;
  final FirmwareRepository firmwareRepo;

  /// Persisted advertisement history, written by the background scan service.
  final BeaconLogStore beaconLog = BeaconLogStore();

  /// Controls that background service.
  final BeaconScanServiceClient beaconScan = BeaconScanServiceClient();

  /// The prebuilt firmware images shipped in `assets/firmware/`.
  final FirmwareBundleRepository firmwareBundles;

  /// Flashes a bare board over the USB cable.
  final UsbFlashService usbFlasher = UsbFlashService();

  /// Per-board low-battery warnings, fed by live readings here and by
  /// background sightings inside the native scan service.
  final LowBatteryAlerts alerts;

  final List<StreamSubscription<DeviceSample>> _sampleSubs = [];
  static const _maxReadings = 120;

  AppState({
    BLEManager? ble,
    WiFiOTAService? wifi,
    FirmwareRepository? firmwareRepo,
    FirmwareBundleRepository? firmwareBundles,
    LowBatteryAlerts? alerts,
  })  : ble = ble ?? BLEManager(),
        wifi = wifi ?? WiFiOTAService(),
        firmwareBundles = firmwareBundles ?? FirmwareBundleRepository(),
        alerts = alerts ?? LowBatteryAlerts(),
        firmwareRepo = firmwareRepo ??
            FirmwareRepository(baseURL: AppConfig.firmwareApiBaseURL) {
    flasher = FirmwareFlasher(ble: this.ble, wifi: this.wifi);
    _wireSampleStreams();
  }

  // MARK: Startup

  /// Warm up the app and fetch initial data. Drives the splash screen.
  ///
  /// The visible duration is not fixed — it ends when the work finishes. A
  /// soft timeout keeps a slow or unreachable backend from holding the splash
  /// indefinitely, and a small minimum keeps it from flickering past too fast.
  Future<void> bootstrap() async {
    final start = DateTime.now();

    _setBootstrapStatus('Loading boards…');
    _boards = await _loadBoards();
    notifyListeners();

    // Bring back whatever the background service logged while we were closed,
    // then make sure it is running again.
    await alerts.load();
    await beaconLog.reload();
    await beaconScan.refresh();
    if (beaconScan.isEnabled) await beaconScan.start();

    _setBootstrapStatus('Fetching data…');
    await _prefetchCatalog();

    const minVisible = Duration(milliseconds: 900);
    final elapsed = DateTime.now().difference(start);
    if (elapsed < minVisible) {
      await Future<void>.delayed(minVisible - elapsed);
    }

    _setBootstrapStatus('Ready');
    _isBootstrapping = false;
    notifyListeners();
  }

  /// Prefetch the firmware catalog to warm the network path. Returns as soon
  /// as the request finishes or a soft timeout elapses, whichever comes first.
  Future<void> _prefetchCatalog() async {
    final board = _selectedBoard ?? (_boards.isEmpty ? null : _boards.first);
    if (board == null) return;
    try {
      await firmwareRepo
          .listFirmware(board.id)
          .timeout(const Duration(seconds: 6)); // 6s ceiling
    } catch (_) {
      // A cold or unconfigured backend must not block launch.
    }
  }

  void _setBootstrapStatus(String status) {
    _bootstrapStatus = status;
    notifyListeners();
  }

  // MARK: Board & pin selection

  void selectBoard(Board board) {
    _selectedBoard = board;

    // Seed a sensible default pin configuration for the board.
    final pin = board.recommendedBatteryPin ??
        (board.adcCapablePins.isEmpty ? null : board.adcCapablePins.first);
    if (pin != null) {
      _pinConfiguration = PinConfiguration.makeDefault(board: board, pin: pin);
    }

    // Keep the flash transport valid for the board.
    if (board.supportedTransports.isNotEmpty &&
        !board.supportedTransports.contains(_activeTransport)) {
      _activeTransport = board.supportedTransports.first;
    }
    // An ESP8266 has no BLE radio, so "Bluetooth mode" is not a preference to
    // keep holding on one — it is a mode the board could never enter.
    _boardSetup = _boardSetup.forBoard(board);
    // The pack chosen for this board is where a newly seen board starts.
    final cfg = _pinConfiguration;
    if (cfg != null) alerts.setDefaultThreshold(cfg.defaultLowBatteryVolts);
    notifyListeners();
  }

  void setBatteryPin(Pin pin) {
    final cfg = _pinConfiguration;
    if (cfg == null) return;
    _pinConfiguration = cfg.copyWith(batteryPinId: pin.id);
    notifyListeners();
  }

  /// Delete everything the app holds about one board.
  ///
  /// A board only exists here because its log does — the Monitor list is rolled
  /// up from those rows — so dropping the log drops the board, and its alert
  /// setting has to go with it. Otherwise a board that came back later would
  /// silently inherit a threshold from a life nobody remembers.
  Future<void> forgetDevice(String deviceId) async {
    alerts.forgetDevice(deviceId);
    await beaconLog.clearDevice(deviceId);
  }

  /// Push the current configuration to the connected board over the active
  /// transport.
  ///
  /// The BLE path holds the board awake for the round trip — a write issued as
  /// the wake window closes would otherwise be lost (DEVICE_PROTOCOL.md §2.4).
  Future<void> applyPinConfiguration() async {
    final cfg = _pinConfiguration;
    if (cfg == null) return;
    switch (_activeTransport) {
      case FlashTransport.ble:
        await ble.withAwakeBoard(() => ble.writePinConfiguration(cfg));
      case FlashTransport.wifi:
        await wifi.writePinConfiguration(cfg);
    }
  }

  // MARK: Connection

  Future<void> startDiscovery() async {
    switch (_activeTransport) {
      case FlashTransport.ble:
        await ble.startScan();
      case FlashTransport.wifi:
        await wifi.startBrowsing();
    }
  }

  Future<void> stopDiscovery() async {
    await ble.stopScan();
    await wifi.stopBrowsing();
  }

  // MARK: Monitoring

  void startMonitoring() {
    _isMonitoring = true;
    _readings.clear();
    switch (_activeTransport) {
      case FlashTransport.ble:
        // Subscribing already holds the wake open (the firmware watches the
        // CCCD), and STAY_AWAKE makes that explicit so a board that drops
        // notifications still stays up for the chart.
        ble.stayAwake().catchError((_) {}); // v1 boards have no session char
        ble.setNotifying(true);
      case FlashTransport.wifi:
        wifi.startPolling(
            intervalMs: _pinConfiguration?.sampleIntervalMs ?? 1000);
    }
    notifyListeners();
  }

  void stopMonitoring() {
    _isMonitoring = false;
    // A run of low readings only means something while the readings keep
    // coming; the next session starts its count from scratch.
    alerts.reset();
    ble.setNotifying(false);
    // Hand the board back to its sleep cycle; leaving it awake would burn the
    // pack until the idle timeout fires.
    ble.sleepNow().catchError((_) {});
    wifi.stopPolling();
    notifyListeners();
  }

  // MARK: USB image generation

  /// The image set the Flash screen is holding, if one has been generated.
  FlashPlan? _flashPlan;
  FlashPlan? get flashPlan => _flashPlan;

  /// Where the generated calibration image was written on the phone.
  String? _generatedImagePath;
  String? get generatedImagePath => _generatedImagePath;

  /// Whether flashing also blanks the board's saved settings.
  ///
  /// On by default, and the reason a reflashed board behaves like a new one:
  /// NVS otherwise keeps the run mode and wake interval from its previous life,
  /// so a board that had been left on a one-minute test cycle would stay on it
  /// instead of taking the firmware's five-minute default.
  bool _eraseSavedSettings = true;
  bool get eraseSavedSettings => _eraseSavedSettings;

  set eraseSavedSettings(bool value) {
    _eraseSavedSettings = value;
    notifyListeners();
  }

  /// How the board should behave once it is running: run mode, wake interval,
  /// sleep windows, Wi-Fi credentials.
  ///
  /// A board used to be born in `pairing` mode and stay there until something
  /// provisioned it over a live link, which meant the answer to "what is this
  /// board for" was asked *after* the flash — over Bluetooth, to a board that
  /// sleeps most of the time. It is asked before the flash now and travels in
  /// the calibration region, so the image itself claims the board.
  BoardSetup _boardSetup = const BoardSetup();
  BoardSetup get boardSetup => _boardSetup;

  set boardSetup(BoardSetup value) {
    _boardSetup = value;
    notifyListeners();
  }

  /// Assembles the flashable image set for the selected board.
  ///
  /// Nothing is compiled here — the firmware `.bin` files were built by
  /// `tools/build_firmware.py` and ship inside the app. This checks they are
  /// present and intact, generates the calibration image from the settings on
  /// screen, writes that image out as a real file, and returns the plan the
  /// Flash screen then writes over USB.
  Future<FlashPlan> generateFlashImage() async {
    final board = _selectedBoard;
    final config = _pinConfiguration;
    if (board == null || config == null) {
      throw const FirmwareBundleException('Choose a board first.');
    }

    final setup = _boardSetup.forBoard(board);
    if (!setup.isComplete) {
      throw const FirmwareBundleException(
          'Name the Wi-Fi network this board should join, or set it to '
          'Bluetooth mode.');
    }

    final calibration = CalibrationImage.now(config, setup: setup);
    final plan = await firmwareBundles.buildPlan(
      boardId: board.id,
      config: config,
      setup: setup,
      eraseSavedSettings: _eraseSavedSettings,
      calibration: calibration,
    );

    _generatedImagePath = await _writeCalibrationFile(board.id, calibration);
    _flashPlan = plan;
    notifyListeners();
    return plan;
  }

  /// Drops the calibration image into app storage so there is a real artefact
  /// to point at — inspectable, and the same bytes that go into flash.
  Future<String?> _writeCalibrationFile(
      String boardId, CalibrationImage image) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final out = Directory('${dir.path}/generated');
      if (!out.existsSync()) out.createSync(recursive: true);
      final file = File('${out.path}/$boardId-calibration.bin');
      await file.writeAsBytes(image.build(), flush: true);
      return file.path;
    } catch (_) {
      // Storage is a convenience here: the plan already holds the bytes.
      return null;
    }
  }

  // MARK: Flashing

  Future<void> flash(FirmwareImage image) async {
    final data = await firmwareRepo.download(image);
    await flasher.flash(data, _activeTransport);
  }

  Future<void> flashLocal(Uint8List data) =>
      flasher.flash(data, _activeTransport);

  // MARK: Private

  void _wireSampleStreams() {
    _sampleSubs.add(ble.samples.listen(_ingest));
    _sampleSubs.add(wifi.samples.listen(_ingest));
  }

  void _ingest(DeviceSample sample) {
    final cfg = _pinConfiguration;
    if (cfg == null) return;

    final volts = cfg.voltageFromRawADC(sample.rawADC);
    _readings.add(BatteryReading(
      timestamp: sample.timestamp,
      rawADC: sample.rawADC,
      voltage: volts,
      percentage: cfg.percentageForVoltage(volts),
      pinId: cfg.batteryPinId,
    ));
    if (_readings.length > _maxReadings) {
      _readings.removeRange(0, _readings.length - _maxReadings);
    }
    _checkLowBattery(volts, cfg);
    notifyListeners();
  }

  /// Feed a live reading to the warning.
  ///
  /// Unawaited on purpose: posting a notification is a platform round trip and
  /// samples arrive on a timer, so waiting on it here would stall the chart.
  void _checkLowBattery(double volts, PinConfiguration cfg) {
    final deviceId = ble.connectedDeviceId ?? wifi.connected?.id ?? cfg.boardId;
    unawaited(alerts
        .ingest(
          deviceId: deviceId,
          deviceName: _liveDeviceName(deviceId, cfg),
          volts: volts,
        )
        .catchError((_) => false));
  }

  /// What to call the board being monitored, in a notification the user reads
  /// with the app closed — so a name, never a bare BLE address if we have one.
  String _liveDeviceName(String deviceId, PinConfiguration cfg) {
    final chosen = cfg.deviceName?.trim();
    if (chosen != null && chosen.isNotEmpty) return chosen;
    for (final device in ble.discovered) {
      if (device.id == deviceId && device.name.isNotEmpty) return device.name;
    }
    return wifi.connected?.name ?? 'This board';
  }

  static Future<List<Board>> _loadBoards() async {
    try {
      final raw = await rootBundle.loadString('assets/boards.json');
      return (jsonDecode(raw) as List)
          .map((e) => Board.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      assert(false, 'boards.json decode failed: $e');
      return [];
    }
  }

  @override
  void dispose() {
    for (final s in _sampleSubs) {
      s.cancel();
    }
    alerts.dispose();
    beaconLog.dispose();
    beaconScan.dispose();
    usbFlasher.dispose();
    ble.dispose();
    wifi.dispose();
    flasher.dispose();
    firmwareRepo.dispose();
    super.dispose();
  }
}
