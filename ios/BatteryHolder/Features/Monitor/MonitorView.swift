import SwiftUI

/// Live battery voltage from the connected board.
struct MonitorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing.xl) {
                if appState.pinConfiguration == nil {
                    ContentUnavailableViewCompat(
                        title: "Not configured",
                        message: "Select a board and battery pin on the Setup tab.",
                        systemImage: "bolt.slash")
                } else {
                    gauge
                    stats
                    historyCard
                    controls
                }
            }
            .padding(Theme.spacing.lg)
        }
        .background(Theme.color.background)
        .navigationTitle("Monitor")
    }

    private var reading: BatteryReading? { appState.latestReading }
    private var pct: Double { reading?.percentage ?? 0 }

    private var gauge: some View {
        ZStack {
            BatteryGauge(fraction: pct, color: Theme.color.battery(forPercentage: pct))
                .frame(width: 220, height: 220)
            VStack(spacing: Theme.spacing.xs) {
                Text(reading.map { String(format: "%.2f", $0.voltage) } ?? "–––")
                    .font(Theme.font.monoLarge)
                    .foregroundStyle(Theme.color.textPrimary)
                Text("volts").font(Theme.font.footnote).foregroundStyle(Theme.color.textSecondary)
                Text(String(format: "%.0f%%", pct * 100))
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.battery(forPercentage: pct))
            }
        }
        .padding(.top, Theme.spacing.md)
    }

    private var stats: some View {
        HStack(spacing: Theme.spacing.sm) {
            StatPill(label: "Raw ADC", value: reading.map { "\($0.rawADC)" } ?? "–")
            StatPill(label: "Pin", value: pinName, tint: Theme.color.accent)
            StatPill(label: "Transport", value: appState.activeTransport.displayName,
                     tint: Theme.color.textSecondary)
        }
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.spacing.sm) {
                SectionHeader(title: "History", subtitle: "Recent voltage")
                Sparkline(values: appState.readings.map(\.voltage),
                          color: Theme.color.battery(forPercentage: pct))
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var controls: some View {
        Button {
            appState.isMonitoring ? appState.stopMonitoring() : appState.startMonitoring()
        } label: {
            Label(appState.isMonitoring ? "Stop monitoring" : "Start monitoring",
                  systemImage: appState.isMonitoring ? "stop.fill" : "play.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private var pinName: String {
        guard let id = appState.pinConfiguration?.batteryPinId,
              let pin = appState.selectedBoard?.pin(withId: id) else { return "–" }
        return pin.name
    }
}
