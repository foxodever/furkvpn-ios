import Foundation
import Libxray
import Network
import NetworkExtension
import os
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

    private var tunFd: Int32 = -1
    private var running = false
    /** "LAN directly" the tunnel's routes were set up with; a change needs new network settings. */
    private var routesLanDirect = true
    private var serverKey: String?
    /** The server and settings the core runs with. */
    private var payload: TunnelPayload?
    private var totalUp: Int64 = 0
    private var totalDown: Int64 = 0

    private var monitor: NWPathMonitor?
    /** "en0" or "pdp_ip0": what the core's connections are bound to. */
    private var physicalInterface: String?
    /** False when only unbound sockets reach the network (the probe before the start). */
    private var bindCore = true
    private var probeResult = ""
    private var startedAt = Date()
    /** What iOS still allows this process, for the debug report. */
    private var memoryTimer: DispatchSourceTimer?
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

    /** An NSError with the message, so the app gets it through fetchLastDisconnectError. */
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.furkvpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /**
     * What to run: sent by the app with the start; otherwise (Shortcuts, the system's VPN switch) the
     * shared files when this build has an App Group, or what the app saved in the VPN profile.
     */
    private func startPayload(_ options: [String: NSObject]?) -> TunnelPayload? {
        if let sent = TunnelPayload.decode(options?[TunnelPayload.key] as? Data) { return sent }
        if Store.groupId != nil, let shared = TunnelPayload.fromStore() { return shared }
        let saved = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[TunnelPayload.key] as? Data
        return TunnelPayload.decode(saved)
    }

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The extension may use about 50 MB; the Go runtime has to collect garbage before that.
        LibxraySetMemoryLimit(32, 50)
        Store.setTunnelError(nil)
        guard let payload = startPayload(options) else {
            let error = Self.failure("Нет данных сервера: откройте FurkVPN и подключитесь из приложения")
            Store.setTunnelError(error.localizedDescription)
            completionHandler(error)
            return
        }
        self.payload = payload
        startedAt = Date()
        // The phone's network first: the core binds its connections to it.
        startPathMonitor()
        if let url = payload.debugUpload { LibxrayStartDebugUpload(url, physicalInterface ?? "") }
        startMemoryReports()
        LibxrayDebugNote("start: \(payload.serverName), options \(options?[TunnelPayload.key] != nil ? "from the app" : "none")")
        let lanDirect = Self.lanDirect(payload.routing)
        routesLanDirect = lanDirect
        let settings = Self.networkSettings(lanDirect: lanDirect)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                LibxrayDebugNote("network settings failed: \(error.localizedDescription)")
                Store.setTunnelError(error.localizedDescription)
                completionHandler(error)
                return
            }
            self.queue.async {
                do {
                    guard let fd = Self.findTunnelDescriptor() else { throw Self.failure("Не найден дескриптор туннеля") }
                    self.tunFd = fd
                    LibxrayDebugNote("tunnel fd \(fd) \(Self.interfaceName(fd) ?? "?")")
                    self.probeNetwork()
                    try self.startCore()
                    self.startWatchers()
                    LibxrayDebugNote("started")
                    self.scheduleSelfTest()
                    completionHandler(nil)
                } catch {
                    LibxrayDebugNote("start failed: \(error.localizedDescription)")
                    os_log("start failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    Store.setTunnelError(error.localizedDescription)
                    completionHandler(Self.failure(error.localizedDescription))
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        LibxrayDebugNote("stop requested, reason \(reason.rawValue)")
        queue.async {
            self.stopWatchers()
            self.stopCore()
            LibxrayDebugNote("stopped")
            LibxrayStopDebugUpload()
            self.memoryTimer?.cancel()
            completionHandler()
        }
    }

    private func startMemoryReports() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.furkvpn.tunnel.memory"))
        timer.schedule(deadline: .now(), repeating: .seconds(5))
        timer.setEventHandler { LibxrayDebugMemoryLeft(Int32(os_proc_available_memory() / 1_048_576)) }
        timer.resume()
        memoryTimer = timer
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
    private static func lanDirect(_ routing: RoutingSettings) -> Bool {
        routing.enabled && routing.lanDirect
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

    /** "utun4" for the descriptor, nil when it is not a utun. */
    private static func interfaceName(_ fd: Int32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(name.count)
        guard fd >= 0, getsockopt(fd, 2, 2, &name, &length) == 0 else { return nil }
        return String(cString: name)
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
        guard let payload else { throw Self.failure("Нет данных сервера") }
        let fallback = autoBest.flatMap { best in
            best.serverKey == payload.serverKey && Date().timeIntervalSince(best.at) < Self.autoBestMaxAge ? best.tag : nil
        }
        // Warnings too: the app's diagnostics screen shows them (DebugLog).
        let interface = bindCore ? physicalInterface : nil
        let config = try Core.buildTunnelConfig(raw: payload.config, options: .init(
            logLevel: "warning", routing: payload.routing, fallback: fallback, interface: interface))
        LibxrayDebugNote("bound to \(interface ?? "nothing")")
        if running { stopCore() }
        LibxrayDebugNote("core starting")
        let error = LibxrayStartTunnel(config, tunFd)
        if !error.isEmpty { throw Self.failure(error) }
        running = true
        serverKey = payload.serverKey
        os_log("core started: %{public}@", log: log, payload.serverName)
    }

    /** Must run on [queue]. Keeps what the core has counted. */
    private func stopCore() {
        guard running else { return }
        sampleTraffic()
        LibxrayDebugNote("core stopping")
        _ = LibxrayStop(nil)
        LibxrayDebugNote("core stopped")
        running = false
    }

    /** Starts the core again on the same tunnel: apps reconnect through it. Must run on [queue]. */
    private func restartCore(_ why: String) {
        guard tunFd >= 0 else { return }
        os_log("restarting the core: %{public}@", log: log, why)
        LibxrayDebugNote("restart: \(why)")
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

    /**
     * Watches the phone's own network; returns once the first path is known (or after a second):
     * the core is started bound to that interface.
     */
    /**
     * Before the core reads the tunnel: does a DNS query get out with the socket bound to the phone's
     * interface, or only without? The core is bound only if binding works (or nothing does).
     */
    private func probeNetwork() {
        probeResult = LibxrayProbeNetwork(physicalInterface ?? "")
        LibxrayDebugNote("network probe \(probeResult)")
        guard let result = try? JSONDecoder().decode([String: String].self, from: Data(probeResult.utf8)) else { return }
        let boundOK = result["bound"]?.hasPrefix("ok") == true
        let unboundOK = result["unbound"]?.hasPrefix("ok") == true
        bindCore = boundOK || !unboundOK
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        let first = DispatchSemaphore(value: 0)
        // Called on [queue].
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkChanged(path)
            first.signal()
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        _ = first.wait(timeout: .now() + 1)
    }

    private func startWatchers() {
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
        // The tunnel itself is an "other" interface; the list is in the order of preference.
        let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        let interfaces: [NWInterface] = path.availableInterfaces.filter { physical.contains($0.type) }
        let previousInterface = physicalInterface
        physicalInterface = interfaces.first?.name
        if physicalInterface != previousInterface, let url = payload?.debugUpload {
            LibxrayStopDebugUpload()
            LibxrayStartDebugUpload(url, physicalInterface ?? "")
        }
        // Wi-Fi ↔ cellular, or another interface to bind the core to; not the order of the rest.
        var names: Set<String> = []
        for interface in interfaces {
            names.insert("\(interface.type)")
        }
        let key: String = path.status == .satisfied ? names.sorted().joined(separator: ",") + " @" + (physicalInterface ?? "") : ""
        LibxrayDebugNote("network: \(key.isEmpty ? "none" : key)")
        // The tunnel coming up makes iOS report the path again: that is the same network.
        guard let previous = pathKey, Date().timeIntervalSince(startedAt) > 10 else {
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

    /** Debug mode (Settings → Диагностика): 15 s after the start the extension stops the VPN with a report
     * as the error, which iOS hands to the app — a way out that needs neither shared files, nor messages,
     * nor the network. No report while the VPN stays "connected" means the extension died or hangs. */
    private func scheduleSelfTest() {
        guard payload?.debugUpload != nil else { return }
        healthQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            let steps = LibxrayDiagnoseRunning("https://www.gstatic.com/generate_204", self.physicalInterface ?? "")
            self.queue.async {
                if self.running { self.sampleTraffic() }
                let summary = "Отчёт расширения: ядро \(self.running ? "работает" : "остановлено"), "
                    + "интерфейс \(self.physicalInterface ?? "—"), из туннеля ↑\(self.totalUp) ↓\(self.totalDown) байт, "
                    + "сообщений от приложения \(self.messagesReceived).\n"
                    + "Проверка сети до запуска ядра (bound — через \(self.physicalInterface ?? "—"), unbound — без привязки): \(self.probeResult); "
                    + "ядро \(self.bindCore ? "привязано" : "не привязано").\n\(steps)\nОшибки ядра:\n"
                    + String(LibxrayDebugErrors(12).suffix(2500))
                LibxrayDebugNote("self-test done")
                self.cancelTunnelWithError(Self.failure(summary))
            }
        }
    }

    /** App messages that reached this process (the report tells "not delivered" from "not answered"). */
    private var messagesReceived = 0

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async { self.messagesReceived += 1 }
        guard let message = TunnelMessage.decode(messageData) else {
            LibxrayDebugNote("message not understood (\(messageData.count) bytes)")
            completionHandler?(nil)
            return
        }
        LibxrayDebugNote("message \(message)".prefix(80).description)
        switch message {
        case .stats:
            queue.async {
                if self.running { self.sampleTraffic() }
                completionHandler?(try? JSONEncoder().encode(TunnelStats(up: self.totalUp, down: self.totalDown)))
            }
        case let .debug(url):
            // The test request takes seconds: not on the core's queue.
            healthQueue.async {
                let check = LibxrayCheckRunning(url, 5000)
                self.queue.async {
                    if self.running { self.sampleTraffic() }
                    let debug = TunnelDebug(running: self.running, server: self.payload?.serverName, descriptor: self.tunFd,
                                            interface: Self.interfaceName(self.tunFd), up: self.totalUp, down: self.totalDown,
                                            check: check, log: LibxrayDebugLog())
                    completionHandler?(try? JSONEncoder().encode(debug))
                }
            }
        case let .reload(sent):
            queue.async {
                guard self.running else {
                    completionHandler?(Data())
                    return
                }
                if let next = sent ?? (Store.groupId != nil ? TunnelPayload.fromStore() : nil) { self.payload = next }
                let lanDirect = Self.lanDirect(self.payload?.routing ?? RoutingSettings())
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
