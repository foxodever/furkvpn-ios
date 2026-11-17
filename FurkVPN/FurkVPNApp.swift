import SwiftUI
import UIKit

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
                .onAppear { MacWindow.configure() }
        }
        .commands { AppCommands(model: model, vpn: model.vpn) }
    }
}

/** The menu bar of the Mac and the ⌘ shortcuts of an iPad keyboard (hold ⌘ to see them). */
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var vpn: VPNController

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model.settingsOpen = true }
                .keyboardShortcut(",")
                .disabled(model.subscription == nil || model.consent != .given)
        }
        // One window is enough for a VPN.
        CommandGroup(replacing: .newItem) {}
        CommandMenu("VPN") {
            Button(vpn.state == .idle ? "Подключиться" : "Отключиться") {
                if vpn.state == .idle {
                    Task { await vpn.connect() }
                } else {
                    vpn.disconnect()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.subscription == nil || model.consent != .given)
            Divider()
            Button("Проверить пинг") { model.testPings() }
                .keyboardShortcut("t")
                .disabled(model.subscription == nil || model.consent != .given)
            Button("Обновить подписку") { model.refreshSubscription(showMessage: true) }
                .keyboardShortcut("r")
                .disabled(model.subscription == nil || model.refreshing || model.consent != .given)
        }
    }
}

/** The window of the Mac build: the content goes up under the title bar, and it can't get smaller than a phone. */
enum MacWindow {
    static func configure() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            scene.sizeRestrictions?.minimumSize = CGSize(width: 400, height: 640)
            #if DEMO
            if let size = Demo.windowSize {
                scene.sizeRestrictions?.minimumSize = size
                scene.sizeRestrictions?.maximumSize = size
            }
            #endif
        }
        #endif
    }
}
