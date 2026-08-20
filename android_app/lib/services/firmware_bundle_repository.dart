import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../models/board_setup.dart';
import '../models/calibration_image.dart';
import '../models/firmware_bundle.dart';
import '../models/pin_configuration.dart';

class FirmwareBundleException implements Exception {
  final String message;

  const FirmwareBundleException(this.message);

  @override
  String toString() => message;
}

/// Reads the firmware that ships inside the app.
///
/// `tools/build_firmware.py` produced these binaries with arduino-cli on a
/// workstation; nothing here compiles anything. The repository's job is to load
/// the manifest, pull the right `.bin` files out of the asset bundle, and
/// assemble them — together with a freshly generated calibration image — into
/// the [FlashPlan] the USB flasher writes.
class FirmwareBundleRepository {
  final AssetBundle bundle;

  FirmwareBundleRepository({AssetBundle? bundle})
      : bundle = bundle ?? rootBundle;

  FirmwareManifest? _manifest;
  final Map<String, Uint8List> _partCache = {};

  /// The manifest, loaded once. A build that shipped no firmware at all gives
  /// an empty manifest rather than an error: the rest of the app still works,
  /// USB flashing simply has nothing to offer.
  Future<FirmwareManifest> manifest() async {
    final cached = _manifest;
    if (cached != null) return cached;
    try {
      final raw = await bundle.loadString('assets/firmware/manifest.json');
      return _manifest =
          FirmwareManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return _manifest = FirmwareManifest.empty;
    }
  }

  Future<FirmwareBundle?> bundleFor(String boardId) async =>
      (await manifest()).bundleFor(boardId);

  /// Assembles everything one USB session will write.
  ///
  /// This is what "Generate BIN file" runs: it proves the embedded images are
  /// present and readable, builds the calibration blob from the settings on
  /// screen, and hands back a plan whose byte count the Flash screen can show
  /// before anything is touched on the board.
  Future<FlashPlan> buildPlan({
    required String boardId,
    required PinConfiguration config,
    BoardSetup? setup,
    bool eraseSavedSettings = true,
    CalibrationImage? calibration,
  }) async {
    final board = await bundleFor(boardId);
    if (board == null) {
      throw FirmwareBundleException(
        'No firmware is bundled for this board. Run tools/build_firmware.py '
        '--board $boardId and rebuild the app.',
      );
    }
    if (board.parts.isEmpty) {
      throw const FirmwareBundleException(
          'The bundled firmware for this board has no images.');
    }

    final segments = <FlashSegment>[];

    // Blank the saved settings first: a board that has been used before holds
    // an old run mode and wake interval in NVS, and those would otherwise
    // outlive the reflash and make a "new" board behave like the old one.
    if (eraseSavedSettings) {
      for (final region in board.eraseRegions) {
        segments.add(FlashSegment(
          offset: region.offset,
          data: Uint8List(region.size)..fillRange(0, region.size, 0xFF),
          label: region.label.isEmpty ? 'saved settings' : region.label,
          blank: true,
        ));
      }
    }

    for (final part in board.parts) {
      segments.add(FlashSegment(
        offset: part.offset,
        data: await _load(board, part),
        label: _labelFor(part.file),
        md5: part.md5,
      ));
    }

    // Calibration last: it is the smallest write, and leaving it until the
    // firmware is in place means a board is only ever calibrated once it can
    // actually read the region.
    final image = calibration ?? CalibrationImage.now(config, setup: setup);
    final blob = image.build();
    if (blob.length > board.calibration.size) {
      throw const FirmwareBundleException(
          'The calibration is too large for the region reserved on this board.');
    }
    segments.add(FlashSegment(
      offset: board.calibration.offset,
      data: blob,
      label: 'calibration',
    ));

    return FlashPlan(
      bundle: board,
      segments: segments,
      calibrationPayload: image.payload,
      setup: image.setup ?? setup,
    );
  }

  Future<Uint8List> _load(FirmwareBundle board, FlashPart part) async {
    final path = board.assetPath(part);
    final cached = _partCache[path];
    if (cached != null) return cached;
    try {
      final data = await bundle.load(path);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (bytes.length != part.size) {
        throw FirmwareBundleException(
            '${part.file} is ${bytes.length} bytes, expected ${part.size}.');
      }
      return _partCache[path] = bytes;
    } on FirmwareBundleException {
      rethrow;
    } catch (_) {
      throw FirmwareBundleException('Bundled image ${part.file} is missing.');
    }
  }

  static String _labelFor(String file) => switch (file) {
        'bootloader.bin' => 'bootloader',
        'partitions.bin' => 'partition table',
        'boot_app0.bin' => 'boot select',
        'firmware.bin' => 'app',
        _ => file,
      };
}
