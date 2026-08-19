import 'board.dart';
import 'pin.dart';

/// Battery chemistry, used to estimate a percentage from measured voltage.
enum BatteryChemistry {
  lipo('LiPo', 3.3, 4.2),
  liion('Li-ion', 3.0, 4.2),
  nimh('NiMH', 1.0, 1.45),
  lead('Lead-acid', 1.75, 2.10),
  custom('Custom', 3.0, 4.2);

  const BatteryChemistry(this.displayName, this.perCellMin, this.perCellMax);

  final String displayName;

  /// Empty / full voltage per cell.
  final double perCellMin;
  final double perCellMax;

  String get id => name;

  static BatteryChemistry fromJson(String raw) => BatteryChemistry.values
      .firstWhere((c) => c.name == raw, orElse: () => BatteryChemistry.lipo);
}

/// User-editable configuration that maps a board's ADC pin + external voltage
/// divider to a real battery voltage. This is what gets pushed to the device
/// and what the app uses to interpret raw ADC samples.
class PinConfiguration {
  final String boardId;
  final String batteryPinId;

  // ADC characteristics (seeded from the board, editable for calibration).
  final int adcResolutionBits;
  final double adcRefVoltage;

  // External resistor divider: battery+ -> R1 -> (ADC pin) -> R2 -> GND.
  final double dividerR1KOhm;
  final double dividerR2KOhm;

  /// Fine trim applied after the divider math (default 1.0).
  final double calibrationFactor;

  /// Sampling cadence for Wi-Fi polling / device notify hint.
  final int sampleIntervalMs;

  // Battery pack description for the percentage estimate.
  final BatteryChemistry chemistry;
  final int cellCount;

  const PinConfiguration({
    required this.boardId,
    required this.batteryPinId,
    required this.adcResolutionBits,
    required this.adcRefVoltage,
    required this.dividerR1KOhm,
    required this.dividerR2KOhm,
    required this.calibrationFactor,
    required this.sampleIntervalMs,
    required this.chemistry,
    required this.cellCount,
  });

  int get adcMaxCount => (1 << adcResolutionBits) - 1;

  /// (R1 + R2) / R2 — how much the divider scales the real voltage down.
  double get dividerRatio {
    if (dividerR2KOhm <= 0) return 1;
    return (dividerR1KOhm + dividerR2KOhm) / dividerR2KOhm;
  }

  /// Convert a raw ADC count into a battery voltage.
  double voltageFromRawADC(int raw) {
    final pinVoltage = raw / adcMaxCount * adcRefVoltage;
    return pinVoltage * dividerRatio * calibrationFactor;
  }

  /// Estimate state-of-charge (0...1) for the configured pack.
  double percentageForVoltage(double voltage) {
    final cells = cellCount < 1 ? 1 : cellCount;
    final perCell = voltage / cells;
    final pct = (perCell - chemistry.perCellMin) /
        (chemistry.perCellMax - chemistry.perCellMin);
    return pct.clamp(0.0, 1.0);
  }

  /// A sensible default configuration for a board + chosen pin.
  factory PinConfiguration.makeDefault({
    required Board board,
    required Pin pin,
  }) =>
      PinConfiguration(
        boardId: board.id,
        batteryPinId: pin.id,
        adcResolutionBits: board.adcResolutionBits,
        adcRefVoltage: board.adcRefVoltage,
        dividerR1KOhm: 100,
        dividerR2KOhm: 100,
        calibrationFactor: 1.0,
        sampleIntervalMs: 1000,
        chemistry: BatteryChemistry.lipo,
        cellCount: 1,
      );

  PinConfiguration copyWith({
    String? batteryPinId,
    int? adcResolutionBits,
    double? adcRefVoltage,
    double? dividerR1KOhm,
    double? dividerR2KOhm,
    double? calibrationFactor,
    int? sampleIntervalMs,
    BatteryChemistry? chemistry,
    int? cellCount,
  }) =>
      PinConfiguration(
        boardId: boardId,
        batteryPinId: batteryPinId ?? this.batteryPinId,
        adcResolutionBits: adcResolutionBits ?? this.adcResolutionBits,
        adcRefVoltage: adcRefVoltage ?? this.adcRefVoltage,
        dividerR1KOhm: dividerR1KOhm ?? this.dividerR1KOhm,
        dividerR2KOhm: dividerR2KOhm ?? this.dividerR2KOhm,
        calibrationFactor: calibrationFactor ?? this.calibrationFactor,
        sampleIntervalMs: sampleIntervalMs ?? this.sampleIntervalMs,
        chemistry: chemistry ?? this.chemistry,
        cellCount: cellCount ?? this.cellCount,
      );

  /// Wire format shared with the firmware — keys match the Swift `Codable`
  /// synthesis so the same board build works with both apps.
  Map<String, dynamic> toJson() => {
        'boardId': boardId,
        'batteryPinId': batteryPinId,
        'adcResolutionBits': adcResolutionBits,
        'adcRefVoltage': adcRefVoltage,
        'dividerR1KOhm': dividerR1KOhm,
        'dividerR2KOhm': dividerR2KOhm,
        'calibrationFactor': calibrationFactor,
        'sampleIntervalMs': sampleIntervalMs,
        'chemistry': chemistry.name,
        'cellCount': cellCount,
      };

  @override
  bool operator ==(Object other) =>
      other is PinConfiguration &&
      other.boardId == boardId &&
      other.batteryPinId == batteryPinId &&
      other.adcResolutionBits == adcResolutionBits &&
      other.adcRefVoltage == adcRefVoltage &&
      other.dividerR1KOhm == dividerR1KOhm &&
      other.dividerR2KOhm == dividerR2KOhm &&
      other.calibrationFactor == calibrationFactor &&
      other.sampleIntervalMs == sampleIntervalMs &&
      other.chemistry == chemistry &&
      other.cellCount == cellCount;

  @override
  int get hashCode => Object.hash(
        boardId,
        batteryPinId,
        adcResolutionBits,
        adcRefVoltage,
        dividerR1KOhm,
        dividerR2KOhm,
        calibrationFactor,
        sampleIntervalMs,
        chemistry,
        cellCount,
      );
}
