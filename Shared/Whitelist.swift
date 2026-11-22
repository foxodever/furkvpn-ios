import Foundation
import Libxray
import Network

/**
 * White lists, as in the Android app: some operators let through only approved services. A check asks,
 * directly and not through the VPN, sites that white lists close (Google) and sites that stay open (VK,
 * Yandex); only the second ones answering means white lists are on, and the server moves to the LTE one.
 * Without the VPN the app checks; with it the tunnel extension does (on a new network, every 5 minutes,
 * and when the app asks), since iOS lets connections past a tunnel only to addresses out of its routes.
 */
enum WhitelistStatus: String, Codable {
    case unknown = "UNKNOWN"
    case allOk = "ALL_OK"
    case whitelist = "WHITELIST"
    case noInternet = "NO_INTERNET"
}

/** How one site answered: [ms] until the response, or why there was none (TIMEOUT, DNS, CONNECT, TLS, OTHER). */
struct ProbeResult: Codable, Hashable {
    var url: String
    var host: String
    var ms: Int64?
    var error: String?

    var ok: Bool { error == nil }
}

/** The latest check: when, on which network and how each site answered; written by the app or the extension. */
struct WhitelistCheck: Codable {
    var time: Date
    var status: WhitelistStatus
    /** "wifi", "cellular", "ethernet", "other" or "none". */
    var network: String
    /** Sites that white lists close (Google). */
    var blocked: [ProbeResult]
    /** Sites that stay open under white lists (VK, Yandex). */
    var allowed: [ProbeResult]
    /** The server this check switched to (its name), for the app to tell. */
    var switchedTo: String?
}

/** The "whitelist" block of the app's config; a missing list keeps the Android app's default (in the core). */
struct WhitelistConfig: Codable, Equatable {
    var blockedProbes: [String]?
    var allowedProbes: [String]?
    var lteServer: [String]?
    var wifiServer: [String]?
    var bypassServer: [String]?
    var pingServers: [String]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedProbes = try? c.decodeIfPresent([String].self, forKey: .blockedProbes)
        allowedProbes = try? c.decodeIfPresent([String].self, forKey: .allowedProbes)
        lteServer = try? c.decodeIfPresent([String].self, forKey: .lteServer)
        wifiServer = try? c.decodeIfPresent([String].self, forKey: .wifiServer)
        bypassServer = try? c.decodeIfPresent([String].self, forKey: .bypassServer)
        pingServers = try? c.decodeIfPresent([String].self, forKey: .pingServers)
    }

    fileprivate var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
}

enum Whitelist {
    /** The check's sites' host names: the extension resolves them and keeps them out of the tunnel's routes. */
    static func hosts(_ config: WhitelistConfig) -> [String] {
        LibxrayWhitelistHosts(config.json).split(separator: ",").map(String.init)
    }

    /**
     * Asks the sites, for up to ~6 s (blocks). [addresses] ({host: address}) are the addresses to connect to;
     * with [pinnedOnly] a host without one fails rather than being looked up through the VPN. [interface]
     * binds the connections to the phone's own network.
     */
    static func check(_ config: WhitelistConfig, addresses: [String: String] = [:], pinnedOnly: Bool = false,
                      interface: String? = nil, network: String) -> WhitelistCheck {
        struct Answer: Decodable {
            var status: WhitelistStatus
            var blocked: [ProbeResult]?
            var allowed: [ProbeResult]?
        }
        let given = (try? JSONEncoder().encode(addresses)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let text = LibxrayWhitelistCheck(config.json, given, pinnedOnly, interface ?? "")
        let a = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        return WhitelistCheck(time: Date(), status: a?.status ?? .noInternet, network: network,
                              blocked: a?.blocked ?? [], allowed: a?.allowed ?? [])
    }

    private struct Server: Encodable {
        var key: String
        var remarks: String
        var kind: String
    }

