import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'esp_loader.dart';

/// The USB twin of the BLE session, from DEVICE_PROTOCOL.md §7.
///
/// After the firmware is flashed the board reboots into the sketch, and the
/// same cable becomes a command channel: one JSON object per line at 115200
/// baud, carrying the same operations the GATT service exposes. That is how a
/// board with no radio link yet gets its calibration confirmed — and how the
/// app reads back what the board actually stored.
///
/// Lines the board addresses to the app carry `"bh":1`; the human-readable boot
/// log does not, so both can share the port.
class SerialConsole {
  final SerialTransport port;

  /// Raw lines, including the board's own log output, for the on-screen trace.
  final void Function(String line)? onLine;

  SerialConsole({required this.port, this.onLine});

  final StreamController<Map<String, dynamic>> _messages =
      StreamController.broadcast();
  StreamSubscription<Uint8List>? _sub;
  String _buffer = '';

  /// Every `"bh":1` object the board sends, replies and events alike.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  void start() {
    _sub ??= port.incoming.listen(_onBytes);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _messages.close();
  }

  void _onBytes(Uint8List bytes) {
    _buffer += utf8.decode(bytes, allowMalformed: true);
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline < 0) {
        // A board that resets mid-line would otherwise grow this forever.
        if (_buffer.length > 8192) _buffer = '';
        return;
      }
      final line = _buffer.substring(0, newline).trim();
      _buffer = _buffer.substring(newline + 1);
      if (line.isEmpty) continue;
      onLine?.call(line);
      if (!line.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic> && decoded['bh'] == 1) {
          _messages.add(decoded);
        }
      } catch (_) {
        // Half a line from before we started listening.
      }
    }
  }

  Future<void> send(Map<String, dynamic> command) async {
    start();
    await port.write(Uint8List.fromList(utf8.encode('${jsonEncode(command)}\n')));
  }

  /// Sends a command and waits for the board's answer to *that* command.
  ///
  /// Replies are matched on `re`, so an event pushed in the middle of a
  /// round trip (the board's status stream is chatty) never gets mistaken for
  /// the reply.
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 5),
    int retries = 1,
  }) async {
    start();
    final expected = command['cmd'] as String;

    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      // Listen before sending, and cancel on the way out: a reply that arrives
      // after we have given up must not land on an abandoned future.
      final answer = Completer<Map<String, dynamic>>();
      final sub = messages.listen((message) {
        if (message['re'] == expected && !answer.isCompleted) {
          answer.complete(message);
        }
      });
      try {
        await send(command);
        return await answer.future.timeout(timeout);
      } on TimeoutException catch (e) {
        lastError = e;
      } finally {
        await sub.cancel();
      }
    }
    throw SerialConsoleException(
        'The board did not answer "$expected" over USB.', lastError);
  }

  /// Waits for the board to come up after a reset and identify itself.
  Future<Map<String, dynamic>> waitForBoot({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    start();
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await request({'cmd': 'hello'},
            timeout: const Duration(seconds: 2), retries: 0);
      } on SerialConsoleException catch (e) {
        lastError = e;
      }
    }
    throw SerialConsoleException(
        'The board did not answer over USB after rebooting.', lastError);
  }
}

class SerialConsoleException implements Exception {
  final String message;
  final Object? cause;

  const SerialConsoleException(this.message, [this.cause]);

  @override
  String toString() => message;
}
