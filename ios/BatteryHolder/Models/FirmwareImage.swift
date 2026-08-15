import Foundation

enum FirmwareChannel: String, Codable {
    case stable, beta
}

/// A firmware build from the AWS catalog.
struct FirmwareImage: Identifiable, Codable, Equatable {
    var buildId: String
    var boardId: String
    var version: String
    var channel: FirmwareChannel
    var sizeBytes: Int
    var sha256: String
    var releaseNotes: String
    var createdAt: Date
    /// Presigned download URL (populated by the detail endpoint).
    var downloadUrl: URL?

    var id: String { buildId }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Progress of an over-the-air flash, published by `FirmwareFlasher`.
struct FlashProgress: Equatable {
    enum Phase: Equatable {
        case idle
        case preparing
        case uploading
        case verifying
        case rebooting
        case done
        case failed(String)
    }
    var phase: Phase = .idle
    /// 0...1 for the upload portion.
    var fraction: Double = 0
    var message: String = ""

    var isActive: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
}
