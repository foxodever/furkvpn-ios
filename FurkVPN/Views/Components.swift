import SwiftUI
import UIKit

/**
 * Rounded block of the main screen, like the Android cards: glass tinted with the card's color on iOS/tvOS 26
 * (the same color wherever the card is on the screen), a solid card before. The plan that ran out is red.
 */
struct CardBackground: ViewModifier {
    var color: Color = .card
    #if os(tvOS)
    private static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 14
    private static let radius: CGFloat = 26
    #else
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let radius: CGFloat = 24
    #endif

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous), color: color)
    }
}

extension View {
    func card(_ color: Color = .card) -> some View { modifier(CardBackground(color: color)) }
}

/**
 * Two halves side by side when the window is wide enough for both: the unfolded iPhone Duo (its inner
 * display is wider than tall and doesn't keep the app in portrait), an iPad, a Mac window, Apple TV.
 * Chosen by the space the window has, not by the device: the Duo's halves, Split View, Slide Over and
 * a narrow Mac window give the narrow layout.
 */
enum WideLayout {
    static let minWidth: CGFloat = 700
    #if os(tvOS)
    static let maxWidth: CGFloat = 1760
    static let gap: CGFloat = 56
    static let homeColumnMaxWidth: CGFloat = 780
    #else
    static let maxWidth: CGFloat = 1200
    /** Between the halves; the halves are equal, so on the Duo the gap lies over the fold. */
    static let gap: CGFloat = 40
    static let homeColumnMaxWidth: CGFloat = 560
    #endif

    static func fits(_ size: CGSize) -> Bool {
        #if os(tvOS)
        return true
        #else
        return size.width >= minWidth
        #endif
    }

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
                let label = Text(text)
                    .font(.subheadline)
                    .foregroundColor(toastText)
                    .multilineTextAlignment(.center)
                    #if os(tvOS)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    #else
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    #endif
                    .glassSurface(Capsule(), fallback: .accentColor)
                    #if os(tvOS)
                    .padding(.horizontal, 120)
                    .padding(.bottom, 48)
                    #else
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    #endif
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                #if os(tvOS)
                label.allowsHitTesting(false)
                #else
                label.onTapGesture { self.text = nil }
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.25), value: text)
    }

    /** On glass (liquid or matte) the message is in the text color; on the flat accent capsule, in its contrast color. */
    private var toastText: Color {
        GlassStyle.current == .flat ? .onAccent : .primary
    }
}

extension View {
    func toast(_ text: Binding<String?>) -> some View { modifier(ToastOverlay(text: text)) }
}

#if !os(tvOS)
func openLink(_ string: String?) {
    guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespaces)) else { return }
    UIApplication.shared.open(url)
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
#endif

struct PingLabel: View {
    var ping: Ping?
    var kind: ServerKind?

    var body: some View {
        if ping == .testing {
            #if os(tvOS)
            ProgressView().scaleEffect(0.6)
            #else
            ProgressView().controlSize(.small)
            #endif
        } else if let text = Format.ping(ping, kind: kind) {
            Text(text)
                #if os(tvOS)
                .font(.caption.monospacedDigit().weight(.medium))
                #else
                .font(.subheadline.monospacedDigit())
                #endif
                .foregroundColor(color)
                .fixedSize()
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
        #if os(tvOS)
        HStack(spacing: 16) {
            Text(server.flag ?? "🌐")
                .font(.system(size: 38))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.title)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let summary = server.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        #else
        HStack(spacing: 12) {
            Text(server.flag ?? "🌐").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.title).font(.body).foregroundColor(.primary).lineLimit(2)
                if let summary = server.summary {
                    Text(summary).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
        #endif
    }
}

#if !os(tvOS)
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
#endif

/** Text field for a key typed or pasted by hand. */
struct ManualKeySheet: View {
    var onAdd: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            ZStack {
                BrandBackdrop()
                VStack(alignment: .leading, spacing: 26) {
                    Text("Введите ключ FurkVPN")
                        .font(.title3.weight(.semibold))
                    Text("Удобно вставить ссылку с iPhone через уведомление клавиатуры Apple TV.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .wraps()
                    TextField("https://sub.furkvpn.com/…", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit {
                            if canSubmit { submit() }
                        }
                    GlassGroup(spacing: 12) {
                        HStack(spacing: 20) {
                            Spacer()
                            Button("Отмена") { dismiss() }
                                .glassButtonStyle()
                            Button("Добавить") { submit() }
                                .glassButtonStyle(prominent: true)
                                .disabled(!canSubmit)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(44)
                .cardSurface(RoundedRectangle(cornerRadius: 36, style: .continuous), color: .card)
                .frame(maxWidth: 980)
                .padding(60)
            }
        }
        #else
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
                Button("Добавить") { submit() }
                    .disabled(!canSubmit)
            }
        }
        .sheetGlass()
        #endif
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        dismiss()
        onAdd(value)
    }
}

/** Alerts shared by the welcome screen and the settings: key errors and "replace the key?". */
struct KeyAlerts: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        let base = content
            .alert("Ключ не добавлен", isPresented: Binding(get: { model.keyError != nil }, set: { if !$0 { model.keyError = nil } })) {
                #if !os(tvOS)
                Button("Открыть бота") { openLink(model.config.telegramBotUrl) }
                #endif
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
        #if os(tvOS)
        base
        #else
        base.alert("Отправить ключ на телевизор?", isPresented: Binding(get: { model.tvSend != nil }, set: { if !$0 { model.tvSend = nil } })) {
            Button("Отправить") { model.confirmTvSend() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Телевизор с кодом \(Self.display(model.tvSend ?? "")) подключится к вашей подписке FurkVPN.")
        }
        #endif
    }
}

extension KeyAlerts {
    /** "ABC123" → "ABC 123": easier to compare with the TV screen. */
    static func display(_ code: String) -> String {
        Format.tvCode(code)
    }
}

extension View {
    func keyAlerts() -> some View { modifier(KeyAlerts()) }
}
