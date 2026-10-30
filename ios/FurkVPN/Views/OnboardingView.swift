import SwiftUI
import UIKit

/** Welcome screen: a FurkVPN key from the clipboard, typed by hand, from the bot or from the site. */
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manual = false
    @State private var siteLogin = false

    var body: some View {
        ZStack {
            Color.brandBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer()
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120)
                    .foregroundColor(.primary)
                Text("Добро пожаловать")
                    .font(.title.bold())
                    .padding(.top, 24)
                Text("Добавьте ключ FurkVPN, чтобы подключиться")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                if model.importing {
                    ProgressView("Загружаем подписку…")
                        .padding(.bottom, 24)
                }
                Button {
                    model.submitKey(UIPasteboard.general.string)
                } label: {
                    Label("Вставить ключ", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    openLink(model.config.telegramBotUrl)
                } label: {
                    Label("Войти через Telegram", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("Бот пришлёт ссылку — просто нажмите на неё")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    siteLogin = true
                } label: {
                    Label("Войти через сайт", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Ввести ключ вручную") { manual = true }
                    .padding(.top, 4)
            }
            .disabled(model.importing)
            .padding(24)
            .frame(maxWidth: 480)
        }
        .sheet(isPresented: $manual) { ManualKeySheet { model.submitKey($0) } }
        .confirmationDialog("Выберите, как войти в личный кабинет", isPresented: $siteLogin, titleVisibility: .visible) {
            Button("Войти через браузер") { openLink(model.config.site.installUrl) }
            Button("Войти по почте") { model.show("В разработке") }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Откроется \(model.config.site.domain)")
        }
    }
}
