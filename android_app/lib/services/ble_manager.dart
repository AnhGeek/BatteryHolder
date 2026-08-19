import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/battery_reading.dart';
import '../models/device_status.dart';
import '../models/pin_configuration.dart';

/// GATT contract shared with the reference firmware — DEVICE_PROTOCOL.md §2.
class BLEUUID {
  static final service = Guid('A1B2C3D4-0001-4A5B-8C6D-000000000000');
  static final voltage = Guid('A1B2C3D4-0002-4A5B-8C6D-000000000000');
  static final rawADC = Guid('A1B2C3D4-0003-4A5B-8C6D-000000000000');
  static final pinConfig = Guid('A1B2C3D4-0004-4A5B-8C6D-000000000000');
  static final otaControl = Guid('A1B2C3D4-0005-4A5B-8C6D-000000000000');
  static final otaData = Guid('A1B2C3D4-0006-4A5B-8C6D-000000000000');

  // v2 additions. Absent on firmware 1.x — see [BLEManager.supportsV2].
  static final provisioning = Guid('A1B2C3D4-0007-4A5B-8C6D-000000000000');
  static final status = Guid('A1B2C3D4-0008-4A5B-8C6D-000000000000');
  static final session = Guid('A1B2C3D4-0009-4A5B-8C6D-000000000000');
}

/// Manufacturer-data company id the firmware advertises under (§2.1).
const int kAdvCompanyId = 0xFFFF;

/// A board seen in a scan, enriched with whatever its advertisement carried.
class DiscoveredDevice {
  final String id;
  final String name;
  int rssi;
  final BluetoothDevice device;

  /// True once the advertisement's `0x42` marker was seen — v1 boards send no
  /// manufacturer data at all, so every flag below stays at its default.
  final bool hasAdvData;
  final bool provisioned;
  final bool wifiMode;
  final bool pairingMode;
  final bool wifiOnline;
  final double? volts;

  /// State of charge, 0–100.
  final int? soc;

  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.device,
    this.hasAdvData = false,
    this.provisioned = false,
    this.wifiMode = false,
    this.pairingMode = false,
    this.wifiOnline = false,
    this.volts,
    this.soc,
  });

  /// Board needs the setup wizard before it will report anything.
  bool get needsSetup => hasAdvData && !provisioned;

  DiscoveredDevice copyWith({
    bool? provisioned,
    bool? wifiMode,
    bool? pairingMode,
  }) =>
      DiscoveredDevice(
        id: id,
        name: name,
        rssi: rssi,
        device: device,
        hasAdvData: hasAdvData,
        provisioned: provisioned ?? this.provisioned,
        wifiMode: wifiMode ?? this.wifiMode,
        pairingMode: pairingMode ?? this.pairingMode,
        wifiOnline: wifiOnline,
        volts: volts,
        soc: soc,
      );

  /// Decodes the §2.1 manufacturer-data payload. Returns the device with flags
  /// filled in, or with [hasAdvData] false when the payload is absent or not
  /// ours.
  factory DiscoveredDevice.fromScan(ScanResult r) {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : (r.device.platformName.isNotEmpty
            ? r.device.platformName
            : 'ESP device');
    final base = DiscoveredDevice(
      id: r.device.remoteId.str,
      name: name,
      rssi: r.rssi,
      device: r.device,
    );

    final bytes = r.advertisementData.manufacturerData[kAdvCompanyId];
    // Guard on the marker: anything else on 0xFFFF is another vendor's test id.
    if (bytes == null || bytes.length < 6 || bytes[0] != 0x42) return base;

    final flags = bytes[2];
    return DiscoveredDevice(
      id: base.id,
      name: name,
      rssi: r.rssi,
      device: r.device,
      hasAdvData: true,
      provisioned: (flags & 0x01) != 0,
      wifiMode: (flags & 0x02) != 0,
      pairingMode: (flags & 0x04) != 0,
      wifiOnline: (flags & 0x08) != 0,
      volts: (bytes[3] | (bytes[4] << 8)) / 1000.0,
      soc: bytes[5],
    );
  }
}

enum ConnectionStatus {
  disconnected,
  connecting,
  discovering,
  connected,

  /// The board closed its wake window and deep slept. An expected outcome, not
  /// a failure — DEVICE_PROTOCOL.md §2.3.
  sleeping,
  failed,
}

class ConnectionState {
  final ConnectionStatus status;
  final String? message;

  const ConnectionState(this.status, [this.message]);

