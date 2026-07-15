import SwiftUI

@main
struct CameraBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in model.handleScenePhase(phase) }
        }
    }
}
