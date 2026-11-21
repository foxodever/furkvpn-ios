import SwiftUI
import UIKit

struct SettingsView: View {
    /** The main screen shows the server list next to it: the side can be chosen. */
    var wide = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var changeKey = false
    @State private var manual = false
    @State private var scanningTv = false
    @State private var scannedTvCode: String?
    @State private var confirmingTvSend = false
    @AppStorage(GlassStyle.key, store: Store.defaults) private var glassStyle = GlassStyle.liquid.rawValue

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
                    .disabled(model.refreshing)
                    Picker("Автообновление подписки", selection: $model.subscriptionUpdateHours) {
                        ForEach(UpdateInterval.choices, id: \.self) { hours in
                            Text(intervalTitle(hours)).tag(hours)
                        }
                    }
                    Button("Сменить ключ") { changeKey = true }
                    Button("Удалить ключ", role: .destructive) { confirmLogout = true }
                }
                // The TV's QR code is scanned with this phone's camera (not with a Mac's).
                if CameraInfo.available && !Platform.isMac {
                    Section(footer: Text("Отсканируйте QR-код с экрана FurkVPN на телевизоре")) {
                        Button {
                            scannedTvCode = nil
                            scanningTv = true
                        } label: { Label("Подключить телевизор", systemImage: "tv") }
                    }
                }
                Section(header: Text("VPN")) {
                    NavigationLink(destination: RoutingView()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Маршрутизация")
                            Text("Свои правила: напрямую, через VPN, блокировать").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    // A Mac has no such page: VPN is in System Settings → VPN.
                    if !Platform.isMac {
                        Button("Системные настройки VPN") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Section(footer: Text("Проверяем сайты при смене сети и, если оператор включил белые списки, переключаем на «Автовыбор LTE»")) {
                    Toggle("Определять белые списки", isOn: $model.whitelistDetect)
                }
                Section(footer: Text("Если iOS остановит VPN — из-за сбоя, смены сети или нехватки памяти, — придёт уведомление с причиной. Ещё уведомим, когда белые списки сменят сервер.")) {
                    Toggle("Уведомлять об отключении VPN", isOn: Binding(get: { model.notifyStops }, set: { model.setNotifyStops($0) }))
                }
                Section(footer: Text("iOS сама подключит VPN снова, если он отключится не по вашей команде. Кнопка «Отключить» выключает и это.")) {
                    Toggle("Переподключаться автоматически", isOn: $model.autoReconnect)
                }
                if AllNetworks.available {
                    Section(footer: Text("Уведомления Telegram, WhatsApp, почты и других приложений приходят через VPN, как и остальной трафик телефона. Помогает, когда оператор режет серверы Apple или включает белые списки. Звонки и СМС оператора, AirDrop и часы остаются напрямую. Если VPN включён, он переподключится.")) {
                        Toggle("Уведомления через VPN", isOn: $model.pushThroughVPN)
                    }
                }
                Section(footer: Text(pingOnOpenFooter)) {
                    Toggle("Проверять пинг при открытии", isOn: $model.pingOnOpen)
                }
                if wide || GlassStyle.available {
                    Section(header: Text("Интерфейс"), footer: interfaceFooter) {
                        if GlassStyle.available {
                            Picker("Стекло", selection: $glassStyle) {
                                ForEach(GlassStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                        }
                        if wide { Toggle("Список серверов слева", isOn: $model.serversOnLeft) }
                    }
                }
                if !Platform.fromAppStore {
                    Section(header: Text("Диагностика")) {
                        NavigationLink(destination: DiagnosticsView()) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Диагностика VPN")
                                Text("Почему VPN не подключается").font(.caption).foregroundColor(.secondary)
                            }
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
            .barItem(.confirmationAction) { Button("Готово") { dismiss() } }
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
            .fullScreenCover(isPresented: $scanningTv, onDismiss: confirmScannedTvCode) {
                ScannerView(title: "Подключить телевизор", hint: "Наведите камеру телефона на QR-код на экране телевизора") {
                    scannedTvCode = $0
                }
            }
            .alert("Отправить ключ на телевизор?", isPresented: $confirmingTvSend, presenting: scannedTvCode) { code in
                Button("Отправить") {
                    scannedTvCode = nil
                    model.sendTvKey(code)
                }
                Button("Отмена", role: .cancel) { scannedTvCode = nil }
            } message: { code in
                Text("Телевизор с кодом \(KeyAlerts.display(code)) подключится к вашей подписке FurkVPN.")
            }
            .keyAlerts()
            .toast($model.toast)
        }
        .navigationViewStyle(.stack)
        .sheetGlass()
    }

    private func confirmScannedTvCode() {
        guard let scannedTvCode else { return }
        self.scannedTvCode = Core.tvCode(scannedTvCode)
        if self.scannedTvCode == nil {
            model.show("Это не QR-код подключения телевизора.")
        } else {
            confirmingTvSend = true
        }
    }

    private var pingOnOpenFooter: String {
        let one = Platform.isMac ? "правым кликом по серверу" : "удержанием сервера"
        return "При первом открытии списка серверов приложение проверяет пинг всех серверов. Это занимает время и расходует батарею — на старых iPhone заметно. Если выключить, пинг проверяется кнопкой «Проверить пинг» или \(one)."
    }

    private var interfaceFooter: Text {
        var lines: [String] = []
        if GlassStyle.available {
            lines.append("Жидкое стекло — как в самой iOS и следует её настройке: «Прозрачное» или «Тонированное» в iOS 26, ползунок прозрачности в iOS 27, «Понижение прозрачности». Матовое — размытие без преломления и бликов. Без стекла — плоские карточки, кнопки и шторки. На тёмном фоне жидкое и матовое стекло почти не отличаются.")
        }
        if wide { lines.append("Список серверов слева удобен левшам — на iPad и раскрытом iPhone Duo.") }
        return Text(lines.joined(separator: "\n\n"))
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

/**
 * Where the VPN can break, mostly after re-signing the IPA: ids, the profile, the App Group, the last error.
 * Not in the App Store's copy of the app (Platform.fromAppStore).
 */
private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    /** What the running extension says about itself; nil when it doesn't run or answer. */
    @State private var core: String?
    @State private var loading = false
    @State private var debugMode = Store.debugMode

    private func loadCore() async {
        loading = true
        defer { loading = false }
        let (data, why) = await vpn.sendExplained(.debug(url: model.config.delayTestUrl))
        guard let data, let d = try? JSONDecoder().decode(TunnelDebug.self, from: data) else {
            core = vpn.isConnected ? "Расширение не ответило: \(data == nil ? why : "непонятный ответ")" : nil
            return
        }
        core = """
        Ядро: \(d.running ? "работает" : "остановлено") · \(d.server ?? "—")
        Туннель: дескриптор \(d.descriptor) (\(d.interface ?? "не utun"))
        Из туннеля ↑ \(d.up) байт · в туннель ↓ \(d.down) байт
        Запрос через ядро из расширения: \(d.check)

        \(d.log)
        """
    }

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
            Section(header: Text("Расширение VPN"), footer: Text(core == nil ? "Подключите VPN и нажмите «Обновить»: расширение покажет, читает ли ядро пакеты туннеля, и последние ошибки и соединения." : "")) {
                if let core {
                    Text(core).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
                Button(loading ? "Загрузка…" : "Обновить") { Task { await loadCore() } }.disabled(loading)
            }
            Section(footer: Text("Для отладки. Включите и подключите VPN: через 15 секунд он сам отключится и покажет отчёт расширения в «Последней ошибке» выше. Режим действует на одно подключение и потом выключается сам.")) {
                Toggle("Режим отладки VPN", isOn: $debugMode)
                    .onChange(of: debugMode) { Store.debugMode = $0 }
            }
            Section {
                Button("Скопировать всё") {
                    UIPasteboard.general.string = rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n" + (core ?? "")
                    model.show("Скопировано")
                }
            }
        }
        .task {
            await vpn.refreshLastError()
            await loadCore()
        }
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
    }
}
