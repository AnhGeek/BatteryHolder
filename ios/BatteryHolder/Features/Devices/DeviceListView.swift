import SwiftUI
import CoreBluetooth

/// Discover and connect to a board over the active transport.
struct DeviceListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.lg) {
                transportPicker
                if appState.activeTransport == .ble {
                    BLEDeviceList(ble: appState.ble)
                } else {
                    WiFiDeviceList(wifi: appState.wifi)
                }
            }
            .padding(Theme.spacing.lg)
        }
        .background(Theme.color.background)
        .navigationTitle("Devices")
        .onDisappear { appState.stopDiscovery() }
    }

    private var transportPicker: some View {
        let transports = appState.selectedBoard?.supportedTransports ?? FlashTransport.allCases
        return Picker("Transport", selection: $appState.activeTransport) {
            ForEach(transports) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - BLE

private struct BLEDeviceList: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            HStack {
                SectionHeader(title: "Bluetooth", subtitle: statusText)
                Spacer()
                Button(ble.isScanning ? "Stop" : "Scan") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 96)
                .disabled(ble.state != .poweredOn)
            }

            if ble.state != .poweredOn {
                Callout(text: "Turn on Bluetooth to scan for boards.", tint: Theme.color.warning,
                        icon: "exclamationmark.triangle.fill")
            }

            ForEach(ble.discovered) { device in
                Button { ble.connect(device) } label: {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(Theme.font.headline)
                                    .foregroundStyle(Theme.color.textPrimary)
                                Text("RSSI \(device.rssi) dBm").font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.color.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusText: String {
        switch ble.connection {
        case .disconnected: return "Not connected"
        case .connecting:   return "Connecting…"
        case .discovering:  return "Discovering services…"
        case .connected:    return "Connected"
        case .failed(let m): return m
        }
    }
}

// MARK: - Wi-Fi

private struct WiFiDeviceList: View {
    @ObservedObject var wifi: WiFiOTAService

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            HStack {
                SectionHeader(title: "Wi-Fi", subtitle: wifi.connected.map { "Connected to \($0.name)" } ?? "Not connected")
                Spacer()
                Button(wifi.isBrowsing ? "Stop" : "Find") {
                    wifi.isBrowsing ? wifi.stopBrowsing() : wifi.startBrowsing()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 96)
            }

            if wifi.discovered.isEmpty {
                Callout(text: "Make sure your phone and the board are on the same Wi-Fi network.",
                        tint: Theme.color.brand, icon: "info.circle.fill")
            }

            ForEach(wifi.discovered) { device in
                Button { wifi.connect(device) } label: {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(Theme.font.headline)
                                    .foregroundStyle(Theme.color.textPrimary)
                                Text("\(device.host):\(device.port)").font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.textSecondary)
                            }
                            Spacer()
                            Image(systemName: wifi.connected?.id == device.id ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundStyle(wifi.connected?.id == device.id ? Theme.color.brand : Theme.color.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
