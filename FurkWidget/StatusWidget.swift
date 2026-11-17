import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/**
 * The FurkVPN widget for the home screen (small and medium) and the Lock Screen: whether the VPN is on, the
 * server, the plan's days left, and the button that turns the VPN on and off (the same intent as the Control
 * Center button: it runs in the app's process). What it shows comes from WidgetState, written by the app and
 * the tunnel extension, which also ask for it to be redrawn.
 */
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetState.kind, provider: StatusProvider()) { entry in
            StatusView(entry: entry)
        }
        .configurationDisplayName("FurkVPN")
        .description("Включён ли VPN, сервер и сколько осталось по подписке. Кнопка включает и выключает VPN.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    /** Nil: nothing written yet (the app not opened since the update) or no shared keychain group. */
    let state: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    private static let sample = WidgetSnapshot(vpn: .on, since: Date().addingTimeInterval(-754), server: "🇪🇺 Автовыбор Wi-Fi",
                                               hasKey: true, plan: "Тариф «Стандарт»",
                                               expires: Date().addingTimeInterval(23 * 86_400 + 3600))

    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), state: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // The widget gallery: the sample when there is nothing to show yet.
        let state = WidgetState.load()
        completion(StatusEntry(date: Date(), state: state ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let state = WidgetState.load()
        var entries = [StatusEntry(date: now, state: state)]
        // The days left change at the time of day the plan ends: an entry for each of the next few changes.
        if let expires = state?.expires, expires > now {
            var change = now.addingTimeInterval(expires.timeIntervalSince(now).truncatingRemainder(dividingBy: 86_400) + 1)
            while entries.count < 4, change <= expires.addingTimeInterval(1) {
                entries.append(StatusEntry(date: change, state: state))
                change.addTimeInterval(86_400)
            }
        }
        // Anything else changes when the app or the tunnel says so; once a day anyway.
        let later = max(entries.last?.date ?? now, now.addingTimeInterval(6 * 3600))
        completion(Timeline(entries: entries, policy: .after(later)))
    }
}

/** The app's colors (Assets.xcassets is the app's): the accent, the card and the "good" green, light and dark. */
private extension Color {
    static func pair(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let furkAccent = pair((0.243, 0.290, 0.369), (0.741, 0.780, 0.863))
    static let furkOnAccent = pair((1, 1, 1), (0.102, 0.110, 0.118))
    static let furkBackground = pair((0.973, 0.976, 0.988), (0.102, 0.110, 0.118))
    static let furkCard = pair((0.882, 0.886, 0.902), (0.200, 0.212, 0.231))
    static let furkGood = pair((0.133, 0.420, 0.271), (0.624, 0.847, 0.702))
}

struct StatusView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family
    /** Not .fullColor: the tinted or clear home screen (iOS 18+, 26+) and the Lock Screen, all in one color. */
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var state: WidgetSnapshot? { entry.state }
    private var on: Bool { state?.vpn == .on }

    /** The server without its flag where the widget is in one color: an emoji comes out as a blot of it. */
    private var server: String? {
        guard let name = state?.server else { return nil }
        return renderingMode == .fullColor ? name : WidgetText.withoutEmoji(name)
    }

    private var title: String {
        switch state?.vpn {
        case .on: return "Подключено"
        case .connecting: return "Подключение…"
        default: return "Отключено"
        }
    }

    /** "Осталось 23 дня", "Подписка закончилась", "Без срока окончания" or nothing. */
    private var planLine: String? {
        guard let state, state.hasKey else { return nil }
        if let expires = state.expires {
            if expires <= entry.date { return "Подписка закончилась" }
            return "Осталось \(WidgetSnapshot.days(Int(expires.timeIntervalSince(entry.date) / 86_400)))"
        }
        return state.endless ? "Без срока окончания" : nil
    }

    private var expired: Bool { state?.expires.map { $0 <= entry.date } ?? false }

