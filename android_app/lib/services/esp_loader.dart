import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

import '../models/firmware_bundle.dart';

/// A byte pipe to a board: the USB port in the app, a fake in the tests.
///
/// [setControlLines] is the important one. DTR and RTS are wired to IO0 and EN
/// on every ESP dev board, and pulsing them in the right order is the only way
/// to get a chip into its ROM download mode without someone holding the BOOT
/// button down.
abstract class SerialTransport {
  Stream<Uint8List> get incoming;

  Future<void> write(Uint8List data);

  Future<void> setBaudRate(int baudRate);

  Future<void> setControlLines({required bool dtr, required bool rts});

  Future<void> close();
}

class EspLoaderException implements Exception {
  final String message;

  const EspLoaderException(this.message);

  @override
  String toString() => message;
}

/// Which part this is. Decides the framing details the ROM expects.
enum EspChip {
  esp8266('ESP8266'),
  esp32('ESP32'),
  esp32s2('ESP32-S2'),
  esp32s3('ESP32-S3'),
  esp32c3('ESP32-C3'),
  unknown('unknown chip');

  const EspChip(this.displayName);

  final String displayName;

  /// The ESP8266 ROM answers commands with 2 status bytes; every ESP32-family
  /// ROM answers with 4.
  int get statusBytes => this == EspChip.esp8266 ? 2 : 4;

  /// Only the ESP8266 ROM lacks the compressed-write commands — everywhere else
  /// they cut the transfer to a fraction of its size.
  bool get supportsCompression => this != EspChip.esp8266;

  /// SPI_ATTACH and the MD5 verify command are ESP32-family only.
  bool get isEsp32Family => this != EspChip.esp8266 && this != EspChip.unknown;

  /// Chips after the original ESP32 take an extra "encrypted" word on the
  /// FLASH_BEGIN family of commands when talking to the ROM.
  bool get flashBeginTakesEncryptionFlag =>
      this == EspChip.esp32s2 || this == EspChip.esp32s3 || this == EspChip.esp32c3;
}

/// Speaks the ESP ROM serial bootloader protocol.
///
/// This is a deliberate reimplementation from the published protocol rather
/// than a port of esptool: esptool and its flasher stubs are GPL-2.0, and this
/// app is MIT. Working without the stub costs some speed — the ROM takes 1 KB
/// blocks where the stub takes 16 KB — which is why the transfer runs
/// compressed at 460800 baud wherever the chip allows it.
///
/// Protocol reference: "Serial protocol" in the ESP-IDF documentation. Frames
/// are SLIP-delimited; a request is
/// `0x00 | cmd | len(2) | checksum(4) | payload` and the reply is
/// `0x01 | cmd | len(2) | value(4) | payload`, whose last two or four bytes are
/// the status.
class EspLoader {
  final SerialTransport port;

  /// Progress log lines, surfaced in the UI so a stalled flash is diagnosable.
  final void Function(String message)? onLog;

  EspChip chip = EspChip.unknown;

  EspLoader({required this.port, this.onLog});

  // ---- Commands ----
  static const int _cmdFlashBegin = 0x02;
  static const int _cmdFlashData = 0x03;
  static const int _cmdFlashEnd = 0x04;
  static const int _cmdSync = 0x08;
  static const int _cmdReadReg = 0x0A;
  static const int _cmdSpiSetParams = 0x0B;
  static const int _cmdSpiAttach = 0x0D;
  static const int _cmdChangeBaudrate = 0x0F;
  static const int _cmdFlashDeflBegin = 0x10;
  static const int _cmdFlashDeflData = 0x11;
  static const int _cmdFlashDeflEnd = 0x12;
  static const int _cmdSpiFlashMd5 = 0x13;

  /// The ROM loader's block size. The stub's is 16x larger; this is the price
  /// of not shipping GPL code.
  static const int blockSize = 0x400;

  /// Register holding the chip magic, readable before anything is configured.
  static const int _chipDetectReg = 0x40001000;

  static const Map<int, EspChip> _chipMagic = {
    0xfff0c101: EspChip.esp8266,
    0x00f01d83: EspChip.esp32,
    0x000007c6: EspChip.esp32s2,
    0x00000009: EspChip.esp32s3,
    0x6921506f: EspChip.esp32c3,
    0x1b31506f: EspChip.esp32c3,
    0x4881606f: EspChip.esp32c3,
    0x4361606f: EspChip.esp32c3,
  };

