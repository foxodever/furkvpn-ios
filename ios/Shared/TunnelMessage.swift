import Foundation

/** Messages from the app to the running tunnel extension (NETunnelProviderSession.sendProviderMessage). */
enum TunnelMessage: Codable {
    /** Traffic counted since the tunnel started. */
    case stats
    /** Delay through one server, measured by the extension: its sockets bypass the tunnel. */
    case ping(serverKey: String, url: String)
    /** The selected server or the settings changed: start the core again with them. */
    case reload

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> TunnelMessage? { try? JSONDecoder().decode(TunnelMessage.self, from: data) }
}

struct TunnelStats: Codable {
    var up: Int64
    var down: Int64
}

struct TunnelPing: Codable {
    /** Milliseconds, or nil when the server did not answer. */
    var ms: Int64?
}
