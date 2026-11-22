import SwiftUI
import UIKit

struct SettingsView: View {
    /** The main screen shows the server list next to it: the side can be chosen. */
    var wide = false
    #if os(tvOS)
    /**
     * Inside the Apple TV Настройки tab: the tab bar names the screen and the tab draws the backdrop and the
     * sidebar, so the form brings neither a title nor a background of its own.
     */
    var embedded = false
    #endif
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var manual = false
    #if os(tvOS)
    @State private var showPairing = false
    @State private var pendingManualKey: String?
    #else
    @State private var changeKey = false
    @State private var scanningTv = false
    @State private var scannedTvCode: String?
    @State private var confirmingTvSend = false
    #endif
    @AppStorage(GlassStyle.key, store: Store.defaults) private var glassStyle = GlassStyle.liquid.rawValue

    var body: some View {
        #if os(tvOS)
        Group {
            if embedded {
                settingsForm
                    .tint(.primary)
            } else {
                TVDetailLayout(icon: "gearshape.fill", caption: "FurkVPN для Apple TV\nВерсия \(Http.appVersion)") {
                    settingsForm
                }
            }
        }
        .navigationTitle(embedded ? "" : "Настройки")
        .navigationDestination(isPresented: $showPairing) {
            TVPairingView(title: "Сменить ключ") {
                showPairing = false
                dismiss()
            }
        }
        .alert("Удалить ключ?", isPresented: $confirmLogout) {
            Button("Удалить ключ", role: .destructive) {
                Task {
                    if await model.logoutNow() {
                        dismiss()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ключ будет удалён с этого Apple TV. Его можно добавить снова в любой момент.")
        }
        .fullScreenCover(isPresented: $manual, onDismiss: submitPendingManualKey) {
            ManualKeySheet { pendingManualKey = $0 }
        }
        #else
        NavigationView {
            settingsForm
                .navigationTitle("Настройки")
                .navigationBarTitleDisplayMode(.inline)
                .barItem(.confirmationAction) { Button("Готово") { dismiss() } }
                .confirmationDialog("Удалить ключ?", isPresented: $confirmLogout, titleVisibility: .visible) {
                    Button("Удалить ключ", role: .destructive) {
                        Task {
                            if await model.logoutNow() {
                                dismiss()
                            }
                        }
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
        #endif
    }

    private var settingsForm: some View {
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
                        Text(Format.updateInterval(hours, subscriptionDefault: model.subscription?.updateIntervalHours))
                            .tag(hours)
                    }
                }
                #if os(tvOS)
                Button("Сменить ключ по QR-коду") { showPairing = true }
                Button("Ввести ключ вручную") {
                    pendingManualKey = nil
                    manual = true
                }
                Button(role: .destructive) {
                    confirmLogout = true
                } label: {
                    HStack {
                        Text("Удалить ключ")
                        Spacer()
                        if model.loggingOut { ProgressView() }
                    }
                }
                .disabled(model.loggingOut)
                #else
                Button("Сменить ключ") { changeKey = true }
                Button("Удалить ключ", role: .destructive) { confirmLogout = true }
                #endif
            }
            #if !os(tvOS)
            // The TV's QR code is scanned with this phone's camera (not with a Mac's).
            if CameraInfo.available && !Platform.isMac {
                Section(footer: Text("Отсканируйте QR-код с экрана FurkVPN на телевизоре")) {
                    Button {
                        scannedTvCode = nil
                        scanningTv = true
                    } label: { Label("Подключить телевизор", systemImage: "tv") }
                }
            }
            #endif
            Section(header: Text("VPN")) {
                NavigationLink(destination: RoutingView()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Маршрутизация")
                        Text("Свои правила: напрямую, через VPN, блокировать").font(.caption).foregroundColor(.secondary)
                    }
                }
                #if !os(tvOS)
                // A Mac has no such page: VPN is in System Settings → VPN.
                if !Platform.isMac {
                    Button("Системные настройки VPN") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                #endif
            }
            Section(footer: Text("Проверяем сайты при смене сети и, если оператор включил белые списки, переключаем на «Автовыбор LTE»")) {
                Toggle("Определять белые списки", isOn: $model.whitelistDetect)
            }
            #if !os(tvOS)
            Section(footer: Text("Если iOS остановит VPN — из-за сбоя, смены сети или нехватки памяти, — придёт уведомление с причиной. Ещё уведомим, когда белые списки сменят сервер.")) {
                Toggle("Уведомлять об отключении VPN", isOn: Binding(get: { model.notifyStops }, set: { model.setNotifyStops($0) }))
            }
            #endif
            Section(footer: Text(autoReconnectFooter)) {
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
            #if !os(tvOS)
            Section(header: Text("Поддержка")) {
                ForEach(model.config.support, id: \.self) { contact in
                    Button(contact.title) { openLink(contact.url) }
                }
            }
            #endif
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
                #if !os(tvOS)
                Button("Политика конфиденциальности") { openLink(model.config.site.privacyUrl) }
                Button("Пользовательское соглашение") { openLink(model.config.site.termsUrl) }
                #endif
            }
        }
    }

    #if os(tvOS)
    private func submitPendingManualKey() {
        guard let key = pendingManualKey else { return }
        pendingManualKey = nil
        model.submitKey(key)
    }
    #else
    private func confirmScannedTvCode() {
        guard let scannedTvCode else { return }
        self.scannedTvCode = Core.tvCode(scannedTvCode)
        if self.scannedTvCode == nil {
            model.show("Это не QR-код подключения телевизора.")
        } else {
            confirmingTvSend = true
        }
    }
    #endif

    private var autoReconnectFooter: String {
        #if os(tvOS)
        return "tvOS сама подключит VPN снова, если он отключится не по вашей команде. Кнопка «Отключиться» выключает и это."
        #else
        return "iOS сама подключит VPN снова, если он отключится не по вашей команде. Кнопка «Отключить» выключает и это."
        #endif
    }

    private var pingOnOpenFooter: String {
        #if os(tvOS)
        return "При первом открытии экрана приложение проверяет пинг всех серверов. Если выключить, пинг проверяется кнопкой пинга или удержанием кнопки выбора на сервере."
        #else
        let one = Platform.isMac ? "правым кликом по серверу" : "удержанием сервера"
        return "При первом открытии списка серверов приложение проверяет пинг всех серверов. Это занимает время и расходует батарею — на старых iPhone заметно. Если выключить, пинг проверяется кнопкой «Проверить пинг» или \(one)."
        #endif
    }

    private var interfaceFooter: Text {
        var lines: [String] = []
        if GlassStyle.available {
            #if os(tvOS)
            lines.append("Жидкое стекло — как в самой tvOS. Матовое — размытие без преломления. Без стекла — плоские карточки и кнопки.")
            #else
            lines.append("Жидкое стекло — как в самой iOS и следует её настройке: «Прозрачное» или «Тонированное» в iOS 26, ползунок прозрачности в iOS 27, «Понижение прозрачности». Матовое — размытие без преломления и бликов. Без стекла — плоские карточки, кнопки и шторки. На тёмном фоне жидкое и матовое стекло почти не отличаются.")
            #endif
        }
        if wide {
            #if os(tvOS)
            lines.append("Переносит список серверов в левую часть главного экрана.")
            #else
            lines.append("Список серверов слева удобен левшам — на iPad и раскрытом iPhone Duo.")
            #endif
        }
        return Text(lines.joined(separator: "\n\n"))
    }

    private var updatedAt: some View {
        Group {
            if let fetched = model.subscription?.fetchedAt {
                Text("Обновлено \(Format.dateTime(fetched))")
            }
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
        let form = Form {
            Section(footer: Text("Если ID расширения и профиля разные или нет App Group — так подписана сборка. Сервер всё равно передаётся при подключении.")) {
                ForEach(rows, id: \.0) { row in
                    infoRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.caption).foregroundColor(.secondary)
                            #if os(tvOS)
                            Text(row.1).font(.subheadline).wraps()
                            #else
                            Text(row.1).font(.subheadline).textSelection(.enabled)
                            #endif
                        }
                    }
                }
            }
            Section(header: Text("Расширение VPN"), footer: Text(core == nil ? "Подключите VPN и нажмите «Обновить»: расширение покажет, читает ли ядро пакеты туннеля, и последние ошибки и соединения." : "")) {
                if let core {
                    infoRow {
                        #if os(tvOS)
                        Text(core).font(.system(.caption2, design: .monospaced)).wraps()
                        #else
                        Text(core).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        #endif
                    }
                }
                Button(loading ? "Загрузка…" : "Обновить") { Task { await loadCore() } }.disabled(loading)
            }
            Section(footer: Text("Для отладки. Включите и подключите VPN: через 15 секунд он сам отключится и покажет отчёт расширения в «Последней ошибке» выше. Режим действует на одно подключение и потом выключается сам.")) {
                Toggle("Режим отладки VPN", isOn: $debugMode)
                    #if os(tvOS)
                    .onChange(of: debugMode) { _, value in Store.debugMode = value }
                    #else
                    .onChange(of: debugMode) { Store.debugMode = $0 }
                    #endif
            }
            #if !os(tvOS)
            Section {
                Button("Скопировать всё") {
                    UIPasteboard.general.string = rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n" + (core ?? "")
                    model.show("Скопировано")
                }
            }
            #endif
        }
        .task {
            await vpn.refreshLastError()
            await loadCore()
        }
        .navigationTitle("Диагностика")
        .inlineNavigationBar()

        #if os(tvOS)
        TVDetailLayout(icon: "stethoscope", caption: "Почему VPN не подключается: подпись сборки, профиль и ответ расширения") {
            form
        }
        #else
        form
        #endif
    }

    @ViewBuilder
    private func infoRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        Button {} label: {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        content()
        #endif
    }
}
