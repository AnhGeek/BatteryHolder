import Foundation

/// A raw sample as delivered by a transport (BLE notify or Wi-Fi poll),
/// before the app applies the pin configuration.
struct DeviceSample: Equatable {
    let rawADC: Int
    /// Voltage the device itself computed, if it reports one.
    let deviceVolts: Double?
    let pinId: String?
    let timestamp: Date

    init(rawADC: Int, deviceVolts: Double? = nil, pinId: String? = nil, timestamp: Date = Date()) {
        self.rawADC = rawADC
        self.deviceVolts = deviceVolts
        self.pinId = pinId
        self.timestamp = timestamp
    }
}

/// A fully-interpreted reading the UI displays and charts.
struct BatteryReading: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let rawADC: Int
    let voltage: Double
    /// State of charge 0...1.
    let percentage: Double?
    let pinId: String
}
