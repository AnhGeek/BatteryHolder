import Foundation

/// Supported chip families.
enum Chip: String, Codable {
    case esp32, esp32c3, esp32s3, esp8266

    var displayName: String {
        switch self {
        case .esp32:   return "ESP32"
        case .esp32c3: return "ESP32-C3"
        case .esp32s3: return "ESP32-S3"
        case .esp8266: return "ESP8266"
        }
    }
}

/// How the app can talk to / flash a board.
enum FlashTransport: String, Codable, CaseIterable, Identifiable {
    case ble, wifi
    var id: String { rawValue }
    var displayName: String { self == .ble ? "Bluetooth" : "Wi-Fi" }
    var systemImage: String { self == .ble ? "dot.radiowaves.left.and.right" : "wifi" }
}

/// A board definition loaded from `boards.json`.
struct Board: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var chip: Chip
    var summary: String
    /// ADC resolution in bits (12 on ESP32, 10 on ESP8266).
    var adcResolutionBits: Int
    /// Full-scale reference voltage at the ADC pin.
    var adcRefVoltage: Double
    /// Preferred default battery pin id.
    var recommendedBatteryPinId: String?
    var supportedTransports: [FlashTransport]
    var pins: [Pin]

    /// Maximum raw ADC count (e.g. 4095 for 12-bit).
    var adcMaxCount: Int { (1 << adcResolutionBits) - 1 }

    /// Pins the user may pick for battery sensing.
    var adcCapablePins: [Pin] { pins.filter { $0.supportsADC } }

    var recommendedBatteryPin: Pin? {
        guard let id = recommendedBatteryPinId else { return nil }
        return pins.first { $0.id == id }
    }

    func pin(withId id: String) -> Pin? { pins.first { $0.id == id } }
}
