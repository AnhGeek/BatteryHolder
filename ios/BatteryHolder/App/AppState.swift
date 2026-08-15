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
