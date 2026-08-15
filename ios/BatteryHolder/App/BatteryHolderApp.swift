import SwiftUI

@main
struct BatteryHolderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .tint(Theme.color.brand)
        }
    }
}