  static const disconnected = ConnectionState(ConnectionStatus.disconnected);
  static const connecting = ConnectionState(ConnectionStatus.connecting);
  static const discovering = ConnectionState(ConnectionStatus.discovering);
  static const connected = ConnectionState(ConnectionStatus.connected);
  static const sleeping = ConnectionState(ConnectionStatus.sleeping);

  factory ConnectionState.failed(String message) =>
      ConnectionState(ConnectionStatus.failed, message);

  bool get isConnected => status == ConnectionStatus.connected;
}

class BLEException implements Exception {
  final String message;
  const BLEException(this.message);

  static const notConnected = BLEException('Not connected to a board.');
  static const missingCharacteristic =
      BLEException('The board is missing a required characteristic.');
  static const notSupported = BLEException(
      'This board runs older firmware that does not support this.');

  factory BLEException.otaRejected(String m) =>
      BLEException('The board rejected the update: $m');

  @override
  String toString() => message;
}

/// Bluetooth LE central that speaks the BatteryHolder GATT contract.
///
/// Implements device protocol v2: the board is asleep most of the time, so a
/// fruitless scan and a self-initiated disconnect are both normal. Screens that
/// need a live link hold it open with [stayAwake] / [sleepNow], ideally through
/// [withAwakeBoard].
class BLEManager extends ChangeNotifier {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _isScanning = false;
  final List<DiscoveredDevice> _discovered = [];
  ConnectionState _connection = ConnectionState.disconnected;
  DeviceSample? _latestSample;
  DeviceStatus? _status;

  BluetoothAdapterState get adapterState => _adapterState;
  bool get isPoweredOn => _adapterState == BluetoothAdapterState.on;
  bool get isScanning => _isScanning;
  List<DiscoveredDevice> get discovered => List.unmodifiable(_discovered);
  ConnectionState get connection => _connection;
  DeviceSample? get latestSample => _latestSample;

  /// Last status object the board pushed or we read (§2.3).
  DeviceStatus? get status => _status;

  /// True when the connected board exposes the v2 characteristics. v1 boards
  /// are driven exactly as before; callers should hide v2-only UI when false.
  bool get supportsV2 =>
      _chars.containsKey(BLEUUID.status) && _chars.containsKey(BLEUUID.session);

  bool get supportsProvisioning => _chars.containsKey(BLEUUID.provisioning);

  /// Keep rescanning until told to stop — the board may be mid-sleep-cycle.
  bool _keepLooking = false;
  bool get keepLooking => _keepLooking;

  /// Emits every interpreted sample; `AppState` subscribes to build readings.
  final _sampleController = StreamController<DeviceSample>.broadcast();
  Stream<DeviceSample> get samples => _sampleController.stream;

  /// Emits every status push — the setup wizard drives itself off this.
  final _statusController = StreamController<DeviceStatus>.broadcast();
  Stream<DeviceStatus> get statusEvents => _statusController.stream;

  BluetoothDevice? _peripheral;
  final Map<Guid, BluetoothCharacteristic> _chars = {};
  double? _lastDeviceVolts;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription<List<int>>> _valueSubs = [];

  /// Completes when the board acknowledges the end of an OTA transfer.
  Completer<void>? _otaCompleter;

  /// Nesting depth of [withAwakeBoard], so nested calls do not sleep the board
  /// out from under an outer one.
  int _awakeDepth = 0;

  /// §2.6: long enough to catch a board that wakes every few minutes.
  static const scanTimeout = Duration(seconds: 30);

