import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Controls the native foreground service that logs board advertisements while
/// the app is closed (`BeaconScanService.kt`).
///
/// Boards advertise for ~20 s every few minutes, so logging that only ran while
/// a screen was open would miss nearly every wake. The service scans
/// continuously and appends to the same JSON-lines file `BeaconLogStore` reads.
class BeaconScanServiceClient extends ChangeNotifier {
  static const _channel =
      MethodChannel('com.batteryholder/beacon_scan');

  bool _enabled = false;
  bool _scanning = false;
  bool _available = true;
  bool _busy = false;

  /// Whether the user has background logging switched on.
  bool get isEnabled => _enabled;

  /// Whether the service is actually scanning right now.
  ///
  /// Not the same question as [isEnabled], and the difference is the one the
  /// user needs told: Android can kill the service, Bluetooth can be switched
  /// off, and a permission can be revoked from Settings — in every one of those
  /// the feature is still "on" and nothing is being logged.
  bool get isScanning => _scanning;

  /// True while a start/stop is in flight, so the switch can show that it heard
  /// the tap rather than sitting still through a permission dialog.
  bool get isBusy => _busy;

  /// False on platforms with no native side (tests, desktop).
  bool get isAvailable => _available;

  /// Re-read both the stored flag and whether a scan is really in flight.
  ///
  /// Worth calling whenever the Monitor screen comes back into view: the
  /// service can die while the app is away, and the switch is a lie until this
  /// runs again.
  Future<void> refresh() async {
    try {
      _enabled = await _channel.invokeMethod<bool>('isEnabled') ?? false;
      _scanning = await _channel.invokeMethod<bool>('isScanning') ?? false;
      _available = true;
    } on MissingPluginException {
      _available = false;
      _enabled = false;
      _scanning = false;
    } catch (_) {
      _enabled = false;
      _scanning = false;
    }
    notifyListeners();
  }

  /// Start background logging. Returns false when a required permission was
  /// refused, so the caller can explain rather than silently doing nothing.
  Future<bool> start() async {
    _busy = true;
    notifyListeners();
    try {
      if (!await _ensurePermissions()) return false;
      await _channel.invokeMethod('start');
      _enabled = true;
      // The service starts asynchronously, and it gives up quietly when
      // Bluetooth is off. Ask it a moment later whether it really scans, so
      // the switch reports what happened rather than what was requested.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _scanning = await _channel.invokeMethod<bool>('isScanning') ?? false;
      return true;
    } on MissingPluginException {
      _available = false;
      return false;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _busy = true;
    notifyListeners();
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // Service may already be gone; the flag below is what the UI reads.
    }
    _enabled = false;
    _scanning = false;
    _busy = false;
    notifyListeners();
  }

  /// Scanning needs the Bluetooth permissions; the ongoing notification needs
  /// POST_NOTIFICATIONS on Android 13+, and without it the foreground service
  /// cannot show its notification and Android may refuse to keep it alive.
  Future<bool> _ensurePermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    // locationWhenInUse stands in for BLUETOOTH_SCAN on API 30 and below, so
    // accept either as proof we can scan.
    final canScan = (results[Permission.bluetoothScan]?.isGranted ?? false) ||
        (results[Permission.locationWhenInUse]?.isGranted ?? false);
    return canScan;
  }
}
