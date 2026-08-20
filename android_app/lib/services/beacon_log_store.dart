import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/beacon_log.dart';

/// Reads (and, in the foreground, appends to) the beacon log.
///
/// The file is JSON-lines in the app's private files directory, shared with the
/// native `BeaconScanService`, which is the writer while the app is closed. One
/// object per line means both sides can append without rewriting the file and a
/// half-written trailing line only ever costs the newest row.
class BeaconLogStore extends ChangeNotifier {
  /// Must match `BeaconScanService.LOG_FILE_NAME` on the Android side.
  static const fileName = 'beacons.jsonl';

  /// Keep the file bounded — at one row per wake this is months of history.
  static const maxEntries = 4000;

  List<BeaconLogEntry> _entries = [];
  bool _loaded = false;

  List<BeaconLogEntry> get entries => List.unmodifiable(_entries);
  bool get isLoaded => _loaded;

  List<KnownDevice> get devices => KnownDevice.rollUp(_entries);

  File? _file;

  Future<File> _logFile() async {
    final cached = _file;
    if (cached != null) return cached;
    // getApplicationSupportDirectory maps to the same files dir the native
    // service writes to (context.getFilesDir()).
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/$fileName');
  }

  /// Re-read the log from disk. Cheap enough to call whenever a screen opens —
  /// the file is capped at [maxEntries] lines.
  Future<void> reload() async {
    try {
      final file = await _logFile();
      if (!await file.exists()) {
        _entries = [];
        _loaded = true;
        notifyListeners();
        return;
      }
      final lines = await file.readAsLines();
      final parsed = <BeaconLogEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            parsed.add(BeaconLogEntry.fromJson(decoded));
          }
        } catch (_) {
          // A torn last line (service killed mid-write) is skipped, not fatal.
        }
      }
      _entries = parsed;
      _loaded = true;
      notifyListeners();
    } catch (_) {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Entries for one board, newest first.
  List<BeaconLogEntry> entriesFor(String deviceId) {
    final rows = _entries.where((e) => e.deviceId == deviceId).toList();
    rows.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return rows;
  }

  /// Append one observation. The native service does this while the app is
  /// closed; this path covers rows seen by the in-app scanner.
  Future<void> append(BeaconLogEntry entry) async {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
    try {
      final file = await _logFile();
      await file.writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: false);
    } catch (_) {
      // Losing a log row must never break scanning.
    }
  }

  /// Forget everything logged for one board.
  ///
  /// The file is rewritten from what is left rather than edited in place: rows
  /// are append-only JSON lines with no index, so there is nothing to delete
  /// from. The native service may append while this runs, in which case the
  /// newest row or two are lost — an acceptable trade for a delete that cannot
  /// corrupt the file.
  Future<void> clearDevice(String deviceId) async {
    _entries = [for (final e in _entries) if (e.deviceId != deviceId) e];
    notifyListeners();
    try {
      final file = await _logFile();
      if (_entries.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      final buffer = StringBuffer();
      for (final entry in _entries) {
        buffer.writeln(jsonEncode(entry.toJson()));
      }
      await file.writeAsString(buffer.toString(), flush: true);
    } catch (_) {
      // The in-memory list is already the truth the UI reads; a failed rewrite
      // just means the rows come back on the next reload.
    }
  }

  Future<void> clear() async {
    _entries = [];
    notifyListeners();
    try {
      final file = await _logFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing to do — the in-memory list is already empty.
    }
  }
}
