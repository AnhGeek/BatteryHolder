import SwiftUI

/// Let the user pick the ADC pin intuitively and dial in the divider math.
struct PinConfigView: View {
    @EnvironmentObject var appState: AppState
    @State private var applyState: ApplyState = .idle

    enum ApplyState: Equatable { case idle, applying, success, failure(String) }

    var body: some View {
        Group {
            if let board = appState.selectedBoard, appState.pinConfiguration != nil {
                content(board: board, config: configBinding)
            } else {
                ContentUnavailableViewCompat(
                    title: "No board selected",
                    message: "Choose a board on the Setup tab first.",
                    systemImage: "cpu")
            }
        }
        .background(Theme.color.background)
        .navigationTitle("Pins")
    }

    private var configBinding: Binding<PinConfiguration> {
        Binding(get: { appState.pinConfiguration! },
                set: { appState.pinConfiguration = $0 })
    }

    private func content(board: Board, config: Binding<PinConfiguration>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.xl) {
                pinPicker(board: board, config: config)
                dividerSection(config: config)
                batterySection(config: config)
                rangeSummary(board: board, config: config.wrappedValue)
                applyButton
            }
            .padding(Theme.spacing.lg)
        }
    }

    // MARK: Pin picker

    private func pinPicker(board: Board, config: Binding<PinConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            SectionHeader(title: "Battery ADC pin",
                          subtitle: "Tap the pin you connected the battery divider to.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: Theme.spacing.sm)],
                      spacing: Theme.spacing.sm) {
                ForEach(board.adcCapablePins) { pin in
                    Button {
                        appState.setBatteryPin(pin)
                    } label: {
                        PinChip(pin: pin, isSelected: config.wrappedValue.batteryPinId == pin.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let pin = board.pin(withId: config.wrappedValue.batteryPinId) {
                if !pin.wifiSafeADC && appState.activeTransport == .wifi {
                    Callout(text: "\(pin.name) uses ADC2, which is unavailable while Wi-Fi is active. Pick an ADC1 pin or use Bluetooth.",
                            tint: Theme.color.warning, icon: "exclamationmark.triangle.fill")
                } else if let note = pin.note {
                    Callout(text: note, tint: Theme.color.brand, icon: "info.circle.fill")
                }
            }
        }
    }

    // MARK: Divider

    private func dividerSection(config: Binding<PinConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            SectionHeader(title: "Voltage divider",
                          subtitle: "battery+ → R1 → (ADC pin) → R2 → GND")
            Card {
                VStack(spacing: Theme.spacing.md) {
                    numberRow("R1 (kΩ)", value: config.dividerR1KOhm)
                    Divider()
                    numberRow("R2 (kΩ)", value: config.dividerR2KOhm)
                    Divider()
                    numberRow("Calibration", value: config.calibrationFactor)
                    Divider()
                    intRow("Sample interval (ms)", value: config.sampleIntervalMs)
                }
            }
        }
    }

    // MARK: Battery

    private func batterySection(config: Binding<PinConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            SectionHeader(title: "Battery pack",
                          subtitle: "Used for the percentage estimate.")
            Card {
                VStack(spacing: Theme.spacing.md) {
                    Picker("Chemistry", selection: config.chemistry) {
                        ForEach(BatteryChemistry.allCases) { Text($0.displayName).tag($0) }
                    }
                    Divider()
                    Stepper("Cells in series: \(config.wrappedValue.cellCount)",
                            value: config.cellCount, in: 1...12)
                }
            }
        }
    }

    // MARK: Range summary

    private func rangeSummary(board: Board, config: PinConfiguration) -> some View {
        let maxMeasurable = config.voltage(fromRawADC: config.adcMaxCount)
        return HStack(spacing: Theme.spacing.sm) {
            StatPill(label: "Divider ratio", value: String(format: "%.2f×", config.dividerRatio))
            StatPill(label: "Max measurable", value: String(format: "%.2f V", maxMeasurable),
                     tint: Theme.color.accent)
            StatPill(label: "ADC max", value: "\(config.adcMaxCount)", tint: Theme.color.textSecondary)
        }
    }

    // MARK: Apply

    private var applyButton: some View {
        VStack(spacing: Theme.spacing.sm) {
            Button {
                Task { await apply() }
            } label: {
                if applyState == .applying {
                    ProgressView().tint(Theme.color.textOnBrand)
                } else {
                    Text("Apply to board")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(applyState == .applying)

            switch applyState {
            case .success:
                Callout(text: "Configuration sent to the board.", tint: Theme.color.success, icon: "checkmark.circle.fill")
            case .failure(let msg):
                Callout(text: msg, tint: Theme.color.danger, icon: "xmark.octagon.fill")
            default:
                EmptyView()
            }
        }
    }

    private func apply() async {
        applyState = .applying
        do {
            try await appState.applyPinConfiguration()
            applyState = .success
        } catch {
            applyState = .failure(error.localizedDescription)
        }
    }

    // MARK: Rows

    private func numberRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(Theme.font.body).foregroundStyle(Theme.color.textPrimary)
            Spacer()
            TextField(label, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.font.mono)
                .frame(maxWidth: 120)
        }
    }

    private func intRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(Theme.font.body).foregroundStyle(Theme.color.textPrimary)
            Spacer()
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.font.mono)
                .frame(maxWidth: 120)
        }
    }
}

// MARK: - Small shared UI

struct Callout: View {
    let text: String
    var tint: Color = Theme.color.brand
    var icon: String = "info.circle.fill"
    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(Theme.font.footnote).foregroundStyle(Theme.color.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(Theme.spacing.md)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
    }
}

/// Minimal stand-in for ContentUnavailableView to support iOS 16.
struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    let systemImage: String
    var body: some View {
        VStack(spacing: Theme.spacing.md) {
            Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(Theme.color.textSecondary)
            Text(title).font(Theme.font.headline).foregroundStyle(Theme.color.textPrimary)
            Text(message).font(Theme.font.footnote).foregroundStyle(Theme.color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.spacing.xl)
    }
}
