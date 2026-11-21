import SwiftUI

/**
 * Settings on Apple TV: subscription management, routing, VPN behavior, layout, diagnostics (non-App Store)
 * and version info — without external links (treated as an extension of the mobile app).
 */
struct TVSettingsView: View {
    var onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var confirmLogout = false
    @State private var showPairing = false
    @State private var showManual = false
    @State private var pendingManualKey: String?
    @AppStorage(TVGlassStyle.key, store: Store.defaults) private var glassStyle = TVGlassStyle.liquid.rawValue

    var body: some View {
        TVSidePanelScreen(systemImage: "gearshape.fill", title: "Настройки", subtitle: panelSubtitle) {
            form
        }
        .navigationDestination(isPresented: $showPairing) {
            TVPairingView(title: "Сменить ключ") {
                showPairing = false
                onClose()
            }
        }
        .sheet(isPresented: $showManual, onDismiss: submitPendingManualKey) {
            TVManualKeyView { key in
                pendingManualKey = key
            }
        }
        .alert("Удалить ключ?", isPresented: $confirmLogout) {
            Button("Удалить ключ", role: .destructive) {
                Task {
                    if await model.logoutNow() {
                        onClose()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ключ будет удалён с этого Apple TV. Его можно добавить снова в любой момент.")
        }
    }

    /** The subscription's name and the app's version under the panel's title. */
    private var panelSubtitle: String {
        let title = model.subscription?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "FurkVPN"
        return "\(title)\nВерсия \(Http.appVersion)"
    }

    private var form: some View {
        Form {
            Section(header: Text("Подписка"), footer: updatedAt) {
                Button {
                    model.refreshSubscription(showMessage: true)
                } label: {
                    HStack {
                        Label("Обновить подписку", systemImage: "arrow.clockwise")
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

                Button {
                    showPairing = true
                } label: {
                    Label("Сменить ключ по QR-коду", systemImage: "qrcode")
                }

                Button {
                    pendingManualKey = nil
                    showManual = true
                } label: {
                    Label("Ввести ключ вручную", systemImage: "keyboard")
                }

                Button(role: .destructive) {
                    confirmLogout = true
                } label: {
                    HStack {
                        Label("Удалить ключ", systemImage: "trash")
                        Spacer()
                        if model.loggingOut { ProgressView() }
                    }
                }
                .disabled(model.loggingOut)
            }

            Section(header: Text("VPN")) {
                NavigationLink(destination: TVRoutingView()) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Маршрутизация")
                            Text("Свои правила: напрямую, через VPN, блокировать")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                }
            }

            Section(footer: Text("tvOS сама подключит VPN снова, если он отключится не по вашей команде. Кнопка «Отключиться» выключает и это.")) {
                Toggle("Переподключаться автоматически", isOn: $model.autoReconnect)
            }

            Section(footer: Text("Проверяем сайты при смене сети и, если оператор включил белые списки, переключаем на «Автовыбор LTE».")) {
                Toggle("Определять белые списки", isOn: $model.whitelistDetect)
            }

            Section(footer: Text("При первом открытии экрана приложение проверяет пинг всех серверов. Если выключить, пинг проверяется кнопкой «Пинг» или удержанием кнопки выбора на сервере.")) {
                Toggle("Проверять пинг при открытии", isOn: $model.pingOnOpen)
            }

            Section(header: Text("Интерфейс"), footer: interfaceFooter) {
                if TVGlassStyle.available {
                    Picker("Стекло", selection: $glassStyle) {
                        ForEach(TVGlassStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                }
                Toggle("Список серверов слева", isOn: $model.serversOnLeft)
            }

            if !Platform.fromAppStore {
                Section(header: Text("Диагностика")) {
                    NavigationLink(destination: TVDiagnosticsView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Диагностика VPN")
                                Text("Почему VPN не подключается")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "stethoscope")
                        }
                    }
                }
            }

            Section(header: Text("О приложении")) {
                HStack {
                    Text("Версия")
                    Spacer()
                    Text(Http.appVersion)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Ядро Xray")
                    Spacer()
                    Text(Core.xrayVersion)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func submitPendingManualKey() {
        guard let key = pendingManualKey else { return }
        pendingManualKey = nil
        model.submitKey(key)
    }

    @ViewBuilder
    private var updatedAt: some View {
        if let fetched = model.subscription?.fetchedAt {
            Text("Обновлено \(Format.dateTime(fetched))")
        }
    }

    private var interfaceFooter: Text {
        if TVGlassStyle.available {
            return Text("Стиль стеклянных поверхностей на tvOS 26 и расположение списка серверов на главном экране.")
        }
        return Text("Переносит список серверов в левую часть главного экрана.")
    }
}

/** VPN profile, signing, and live tunnel extension diagnostics (omitted in App Store builds). */
private struct TVDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
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
        TVSidePanelScreen(systemImage: "stethoscope", title: "Диагностика", subtitle: "Почему VPN не подключается: профиль, подпись и отчёт расширения") {
            diagnosticsForm(rows)
        }
        .task {
            await vpn.refreshLastError()
            await loadCore()
        }
    }

    private func diagnosticsForm(_ rows: [(String, String)]) -> some View {
        Form {
            Section(footer: Text("Если ID расширения и профиля разные или нет App Group — так подписана сборка. Сервер всё равно передаётся при подключении.")) {
                ForEach(rows, id: \.0) { row in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.0)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.1)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .wraps()
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Section(
                header: Text("Расширение VPN"),
                footer: Text(core == nil ? "Подключите VPN и нажмите «Обновить»: расширение покажет, читает ли ядро пакеты туннеля, и последние ошибки и соединения." : "")
            ) {
                if let core {
                    Button {} label: {
                        Text(core)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .wraps()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(loading ? "Загрузка…" : "Обновить") {
                    Task { await loadCore() }
                }
                .disabled(loading)
            }
            Section(footer: Text("Для отладки. Включите и подключите VPN: через 15 секунд он сам отключится и покажет отчёт расширения в «Последней ошибке» выше. Режим действует на одно подключение и потом выключается сам.")) {
                Toggle("Режим отладки VPN", isOn: $debugMode)
                    .onChange(of: debugMode) { _, value in
                        Store.debugMode = value
                    }
            }
        }
    }
}
