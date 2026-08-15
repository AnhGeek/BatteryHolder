import SwiftUI

@main
struct BatteryHolderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .tint(Theme.color.brand)
        }
    }
}

/// Shows the animated splash while the app fetches initial data, then crossfades
/// into the main tab UI once `AppState.bootstrap()` completes.
struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            if appState.isBootstrapping {
                SplashView()
                    .transition(.opacity)
            } else {
                RootTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: appState.isBootstrapping)
        .task { await appState.bootstrap() }
    }
}
