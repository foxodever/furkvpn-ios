import Foundation

enum ServerKind: String, Codable {
    case server = "SERVER"
    case auto = "AUTO"
    case separator = "SEPARATOR"
}

struct ServerEntry: Codable, Hashable, Identifiable {
    /** Stable id across subscription updates: remarks plus occurrence number. */
    var key: String
    var remarks: String
    var flag: String?
    var title: String
    var kind: ServerKind
    var summary: String?

    var id: String { key }
    var displayName: String { [flag, title].compactMap { $0 }.joined(separator: " ") }
    /** Servers and auto-selects get a ping (auto-select: through its own routing, like the VPN). */
    var pingable: Bool { kind != .separator }
}

struct SubscriptionInfo: Codable {
    var url: String
    var title: String?
    var announce: String?
    var supportUrl: String?
    var updateIntervalHours: Int?
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Int64?
    var fetchedAt: Date
    var servers: [ServerEntry]

    var selectable: [ServerEntry] { servers.filter { $0.kind != .separator } }

    /** [fetchedAt] in whole milliseconds: tags the config list saved with this server list. */
    var fetchedAtMs: Int64 { Int64((fetchedAt.timeIntervalSince1970 * 1000).rounded()) }

    /** Remnawave short UUID: the last path segment of the key. */
    var shortId: String? { URL(string: url)?.pathComponents.last { $0 != "/" } }
}

/** Plan and expiry of the subscription owner, from https://furkapp.net/api/v1/subscription/status. */
struct AccountStatus: Codable {
    var found: Bool = false
    var planId: Int?
    var planName: String?
    /** Unix seconds; nil when the plan never expires. */
    var expiresAt: Int64?
    var isFree: Bool = false
    var status: String?
    var trafficUsed: Int64?
    var trafficLimit: Int64?
    var fetchedAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = try c.decodeIfPresent(Bool.self, forKey: .found) ?? false
        planId = try? c.decodeIfPresent(Int.self, forKey: .planId)
        planName = try? c.decodeIfPresent(String.self, forKey: .planName)
        expiresAt = try? c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        isFree = (try? c.decodeIfPresent(Bool.self, forKey: .isFree)) ?? false
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        trafficUsed = try? c.decodeIfPresent(Int64.self, forKey: .trafficUsed)
        trafficLimit = try? c.decodeIfPresent(Int64.self, forKey: .trafficLimit)
        fetchedAt = try? c.decodeIfPresent(Date.self, forKey: .fetchedAt)
    }
}

struct SupportContact: Codable, Hashable {
    var type: String
    var title: String
    var url: String
}

/** A button with a link; known types ("website", "bot") get a localized title when [title] is not set. */
struct AppLink: Codable, Hashable {
    var type: String
    var title: String?
    var url: String
}

/** A proxy Telegram adds from its link (https://t.me/proxy, /socks, /webproxy or tg://). */
struct TelegramProxy: Codable, Hashable {
    var title: String
    var url: String
    var flag: String?

    var valid: Bool {
        let u = url.trimmingCharacters(in: .whitespaces).lowercased()
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            && ["https://t.me/", "https://telegram.me/", "tg://"].contains { u.hasPrefix($0) }
    }
}

struct ServerFilter: Codable, Hashable {
    var emoji: String
    var title: String
}

/** Host names without "https://". */
struct SiteConfig: Codable {
    var domain: String = "furkvpn.info"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = (try? c.decodeIfPresent(String.self, forKey: .domain)) ?? SiteConfig().domain
    }

    /** "Войти через сайт": the account page with the button that adds the key to the app. */
    var installUrl: String { "https://\(domain)/dashboard/install" }

    /** Settings → О приложении. */
    var privacyUrl: String { "https://\(domain)/privacy" }
    var termsUrl: String { "https://\(domain)/terms" }

    /** "Продлить" / "Купить тариф": the site's payment page for the subscription (its short UUID). */
    func renewalUrl(_ subscriptionId: String) -> String {
        let id = subscriptionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? subscriptionId
        return "https://\(domain)/renewal?sub=\(id)"
    }

    /** "https://furkvpn.info/" becomes "furkvpn.info"; anything that is not a host name falls back to the default. */
    func sanitized() -> SiteConfig {
        var site = SiteConfig()
        if let host = Self.hostName(domain) { site.domain = host }
        return site
    }

    private static func hostName(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespaces)
        if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
        host = String(host.prefix { !"/?#".contains($0) }).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let pattern = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,62}(:\\d{1,5})?$"
        return host.range(of: pattern, options: .regularExpression) != nil ? host : nil
    }
}

