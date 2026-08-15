import Foundation
import Combine
import SwiftUI

/// Backend + integration configuration. Fill these in after deploying
/// `backend/template.yaml` (see docs/AWS_BACKEND.md).
enum AppConfig {
    static let firmwareApiBaseURL = URL(string: "https://REPLACE_ME.execute-api.ap-southeast-1.amazonaws.com/prod")!
    static let cognitoUserPoolId = "REPLACE_ME"
    static let cognitoClientId = "REPLACE_ME"
}

/// Composition root and single source of truth for the UI.
///
/// Owns the services, the board catalog, the working `PinConfiguration`, and
/// the live reading buffer. Views observe it via `@EnvironmentObject`.
@MainActor
final class AppState: ObservableObject {

    // MARK: Catalog & configuration
    @Published private(set) var boards: [Board] = []
    @Published var selectedBoard: Board?
    @Published var pinConfiguration: PinConfiguration?

    // MARK: Transport selection
    @Published var activeTransport: FlashTransport = .ble

    // MARK: Live monitoring
    @Published private(set) var readings: [BatteryReading] = []
    @Published var isMonitoring = false

    // MARK: Services
    let ble: BLEManager
    let wifi: WiFiOTAService
    let flasher: FirmwareFlasher
    let firmwareRepo: FirmwareRepository

    private var cancellables = Set<AnyCancellable>()
    private let maxReadings = 120

    init(ble: BLEManager = BLEManager(),
         wifi: WiFiOTAService = WiFiOTAService(),
         firmwareRepo: FirmwareRepository = FirmwareRepository(baseURL: AppConfig.firmwareApiBaseURL)) {
        self.ble = ble
        self.wifi = wifi
        self.firmwareRepo = firmwareRepo
        self.flasher = FirmwareFlasher(ble: ble, wifi: wifi)

        self.boards = Self.loadBoards()
        wireSampleStreams()
    }

    // MARK: Board & pin selection

    func selectBoard(_ board: Board) {
        selectedBoard = board
        // Seed a sensible default pin configuration for the board.
        let pin = board.recommendedBatteryPin ?? board.adcCapablePins.first
        if let pin {
            pinConfiguration = PinConfiguration.makeDefault(board: board, pin: pin)
        }
        // Keep flash transport valid for the board.
        if let first = board.supportedTransports.first, !board.supportedTransports.contains(activeTransport) {
            activeTransport = first
        }
    }

    func setBatteryPin(_ pin: Pin) {
        guard var cfg = pinConfiguration else { return }
        cfg.batteryPinId = pin.id
        pinConfiguration = cfg
    }

    /// Push the current configuration to the connected board over the active transport.
    func applyPinConfiguration() async throws {
        guard let cfg = pinConfiguration else { return }
        switch activeTransport {
        case .ble:  try await ble.writePinConfiguration(cfg)
        case .wifi: try await wifi.writePinConfiguration(cfg)
        }
    }

    // MARK: Connection

    func startDiscovery() {
        switch activeTransport {
        case .ble:  ble.startScan()
        case .wifi: wifi.startBrowsing()
        }
    }

    func stopDiscovery() {
        ble.stopScan()
        wifi.stopBrowsing()
    }

    // MARK: Monitoring

