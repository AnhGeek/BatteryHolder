import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:battery_holder/models/firmware_bundle.dart';
import 'package:battery_holder/services/esp_loader.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the chip's ROM bootloader.
///
/// It speaks the same SLIP framing and command set as the real thing and keeps
/// a model of its flash, so a test can assert on what the board *ends up
/// holding* rather than on which bytes the app happened to send. Without
/// hardware in the loop that is the strongest statement available about the
/// flashing path.
class FakeEspRom implements SerialTransport {
  FakeEspRom({
    this.chipMagic = 0x00f01d83,
    this.statusBytes = 4,
    this.corruptWrites = false,
  });

  final int chipMagic;
  final int statusBytes;

  /// Stores something other than what was sent — a bad cable, a marginal
  /// flash part, a write that silently landed short.
  final bool corruptWrites;

  final _incoming = StreamController<Uint8List>.broadcast();
  final List<int> _rx = [];

  /// Sparse model of flash: offset -> byte.
  final Map<int, int> flash = {};

  /// Every control-line transition, so the reset dance can be asserted on.
  final List<({bool dtr, bool rts})> controlLines = [];

  int baudRate = 115200;
  bool inDownloadMode = false;
  int syncCount = 0;

  int? _writeOffset;
  bool _writeCompressed = false;
  final List<int> _writeBuffer = [];

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> setBaudRate(int rate) async => baudRate = rate;

  @override
  Future<void> setControlLines({required bool dtr, required bool rts}) async {
    controlLines.add((dtr: dtr, rts: rts));
    // The board enters download mode when IO0 is held low as EN is released,
    // which is what the classic reset sequence produces.
    if (dtr && !rts) inDownloadMode = true;
  }

  @override
  Future<void> close() async {
    await _incoming.close();
  }

  @override
  Future<void> write(Uint8List data) async {
    _rx.addAll(data);
    while (true) {
      final start = _rx.indexOf(0xC0);
      if (start < 0) return;
      final end = _rx.indexOf(0xC0, start + 1);
      if (end < 0) return;
      final frame = _unslip(_rx.sublist(start + 1, end));
      _rx.removeRange(0, end + 1);
      if (frame.length >= 8) _handle(frame);
    }
  }

  void _handle(List<int> frame) {
    final view = ByteData.view(Uint8List.fromList(frame).buffer);
    final command = frame[1];
    final size = view.getUint16(2, Endian.little);
    final payload = frame.sublist(8, 8 + size);
    final body = ByteData.view(Uint8List.fromList(payload).buffer);

    var value = 0;
    switch (command) {
      case 0x08: // SYNC
        if (!inDownloadMode) return; // a running sketch answers nothing
        syncCount++;
      case 0x0A: // READ_REG
        value = chipMagic;
      case 0x02: // FLASH_BEGIN
      case 0x10: // FLASH_DEFL_BEGIN
        _writeCompressed = command == 0x10;
        _writeOffset = body.getUint32(12, Endian.little);
        _writeBuffer.clear();
        // The ROM erases the region it was told about.
        final eraseSize = body.getUint32(0, Endian.little);
        for (var i = 0; i < eraseSize; i++) {
          flash[_writeOffset! + i] = 0xFF;
        }
      case 0x03: // FLASH_DATA
      case 0x11: // FLASH_DEFL_DATA
        _writeBuffer.addAll(payload.sublist(16));
      case 0x04: // FLASH_END
      case 0x12: // FLASH_DEFL_END
        final bytes = _writeCompressed
            ? ZLibCodec().decode(_writeBuffer)
            : _writeBuffer;
        for (var i = 0; i < bytes.length; i++) {
          flash[_writeOffset! + i] = bytes[i];
        }
        if (corruptWrites && bytes.isNotEmpty) {
          flash[_writeOffset!] = (flash[_writeOffset!]! ^ 0xFF) & 0xFF;
        }
        _writeBuffer.clear();
      case 0x13: // SPI_FLASH_MD5
        final offset = body.getUint32(0, Endian.little);
        final length = body.getUint32(4, Endian.little);
        final region = [
          for (var i = 0; i < length; i++) flash[offset + i] ?? 0xFF,
        ];
        _reply(command, 0, extra: ascii.encode(md5.convert(region).toString()));
        return;
    }
    _reply(command, value);
  }

