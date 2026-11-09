import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var changeKey = false
    @State private var manual = false
    @State private var scanningTv = false

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
                // The TV's QR code is scanned with this phone's camera.
                if CameraInfo.available {
                    Section(footer: Text("Отсканируйте QR-код с экрана FurkVPN на телевизоре")) {
                        Button { scanningTv = true } label: { Label("Подключить телевизор", systemImage: "tv") }
                    }
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
                Section(header: Text("Диагностика")) {
                    NavigationLink(destination: DiagnosticsView()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Диагностика VPN")
                            Text("Почему VPN не подключается").font(.caption).foregroundColor(.secondary)
                        }
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
                    Button("Политика конфиденциальности") { openLink(model.config.site.privacyUrl) }
                    Button("Пользовательское соглашение") { openLink(model.config.site.termsUrl) }
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
            .fullScreenCover(isPresented: $scanningTv) {
                ScannerView(title: "Подключить телевизор", hint: "Наведите камеру телефона на QR-код на экране телевизора") {
                    model.submitKey($0)
                }
            }
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

/** Where the VPN can break, mostly after re-signing the IPA: ids, the profile, the App Group, the last error. */
private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController

    var body: some View {
        let rows = vpn.diagnostics
        Form {
            Section(footer: Text("Если ID расширения и профиля разные или нет App Group — так подписан IPA. Сервер всё равно передаётся при подключении.")) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption).foregroundColor(.secondary)
                        Text(row.1).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button("Скопировать") {
                    UIPasteboard.general.string = rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                    model.show("Скопировано")
                }
            }
        }
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
    }
}
