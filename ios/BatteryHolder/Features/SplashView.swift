import SwiftUI

/// Launch/splash screen shown while the app warms up and fetches initial data.
///
/// The duration is *not* fixed: it stays visible until `AppState.bootstrap()`
/// finishes (a real network warm-up with a soft timeout), so it lasts a few
/// seconds at most and disappears as soon as data is ready.
struct SplashView: View {
    @EnvironmentObject var appState: AppState
    @State private var logoPulse = false
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: Theme.spacing.xl) {
                Spacer()

                AppLogo(size: 132)
                    .scaleEffect(logoPulse ? 1.04 : 0.98)
                    .shadow(color: Theme.color.brand.opacity(glowPulse ? 0.55 : 0.2),
                            radius: glowPulse ? 44 : 22)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: logoPulse)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: glowPulse)

                VStack(spacing: Theme.spacing.xs) {
                    Text("BatteryHolder")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text("ESP32 · ESP8266 battery tools")
                        .font(Theme.font.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                VStack(spacing: Theme.spacing.md) {
                    LoadingDots()
                    Text(appState.bootstrapStatus)
                        .font(Theme.font.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: appState.bootstrapStatus)
                }
                .padding(.bottom, Theme.spacing.xxxl)
            }
            .padding(Theme.spacing.xl)
        }
        .onAppear {
            logoPulse = true
            glowPulse = true
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0E2052), Color(hex: 0x091438), Color(hex: 0x03060F)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.color.brand.opacity(0.35), .clear],
                           center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// An indeterminate three-dot loader that animates continuously while data loads.
private struct LoadingDots: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.color.accent)
                    .frame(width: 10, height: 10)
                    .scaleEffect(active ? 1 : 0.4)
                    .opacity(active ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(i) * 0.18), value: active)
            }
        }
        .onAppear { active = true }
    }
}

#Preview {
    SplashView().environmentObject(AppState())
}