  void _reply(int command, int value, {List<int> extra = const []}) {
    final head = Uint8List(8);
    final view = ByteData.view(head.buffer);
    head[0] = 0x01;
    head[1] = command;
    view.setUint16(2, extra.length + statusBytes, Endian.little);
    view.setUint32(4, value, Endian.little);

    final frame = <int>[...head, ...extra, ...List.filled(statusBytes, 0)];
    _incoming.add(_slip(frame));
  }

  static Uint8List _slip(List<int> data) {
    final out = <int>[0xC0];
    for (final byte in data) {
      if (byte == 0xC0) {
        out.addAll([0xDB, 0xDC]);
      } else if (byte == 0xDB) {
        out.addAll([0xDB, 0xDD]);
      } else {
        out.add(byte);
      }
    }
    return Uint8List.fromList(out..add(0xC0));
  }

  static List<int> _unslip(List<int> frame) {
    final out = <int>[];
    for (var i = 0; i < frame.length; i++) {
      if (frame[i] == 0xDB && i + 1 < frame.length) {
        i++;
        out.add(frame[i] == 0xDC ? 0xC0 : 0xDB);
      } else {
        out.add(frame[i]);
      }
    }
    return out;
  }

  /// What the board is holding at [offset], for assertions.
  List<int> read(int offset, int length) =>
      [for (var i = 0; i < length; i++) flash[offset + i] ?? 0xFF];
}

