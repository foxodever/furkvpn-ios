import SwiftUI

extension Color {
    static let brandBackground = Color("Background")
    static let card = Color("Card")
    static let cardHigh = Color("CardHigh")
    static let onAccent = Color("OnAccent")
    static let errorCard = Color("ErrorCard")
    static let onErrorCard = Color("OnErrorCard")
    static let good = Color("Good")
}

extension View {
    /**
     * All the lines the text needs. Without it a text can come out cut to one line with "…" when a stack
     * is given a fixed height to share (the halves of the wide layout are as tall as the screen).
     */
    func wraps() -> some View { fixedSize(horizontal: false, vertical: true) }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: max(value, 0))
    }

    static func speed(_ bytesPerSecond: Int64) -> String { bytes(bytesPerSecond) + "/с" }

    static func date(_ seconds: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /** 1 день, 2 дня, 5 дней. */
    static func days(_ n: Int) -> String { "\(n) " + plural(n, "день", "дня", "дней") }

    static func hours(_ n: Int) -> String { "\(n) " + plural(n, "час", "часа", "часов") }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static func ping(_ ping: Ping?, kind: ServerKind?) -> String? {
        switch ping {
        case let .ok(ms): return "\(ms) мс"
        case .failed: return "—"
        case .testing: return nil
        case nil: return kind == .auto ? "авто" : nil
        }
    }

    /** "ABC123" → "ABC 123": easier to compare between the TV and phone screens. */
    static func tvCode(_ code: String) -> String {
        code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code
    }

    static func updateInterval(_ hours: Int, subscriptionDefault: Int?) -> String {
        switch hours {
        case UpdateInterval.fromSubscription: return "Как в подписке (\(subscriptionDefault ?? 6) ч)"
        case UpdateInterval.manual: return "Только вручную"
        default: return (hours == 1 ? "Каждый " : "Каждые ") + Self.hours(hours)
        }
    }
}

extension RouteAction {
    var title: String {
        switch self {
        case .direct: return "Напрямую"
        case .proxy: return "Через VPN"
        case .block: return "Блокировать"
        }
    }

    var hint: String {
        switch self {
        case .direct: return "Без VPN"
        case .proxy: return "Даже если сервер отправил бы их напрямую"
        case .block: return "Эти сайты не будут открываться"
        }
    }
}
