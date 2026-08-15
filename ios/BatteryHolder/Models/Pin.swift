import Foundation

/// A capability a physical pin can perform.
enum PinCapability: String, Codable, CaseIterable {
    case adc, digitalIn, digitalOut, touch, dac, pwm, i2c, spi, uart, strapping
}

/// A single physical pin on a board, with the metadata the app needs to let the
/// user pick an ADC pin intuitively and safely.
struct Pin: Identifiable, Codable, Equatable, Hashable {
    /// Stable identifier, e.g. "gpio34" or "a0".
    var id: String
    /// Human label, e.g. "GPIO34" or "A0 (ADC0)".
    var name: String
    /// GPIO number when applicable (nil for analog-only pins like ESP8266 A0).
    var gpio: Int?
    /// ADC channel label, e.g. "ADC1_CH6".
    var adcChannel: String?
    /// ADC unit (1 or 2 on ESP32). ADC2 conflicts with Wi-Fi.
    var adcUnit: Int?
    /// True if the pin can only be an input (e.g. GPIO34-39 on ESP32).
    var inputOnly: Bool
    /// True if this pin's ADC works while Wi-Fi is active. ESP32 ADC2 pins are false.
    var wifiSafeADC: Bool
    /// Everything this pin can do.
    var capabilities: [PinCapability]
    /// Optional caveat surfaced in the UI (strapping pin, ADC2 note, ...).
    var note: String?

    var supportsADC: Bool { capabilities.contains(.adc) }
}
