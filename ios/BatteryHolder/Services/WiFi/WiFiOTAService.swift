import Foundation
import Network
import Combine

struct WiFiDevice: Identifiable, Equatable {
    let id: String        // Bonjour service name
    let name: String
    var host: String
    var port: Int
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}

enum WiFiError: LocalizedError {
    case notConnected, badResponse, resolveFailed
    var errorDescription: String? {
        switch self {
        case .notConnected: return "No board selected on the network."
        case .badResponse: return "The board returned an unexpected response."
        case .resolveFailed: return "Could not resolve the board's address."
        }
    }
}

/// Discovers boards via Bonjour and drives voltage polling + HTTP OTA.
final class WiFiOTAService: NSObject, ObservableObject {
    @Published private(set) var discovered: [WiFiDevice] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var connected: WiFiDevice?
    @Published var latestSample: DeviceSample?

    private var browser: NWBrowser?
    private var pollTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    // MARK: Discovery

    func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_batteryholder._tcp", domain: nil), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handle(results: results) }
        }
        browser.start(queue: .main)
        isBrowsing = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private func handle(results: Set<NWBrowser.Result>) async {
        var devices: [WiFiDevice] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if let (host, port) = await resolve(result.endpoint) {
                devices.append(WiFiDevice(id: name, name: name, host: host, port: port))
            }
        }
        discovered = devices
    }

    /// Resolve a Bonjour endpoint to a concrete host + port.
    private func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard case .ready = state,
                      let path = connection.currentPath,
                      case let .hostPort(host, port)? = path.remoteEndpoint else {
                    if case .failed = state, !resumed { resumed = true; continuation.resume(returning: nil) }
                    return
                }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: ("\(host)".components(separatedBy: "%").first ?? "\(host)", Int(port.rawValue)))
                }
                connection.cancel()
            }
            connection.start(queue: .global())
        }
    }

    func connect(_ device: WiFiDevice) { connected = device }
    func disconnect() { stopPolling(); connected = nil }

    // MARK: Voltage polling

    func startPolling(intervalMs: Int) {
        guard let device = connected else { return }
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(device)
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private func pollOnce(_ device: WiFiDevice) async {
        struct VoltageDTO: Decodable { let raw: Int; let volts: Double?; let pin: String? }
        do {
            let (data, _) = try await session.data(from: device.baseURL.appendingPathComponent("api/voltage"))
            let dto = try JSONDecoder().decode(VoltageDTO.self, from: data)
            latestSample = DeviceSample(rawADC: dto.raw, deviceVolts: dto.volts, pinId: dto.pin)
        } catch {
            // Transient network errors are ignored; the next tick retries.
        }
    }

    // MARK: Pin configuration

    func writePinConfiguration(_ config: PinConfiguration) async throws {
        guard let device = connected else { throw WiFiError.notConnected }
        var request = URLRequest(url: device.baseURL.appendingPathComponent("api/config"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(config)
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WiFiError.badResponse }
    }

    // MARK: OTA upload

    func uploadFirmware(_ image: Data, progress: @escaping (Double) -> Void) async throws {
        guard let device = connected else { throw WiFiError.notConnected }
        let boundary = "BatteryHolder-\(UUID().uuidString)"
        var request = URLRequest(url: device.baseURL.appendingPathComponent("update"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(image)
        body.append("\r\n--\(boundary)--\r\n")

        let delegate = UploadProgressDelegate(progress: progress)
        let progressSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (_, response) = try await progressSession.upload(for: request, from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WiFiError.badResponse }
    }
}

/// Reports byte-level upload progress for the firmware POST.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { self.progress(fraction) }
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