  static const int _slipEnd = 0xC0;
  static const int _slipEsc = 0xDB;
  static const int _slipEscEnd = 0xDC;
  static const int _slipEscEsc = 0xDD;

  final List<int> _rx = [];
  final List<Uint8List> _packets = [];
  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _packetArrived;

  bool _listening = false;

  void _log(String message) => onLog?.call(message);

  // MARK: - Session

  /// Puts the chip in download mode and syncs with its ROM loader.
  ///
  /// Two reset strategies are tried in turn: the classic DTR/RTS dance every
  /// USB-UART bridge board uses, and the sequence the ESP32-C3/S3 native USB
  /// port needs. Which one a board wants is not knowable from the USB
  /// descriptors, so the loop simply alternates.
  Future<void> connect({int attempts = 8}) async {
    _startListening();

    for (var attempt = 0; attempt < attempts; attempt++) {
      final useUsbJtag = attempt.isOdd;
      _log(attempt == 0
          ? 'Resetting the board into download mode…'
          : 'Retrying (${useUsbJtag ? 'native USB' : 'classic'} reset)…');

      await (useUsbJtag ? _usbJtagReset() : _classicReset());
      _drain();

      for (var sync = 0; sync < 5; sync++) {
        try {
          await _sync();
          await _identify();
          _log('Connected to ${chip.displayName}.');
          return;
        } on EspLoaderException {
          // The ROM misses the first few sync frames while it is still coming
          // up; that is expected, not an error worth surfacing.
        }
      }
    }
    throw const EspLoaderException(
      'The board did not answer its bootloader. Check the cable supports data, '
      'and try again holding the BOOT button while it resets.',
    );
  }