/** Settings served by https://furkapp.net/api/v1/config. Built-in defaults are used offline. */
struct RemoteConfig: Codable {
    var allowedSubscriptionHosts = ["*.furkvpn.com", "furkconnection.net"]
    var subscriptionMirrors = ["https://furkconnection.net"]
    var telegramBotUrl = "https://t.me/FurkVPNbot?start=app"
    var renewUrl = "https://t.me/FurkVPNbot"
    var support = [
        SupportContact(type: "telegram", title: "Telegram", url: "https://t.me/FurkVPNSupport"),
        SupportContact(type: "vk", title: "ВКонтакте", url: "https://vk.me/FurkVPN"),
        SupportContact(type: "email", title: "furkvpn@vulpine.email", url: "mailto:furkvpn@vulpine.email"),
    ]
    /** "Наш сайт" / "Наш бот" buttons on the main screen. */
    var links = [
        AppLink(type: "website", title: nil, url: "https://furkvpn.info"),
        AppLink(type: "bot", title: nil, url: "https://t.me/FurkVPNbot"),
    ]
    var site = SiteConfig()
    /** "Прокси для Telegram" under the links on the main screen; hidden while empty. */
    var telegramProxies: [TelegramProxy] = []
    /** Tabs above the server list: servers whose names contain the emoji. */
    var serverFilters = [
        ServerFilter(emoji: "⚡️", title: "Надёжный"),
        ServerFilter(emoji: "🎮", title: "Игровой"),
        ServerFilter(emoji: "📺", title: "Ютуб Без рекламы"),
        ServerFilter(emoji: "🤖", title: "Работает Gemini"),
        ServerFilter(emoji: "🏴‍☠️", title: "Можно Торренты"),
    ]
    var delayTestUrl = "https://www.gstatic.com/generate_204"
    /** White list detection: the sites to ask and the servers to switch between (Shared/Whitelist.swift). */
    var whitelist = WhitelistConfig()

    init() {}

    // Unknown keys are ignored and missing or broken ones keep the defaults, like the Android app.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemoteConfig()
        allowedSubscriptionHosts = (try? c.decodeIfPresent([String].self, forKey: .allowedSubscriptionHosts)) ?? d.allowedSubscriptionHosts
        subscriptionMirrors = (try? c.decodeIfPresent([String].self, forKey: .subscriptionMirrors)) ?? d.subscriptionMirrors
        telegramBotUrl = (try? c.decodeIfPresent(String.self, forKey: .telegramBotUrl)) ?? d.telegramBotUrl
        renewUrl = (try? c.decodeIfPresent(String.self, forKey: .renewUrl)) ?? d.renewUrl
        support = (try? c.decodeIfPresent([SupportContact].self, forKey: .support)) ?? d.support
        links = (try? c.decodeIfPresent([AppLink].self, forKey: .links)) ?? d.links
        site = (try? c.decodeIfPresent(SiteConfig.self, forKey: .site)) ?? d.site
        telegramProxies = (try? c.decodeIfPresent([TelegramProxy].self, forKey: .telegramProxies)) ?? d.telegramProxies
        serverFilters = (try? c.decodeIfPresent([ServerFilter].self, forKey: .serverFilters)) ?? d.serverFilters
        delayTestUrl = (try? c.decodeIfPresent(String.self, forKey: .delayTestUrl)) ?? d.delayTestUrl
        whitelist = (try? c.decodeIfPresent(WhitelistConfig.self, forKey: .whitelist)) ?? d.whitelist
    }

    /** A broken server response must never lock users out: empty lists fall back to defaults. */
    func sanitized() -> RemoteConfig {
        let d = RemoteConfig()
        var c = self
        if c.allowedSubscriptionHosts.isEmpty { c.allowedSubscriptionHosts = d.allowedSubscriptionHosts }
        if c.support.isEmpty { c.support = d.support }
        c.links = c.links.filter { !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
        c.telegramProxies = c.telegramProxies.filter(\.valid)
        c.site = c.site.sanitized()
        c.serverFilters = c.serverFilters.filter { !$0.emoji.trimmingCharacters(in: .whitespaces).isEmpty }
        if c.telegramBotUrl.trimmingCharacters(in: .whitespaces).isEmpty { c.telegramBotUrl = d.telegramBotUrl }
        if c.renewUrl.trimmingCharacters(in: .whitespaces).isEmpty { c.renewUrl = d.renewUrl }
        if c.delayTestUrl.trimmingCharacters(in: .whitespaces).isEmpty { c.delayTestUrl = d.delayTestUrl }
        return c
    }
}

enum RouteAction: String, CaseIterable, Codable, Identifiable {
    case block, direct, proxy
    var id: String { rawValue }
}

/** Settings → Routing: the user's own rules, applied before the server's ones. */
struct RoutingSettings: Codable, Equatable {
    var enabled = true
    var lanDirect = true
    var ruDirect = false
    var direct: [String] = []
    var proxy: [String] = []
    var block: [String] = []

    func rules(_ action: RouteAction) -> [String] {
        switch action {
        case .block: return block
        case .direct: return direct
        case .proxy: return proxy
        }
    }

    mutating func setRules(_ action: RouteAction, _ entries: [String]) {
        switch action {
        case .block: block = entries
        case .direct: direct = entries
        case .proxy: proxy = entries
        }
    }

    /** Adds entries to one list and takes them out of the other two. */
    mutating func add(_ entries: [String], to action: RouteAction) {
        for other in RouteAction.allCases where other != action {
            setRules(other, rules(other).filter { !entries.contains($0) })
        }
        var list = rules(action)
        for e in entries where !list.contains(e) { list.append(e) }
        setRules(action, list)
    }
}

/** Subscription auto-update: hours, or one of these two. */
enum UpdateInterval {
    static let fromSubscription = 0
    static let manual = -1
    static let choices = [fromSubscription, 1, 3, 6, 12, 24, manual]
}
