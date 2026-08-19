
import 'package:flutter/foundation.dart';

import '../models/board.dart';
import '../models/firmware_image.dart';
import 'ble_manager.dart';
import 'firmware_repository.dart';
import 'wifi_ota_service.dart';

/// Transport-agnostic OTA orchestrator. Given firmware bytes and a chosen
/// transport, it drives the right service and publishes a single progress
/// stream the UI can bind to.
class FirmwareFlasher extends ChangeNotifier {
  FlashProgress _progress = const FlashProgress();
  FlashProgress get progress => _progress;

  final BLEManager ble;
  final WiFiOTAService wifi;

  FirmwareFlasher({required this.ble, required this.wifi});

  Future<void> flash(Uint8List data, FlashTransport transport) async {
    _set(const FlashProgress(
      phase: FlashPhase.preparing,
      fraction: 0,
      message: 'Preparing update…',
    ));

    try {
      _set(_progress.copyWith(
        phase: FlashPhase.uploading,
        message: 'Uploading firmware over ${transport.displayName}…',
      ));

      void onProgress(double fraction) =>
          _set(_progress.copyWith(fraction: fraction));

      switch (transport) {
        case FlashTransport.ble:
          await ble.uploadFirmware(data, onProgress);
        case FlashTransport.wifi:
          await wifi.uploadFirmware(data, onProgress);
      }

      _set(_progress.copyWith(
          phase: FlashPhase.verifying, message: 'Verifying…'));
      _set(_progress.copyWith(
          phase: FlashPhase.rebooting, message: 'Rebooting board…'));
      _set(_progress.copyWith(
          phase: FlashPhase.done, fraction: 1, message: 'Update complete'));
    } catch (e) {
      final message = describeError(e);
      _set(_progress.copyWith(
        phase: FlashPhase.failed,
        message: message,
        failureMessage: message,
      ));
      rethrow;
    }
  }

  void reset() => _set(const FlashProgress());

  void _set(FlashProgress progress) {
    _progress = progress;
    notifyListeners();
  }
}

/// Unwraps our typed exceptions into the message the UI shows, the way
/// `LocalizedError.errorDescription` does on iOS.
String describeError(Object error) => switch (error) {
      BLEException e => e.message,
      WiFiException e => e.message,
      FirmwareRepositoryException e => e.message,
      _ => error.toString().replaceFirst(RegExp(r'^(Exception|Error): '), ''),
    };
