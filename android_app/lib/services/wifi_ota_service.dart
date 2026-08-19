import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart' as nsd;

import '../models/battery_reading.dart';
import '../models/pin_configuration.dart';

class WiFiDevice {
  /// Bonjour service name.
  final String id;
  final String name;
  final String host;
  final int port;

  const WiFiDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });

  Uri get baseUrl => Uri.parse('http://$host:$port');

  @override
  bool operator ==(Object other) => other is WiFiDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// How the board on the LAN is currently answering. A sleeping board and a
/// broken network look identical at the socket level, so this is inferred from
/// a run of consecutive poll failures — FLUTTER_APP_HANDOFF.md §6.
enum WiFiReachability {
  /// Answering polls.
  live,

  /// Missed a couple of polls in a row — almost certainly deep asleep.
  asleep,

  /// Missed long enough that something else is probably wrong.
  unreachable,
}

class WiFiException implements Exception {
  final String message;
  const WiFiException(this.message);

  static const notConnected =
      WiFiException('No board selected on the network.');
  static const badResponse =
      WiFiException('The board returned an unexpected response.');
  static const resolveFailed =
      WiFiException("Could not resolve the board's address.");

  @override
  String toString() => message;
}

/// Discovers boards via Bonjour/mDNS and drives voltage polling + HTTP OTA.
///
/// Port of the iOS `WiFiOTAService`. `NWBrowser` becomes the `nsd` plugin,
/// which wraps Android's `NsdManager`; resolution is handled by the platform
/// rather than by opening a probe connection.
class WiFiOTAService extends ChangeNotifier {
  static const serviceType = '_batteryholder._tcp';

  final List<WiFiDevice> _discovered = [];
  bool _isBrowsing = false;
  WiFiDevice? _connected;
  DeviceSample? _latestSample;

  List<WiFiDevice> get discovered => List.unmodifiable(_discovered);
  bool get isBrowsing => _isBrowsing;
  WiFiDevice? get connected => _connected;
  DeviceSample? get latestSample => _latestSample;

  final _sampleController = StreamController<DeviceSample>.broadcast();
  Stream<DeviceSample> get samples => _sampleController.stream;

  nsd.Discovery? _discovery;
  Timer? _pollTimer;
  final _client = http.Client();

  /// Consecutive failed polls, used to infer [reachability] and to back off.
  int _pollFailures = 0;
  int _pollIntervalMs = 1000;
  int _basePollIntervalMs = 1000;

  WiFiReachability get reachability {
    if (_pollFailures == 0) return WiFiReachability.live;
    return _pollFailures <= _asleepAfterFailures
        ? WiFiReachability.asleep
        : WiFiReachability.unreachable;
  }

  /// Two misses is enough to call it asleep; the board's wake window is short.
  static const _asleepAfterFailures = 3;

  /// Ceiling on the backoff, so a woken board is picked up within a wake window.
  static const _maxPollIntervalMs = 15000;

  // MARK: Discovery

