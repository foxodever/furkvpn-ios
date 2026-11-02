import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var changeKey = false
    @State private var manual = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Подписка"), footer: updatedAt) {
                    Button {
                        model.refreshSubscription(showMessage: true)
                    } label: {
                        HStack {
                            Text("Обновить подписку")
                            Spacer()
                            if model.refreshing { ProgressView() }
                        }
                    }
                    Picker("Автообновление подписки", selection: $model.subscriptionUpdateHours) {
                        ForEach(UpdateInterval.choices, id: \.self) { hours in
                            Text(intervalTitle(hours)).tag(hours)
                        }
                    }
                    Button("Сменить ключ") { changeKey = true }
                    Button("Удалить ключ", role: .destructive) { confirmLogout = true }
                }
                Section(header: Text("VPN")) {
                    NavigationLink(destination: RoutingView()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Маршрутизация")
                            Text("Свои правила: напрямую, через VPN, блокировать").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button("Системные настройки VPN") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section(header: Text("Поддержка")) {
                    ForEach(model.config.support, id: \.self) { contact in
                        Button(contact.title) { openLink(contact.url) }
                    }
                }
                Section(header: Text("О приложении")) {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(Http.appVersion).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Ядро Xray")
                        Spacer()
                        Text(Core.xrayVersion).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .confirmationDialog("Удалить ключ?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Удалить ключ", role: .destructive) {
                    model.logout()
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Ключ будет удалён с этого устройства. Его можно добавить снова в любой момент.")
            }
            .confirmationDialog("Сменить ключ", isPresented: $changeKey) {
                Button("Вставить ключ") { model.submitKey(UIPasteboard.general.string) }
                Button("Ввести ключ вручную") { manual = true }
                Button("Отмена", role: .cancel) {}
            }
            .sheet(isPresented: $manual) { ManualKeySheet { model.submitKey($0) } }
            .keyAlerts()
            .toast($model.toast)
        }
        .navigationViewStyle(.stack)
    }

    private var updatedAt: some View {
        Group {
            if let fetched = model.subscription?.fetchedAt {
                Text("Обновлено \(Format.dateTime(fetched))")
            }
        }
    }

    private func intervalTitle(_ hours: Int) -> String {
        switch hours {
        case UpdateInterval.fromSubscription: return "Как в подписке (\(model.subscription?.updateIntervalHours ?? 6) ч)"
        case UpdateInterval.manual: return "Только вручную"
        default: return (hours == 1 ? "Каждый " : "Каждые ") + Format.hours(hours)
        }
    }
}
