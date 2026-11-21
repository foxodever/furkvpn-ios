import Foundation

/** Messages from the app to the running tunnel extension (NETunnelProviderSession.sendProviderMessage). */
enum TunnelMessage: Codable {
    /** Traffic counted since the tunnel started. */
    case stats
    /** The selected server or the settings changed: start the core again with them. */
    case reload(TunnelPayload?)
    /** The extension's state, a test request through its core and the core's recent log (Settings → Диагностика). */
    case debug(url: String)
    /** The addresses the extension resolved the subscription's servers to ({name: address}), out of the tunnel's routes. */
    case addresses
    /** Check for white lists now (WhitelistCheck back, after it switched the server if it had to). */
    case whitelist
    /** Where the pings go while the tunnel takes every connection (PingBridge back); nil when it doesn't. */
    case bridge

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> TunnelMessage? { try? JSONDecoder().decode(TunnelMessage.self, from: data) }
}

/**
 * The tunnel extension's ping bridge (core/libxray/pingbridge.go): a SOCKS inbound of its core on 127.0.0.1
 * behind this password, with a new one for each start of the tunnel. Only while the tunnel takes every
 * connection (Settings → «Уведомления через VPN»): the app's pings get past it only this way then.
 */
struct PingBridge: Codable, Equatable {
    var port: Int
    var user: String
    var pass: String
}

struct TunnelStats: Codable {
    var up: Int64
    var down: Int64
}

struct TunnelDebug: Codable {
    var running: Bool
    var server: String?
    var descriptor: Int32
    var interface: String?
    var up: Int64
    var down: Int64
    var check: String
    var log: String
}


/**
 * What the extension needs to run: the selected server's raw config and the routing settings.
 * The app sends it with the start (and keeps it in the VPN profile), so the tunnel works even when
 * a re-signed build has no shared App Group; with one, the extension can also read the files.
 */
struct TunnelPayload: Codable, Equatable {
    var serverKey: String
    var serverName: String
    var config: String
    var routing: RoutingSettings
    /** Debug mode (Settings → Диагностика): 15 s after the start the extension stops the tunnel with its report. */
    var debugMode: Bool?
    /**
     * The server names and addresses of the whole subscription: the extension leaves them all out of the
     * tunnel's routes, so the app's pings reach every server while the VPN is on.
     */
    var servers: [String]?
    /**
     * The host names of the white list check's sites (when it is on): out of the tunnel's routes as well, so
     * the extension asks them directly while the VPN is on.
     */
    var probes: [String]?

    static let key = "payload"

    /**
     * The selected server, from the files of this process (or the shared ones). [debug] only for the start
     * from the app: other starts and reloads never run the self-test.
     */
    static func fromStore(debug: Bool = false) -> TunnelPayload? {
        guard let info = Store.loadSubscription(), let server = Store.selectedEntry(in: info),
              let raw = Store.config(for: server.key) else { return nil }
        return TunnelPayload(serverKey: server.key, serverName: server.displayName, config: raw, routing: Store.routing,
                             debugMode: debug ? true : nil, servers: Core.subscriptionServers(Store.allConfigs()),
                             probes: Store.whitelistDetect ? Whitelist.hosts(Store.loadRemoteConfig()?.whitelist ?? WhitelistConfig()) : nil)
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data?) -> TunnelPayload? {
        data.flatMap { try? JSONDecoder().decode(TunnelPayload.self, from: $0) }
    }
}
