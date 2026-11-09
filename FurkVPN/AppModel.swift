import Foundation
import SwiftUI

enum Ping: Equatable {
    case testing
    case ok(Int64)
    case failed
}

/** At most [limit] tasks at once; waiters go in order. */
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/** State of the app's screens: subscription, account, servers and their pings, settings. */
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: RemoteConfig
    @Published private(set) var subscription: SubscriptionInfo?
    @Published private(set) var account: AccountStatus?
    @Published private(set) var selectedKey: String?
    @Published private(set) var pings: [String: Ping] = [:]
    @Published private(set) var pinging = false
    @Published private(set) var importing = false
    @Published private(set) var refreshing = false
    @Published var keyError: String?
    @Published var pendingReplace: Core.Key?
    /** Code of the TV that asked for this phone's key; the alert confirms sending it. */
    @Published var tvSend: String?
    @Published var toast: String?
    @Published var routing: RoutingSettings {
        didSet {
            guard routing != oldValue else { return }
            Store.routing = routing
            scheduleReload()
        }
    }
    @Published var subscriptionUpdateHours: Int {
        didSet { Store.subscriptionUpdateHours = subscriptionUpdateHours }
    }

    let vpn = VPNController()
    private var configFetchedAt = Date.distantPast
    private var resumedBefore = false
    private var lastResume = Date.distantPast
    private var reloadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /** Imports and refreshes of the subscription, one after another: a refresh never overwrites a new key. */
    private var subscriptionQueue: Task<Void, Never>?

    init() {
        config = Store.loadRemoteConfig()?.sanitized() ?? RemoteConfig()
        subscription = Store.loadSubscription()
        account = Store.loadAccount()
        selectedKey = Store.selectedServer
        routing = Store.routing
        subscriptionUpdateHours = Store.subscriptionUpdateHours
        vpn.onError = { [weak self] message in self?.show("Ошибка подключения: \(message)") }
        #if DEMO
        if Demo.on {
            config = Demo.config
            configFetchedAt = Date()
            resumedBefore = true
            lastResume = Date().addingTimeInterval(3600)
            subscription = Demo.welcome ? nil : Demo.subscription
            account = Demo.welcome ? nil : Demo.account
            pings = Demo.pings
            selectedKey = Demo.subscription.servers.first?.key
        }
        #endif
    }

    var selectedServer: ServerEntry? {
        guard let list = subscription?.selectable else { return nil }
        return list.first { $0.key == selectedKey } ?? list.first
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Refreshing

    /** Called whenever the app comes to the foreground, the first time right after start. */
    func onResume() {
        // The start and the first "active" come together: once is enough.
        guard Date().timeIntervalSince(lastResume) > 2 else { return }
        lastResume = Date()
        let coldStart = !resumedBefore
        resumedBefore = true
        Task {
            // On start the config is always fetched again; later only when older than an hour.
            if coldStart || Date().timeIntervalSince(configFetchedAt) > 3600 { await refreshConfig() }
            guard let info = subscription else { return }
            await refreshAccount(info.url)
            try? await enqueue { [weak self] in
                guard let self, let current = self.subscription, self.isStale(current) else { return }
                try await self.refreshNow()
            }
        }
    }

    func refreshConfig() async {
        guard let url = URL(string: Http.apiBase + "/api/v1/config"),
              let answer = try? await Http.get(url), (200..<300).contains(answer.1.statusCode),
              let decoded = try? JSONDecoder().decode(RemoteConfig.self, from: answer.0) else { return }
        config = decoded.sanitized()
        configFetchedAt = Date()
        Store.saveRemoteConfig(config)
    }

    private func refreshAccount(_ subscriptionUrl: String, force: Bool = false) async {
        if !force, let fetched = account?.fetchedAt, Date().timeIntervalSince(fetched) < 600 { return }
        guard let url = URL(string: Http.apiBase + "/api/v1/subscription/status"),
              let data = try? await Http.postJSON(url, body: ["url": subscriptionUrl]),
              var status = try? JSONDecoder().decode(AccountStatus.self, from: data),
              subscription?.url == subscriptionUrl else { return }
        status.fetchedAt = Date()
        account = status
        Store.saveAccount(status)
    }

    private func isStale(_ info: SubscriptionInfo) -> Bool {
        let setting = subscriptionUpdateHours
        if setting == UpdateInterval.manual { return false }
        let hours = setting == UpdateInterval.fromSubscription ? (info.updateIntervalHours ?? 6) : setting
        return Date().timeIntervalSince(info.fetchedAt) > Double(min(max(hours, 1), 48)) * 3600
    }

    /** Runs [operation] after the imports and refreshes queued before it; rethrows its error. */
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = subscriptionQueue
        let task = Task { @MainActor () -> Error? in
            await previous?.value
            do {
                try await operation()
                return nil
            } catch {
                return error
            }
        }
        subscriptionQueue = Task { _ = await task.value }
        if let error = await task.value { throw error }
    }

    // MARK: Keys

    func submitKey(_ text: String?) {
        guard !importing else { return }
        // The QR code of a TV (scanned here or opened from the camera app): send it our key.
        if let code = Core.tvCode(text) {
            if subscription == nil {
                keyError = "Это QR-код телевизора. Сначала добавьте ключ на этом телефоне, а потом отсканируйте код ещё раз"
            } else {
                tvSend = code
            }
            return
        }
        switch Core.parseKey(text, allowedHosts: config.allowedSubscriptionHosts) {
        case .empty: keyError = "В буфере обмена пусто. Скопируйте ключ и попробуйте снова."
        case .notALink: keyError = "Это не похоже на ключ. Скопируйте ссылку целиком — она начинается с https://"
        case .foreign: keyError = "Это не ключ FurkVPN. В приложение можно добавить только ключ FurkVPN."
        case let .ok(key):
            if let current = subscription {
                if current.url == key.url {
                    refreshSubscription(showMessage: true)
                } else {
                    pendingReplace = key
                }
            } else {
                importKey(key)
            }
        }
    }

    func confirmReplace() {
        guard let key = pendingReplace else { return }
        pendingReplace = nil
        importKey(key)
    }

    private func importKey(_ key: Core.Key) {
        importing = true
        Task {
            defer { importing = false }
            do {
                try await enqueue { [weak self] in
                    guard let self else { return }
                    let wasActive = self.vpn.isActive
                    let downloaded = try await SubscriptionLoader.download(key, config: self.config)
                    let info = SubscriptionLoader.info(for: key, downloaded)
                    Store.saveSubscription(info, configs: downloaded.configs)
                    Store.clearAccount()
                    self.subscription = info
                    self.account = nil
                    self.pings = [:]
                    self.select(info.selectable.first?.key, reconnect: false)
                    self.show("Ключ добавлен")
                    if wasActive { await self.vpn.reload() }
                }
                await refreshAccount(key.url, force: true)
            } catch {
                keyError = (error as? LocalizedError)?.errorDescription ?? SubscriptionError.network(error).errorDescription
            }
        }
    }

    /** Re-downloads the current subscription; keeps the old copy on failure. Run it through [enqueue]. */
    private func refreshNow() async throws {
        // Read in the queue: an import or logout queued before may have replaced the key.
        guard let current = subscription else { return }
        // The key's domain is no longer allowed: an error, not a silent "updated".
        guard case let .ok(key) = Core.parseKey(current.url, allowedHosts: config.allowedSubscriptionHosts) else {
            throw SubscriptionError.foreign
        }
        refreshing = true
        defer { refreshing = false }
        let downloaded = try await SubscriptionLoader.download(key, config: config)
        let info = SubscriptionLoader.info(for: key, downloaded)
        let oldConfig = selectedServer.flatMap { Store.config(for: $0.key) }
        Store.saveSubscription(info, configs: downloaded.configs)
        subscription = info
        // The tunnel is rebuilt when the selected server's config changed.
        if vpn.isActive, let server = selectedServer, Store.config(for: server.key) != oldConfig { await vpn.reload() }
    }

    func refreshSubscription(showMessage: Bool) {
        Task {
            do {
                try await enqueue { [weak self] in try await self?.refreshNow() }
                if let url = subscription?.url { await refreshAccount(url, force: true) }
                if showMessage { show("Подписка обновлена") }
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить подписку.")
            }
        }
    }

    func logout() {
        vpn.disconnect()
        Task {
            try? await enqueue { [weak self] in
                guard let self else { return }
                Store.clearSubscription()
                self.subscription = nil
                self.account = nil
                self.selectedKey = nil
                self.pings = [:]
            }
        }
    }

    // MARK: TV

    func confirmTvSend() {
        guard let code = tvSend, let key = subscription?.url else { return }
        tvSend = nil
        Task {
            var status = 0
            if let url = URL(string: Http.apiBase + "/api/v1/tv/send") {
                status = (try? await Http.post(url, body: ["code": code, "key": key])) ?? 0
            }
            switch status {
            case 200: show("Ключ отправлен — телевизор подключится сам")
            case 404: show("Код устарел. Отсканируйте новый QR-код с экрана телевизора")
            case 400: show("Это не ключ FurkVPN. В приложение можно добавить только ключ FurkVPN.")
            case 429: show("Слишком много попыток. Подождите минуту")
            default: show("Не удалось отправить ключ. Проверьте интернет")
            }
        }
    }

    // MARK: Servers

    func select(_ key: String?, reconnect: Bool = true) {
        selectedKey = key
        Store.selectedServer = key
        if reconnect, vpn.isActive { Task { await vpn.reload() } }
    }

    /** Settings changed while connected: rebuild the tunnel once they settle. */
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, vpn.isActive else { return }
            await vpn.reload()
        }
    }

    private var pingTask: Task<Void, Never>?
    private var pingRun = 0
    /** Shared by restarted runs: a cancelled run's measurements keep their slot until they finish. */
    private let pingLimit = AsyncLimiter(6)
    /** Servers whose ping is being measured right now. Queued ones aren't here. */
    private var measuring = Set<String>()

    /** Pressed again while pinging: starts over, like Happ. */
    func testPings() {
        guard let info = subscription else { return }
        pingTask?.cancel()
        pingRun += 1
        let run = pingRun
        let servers = info.servers.filter(\.pingable)
        pinging = true
        for s in servers { pings[s.key] = .testing }
        pingTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for entry in servers {
                    group.addTask { @MainActor in
                        await self.pingLimit.acquire()
                        // Already pinged by a long press, or still being measured (it will report).
                        if !Task.isCancelled, self.pings[entry.key] == .testing, !self.measuring.contains(entry.key) {
                            await self.measure(entry)
                        }
                        await self.pingLimit.release()
                    }
                }
            }
            if run == pingRun { pinging = false }
        }
    }

    /** Long press on a server or auto-select: ping just this one, also when it waits in the "ping all" queue. */
    func pingServer(_ entry: ServerEntry) {
        guard entry.pingable, !measuring.contains(entry.key) else { return }
        pings[entry.key] = .testing
        Task { await measure(entry) }
    }

    /** The core can't be interrupted: a started measurement reports even if its run was restarted. */
    private func measure(_ entry: ServerEntry) async {
        measuring.insert(entry.key)
        defer { measuring.remove(entry.key) }
        let url = config.delayTestUrl
        var ms: Int64?
        if vpn.isConnected {
            // The app's own connections go through the tunnel; the extension's ones go straight to the server.
            if let data = await vpn.send(.ping(serverKey: entry.key, url: url, config: Store.config(for: entry.key))),
               let answer = try? JSONDecoder().decode(TunnelPing.self, from: data) {
                ms = answer.ms
            }
        } else if let raw = Store.config(for: entry.key) {
            ms = await Task.detached(priority: .userInitiated) { Core.ping(config: raw, url: url) }.value
        }
        pings[entry.key] = ms.map(Ping.ok) ?? .failed
    }

    // MARK: Routing

    func addRoutingRules(_ entries: [String], to action: RouteAction) {
        routing.add(entries, to: action)
    }

    func removeRoutingRule(_ entry: String, from action: RouteAction) {
        routing.setRules(action, routing.rules(action).filter { $0 != entry })
    }

    func clearRoutingRules(_ action: RouteAction) {
        routing.setRules(action, [])
    }

    // MARK: Links

    var renewUrl: URL? {
        if let id = subscription?.shortId, !id.isEmpty { return URL(string: config.site.renewalUrl(id)) }
        return URL(string: config.renewUrl)
    }
}
