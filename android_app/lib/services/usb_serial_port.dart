import 'dart:async';

import 'package:flutter/services.dart';

import 'esp_loader.dart';

/// A USB-serial adapter the phone can see on its OTG port.
class UsbSerialDevice {
  final int deviceId;
  final int vendorId;
  final int productId;
  final String? product;
  final String? manufacturer;

  /// Which bridge driver the native side matched: `cdc`, `cp210x`, `ch34x` or
  /// `ftdi`.
  final String driver;

  final bool hasPermission;

  const UsbSerialDevice({
    required this.deviceId,
    required this.vendorId,
    required this.productId,
    required this.driver,
    required this.hasPermission,
    this.product,
    this.manufacturer,
  });

  /// What the user sees in the picker — the board's own name where the
  /// descriptor has one, otherwise the bridge chip.
  String get title {
    final name = (product ?? '').trim();
    if (name.isNotEmpty) return name;
    return switch (driver) {
      'cp210x' => 'CP210x USB bridge',
      'ch34x' => 'CH340 USB bridge',
      'ftdi' => 'FTDI USB bridge',
      _ => 'USB serial device',
    };
  }

  String get idsDisplay =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}';

  factory UsbSerialDevice.fromMap(Map<dynamic, dynamic> map) => UsbSerialDevice(
        deviceId: (map['deviceId'] as num).toInt(),
        vendorId: (map['vid'] as num?)?.toInt() ?? 0,
        productId: (map['pid'] as num?)?.toInt() ?? 0,
        product: map['product'] as String?,
        manufacturer: map['manufacturer'] as String?,
        driver: map['driver'] as String? ?? 'cdc',
        hasPermission: map['hasPermission'] as bool? ?? false,
      );
}

class UsbSerialException implements Exception {
  final String message;

  const UsbSerialException(this.message);

  @override
  String toString() => message;
}

/// The Dart half of [UsbSerialBridge] on the Android side.
///
/// One port at a time — there is one OTG socket, and the native bridge holds
/// one connection — so this is a singleton rather than something you construct
/// per screen.
class UsbSerialPort implements SerialTransport {
  static const MethodChannel _channel =
      MethodChannel('com.batteryholder/usb_serial');
  static const EventChannel _events =
      EventChannel('com.batteryholder/usb_serial/events');
  static const EventChannel _deviceEvents =
      EventChannel('com.batteryholder/usb_serial/devices');

  static final UsbSerialPort instance = UsbSerialPort._();

  UsbSerialPort._();

  Stream<Uint8List>? _incoming;
  bool _isOpen = false;

  bool get isOpen => _isOpen;

  /// Fires whenever a serial device is plugged in or pulled out.
  ///
  /// A board that resets can take its USB port with it and come back under a
  /// new device id, so anything holding a device needs to re-read the list
  /// rather than assume the one it has is still there.
  static Stream<void> get deviceEvents {
    try {
      return _deviceEvents.receiveBroadcastStream();
    } on MissingPluginException {
      return const Stream.empty();
    }
  }

  /// Serial adapters currently plugged in. Empty is the normal answer when
  /// nothing is attached — not an error.
  static Future<List<UsbSerialDevice>> list() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('list');
      return (raw ?? [])
          .map((e) => UsbSerialDevice.fromMap(e as Map<dynamic, dynamic>))
          .toList();
    } on PlatformException catch (e) {
      throw UsbSerialException(e.message ?? 'Could not list USB devices.');
    } on MissingPluginException {
      // Anything that is not the Android app (tests, desktop) has no bridge.
      return const [];
    }
  }

  /// Asks Android for access to one device. The dialog is the system's; the
  /// answer comes back here.
  static Future<bool> requestPermission(int deviceId) async {
    try {
      return await _channel.invokeMethod<bool>(
              'requestPermission', {'deviceId': deviceId}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> open(int deviceId, {int baudRate = 115200}) async {
    final ok = await _channel.invokeMethod<bool>(
            'open', {'deviceId': deviceId, 'baudRate': baudRate}) ??
        false;
    if (!ok) {
      throw const UsbSerialException(
          'Could not open the USB device. Unplug it, plug it back in and allow '
          'access when Android asks.');
    }
    _isOpen = true;
  }

  @override
  Stream<Uint8List> get incoming => _incoming ??= _events
      .receiveBroadcastStream()
      .map((event) => event is Uint8List ? event : Uint8List(0))
      .asBroadcastStream();

  @override
  Future<void> write(Uint8List data) async {
    final written =
        await _channel.invokeMethod<int>('write', {'data': data}) ?? -1;
    if (written < data.length) {
      throw const UsbSerialException('The USB write was cut short.');
    }
  }

  @override
  Future<void> setBaudRate(int baudRate) =>
      _channel.invokeMethod<void>('setBaudRate', {'baudRate': baudRate});

  @override
  Future<void> setControlLines({required bool dtr, required bool rts}) =>
      _channel.invokeMethod<void>('setControlLines', {'dtr': dtr, 'rts': rts});

  @override
  Future<void> close() async {
    if (!_isOpen) return;
    _isOpen = false;
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // The cable may already be out; nothing left to release.
    }
  }
}
