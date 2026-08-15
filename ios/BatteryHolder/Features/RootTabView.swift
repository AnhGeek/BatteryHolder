import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            NavigationStack { BoardSetupView() }
                .tabItem { Label("Setup", systemImage: "cpu") }

            NavigationStack { DeviceListView() }
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack { MonitorView() }
                .tabItem { Label("Monitor", systemImage: "bolt.fill") }

            NavigationStack { FlashView() }
                .tabItem { Label("Flash", systemImage: "arrow.down.circle") }
        }
    }
}
