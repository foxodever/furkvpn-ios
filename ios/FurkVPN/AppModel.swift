import Foundation
import SwiftUI

enum Ping: Equatable {
    case testing
    case ok(Int64)
    case failed
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
    private var reloadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init() {
        config = Store.loadRemoteConfig()?.sanitized() ?? RemoteConfig()
        subscription = Store.loadSubscription()
        account = Store.loadAccount()
        selectedKey = Store.selectedServer
        routing = Store.routing
        subscriptionUpdateHours = Store.subscriptionUpdateHours
        vpn.onError = { [weak self] message in self?.show("Ошибка подключения: \(message)") }
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

    /** Called when the app comes to the foreground: refresh what is outdated. */
    func onResume() {
        Task {
            if Date().timeIntervalSince(configFetchedAt) > 3600 { await refreshConfig() }
            guard let info = subscription else { return }
            await refreshAccount(info.url)
            if isStale(info) { try? await refreshSubscriptionNow() }
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
              var status = try? JSONDecoder().decode(AccountStatus.self, from: data) else { return }
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

    // MARK: Keys

    func submitKey(_ text: String?) {
        guard !importing else { return }
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
                let wasConnected = vpn.isConnected
                let downloaded = try await SubscriptionLoader.download(key, config: config)
                let info = SubscriptionLoader.info(for: key, downloaded)
                Store.saveSubscription(info, configs: downloaded.configs)
                Store.clearAccount()
                subscription = info
                account = nil
                pings = [:]
                select(info.selectable.first?.key, reconnect: false)
                show("Ключ добавлен")
                await refreshAccount(key.url, force: true)
                if wasConnected { await vpn.reload() }
            } catch {
                keyError = (error as? LocalizedError)?.errorDescription ?? SubscriptionError.network(error).errorDescription
            }
        }
    }

    /** Re-downloads the current subscription; keeps the old copy on failure. */
    private func refreshSubscriptionNow() async throws {
        guard let current = subscription,
              case let .ok(key) = Core.parseKey(current.url, allowedHosts: config.allowedSubscriptionHosts) else { return }
        refreshing = true
        defer { refreshing = false }
        let downloaded = try await SubscriptionLoader.download(key, config: config)
        let info = SubscriptionLoader.info(for: key, downloaded)
        let oldConfig = selectedServer.flatMap { Store.config(for: $0.key) }
        Store.saveSubscription(info, configs: downloaded.configs)
        subscription = info
        // The tunnel is rebuilt when the selected server's config changed.
        if vpn.isConnected, let server = selectedServer, Store.config(for: server.key) != oldConfig { await vpn.reload() }
    }

    func refreshSubscription(showMessage: Bool) {
        Task {
            do {
                try await refreshSubscriptionNow()
                if let url = subscription?.url { await refreshAccount(url, force: true) }
                if showMessage { show("Подписка обновлена") }
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить подписку.")
            }
        }
    }

    func logout() {
        vpn.disconnect()
        Store.clearSubscription()
        subscription = nil
        account = nil
        selectedKey = nil
        pings = [:]
    }

    // MARK: Servers

    func select(_ key: String?, reconnect: Bool = true) {
        selectedKey = key
        Store.selectedServer = key
        if reconnect, vpn.isConnected { Task { await vpn.reload() } }
    }

    /** Settings changed while connected: rebuild the tunnel once they settle. */
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, vpn.isConnected else { return }
            await vpn.reload()
        }
    }

    private func measure(_ entry: ServerEntry) async -> Int64? {
        let url = config.delayTestUrl
        if vpn.isConnected {
            // The app's own connections go through the tunnel; the extension's ones go straight to the server.
            guard let data = await vpn.send(.ping(serverKey: entry.key, url: url)),
                  let answer = try? JSONDecoder().decode(TunnelPing.self, from: data) else { return nil }
            return answer.ms
        }
        guard let raw = Store.config(for: entry.key) else { return nil }
        return await Task.detached(priority: .userInitiated) { Core.ping(config: raw, url: url) }.value
    }

    func testPings() {
        guard !pinging, let info = subscription else { return }
        let servers = info.servers.filter(\.pingable)
        pinging = true
        for s in servers { pings[s.key] = .testing }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var queued = servers[...]
                // Six at a time, like the Android app.
                func addNext() {
                    guard let entry = queued.popFirst() else { return }
                    group.addTask { @MainActor in
                        let ms = await self.measure(entry)
                        self.pings[entry.key] = ms.map(Ping.ok) ?? .failed
                    }
                }
                for _ in 0..<6 { addNext() }
                while await group.next() != nil { addNext() }
            }
            pinging = false
        }
    }

    /** Long press on a server or auto-select: ping just this one. */
    func pingServer(_ entry: ServerEntry) {
        guard entry.pingable, pings[entry.key] != .testing else { return }
        pings[entry.key] = .testing
        Task {
            let ms = await measure(entry)
            pings[entry.key] = ms.map(Ping.ok) ?? .failed
        }
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
