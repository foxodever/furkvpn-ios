import SwiftUI
import UIKit

extension Color {
    static let brandBackground = Color("Background")
    static let card = Color("Card")
    static let cardHigh = Color("CardHigh")
    static let onAccent = Color("OnAccent")
    static let errorCard = Color("ErrorCard")
    static let onErrorCard = Color("OnErrorCard")
    static let good = Color("Good")
}

/**
 * Rounded block of the main screen, like the Android cards: glass tinted with the card's color on iOS 26 (the
 * same color wherever the card is on the screen), a solid card before. The plan that ran out is red.
 */
struct CardBackground: ViewModifier {
    var color: Color = .card

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), color: color)
    }
}

extension View {
    func card(_ color: Color = .card) -> some View { modifier(CardBackground(color: color)) }

    /**
     * All the lines the text needs. Without it a text can come out cut to one line with "…" when a stack
     * is given a fixed height to share (the halves of the wide layout are as tall as the screen).
     */
    func wraps() -> some View { fixedSize(horizontal: false, vertical: true) }
}

/**
 * Two halves side by side when the window is wide enough for both: the unfolded iPhone Duo (its inner
 * display is wider than tall and doesn't keep the app in portrait), an iPad, a Mac window. Chosen by the
 * space the window has, not by the device: the Duo's halves, Split View, Slide Over and a narrow Mac
 * window give the narrow layout.
 */
enum WideLayout {
    static let minWidth: CGFloat = 700
    static let maxWidth: CGFloat = 1200
    /** Between the halves; the halves are equal, so on the Duo the gap lies over the fold. */
    static let gap: CGFloat = 40

    static func fits(_ size: CGSize) -> Bool { size.width >= minWidth }

    /**
     * Extra room on the side with the smaller safe area inset, so the halves are centred on the window (the
     * fold) rather than on its safe area: the Duo can put the status bar and the toolbar down one side.
     */
    static func centering(_ geo: GeometryProxy) -> EdgeInsets {
        let leading = geo.safeAreaInsets.leading, trailing = geo.safeAreaInsets.trailing
        return EdgeInsets(top: 0, leading: max(trailing - leading, 0), bottom: 0, trailing: max(leading - trailing, 0))
    }
}

/** Short message at the bottom of the screen (the Android snackbar). */
struct ToastOverlay: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(toastText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassSurface(Capsule(), fallback: .accentColor)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { self.text = nil }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: text)
    }

    /** Dark text on the glass of iOS 26, light text on the accent capsule before. */
    /** On glass (liquid or matte) the message is in the text color; on the flat accent capsule, in its contrast color. */
    private var toastText: Color {
        GlassStyle.current == .flat ? .onAccent : .primary
    }
}

extension View {
    func toast(_ text: Binding<String?>) -> some View { modifier(ToastOverlay(text: text)) }
}

func openLink(_ string: String?) {
    guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespaces)) else { return }
    UIApplication.shared.open(url)
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
}

/**
 * Links in the announcement of the subscription, as on Android: addresses with http(s), Telegram names
 * ("@FurkVPNbot" → t.me) and bare domains ("FurkVPN.info" → https). Text opens them on a tap. An e-mail
 * address opens Mail: its "@domain" used to be taken for a Telegram name (somebody else's).
 */
enum Linkify {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(https?://[^\s]+)|([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)|((?<![A-Za-z0-9_.])@[A-Za-z0-9_]{4,})|(\b[A-Za-z0-9-]+\.(?:info|ru|com|net|app|me)\b(?:/[^\s]*)?)"#)

    static func text(_ string: String) -> AttributedString {
        let ns = string as NSString
        var result = AttributedString()
        var last = 0
        for match in pattern.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result.append(AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            let found = ns.substring(with: match.range)
            // A sentence's punctuation right after the link is not part of it.
            var value = found
            while let end = value.last, ".,)!".contains(end) { value.removeLast() }
            let address: String
            if value.hasPrefix("@") {
                address = "https://t.me/" + String(value.dropFirst())
            } else if value.hasPrefix("http") {
                address = value
            } else if value.contains("@") {
                address = "mailto:" + value
            } else {
                address = "https://" + value
            }
            var link = AttributedString(value)
            link.link = URL(string: address)
            result.append(link)
            result.append(AttributedString(String(found.dropFirst(value.count))))
            last = match.range.location + match.range.length
        }
        result.append(AttributedString(ns.substring(from: last)))
        return result
    }
}

struct PingLabel: View {
    var ping: Ping?
    var kind: ServerKind?

    var body: some View {
        if ping == .testing {
            ProgressView().controlSize(.small)
        } else if let text = Format.ping(ping, kind: kind) {
            Text(text)
                .font(.subheadline.monospacedDigit())
                .foregroundColor(color)
        }
    }