  Future<void> startBrowsing() async {
    if (_discovery != null) return;
    _discovered.clear();
    _isBrowsing = true;
    notifyListeners();

    try {
      final discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.any);
      _discovery = discovery;
      discovery.addServiceListener((service, status) {
        if (status == nsd.ServiceStatus.found) {
          _add(service);
        } else {
          _discovered.removeWhere((d) => d.id == (service.name ?? ''));
          notifyListeners();
        }
      });
    } catch (_) {
      _isBrowsing = false;
      notifyListeners();
    }
  }

  void _add(nsd.Service service) {
    final name = service.name;
    final port = service.port;
    final host = service.addresses?.firstOrNull?.address ?? service.host;
    if (name == null || port == null || host == null) return;
    if (_discovered.any((d) => d.id == name)) return;

    _discovered.add(WiFiDevice(id: name, name: name, host: host, port: port));
    notifyListeners();
  }

  Future<void> stopBrowsing() async {
    final discovery = _discovery;
    _discovery = null;
    _isBrowsing = false;
    notifyListeners();
    if (discovery != null) {
      try {
        await nsd.stopDiscovery(discovery);
      } catch (_) {
        // Already torn down.
      }
    }
  }

  void connect(WiFiDevice device) {
    _connected = device;
    notifyListeners();
  }

  void disconnect() {
    stopPolling();
    _connected = null;
    notifyListeners();
  }

  // MARK: Voltage polling

  void startPolling({required int intervalMs}) {
    final device = _connected;
    if (device == null) return;
    stopPolling();
    _basePollIntervalMs = intervalMs;
    _pollIntervalMs = intervalMs;
    _pollFailures = 0;
    _scheduleNextPoll(device, immediate: true);
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// One-shot rescheduling rather than [Timer.periodic]: the interval grows
  /// while the board is asleep, so there is no fixed period to lock in.
  void _scheduleNextPoll(WiFiDevice device, {bool immediate = false}) {
    _pollTimer?.cancel();
    _pollTimer = Timer(
      Duration(milliseconds: immediate ? 0 : _pollIntervalMs),
      () async {
        await _pollOnce(device);
        // Only keep going if nobody stopped or reconnected in the meantime.
        if (_pollTimer != null && _connected?.id == device.id) {
          _scheduleNextPoll(device);
        }
      },
    );
  }

  Future<void> _pollOnce(WiFiDevice device) async {
    try {
      final response = await _client
          .get(device.baseUrl.resolve('api/voltage'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) throw WiFiException.badResponse;
      final dto = jsonDecode(response.body) as Map<String, dynamic>;
      final sample = DeviceSample(
        rawADC: dto['raw'] as int,
        deviceVolts: (dto['volts'] as num?)?.toDouble(),
        pinId: dto['pin'] as String?,
      );
      _latestSample = sample;
      _sampleController.add(sample);
      _pollFailures = 0;
      _pollIntervalMs = _basePollIntervalMs;
      notifyListeners();
    } catch (_) {
      // A miss usually means the board deep slept mid-cycle. Back off rather
      // than hammering the network for the rest of its sleep interval.
      _pollFailures++;
      _pollIntervalMs =
          (_pollIntervalMs * 2).clamp(_basePollIntervalMs, _maxPollIntervalMs);
      notifyListeners();
    }
  }

  // MARK: Pin configuration

  Future<void> writePinConfiguration(PinConfiguration config) async {
    final device = _connected;
    if (device == null) throw WiFiException.notConnected;
    final response = await _client.post(
      device.baseUrl.resolve('api/config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    if (response.statusCode != 200) throw WiFiException.badResponse;
  }

  // MARK: OTA upload

  Future<void> uploadFirmware(
    Uint8List image,
    void Function(double) onProgress,
  ) async {
    final device = _connected;
    if (device == null) throw WiFiException.notConnected;

    final request = _ProgressMultipartRequest(
      'POST',
      device.baseUrl.resolve('update'),
      onProgress: onProgress,
    )..files.add(http.MultipartFile.fromBytes(
        'firmware',
        image,
        filename: 'firmware.bin',
      ));

    final response = await request.send();
    if (response.statusCode != 200) throw WiFiException.badResponse;
  }

  @override
  void dispose() {
    stopPolling();
    stopBrowsing();
    _client.close();
    _sampleController.close();
    super.dispose();
  }
}

/// Reports byte-level upload progress for the firmware POST, the way
/// `URLSessionTaskDelegate.didSendBodyData` does on iOS.
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(double) onProgress;

  _ProgressMultipartRequest(super.method, super.url, {required this.onProgress});

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    final total = contentLength;
    if (total <= 0) return byteStream;

    var sent = 0;
    final transformer = StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (data, sink) {
        sent += data.length;
        onProgress(sent / total);
        sink.add(data);
      },
    );
    return http.ByteStream(byteStream.transform(transformer));
  }
}
