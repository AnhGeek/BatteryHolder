import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            NavigationStack { MonitorView() }
                .tabItem { Label("Monitor", systemImage: "bolt.fill") }

            NavigationStack { DeviceListView() }
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack { BoardSetupView() }
                .tabItem { Label("Setup", systemImage: "cpu") }

            NavigationStack { FlashView() }
                .tabItem { Label("Flash", systemImage: "arrow.down.circle") }
        }
    }
}

#if DEBUG
struct RootTabView_Previews: PreviewProvider {
    static var previews: some View {
        RootTabView()
            .environmentObject(AppState.preview)
            .tint(Theme.color.brand)
    }
}
#endif
