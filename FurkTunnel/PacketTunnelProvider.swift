import Foundation
import Libxray
import Network
import NetworkExtension
import os.log

/**
 * The VPN itself: Xray-core reads and writes the tunnel's packets through its own TUN inbound
 * (the utun descriptor of this extension). Everything the Android service does to keep
 * auto-select healthy is here too: a fresh core on a new network, a restart when the servers
 * auto-select was using stop answering, a recheck after a long sleep.
 */
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.furkvpn.app.tunnel", category: "tunnel")
    /** Starts, restarts and stops of the core, one at a time. */
    private let queue = DispatchQueue(label: "com.furkvpn.tunnel.core")
    /** Auto-select checks block for seconds; they must not hold up messages from the app. */
    private let healthQueue = DispatchQueue(label: "com.furkvpn.tunnel.health")
    private let pingQueue = DispatchQueue(label: "com.furkvpn.tunnel.ping", attributes: .concurrent)
    /** At most this many delay tests at once: each one is a whole Xray instance, and memory is tight here. */
    private let pingSlots = DispatchSemaphore(value: 3)

    private var tunFd: Int32 = -1
    private var running = false
    /** "LAN directly" the tunnel's routes were set up with; a change needs new network settings. */
    private var routesLanDirect = true
    private var serverKey: String?
    private var totalUp: Int64 = 0
    private var totalDown: Int64 = 0

    private var monitor: NWPathMonitor?
    private var pathKey: String?
    private var pathSatisfied = true
    private var networkWork: DispatchWorkItem?
    private var healthTimer: DispatchSourceTimer?
    private var lastHealthRestart = Date.distantPast
    private var sleptAt: Date?
    /** The server auto-select found best a moment ago, to start the next core with it as the fallback. */
    private var autoBest: (serverKey: String, tag: String, at: Date)?

    private static let tunIPv4 = "172.19.0.1"
    private static let tunDNS = "172.19.0.2"
    private static let tunIPv6 = "fdfe:dcba:9876::1"
    private static let mtu = 1500
    private static let networkSettle: TimeInterval = 3
    private static let autoCheckInterval = 10
    private static let healthRestartMin: TimeInterval = 120
    private static let longSleep: TimeInterval = 5 * 60
    private static let autoBestMaxAge: TimeInterval = 10 * 60

    private struct TunnelError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The extension may use about 50 MB; the Go runtime has to collect garbage before that.
        LibxraySetMemoryLimit(32, 50)
        Store.setTunnelError(nil)
        let lanDirect = Self.lanDirect
        routesLanDirect = lanDirect
        let settings = Self.networkSettings(lanDirect: lanDirect)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                Store.setTunnelError(error.localizedDescription)
                completionHandler(error)
                return
            }
            self.queue.async {
                do {
                    guard let fd = Self.findTunnelDescriptor() else { throw TunnelError(message: "no tunnel descriptor") }
                    self.tunFd = fd
                    try self.startCore()
                    self.startWatchers()
                    completionHandler(nil)
                } catch {
                    os_log("start failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    Store.setTunnelError(error.localizedDescription)
                    completionHandler(error)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.stopWatchers()
            self.stopCore()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        sleptAt = Date()
        completionHandler()
    }

    // After a long sleep the connections to the servers may be dead (the operator dropped them):
    // check auto-select's servers now instead of waiting for its next round.
    override func wake() {
        guard let slept = sleptAt else { return }
        sleptAt = nil
        if Date().timeIntervalSince(slept) >= Self.longSleep { checkAutoSelect(afterSleep: true) }
    }

    // MARK: Core

    /** Settings → Routing → "Локальная сеть напрямую" (on by default). */
    private static var lanDirect: Bool {
        let routing = Store.routing
        return routing.enabled && routing.lanDirect
    }

    /**
     * With "LAN directly" the local network, link-local and multicast stay out of the routes, not only
     * go direct in Xray: device discovery (AirPlay, Chromecast, printers) works as without the VPN.
     */
    private static func networkSettings(lanDirect: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)
        let routes = Core.tunnelRoutes(lanDirect: lanDirect)
        let ipv4 = NEIPv4Settings(addresses: [tunIPv4], subnetMasks: ["255.255.255.252"])
        // The DNS address is in 172.16/12, which "LAN directly" leaves out.
        ipv4.includedRoutes = routes.ipv4.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: Self.mask($0.prefix)) }
            + [NEIPv4Route(destinationAddress: tunDNS, subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        // IPv6 goes into the tunnel too, so it doesn't leak past the VPN; the core answers DNS with IPv4 only.
        let ipv6 = NEIPv6Settings(addresses: [tunIPv6], networkPrefixLengths: [126])
        ipv6.includedRoutes = routes.ipv6.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: [tunDNS])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /** "255.255.0.0" for 16. */
    private static func mask(_ prefix: Int) -> String {
        let bits: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return [24, 16, 8, 0].map { String((bits >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    /** The utun descriptor NetworkExtension opened for this tunnel (the way WireGuard and Xray's docs find it). */
    private static func findTunnelDescriptor() -> Int32? {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var length = socklen_t(name.count)
            // SYSPROTO_CONTROL, UTUN_OPT_IFNAME
            if getsockopt(fd, 2, 2, &name, &length) == 0, String(cString: name).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    /** Must run on [queue]. */
    private func startCore() throws {
        guard let info = Store.loadSubscription(), let server = Store.selectedEntry(in: info) else {
            throw TunnelError(message: "В подписке нет серверов.")
        }
        guard let raw = Store.config(for: server.key) else { throw TunnelError(message: "В подписке нет серверов.") }
        let fallback = autoBest.flatMap { best in
            best.serverKey == server.key && Date().timeIntervalSince(best.at) < Self.autoBestMaxAge ? best.tag : nil
        }
        let config = try Core.buildTunnelConfig(raw: raw, options: .init(routing: Store.routing, fallback: fallback))
        if running { stopCore() }
        let error = LibxrayStartTunnel(config, tunFd)
        if !error.isEmpty { throw TunnelError(message: error) }
        running = true
        serverKey = server.key
        os_log("core started: %{public}@", log: log, server.displayName)
    }

    /** Must run on [queue]. Keeps what the core has counted. */
    private func stopCore() {
        guard running else { return }
        sampleTraffic()
        _ = LibxrayStop(nil)
        running = false
    }

    /** Starts the core again on the same tunnel: apps reconnect through it. Must run on [queue]. */
    private func restartCore(_ why: String) {
        guard tunFd >= 0 else { return }
        os_log("restarting the core: %{public}@", log: log, why)
        reasserting = true
        do {
            try startCore()
        } catch {
            os_log("restart failed: %{public}@", log: log, type: .error, error.localizedDescription)
            Store.setTunnelError(error.localizedDescription)
            cancelTunnelWithError(error)
        }
        reasserting = false
    }

    private func sampleTraffic() {
        totalUp += LibxrayQueryStats("inbound>>>tun-in>>>traffic>>>uplink", true)
        totalDown += LibxrayQueryStats("inbound>>>tun-in>>>traffic>>>downlink", true)
    }

    // MARK: Watchers

    private func startWatchers() {
        let monitor = NWPathMonitor()
        // The tunnel itself is an "other" interface; only the phone's own network matters.
        // Called on [queue].
        monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(path) }
        monitor.start(queue: queue)
        self.monitor = monitor

        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + .seconds(Self.autoCheckInterval), repeating: .seconds(Self.autoCheckInterval))
        timer.setEventHandler { [weak self] in self?.checkAutoSelectNow(afterSleep: false) }
        timer.resume()
        healthTimer = timer
    }

    private func stopWatchers() {
        monitor?.cancel()
        monitor = nil
        healthTimer?.cancel()
        healthTimer = nil
        networkWork?.cancel()
        networkWork = nil
    }

    /**
     * Wi-Fi ↔ mobile or another network: connections to the servers made on the old network are
     * dead but would hang for minutes (and auto-select's checks with them), so the core starts afresh.
     */
    private func networkChanged(_ path: Network.NWPath) {
        pathSatisfied = path.status == .satisfied
        let interfaces = path.availableInterfaces.filter { $0.type != .other }
        let key = path.status == .satisfied ? interfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",") : ""
        guard let previous = pathKey else {
            pathKey = key // the network the tunnel was started on
            return
        }
        guard key != previous else { return }
        pathKey = key
        networkWork?.cancel()
        guard !key.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pathKey == key, self.running else { return }
            self.restartCore("network changed")
        }
        networkWork = work
        queue.asyncAfter(deadline: .now() + Self.networkSettle, execute: work)
    }

    private func checkAutoSelect(afterSleep: Bool) {
        healthQueue.async { [weak self] in self?.checkAutoSelectNow(afterSleep: afterSleep) }
    }

    /**
     * Auto-select switches only new connections, and only after its next check (once a minute).
     * When a server it was using stops answering (checked twice), or none answers at all, the core
     * restarts so apps reconnect through a live server instead of hanging on the dead one.
     * Runs on [healthQueue].
     */
    private func checkAutoSelectNow(afterSleep: Bool) {
        guard let key = queue.sync(execute: { running ? serverKey : nil }) else { return }
        let answer = LibxrayAutoSelectCheck(afterSleep)
        struct Check: Decodable {
            var restart: Bool
            var best: String
        }
        guard let check = try? JSONDecoder().decode(Check.self, from: Data(answer.utf8)) else { return }
        queue.async { [weak self] in
            guard let self, self.running, self.serverKey == key else { return }
            if !check.best.isEmpty { self.autoBest = (key, check.best, Date()) }
            guard check.restart, self.pathSatisfied else { return }
            guard Date().timeIntervalSince(self.lastHealthRestart) >= Self.healthRestartMin else { return }
            self.lastHealthRestart = Date()
            self.restartCore("auto-select servers stopped answering")
        }
    }

    // MARK: Messages from the app

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = TunnelMessage.decode(messageData) else {
            completionHandler?(nil)
            return
        }
        switch message {
        case .stats:
            queue.async {
                if self.running { self.sampleTraffic() }
                completionHandler?(try? JSONEncoder().encode(TunnelStats(up: self.totalUp, down: self.totalDown)))
            }
        case let .ping(serverKey, url):
            pingQueue.async {
                self.pingSlots.wait()
                defer { self.pingSlots.signal() }
                let ms = Store.config(for: serverKey).flatMap { Core.ping(config: $0, url: url) }
                completionHandler?(try? JSONEncoder().encode(TunnelPing(ms: ms)))
            }
        case .reload:
            queue.async {
                guard self.running else {
                    completionHandler?(Data())
                    return
                }
                let lanDirect = Self.lanDirect
                guard lanDirect != self.routesLanDirect else {
                    self.restartCore("settings changed")
                    completionHandler?(Data())
                    return
                }
                // "LAN directly" changed: new routes for the tunnel, then the core on them.
                self.routesLanDirect = lanDirect
                self.reasserting = true
                self.setTunnelNetworkSettings(Self.networkSettings(lanDirect: lanDirect)) { _ in
                    self.queue.async {
                        if let fd = Self.findTunnelDescriptor() { self.tunFd = fd }
                        self.restartCore("routes changed")
                        completionHandler?(Data())
                    }
                }
            }
        }
    }
}
