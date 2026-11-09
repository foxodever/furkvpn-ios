import Foundation
import Security
import UIKit

enum SubscriptionError: LocalizedError {
    case foreign, notFound, badFormat, noServers
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .foreign: return "Это не ключ FurkVPN. В приложение можно добавить только ключ FurkVPN."
        case .notFound: return "Ключ не найден. Получите новый в боте."
        case .badFormat: return "Не удалось прочитать подписку. Напишите в поддержку."
        case .noServers: return "В подписке нет серверов."
        case .network: return "Не удалось загрузить подписку. Проверьте интернет и попробуйте ещё раз."
        }
    }
}

/**
 * Requests of the app. While the VPN is connected they simply go through the tunnel (on iOS the
 * app is not excluded from its own VPN), like the Android app's requests through its local proxy.
 */
enum Http {
    static let apiBase = "https://furkapp.net"

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    static let userAgent = "FurkVPN/\(appVersion) iOS/\(UIDevice.current.systemVersion)"

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 60
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }()

    /** "iPhone15,3": what Remnawave shows as the device model. */
    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.isEmpty ? UIDevice.current.model : machine
    }()

    /**
     * Device id for the panel's device limit (x-hwid). Kept in the keychain, so a reinstall of the
     * app is still the same device; "this device only", so a new phone restored from a backup is a
     * new device.
     */
    static let deviceId: String = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.furkvpn.app",
            kSecAttrAccount as String: "hwid",
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString.lowercased()
        var add = query
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return id
    }()

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /** POST of a JSON body; the HTTP status (the TV pairing API answers with it). */
    static func post(_ url: URL, body: [String: Any]) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func postJSON(_ url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/** The subscription as downloaded: entries, their raw configs and the panel's headers. */
struct DownloadedSubscription {
    var servers: [ServerEntry]
    var configs: [String]
    var headers: [String: String]
}

enum SubscriptionLoader {
    /**
     * Tries the key's own host first and, if it is slow or unreachable, the mirror domains from
     * the remote config with the same path. The first valid response wins.
     */
    static func download(_ key: Core.Key, config: RemoteConfig) async throws -> DownloadedSubscription {
        let allowed = config.allowedSubscriptionHosts
        var candidates = [key.url + "/json"]
        for mirror in config.subscriptionMirrors {
            var base = mirror.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            guard let host = URL(string: base)?.host?.lowercased(), !host.isEmpty, host != key.host,
                  Core.hostAllowed(host, allowedHosts: allowed) else { continue }
            let candidate = base + key.path + "/json"
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        let tasks: [() async throws -> DownloadedSubscription] = candidates.compactMap { URL(string: $0) }.map { url in
            { try await fetch(url, allowed: allowed) }
        }
        return try await raceStaggered(tasks, stagger: 3)
    }

    private static func fetch(_ url: URL, allowed: [String]) async throws -> DownloadedSubscription {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await Http.get(url, headers: [
                "Accept": "application/json",
                "x-hwid": Http.deviceId,
                "x-device-os": "iOS",
                "x-ver-os": UIDevice.current.systemVersion,
                "x-device-model": Http.deviceModel,
            ])
        } catch {
            throw SubscriptionError.network(error)
        }
        // Redirects must not lead outside our domains.
        guard let host = response.url?.host, Core.hostAllowed(host, allowedHosts: allowed) else { throw SubscriptionError.foreign }
        if response.statusCode == 404 { throw SubscriptionError.notFound }
        guard (200..<300).contains(response.statusCode) else { throw SubscriptionError.network(URLError(.badServerResponse)) }
        let parsed: (servers: [ServerEntry], configs: [String])
        do {
            parsed = try Core.parseSubscription(String(decoding: data, as: UTF8.self))
        } catch let error as Core.ParseError where error.message.contains("no servers") {
            throw SubscriptionError.noServers
        } catch {
            throw SubscriptionError.badFormat
        }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return DownloadedSubscription(servers: parsed.servers, configs: parsed.configs, headers: headers)
    }

    static func info(for key: Core.Key, _ downloaded: DownloadedSubscription) -> SubscriptionInfo {
        let h = downloaded.headers
        let userInfo = Core.parseUserInfo(h["subscription-userinfo"])
        let support = h["support-url"]?.trimmingCharacters(in: .whitespaces)
        return SubscriptionInfo(
            url: key.url,
            title: Core.decodeHeader(h["profile-title"]),
            announce: Core.decodeHeader(h["announce"]),
            supportUrl: support?.hasPrefix("http") == true ? support : nil,
            updateIntervalHours: h["profile-update-interval"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            upload: userInfo["upload"],
            download: userInfo["download"],
            total: userInfo["total"].flatMap { $0 > 0 ? $0 : nil },
            expire: userInfo["expire"].flatMap { $0 > 0 ? $0 : nil },
            fetchedAt: Date(),
            servers: downloaded.servers
        )
    }
}

/**
 * Starts the tasks one after another with a delay (a failed task starts the next one at once)
 * and returns the first successful result. Throws the most meaningful error if all fail.
 */
func raceStaggered<T: Sendable>(_ tasks: [() async throws -> T], stagger: TimeInterval) async throws -> T {
    try await withThrowingTaskGroup(of: RaceEvent<T>.self) { group in
        var next = 0
        var running = 0
        var errors: [Error] = []
        func launch() {
            guard next < tasks.count else { return }
            let task = tasks[next]
            next += 1
            running += 1
            group.addTask {
                do { return .done(.success(try await task())) } catch { return .done(.failure(error)) }
            }
            if next < tasks.count {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                    return .tick
                }
            }
        }
        launch()
        while let event = try await group.next() {
            switch event {
            case .tick:
                if !Task.isCancelled { launch() }
            case let .done(.success(value)):
                group.cancelAll()
                return value
            case let .done(.failure(error)):
                running -= 1
                errors.append(error)
                if next < tasks.count {
                    launch()
                } else if running == 0 {
                    group.cancelAll()
                    throw pickError(errors)
                }
            }
        }
        throw pickError(errors)
    }
}

private enum RaceEvent<T: Sendable>: Sendable {
    case done(Result<T, Error>)
    case tick
}

private func pickError(_ errors: [Error]) -> Error {
    func first(_ match: (SubscriptionError) -> Bool) -> Error? {
        errors.first { ($0 as? SubscriptionError).map(match) ?? false }
    }
    if let e = first({ if case .notFound = $0 { return true }; return false }) { return e }
    if let e = first({ if case .foreign = $0 { return true }; return false }) { return e }
    if let e = first({ if case .badFormat = $0 { return true }; return false }) { return e }
    if let e = errors.first(where: { $0 is SubscriptionError }) { return e }
    return SubscriptionError.network(errors.last ?? URLError(.unknown))
}
