import Foundation
import NetworkExtension

/** The system VPN profile of FurkVPN and its tunnel: connect, disconnect, status, messages to the extension. */
@MainActor
final class VPNController: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected(since: Date), stopping
    }

    @Published private(set) var state: State = .idle
    /** The last start of the tunnel, to tell its error from older ones. */
    private(set) var startedAt = Date.distantPast
    var onError: ((String) -> Void)?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    /** A server or settings change while connecting: the start may have read the old ones. */
    private var reloadWhenConnected = false
    static let tunnelBundleId = "com.furkvpn.app.tunnel"

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.update(connection) }
        }
        Task { await load() }
    }

    private func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleId }
        if let connection = manager?.connection { update(connection) }
    }

    private func update(_ connection: NEVPNConnection) {
        guard connection === manager?.connection else { return }
        let previous = state
        switch connection.status {
        case .connected: state = .connected(since: connection.connectedDate ?? Date())
        case .connecting, .reasserting: state = .connecting
        case .disconnecting: state = .stopping
        default: state = .idle
        }
        if state == .idle, previous == .connecting, let message = Store.tunnelError(since: startedAt) {
            onError?(message)
        }
        if case .connected = state, reloadWhenConnected {
            reloadWhenConnected = false
            Task { _ = await send(.reload) }
        }
        if state == .idle { reloadWhenConnected = false }
    }

    /** Creates the VPN profile on first use: iOS asks the user to allow it. */
    private func preparedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleId
        proto.serverAddress = "FurkVPN"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FurkVPN"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // A freshly saved profile has to be loaded again before it can start.
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    func connect() async {
        do {
            let manager = try await preparedManager()
            startedAt = Date()
            Store.setTunnelError(nil)
            state = .connecting
            try manager.connection.startVPNTunnel()
        } catch {
            state = .idle
            let nsError = error as NSError
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                onError?("Разрешите FurkVPN создать VPN-подключение, чтобы подключиться")
            } else {
                onError?(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /** Connected or on the way there: a change of server or settings has to reach the tunnel. */
    var isActive: Bool { isConnected || state == .connecting }

    /** Sends a message to the running extension; nil when it is not running or did not answer. */
    func send(_ message: TunnelMessage) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message.encoded()) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    func stats() async -> TunnelStats? {
        guard let data = await send(.stats) else { return nil }
        return try? JSONDecoder().decode(TunnelStats.self, from: data)
    }

    /**
     * Asks the extension to start the core again with the selected server and settings. While still
     * connecting it waits for the connection: the start may have read the previous server.
     */
    func reload() async {
        if state == .connecting {
            reloadWhenConnected = true
            return
        }
        _ = await send(.reload)
    }

    /** For Shortcuts and Siri: connected or connecting turns off, otherwise on. */
    func toggle() async {
        if isActive { disconnect() } else { await connect() }
    }
}
