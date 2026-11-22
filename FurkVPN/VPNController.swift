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

/**
 * Settings → «Уведомления через VPN» (on by default): the tunnel takes every connection of the phone
 * (includeAllNetworks), Apple's push notifications among them (excludeAPNs off). Without it iOS keeps them —
 * like some other services of its own — outside any VPN, and where the operator cuts Apple's servers (white
 * lists) the notifications of Telegram and every other app stop coming. As in Happ and Incy. The operator's
 * calls and texts, AirDrop, CarPlay and the Watch stay outside (the system's defaults), and the local network
 * with «Локальная сеть напрямую» (excludeLocalNetworks). What else changes: iOS no longer keeps the addresses
 * out of the tunnel's routes outside it — the app's pings go through the extension's ping bridge
 * (core/libxray/pingbridge.go) — and while the tunnel is down but on (connecting, reconnecting) the phone has
 * no network at all. A profile change applies to the next start of the tunnel.
 */
enum AllNetworks {
    /**
     * iOS 16.4+ (excludeAPNs), not on a Mac, and only in a build signed by Furry LLC (the App Group is ours):
     * the extension of a re-signed IPA isn't taken for the tunnel's provider (compatibility mode lives on the
     * routes left out of the tunnel), and with every connection in the tunnel nothing of it would get out.
     */
    static var available: Bool {
        #if targetEnvironment(macCatalyst) || os(tvOS)
        return false
        #else
        guard !Platform.isMac, Store.groupId == "group.com.furkvpn.app" else { return false }
        if #available(iOS 16.4, *) { return true }
        return false
        #endif
    }

    static var on: Bool { available && Store.pushThroughVPN }

    private static var lanDirect: Bool { Store.routing.enabled && Store.routing.lanDirect }

    /** The profile isn't as the settings say (a tunnel started with it runs without them). */
    static func outdated(_ proto: NETunnelProviderProtocol) -> Bool {
        #if targetEnvironment(macCatalyst) || os(tvOS)
        return false
        #else
        return proto.includeAllNetworks != on || (on && proto.excludeLocalNetworks != lanDirect)
        #endif
    }

    static func apply(_ proto: NETunnelProviderProtocol) {
        #if !targetEnvironment(macCatalyst) && !os(tvOS)
        let on = self.on
        proto.includeAllNetworks = on
        proto.excludeLocalNetworks = on && lanDirect
        if #available(iOS 16.4, *) { proto.excludeAPNs = !on }
        #endif
    }

    /** Settings → Диагностика. */
    static func describe(_ proto: NETunnelProviderProtocol?) -> String {
        #if os(tvOS)
        return "нет на Apple TV"
        #elseif targetEnvironment(macCatalyst)
        return "нет на Mac"
        #else
        guard available else { return "недоступно в этой сборке или версии iOS" }
        guard let proto else { return "профиля нет" }
        let now = proto.includeAllNetworks ? "весь трафик в туннеле, уведомления Apple через VPN" : "выключено"
        return outdated(proto) ? now + " (изменится при следующем подключении)" : now
        #endif
    }
}

