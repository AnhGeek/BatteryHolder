import Foundation

/// Battery chemistry, used to estimate a percentage from measured voltage.
enum BatteryChemistry: String, Codable, CaseIterable, Identifiable {
    case lipo, liion, nimh, lead, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lipo:  return "LiPo"
        case .liion: return "Li-ion"
        case .nimh:  return "NiMH"
        case .lead:  return "Lead-acid"
        case .custom: return "Custom"
        }
    }

    /// Empty / full voltage per cell.
    var perCellRange: (min: Double, max: Double) {
        switch self {
        case .lipo:  return (3.3, 4.2)
        case .liion: return (3.0, 4.2)
        case .nimh:  return (1.0, 1.45)
        case .lead:  return (1.75, 2.10)
        case .custom: return (3.0, 4.2)
        }
    }
}

/// User-editable configuration that maps a board's ADC pin + external voltage
/// divider to a real battery voltage. This is what gets pushed to the device
/// and what the app uses to interpret raw ADC samples.
struct PinConfiguration: Codable, Equatable {
    var boardId: String
    var batteryPinId: String

    // ADC characteristics (seeded from the board, editable for calibration).
    var adcResolutionBits: Int
    var adcRefVoltage: Double

    // External resistor divider: battery+ -> R1 -> (ADC pin) -> R2 -> GND.
    var dividerR1KOhm: Double
    var dividerR2KOhm: Double

    /// Fine trim applied after the divider math (default 1.0).
    var calibrationFactor: Double

    /// Sampling cadence for Wi-Fi polling / device notify hint.
    var sampleIntervalMs: Int

    // Battery pack description for the percentage estimate.
    var chemistry: BatteryChemistry
    var cellCount: Int

    var adcMaxCount: Int { (1 << adcResolutionBits) - 1 }

    /// (R1 + R2) / R2 — how much the divider scales the real voltage down.
    var dividerRatio: Double {
        guard dividerR2KOhm > 0 else { return 1 }
        return (dividerR1KOhm + dividerR2KOhm) / dividerR2KOhm
    }

    /// Convert a raw ADC count into a battery voltage.
    func voltage(fromRawADC raw: Int) -> Double {
        let pinVoltage = Double(raw) / Double(adcMaxCount) * adcRefVoltage
        return pinVoltage * dividerRatio * calibrationFactor
    }

    /// Estimate state-of-charge (0...1) for the configured pack.
    func percentage(forVoltage voltage: Double) -> Double {
        let cells = max(1, cellCount)
        let perCell = voltage / Double(cells)
        let range = chemistry.perCellRange
        let pct = (perCell - range.min) / (range.max - range.min)
        return min(1, max(0, pct))
    }

    /// A sensible default configuration for a board + chosen pin.
    static func makeDefault(board: Board, pin: Pin) -> PinConfiguration {
        PinConfiguration(
            boardId: board.id,
            batteryPinId: pin.id,
            adcResolutionBits: board.adcResolutionBits,
            adcRefVoltage: board.adcRefVoltage,
            dividerR1KOhm: 100,
            dividerR2KOhm: 100,
            calibrationFactor: 1.0,
            sampleIntervalMs: 1000,
            chemistry: .lipo,
            cellCount: 1
        )
    }
}
