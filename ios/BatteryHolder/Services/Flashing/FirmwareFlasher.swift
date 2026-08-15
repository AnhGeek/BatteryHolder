import Foundation
import Combine

/// Transport-agnostic OTA orchestrator. Given firmware bytes and a chosen
/// transport, it drives the right service and publishes a single progress
/// stream the UI can bind to.
@MainActor
final class FirmwareFlasher: ObservableObject {
    @Published private(set) var progress = FlashProgress()

    private let ble: BLEManager
    private let wifi: WiFiOTAService

    init(ble: BLEManager, wifi: WiFiOTAService) {
        self.ble = ble
        self.wifi = wifi
    }

    func flash(data: Data, over transport: FlashTransport) async throws {
        progress = FlashProgress(phase: .preparing, fraction: 0, message: "Preparing update…")
        do {
            progress.phase = .uploading
            progress.message = "Uploading firmware over \(transport.displayName)…"

            let onProgress: (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    self?.progress.fraction = fraction
                }
            }

            switch transport {
            case .ble:  try await ble.uploadFirmware(data, progress: onProgress)
            case .wifi: try await wifi.uploadFirmware(data, progress: onProgress)
            }

            progress.phase = .verifying
            progress.message = "Verifying…"
            progress.phase = .rebooting
            progress.message = "Rebooting board…"
            progress.phase = .done
            progress.fraction = 1
            progress.message = "Update complete"
        } catch {
            progress.phase = .failed(error.localizedDescription)
            progress.message = error.localizedDescription
            throw error
        }
    }

    func reset() { progress = FlashProgress() }
}