/** Resumes a continuation once: with the extension's answer, or with what stands for none when it didn't come in time. */
private final class PendingAnswer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
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
    /** A connect is saving the profile (iOS may be asking to allow it): a second press waits for it. */
    private var starting = false
    /** Logout is removing VPN profiles: blocks new connects until cleanup completes. */
    private var clearing = false
    /** Incremented by disconnect/logout so an in-flight preparedManager() cannot start a stale tunnel. */
    private var startEpoch = 0
    private var startTask: Task<Void, Never>?
    private var declineTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

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
        loadTask = Task { await load() }
    }

    /** Returns once the VPN profile has been read: until then [state] is idle whatever the VPN does. */
    func loaded() async {
        await loadTask?.value
    }

    private func load() async {
        // Only this app's profiles come back; one made by an earlier build may point at an old extension id
        // (preparedManager fixes that on the next connect).
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelExtension.id }
            ?? managers.first
        if let connection = manager?.connection { update(connection) }
        if Store.consentDeclined {
            disableForConsentDecline()
            return
        }
        // «Уведомления через VPN» for starts without the app too (Shortcuts, Settings, on demand): a profile
        // saved by an earlier build gets it now. A tunnel that is up keeps running as it is.
        if !isActive, state != .stopping { await saveProfileSettings() }
    }

    /** The profile as the settings say, when it isn't yet. Only with the tunnel down: a change needs a new start anyway. */
    private func saveProfileSettings() async {
        guard let manager, let proto = manager.protocolConfiguration as? NETunnelProviderProtocol, AllNetworks.outdated(proto) else { return }
        AllNetworks.apply(proto)
        manager.protocolConfiguration = proto
        try? await manager.saveToPreferences()
        try? await manager.loadFromPreferences()
    }

    /** Settings → «Уведомления через VPN» changed: into the profile now, and a running tunnel starts again with it. */
    func profileSettingsChanged() async {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol, AllNetworks.outdated(proto) else { return }
        if isActive {
            reconnect()
        } else if state == .idle {
            await saveProfileSettings()
        }
    }

    /** Off and on again (the next start saves the profile with the current settings). */
    private func reconnect() {
        connectWhenStopped = true
        stopTunnel(clearReconnect: false)
    }

    /** The status as iOS has it now: a change may have passed while the app was not running (a Mac asleep). */
    func resync() {
        // Not in the middle of a connect or logout: iOS has not heard of it yet, and the screen would fall back to "off".
        guard !starting, !clearing, Date().timeIntervalSince(startedAt) > 15 else { return }
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
            } else if !clearing {
                Task { await syncStoredPayload() }
            }
        }
        if case .connected = state, reloadWhenConnected {
            reloadWhenConnected = false
            Task { await self.reload() }
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

    /**
     * Settings → «Переподключаться автоматически»: an on-demand rule that has iOS start the tunnel again
     * whenever it is down (killed, a network change) until the user turns the VPN off. Not for debug mode:
     * its self-test stops the tunnel on purpose.
     */
    nonisolated static func applyOnDemand(_ manager: NETunnelProviderManager, on: Bool) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = on
    }

    /** Creates the VPN profile on first use: iOS asks the user to allow it. */
    private func preparedManager(_ payload: TunnelPayload?) async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelExtension.id
        // For starts without the app (Shortcuts, the VPN switch in Settings) when there is no shared App Group;
        // they never run the self-test of debug mode.
        if var payload {
            payload.debugMode = nil
            proto.providerConfiguration = [TunnelPayload.key: payload.encoded()]
        }
        proto.serverAddress = "FurkVPN"
        AllNetworks.apply(proto)
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FurkVPN"
        manager.isEnabled = true
        Self.applyOnDemand(manager, on: Store.autoReconnect && payload?.debugMode != true)
        try await manager.saveToPreferences()
        // A freshly saved profile has to be loaded again before it can start.
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    func connect() async {
        // Pressed twice on the first connection, each press made a VPN profile of its own.
        guard !starting, !clearing, Store.consentGiven, Store.loadSubscription() != nil else { return }
        starting = true
        startEpoch += 1
        let epoch = startEpoch
        // Capture synchronously before assigning startTask so earlier and later tasks form a strict DAG.
        let pendingDecline = declineTask
        let pendingSync = syncTask
        let task = Task { @MainActor in
            defer {
                self.starting = false
                self.startTask = nil
            }
            userStopped = false
            do {
                if let pendingDecline { await pendingDecline.value }
                if let pendingSync { await pendingSync.value }
                guard epoch == self.startEpoch, Store.consentGiven, Store.loadSubscription() != nil else { return }
                // Never in the App Store's copy: a TestFlight build's switch may still be on after the update.
                let debug = Store.debugMode && !Platform.fromAppStore
                // Debug mode is for this one connection: its self-test ends it anyway.
                Store.debugMode = false
                guard var savedPayload = TunnelPayload.fromStore(debug: debug) else {
                    onError?("Нет данных сервера: обновите подписку и попробуйте снова")
                    return
                }
                var manager = try await preparedManager(savedPayload)
                // Re-read after every suspending save in case key, server or routing changed mid-flight.
                while true {
                    guard epoch == self.startEpoch, Store.consentGiven else { return }
                    guard let latest = TunnelPayload.fromStore(debug: debug) else {
                        onError?("Нет данных сервера: обновите подписку и попробуйте снова")
                        return
                    }
                    if latest == savedPayload { break }
                    savedPayload = latest
                    manager = try await preparedManager(savedPayload)
                }
                startedAt = Date()
                lastError = nil
                Store.setTunnelError(nil)
                state = .connecting
                // The server's config goes with the start: the extension needs no shared files.
                let options: [String: NSObject] = [TunnelPayload.key: savedPayload.encoded() as NSData]
                try manager.connection.startVPNTunnel(options: options)
            } catch {
                guard epoch == self.startEpoch else { return }
                state = .idle
                let nsError = error as NSError
                if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                    onError?("Разрешите FurkVPN создать VPN-подключение, чтобы подключиться")
                } else {
                    onError?(error.localizedDescription)
                }
            }
        }
        startTask = task
        await task.value
    }

    /**
     * The user's own stop: nothing brings the VPN back after it. A reconnect waiting for the tunnel to go down
     * (a reload the extension didn't answer) used to start it again right after "Отключиться".
     */
    func disconnect() {
        stopTunnel(clearReconnect: true)
    }

    private func stopTunnel(clearReconnect: Bool) {
        startEpoch += 1
        let epoch = startEpoch
        if clearReconnect { connectWhenStopped = false }
        // With nothing running there is no stop to come, and the flag would hide the next connection's error.
        userStopped = state != .idle
        Task {
            await loaded()
            guard epoch == self.startEpoch, let manager else { return }
            if state != .idle { userStopped = true }
            // Shortcuts and the Control Center button save the profile through their own copy of it: this one
            // may not know that their start turned auto-reconnect on, and iOS would bring the VPN right back.
            try? await manager.loadFromPreferences()
            guard epoch == self.startEpoch else { return }
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try? await manager.saveToPreferences()
            }
            guard epoch == self.startEpoch else { return }
            manager.connection.stopVPNTunnel()
            // The tunnel may be down already and the app not told (a Mac that slept through it): the screen
            // said "connected" with nothing left to stop. What iOS says now is what the screen shows.
            update(manager.connection)
        }
    }

    /** Stops any tunnel, disables saved profiles and clears fallback payloads when consent is declined. */
    func disableForConsentDecline() {
        #if DEMO
        if Demo.on {
            state = .idle
            return
        }
        #endif
        startEpoch += 1
        let epoch = startEpoch
        connectWhenStopped = false
        reloadWhenConnected = false
        userStopped = state != .idle
        // Capture synchronously before assigning declineTask so earlier and later tasks form a strict DAG.
        let pendingStart = startTask
        let pendingSync = syncTask
        let previousDecline = declineTask
        declineTask = Task {
            if let previousDecline { await previousDecline.value }
            if let pendingStart { await pendingStart.value }
            if let pendingSync { await pendingSync.value }
            await loaded()
            guard epoch == self.startEpoch, !Store.consentGiven else { return }
            var lastFailure: Error?
            let managers: [NETunnelProviderManager]
            do {
                managers = try await NETunnelProviderManager.loadAllFromPreferences()
            } catch {
                // Keep best-effort cleanup of the cached manager, but still surface enumeration failure.
                lastFailure = error
                managers = manager.map { [$0] } ?? []
            }
            for m in managers {
                guard epoch == self.startEpoch, !Store.consentGiven else { return }
                try? await m.loadFromPreferences()
                guard epoch == self.startEpoch, !Store.consentGiven else { return }
                if m.connection.status != .disconnected && m.connection.status != .invalid {
                    userStopped = true
                }
                m.isOnDemandEnabled = false
                m.isEnabled = false
                if let proto = m.protocolConfiguration as? NETunnelProviderProtocol {
                    proto.providerConfiguration = nil
                    m.protocolConfiguration = proto
                }
                do {
                    try await m.saveToPreferences()
                } catch {
                    // Fallback: remove the profile outright if disabling/wiping it fails.
                    do {
                        try await m.removeFromPreferences()
                        if m === manager { manager = nil }
                    } catch {
                        lastFailure = error
                    }
                }
                m.connection.stopVPNTunnel()
            }
            if let lastFailure, epoch == self.startEpoch, !Store.consentGiven {
                onError?("Не удалось выключить профиль VPN: \(lastFailure.localizedDescription)")
            }
        }
    }

    /** Keeps the saved profile's fallback payload (and enabled flag) current across key, server or routing changes. */
    func syncStoredPayload() async {
        #if DEMO
        if Demo.on { return }
        #endif
        let previousSync = syncTask
        let pendingDecline = declineTask
        let epoch = startEpoch
        let task = Task { @MainActor in
            await previousSync?.value
            if let pendingDecline { await pendingDecline.value }
            await loaded()
            guard epoch == self.startEpoch, !starting, !clearing, Store.consentGiven, let manager else { return }
            try? await manager.loadFromPreferences()
            // Re-read the desired payload AFTER all suspensions so an older sync never writes a stale server.
            guard epoch == self.startEpoch, !starting, !clearing, Store.consentGiven,
                  let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  var payload = TunnelPayload.fromStore() else { return }
            payload.debugMode = nil
            let existing = TunnelPayload.decode(proto.providerConfiguration?[TunnelPayload.key] as? Data)
            let payloadDiffers = existing != payload
            let needsEnable = !manager.isEnabled
            guard payloadDiffers || needsEnable else { return }
            proto.providerConfiguration = [TunnelPayload.key: payload.encoded()]
            manager.protocolConfiguration = proto
            manager.isEnabled = true
            try? await manager.saveToPreferences()
            try? await manager.loadFromPreferences()
        }
        syncTask = task
        await task.value
    }

    /**
     * Stops the tunnel and removes the saved VPN profile (which stores the server payload in
     * providerConfiguration) so system VPN settings cannot reconnect after the user deletes the key.
     */
    func clearOnLogout() async throws {
        #if DEMO
        if Demo.on {
            state = .idle
            return
        }
        #endif
        clearing = true
        defer { clearing = false }
        startEpoch += 1
        connectWhenStopped = false
        reloadWhenConnected = false
        if let pendingDecline = declineTask {
            await pendingDecline.value
        }
        if let active = startTask {
            await active.value
        }
        if let pendingSync = syncTask {
            await pendingSync.value
        }
        await loaded()
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard !managers.isEmpty else {
            manager = nil
            state = .idle
            return
        }
        userStopped = state != .idle
        var lastFailure: Error?
        for m in managers {
            try? await m.loadFromPreferences()
            if m.isOnDemandEnabled {
                m.isOnDemandEnabled = false
                try? await m.saveToPreferences()
            }
            m.connection.stopVPNTunnel()
            do {
                try await m.removeFromPreferences()
            } catch {
                // Fallback: clear stored server credentials even if profile removal itself fails.
                if let proto = m.protocolConfiguration as? NETunnelProviderProtocol {
                    proto.providerConfiguration = nil
                    m.protocolConfiguration = proto
                    m.isEnabled = false
                    do {
                        try await m.saveToPreferences()
                    } catch {
                        lastFailure = error
                    }
                } else {
                    lastFailure = error
                }
            }
        }
        if let lastFailure { throw lastFailure }
        manager = nil
        state = .idle
    }

    /** Settings → «Переподключаться автоматически» changed: a connected VPN keeps it from now on, otherwise from the next connection. */
    func setAutoReconnect(_ on: Bool) async {
        Store.autoReconnect = on
        guard let manager, isActive else { return }
        Self.applyOnDemand(manager, on: on)
        try? await manager.saveToPreferences()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /** Connected or on the way there: a change of server or settings has to reach the tunnel. */
    var isActive: Bool { isConnected || state == .connecting }

    /**
     * Sends a message to the running extension; nil when it is not running or did not answer in [timeout]
     * seconds. iOS doesn't always call back when the extension dies or hangs with a message, and whoever
     * waited for the answer (a subscription update and everything queued behind it, the speed on the main
     * screen) would wait forever.
     */
    func send(_ message: TunnelMessage, timeout: TimeInterval = 30) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let answer = PendingAnswer(continuation)
            do {
                try session.sendProviderMessage(message.encoded()) { answer.resume($0) }
            } catch {
                answer.resume(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer.resume(nil) }
        }
    }

    /** Like [send], with why there was no answer (Settings → Диагностика). */
    func sendExplained(_ message: TunnelMessage) async -> (Data?, String) {
        guard let session = manager?.connection as? NETunnelProviderSession else { return (nil, "нет VPN-профиля") }
        guard session.status == .connected else { return (nil, "VPN не подключён (статус \(session.status.rawValue))") }
        let started = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String), Never>) in
            let answer = PendingAnswer(continuation)
            do {
                try session.sendProviderMessage(message.encoded()) { data in
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    answer.resume((data, data == nil ? "расширение ответило пустым через \(seconds) с" : ""))
                }
            } catch {
                answer.resume((nil, "не отправилось: \(error.localizedDescription)"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { answer.resume((nil, "расширение не ответило за 30 с")) }
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
        let epoch = startEpoch
        // «Локальная сеть напрямую» or «Уведомления через VPN» changed what the profile has to say: only a new
        // start of the tunnel takes it.
        if isActive, let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol, AllNetworks.outdated(proto) {
            reconnect()
            return
        }
        // Keep the saved profile's fallback payload aligned for non-App-Group builds even if the app closes next.
        await syncStoredPayload()
        guard epoch == self.startEpoch else { return }
        if state == .connecting {
            reloadWhenConnected = true
            return
        }
        if await send(.reload(TunnelPayload.fromStore())) == nil, epoch == self.startEpoch, isConnected {
            // Some re-signed builds never get app messages through to the extension: reconnect instead
            // (auto-reconnect off first, or iOS starts the tunnel again by itself, with the old server).
            reconnect()
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
            ("Уведомления через VPN", AllNetworks.describe(proto)),
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
