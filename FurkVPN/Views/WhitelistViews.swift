import SwiftUI

// "Белые списки" on the main screen and its details, as in the Android app (ui/home/Whitelist.kt).

private extension WhitelistStatus {
    var text: String {
        switch self {
        case .allOk: return "Сейчас у вас работают все сервисы"
        case .whitelist: return "Сейчас работают только сервисы из белого списка"
        case .noInternet: return "Сейчас у вас ничего не работает"
        case .unknown: return "Проверяем…"
        }
    }

    var color: Color {
        switch self {
        case .allOk: return .good
        case .whitelist: return .orange
        case .noInternet: return .red
        case .unknown: return .secondary
        }
    }
}

/** Hidden when the detection is off in Settings. */
struct WhitelistCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var details = false

    /** Another app's VPN, while ours is off (connecting ours turns it off). */
    private var otherVPN: Bool { model.otherVPN && vpn.state == .idle }

    var body: some View {
        if model.whitelistDetect {
            Button { details = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Белые списки").font(.headline)
                        Text(otherVPN ? "Включён другой VPN — проверка не покажет, что блокирует оператор" : status.text)
                            .font(.subheadline)
                            .foregroundColor(otherVPN ? .orange : .secondary)
                            .wraps()
                        Text("Подробнее").font(.subheadline.weight(.semibold)).foregroundColor(.accentColor).padding(.top, 2)
                    }
                    Spacer()
                    if otherVPN {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).frame(width: 24, height: 24)
                    } else {
                        StatusDot(status: status, checking: model.whitelistChecking)
                    }
                }
                .foregroundColor(.primary)
                .card()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $details) {
                WhitelistSheet().environmentObject(model).environmentObject(vpn)
            }
        }
    }

    private var status: WhitelistStatus { model.whitelistCheck?.status ?? .unknown }
}

private struct StatusDot: View {
    var status: WhitelistStatus
    var checking: Bool

    var body: some View {
        ZStack {
            if checking {
                ProgressView()
            } else {
                Circle().fill(status.color).frame(width: 12, height: 12)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/** When the sites were checked, how each one answered, and that it was done without the VPN. */
private struct WhitelistSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let check = model.whitelistCheck
        let status = check?.status ?? .unknown
        NavigationView {
            List {
                if model.otherVPN && vpn.state == .idle {
                    Section {
                        Label("Включён другой VPN. Пока он работает, сайты открываются через него, и проверка не покажет, что блокирует оператор. Выключите его или подключите FurkVPN — тогда проверит наш VPN.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        StatusDot(status: status, checking: false)
                        Text(status.text).wraps()
                    }
                    if let check {
                        Text("Последняя проверка: \(Format.dateTime(check.time)) · сеть: \(networkName(check.network))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Проверки ещё не было").font(.subheadline).foregroundColor(.secondary)
                    }
                }
                if let check {
                    probes("Закрываются белыми списками", check.blocked)
                    probes("Открыты и при белых списках", check.allowed)
                }
                Section(footer: Text("Если Google не отвечает, а VK и Яндекс открываются, значит, оператор включил белые списки.")) {
                    Label("Проверка выполняется без VPN — напрямую через вашего оператора, поэтому видно, что он блокирует на самом деле.",
                          systemImage: "info.circle")
                        .font(.subheadline)
                }
                Section {
                    Button {
                        model.checkWhitelist()
                    } label: {
                        HStack {
                            Text("Проверить снова")
                            Spacer()
                            if model.whitelistChecking { ProgressView() }
                        }
                    }
                    .disabled(model.whitelistChecking)
                }
            }
            .navigationTitle("Белые списки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }

    private func probes(_ title: String, _ results: [ProbeResult]) -> some View {
        Section(header: Text(title)) {
            ForEach(results, id: \.self) { probe in
                HStack(spacing: 12) {
                    Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(probe.ok ? .good : .red)
                    Text(probe.host)
                    Spacer()
                    Text(answer(probe))
                        .font(.subheadline)
                        .foregroundColor(probe.ok ? .secondary : .red)
                }
            }
        }
    }

    private func answer(_ probe: ProbeResult) -> String {
        switch probe.error {
        case nil: return "отвечает · \(probe.ms ?? 0) мс"
        case "TIMEOUT": return "нет ответа"
        case "DNS": return "адрес не найден"
        case "CONNECT": return "не подключается"
        case "TLS": return "ошибка TLS"
        default: return "недоступен"
        }
    }

    private func networkName(_ kind: String) -> String {
        switch kind {
        case "wifi": return "Wi-Fi"
        case "cellular": return "мобильная"
        case "ethernet": return "Ethernet"
        case "none": return "нет сети"
        default: return "другая"
        }
    }
}
