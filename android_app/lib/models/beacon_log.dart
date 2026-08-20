/// One observed BLE advertisement from a BatteryHolder board.
///
/// Written by the background scan service (see `BeaconScanService.kt`) as one
/// JSON object per line, so both the service and the UI can append/read without
/// rewriting the whole file. Field names are short because every wake writes a
/// row and the file lives on the phone forever.
class BeaconLogEntry {
  final DateTime timestamp;

  /// BLE address of the board, and the key everything groups by.
  final String deviceId;

  /// Advertised local name, e.g. `BH-d08c`.
  final String name;
  final int rssi;

  /// Battery volts decoded from manufacturer data, when present.
  final double? volts;

  /// State of charge 0–100, when present.
  final int? soc;

  /// Raw flags byte — `0x01` provisioned, `0x02` wifi mode, `0x04` pairing,
  /// `0x08` wifi online (DEVICE_PROTOCOL.md §2.1).
  final int flags;

  const BeaconLogEntry({
    required this.timestamp,
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.volts,
    this.soc,
    this.flags = 0,
  });

  bool get provisioned => (flags & 0x01) != 0;
  bool get wifiMode => (flags & 0x02) != 0;
  bool get pairingMode => (flags & 0x04) != 0;
  bool get wifiOnline => (flags & 0x08) != 0;

  factory BeaconLogEntry.fromJson(Map<String, dynamic> json) => BeaconLogEntry(
        timestamp:
            DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
        deviceId: json['id'] as String,
        name: json['n'] as String? ?? '',
        rssi: (json['r'] as num?)?.toInt() ?? 0,
        volts: (json['v'] as num?)?.toDouble(),
        soc: (json['s'] as num?)?.toInt(),
        flags: (json['f'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'id': deviceId,
        'n': name,
        'r': rssi,
        'v': ?volts,
        's': ?soc,
        'f': flags,
      };
}

/// A board the app has seen at least once, rolled up from its log entries.
///
/// This is what the Monitor tab lists: boards persist across app restarts even
/// though they are only reachable during their short wake windows.
class KnownDevice {
  final String deviceId;
  final String name;

  /// Most recent observation.
  final BeaconLogEntry latest;

  /// How many advertisements have been logged for this board.
  final int entryCount;

  const KnownDevice({
    required this.deviceId,
    required this.name,
    required this.latest,
    required this.entryCount,
  });

  DateTime get lastSeen => latest.timestamp;
  double? get volts => latest.volts;
  int? get soc => latest.soc;

  /// Rolls a device-ordered list of entries into one row per board, newest
  /// first. [entries] may be in any order.
  static List<KnownDevice> rollUp(List<BeaconLogEntry> entries) {
    final latest = <String, BeaconLogEntry>{};
    final counts = <String, int>{};

    for (final e in entries) {
      counts[e.deviceId] = (counts[e.deviceId] ?? 0) + 1;
      final current = latest[e.deviceId];
      if (current == null || e.timestamp.isAfter(current.timestamp)) {
        latest[e.deviceId] = e;
      }
    }

    final devices = [
      for (final entry in latest.entries)
        KnownDevice(
          deviceId: entry.key,
          // A board that once advertised anonymously may have a name later.
          name: entry.value.name.isEmpty ? entry.key : entry.value.name,
          latest: entry.value,
          entryCount: counts[entry.key] ?? 0,
        ),
    ];
    devices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return devices;
  }
}