    private var color: Color {
        guard case let .ok(ms) = ping else { return .secondary }
        if ms < 300 { return .good }
        if ms < 800 { return .orange }
        return .red
    }
}

/** Flag, name and protocol of a server. */
struct ServerTitle: View {
    var server: ServerEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(server.flag ?? "🌐").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.title).font(.body).foregroundColor(.primary).lineLimit(2)
                if let summary = server.summary {
                    Text(summary).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct SupportSheet: View {
    let contacts: [SupportContact]
    let subscriptionSupport: String?
    /** The main screen's links ("Наш бот"): the subscription's support link is usually one of them. */
    var links: [AppLink] = []
    @Environment(\.dismiss) private var dismiss

    /** The subscription's own support link, unless it is a contact above or a link of the main screen already. */
    private var extraSupport: String? {
        guard let subscriptionSupport else { return nil }
        let known = contacts.map(\.url) + links.map(\.url)
        return known.contains { Self.sameLink($0, subscriptionSupport) } ? nil : subscriptionSupport
    }

    /** "https://t.me/FurkVPNbot/" and "http://t.me/furkvpnbot?start=app" are the same place. */
    private static func sameLink(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces).lowercased()
            if let r = v.range(of: "://") { v = String(v[r.upperBound...]) }
            v = String(v.prefix { $0 != "?" && $0 != "#" })
            while v.hasSuffix("/") { v.removeLast() }
            return v.hasPrefix("www.") ? String(v.dropFirst(4)) : v
        }
        return key(a) == key(b)
    }

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Обычно отвечаем в течение нескольких часов")) {
                    ForEach(contacts, id: \.self) { contact in
                        Button {
                            openLink(contact.url)
                        } label: {
                            Label(contact.title, systemImage: icon(contact.type))
                        }
                    }
                    if let extraSupport {
                        Button { openLink(extraSupport) } label: { Label("Поддержка подписки", systemImage: "questionmark.circle") }
                    }
                }
            }
            .navigationTitle("Поддержка")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.confirmationAction) { Button("Закрыть") { dismiss() } }
        }
        .sheetGlass()
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "telegram": return "paperplane.fill"
        case "vk": return "bubble.left.and.bubble.right.fill"
        case "email": return "envelope.fill"
        default: return "link"
        }
    }
}

struct TelegramProxiesSheet: View {
    let proxies: [TelegramProxy]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Telegram заработает без VPN. Подключите все: Telegram сам выберет самый быстрый.")) {
                    ForEach(proxies, id: \.self) { proxy in
                        HStack {
                            Text([proxy.flag, proxy.title].compactMap { $0 }.joined(separator: " "))
                            Spacer()
                            Button("Подключить") { openLink(proxy.url) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Прокси для Telegram")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.confirmationAction) { Button("Закрыть") { dismiss() } }
        }
        .sheetGlass()
    }
}

/** Text field for a key typed or pasted by hand. */
struct ManualKeySheet: View {
    var onAdd: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Ссылка подписки")) {
                    TextField("https://sub.furkvpn.com/…", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Введите ключ")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Отмена") { dismiss() } }
            .barItem(.confirmationAction) {
                Button("Добавить") {
                    dismiss()
                    onAdd(text)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheetGlass()
    }
}

/** Alerts shared by the welcome screen, the settings and the sheets of the account: key errors, "replace the key?", another account found. */
struct KeyAlerts: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert("Ключ не добавлен", isPresented: Binding(get: { model.keyError != nil }, set: { if !$0 { model.keyError = nil } })) {
                Button("Открыть бота") { openLink(model.config.telegramBotUrl) }
                Button("Закрыть", role: .cancel) {}
            } message: {
                Text(model.keyError ?? "")
            }
            .alert("Заменить ключ?", isPresented: Binding(get: { model.pendingReplace != nil }, set: { if !$0 { model.pendingReplace = nil } })) {
                Button("Заменить", role: .destructive) { model.confirmReplace() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Текущий ключ будет заменён новым.")
            }
            .alert("Отправить ключ на телевизор?", isPresented: Binding(get: { model.tvSend != nil }, set: { if !$0 { model.tvSend = nil } })) {
                Button("Отправить") { model.confirmTvSend() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Телевизор с кодом \(Self.display(model.tvSend ?? "")) подключится к вашей подписке FurkVPN.")
            }
            .alert("Найден другой аккаунт", isPresented: Binding(get: { model.otherAccountKey != nil }, set: { if !$0 { model.otherAccountKey = nil } })) {
                Button("Перейти на него") { model.switchToOtherAccount() }
                Button("Остаться", role: .cancel) {}
            } message: {
                Text("Подписка App Store или вход через Apple привязаны к другому аккаунту FurkVPN. Перейти на него? Ключ в приложении заменится.")
            }
    }
}

extension KeyAlerts {
    /** "ABC123" → "ABC 123": easier to compare with the TV screen. */
    static func display(_ code: String) -> String {
        code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code
    }
}

extension View {
    func keyAlerts() -> some View { modifier(KeyAlerts()) }
}
