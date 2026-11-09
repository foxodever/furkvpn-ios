import Foundation

/** Messages from the app to the running tunnel extension (NETunnelProviderSession.sendProviderMessage). */
enum TunnelMessage: Codable {
    /** Traffic counted since the tunnel started. */
    case stats
    /** The selected server or the settings changed: start the core again with them. */
    case reload(TunnelPayload?)
    /** The extension's state, a test request through its core and the core's recent log (Settings → Диагностика). */
    case debug(url: String)

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> TunnelMessage? { try? JSONDecoder().decode(TunnelMessage.self, from: data) }
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
struct TunnelPayload: Codable {
    var serverKey: String
    var serverName: String
    var config: String
    var routing: RoutingSettings
    /** Where the extension posts its state every 5 s (Settings → Диагностика; temporary, for debugging). */
    var debugUpload: String?

    static let key = "payload"

    /** The selected server, from the files of this process (or the shared ones). */
    static func fromStore() -> TunnelPayload? {
        guard let info = Store.loadSubscription(), let server = Store.selectedEntry(in: info),
              let raw = Store.config(for: server.key) else { return nil }
        return TunnelPayload(serverKey: server.key, serverName: server.displayName, config: raw, routing: Store.routing,
                             debugUpload: Store.debugUpload ? Store.debugUploadURL : nil)
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data?) -> TunnelPayload? {
        data.flatMap { try? JSONDecoder().decode(TunnelPayload.self, from: $0) }
    }
}
