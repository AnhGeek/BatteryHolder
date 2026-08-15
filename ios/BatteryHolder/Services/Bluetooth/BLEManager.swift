import Foundation
import CoreBluetooth
import Combine

/// GATT contract shared with the reference firmware (see docs/ARCHITECTURE.md).
enum BLEUUID {
    static let service     = CBUUID(string: "A1B2C3D4-0001-4A5B-8C6D-000000000000")
    static let voltage     = CBUUID(string: "A1B2C3D4-0002-4A5B-8C6D-000000000000")
    static let rawADC      = CBUUID(string: "A1B2C3D4-0003-4A5B-8C6D-000000000000")
    static let pinConfig   = CBUUID(string: "A1B2C3D4-0004-4A5B-8C6D-000000000000")
    static let otaControl  = CBUUID(string: "A1B2C3D4-0005-4A5B-8C6D-000000000000")
    static let otaData     = CBUUID(string: "A1B2C3D4-0006-4A5B-8C6D-000000000000")
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    let peripheral: CBPeripheral
    static func == (l: DiscoveredDevice, r: DiscoveredDevice) -> Bool { l.id == r.id && l.rssi == r.rssi }
}

enum ConnectionState: Equatable {
    case disconnected, connecting, discovering, connected
    case failed(String)
}

enum BLEError: LocalizedError {
    case notConnected, missingCharacteristic, otaRejected(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a board."
        case .missingCharacteristic: return "The board is missing a required characteristic."
        case .otaRejected(let m): return "The board rejected the update: \(m)"
        }
    }
}

/// CoreBluetooth central that speaks the BatteryHolder GATT contract.
///
/// The central manager uses the main queue (`queue: nil`) so delegate callbacks
/// land on the main thread and can mutate `@Published` state directly.
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published var latestSample: DeviceSample?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var lastDeviceVolts: Double?

    // Async bridges for write / OTA completion.
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var otaContinuation: CheckedContinuation<Void, Error>?
    private var otaProgress: ((Double) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Scan

    func startScan() {
        guard state == .poweredOn else { return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: [BLEUUID.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    // MARK: Connect

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        connection = .connecting
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        chars.removeAll()
        connection = .disconnected
    }

    // MARK: Monitoring

    func setNotifying(_ on: Bool) {
        for uuid in [BLEUUID.voltage, BLEUUID.rawADC] {
            if let c = chars[uuid] { peripheral?.setNotifyValue(on, for: c) }
        }
    }

    // MARK: Pin configuration

    func writePinConfiguration(_ config: PinConfiguration) async throws {
        guard let p = peripheral else { throw BLEError.notConnected }
        guard let c = chars[BLEUUID.pinConfig] else { throw BLEError.missingCharacteristic }
        let data = try JSONEncoder().encode(config)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeContinuations[BLEUUID.pinConfig] = cont
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    // MARK: OTA

    /// Stream a firmware image to the board using the OTA control/data
    /// characteristics. Resolves when the board acknowledges success.
    func uploadFirmware(_ image: Data, progress: @escaping (Double) -> Void) async throws {
        guard let p = peripheral else { throw BLEError.notConnected }
        guard let control = chars[BLEUUID.otaControl], let dataChar = chars[BLEUUID.otaData] else {
            throw BLEError.missingCharacteristic
        }
        p.setNotifyValue(true, for: control)
        otaProgress = progress

        // START | uint32 size (LE)
        var start = Data([0x01]); start.append(uint32LE(UInt32(image.count)))
        try await write(start, to: control, on: p)

        // Stream chunks without response, sized to the negotiated MTU.
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        let chunkSize = max(20, min(mtu, 244))
        var offset = 0
        while offset < image.count {
            let end = min(offset + chunkSize, image.count)
            p.writeValue(image.subdata(in: offset..<end), for: dataChar, type: .withoutResponse)
            offset = end
            progress(Double(offset) / Double(image.count))
            try await Task.sleep(nanoseconds: 3_000_000) // light backpressure
        }

        // END | uint32 crc32 (LE), then await the board's status notification.
        var endCmd = Data([0x02]); endCmd.append(uint32LE(crc32(image)))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            otaContinuation = cont
            p.writeValue(endCmd, for: control, type: .withResponse)
        }
    }

    // MARK: Helpers

    private func write(_ data: Data, to char: CBCharacteristic, on p: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeContinuations[char.uuid] = cont
            p.writeValue(data, for: char, type: .withResponse)
        }
    }

    private func uint32LE(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if state != .poweredOn { isScanning = false }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "ESP device"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name,
                                      rssi: RSSI.intValue, peripheral: peripheral)
        if let idx = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[idx].rssi = device.rssi
        } else {
            discovered.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connection = .discovering
        peripheral.discoverServices([BLEUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connection = .failed(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        chars.removeAll()
        connection = .disconnected
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEUUID.service }) else {
            connection = .failed("BatteryHolder service not found")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        connection = .connected
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case BLEUUID.voltage:
            lastDeviceVolts = data.readFloat32LE()
        case BLEUUID.rawADC:
            let raw = Int(data.readUInt16LE())
            latestSample = DeviceSample(rawADC: raw, deviceVolts: lastDeviceVolts)
        case BLEUUID.otaControl:
            handleOTAStatus(data)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let cont = writeContinuations.removeValue(forKey: characteristic.uuid) else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func handleOTAStatus(_ data: Data) {
        guard let status = data.first else { return }
        switch status {
        case 0x10: // done OK
            otaContinuation?.resume(); otaContinuation = nil
        case 0x1F: // error
            let msg = data.count > 1 ? String(decoding: data.dropFirst(), as: UTF8.self) : "unknown"
            otaContinuation?.resume(throwing: BLEError.otaRejected(msg)); otaContinuation = nil
        default:
            break // 0x00 = ready / progress ack, ignored
        }
    }
}

// MARK: - Data decoding + CRC32

private extension Data {
    func readFloat32LE() -> Double? {
        guard count >= 4 else { return nil }
        let bits = withUnsafeBytes { $0.load(as: UInt32.self) }
        return Double(Float(bitPattern: UInt32(littleEndian: bits)))
    }
    func readUInt16LE() -> UInt16 {
        guard count >= 2 else { return 0 }
        return withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
    }
}

/// Standard CRC-32 (IEEE 802.3), matching the reference firmware's check.
func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
        }
    }
    return ~crc
}
