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
    /** The phone's own interfaces ("en0", "pdp_ip0"), best first. */
    private var physicalInterfaces: [String] = []
    private var physicalInterface: String? { physicalInterfaces.first }
    /** What the core's connections are bound to: the first interface the probe got out through, nil when only unbound sockets did. */
    private var coreInterface: String?
    private var probeResult = ""
    /** Debug mode: the same probe before the tunnel's settings are applied. */
    private var probeBefore = ""
    /** The path as iOS describes it, for the debug report. */
    private var pathInfo = ""
    private var lastPath: Network.NWPath?
    /** Debug mode: the other ways out tried once the tunnel is up (`probeOtherWays`). */
    private var otherWays = ""
    /**
     * The server config with its servers' addresses written in, resolved before the tunnel's settings,
     * and the addresses kept out of the tunnel's routes.
     */
    private var pinned: (config: String, exclude: [String]) = ("", [])
    /**
     * The other servers of the subscription, resolved once before the tunnel's settings: their addresses by
     * name for the app's pings, and the addresses, also out of the tunnel's routes — past a tunnel that is
     * up, iOS lets a connection through only to an address out of its routes, the app's too.
     */
    private var subscription: (addresses: [String: String], exclude: [String]) = ([:], [])
    /** What stays out of the tunnel's routes: the selected servers and their name servers, then the rest of the subscription. */
    private var excluded: [String] {
        var seen = Set<String>()
        return (pinned.exclude + subscription.exclude).filter { seen.insert($0).inserted }
    }
    /**
     * Compatibility mode: the probe got no answer past the tunnel (iOS doesn't take this extension for the
     * tunnel's provider — an IPA re-signed with the app's App ID for the extension too — or the network was
     * not ready) — the core runs unbound, its servers are out of the tunnel's routes, and nothing goes direct.
     * Up to 1.3.2 every build ran like this: the tunnel's routes hid the phone's default route from the kernel
     * (core/libxray/tunroutes.go).
     */
    private var compat = false
    /** Compatibility mode may only mean a network that was not ready when asked: it is asked once more, once per network. */
    private var compatRecheck: DispatchWorkItem?
    private var compatRechecked = false
    /** The network the core was last started on (`currentNetwork`), "" with none. */
    private var networkSignature = ""
    /** A new network waiting to settle. */
    private var settlingSignature: String?
    private var networkWork: DispatchWorkItem?
    /** Looks for a new network every few seconds: iOS may not report the path again when it changes. */
    private var networkTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    /** Moves the "VPN stopped" notification on while this process lives (StopNotices). */
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.furkvpn.tunnel.watchdog")
    /** No such notification is due (asleep, stopping, given up): the watchdog doesn't schedule it. On [watchdogQueue]. */
    private var watchdogPaused = false
    /** Stopping or given up: a wake doesn't bring the watchdog back. On [watchdogQueue]. */
    private var watchdogDone = false
    /** stopTunnel has been called: nothing starts the core again. */
    private var stopping = false
    /** White list checks every few minutes while connected (Shared/Whitelist.swift). */
    private var whitelistTimer: DispatchSourceTimer?
    /** White list checks take seconds: neither the core's queue nor auto-select's. */
    private let whitelistQueue = DispatchQueue(label: "com.furkvpn.tunnel.whitelist")
    private var whitelistWork: DispatchWorkItem?
    /** The extension stopped the tunnel itself and has said why: iOS's stop that may follow needs no notification. */
    private var gaveUp = false
    private var lastHealthRestart = Date.distantPast
    private var sleptAt: Date?
    /** The last turn of the network timer: a gap between two is time this process was not running. On [queue]. */
    private var lastTick = Date()
    /** The last time a wake-up was handled (iOS's word and the clock's both tell of the same one). On [queue]. */
    private var lastWoke = Date.distantPast
    /** White list checks that said "nothing works" in a row: asked again sooner, a few times. On [whitelistQueue]. */
    private var noInternetChecks = 0
    /** The server auto-select found best a moment ago, to start the next core with it as the fallback. */
    private var autoBest: (serverKey: String, tag: String, at: Date)?
    /**
     * Settings → «Уведомления через VPN»: the profile has the tunnel take every connection (includeAllNetworks),
     * and iOS no longer keeps the addresses out of the routes outside it. The app's pings come to the core through
     * this bridge instead (core/libxray/pingbridge.go) and go out from here, as the core's own connections do.
     */
    private var bridge: PingBridge?

    private static let tunIPv4 = "172.19.0.1"
    private static let tunDNS = "172.19.0.2"
    /** Yandex's second DNS: out of the tunnel's routes in debug mode, to see if an excluded route gets out. */
    private static let probeExcluded = "77.88.8.1"
    /** Yandex DNS addresses (reachable under the operators' white lists) to probe the network with. */
    private static let probeServers = ["77.88.8.8", "77.88.8.88", "77.88.8.7"]
    /** One the tunnel doesn't keep out of its routes: such a one would answer whatever iOS lets through. */
    private var probeServer: String { Self.probeServers.first { !excluded.contains($0) } ?? Self.probeServers[0] }
    private static let tunIPv6 = "fdfe:dcba:9876::1"
    private static let mtu = 1500
    /** A network that is gone may be back in a moment (Wi-Fi moving between access points)… */
    private static let networkSettle: TimeInterval = 3
    /** …another one is there to stay. */
    private static let newNetworkSettle: TimeInterval = 1
    private static let networkPoll = 5
    private static let compatRecheckAfter: TimeInterval = 20
    private static let autoCheckInterval = 10
    private static let healthRestartMin: TimeInterval = 120
    private static let longSleep: TimeInterval = 5 * 60
    /** Asleep this long, the connections to the servers are dead for sure: the core starts afresh. */
    private static let deadSleep: TimeInterval = 30 * 60
    private static let autoBestMaxAge: TimeInterval = 10 * 60
    private static let whitelistInterval = 5 * 60

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
        if (protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks == true {
            let port = Int(LibxrayFreeLocalPort())
            bridge = port > 0 ? PingBridge(port: port, user: "furk", pass: UUID().uuidString) : nil
            LibxrayDebugNote("all networks in the tunnel, ping bridge \(port > 0 ? "on 127.0.0.1:\(port)" : "not started")")
        }
        // The phone's network first: the core binds its connections to it.
        startPathMonitor()
        let network: String = queue.sync {
            networkSignature = currentNetwork()
            return networkSignature
        }
        LibxrayDebugNote("network: \(network.isEmpty ? "none" : network)")
        LibxrayDebugNote("start: \(payload.serverName), options \(options?[TunnelPayload.key] != nil ? "from the app" : "none")")
        // Debug mode: does this process reach the network at all, before there is a tunnel to go into?
        if payload.debugMode == true {
            probeBefore = LibxrayProbeNetworkVia(probeServer, queue.sync { physicalInterfaces }.joined(separator: ","))
        }
        routesLanDirect = Self.lanDirect(payload.routing)
        // While this process still reaches the network: the servers' addresses, to leave them out of the routes.
        pinned = Core.pinTunnelServers(payload.config)
        // The other servers for the app's pings, and the white list check's sites for the checks.
        subscription = Core.resolveServers((payload.servers ?? []) + (payload.probes ?? []))
        LibxrayDebugNote("servers pinned, \(pinned.exclude.count) addresses out of the tunnel, \(subscription.exclude.count) of the subscription")
        let settings = tunnelSettings()
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
                    if payload.debugMode == true { self.otherWays = self.probeOtherWays() }
                    try self.startCore()
                    self.startWatchers()
                    LibxrayDebugNote("started")
                    self.scheduleSelfTest()
                    completionHandler(nil)
                    // The widgets: on, and with which server (the app may not be running to tell them).
                    WidgetState.change { s in
                        s.vpn = .on
                        s.since = Date()
                        s.server = payload.serverName
                        s.hasKey = true
                    }
                    self.scheduleWhitelistCheck(after: 2)
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
            // A reload still applying the tunnel's settings must not start the core again after this.
            self.stopping = true
            self.pauseWatchdog(forGood: true)
            self.stopWatchers()
            self.stopCore()
            LibxrayDebugNote("stopped")
            WidgetState.change { $0.vpn = .off }
            // Not stopped by the user: say why (Settings → «Уведомлять об отключении VPN»), then let go.
            var finished = false
            let finish = {
                self.queue.async {
                    guard !finished else { return }
                    finished = true
                    completionHandler()
                }
            }
            if self.gaveUp {
                StopNotices.disarm()
                finish()
            } else {
                StopNotices.stopped(reason, done: finish)
            }
            self.queue.asyncAfter(deadline: .now() + 1, execute: finish)
        }
    }

    /** The extension gives up by itself: the error goes to the app (and to a notification, when they are on). */
    private func giveUp(_ error: Error) {
        gaveUp = true
        pauseWatchdog(forGood: true)
        StopNotices.post("FurkVPN отключён", error.localizedDescription)
        WidgetState.change { $0.vpn = .off }
        cancelTunnelWithError(error)
    }

    // The phone goes to sleep and this process with it: the "VPN stopped" notification must not go off meanwhile.
    override func sleep(completionHandler: @escaping () -> Void) {
        sleptAt = Date()
        // Not only taken back: the watchdog's next turn could come before iOS freezes this process, and the
        // notification it scheduled would go off a minute into the phone's sleep.
        pauseWatchdog()
        completionHandler()
    }

    /** Takes the scheduled "VPN stopped" notification back and keeps the watchdog from scheduling it again. */
    private func pauseWatchdog(forGood: Bool = false) {
        watchdogQueue.sync {
            watchdogPaused = true
            if forGood { watchdogDone = true }
            StopNotices.disarm()
        }
    }

    private func resumeWatchdog() {
        watchdogQueue.async {
            guard !self.watchdogDone else { return }
            self.watchdogPaused = false
            StopNotices.arm()
        }
    }

    override func wake() {
        resumeWatchdog()
        guard let slept = sleptAt else { return }
        sleptAt = nil
        woke(after: Date().timeIntervalSince(slept))
    }

    /**
     * Awake after [seconds] asleep — iOS said so (wake), or the network timer saw the clock jump: a Mac with
     * its lid closed doesn't always say. After a long sleep the connections to the servers may be dead (the
     * operator or the router dropped them): auto-select's servers are checked now instead of at its next round.
     * After a very long one they are dead for sure, the pooled ones too (XHTTP, gRPC), and new requests would
     * hang on them for minutes — the VPN "didn't work" after a Mac had slept for hours: the core starts afresh.
     */
    private func woke(after seconds: TimeInterval) {
        guard seconds >= Self.longSleep else { return }
        queue.async {
            guard Date().timeIntervalSince(self.lastWoke) > 60 else { return }
            self.lastWoke = Date()
            LibxrayDebugNote("awake after \(Int(seconds / 60)) min asleep")
            if seconds >= Self.deadSleep, self.running, !self.reloading, !self.stopping {
                self.lastHealthRestart = Date()
                self.restartCore("awake after a long sleep")
            } else {
                self.checkAutoSelect(afterSleep: true)
            }
            self.scheduleWhitelistCheck(after: 3)
        }
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
    /** The settings for the current routes, debug mode and servers. */
    private func tunnelSettings() -> NEPacketTunnelNetworkSettings {
        Self.networkSettings(lanDirect: routesLanDirect, debug: payload?.debugMode == true, exclude: excluded)
    }

    /**
     * [exclude]: the servers' addresses (and the name servers for their names) stay out of the routes:
     * the core reaches them even where iOS doesn't let this extension past its own tunnel.
     */
    private static func networkSettings(lanDirect: Bool, debug: Bool, exclude: [String]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)
        let routes = Core.tunnelRoutes(lanDirect: lanDirect)
        let ipv4 = NEIPv4Settings(addresses: [tunIPv4], subnetMasks: ["255.255.255.252"])
        // The DNS address is in 172.16/12, which "LAN directly" leaves out.
        ipv4.includedRoutes = routes.ipv4.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: Self.mask($0.prefix)) }
            + [NEIPv4Route(destinationAddress: tunDNS, subnetMask: "255.255.255.255")]
        let v4 = exclude.filter { !$0.contains(":") } + (debug ? [probeExcluded] : [])
        ipv4.excludedRoutes = v4.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        settings.ipv4Settings = ipv4
        // IPv6 goes into the tunnel too, so it doesn't leak past the VPN; the core answers DNS with IPv4 only.
        let ipv6 = NEIPv6Settings(addresses: [tunIPv6], networkPrefixLengths: [126])
        ipv6.includedRoutes = routes.ipv6.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
        ipv6.excludedRoutes = exclude.filter { $0.contains(":") }.map { NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128) }
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
        let interface = coreInterface
        let config = try Core.buildTunnelConfig(raw: pinned.config.isEmpty ? payload.config : pinned.config, options: .init(
            logLevel: "warning", routing: payload.routing, fallback: fallback, interface: interface, noDirect: compat, bridge: bridge))
        LibxrayDebugNote("bound to \(interface ?? "nothing")\(compat ? ", compatibility mode" : "")")
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
        guard tunFd >= 0, !stopping else { return }
        os_log("restarting the core: %{public}@", log: log, why)
        LibxrayDebugNote("restart: \(why)")
        reasserting = true
        do {
            try startCore()
        } catch {
            os_log("restart failed: %{public}@", log: log, type: .error, error.localizedDescription)
            Store.setTunnelError(error.localizedDescription)
            giveUp(error)
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
     * Before the core starts: does a DNS query get out unbound and bound to each of the phone's
     * interfaces? Unbound working means iOS lets this extension past its tunnel: the core is bound to the
     * first interface that works (unbound when none does). Otherwise it is compatibility mode: unbound,
     * the servers reached through the routes left out of the tunnel — binding to a second interface that
     * still gets out (mobile data while on Wi-Fi) would spend mobile data and fail on one network only.
     * Must run on [queue].
     */
    private func probeNetwork() {
        probeResult = LibxrayProbeNetworkVia(probeServer, physicalInterfaces.joined(separator: ","))
        LibxrayDebugNote("network probe \(probeResult)")
        let result = (try? JSONDecoder().decode([String: String].self, from: Data(probeResult.utf8))) ?? [:]
        compat = result["unbound"]?.hasPrefix("ok") != true && !pinned.exclude.isEmpty
        coreInterface = compat ? nil : physicalInterfaces.first(where: { result[$0]?.hasPrefix("ok") == true })
        scheduleCompatRecheck()
    }

    /**
     * Compatibility mode chosen on a network that was not ready yet (a moment after Wi-Fi ↔ mobile) would stay
     * until the next change, with nothing going direct. A little later the phone's interface is asked once more
     * — bound to it: with the core running, an unbound question could be answered through the tunnel — and
     * when it answers, the network is probed again as a new one. Once per network. Must run on [queue].
     */
    private func scheduleCompatRecheck() {
        compatRecheck?.cancel()
        compatRecheck = nil
        guard compat, !compatRechecked, let interface = physicalInterfaces.first else { return }
        let server = probeServer
        let work = DispatchWorkItem { [weak self] in
            guard LibxrayProbeDNS("\(server):53", interface).hasPrefix("ok") else { return }
            self?.queue.async {
                guard let self, self.running, self.compat, !self.compatRechecked else { return }
                self.compatRechecked = true
                LibxrayDebugNote("the network answers on \(interface): probing again")
                self.reload(nil, newNetwork: true) {}
            }
        }
        compatRecheck = work
        healthQueue.asyncAfter(deadline: .now() + Self.compatRecheckAfter, execute: work)
    }

    /**
     * Debug mode, once the tunnel is up: the ways out of this process other than plain sockets —
     * Network.framework (as is and tied to the phone's interface), NetworkExtension's own
     * createTCPConnection, and a socket to an address in excludedRoutes. Which of them iOS lets
     * through tells where it cuts the provider off. Must run on [queue]; takes about 2 s.
     */
    private func probeOtherWays() -> String {
        let started = Date()
        let endpoint = Network.NWEndpoint.hostPort(host: Network.NWEndpoint.Host(probeServer), port: 53)
        var variants: [(String, NWParameters)] = [("NWConnection", .tcp)]
        if let name = physicalInterface, let interface = lastPath?.availableInterfaces.first(where: { $0.name == name }) {
            let parameters = NWParameters.tcp
            parameters.requiredInterface = interface
            variants.append(("NWConnection через \(name)", parameters))
        }
        let probeQueue = DispatchQueue(label: "com.furkvpn.tunnel.probe")
        let connections = variants.map { ($0.0, NWConnection(to: endpoint, using: $0.1)) }
        for (_, connection) in connections { connection.start(queue: probeQueue) }
        let viaProvider = createTCPConnection(to: NWHostEndpoint(hostname: probeServer, port: "53"), enableTLS: false,
                                              tlsParameters: nil, delegate: nil)
        let outside = LibxrayProbeDNS("\(Self.probeExcluded):53", "")
        let left = 2 - Date().timeIntervalSince(started)
        if left > 0 { Thread.sleep(forTimeInterval: left) }
        var lines: [String] = []
        for (name, connection) in connections {
            var state: String
            switch connection.state {
            case .ready: state = "ok"
            case let .waiting(error): state = "ждёт: \(error)"
            case let .failed(error): state = "ошибка: \(error)"
            default: state = "\(connection.state)"
            }
            if let path = connection.currentPath, path.status != .satisfied {
                state += " (путь \(path.status), \(path.unsatisfiedReason))"
            }
            connection.cancel()
            lines.append("\(name): \(state)")
        }
        let providerState: String
        switch viaProvider.state {
        case .connected: providerState = "ok"
        case .connecting: providerState = "подключается"
        case .waiting: providerState = "ждёт"
        case .disconnected: providerState = "разорвано: \(viaProvider.error?.localizedDescription ?? "—")"
        case .cancelled: providerState = "отменено"
        default: providerState = "недействительно"
        }
        viaProvider.cancel()
        lines.append("createTCPConnection: \(providerState)")
        lines.append("сокет к \(Self.probeExcluded) из excludedRoutes: \(outside)")
        return lines.joined(separator: "; ")
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        let first = DispatchSemaphore(value: 0)
        // Called on [queue].
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkChanged(path)
            first.signal()
        }
        // Before the start: the handler reads it.
        self.monitor = monitor
        monitor.start(queue: queue)
        _ = first.wait(timeout: .now() + 1)
    }

    private func startWatchers() {
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + .seconds(Self.autoCheckInterval), repeating: .seconds(Self.autoCheckInterval))
        timer.setEventHandler { [weak self] in self?.checkAutoSelectNow(afterSleep: false) }
        timer.resume()
        healthTimer = timer
        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.schedule(deadline: .now(), repeating: .seconds(20))
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.watchdogPaused else { return }
            StopNotices.arm()
        }
        watchdog.resume()
        watchdogTimer = watchdog
        let network = DispatchSource.makeTimerSource(queue: queue)
        network.schedule(deadline: .now() + .seconds(Self.networkPoll), repeating: .seconds(Self.networkPoll))
        lastTick = Date()
        network.setEventHandler { [weak self] in
            guard let self else { return }
            // The timer doesn't run while the device sleeps: a gap in its turns is a sleep.
            let gap = Date().timeIntervalSince(self.lastTick)
            self.lastTick = Date()
            if gap >= Self.longSleep { self.woke(after: gap) }
            self.checkNetwork()
        }
        network.resume()
        networkTimer = network
        let whitelist = DispatchSource.makeTimerSource(queue: whitelistQueue)
        whitelist.schedule(deadline: .now() + .seconds(Self.whitelistInterval), repeating: .seconds(Self.whitelistInterval))
        whitelist.setEventHandler { [weak self] in _ = self?.checkWhitelistNow() }
        whitelist.resume()
        whitelistTimer = whitelist
    }

    private func stopWatchers() {
        monitor?.cancel()
        monitor = nil
        healthTimer?.cancel()
        healthTimer = nil
        networkWork?.cancel()
        networkWork = nil
        compatRecheck?.cancel()
        compatRecheck = nil
        networkTimer?.cancel()
        networkTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        whitelistTimer?.cancel()
        whitelistTimer = nil
        whitelistQueue.async {
            self.whitelistWork?.cancel()
            self.whitelistWork = nil
        }
    }

    /** iOS reports the path again: what it says is kept, and a new network looked for. Runs on [queue]. */
    private func networkChanged(_ path: Network.NWPath) {
        notePath(path)
        checkNetwork()
    }

    /** The interfaces to bind the core to, best first, and the path for the debug report. Must run on [queue]. */
    private func notePath(_ path: Network.NWPath) {
        physicalInterfaces = Core.physicalInterfaces(path)
        lastPath = path
        let status = path.status == .satisfied ? "\(path.status)" : "\(path.status) (\(path.unsatisfiedReason))"
        let listed = path.availableInterfaces.map { "\($0.name) \($0.type)" }.joined(separator: ", ")
        let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
        let used = types.filter { path.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: "/")
        pathInfo = "\(status), интерфейсы \(listed), идёт через \(used)"
    }

    /**
     * The network the phone is on: the interface iOS sends through (the first of the path's own) with its
     * addresses — not any interface that has one: Wi-Fi just joined has an address seconds before iOS moves to
     * it, and mobile data keeps its own under Wi-Fi. Where iOS doesn't say (to an extension it keeps behind
     * its own tunnel the path is "unsatisfied" whatever the network), the interfaces that have addresses,
     * Wi-Fi before mobile data. "" with no network. Must run on [queue].
     */
    private func currentNetwork() -> String {
        if let path = monitor?.currentPath, path.status == .satisfied, let primary = Core.physicalInterfaces(path).first {
            let signature = LibxrayInterfaceSignature(primary)
            if !signature.isEmpty { return signature }
        }
        return LibxrayNetworkSignature()
    }

    /**
     * Wi-Fi ↔ mobile or another network: connections to the servers made on the old network are dead but
     * would hang for minutes (and auto-select's checks with them), and the core is bound to the old interface.
     * Once the new network has settled the core starts afresh on it (`reload`). Looked for when iOS reports the
     * path and every few seconds. Must run on [queue].
     */
    private func checkNetwork() {
        let now = currentNetwork()
        guard now != networkSignature else {
            settlingSignature = nil
            networkWork?.cancel()
            networkWork = nil
            return
        }
        guard now != settlingSignature else { return }
        settlingSignature = now
        networkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settlingSignature = nil
            // Still changing, or the core is not up yet: the next check looks again. (The start may have
            // taken this network as its own since.)
            guard self.running, now != self.networkSignature, self.currentNetwork() == now else { return }
            self.networkSignature = now
            self.compatRechecked = false
            LibxrayDebugNote("network: \(now.isEmpty ? "none" : now)")
            // No network: the next one starts the core afresh, even if it is the same one again.
            guard !now.isEmpty else { return }
            self.reload(nil, newNetwork: true) {
                // Operators turn white lists on for mobile data: a new network is worth a check.
                self.scheduleWhitelistCheck(after: 2)
            }
        }
        networkWork = work
        queue.asyncAfter(deadline: .now() + (now.isEmpty ? Self.networkSettle : Self.newNetworkSettle), execute: work)
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
            // A reload is about to start the core again anyway.
            guard let self, self.running, !self.reloading, self.serverKey == key else { return }
            if !check.best.isEmpty { self.autoBest = (key, check.best, Date()) }
            guard check.restart, !self.networkSignature.isEmpty else { return }
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
        guard payload?.debugMode == true else { return }
        healthQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            let bound = self.queue.sync { self.coreInterface }
            let steps = LibxrayDiagnoseRunning("https://www.gstatic.com/generate_204", bound ?? "")
            self.queue.async {
                if self.running { self.sampleTraffic() }
                let before = self.probeBefore.isEmpty ? "—" : self.probeBefore
                let binding = bound.map { "привязано к \($0)" } ?? "без привязки"
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let summary = "Отчёт расширения \(version): ядро \(self.running ? "работает" : "остановлено"), "
                    + "из туннеля ↑\(self.totalUp) ↓\(self.totalDown) байт, сообщений от приложения \(self.messagesReceived).\n"
                    + "Сеть по iOS: \(self.pathInfo).\nАдреса: \(Core.interfaceSummary).\n"
                    + "Проверка сети до туннеля: \(before)\n"
                    + "Проверка сети с туннелем: \(self.probeResult); ядро \(binding)"
                    + "\(self.compat ? ", режим совместимости (без «напрямую»)" : ""), вне туннеля адресов серверов: \(self.pinned.exclude.count), всей подписки: \(self.subscription.exclude.count).\n"
                    + "Другие пути с туннелем: \(self.otherWays)\n"
                    + "\(steps)\nОшибки ядра:\n"
                    + String(LibxrayDebugErrors(8).suffix(1600))
                LibxrayDebugNote("self-test done")
                self.gaveUp = true
                self.pauseWatchdog(forGood: true)
                WidgetState.change { $0.vpn = .off }
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
        switch message {
        case .stats, .addresses, .bridge:
            // Asked every second while the app is open: noted, they pushed everything else out of the log
            // (150 lines) in a couple of minutes — the lines about the network and the restarts too.
            break
        default:
            LibxrayDebugNote("message \(message)".prefix(80).description)
        }
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
        case .addresses:
            queue.async { completionHandler?(try? JSONEncoder().encode(self.subscription.addresses)) }
        case .bridge:
            // Nil without one: the app binds its pings to the phone's interface, as before.
            queue.async { completionHandler?(self.bridge.flatMap { try? JSONEncoder().encode($0) }) }
        case .whitelist:
            whitelistQueue.async {
                let check = self.checkWhitelistNow()
                completionHandler?(check.flatMap { try? JSONEncoder().encode($0) })
            }
        case let .reload(sent):
            queue.async {
                self.reload(sent ?? (Store.groupId != nil ? TunnelPayload.fromStore() : nil)) { completionHandler?(Data()) }
            }
        }
    }

    /** A reload is applying new routes; reloads that come meanwhile wait and run as one, with the newest payload. */
    private var reloading = false
    private var queuedReload: (next: TunnelPayload?, newNetwork: Bool, done: [() -> Void])?

    /**
     * Starts the core again with [next] (the server or the settings changed), with new routes when needed.
     * One at a time: a second one while new routes are being applied used to overlap it, and a burst of them
     * (subscription updates pressed again and again) left the tunnel stuck "reconnecting". [newNetwork]: the
     * phone is on another network — which way gets out on it, and in compatibility mode the routes again.
     * Must run on [queue].
     */
    private func reload(_ next: TunnelPayload?, newNetwork: Bool = false, done: @escaping () -> Void) {
        if reloading {
            var queued = queuedReload ?? (next: nil, newNetwork: false, done: [])
            if let next { queued.next = next }
            queued.newNetwork = queued.newNetwork || newNetwork
            queued.done.append(done)
            queuedReload = queued
            return
        }
        reloading = true
        applyReload(next, newNetwork: newNetwork) {
            self.reloading = false
            done()
            if let queued = self.queuedReload {
                self.queuedReload = nil
                self.reload(queued.next, newNetwork: queued.newNetwork) { queued.done.forEach { $0() } }
            }
        }
    }

    /** Must run on [queue]; [done] is called on it. */
    private func applyReload(_ next: TunnelPayload?, newNetwork: Bool, done: @escaping () -> Void) {
        guard running, !stopping else {
            done()
            return
        }
        let probesBefore = payload?.probes ?? []
        if let next {
            payload = next
            // Another server (from the app, a shortcut or the white list check): the widgets show it.
            WidgetState.change { $0.server = next.serverName }
        }
        let lanDirect = Self.lanDirect(payload?.routing ?? RoutingSettings())
        // Another server: its addresses (the name servers it was looked up with are out of the routes already).
        // The subscription's are as resolved at the start: usually the new server's are among them. Not on a new
        // network alone: until the tunnel has its settings again the name servers may be out of reach, and a
        // lookup that fails would drop the server's addresses from what stays out of the routes.
        let previous = Set(excluded)
        if let next { pinned = Core.pinTunnelServers(next.config) }
        // White list detection turned on or off: its sites in or out of the routes.
        let probesChanged = next.map { ($0.probes ?? []) != probesBefore } ?? false
        if let next, probesChanged {
            subscription = Core.resolveServers((next.servers ?? []) + (next.probes ?? []))
        }
        // Just turned on: its first check, now that the sites' addresses are known (the one the app asked for
        // with the switch came before them and checked nothing).
        let finish = {
            done()
            if probesChanged { self.scheduleWhitelistCheck(after: 2) }
        }
        let routesChanged = lanDirect != routesLanDirect || Set(excluded) != previous
        if newNetwork {
            // Which way gets out on the new network (the interface to bind to, compatibility mode) — asked with
            // the core stopped: while it runs, an unbound question could be answered through the tunnel.
            reasserting = true
            stopCore()
            if let path = monitor?.currentPath { notePath(path) }
            probeNetwork()
        }
        // In compatibility mode all the core reaches are the addresses left out of the routes, and those stay
        // on the old network until the tunnel gets its settings again (up to 1.3.1 nothing worked after
        // Wi-Fi ↔ mobile until the VPN was turned off). Otherwise the settings stay: the core is bound to the
        // phone's interface, and no other client applies them again on a new network.
        guard routesChanged || (newNetwork && compat) else {
            restartCore(newNetwork ? "network changed" : "settings changed")
            // restartCore leaves it on when there is no tunnel to start on.
            reasserting = false
            finish()
            return
        }
        // New routes for the tunnel ("LAN directly", the servers or the network changed), then the core on them.
        routesLanDirect = lanDirect
        reasserting = true
        setTunnelNetworkSettings(tunnelSettings()) { _ in
            self.queue.async {
                // The tunnel's descriptor stays the same; look for it again only if it is gone, and with the core
                // stopped: the core works on a copy of it (Xray dups it, maybe to a lower number), and a search
                // while it runs could take that copy, which the restart closes — "bad file descriptor" (seen on a Mac).
                self.stopCore()
                if Self.interfaceName(self.tunFd) == nil, let fd = Self.findTunnelDescriptor() { self.tunFd = fd }
                // What gets out may be different with the routes on the new network.
                if newNetwork { self.probeNetwork() }
                self.restartCore(newNetwork ? "network changed" : "routes changed")
                // restartCore leaves it on when there is no tunnel to start on.
                self.reasserting = false
                finish()
            }
        }
    }

    // MARK: White lists

    private func scheduleWhitelistCheck(after seconds: Double) {
        whitelistQueue.async {
            self.whitelistWork?.cancel()
            let work = DispatchWorkItem { [weak self] in _ = self?.checkWhitelistNow() }
            self.whitelistWork = work
            self.whitelistQueue.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /**
     * Asks the check's sites directly — at the addresses resolved before the tunnel and left out of its routes,
     * the only ones iOS lets this process reach past its tunnel — and moves to the server for white lists when
     * the operator turned them on (back when they are off). Nil when detection is off or the sites' addresses
     * are unknown, or when the check learned nothing. Runs on [whitelistQueue]; blocks for up to ~6 s, ~16 s
     * when white lists are found (the check is made twice then).
     */
    @discardableResult
    private func checkWhitelistNow() -> WhitelistCheck? {
        guard Store.whitelistDetect else { return nil }
        let state: (running: Bool, addresses: [String: String], interface: String?, path: Network.NWPath?) =
            queue.sync { (running, subscription.addresses, coreInterface, lastPath) }
        let config = Store.loadRemoteConfig()?.whitelist ?? WhitelistConfig()
        guard state.running, Whitelist.hosts(config).contains(where: { state.addresses[$0] != nil }) else { return nil }
        let ask = {
            Whitelist.check(config, addresses: state.addresses, pinnedOnly: true, interface: state.interface,
                            network: state.path.map(Whitelist.networkKind) ?? "other")
        }
        // White lists just found are asked about once more before the server is moved.
        var check = Whitelist.confirmed(ask(), again: ask)
        LibxrayDebugNote("white lists: \(check.status.rawValue)")
        // The sites it needed have no addresses (their lookup failed before the tunnel): nothing learned.
        guard check.status != .unknown else { return nil }
        // "Nothing works" right after a wake-up or on a network just joined is often only too early: asked
        // again soon, a few times, instead of staying on the app's card until the next check in five minutes.
        if check.status == .noInternet {
            noInternetChecks += 1
            if noInternetChecks <= 3 { scheduleWhitelistCheck(after: 15) }
        } else {
            noInternetChecks = 0
        }
        guard let target = Whitelist.apply(&check) else {
            SharedChange.post()
            return check
        }
        // The server the check chose (Store.selectedServer now): the core moves to it.
        let on = check.status == .whitelist
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.reload(TunnelPayload.fromStore()) { done.signal() }
        }
        _ = done.wait(timeout: .now() + 10)
        SharedChange.post()
        StopNotices.post(on ? "Включены белые списки" : "Белые списки выключены",
                         on ? "Переключили на \(target.displayName)" : "Вернули \(target.displayName)")
        return check
    }
}
