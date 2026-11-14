import Foundation
import SwiftUI
import UserNotifications

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
    @Published var serversOnLeft: Bool {
        didSet { Store.serversOnLeft = serversOnLeft }
    }
    /** The settings sheet; also opened from the menu (⌘, on a Mac or an iPad with a keyboard). */
    @Published var settingsOpen = false
    /** The latest white list check (the card on the main screen), by the app or by the extension. */
    @Published private(set) var whitelistCheck: WhitelistCheck?
    @Published private(set) var whitelistChecking = false
    /** Another app's VPN is on (ours is off): the app's check would go through it, so there is none. */
    @Published private(set) var otherVPN = false
    /** Settings → «Определять белые списки». */
    @Published var whitelistDetect: Bool {
        didSet {
            guard whitelistDetect != oldValue else { return }
            Store.whitelistDetect = whitelistDetect
            if whitelistDetect { checkWhitelist() }
            // The check's sites go in or out of the tunnel's routes.
            scheduleReload()
        }
    }
    /** Settings → «Уведомлять об отключении VPN» (the permission is asked when it is turned on). */
    @Published private(set) var notifyStops: Bool
    /** Settings → «Переподключаться автоматически». */
    @Published var autoReconnect: Bool {
        didSet {
            guard autoReconnect != oldValue else { return }
            let on = autoReconnect
            Task { await vpn.setAutoReconnect(on) }
        }
    }

    let vpn = VPNController()
    private var configFetchedAt = Date.distantPast
    private var resumedBefore = false
    private var lastResume = Date.distantPast
    private var reloadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /** Imports and refreshes of the subscription, one after another: a refresh never overwrites a new key. */
    private var subscriptionQueue: Task<Void, Never>?
    private var whitelistTask: Task<Void, Never>?
    /** An update the user asked for is queued or running: the next request waits for it to end. */
    private var refreshRequested = false
    /** The newest white list switch already told about. */
    private var toldSwitchAt = Date()
    private var sharedObserver: NSObjectProtocol?

    init() {
        config = Store.loadRemoteConfig()?.sanitized() ?? RemoteConfig()
        subscription = Store.loadSubscription()
        account = Store.loadAccount()
        selectedKey = Store.selectedServer
        routing = Store.routing
        subscriptionUpdateHours = Store.subscriptionUpdateHours
        serversOnLeft = Store.serversOnLeft
        whitelistDetect = Store.whitelistDetect
        whitelistCheck = Store.whitelistCheck
        notifyStops = Store.notifyStops
        autoReconnect = Store.autoReconnect
        vpn.onError = { [weak self] message in self?.show("Ошибка подключения: \(message)") }
        _ = PhysicalNetwork.shared // starts watching the network before the first ping
        // Operators turn white lists on for mobile data: a new network is worth a check.
        PhysicalNetwork.shared.onChange = { [weak self] in
            Task { @MainActor in self?.networkChanged() }
        }
        // The extension checked for white lists and maybe moved the server.
        SharedChange.observe()
        sharedObserver = NotificationCenter.default.addObserver(forName: SharedChange.local, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncShared() }
        }
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
            serversOnLeft = Demo.serversLeft
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
        syncShared()
        if Date().timeIntervalSince(whitelistCheck?.time ?? .distantPast) > 60 { checkWhitelist() }
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
                    // White lists are looked for afresh: a check made before this key had no server to move,
                    // and "on already" never moves one.
                    Store.whitelistCheck = nil
                    Store.whitelistAutoSwitched = nil
                    self.whitelistCheck = nil
                    self.show("Ключ добавлен")
                    if wasActive { await self.vpn.reload() }
                }
                checkWhitelist()
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
        // An update the user asked for keeps the button busy until its account refresh is done too.
        let requested = refreshing
        refreshing = true
        defer { refreshing = requested }
        let downloaded = try await SubscriptionLoader.download(key, config: config)
        let info = SubscriptionLoader.info(for: key, downloaded)
        let oldConfig = selectedServer.flatMap { Store.config(for: $0.key) }
        Store.saveSubscription(info, configs: downloaded.configs)
        subscription = info
        // The tunnel is rebuilt when the selected server's config changed.
        if vpn.isActive, let server = selectedServer, Store.config(for: server.key) != oldConfig { await vpn.reload() }
    }

    func refreshSubscription(showMessage: Bool) {
        Task { await refreshSubscriptionNow(showMessage: showMessage) }
    }

    /**
     * The update the user asked for (button, pull to refresh, menu); returns when it is done. Pressed again
     * meanwhile it does nothing: every update queued after another one rebuilt the tunnel again, and a pile
     * of them left it stuck "reconnecting".
     */
    func refreshSubscriptionNow(showMessage: Bool) async {
        guard !refreshRequested else { return }
        refreshRequested = true
        refreshing = true
        defer {
            refreshRequested = false
            refreshing = false
        }
        do {
            try await enqueue { [weak self] in try await self?.refreshNow() }
            if let url = subscription?.url { await refreshAccount(url, force: true) }
            if showMessage { show("Подписка обновлена") }
        } catch {
            show((error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить подписку.")
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
                self.whitelistCheck = nil
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

    // MARK: White lists

    /**
     * Checks for white lists now: without the VPN the app asks the sites itself; with it the extension does
     * (only it gets past its tunnel to them) and moves the server if it has to. Nothing while connecting.
     */
    func checkWhitelist() {
        guard whitelistDetect, whitelistTask == nil else { return }
        #if DEMO
        if Demo.on { return }
        #endif
        whitelistChecking = true
        whitelistTask = Task {
            defer {
                whitelistChecking = false
                whitelistTask = nil
            }
            // On a cold start the VPN's state is not known yet: ours, already on, would pass for somebody else's.
            await vpn.loaded()
            otherVPN = false
            if vpn.isConnected {
                guard let data = await vpn.send(.whitelist), let check = try? JSONDecoder().decode(WhitelistCheck.self, from: data) else { return }
                whitelistCheck = check
                syncShared()
            } else if vpn.state == .idle {
                // Sites through someone else's VPN all answer: no check, and no server switched on it.
                if !OtherVPN.interfaces().isEmpty {
                    otherVPN = true
                    return
                }
                let config = self.config.whitelist
                let network = PhysicalNetwork.shared.kind
                var check = await Task.detached(priority: .userInitiated) { Whitelist.check(config, network: network) }.value
                // The VPN came up meanwhile: the extension checks from now on.
                guard vpn.state == .idle else { return }
                if let target = Whitelist.apply(&check) {
                    selectedKey = target.key
                    toldSwitchAt = check.time
                    show(check.status == .whitelist ? "Включены белые списки — переключили на \(target.displayName)"
                        : "Белые списки выключены — вернули \(target.displayName)")
                }
                whitelistCheck = check
            }
        }
    }

    private var networkTask: Task<Void, Never>?

    private func networkChanged() {
        networkTask?.cancel()
        networkTask = Task {
            // Let the new network settle. With the VPN on the extension checks by itself once the tunnel is on
            // the new network: asked now, it would answer from the old one ("nothing works").
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, !vpn.isConnected { checkWhitelist() }
        }
    }

    /** What the extension may have changed: the selected server and the latest white list check. */
    func syncShared() {
        let saved = Store.selectedServer
        if saved != selectedKey, saved != nil { selectedKey = saved }
        guard let check = Store.whitelistCheck else { return }
        if whitelistCheck.map({ check.time >= $0.time }) ?? true { whitelistCheck = check }
        if let name = check.switchedTo, check.time > toldSwitchAt, Date().timeIntervalSince(check.time) < 600 {
            toldSwitchAt = check.time
            show(check.status == .whitelist ? "Включены белые списки — переключили на \(name)" : "Белые списки выключены — вернули \(name)")
        }
    }

    /** While white lists are on, the ping button checks only the servers made for them (when there are any). */
    var pingWhitelistOnly: Bool {
        guard whitelistDetect, whitelistCheck?.status == .whitelist, let info = subscription else { return false }
        return !Whitelist.pingKeys(info.servers, config: config.whitelist).isEmpty
    }

    // MARK: Notifications

    /** Turns «Уведомлять об отключении VPN» on (asking iOS for permission) or off. */
    func setNotifyStops(_ on: Bool) {
        guard on else {
            notifyStops = false
            Store.notifyStops = false
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notifyStops = granted
            Store.notifyStops = granted
            if !granted { show("Разрешите уведомления FurkVPN в настройках iOS") }
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
        var servers = info.servers.filter(\.pingable)
        if pingWhitelistOnly {
            let keys = Whitelist.pingKeys(info.servers, config: config.whitelist)
            servers = servers.filter { keys.contains($0.key) }
        }
        pinging = true
        for s in servers { pings[s.key] = .testing }
        pingTask = Task {
            await self.useServerAddresses()
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
        Task {
            await useServerAddresses()
            await measure(entry)
        }
    }

    /**
     * With the VPN on, a ping gets past the tunnel only to an address out of its routes: the tests connect to
     * the addresses the extension resolved the servers to and left out (and don't look the names up through
     * the tunnel). Without the VPN, or from an older extension that doesn't answer, the names are looked up.
     */
    private func useServerAddresses() async {
        var addresses: [String: String] = [:]
        if vpn.isConnected, let data = await vpn.send(.addresses) {
            addresses = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        Core.setServerAddresses(addresses)
    }

    /**
     * The core can't be interrupted: a started measurement reports even if its run was restarted.
     * Always measured in the app: with the VPN on, the test's connections are bound to the phone's
     * own network, past the tunnel (in the tunnel extension the tests would get it killed for memory).
     */
    private func measure(_ entry: ServerEntry) async {
        measuring.insert(entry.key)
        defer { measuring.remove(entry.key) }
        let url = config.delayTestUrl
        let interface = vpn.isActive ? PhysicalNetwork.shared.interfaceName : nil
        var ms: Int64?
        if let raw = Store.config(for: entry.key) {
            ms = await Task.detached(priority: .userInitiated) { Core.ping(config: raw, url: url, interface: interface) }.value
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