void main() {
  group('EspLoader', () {
    test('resets the board into download mode and identifies the chip',
        () async {
      final rom = FakeEspRom();
      final loader = EspLoader(port: rom);

      await loader.connect();

      expect(loader.chip, EspChip.esp32);
      expect(rom.syncCount, greaterThan(0));
      // EN pulled low first, then IO0 held while EN is released: that ordering
      // is the whole trick, so it is worth pinning down.
      expect(rom.controlLines.first, (dtr: false, rts: true));
      expect(rom.controlLines[1], (dtr: true, rts: false));
      await loader.dispose();
    });

    test('a board that never enters download mode fails with advice', () async {
      final rom = FakeEspRom();
      // Simulate a board whose auto-reset circuit is not wired: the control
      // lines move but the ROM never listens.
      rom.inDownloadMode = false;
      final loader = EspLoader(port: NonRespondingRom(rom));

      await expectLater(
        loader.connect(attempts: 1),
        throwsA(isA<EspLoaderException>().having(
            (e) => e.message, 'message', contains('BOOT button'))),
      );
      await loader.dispose();
    });

    test('writes every segment to the right offset', () async {
      final rom = FakeEspRom();
      final loader = EspLoader(port: rom);
      await loader.connect();
      await loader.prepareFlash();

      final app = Uint8List.fromList(
          List.generate(3000, (i) => (i * 7 + 3) & 0xFF));
      final calibration = Uint8List.fromList(utf8.encode('{"pin":"gpio34"}'));

      await loader.writeSegments([
        FlashSegment(offset: 0x10000, data: app, label: 'app'),
        FlashSegment(
            offset: 0x3D0000, data: calibration, label: 'calibration'),
      ]);

      expect(rom.read(0x10000, app.length), app);
      expect(rom.read(0x3D0000, calibration.length), calibration);
      await loader.dispose();
    });

    test('blanking a region leaves it erased', () async {
      final rom = FakeEspRom();
      rom.flash[0x9000] = 0x42; // a leftover from the board's previous life
      final loader = EspLoader(port: rom);
      await loader.connect();

      final blank = Uint8List(0x7000)..fillRange(0, 0x7000, 0xFF);
      await loader.writeSegments(
          [FlashSegment(offset: 0x9000, data: blank, label: 'saved settings')]);

      expect(rom.read(0x9000, 16), List.filled(16, 0xFF));
      await loader.dispose();
    });

    test('a board that stored the wrong bytes fails verification', () async {
      final rom = FakeEspRom(corruptWrites: true);
      final loader = EspLoader(port: rom);
      await loader.connect();

      final data = Uint8List.fromList(List.filled(2048, 0xAB));
      await expectLater(
        loader.writeSegments(
            [FlashSegment(offset: 0x10000, data: data, label: 'app')]),
        throwsA(isA<EspLoaderException>()
            .having((e) => e.message, 'message', contains('did not verify'))),
      );
      await loader.dispose();
    });

    test('verification covers the calibration blob, not just the manifest',
        () async {
      // The calibration is generated on the phone, so it has no checksum in the
      // manifest to compare against — it is checked against the bytes sent.
      final rom = FakeEspRom(corruptWrites: true);
      final loader = EspLoader(port: rom);
      await loader.connect();

      final calibration = Uint8List.fromList(utf8.encode('{"pin":"gpio34"}'));
      await expectLater(
        loader.verifyAll([
          FlashSegment(
              offset: 0x3D0000, data: calibration, label: 'calibration'),
        ]),
        throwsA(isA<EspLoaderException>()),
      );
      await loader.dispose();
    });

    test('writing and verifying never reset the board', () async {
      // The whole point of holding the board in the bootloader: a run that goes
      // wrong must leave it reachable, not running whatever it now holds.
      final rom = FakeEspRom();
      final loader = EspLoader(port: rom);
      await loader.connect();
      final afterConnect = rom.controlLines.length;

      final segments = [
        FlashSegment(
            offset: 0x10000,
            data: Uint8List.fromList(List.generate(4096, (i) => i & 0xFF)),
            label: 'app'),
        FlashSegment(
            offset: 0x3D0000,
            data: Uint8List.fromList(utf8.encode('{"pin":"gpio34"}')),
            label: 'calibration'),
      ];
      await loader.writeSegments(segments);
      final verified = await loader.verifyAll(segments);

      expect(verified, isTrue);
      expect(rom.controlLines.length, afterConnect,
          reason: 'nothing may touch EN or IO0 between writing and verifying');

      // Only the explicit call reboots it.
      await loader.hardReset();
      expect(rom.controlLines.length, greaterThan(afterConnect));
      expect(rom.controlLines.last, (dtr: false, rts: false));
      await loader.dispose();
    });

    test('an ESP8266 is written uncompressed and left unverified', () async {
      // The ESP8266 ROM has neither the deflate commands nor the MD5 one.
      final rom = FakeEspRom(chipMagic: 0xfff0c101, statusBytes: 2);
      final loader = EspLoader(port: rom);
      await loader.connect();

      expect(loader.chip, EspChip.esp8266);
      expect(loader.chip.supportsCompression, isFalse);

      final image = Uint8List.fromList(List.generate(2048, (i) => i & 0xFF));
      await loader.writeSegments(
          [FlashSegment(offset: 0, data: image, label: 'app')]);

      expect(rom.read(0, image.length), image);
      await loader.dispose();
    });

    test('raising the baud rate moves the port with it', () async {
      final rom = FakeEspRom();
      final loader = EspLoader(port: rom);
      await loader.connect();

      await loader.raiseBaudRate(460800);

      expect(rom.baudRate, 460800);
      await loader.dispose();
    });
  });
}

/// A board whose ROM never answers — the auto-reset circuit is missing, or the
/// cable is charge-only.
class NonRespondingRom implements SerialTransport {
  NonRespondingRom(this.inner);

  final FakeEspRom inner;

  @override
  Stream<Uint8List> get incoming => inner.incoming;

  @override
  Future<void> write(Uint8List data) async {}

  @override
  Future<void> setBaudRate(int baudRate) async {}

  @override
  Future<void> setControlLines({required bool dtr, required bool rts}) async {}

  @override
  Future<void> close() async {}
}
