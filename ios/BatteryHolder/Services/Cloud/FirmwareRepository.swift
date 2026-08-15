import Foundation
import CryptoKit

enum FirmwareRepositoryError: LocalizedError {
    case http(Int), noDownloadURL, checksumMismatch
    var errorDescription: String? {
        switch self {
        case .http(let code): return "Server returned HTTP \(code)."
        case .noDownloadURL: return "No download URL was provided for this build."
        case .checksumMismatch: return "Downloaded firmware failed its SHA-256 check."
        }
    }
}

/// REST client for the AWS firmware catalog (see docs/AWS_BACKEND.md).
final class FirmwareRepository {
    private let baseURL: URL
    private let session: URLSession
    /// Supplies a Cognito JWT for authorized requests. Returns nil when unauthenticated.
    var tokenProvider: () async -> String? = { nil }

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func authorized(_ url: URL, method: String = "GET") async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// List builds available for a board, newest first.
    func listFirmware(boardId: String) async throws -> [FirmwareImage] {
        struct Envelope: Decodable { let items: [FirmwareImage] }
        let url = baseURL.appendingPathComponent("boards/\(boardId)/firmware")
        let (data, response) = try await session.data(for: await authorized(url))
        try Self.check(response)
        return try decoder().decode(Envelope.self, from: data).items
    }

    /// Fetch build detail including a presigned `downloadUrl`.
    func detail(buildId: String) async throws -> FirmwareImage {
        let url = baseURL.appendingPathComponent("firmware/\(buildId)")
        let (data, response) = try await session.data(for: await authorized(url))
        try Self.check(response)
        return try decoder().decode(FirmwareImage.self, from: data)
    }

    /// Download the firmware binary and verify its SHA-256 before returning it.
    func download(_ image: FirmwareImage) async throws -> Data {
        let resolved = image.downloadUrl != nil ? image : try await detail(buildId: image.buildId)
        guard let url = resolved.downloadUrl else { throw FirmwareRepositoryError.noDownloadURL }

        let (data, response) = try await session.data(from: url)
        try Self.check(response)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(resolved.sha256) == .orderedSame else {
            throw FirmwareRepositoryError.checksumMismatch
        }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FirmwareRepositoryError.http(http.statusCode)
        }
    }
}
