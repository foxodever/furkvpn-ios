import AppIntents
import NetworkExtension

// "Подключить", "Отключить", "Вкл/выкл" for Shortcuts, Siri, automations and the Action button:
// they switch the VPN without opening the app (like the Android shortcuts for Samsung routines and
// the Infinix button).

@available(iOS 16.0, *)
private struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource
}

@available(iOS 16.0, *)
private enum TunnelSwitch {
    static func manager() async throws -> NETunnelProviderManager {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        // The profile is created by the first connection in the app (iOS asks for permission there).
        guard Store.loadSubscription() != nil,
              let manager = all.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelExtension.id })
        else { throw IntentFailure(localizedStringResource: "Сначала подключитесь в приложении FurkVPN") }
        return manager
    }

    static func isOn(_ manager: NETunnelProviderManager) -> Bool {
        [.connected, .connecting, .reasserting].contains(manager.connection.status)
    }

    static func turnOn(_ manager: NETunnelProviderManager) async throws {
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        Store.setTunnelError(nil)
        var options: [String: NSObject] = [:]
        if let payload = TunnelPayload.fromStore() { options[TunnelPayload.key] = payload.encoded() as NSData }
        try manager.connection.startVPNTunnel(options: options)
    }
}

@available(iOS 16.0, *)
struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Подключить VPN"
    static let description = IntentDescription("Подключает FurkVPN к выбранному серверу.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = try await TunnelSwitch.manager()
        if !TunnelSwitch.isOn(manager) { try await TunnelSwitch.turnOn(manager) }
        return .result(dialog: "FurkVPN подключается…")
    }
}

@available(iOS 16.0, *)
struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Отключить VPN"
    static let description = IntentDescription("Отключает FurkVPN.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = try await TunnelSwitch.manager()
        manager.connection.stopVPNTunnel()
        return .result(dialog: "FurkVPN отключён")
    }
}

@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить или выключить VPN"
    static let description = IntentDescription("Подключает FurkVPN, а если он уже подключён — отключает.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = try await TunnelSwitch.manager()
        if TunnelSwitch.isOn(manager) {
            manager.connection.stopVPNTunnel()
            return .result(dialog: "FurkVPN отключён")
        }
        try await TunnelSwitch.turnOn(manager)
        return .result(dialog: "FurkVPN подключается…")
    }
}

@available(iOS 17.0, *)
struct FurkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVPNIntent(),
            phrases: ["Включи или выключи \(.applicationName)", "Переключи \(.applicationName)"],
            shortTitle: "Вкл/выкл VPN",
            systemImageName: "power"
        )
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: ["Подключи \(.applicationName)", "Включи \(.applicationName)"],
            shortTitle: "Подключить",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: ["Отключи \(.applicationName)", "Выключи \(.applicationName)"],
            shortTitle: "Отключить",
            systemImageName: "lock.open"
        )
    }
}
