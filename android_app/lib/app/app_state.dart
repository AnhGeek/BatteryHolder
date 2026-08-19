import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/battery_reading.dart';
import '../models/board.dart';
import '../models/firmware_image.dart';
import '../models/pin.dart';
import '../models/pin_configuration.dart';
import '../services/ble_manager.dart';
import '../services/firmware_flasher.dart';
import '../services/firmware_repository.dart';
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

  final List<StreamSubscription<DeviceSample>> _sampleSubs = [];
  static const _maxReadings = 120;

  AppState({
    BLEManager? ble,
    WiFiOTAService? wifi,
    FirmwareRepository? firmwareRepo,
  })  : ble = ble ?? BLEManager(),
        wifi = wifi ?? WiFiOTAService(),
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
    notifyListeners();
  }

  void setBatteryPin(Pin pin) {
    final cfg = _pinConfiguration;
    if (cfg == null) return;
    _pinConfiguration = cfg.copyWith(batteryPinId: pin.id);
    notifyListeners();
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
    ble.setNotifying(false);
    // Hand the board back to its sleep cycle; leaving it awake would burn the
    // pack until the idle timeout fires.
    ble.sleepNow().catchError((_) {});
    wifi.stopPolling();
    notifyListeners();
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
    notifyListeners();
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
    ble.dispose();
    wifi.dispose();
    flasher.dispose();
    firmwareRepo.dispose();
    super.dispose();
  }
}
