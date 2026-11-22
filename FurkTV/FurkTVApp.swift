import SwiftUI

@main
struct FurkTVApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.vpn)
                .task { model.onResume() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.onResume() }
                }
        }
    }
}
