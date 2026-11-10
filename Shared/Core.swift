import Foundation
import Libxray
import Network

/** Swift facade over the gomobile binding of core/libxray (the same Go code as in the Android app). */
enum Core {
    struct Key: Decodable, Equatable {
        var url: String
        var host: String
        var path: String
        var shortId: String
    }

    enum KeyResult {
        case ok(Key)
        case empty
        case notALink
        case foreign
    }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var xrayVersion: String { LibxrayXrayVersion() }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /** A bare key, an import link or a message with a link → a normalized FurkVPN subscription key. */
    static func parseKey(_ input: String?, allowedHosts: [String]) -> KeyResult {
        let text = LibxrayParseKey(input ?? "", json(allowedHosts))
        struct Answer: Decodable {
            var result: String
            var url: String?
            var host: String?
            var path: String?
            var shortId: String?
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)) else { return .notALink }
        switch a.result {
        case "ok":
            guard let url = a.url else { return .notALink }
            return .ok(Key(url: url, host: a.host ?? "", path: a.path ?? "", shortId: a.shortId ?? ""))
        case "empty": return .empty
        case "foreign": return .foreign
        default: return .notALink
        }
    }

    static func hostAllowed(_ host: String, allowedHosts: [String]) -> Bool {
        LibxrayHostAllowed(host, json(allowedHosts))
    }

    /** The Remnawave Xray JSON subscription → server entries and their raw configs (same order). */
    static func parseSubscription(_ body: String) throws -> (servers: [ServerEntry], configs: [String]) {
        var error: NSError?
        let text = LibxrayParseSubscription(body, &error)
        if let error { throw ParseError(message: error.localizedDescription) }
        struct Answer: Decodable {
            var servers: [ServerEntry]
            var configs: [String]
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        return (answer.servers, answer.configs)
    }

    /** Remnawave header values may be prefixed with "base64:". */
    static func decodeHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let decoded = LibxrayDecodeHeader(value)
        return decoded.isEmpty ? nil : decoded
    }

    /** "upload=1; download=2; total=3; expire=4" → dictionary. */
    static func parseUserInfo(_ value: String?) -> [String: Int64] {
        object(LibxrayParseUserInfo(value ?? "")).compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    /** Routing entries from what people type; the rejected ones are returned as typed. */
    static func parseRouteList(_ text: String) -> (valid: [String], invalid: [String]) {
        let o = object(LibxrayParseRouteList(text))
        return (o["valid"] as? [String] ?? [], o["invalid"] as? [String] ?? [])
    }

    /** "youtube.com" for "domain:youtube.com", "yandex" for "keyword:yandex". */
    static func routeDisplay(_ entry: String) -> String { LibxrayRouteDisplay(entry) }

    /** The entry as one would type it, for editing: ".com", "keyword:yandex", "1.2.3.4". */
    static func routeEditable(_ entry: String) -> String { LibxrayRouteEditable(entry) }

    struct TunnelOptions: Encodable {
        var logLevel = "error"
        var routing: RoutingSettings
        var fallback: String?
        /** The phone's own interface: the core's connections are bound to it, never into its own tunnel. */
        var interface: String?
    }

    /** The server's config with Xray's TUN inbound, the user's rules and traffic counters. */
    static func buildTunnelConfig(raw: String, options: TunnelOptions) throws -> String {
        let optionsJSON = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        var error: NSError?
        let config = LibxrayBuildTunnelConfig(raw, optionsJSON, &error)
        if let error { throw ParseError(message: error.localizedDescription) }
        return config
    }

    struct Route: Decodable {
        var address: String
        var prefix: Int
    }

    /** Routes of the tunnel: everything, or without the local network and multicast when [lanDirect]. */
    static func tunnelRoutes(lanDirect: Bool) -> (ipv4: [Route], ipv6: [Route]) {
        struct Answer: Decodable {
            var ipv4: [Route]
            var ipv6: [Route]
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: Data(LibxrayTunnelRoutes(lanDirect).utf8)) else {
            return ([Route(address: "0.0.0.0", prefix: 0)], [Route(address: "::", prefix: 0)])
        }
        return (a.ipv4, a.ipv6)
    }

    /** The TV's QR code "https://furkapp.net/tv/ABC123" → "ABC123"; nil for anything else. */
    static func tvCode(_ text: String?) -> String? {
        let code = LibxrayTvCodeFromLink(text ?? "")
        return code.isEmpty ? nil : code
    }

    /**
     * Real delay through the server in milliseconds, or nil when it is unreachable. [interface]
     * ("en0", "pdp_ip0") binds the test's connections to the phone's own network, past the VPN.
     */
    static func ping(config: String, url: String, timeoutMs: Int32 = 5000, interface: String? = nil) -> Int64? {
        let ms = LibxrayPingVia(config, url, timeoutMs, interface ?? "")
        return ms >= 0 ? ms : nil
    }

    /**
     * The phone's own interfaces ("en0", "pdp_ip0") for connections past the tunnel, best first: those
     * the path goes through, then the rest, and only ones with an address — Wi-Fi that is on but joined
     * to nothing is listed too, and a socket bound to it gets "network is unreachable".
     */
    static func physicalInterfaces(_ path: Network.NWPath) -> [String] {
        let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        // The tunnel itself is an "other" interface; the list is in the order of preference.
        let listed = path.availableInterfaces.filter { physical.contains($0.type) }
        let ordered = listed.filter { path.usesInterfaceType($0.type) } + listed.filter { !path.usesInterfaceType($0.type) }
        let names = ordered.map(\.name)
        let usable = LibxrayUsableInterfaces(names.joined(separator: ",")).split(separator: ",").map(String.init)
        return usable.isEmpty ? names : usable
    }

    /** The interfaces that are up with their addresses, for the debug report. */
    static var interfaceSummary: String { LibxrayInterfaceSummary() }
}