  Future<void> _classicReset() async {
    await port.setControlLines(dtr: false, rts: true); // EN low: in reset
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setControlLines(dtr: true, rts: false); // IO0 low, EN released
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await port.setControlLines(dtr: false, rts: false); // let IO0 go
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// The C3/S3 native USB port drives EN and IO0 through the same two lines,
  /// but never wants both asserted at once — hence the (1,1) waypoints.
  Future<void> _usbJtagReset() async {
    await port.setControlLines(dtr: false, rts: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setControlLines(dtr: true, rts: false); // IO0 low
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setControlLines(dtr: true, rts: true);
    await port.setControlLines(dtr: false, rts: true); // EN low
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setControlLines(dtr: false, rts: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> _sync() async {
    final payload = Uint8List(36);
    payload[0] = 0x07;
    payload[1] = 0x07;
    payload[2] = 0x12;
    payload[3] = 0x20;
    payload.fillRange(4, 36, 0x55);
    await _command(_cmdSync, payload,
        timeout: const Duration(milliseconds: 500), checkStatus: false);
    // The ROM answers a sync eight times; swallow the rest so they are not
    // mistaken for the reply to the next command.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    _drain();
  }

  Future<void> _identify() async {
    final magic = await readRegister(_chipDetectReg);
    chip = _chipMagic[magic] ?? EspChip.unknown;
    if (chip == EspChip.unknown) {
      throw EspLoaderException(
          'Unrecognised chip (magic 0x${magic.toRadixString(16)}).');
    }
  }

  /// Reads one 32-bit register — how the chip identifies itself.
  Future<int> readRegister(int address) async {
    final response = await _command(_cmdReadReg, _u32(address),
        timeout: const Duration(seconds: 2));
    return response.value;
  }

  /// Raises the transfer rate once the ROM is talking. Failure is survivable:
  /// the session simply stays at 115200.
  Future<void> raiseBaudRate(int baudRate) async {
    if (!chip.isEsp32Family) return; // the ESP8266 ROM has no such command
    try {
      final payload = Uint8List(8);
      final view = ByteData.view(payload.buffer);
      view.setUint32(0, baudRate, Endian.little);
      view.setUint32(4, 0, Endian.little); // 0 = "current rate is the ROM's"
      await _command(_cmdChangeBaudrate, payload,
          timeout: const Duration(seconds: 2));
      await port.setBaudRate(baudRate);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _drain();
      try {
        await _sync();
        _log('Link raised to $baudRate baud.');
      } on EspLoaderException {
        // The board took the command but will not talk at the new rate; put
        // the port back where the ROM still is.
        await port.setBaudRate(115200);
        _drain();
        await _sync();
        _log('Board kept the link at 115200 baud.');
      }
    } on EspLoaderException {
      _log('Board kept the link at 115200 baud.');
    }
  }

  /// Attaches the SPI flash and tells the ROM how big it is, so its erase
  /// arithmetic matches the real part.
  Future<void> prepareFlash({int flashSize = 4 * 1024 * 1024}) async {
    if (chip.isEsp32Family) {
      // ROM mode wants the argument padded to eight bytes; 0 selects the
      // default flash pins, which is what every dev board uses.
      await _command(_cmdSpiAttach, Uint8List(8),
          timeout: const Duration(seconds: 5));
    }
    final params = Uint8List(24);
    final view = ByteData.view(params.buffer);
    view.setUint32(0, 0, Endian.little); // flash id, unused
    view.setUint32(4, flashSize, Endian.little);
    view.setUint32(8, 64 * 1024, Endian.little); // block
    view.setUint32(12, 4 * 1024, Endian.little); // sector
    view.setUint32(16, 256, Endian.little); // page
    view.setUint32(20, 0xFFFF, Endian.little); // status mask
    await _command(_cmdSpiSetParams, params, timeout: const Duration(seconds: 5));
  }

  // MARK: - Writing

  /// Writes every segment, reporting 0…1 across the whole plan.
  Future<void> writeSegments(
    List<FlashSegment> segments, {
    void Function(double fraction, String label)? onProgress,
  }) async {
    final total = segments.fold<int>(0, (sum, s) => sum + s.size);
    var done = 0;

    for (final segment in segments) {
      _log('Writing ${segment.label} '
          '(${_kb(segment.size)} at 0x${segment.offset.toRadixString(16)})…');
      await _writeSegment(
        segment,
        onChunk: (bytes) {
          done += bytes;
          onProgress?.call(total == 0 ? 1 : done / total, segment.label);
        },
      );
      await verifySegment(segment);
    }
  }

  Future<void> _writeSegment(
    FlashSegment segment, {
    required void Function(int bytes) onChunk,
  }) async {
    final compressed = chip.supportsCompression;
    final payload = compressed
        ? Uint8List.fromList(ZLibCodec(level: 9).encode(segment.data))
        : _padToBlock(segment.data);

    final blocks = (payload.length + blockSize - 1) ~/ blockSize;
    await _flashBegin(
      uncompressedSize: segment.data.length,
      blocks: blocks,
      offset: segment.offset,
      compressed: compressed,
    );

    for (var index = 0; index < blocks; index++) {
      final start = index * blockSize;
      final end =
          start + blockSize > payload.length ? payload.length : start + blockSize;
      var block = payload.sublist(start, end);
      // Only uncompressed writes pad: a deflate stream must arrive byte-exact.
      if (!compressed && block.length < blockSize) {
        block = _padToBlock(block);
      }

      final header = Uint8List(16);
      final view = ByteData.view(header.buffer);
      view.setUint32(0, block.length, Endian.little);
      view.setUint32(4, index, Endian.little);
      view.setUint32(8, 0, Endian.little);
      view.setUint32(12, 0, Endian.little);

      final body = Uint8List(header.length + block.length)
        ..setRange(0, header.length, header)
        ..setRange(header.length, header.length + block.length, block);

      await _command(
        compressed ? _cmdFlashDeflData : _cmdFlashData,
        body,
        checksum: _checksum(block),
        timeout: const Duration(seconds: 10),
        retries: 2,
      );

      // Report against the real image, not the compressed stream, so the bar
      // tracks what the board ends up holding.
      onChunk((segment.data.length / blocks).round());
    }

    // 1 = stay in the loader: the plan may still have segments to write, and
    // the reset at the end is ours to time.
    await _command(compressed ? _cmdFlashDeflEnd : _cmdFlashEnd, _u32(1),
        timeout: const Duration(seconds: 10));
  }

  Future<void> _flashBegin({
    required int uncompressedSize,
    required int blocks,
    required int offset,
    required bool compressed,
  }) async {
    // The ROM erases what FLASH_BEGIN describes, so for a compressed write the
    // size field still has to cover the *uncompressed* extent, rounded up to
    // whole blocks.
    final eraseBlocks = (uncompressedSize + blockSize - 1) ~/ blockSize;
    final writeSize = compressed ? eraseBlocks * blockSize : uncompressedSize;

    final params = BytesBuilder();
    params.add(_u32(writeSize));
    params.add(_u32(blocks));
    params.add(_u32(blockSize));
    params.add(_u32(offset));
    if (chip.flashBeginTakesEncryptionFlag) {
      params.add(_u32(0)); // not encrypted
    }

    await _command(
      compressed ? _cmdFlashDeflBegin : _cmdFlashBegin,
      params.toBytes(),
      // Erasing a megabyte on a slow flash part is measured in tens of seconds.
      timeout: Duration(seconds: 30 + (uncompressedSize ~/ 100000)),
    );
  }

  /// Whether this chip can be asked what it is holding. The ESP8266 ROM has no
  /// MD5 command, so there the write acknowledgements are all there is.
  bool get canVerify => chip.isEsp32Family;

  /// Re-reads every segment's checksum straight off the board.
  ///
  /// Called after all the writing is done, as the last thing before anything
  /// reboots: a per-segment check right after its own write cannot catch a
  /// later write landing in the wrong place, and "is the image on the board
  /// actually correct" is the question worth being sure about.
  Future<bool> verifyAll(List<FlashSegment> segments) async {
    if (!canVerify) {
      _log('${chip.displayName} cannot checksum its own flash — '
          'relying on the write acknowledgements.');
      return false;
    }
    for (final segment in segments) {
      final digest = await verifySegment(segment);
      _log(digest == null
          ? '${segment.label}: board returned no checksum'
          : '${segment.label} verified · md5 ${digest.substring(0, 8)}…');
    }
    return true;
  }

  /// Compares the board's own hash of a region against the bytes we sent.
  /// Returns the digest, or null when the chip cannot answer.
  Future<String?> verifySegment(FlashSegment segment) async {
    final reported = await flashMd5(segment.offset, segment.data.length);
    if (reported == null) return null;

    final expected = md5.convert(segment.data).toString();
    if (reported != expected) {
      throw EspLoaderException(
        '${segment.label} did not verify: the board holds $reported, '
        'the image is $expected. Nothing was rebooted — try flashing again.',
      );
    }
    return reported;
  }

  /// The board's MD5 over a span of its own flash.
  Future<String?> flashMd5(int offset, int length) async {
    if (!canVerify) return null;
    final params = Uint8List(16);
    final view = ByteData.view(params.buffer);
    view.setUint32(0, offset, Endian.little);
    view.setUint32(4, length, Endian.little);

    final response = await _command(_cmdSpiFlashMd5, params,
        timeout: const Duration(seconds: 30));
    return _md5FromResponse(response);
  }

  String? _md5FromResponse(_Response response) {
    final body = response.payload;
    if (body.length >= 32) {
      final text = ascii.decode(body.sublist(0, 32), allowInvalid: true);
      if (RegExp(r'^[0-9a-f]{32}$').hasMatch(text)) return text;
    }
    if (body.length >= 16) {
      return body
          .sublist(0, 16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    return null;
  }

  /// Pulses EN so the board leaves the bootloader and runs what was written.
  ///
  /// Never called as part of writing: the board is left sitting in its ROM
  /// bootloader until everything has been written *and* checksummed, so a run
  /// that goes wrong halfway leaves a board that is still reachable rather than
  /// one that has rebooted into whatever it now holds.
  Future<void> hardReset() async {
    await port.setControlLines(dtr: false, rts: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setControlLines(dtr: false, rts: false);
    _log('Board reset — running the new firmware.');
  }

  // MARK: - Framing

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _sub = port.incoming.listen(_onBytes);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _listening = false;
  }

  void _onBytes(Uint8List bytes) {
    _rx.addAll(bytes);
    while (true) {
      final start = _rx.indexOf(_slipEnd);
      if (start < 0) {
        _rx.clear();
        return;
      }
      final end = _rx.indexOf(_slipEnd, start + 1);
      if (end < 0) {
        if (start > 0) _rx.removeRange(0, start);
        return;
      }
      final frame = _rx.sublist(start + 1, end);
      _rx.removeRange(0, end + 1);
      if (frame.isEmpty) continue; // back-to-back delimiters
      _packets.add(_slipDecode(frame));
      _packetArrived?.complete();
      _packetArrived = null;
    }
  }

  void _drain() {
    _rx.clear();
    _packets.clear();
  }

  static Uint8List _slipDecode(List<int> frame) {
    final out = <int>[];
    for (var i = 0; i < frame.length; i++) {
      if (frame[i] == _slipEsc && i + 1 < frame.length) {
        i++;
        out.add(frame[i] == _slipEscEnd
            ? _slipEnd
            : (frame[i] == _slipEscEsc ? _slipEsc : frame[i]));
      } else {
        out.add(frame[i]);
      }
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _slipEncode(Uint8List data) {
    final out = <int>[_slipEnd];
    for (final byte in data) {
      if (byte == _slipEnd) {
        out.addAll([_slipEsc, _slipEscEnd]);
      } else if (byte == _slipEsc) {
        out.addAll([_slipEsc, _slipEscEsc]);
      } else {
        out.add(byte);
      }
    }
    out.add(_slipEnd);
    return Uint8List.fromList(out);
  }

  Future<_Response> _command(
    int command,
    Uint8List payload, {
    int checksum = 0,
    Duration timeout = const Duration(seconds: 3),
    bool checkStatus = true,
    int retries = 0,
  }) async {
    _startListening();

    EspLoaderException? failure;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final frame = Uint8List(8 + payload.length);
      final view = ByteData.view(frame.buffer);
      frame[0] = 0x00; // request
      frame[1] = command;
      view.setUint16(2, payload.length, Endian.little);
      view.setUint32(4, checksum, Endian.little);
      frame.setRange(8, frame.length, payload);

      await port.write(_slipEncode(frame));

      try {
        final response = await _awaitResponse(command, timeout);
        if (checkStatus) _checkStatus(command, response);
        return response;
      } on EspLoaderException catch (e) {
        failure = e;
      }
    }
    throw failure ?? const EspLoaderException('No answer from the board.');
  }

  Future<_Response> _awaitResponse(int command, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_packets.isNotEmpty) {
        final packet = _packets.removeAt(0);
        // Frames shorter than a header, or answering some other command, are
        // leftovers from the sync burst.
        if (packet.length < 8 || packet[0] != 0x01 || packet[1] != command) {
          continue;
        }
        final view = ByteData.view(packet.buffer, packet.offsetInBytes);
        final size = view.getUint16(2, Endian.little);
        final value = view.getUint32(4, Endian.little);
        final body = packet.sublist(8, (8 + size).clamp(8, packet.length));
        return _Response(command: command, value: value, payload: body);
      }

      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw EspLoaderException(
            'The board did not answer command 0x${command.toRadixString(16)}.');
      }
      final waiter = _packetArrived ??= Completer<void>();
      await waiter.future.timeout(left, onTimeout: () {
        _packetArrived = null;
      });
    }
  }

  void _checkStatus(int command, _Response response) {
    final body = response.payload;
    final statusLength = chip.statusBytes;
    if (body.length < statusLength) return; // nothing to check against
    final status = body.sublist(body.length - statusLength);
    if (status[0] == 0) return;
    throw EspLoaderException(
        'Board refused command 0x${command.toRadixString(16)} '
        '(error 0x${status[1].toRadixString(16)}).');
  }

  // MARK: - Helpers

  static Uint8List _u32(int value) {
    final out = Uint8List(4);
    ByteData.view(out.buffer).setUint32(0, value, Endian.little);
    return out;
  }

  /// The ROM writes whole blocks; the tail is filled with the erased value so
  /// it reads back as untouched flash.
  static Uint8List _padToBlock(Uint8List data) {
    final blocks = (data.length + blockSize - 1) ~/ blockSize;
    final size = (blocks == 0 ? 1 : blocks) * blockSize;
    if (size == data.length) return data;
    return Uint8List(size)
      ..fillRange(0, size, 0xFF)
      ..setRange(0, data.length, data);
  }

  /// The data commands are checksummed with a plain XOR over the payload.
  static int _checksum(Uint8List data) {
    var checksum = 0xEF;
    for (final byte in data) {
      checksum ^= byte;
    }
    return checksum;
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';
}

class _Response {
  final int command;
  final int value;
  final Uint8List payload;

  const _Response({
    required this.command,
    required this.value,
    required this.payload,
  });
}
