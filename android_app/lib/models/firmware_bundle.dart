import 'dart:typed_data';

/// The prebuilt firmware that ships inside the app, described by
/// `assets/firmware/manifest.json`.
///
/// The phone never compiles anything: `tools/build_firmware.py` runs
/// arduino-cli on a workstation, drops the resulting `.bin` files into
/// `assets/firmware/<boardId>/`, and records here where each one belongs in the
/// board's flash. Everything the USB flasher needs — offsets, flash geometry,
/// the calibration region, which sectors to blank — comes from this file rather
/// than being hard-coded, so a change to the partition table travels with the
/// binaries that assume it.
class FirmwareManifest {
  final int schema;

  /// `FW_VERSION` from the sketch these binaries were built from.
  final String firmwareVersion;
  final DateTime? builtAt;
  final Map<String, FirmwareBundle> bundles;

  const FirmwareManifest({
    required this.schema,
    required this.firmwareVersion,
    required this.bundles,
    this.builtAt,
  });

  static const empty = FirmwareManifest(
    schema: 0,
    firmwareVersion: '0.0.0',
    bundles: {},
  );

  FirmwareBundle? bundleFor(String boardId) => bundles[boardId];

  factory FirmwareManifest.fromJson(Map<String, dynamic> json) {
    final raw = (json['bundles'] as Map?) ?? const {};
    return FirmwareManifest(
      schema: (json['schema'] as num?)?.toInt() ?? 0,
      firmwareVersion: json['firmwareVersion'] as String? ?? '0.0.0',
      builtAt: DateTime.tryParse(json['builtAt'] as String? ?? ''),
      bundles: {
        for (final entry in raw.entries)
          entry.key as String:
              FirmwareBundle.fromJson(entry.value as Map<String, dynamic>),
      },
    );
  }
}

/// One board's worth of flashable images.
class FirmwareBundle {
  final String boardId;
  final String name;
  final String chip;

  /// Sketch folder under `firmware/` and the FQBN it was built with — printed
  /// in the UI so a board can be traced back to a reproducible build.
  final String sketch;
  final String fqbn;

  final String flashMode;
  final String flashFreq;
  final String flashSize;

  final List<FlashPart> parts;

  /// Where the calibration blob goes: the `calib` partition on ESP32, the
  /// sector below the EEPROM on ESP8266.
  final FlashRegion calibration;

  /// Sectors that hold saved settings. Blanking them is what makes a reflashed
  /// board behave like one out of the box, instead of inheriting the run mode
  /// and wake interval of whatever was on it before.
  final List<FlashRegion> eraseRegions;

  const FirmwareBundle({
    required this.boardId,
    required this.name,
    required this.chip,
    required this.sketch,
    required this.fqbn,
    required this.flashMode,
    required this.flashFreq,
    required this.flashSize,
    required this.parts,
    required this.calibration,
    this.eraseRegions = const [],
  });

  /// Bytes of firmware, ignoring the calibration blob.
  int get imageBytes => parts.fold(0, (sum, p) => sum + p.size);

  /// Asset path of one part.
  String assetPath(FlashPart part) => 'assets/firmware/$boardId/${part.file}';

  factory FirmwareBundle.fromJson(Map<String, dynamic> json) => FirmwareBundle(
        boardId: json['boardId'] as String,
        name: json['name'] as String? ?? json['boardId'] as String,
        chip: json['chip'] as String? ?? 'esp32',
        sketch: json['sketch'] as String? ?? '',
        fqbn: json['fqbn'] as String? ?? '',
        flashMode: json['flashMode'] as String? ?? 'dio',
        flashFreq: json['flashFreq'] as String? ?? '40m',
        flashSize: json['flashSize'] as String? ?? '4MB',
        parts: ((json['parts'] as List?) ?? const [])
            .map((e) => FlashPart.fromJson(e as Map<String, dynamic>))
            .toList(),
        calibration:
            FlashRegion.fromJson((json['calibration'] as Map<String, dynamic>?) ??
                const {'offset': 0, 'size': 4096}),
        eraseRegions: ((json['eraseRegions'] as List?) ?? const [])
            .map((e) => FlashRegion.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One `.bin` and the flash offset it is written to.
class FlashPart {
  final String file;
  final int offset;
  final int size;
  final String md5;

  const FlashPart({
    required this.file,
    required this.offset,
    required this.size,
    required this.md5,
  });

  factory FlashPart.fromJson(Map<String, dynamic> json) => FlashPart(
        file: json['file'] as String,
        offset: (json['offset'] as num).toInt(),
        size: (json['size'] as num).toInt(),
        md5: json['md5'] as String? ?? '',
      );
}

/// A named span of flash.
class FlashRegion {
  final int offset;
  final int size;
  final String label;

  const FlashRegion({required this.offset, required this.size, this.label = ''});

  factory FlashRegion.fromJson(Map<String, dynamic> json) => FlashRegion(
        offset: (json['offset'] as num).toInt(),
        size: (json['size'] as num).toInt(),
        label: json['label'] as String? ?? '',
      );
}

/// A block of bytes ready to be written at [offset].
///
/// The unit the flasher works in: firmware parts, the calibration blob and the
/// blanked settings sectors all become segments, so the write loop has exactly
/// one kind of thing to deal with.
class FlashSegment {
  final int offset;
  final Uint8List data;

  /// Shown in the progress log — "app", "calibration", "saved settings".
  final String label;

  /// MD5 the build recorded, when there is one to check against.
  final String? md5;

  /// This span is erased rather than filled with content of its own.
  ///
  /// Blanked settings only read back as 0xFF until the board runs and starts
  /// saving again, so they are checked immediately after writing but skipped
  /// when auditing a board that has been up since.
  final bool blank;

  const FlashSegment({
    required this.offset,
    required this.data,
    required this.label,
    this.md5,
    this.blank = false,
  });

  int get size => data.length;
}

/// Everything that will be written in one USB session.
class FlashPlan {
  final FirmwareBundle bundle;
  final List<FlashSegment> segments;

  /// The calibration this plan carries, for display and for the follow-up
  /// hand-off over the serial console.
  final Map<String, dynamic> calibrationPayload;

  const FlashPlan({
    required this.bundle,
    required this.segments,
    required this.calibrationPayload,
  });

  int get totalBytes => segments.fold(0, (sum, s) => sum + s.size);
}
