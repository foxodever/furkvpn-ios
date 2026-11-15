#if DEMO
import SwiftUI
import UIKit

/**
 * Sample data for screenshots in the iOS Simulator and on the Mac (screenshots.sh builds with the DEMO
 * flag; the IPA never contains this). Launch arguments: -demo (sample subscription), -demoWelcome (no key),
 * -demoConnected, -demoServers, -demoSettings (open that screen), -demoServersLeft (the list on the left of
 * a wide window), -demoGlass liquid|matte|flat (Settings → «Стекло»; liquid without it); for the Mac -demoTheme dark|light, -demoWindow 1200x820 (the window's size in points),
 * -demoSnapshot <path> (the app saves a picture of its window there).
 */
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var on: Bool { args.contains("-demo") }
    static var welcome: Bool { args.contains("-demoWelcome") }
    static var connected: Bool { args.contains("-demoConnected") }
    static var servers: Bool { args.contains("-demoServers") }
    static var settings: Bool { args.contains("-demoSettings") }
    static var serversLeft: Bool { args.contains("-demoServersLeft") }
    /** The simulator keeps the app's settings between launches: every launch sets the style. */
    static var glass: String { value("-demoGlass") ?? "liquid" }

    private static func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var colorScheme: ColorScheme? {
        switch value("-demoTheme") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static var windowSize: CGSize? {
        let parts = value("-demoWindow")?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /** A picture of the window drawn by the app itself: needs no permission to record the screen. */
    static func snapshotLater() {
        guard let path = value("-demoSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func server(_ remarks: String, _ kind: ServerKind = .server, _ summary: String? = "VLESS · XHTTP · REALITY") -> ServerEntry {
        let scalars = Array(remarks.unicodeScalars)
        let regional = { (s: Unicode.Scalar) in (0x1F1E6...0x1F1FF).contains(s.value) }
        var flag: String?
        var title = remarks
        if kind != .separator, scalars.count > 2, regional(scalars[0]), regional(scalars[1]) {
            flag = String(String.UnicodeScalarView(scalars[0...1]))
            title = String(String.UnicodeScalarView(scalars[2...])).trimmingCharacters(in: .whitespaces)
        }
        return ServerEntry(key: remarks + "#1", remarks: remarks, flag: flag, title: title, kind: kind,
                           summary: kind == .server ? summary : nil)
    }

    static let subscription = SubscriptionInfo(
        url: "https://sub.furkvpn.com/demoDEMOdemo0001",
        title: "FurkVPN | Подписка",
        announce: "📺 — YouTube без рекламы | 🤖 — работают нейросети | 🏴‍☠️ — можно торренты",
        supportUrl: nil,
        updateIntervalHours: 6,
        upload: 1_200_000_000,
        download: 38_400_000_000,
        total: nil,
        expire: Int64(Date().timeIntervalSince1970) + 23 * 86_400,
        fetchedAt: Date().addingTimeInterval(-1800),
        servers: [
            server("🇪🇺 Автовыбор Wi-Fi 🎲", .auto),
            server("🇷🇺 Автовыбор LTE 🎲", .auto),
            server("Домашние (Wi-Fi)", .separator),
            server("🇳🇱 Нидерланды ⚡🤖🎮"),
            server("🇵🇱 Польша ⚡️🤖"),
            server("🇩🇪 Германия ⚡️🤖"),
            server("🇫🇮 Финляндия 📺"),
            server("🇺🇸 США 🤖"),
            server("Обходы (LTE)", .separator),
            server("🇷🇺🐱 Все операторы"),
            server("🇪🇺🦊 Все операторы"),
            server("🇪🇺🐃 Hysteria (СФО)", .server, "HYSTERIA2 · QUIC"),
        ]
    )

    static let pings: [String: Ping] = [
        "🇪🇺 Автовыбор Wi-Fi 🎲#1": .ok(48),
        "🇷🇺 Автовыбор LTE 🎲#1": .ok(71),
        "🇳🇱 Нидерланды ⚡🤖🎮#1": .ok(52),
        "🇵🇱 Польша ⚡️🤖#1": .ok(64),
        "🇩🇪 Германия ⚡️🤖#1": .ok(58),
        "🇫🇮 Финляндия 📺#1": .ok(83),
        "🇺🇸 США 🤖#1": .ok(412),
        "🇷🇺🐱 Все операторы#1": .ok(37),
        "🇪🇺🦊 Все операторы#1": .failed,
        "🇪🇺🐃 Hysteria (СФО)#1": .ok(695),
    ]

    static var account: AccountStatus? {
        let json = #"{"found":true,"planName":"Стандарт","expiresAt":\#(Int64(Date().timeIntervalSince1970) + 23 * 86_400),"isFree":false,"trafficUsed":39600000000}"#
        return try? JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
    }

    static var config: RemoteConfig {
        var c = RemoteConfig()
        c.telegramProxies = [
            TelegramProxy(title: "Германия", url: "https://t.me/proxy?server=demo", flag: "🇩🇪"),
            TelegramProxy(title: "Нидерланды", url: "https://t.me/proxy?server=demo2", flag: "🇳🇱"),
        ]
        return c
    }

    /** Traffic counters that grow like a real connection. */
    static var stats: TunnelStats {
        let t = Int64(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000))
        return TunnelStats(up: 18_000_000 + t * 23_000, down: 412_000_000 + t * 640_000)
    }
}
#endif
