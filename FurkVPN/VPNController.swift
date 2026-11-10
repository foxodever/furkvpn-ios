import Foundation
import NetworkExtension

/**
 * The packet tunnel extension inside this app. Its bundle id is read from the app itself: tools that
 * re-sign an IPA with another certificate often give the app and the extension new ids, and a profile
 * pointing at the old one fails right after "connecting".
 */
enum TunnelExtension {
    /** PlugIns/….appex of the packet tunnel. */
    static let bundleURL: URL? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for url in items where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            return url
        }
        return nil
    }()

    static let bundleId: String? = bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

    static var id: String { bundleId ?? (Bundle.main.bundleIdentifier ?? "com.furkvpn.app") + ".tunnel" }
}

/** The system VPN profile of FurkVPN and its tunnel: connect, disconnect, status, messages to the extension. */
@MainActor
final class VPNController: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected(since: Date), stopping
    }

    @Published private(set) var state: State = .idle
    /** The last start of the tunnel, to tell its error from older ones. */
    private(set) var startedAt = Date.distantPast
    var onError: ((String) -> Void)?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    /** A server or settings change while connecting: the start may have read the old ones. */
    private var reloadWhenConnected = false
    /** Why the last connection ended, as iOS tells it (Settings → Диагностика). */
    @Published private(set) var lastError: String?
    /** Disconnect pressed in the app: no error to look for. */
    private var userStopped = false
    /** A reload the extension didn't get: connect again once the tunnel is down. */
    private var connectWhenStopped = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.update(connection) }
        }
        #if DEMO
        if Demo.on {
            if Demo.connected { state = .connected(since: Date().addingTimeInterval(-754)) }
            return
        }
        #endif
        Task { await load() }
    }

    private func load() async {
        // Only this app's profiles come back; one made by an earlier build may point at an old extension id
        // (preparedManager fixes that on the next connect).
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelExtension.id }
            ?? managers.first
        if let connection = manager?.connection { update(connection) }
    }

    private func update(_ connection: NEVPNConnection) {
        guard connection === manager?.connection else { return }
        let previous = state
        switch connection.status {
        case .connected: state = .connected(since: connection.connectedDate ?? Date())
        case .connecting, .reasserting: state = .connecting
        case .disconnecting: state = .stopping
        default: state = .idle
        }
        if state == .idle, previous != .idle {
            if !userStopped { reportDisconnect(connection) }
            userStopped = false
            if connectWhenStopped {
                connectWhenStopped = false
                Task { await connect() }
            }
        }
        if case .connected = state, reloadWhenConnected {
            reloadWhenConnected = false
            Task { _ = await send(.reload(TunnelPayload.fromStore())) }
        }
        if state == .idle { reloadWhenConnected = false }
    }

    /**
     * The tunnel stopped by itself (at the start or later, e.g. the extension was killed): the
     * extension's message (shared files) or, from iOS 16, what iOS says — it also carries the
     * extension's error when there is no shared App Group. Nothing for a clean stop.
     */
    private func reportDisconnect(_ connection: NEVPNConnection) {
        let started = startedAt
        startedAt = .distantPast
        if Date().timeIntervalSince(started) < 60, let message = Store.tunnelError(since: started) {
            lastError = message
            onError?(message)
            return
        }
        guard #available(iOS 16.0, *) else { return }
        connection.fetchLastDisconnectError { error in
            guard let error = error as NSError? else { return }
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            let message = [error.localizedDescription, underlying].compactMap { $0 }.joined(separator: " — ")
            Task { @MainActor in
                self.lastError = message
                self.onError?(message)
            }
        }
    }

    /** Creates the VPN profile on first use: iOS asks the user to allow it. */
    private func preparedManager(_ payload: TunnelPayload?) async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelExtension.id
        // For starts without the app (Shortcuts, the VPN switch in Settings) when there is no shared App Group.
        if let payload { proto.providerConfiguration = [TunnelPayload.key: payload.encoded()] }
        proto.serverAddress = "FurkVPN"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FurkVPN"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // A freshly saved profile has to be loaded again before it can start.
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    func connect() async {
        do {
            let payload = TunnelPayload.fromStore()
            let manager = try await preparedManager(payload)
            startedAt = Date()
            lastError = nil
            Store.setTunnelError(nil)
            state = .connecting
            // The server's config goes with the start: the extension needs no shared files.
            var options: [String: NSObject] = [:]
            if let payload { options[TunnelPayload.key] = payload.encoded() as NSData }
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            state = .idle
            let nsError = error as NSError
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                onError?("Разрешите FurkVPN создать VPN-подключение, чтобы подключиться")
            } else {
                onError?(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        userStopped = true
        manager?.connection.stopVPNTunnel()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /** Connected or on the way there: a change of server or settings has to reach the tunnel. */
    var isActive: Bool { isConnected || state == .connecting }

    /** Sends a message to the running extension; nil when it is not running or did not answer. */
    func send(_ message: TunnelMessage) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message.encoded()) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /** Like [send], with why there was no answer (Settings → Диагностика). */
    func sendExplained(_ message: TunnelMessage) async -> (Data?, String) {
        guard let session = manager?.connection as? NETunnelProviderSession else { return (nil, "нет VPN-профиля") }
        guard session.status == .connected else { return (nil, "VPN не подключён (статус \(session.status.rawValue))") }
        let started = Date()
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message.encoded()) { data in
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    continuation.resume(returning: (data, data == nil ? "расширение ответило пустым через \(seconds) с" : ""))
                }
            } catch {
                continuation.resume(returning: (nil, "не отправилось: \(error.localizedDescription)"))
            }
        }
    }

    func stats() async -> TunnelStats? {
        #if DEMO
        if Demo.on { return Demo.stats }
        #endif
        guard let data = await send(.stats) else { return nil }
        return try? JSONDecoder().decode(TunnelStats.self, from: data)
    }

    /**
     * Asks the extension to start the core again with the selected server and settings. While still
     * connecting it waits for the connection: the start may have read the previous server.
     */
    func reload() async {
        if state == .connecting {
            reloadWhenConnected = true
            return
        }
        if await send(.reload(TunnelPayload.fromStore())) == nil, isConnected {
            // Some re-signed builds never get app messages through to the extension: reconnect instead.
            connectWhenStopped = true
            userStopped = true
            manager?.connection.stopVPNTunnel()
        }
    }

    // MARK: Diagnostics

    /** Asks iOS again why the last connection ended (the app may have slept through the change). */
    func refreshLastError() async {
        guard #available(iOS 16.0, *), let connection = manager?.connection else { return }
        let message: String? = await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                guard let error = error as NSError? else {
                    continuation.resume(returning: nil)
                    return
                }
                let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
                continuation.resume(returning: [error.localizedDescription, underlying].compactMap { $0 }.joined(separator: " — "))
            }
        }
        if let message { lastError = message }
    }

    /** What Settings → Диагностика shows: where the VPN can break on a re-signed build. */
    var diagnostics: [(String, String)] {
        let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol
        let status: String
        switch manager?.connection.status {
        case nil: status = "профиля нет — создаётся первым подключением"
        case .invalid?: status = "профиль недействителен"
        case .disconnected?: status = "отключён"
        case .connecting?: status = "подключается"
        case .connected?: status = "подключён"
        case .reasserting?: status = "переподключается"
        case .disconnecting?: status = "отключается"
        default: status = "неизвестно"
        }
        return [
            ("Приложение", Bundle.main.bundleIdentifier ?? "—"),
            ("Расширение VPN", TunnelExtension.bundleId ?? "не найдено в приложении"),
            ("Профиль указывает на", proto?.providerBundleIdentifier ?? "—"),
            ("Профиль VPN", status + (manager?.isEnabled == false ? ", выключен" : "")),
            ("App Group", Store.groupId ?? "нет — сервер передаётся при подключении"),
            ("Последняя ошибка", lastError ?? Store.tunnelError(since: .distantPast) ?? "—"),
            ("Подпись приложения", SignatureReport.app),
            ("Подпись расширения", SignatureReport.tunnel),
            ("Профиль подписи приложения", SignatureReport.appProfile),
            ("Профиль подписи расширения", SignatureReport.tunnelProfile),
        ]
    }

    /** For Shortcuts and Siri: connected or connecting turns off, otherwise on. */
    func toggle() async {
        if isActive { disconnect() } else { await connect() }
    }
}