    func startMonitoring() {
        isMonitoring = true
        readings.removeAll()
        switch activeTransport {
        case .ble:  ble.setNotifying(true)
        case .wifi: wifi.startPolling(intervalMs: pinConfiguration?.sampleIntervalMs ?? 1000)
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        ble.setNotifying(false)
        wifi.stopPolling()
    }

    // MARK: Flashing

    func flash(_ image: FirmwareImage) async throws {
        let data = try await firmwareRepo.download(image)
        try await flasher.flash(data: data, over: activeTransport)
    }

    // MARK: Private

    private func wireSampleStreams() {
        ble.$latestSample
            .compactMap { $0 }
            .sink { [weak self] in self?.ingest($0) }
            .store(in: &cancellables)

        wifi.$latestSample
            .compactMap { $0 }
            .sink { [weak self] in self?.ingest($0) }
            .store(in: &cancellables)
    }

    private func ingest(_ sample: DeviceSample) {
        guard let cfg = pinConfiguration else { return }
        let volts = cfg.voltage(fromRawADC: sample.rawADC)
        let pct = cfg.percentage(forVoltage: volts)
        let reading = BatteryReading(timestamp: sample.timestamp,
                                     rawADC: sample.rawADC,
                                     voltage: volts,
                                     percentage: pct,
                                     pinId: cfg.batteryPinId)
        readings.append(reading)
        if readings.count > maxReadings {
            readings.removeFirst(readings.count - maxReadings)
        }
    }

    private static func loadBoards() -> [Board] {
        guard let url = Bundle.main.url(forResource: "boards", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("boards.json missing from bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([Board].self, from: data)
        } catch {
            assertionFailure("boards.json decode failed: \(error)")
            return []
        }
    }
}

extension AppState {
    /// Most recent reading, if any.
    var latestReading: BatteryReading? { readings.last }
}

// MARK: - Preview fixtures

#if DEBUG

/// Sample state for SwiftUI previews.
///
/// These live here rather than in a separate file because `boards` and
/// `readings` are `private(set)` — only code in this file can seed them.
extension AppState {

    /// Configured and streaming: a selected board, a seeded pin configuration,
    /// and a synthetic discharge curve for the gauge and sparkline to draw.
    static var preview: AppState {
        let state = previewEmpty
        if let board = state.boards.first {
            state.selectBoard(board)
        }
        state.readings = previewReadings(config: state.pinConfiguration)
        return state
    }

    /// Freshly launched: nothing selected, so views render their empty states.
    static var previewEmpty: AppState {
        let state = AppState()
        // Fall back to a built-in board if boards.json isn't in the preview bundle.
        if state.boards.isEmpty { state.boards = [.previewESP32] }
        return state
    }

    /// A gentle 4.05 V -> 3.72 V discharge with a little sensor noise, run back
    /// through the real configuration math so the numbers are self-consistent.
    private static func previewReadings(config: PinConfiguration?) -> [BatteryReading] {
        guard let config else { return [] }
        let now = Date()
        let count = 60
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let target = 4.05 - 0.33 * t + sin(Double(i) / 3.5) * 0.006
            let scale = config.adcRefVoltage * config.dividerRatio * config.calibrationFactor
            let raw = Int((target / scale) * Double(config.adcMaxCount))
            let volts = config.voltage(fromRawADC: raw)
            return BatteryReading(timestamp: now.addingTimeInterval(Double(i - count + 1)),
                                  rawADC: raw,
                                  voltage: volts,
                                  percentage: config.percentage(forVoltage: volts),
                                  pinId: config.batteryPinId)
        }
    }
}

extension Board {
    /// Stand-in catalog entry so previews never depend on the bundled JSON.
    static let previewESP32 = Board(
        id: "esp32-wroom",
        name: "ESP32 DevKitC (WROOM-32)",
        chip: .esp32,
        summary: "Classic dual-core ESP32 with Wi-Fi and Bluetooth LE.",
        adcResolutionBits: 12,
        adcRefVoltage: 3.3,
        recommendedBatteryPinId: "gpio34",
        supportedTransports: [.ble, .wifi],
        pins: [
            Pin(id: "gpio34", name: "GPIO34", gpio: 34, adcChannel: "ADC1_CH6", adcUnit: 1,
                inputOnly: true, wifiSafeADC: true, capabilities: [.adc, .digitalIn],
                note: "Input-only pin — ideal for battery sensing."),
            Pin(id: "gpio35", name: "GPIO35", gpio: 35, adcChannel: "ADC1_CH7", adcUnit: 1,
                inputOnly: true, wifiSafeADC: true, capabilities: [.adc, .digitalIn], note: nil),
            Pin(id: "gpio32", name: "GPIO32", gpio: 32, adcChannel: "ADC1_CH4", adcUnit: 1,
                inputOnly: false, wifiSafeADC: true,
                capabilities: [.adc, .digitalIn, .digitalOut, .touch, .pwm], note: nil),
            Pin(id: "gpio25", name: "GPIO25", gpio: 25, adcChannel: "ADC2_CH8", adcUnit: 2,
                inputOnly: false, wifiSafeADC: false,
                capabilities: [.adc, .digitalIn, .digitalOut, .dac, .pwm],
                note: "ADC2 is unavailable while Wi-Fi is active."),
            Pin(id: "gpio2", name: "GPIO2", gpio: 2, adcChannel: "ADC2_CH2", adcUnit: 2,
                inputOnly: false, wifiSafeADC: false,
                capabilities: [.adc, .digitalIn, .digitalOut, .strapping],
                note: "Strapping pin — affects boot mode."),
        ])
}

#endif
