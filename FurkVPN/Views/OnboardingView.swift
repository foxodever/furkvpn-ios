import SwiftUI
import UIKit

/** Welcome screen: a FurkVPN key from the clipboard, a QR code, the bot, the site or typed by hand (on Apple TV: phone QR pairing or manual key). */
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manual = false
    #if os(tvOS)
    private enum Focus { case pair }
    @State private var showPairing = false
    @State private var pendingManualKey: String?
    @FocusState private var focus: Focus?
    #else
    @State private var scanning = false
    #endif

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            content
                .defaultFocus($focus, .pair)
                .onAppear { focus = .pair }
                .navigationDestination(isPresented: $showPairing) {
                    TVPairingView(title: "Подключить телевизор") { showPairing = false }
                }
                .fullScreenCover(isPresented: $manual, onDismiss: submitPendingManualKey) {
                    ManualKeySheet { pendingManualKey = $0 }
                }
        }
        #else
        content
            .sheet(isPresented: $manual) { ManualKeySheet { model.submitKey($0) } }
            .fullScreenCover(isPresented: $scanning) {
                ScannerView(title: "Сканирование QR-кода", hint: "Наведите камеру на QR-код с ключом") { model.submitKey($0) }
            }
        #endif
    }

    private var content: some View {
        GeometryReader { geo in
            ZStack {
                BrandBackdrop()
                if WideLayout.fits(geo.size) {
                    // Unfolded iPhone Duo, iPad, Mac, Apple TV: the greeting on one half, the ways to add a key on the other.
                    HStack(spacing: WideLayout.gap) {
                        greeting.frame(maxWidth: .infinity)
                        actions.frame(maxWidth: actionsMaxWidth).frame(maxWidth: .infinity)
                    }
                    .padding(outerPadding)
                    .frame(maxWidth: WideLayout.maxWidth)
                    .padding(WideLayout.centering(geo))
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        greeting
                        Spacer()
                        actions
                    }
                    .padding(24)
                    .frame(maxWidth: 480)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .disabled(model.importing)
        }
    }

    private var greeting: some View {
        VStack(spacing: greetingSpacing) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoWidth)
                .foregroundColor(.primary)
            Text("Добро пожаловать")
                .font(.title.weight(.semibold))
                .padding(.top, 24)
            Text(greetingSubtitle)
                .font(subtitleFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .wraps()
        }
    }

    private var actions: some View {
        VStack(spacing: actionSpacing) {
            if model.importing {
                ProgressView("Загружаем подписку…")
                    .padding(.bottom, 24)
            }
            #if os(tvOS)
            GlassGroup(spacing: 14) {
                VStack(spacing: 18) {
                    wideButton("Подключить через телефон", icon: "qrcode", prominent: true) {
                        showPairing = true
                    }
                    .focused($focus, equals: .pair)
                    Text("Откройте FurkVPN на телефоне → Настройки → «Подключить телевизор» и отсканируйте QR-код")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .wraps()
                        .padding(.horizontal, 12)
                    wideButton("Ввести ключ вручную", icon: "keyboard") {
                        pendingManualKey = nil
                        manual = true
                    }
                }
            }
            #else
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    wideButton("Вставить ключ", icon: "doc.on.clipboard", prominent: true) {
                        model.submitKey(UIPasteboard.general.string)
                    }
                    if CameraInfo.available {
                        wideButton("Сканировать QR-код", icon: "qrcode.viewfinder") { scanning = true }
                    }
                    wideButton("Войти через Telegram", icon: "paperplane.fill") { openLink(model.config.telegramBotUrl) }
                    Text("Бот пришлёт ссылку — просто нажмите на неё")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // The account page has the button that adds the key to the app.
                    wideButton("Войти через сайт", icon: "globe") { openLink(model.config.site.installUrl) }
                }
            }
            Button("Ввести ключ вручную") { manual = true }
                .padding(.top, 4)
            #endif
        }
    }

    private func wideButton(_ title: String, icon: String, prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, buttonVerticalPadding)
        }
        .glassButtonStyle(prominent: prominent)
        .largeControlSize()
    }

    #if os(tvOS)
    private func submitPendingManualKey() {
        guard let key = pendingManualKey else { return }
        pendingManualKey = nil
        model.submitKey(key)
    }

    private var logoWidth: CGFloat { 210 }
    private var greetingSpacing: CGFloat { 16 }
    private var actionSpacing: CGFloat { 18 }
    private var actionsMaxWidth: CGFloat { 700 }
    private var outerPadding: CGFloat { 80 }
    private var buttonVerticalPadding: CGFloat { 6 }
    private var subtitleFont: Font { .callout }
    private var greetingSubtitle: String { "Подключите Apple TV к вашей подписке FurkVPN" }
    #else
    private var logoWidth: CGFloat { 120 }
    private var greetingSpacing: CGFloat { 12 }
    private var actionSpacing: CGFloat { 12 }
    private var actionsMaxWidth: CGFloat { 420 }
    private var outerPadding: CGFloat { 24 }
    private var buttonVerticalPadding: CGFloat { 4 }
    private var subtitleFont: Font { .body }
    private var greetingSubtitle: String { "Добавьте ключ FurkVPN, чтобы подключиться" }
    #endif
}
