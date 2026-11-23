import SwiftUI
import UIKit

/**
 * Welcome screen: a FurkVPN key from the clipboard, a QR code, the bot, a sign-in (the site, an email, Apple),
 * a plan bought in the App Store, or a key typed by hand.
 */
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manual = false
    @State private var scanning = false
    @State private var signingIn = false
    @State private var subscribing = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                BrandBackdrop()
                if WideLayout.fits(geo.size) {
                    // Unfolded iPhone Duo, iPad: the greeting on one half, the ways to add a key on the other.
                    HStack(spacing: WideLayout.gap) {
                        greeting.frame(maxWidth: .infinity)
                        actions.frame(maxWidth: 420).frame(maxWidth: .infinity)
                    }
                    .padding(24)
                    .frame(maxWidth: WideLayout.maxWidth)
                    .padding(WideLayout.centering(geo))
                } else {
                    // The ways in don't fit a small screen under the greeting: then it all scrolls.
                    ScrollView {
                        VStack(spacing: 12) {
                            Spacer(minLength: 0)
                            greeting
                            Spacer(minLength: 12)
                            actions
                        }
                        .padding(24)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .disabled(model.importing)
        }
        .sheet(isPresented: $manual) { ManualKeySheet { model.submitKey($0) } }
        .sheet(isPresented: $signingIn) { SignInSheet().environmentObject(model) }
        #if PURCHASES
        .sheet(isPresented: $subscribing) { SubscribeSheet().environmentObject(model) }
        #endif
        .fullScreenCover(isPresented: $scanning) {
            ScannerView(title: "Сканирование QR-кода", hint: "Наведите камеру на QR-код с ключом") { model.submitKey($0) }
        }
        #if DEMO
        .onAppear { signingIn = Demo.signIn }
        #endif
    }

    private var greeting: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 120)
                .foregroundColor(.primary)
            Text("Добро пожаловать")
                .font(.title.weight(.semibold))
                .padding(.top, 24)
            Text("Добавьте ключ FurkVPN, чтобы подключиться")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if model.importing {
                ProgressView("Загружаем подписку…")
                    .padding(.bottom, 24)
            }
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    wideButton("Вставить ключ", icon: "doc.on.clipboard", prominent: true) {
                        model.submitKey(UIPasteboard.general.string)
                    }
                    if CameraInfo.available {
                        wideButton("Сканировать QR-код", icon: "qrcode.viewfinder") { scanning = true }
                    }
                    wideButton("Добавить из Telegram", icon: "paperplane.fill") { openLink(model.config.telegramBotUrl) }
                    Text("Бот пришлёт ссылку — просто нажмите на неё")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // The site's page that adds the key to the app, a code by email or Sign in with Apple.
                    wideButton("Войти через сайт", icon: "globe") { signingIn = true }
                    #if PURCHASES
                    wideButton("Оформить подписку", icon: "bag") { subscribing = true }
                    #endif
                }
            }
            Button("Ввести ключ вручную") { manual = true }
                .padding(.top, 4)
        }
    }

    private func wideButton(_ title: String, icon: String, prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .glassButtonStyle(prominent: prominent)
        .controlSize(.large)
    }
}
