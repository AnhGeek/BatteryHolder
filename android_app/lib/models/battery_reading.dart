/// A raw sample as delivered by a transport (BLE notify or Wi-Fi poll),
/// before the app applies the pin configuration.
class DeviceSample {
  final int rawADC;

  /// Voltage the device itself computed, if it reports one.
  final double? deviceVolts;
  final String? pinId;
  final DateTime timestamp;

  DeviceSample({
    required this.rawADC,
    this.deviceVolts,
    this.pinId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// A fully-interpreted reading the UI displays and charts.
class BatteryReading {
  final DateTime timestamp;
  final int rawADC;
  final double voltage;

  /// State of charge 0...1.
  final double? percentage;
  final String pinId;

  const BatteryReading({
    required this.timestamp,
    required this.rawADC,
    required this.voltage,
    required this.percentage,
    required this.pinId,
  });
}
