import Foundation
import Network

/**
 * The phone's own network interface ("en0" for Wi-Fi, "pdp_ip0" for cellular): pings bind their
 * connections to it while the VPN is on, so they measure the way to the server, not through the tunnel.
 */
final class PhysicalNetwork {
    static let shared = PhysicalNetwork()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var name: String?
    private var networkKind = "other"
    /** The network as a white list check sees it: its kind and interfaces. */
    private var key: String?
    /** Another network (Wi-Fi ↔ mobile data, another interface): called on a background queue. */
    var onChange: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(path)
        }
        monitor.start(queue: DispatchQueue(label: "com.furkvpn.network"))
    }

    private func set(_ path: Network.NWPath) {
        let interfaces = Core.physicalInterfaces(path)
        let kind = Whitelist.networkKind(path)
        let newKey = kind + " " + interfaces.joined(separator: ",")
        lock.lock()
        name = interfaces.first
        networkKind = kind
        let changed = key != nil && key != newKey
        key = newKey
        lock.unlock()
        if changed { onChange?() }
    }

    /** "wifi", "cellular", "ethernet", "other" or "none". */
    var kind: String {
        lock.lock()
        defer { lock.unlock() }
        return networkKind
    }

    var interfaceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }
}
