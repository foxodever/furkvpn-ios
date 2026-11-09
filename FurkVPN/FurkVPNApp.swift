import SwiftUI

@main
struct FurkVPNApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.vpn)
                // furkvpn://import?url=… from furkapp.net/import and the site's "Войти в приложение FurkVPN".
                .onOpenURL { model.submitKey($0.absoluteString) }
                // Right after start the config is always fetched again; scenePhase may already be active then.
                .task { model.onResume() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.onResume() }
                }
        }
    }
}
