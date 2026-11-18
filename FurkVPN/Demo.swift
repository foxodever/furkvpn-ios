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
            // Retina size whatever the screen of the build machine (its virtual display is 1×): the App Store
            // takes the Mac's screenshots at 2880×1800.
            let format = UIGraphicsImageRendererFormat()
            format.scale = max(window.screen.scale, 2)
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
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
        // The App Store's screenshots are made from this: no names of other companies' services (rule 5.2.1).
        announce: "⚡ — самые надёжные | 🤖 — работают нейросети | 🎮 — низкий пинг для игр",
        supportUrl: nil,
        updateIntervalHours: 6,
        upload: 1_200_000_000,
        download: 38_400_000_000,
        total: nil,
        expire: Int64(Date().timeIntervalSince1970) + 23 * 86_400,
        fetchedAt: Date().addingTimeInterval(-1800),
        // The servers of the real subscription (names and protocols as in Remnawave, 2026-11-17).
        servers: [
            server("🇪🇺 Автовыбор Wi-Fi 🎲", .auto),
            server("🇷🇺 Автовыбор LTE 🎲", .auto),
            server("Домашние (Wi-Fi)", .separator),
            server("🇳🇱 Нидерланды ⭐️🤖🏴‍☠️", .server, "VLESS · TCP · REALITY"),
            server("🇳🇱 Нидерланды ⚡🤖🎮🏴‍☠️", .server, "VLESS · TCP · REALITY"),
            server("🇵🇱 Польша⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇧🇬 Болгария⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇩🇪 Германия⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇳🇱 Нидерланды #2 ⭐️🤖🏴‍☠️", .server, "VLESS · TCP · REALITY"),
            server("🇵🇱 Польша #2 ⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇧🇬 Болгария #2 ⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇩🇪 Германия #2 ⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇦🇹 Австрия⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇰🇿 Казахстан⚡️🤖", .server, "VLESS · TCP · TLS"),
            server("🇭🇰 Гонконг 🤖", .server, "VLESS · TCP · TLS"),
            server("🇺🇸 США 🤖", .server, "VLESS · TCP · TLS"),
            server("🇷🇺 Москва 📺🤖", .server, "VLESS · TCP · REALITY"),
            server("🇵🇱 Польша #3", .server, "VLESS · TCP · TLS"),
            server("🇳🇱 Нидерланды #3", .server, "VLESS · TCP · TLS"),
            server("🇦🇹 Австрия #3", .server, "VLESS · TCP · TLS"),
            server("🇳🇱 Нидерланды Hysteria ⚡🤖", .server, "HYSTERIA2 · QUIC"),
            server("🇵🇱 Польша Hysteria ⚡️🤖", .server, "HYSTERIA2 · QUIC"),
            server("Обходы (LTE)", .separator),
            server("🇷🇺🐱 Все операторы", .server, "VLESS · GRPC · REALITY"),
            server("🇷🇺🦊 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇷🇺🐳 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇷🇺🛡 Все операторы (Крым)", .server, "VLESS · WS · TLS"),
            server("🇷🇺🐭 Все операторы", .server, "VLESS · GRPC · REALITY"),
            server("🇷🇺🦝 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇷🇺🍏 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇪🇺🐱 Все операторы", .server, "VLESS · GRPC · REALITY"),
            server("🇪🇺🦊 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇪🇺🐳 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇪🇺🐭 Все операторы", .server, "VLESS · GRPC · REALITY"),
            server("🇪🇺🍏 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇪🇺🦝 Все операторы", .server, "VLESS · XHTTP · TLS"),
            server("🇷🇺🦬 Все операторы (СФО-2)", .server, "VLESS · TCP · REALITY"),
            server("🇪🇺🦬 Все операторы (СФО-2)", .server, "VLESS · TCP · REALITY"),
            server("🇷🇺🦬 Hysteria (СФО-2)", .server, "HYSTERIA2 · QUIC"),
            server("🇪🇺🦬 Hysteria (СФО-2)", .server, "HYSTERIA2 · QUIC"),
            server("🇷🇺🐳 Hysteria", .server, "HYSTERIA2 · QUIC"),
            server("🇪🇺🐳 Hysteria", .server, "HYSTERIA2 · QUIC"),
            server("🇷🇺🐭 Hysteria", .server, "HYSTERIA2 · QUIC"),
            server("🇪🇺🐭 Hysteria", .server, "HYSTERIA2 · QUIC"),
        ]
    )

    static let pings: [String: Ping] = [
        "🇪🇺 Автовыбор Wi-Fi 🎲#1": .ok(48),
        "🇷🇺 Автовыбор LTE 🎲#1": .ok(71),
        "🇳🇱 Нидерланды ⭐️🤖🏴‍☠️#1": .ok(52),
        "🇳🇱 Нидерланды ⚡🤖🎮🏴‍☠️#1": .ok(48),
        "🇵🇱 Польша⚡️🤖#1": .ok(64),
        "🇧🇬 Болгария⚡️🤖#1": .ok(71),
        "🇩🇪 Германия⚡️🤖#1": .ok(58),
        "🇳🇱 Нидерланды #2 ⭐️🤖🏴‍☠️#1": .ok(55),
        "🇵🇱 Польша #2 ⚡️🤖#1": .ok(66),
        "🇧🇬 Болгария #2 ⚡️🤖#1": .ok(74),
        "🇩🇪 Германия #2 ⚡️🤖#1": .ok(61),
        "🇦🇹 Австрия⚡️🤖#1": .ok(69),
        "🇰🇿 Казахстан⚡️🤖#1": .ok(118),
        "🇭🇰 Гонконг 🤖#1": .ok(236),
        "🇺🇸 США 🤖#1": .ok(142),
        "🇷🇺 Москва 📺🤖#1": .ok(21),
        "🇵🇱 Польша #3#1": .ok(70),
        "🇳🇱 Нидерланды #3#1": .ok(57),
        "🇦🇹 Австрия #3#1": .ok(73),
        "🇳🇱 Нидерланды Hysteria ⚡🤖#1": .ok(49),
        "🇵🇱 Польша Hysteria ⚡️🤖#1": .ok(63),
        "🇷🇺🐱 Все операторы#1": .ok(37),
        "🇷🇺🦊 Все операторы#1": .ok(41),
        "🇷🇺🐳 Все операторы#1": .ok(44),
        "🇷🇺🛡 Все операторы (Крым)#1": .ok(52),
        "🇷🇺🐭 Все операторы#1": .failed,
        "🇷🇺🦝 Все операторы#1": .ok(39),
        "🇷🇺🍏 Все операторы#1": .ok(46),
        "🇪🇺🐱 Все операторы#1": .ok(58),
        "🇪🇺🦊 Все операторы#1": .ok(61),
        "🇪🇺🐳 Все операторы#1": .ok(66),
        "🇪🇺🐭 Все операторы#1": .ok(63),
        "🇪🇺🍏 Все операторы#1": .ok(70),
        "🇪🇺🦝 Все операторы#1": .ok(55),
        "🇷🇺🦬 Все операторы (СФО-2)#1": .ok(88),
        "🇪🇺🦬 Все операторы (СФО-2)#1": .ok(93),
        "🇷🇺🦬 Hysteria (СФО-2)#1": .ok(95),
        "🇪🇺🦬 Hysteria (СФО-2)#1": .ok(101),
        "🇷🇺🐳 Hysteria#1": .ok(84),
        "🇪🇺🐳 Hysteria#1": .ok(79),
        "🇷🇺🐭 Hysteria#1": .ok(102),
        "🇪🇺🐭 Hysteria#1": .ok(97),
    ]

    static var account: AccountStatus? {
        let json = #"{"found":true,"planName":"Стандарт","expiresAt":\#(Int64(Date().timeIntervalSince1970) + 23 * 86_400),"isFree":false,"trafficUsed":39600000000}"#
        return try? JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
    }

    static var config: RemoteConfig {
        var c = RemoteConfig()
        // As the API's, without other companies' names (the App Store's screenshots).
        c.serverFilters = [
            ServerFilter(emoji: "⚡️", title: "Надёжный"),
            ServerFilter(emoji: "🎮", title: "Игровой"),
            ServerFilter(emoji: "📺", title: "Видео"),
            ServerFilter(emoji: "🤖", title: "Нейросети"),
        ]
        // No «Прокси для Telegram» card either: another company's name.
        c.telegramProxies = []
        return c
    }

    /** Traffic counters that grow like a real connection. */
    static var stats: TunnelStats {
        let t = Int64(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000))
        return TunnelStats(up: 18_000_000 + t * 23_000, down: 412_000_000 + t * 640_000)
    }
}
#endif
