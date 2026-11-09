import Foundation

/**
 * What the app and the tunnel extension share: files in the App Group container and its
 * UserDefaults. The app writes, the extension reads the selected server's config and the
 * settings when it starts or reloads.
 */
enum Store {
    /**
     * The App Group this build is entitled to: ours, or the one a re-signing tool made from the
     * new bundle id ("group.<app id>"). Nil without one: then the app and the extension can't share
     * files, and the extension gets what it needs with the start (TunnelPayload) instead.
     */
    static let groupId: String? = {
        var candidates = ["group.com.furkvpn.app"]
        if var id = Bundle.main.bundleIdentifier {
            if id.hasSuffix(".tunnel") { id.removeLast(".tunnel".count) }
            candidates.append("group." + id)
        }
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    static let container: URL = {
        if let groupId, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) { return url }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let defaults: UserDefaults = groupId.flatMap { UserDefaults(suiteName: $0) } ?? .standard

    private static let subscriptionFile = container.appendingPathComponent("subscription.json")
    private static let configsFile = container.appendingPathComponent("subscription_configs.json")
    private static let remoteConfigFile = container.appendingPathComponent("remote_config.json")
    private static let accountFile = container.appendingPathComponent("account.json")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Subscription

    static func loadSubscription() -> SubscriptionInfo? { read(SubscriptionInfo.self, subscriptionFile) }

    /** Server configs and the [SubscriptionInfo.fetchedAtMs] of the list they belong to. */
    private struct SavedConfigs: Codable {
        var fetchedAt: Int64
        var configs: [String]
    }

    /** [configs][i] is the raw Xray config of [info.servers][i]. */
    static func saveSubscription(_ info: SubscriptionInfo, configs: [String]) {
        write(SavedConfigs(fetchedAt: info.fetchedAtMs, configs: configs), configsFile)
        write(info, subscriptionFile)
    }

    static func clearSubscription() {
        try? FileManager.default.removeItem(at: subscriptionFile)
        try? FileManager.default.removeItem(at: configsFile)
        try? FileManager.default.removeItem(at: accountFile)
        selectedServer = nil
    }

    /**
     * Raw Xray config of a server, as served by the panel. Servers are matched to configs by position,
     * so a config list from another download (the files are written one after the other, and the
     * extension may read in between) gives nil rather than another server's config.
     */
    static func config(for serverKey: String) -> String? {
        for _ in 0..<2 {
            guard let info = loadSubscription(), let index = info.servers.firstIndex(where: { $0.key == serverKey }) else { return nil }
            // Before 1.1.0: a bare array.
            if let configs = read([String].self, configsFile) { return index < configs.count ? configs[index] : nil }
            guard let saved = read(SavedConfigs.self, configsFile) else { return nil }
            if saved.fetchedAt == info.fetchedAtMs { return index < saved.configs.count ? saved.configs[index] : nil }
        }
        return nil
    }

    /** The selected server, falling back to the first selectable one. */
    static func selectedEntry(in info: SubscriptionInfo?) -> ServerEntry? {
        guard let info else { return nil }
        let saved = selectedServer
        return info.selectable.first { $0.key == saved } ?? info.selectable.first
    }

    // MARK: Remote config and account

    static func loadRemoteConfig() -> RemoteConfig? { read(RemoteConfig.self, remoteConfigFile) }
    static func saveRemoteConfig(_ config: RemoteConfig) { write(config, remoteConfigFile) }

    static func loadAccount() -> AccountStatus? { read(AccountStatus.self, accountFile) }
    static func saveAccount(_ status: AccountStatus) { write(status, accountFile) }
    static func clearAccount() { try? FileManager.default.removeItem(at: accountFile) }

    // MARK: Settings

    static var selectedServer: String? {
        get { defaults.string(forKey: "selectedServer") }
        set { defaults.set(newValue, forKey: "selectedServer") }
    }

    static var routing: RoutingSettings {
        get { defaults.data(forKey: "routing").flatMap { try? decoder.decode(RoutingSettings.self, from: $0) } ?? RoutingSettings() }
        set { defaults.set(try? encoder.encode(newValue), forKey: "routing") }
    }

    /** Hours, or [UpdateInterval.fromSubscription] / [UpdateInterval.manual]. */
    static var subscriptionUpdateHours: Int {
        get { defaults.object(forKey: "subscriptionUpdateHours") as? Int ?? UpdateInterval.fromSubscription }
        set { defaults.set(newValue, forKey: "subscriptionUpdateHours") }
    }

    /** Settings → Диагностика → send the extension's log to the developer (temporary, for debugging). */
    static var debugUpload: Bool {
        get { defaults.bool(forKey: "debugUpload") }
        set { defaults.set(newValue, forKey: "debugUpload") }
    }

    /** A collector on the API server, only while the VPN on iPhones is being debugged. */
    static let debugUploadURL = "http://54.36.51.149:18790/fv-dbg-7Qm2xK9p"

    /** The last error of the tunnel extension, for the app to show. */
    static func setTunnelError(_ message: String?) {
        if let message {
            defaults.set(["message": message, "at": Date().timeIntervalSince1970], forKey: "tunnelError")
        } else {
            defaults.removeObject(forKey: "tunnelError")
        }
    }

    static func tunnelError(since: Date) -> String? {
        guard let dict = defaults.dictionary(forKey: "tunnelError"), let message = dict["message"] as? String,
              let at = dict["at"] as? Double, at >= since.timeIntervalSince1970 - 1 else { return nil }
        return message
    }
}