    var body: some View {
        content.containerBackground(for: .widget) {
            switch family {
            case .systemSmall, .systemMedium: Color.furkBackground
            default: Color.clear
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: Label("FurkVPN: \(title.lowercased())", systemImage: on ? "lock.shield.fill" : "shield.slash")
        case .systemMedium: medium
        default: small
        }
    }

    /** Without a key (or before the app has written anything) the widget only sends to the app. */
    private var ready: Bool { state?.hasKey == true }

    private var noKey: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FurkVPN").font(.headline)
            Text(state == nil ? "Откройте приложение, чтобы виджет ожил" : "Добавьте ключ в приложении")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var small: some View {
        Group {
            if ready {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        PowerButton(on: on, size: 50)
                        Spacer(minLength: 0)
                        Text(verbatim: "furk\n[vpn]").font(.caption2.weight(.semibold)).multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    statusLines
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                noKey
            }
        }
    }

    private var medium: some View {
        Group {
            if ready {
                HStack(spacing: 14) {
                    PowerButton(on: on, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        statusLines
                        Spacer(minLength: 6)
                        // As on the plan card: an ended plan is no longer shown by its name.
                        if let plan = state?.plan { Text(expired ? "Ваша подписка" : plan).font(.caption.weight(.semibold)).lineLimit(1) }
                        if let planLine {
                            Text(planLine).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                                .foregroundStyle(expired ? Color.red : Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            } else {
                noKey
            }
        }
    }

    /** "Подключено", the time on (or the plan's days left on the small widget), the server. */
    @ViewBuilder
    private var statusLines: some View {
        Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? Color.furkGood : Color.primary)
        if on, let since = state?.since {
            Text(since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else if family == .systemSmall, let planLine {
            Text(planLine).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(expired ? Color.red : Color.secondary)
        }
        if let server {
            Text(server).font(.caption).lineLimit(1).minimumScaleFactor(0.85).foregroundStyle(.secondary)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if ready {
                Button(intent: ToggleVPNControlIntent()) {
                    VStack(spacing: 1) {
                        Image(systemName: "power").font(.title3.weight(.semibold))
                        Text(on ? "вкл" : "выкл").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .widgetAccentable()
            } else {
                Image(systemName: "power").font(.title3)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("FurkVPN", systemImage: on ? "lock.shield.fill" : "shield.slash")
                .font(.headline).widgetAccentable()
            if ready {
                Text(title).font(.caption)
                if let server { Text(server).font(.caption).lineLimit(1) }
                else if let planLine { Text(planLine).font(.caption).lineLimit(1) }
            } else {
                Text("Откройте приложение").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/**
 * The round button of the home screen widgets: filled with the accent color while the VPN is on. On a tinted or
 * clear home screen iOS draws the widget in one color — the filled circle and its icon came out as one blot of
 * it, with no icon to be seen: there the circle is faint (fuller when on) and only the icon takes the tint.
 */
private struct PowerButton: View {
    var on: Bool
    var size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Button(intent: ToggleVPNControlIntent()) {
            Image(systemName: "power")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(fullColor ? (on ? Color.furkOnAccent : Color.furkAccent) : Color.white)
                .widgetAccentable(!fullColor)
                .frame(width: size, height: size)
                .background(disc)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Отключить VPN" : "Подключить VPN")
    }

    @ViewBuilder
    private var disc: some View {
        if fullColor {
            Circle().fill(on ? Color.furkAccent : Color.furkCard)
        } else {
            Circle().fill(Color.white.opacity(on ? 0.3 : 0.1))
                .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.35), lineWidth: 1.5))
        }
    }
}

enum WidgetText {
    /** "🇪🇺 Автовыбор Wi-Fi 🎲" → "Автовыбор Wi-Fi"; the name as it is when nothing else is left. */
    static func withoutEmoji(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let emoji = scalar.properties.isEmojiPresentation
                || (0x1F000...0x1FAFF).contains(v) // flags (regional indicators), pictographs
                || (0xE0020...0xE007F).contains(v) // tags of subdivision flags
                || v == 0xFE0F || v == 0x200D || v == 0x20E3 // emoji style, joiner, keycap
            if !emoji { kept.append(scalar) }
        }
        let words = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? text : words
    }
}
