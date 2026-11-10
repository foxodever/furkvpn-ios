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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(Core.physicalInterfaces(path).first)
        }
        monitor.start(queue: DispatchQueue(label: "com.furkvpn.network"))
    }

    private func set(_ value: String?) {
        lock.lock()
        name = value
        lock.unlock()
    }

    var interfaceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }
}
