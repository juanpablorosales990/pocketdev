import SwiftUI

@main
struct PocketDevApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        Task { await appState.handleBackground() }
                    case .active:
                        Task { await appState.handleForeground() }
                    default:
                        break
                    }
                }
        }
    }
}
