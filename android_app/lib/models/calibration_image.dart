import 'dart:convert';
import 'dart:typed_data';

import 'board_setup.dart';
import 'pin_configuration.dart';

/// The calibration image the phone writes into the board's flash.
///
/// A board fresh out of its bag has never met the phone: no Bluetooth pairing,
/// no Wi-Fi, an empty NVS. Its ADC pin and divider therefore cannot arrive over
/// the air — they are written straight into a flash region that sits *outside*
/// the program image while the firmware itself is being flashed over USB. The
/// sketch reads that region on its very first boot (see `applyCalibRegion()` in
/// both sketches) and folds it into its saved settings.
///
/// Layout, little-endian throughout, matching the firmware byte for byte:
///
/// ```text
///   offset  size  field
///        0     4  magic "BHCB"
///        4     2  format version (1)
///        6     2  flags (reserved, 0)
///        8     4  payload length
///       12     4  CRC-32 (IEEE) of the payload
///       16     N  UTF-8 JSON: a PinConfiguration plus "stamp"
/// ```
///
/// The JSON carries the [BoardSetup] as well — a `power` block with the run
/// mode folded into it, and Wi-Fi credentials when the board is meant to join
/// a network. That is what makes the image self-sufficient: the board wakes up
/// already claimed, in the mode it was built for, instead of coming off the
/// cable unprovisioned and waiting to be asked over Bluetooth.
///
/// The `stamp` is what keeps the region from fighting the board: the firmware
/// mirrors the stamp it applied into NVS, so a board reconfigured later over
/// Bluetooth keeps the newer settings instead of being pulled back here on
/// every boot.
class CalibrationImage {
  /// "BHCB" read as a little-endian word.
  static const int magic = 0x42434842;
  static const int formatVersion = 1;
  static const int headerSize = 16;

  final PinConfiguration config;

  /// Run mode, timers and credentials. Omitted only by callers that genuinely
  /// have nothing to say about behaviour, which leaves the board on its
  /// compiled-in defaults — i.e. unclaimed.
  final BoardSetup? setup;

  /// Seconds since the epoch, the moment the image was generated.
  final int stamp;

  const CalibrationImage({
    required this.config,
    required this.stamp,
    this.setup,
  });

  factory CalibrationImage.now(PinConfiguration config, {BoardSetup? setup}) =>
      CalibrationImage(
        config: config,
        setup: setup,
        stamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

  /// The JSON the firmware parses — the same wire format the BLE pin-config
  /// characteristic takes, plus the stamp.
  Map<String, dynamic> get payload => {
        ...config.toJson(),
        ...?setup?.toCalibrationJson(),
        'stamp': stamp,
      };

  /// Header + payload, ready to be written at the region's offset.
  ///
  /// Nothing is padded to the region size: the flasher erases whole sectors
  /// before writing, so the tail is already 0xFF — which is also how the
  /// firmware tells an unwritten region from a written one.
  Uint8List build() {
    final body = utf8.encode(jsonEncode(payload));
    final out = Uint8List(headerSize + body.length);
    final view = ByteData.view(out.buffer);

    view.setUint32(0, magic, Endian.little);
    view.setUint16(4, formatVersion, Endian.little);
    view.setUint16(6, 0, Endian.little); // flags
    view.setUint32(8, body.length, Endian.little);
    view.setUint32(12, crc32(body), Endian.little);
    out.setRange(headerSize, out.length, body);
    return out;
  }

  /// How much of the region this image occupies.
  int get byteLength => headerSize + utf8.encode(jsonEncode(payload)).length;

  /// CRC-32 (IEEE 802.3), the same polynomial `crc32Buf()` uses in the sketches.
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte & 0xFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return (~crc) & 0xFFFFFFFF;
  }

  /// Reads an image back — used to verify what a board reports it is holding.
  static CalibrationImageContents? parse(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (view.getUint32(0, Endian.little) != magic) return null;
    if (view.getUint16(4, Endian.little) != formatVersion) return null;

    final length = view.getUint32(8, Endian.little);
    final crc = view.getUint32(12, Endian.little);
    if (length == 0 || headerSize + length > bytes.length) return null;

    final body = bytes.sublist(headerSize, headerSize + length);
    if (crc32(body) != crc) return null;

    try {
      return CalibrationImageContents(
          jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// A decoded calibration payload.
class CalibrationImageContents {
  final Map<String, dynamic> json;

  const CalibrationImageContents(this.json);

  int get stamp => (json['stamp'] as num?)?.toInt() ?? 0;
  String? get batteryPinId => json['batteryPinId'] as String?;
}