  BLEManager() {
    // Where the platform has no Bluetooth stack (tests, desktop), the plugin
    // throws instead of emitting; treat that as "adapter unavailable" so the
    // UI just shows the turn-on-Bluetooth callout rather than crashing.
    _adapterSub = FlutterBluePlus.adapterState.listen(
      (state) {
        _adapterState = state;
        if (state != BluetoothAdapterState.on) _isScanning = false;
        notifyListeners();
      },
      onError: (_) {
        _adapterState = BluetoothAdapterState.unavailable;
        _isScanning = false;
        notifyListeners();
      },
    );
    _scanningSub = FlutterBluePlus.isScanning.listen(
      (scanning) {
        _isScanning = scanning;
        notifyListeners();
        // §2.6 "keep looking": relaunch as soon as a sweep ends.
        if (!scanning && _keepLooking && isPoweredOn) {
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            if (_keepLooking) _startScanNow(clear: false);
          });
        }
      },
      onError: (_) {},
    );
  }

  // MARK: Scan

  /// Android needs runtime permission before it will hand back scan results;
  /// iOS covers this with the Info.plist usage strings alone.
  Future<bool> requestPermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return results[Permission.bluetoothScan]?.isGranted ?? false;
  }

  /// One 30-second sweep. Set [keepLooking] to rescan until [stopScan].
  Future<void> startScan({bool keepLooking = false}) async {
    if (!await requestPermissions()) return;
    if (!isPoweredOn) return;
    _keepLooking = keepLooking;
    await _startScanNow(clear: true);
  }

  Future<void> _startScanNow({required bool clear}) async {
    if (clear) {
      _discovered.clear();
      notifyListeners();
    }

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final device = DiscoveredDevice.fromScan(r);
        final existing = _discovered.indexWhere((d) => d.id == device.id);
        // Replace wholesale: the advertisement's battery and flag bytes change
        // between wakes, so keeping the first sighting would show stale data.
        if (existing >= 0) {
          _discovered[existing] = device;
        } else {
          _discovered.add(device);
        }
      }
      notifyListeners();
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [BLEUUID.service],
        timeout: scanTimeout,
      );
    } catch (_) {
      _keepLooking = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    _keepLooking = false;
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    notifyListeners();
  }

  // MARK: Connect

  Future<void> connect(DiscoveredDevice device) async {
    await stopScan();
    _connection = ConnectionState.connecting;
    _status = null;
    notifyListeners();

    _peripheral = device.device;
    try {
      await _connSub?.cancel();
      _connSub = device.device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _chars.clear();
          // A board that announced "sleeping" then dropped the link did exactly
          // what it should; don't overwrite that with a bare "disconnected".
          _connection = _status?.isSleeping ?? false
              ? ConnectionState.sleeping
              : ConnectionState.disconnected;
          _awakeDepth = 0;
          notifyListeners();
        }
      });

      await device.device.connect(timeout: const Duration(seconds: 15));

      _connection = ConnectionState.discovering;
      notifyListeners();

      final services = await device.device.discoverServices();
      final service =
          services.where((s) => s.uuid == BLEUUID.service).firstOrNull;
      if (service == null) {
        _connection = ConnectionState.failed('BatteryHolder service not found');
        notifyListeners();
        return;
      }

      _chars.clear();
      for (final ch in service.characteristics) {
        _chars[ch.uuid] = ch;
        _listen(ch);
      }

      // A larger MTU makes the OTA data path meaningfully faster on Android.
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await device.device.requestMtu(247);
        } catch (_) {
          // Not fatal: the transfer just uses smaller chunks.
        }
      }

      _connection = ConnectionState.connected;
      notifyListeners();

      // Subscribe to status before anything else so provisioning and sleep
      // events are never missed. Optional: v1 boards have no status char.
      await _subscribeStatus();
    } catch (e) {
      _connection = ConnectionState.failed(_describe(e));
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    for (final s in _valueSubs) {
      await s.cancel();
    }
    _valueSubs.clear();
    await _peripheral?.disconnect();
    _peripheral = null;
    _chars.clear();
    _awakeDepth = 0;
    _connection = ConnectionState.disconnected;
    notifyListeners();
  }

  void _listen(BluetoothCharacteristic ch) {
    _valueSubs.add(ch.onValueReceived.listen((data) => _handleValue(ch, data)));
  }

  Future<void> _subscribeStatus() async {
    final ch = _chars[BLEUUID.status];
    if (ch == null) return; // v1 board
    try {
      await ch.setNotifyValue(true);
      _handleStatusPayload(await ch.read());
    } catch (_) {
      // A board that refuses notify on status still works for everything else.
    }
  }

  void _handleValue(BluetoothCharacteristic ch, List<int> data) {
    if (ch.uuid == BLEUUID.voltage) {
      _lastDeviceVolts = _readFloat32LE(data);
    } else if (ch.uuid == BLEUUID.rawADC) {
      final sample = DeviceSample(
        rawADC: _readUInt16LE(data),
        deviceVolts: _lastDeviceVolts,
      );
      _latestSample = sample;
      _sampleController.add(sample);
      notifyListeners();
    } else if (ch.uuid == BLEUUID.status) {
      _handleStatusPayload(data);
    } else if (ch.uuid == BLEUUID.otaControl) {
      _handleOTAStatus(data);
    }
  }

  void _handleStatusPayload(List<int> data) {
    if (data.isEmpty) return;
    try {
      final decoded = jsonDecode(utf8.decode(data, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return;
      final status = DeviceStatus.fromJson(decoded);
      _status = status;
      _statusController.add(status);
      if (status.isSleeping) _connection = ConnectionState.sleeping;
      notifyListeners();
    } catch (_) {
      // A truncated notification is not worth surfacing.
    }
  }

  // MARK: Monitoring

  /// Subscribing also holds the wake open on its own — the firmware watches the
  /// CCCD — so a monitor screen will not be cut off mid-chart.
  Future<void> setNotifying(bool on) async {
    for (final uuid in [BLEUUID.voltage, BLEUUID.rawADC]) {
      final ch = _chars[uuid];
      if (ch == null) continue;
      try {
        await ch.setNotifyValue(on);
      } catch (_) {
        // A board that doesn't advertise notify on one of these is still usable.
      }
    }
  }

  // MARK: Pin configuration

  Future<void> writePinConfiguration(PinConfiguration config) async {
    if (_peripheral == null) throw BLEException.notConnected;
    final ch = _chars[BLEUUID.pinConfig];
    if (ch == null) throw BLEException.missingCharacteristic;
    await ch.write(utf8.encode(jsonEncode(config.toJson())),
        withoutResponse: false);
  }

  // MARK: Session control (§2.4)

  Future<void> _writeSession(List<int> payload) async {
    if (_peripheral == null) throw BLEException.notConnected;
    final ch = _chars[BLEUUID.session];
    if (ch == null) throw BLEException.notSupported;
    await ch.write(payload, withoutResponse: false);
  }

  /// `0x01 STAY_AWAKE` — [seconds] 0 means "until I disconnect".
  Future<void> stayAwake({int seconds = 0}) =>
      _writeSession([0x01, ..._uint16LE(seconds)]);

  /// `0x02 SLEEP_NOW` — a non-null [intervalSec] also updates the interval.
  Future<void> sleepNow({int? intervalSec}) =>
      _writeSession([0x02, ..._uint32LE(intervalSec ?? 0)]);

  /// `0x03 FACTORY_RESET` — wipes NVS and reboots into pairing.
  Future<void> factoryReset() => _writeSession([0x03]);

  /// `0x04 SET_MODE`.
  Future<void> setMode(RunMode mode) =>
      _writeSession([0x04, mode.wireValue]);

  /// `0x05 FORGET_WIFI` — drops credentials and falls back to BLE mode.
  Future<void> forgetWifi() => _writeSession([0x05]);

  /// `0x06 IDENTIFY` — blinks the status LED.
  ///
  /// Returns false when the board answers that it has no LED to blink (the
  /// C3/S3 DevKit variants that ship without a discrete one), so the caller can
  /// say so rather than claiming a success the user cannot see. Firmware that
  /// does not answer at all is assumed to have blinked.
  Future<bool> identify() async {
    final answered = statusEvents
        .firstWhere((s) => s.event == 'identify')
        .timeout(const Duration(seconds: 3),
            onTimeout: () => const DeviceStatus());
    await _writeSession([0x06]);
    return (await answered).detail != 'no-led';
  }

  /// Hold the board awake for the duration of [body], then let it sleep again.
  ///
  /// Nesting is safe: only the outermost call issues [sleepNow]. On a v1 board
  /// (no session characteristic) this is a transparent pass-through.
  Future<T> withAwakeBoard<T>(Future<T> Function() body) async {
    if (!supportsV2) return body();

    if (_awakeDepth == 0) {
      try {
        await stayAwake();
      } catch (_) {
        // Board may already be gone; let [body] surface the real failure.
      }
    }
    _awakeDepth++;
    try {
      return await body();
    } finally {
      _awakeDepth--;
      if (_awakeDepth == 0 && _connection.isConnected) {
        try {
          await sleepNow();
        } catch (_) {
          // Losing the link before we can hand it back is harmless — the
          // board's idle timeout puts it to sleep anyway.
        }
      }
    }
  }

  // MARK: Provisioning (§2.5)

  /// Write the provisioning payload. The board answers asynchronously on the
  /// status characteristic — drive the UI off [statusEvents], not this future.
  Future<void> provision({
    required RunMode mode,
    String? ssid,
    String? password,
    String? backendUrl,
    String? deviceToken,
    int? reportIntervalSec,
    PowerConfig? power,
  }) async {
    if (_peripheral == null) throw BLEException.notConnected;
    final ch = _chars[BLEUUID.provisioning];
    if (ch == null) throw BLEException.notSupported;

    final payload = <String, dynamic>{
      'mode': mode.name,
      'ssid': ?ssid,
      'password': ?password,
      'backendUrl': ?backendUrl,
      'deviceToken': ?deviceToken,
      'reportIntervalSec': ?reportIntervalSec,
      'power': ?power?.toJson(),
    };
    await ch.write(utf8.encode(jsonEncode(payload)), withoutResponse: false);
  }

  /// Correct the cached scan entry after setup succeeds.
  ///
  /// The list still holds the advertisement captured *before* provisioning, so
  /// without this a board the user just set up keeps its "Needs setup" badge
  /// until it next wakes and re-advertises — which can be minutes away.
  void markProvisioned(String deviceId, RunMode mode) {
    final index = _discovered.indexWhere((d) => d.id == deviceId);
    if (index < 0) return;
    _discovered[index] = _discovered[index].copyWith(
      provisioned: true,
      wifiMode: mode == RunMode.wifi,
      pairingMode: false,
    );
    notifyListeners();
  }

  /// Provisioning state without secrets, from the characteristic's read path.
  Future<Map<String, dynamic>?> readProvisioning() async {
    final ch = _chars[BLEUUID.provisioning];
    if (ch == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(await ch.read()));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Apply a power block. The firmware takes it through the provisioning
  /// payload, so this is a `mode`-preserving provisioning write.
  Future<void> writePower(PowerConfig power) => provision(
        mode: _status?.mode ?? RunMode.ble,
        power: power,
      );

  // MARK: OTA

  /// Stream a firmware image to the board using the OTA control/data
  /// characteristics. Completes when the board acknowledges success.
  ///
  /// Wrapped in [withAwakeBoard]: an OTA that starts seconds before the wake
  /// window closes would otherwise die mid-transfer.
  Future<void> uploadFirmware(
    Uint8List image,
    void Function(double) onProgress,
  ) =>
      withAwakeBoard(() => _uploadFirmware(image, onProgress));

  Future<void> _uploadFirmware(
    Uint8List image,
    void Function(double) onProgress,
  ) async {
    final device = _peripheral;
    if (device == null) throw BLEException.notConnected;
    final control = _chars[BLEUUID.otaControl];
    final dataChar = _chars[BLEUUID.otaData];
    if (control == null || dataChar == null) {
      throw BLEException.missingCharacteristic;
    }

    await control.setNotifyValue(true);

    // START | uint32 size (LE)
    await control.write([0x01, ..._uint32LE(image.length)],
        withoutResponse: false);

    // Stream chunks without response, sized to the negotiated MTU.
    final mtu = device.mtuNow;
    final chunkSize = (mtu - 3).clamp(20, 244);
    var offset = 0;
    while (offset < image.length) {
      final end = (offset + chunkSize).clamp(0, image.length);
      await dataChar.write(image.sublist(offset, end), withoutResponse: true);
      offset = end;
      onProgress(offset / image.length);
      // Light backpressure so the board's write queue keeps up.
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }

    // END | uint32 crc32 (LE), then await the board's status notification.
    final completer = Completer<void>();
    _otaCompleter = completer;
    await control.write([0x02, ..._uint32LE(crc32(image))],
        withoutResponse: false);
    return completer.future;
  }

  void _handleOTAStatus(List<int> data) {
    if (data.isEmpty) return;
    final completer = _otaCompleter;
    if (completer == null || completer.isCompleted) return;

    switch (data.first) {
      case 0x10: // done OK
        _otaCompleter = null;
        completer.complete();
      case 0x1F: // error
        final msg = data.length > 1
            ? utf8.decode(data.sublist(1), allowMalformed: true)
            : 'unknown';
        _otaCompleter = null;
        completer.completeError(BLEException.otaRejected(msg));
      default:
        break; // 0x00 = ready / progress ack, ignored
    }
  }

  // MARK: Helpers

  List<int> _uint16LE(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  List<int> _uint32LE(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];

  double? _readFloat32LE(List<int> data) {
    if (data.length < 4) return null;
    return ByteData.sublistView(Uint8List.fromList(data))
        .getFloat32(0, Endian.little);
  }

  int _readUInt16LE(List<int> data) {
    if (data.length < 2) return 0;
    return ByteData.sublistView(Uint8List.fromList(data))
        .getUint16(0, Endian.little);
  }

  String _describe(Object e) => e is BLEException
      ? e.message
      : e.toString().replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _adapterSub?.cancel();
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _connSub?.cancel();
    for (final s in _valueSubs) {
      s.cancel();
    }
    _sampleController.close();
    _statusController.close();
    super.dispose();
  }
}

/// Standard CRC-32 (IEEE 802.3), matching the reference firmware's check.
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1);
    }
  }
  return (~crc) & 0xFFFFFFFF;
}
