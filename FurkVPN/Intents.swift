import AppIntents
import NetworkExtension

// "Подключить", "Отключить", "Вкл/выкл", "Подключить к серверу" and "Статус VPN" for Shortcuts, Siri,
// automations and the Action button: they work without opening the app (like the Android shortcuts for
// Samsung routines and the Infinix button). The Control Center button is in ControlIntent.swift.

@available(iOS 16.0, *)
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource
}

@available(iOS 16.0, *)
enum TunnelSwitch {
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
        if Store.autoReconnect != manager.isOnDemandEnabled {
            VPNController.applyOnDemand(manager, on: Store.autoReconnect)
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        Store.setTunnelError(nil)
        var options: [String: NSObject] = [:]
        if let payload = TunnelPayload.fromStore() { options[TunnelPayload.key] = payload.encoded() as NSData }
        try manager.connection.startVPNTunnel(options: options)
        // The widgets, until the tunnel says it is on (it may have been quicker than this).
        let server = Store.selectedEntry(in: Store.loadSubscription())?.displayName
        WidgetState.change { s in
            if s.vpn != .on { s.vpn = .connecting }
            s.server = server ?? s.server
        }
    }

    /** Off, and stays off: an on-demand rule would start it again. */
    static func turnOff(_ manager: NETunnelProviderManager) async throws {
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
        WidgetState.change { $0.vpn = .off }
    }

    /** On when off, off when on or on the way: what the Shortcuts toggle and the Control Center button do. */
    static func toggle() async throws -> Bool {
        let manager = try await manager()
        if isOn(manager) {
            try await turnOff(manager)
            return false
        }
        try await turnOn(manager)
        return true
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
        try await TunnelSwitch.turnOff(manager)
        return .result(dialog: "FurkVPN отключён")
    }
}

@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить или выключить VPN"
    static let description = IntentDescription("Подключает FurkVPN, а если он уже подключён — отключает.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let on = try await TunnelSwitch.toggle()
        return .result(dialog: on ? "FurkVPN подключается…" : "FurkVPN отключён")
    }
}

/** A server of the subscription, for "Подключить к серверу" (Shortcuts and Siri list them). */
@available(iOS 16.0, *)
struct ServerAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Сервер"
    static let defaultQuery = ServerQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ entry: ServerEntry) {
        id = entry.key
        name = entry.displayName
    }
}

@available(iOS 16.0, *)
struct ServerQuery: EntityQuery, EntityStringQuery {
    private var servers: [ServerAppEntity] { (Store.loadSubscription()?.selectable ?? []).map(ServerAppEntity.init) }

    func entities(for identifiers: [String]) async throws -> [ServerAppEntity] {
        servers.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ServerAppEntity] {
        servers.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ServerAppEntity] { servers }
}

@available(iOS 16.0, *)
struct ConnectToServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Подключить к серверу"
    static let description = IntentDescription("Выбирает сервер FurkVPN и подключается к нему (или переключается, если VPN уже включён).")
    static let openAppWhenRun = false

    @Parameter(title: "Сервер")
    var server: ServerAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Подключить FurkVPN к \(\.$server)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = try await TunnelSwitch.manager()
        guard Store.loadSubscription()?.selectable.contains(where: { $0.key == server.id }) == true else {
            throw IntentFailure(localizedStringResource: "Такого сервера больше нет в подписке")
        }
        Store.selectedServer = server.id
        if TunnelSwitch.isOn(manager) {
            // Still connecting, or moving to another network: the tunnel takes messages only once connected
            // (and its start may have read the server chosen before).
            var waited = 0
            while manager.connection.status != .connected, TunnelSwitch.isOn(manager), waited < 20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            // The running tunnel moves to it, as when it is picked in the app.
            if manager.connection.status == .connected, let session = manager.connection as? NETunnelProviderSession {
                try? session.sendProviderMessage(TunnelMessage.reload(TunnelPayload.fromStore()).encoded()) { _ in }
            }
        } else {
            try await TunnelSwitch.turnOn(manager)
        }
        return .result(dialog: "FurkVPN: \(server.name)")
    }
}

/** For automations: "if FurkVPN is on…". */
@available(iOS 16.0, *)
struct VPNStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Статус VPN"
    static let description = IntentDescription("Подключён ли FurkVPN: «Да» или «Нет», для условий в быстрых командах.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let manager = try await TunnelSwitch.manager()
        let on = manager.connection.status == .connected
        var text = on ? "FurkVPN подключён" : "FurkVPN не подключён"
        if on, let server = Store.loadSubscription().flatMap({ Store.selectedEntry(in: $0) }) { text += " — " + server.displayName }
        return .result(value: on, dialog: "\(text)")
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
        AppShortcut(
            intent: ConnectToServerIntent(),
            phrases: ["Подключи \(.applicationName) к серверу", "Смени сервер \(.applicationName)"],
            shortTitle: "Подключить к серверу",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: VPNStatusIntent(),
            phrases: ["Подключён ли \(.applicationName)", "Статус \(.applicationName)"],
            shortTitle: "Статус VPN",
            systemImageName: "info.circle"
        )
    }
}
