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

/** Rounded block of the main screen, like the Android cards. */
struct CardBackground: ViewModifier {
    var color: Color = .card

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

extension View {
    func card(_ color: Color = .card) -> some View { modifier(CardBackground(color: color)) }
}

/**
 * Two halves side by side when the window is wide enough for both: the unfolded iPhone Duo (its inner
 * display is wider than tall and doesn't keep the app in portrait), an iPad. Chosen by the space the
 * window has, not by the device: the Duo's halves, Split View and Slide Over give the narrow layout.
 */
enum WideLayout {
    static let minWidth: CGFloat = 700
    static let maxWidth: CGFloat = 1000
    /** Between the halves; the halves are equal, so on the Duo the gap lies over the fold. */
    static let gap: CGFloat = 40

    static func fits(_ size: CGSize) -> Bool { size.width >= minWidth }
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
    private var toastText: Color {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return .primary }
        #endif
        return .onAccent
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
    @Environment(\.dismiss) private var dismiss

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
                    if let subscriptionSupport, !contacts.contains(where: { $0.url == subscriptionSupport }) {
                        Button { openLink(subscriptionSupport) } label: { Label("Поддержка подписки", systemImage: "questionmark.circle") }
                    }
                }
            }
            .navigationTitle("Поддержка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } }
            }
        }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } }
            }
        }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        dismiss()
                        onAdd(text)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/** Alerts shared by the welcome screen and the settings: key errors and "replace the key?". */
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