    private static func serversJSON(_ servers: [ServerEntry]) -> String {
        let list = servers.map { Server(key: $0.key, remarks: $0.remarks, kind: $0.kind.rawValue) }
        return (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /**
     * Which server to switch to when the status changes from [old] to [new], or nil to keep [current].
     * White lists on: the LTE server unless a bypass or LTE one is chosen; off: back, only from a bypass server
     * or from the one the app itself chose ([autoSwitched]) — a hand-picked one stays. Back is [previous], the
     * server chosen before the app moved it, or the Wi-Fi server when the subscription no longer has it.
     */
    static func target(old: WhitelistStatus, new: WhitelistStatus, current: String, servers: [ServerEntry],
                       config: WhitelistConfig, autoSwitched: String?, previous: String?) -> ServerEntry? {
        let key = LibxrayWhitelistTarget(old.rawValue, new.rawValue, current, serversJSON(servers), config.json,
                                         autoSwitched ?? "", previous ?? "")
        return key.isEmpty ? nil : servers.first { $0.key == key }
    }

    /** Servers made for white lists ("Все операторы", "LTE"): while they are on, the only ones worth pinging. */
    static func pingKeys(_ servers: [ServerEntry], config: WhitelistConfig) -> Set<String> {
        let text = LibxrayWhitelistPingServers(serversJSON(servers), config.json)
        return Set((try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? [])
    }

    /** "wifi", "cellular", "ethernet", "other" or "none" for the check's details. */
    static func networkKind(_ path: Network.NWPath) -> String {
        guard path.status == .satisfied else {
            // The tunnel's extension in compatibility mode sees its path "unsatisfied" whatever the network:
            // an interface of the phone's with an address tells it then (Wi-Fi that is on but not joined has none).
            let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
            let listed = path.availableInterfaces.filter { physical.contains($0.type) }
            let usable = Set(LibxrayUsableInterfaces(listed.map(\.name).joined(separator: ",")).split(separator: ",").map(String.init))
            let online = listed.filter { usable.contains($0.name) }
            guard let first = online.first(where: { path.usesInterfaceType($0.type) }) ?? online.first else { return "none" }
            switch first.type {
            case .wifi: return "wifi"
            case .cellular: return "cellular"
            default: return "ethernet"
            }
        }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        // With the VPN on the path goes through the tunnel: the phone's own interfaces tell the network.
        let types = path.availableInterfaces.map(\.type)
        if types.contains(.wifi) { return "wifi" }
        if types.contains(.cellular) { return "cellular" }
        if types.contains(.wiredEthernet) { return "ethernet" }
        return "other"
    }

    /** Between a check that found white lists and the one that confirms it. */
    private static let confirmAfter: TimeInterval = 4

    /**
     * A check that says white lists have just come on is made once more a few seconds later, and that one
     * counts: a single check with Google slow to answer (a network just joined, a Mac waking up) used to move
     * the server. Blocks for the pause and the second check.
     */
    static func confirmed(_ first: WhitelistCheck, again: () -> WhitelistCheck) -> WhitelistCheck {
        guard first.status == .whitelist, (Store.whitelistCheck?.status ?? .unknown) != .whitelist else { return first }
        Thread.sleep(forTimeInterval: confirmAfter)
        return again()
    }

    /**
     * Applies a finished check to the shared settings: remembers it, and moves the selected server when the
     * status changed (the server it was moved from and the app's own choice are remembered, so it is moved back
     * later). Returns the server it switched to. Called by whichever process checked: the app without the VPN,
     * the extension with it.
     */
    static func apply(_ check: inout WhitelistCheck) -> ServerEntry? {
        let old = Store.whitelistCheck?.status ?? .unknown
        var target: ServerEntry?
        if let info = Store.loadSubscription(), let current = Store.selectedEntry(in: info) {
            target = Self.target(old: old, new: check.status, current: current.key, servers: info.selectable,
                                 config: Store.loadRemoteConfig()?.whitelist ?? WhitelistConfig(),
                                 autoSwitched: Store.whitelistAutoSwitched, previous: Store.whitelistPrevious)
            if check.status == .allOk, old != .allOk, target != nil {
                Store.whitelistAutoSwitched = nil
                Store.whitelistPrevious = nil
            }
            if let target {
                Store.selectedServer = target.key
                if check.status == .whitelist {
                    Store.whitelistAutoSwitched = target.key
                    Store.whitelistPrevious = current.key
                }
                check.switchedTo = target.displayName
            }
        }
        Store.whitelistCheck = check
        return target
    }
}
