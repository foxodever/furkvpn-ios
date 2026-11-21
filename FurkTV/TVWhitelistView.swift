import SwiftUI

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

    var icon: String {
        switch self {
        case .allOk: return "checkmark.shield.fill"
        case .whitelist: return "list.bullet.rectangle.fill"
        case .noInternet: return "wifi.exclamationmark"
        case .unknown: return "shield.lefthalf.filled"
        }
    }

    /** The badge keeps the accent while nothing is known yet: grey looks disabled. */
    var badgeTint: Color {
        self == .unknown ? .accentColor : color
    }
}

/** Focusable whitelist status card on the Apple TV home dashboard; hidden when disabled in Settings. */
struct TVWhitelistCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var showDetails = false

    private var otherVPN: Bool { model.otherVPN && vpn.state == .idle }
    private var status: WhitelistStatus { model.whitelistCheck?.status ?? .unknown }

    var body: some View {
        if model.whitelistDetect {
            Button {
                showDetails = true
            } label: {
                HStack(spacing: 20) {
                    TVIconBadge(
                        systemImage: otherVPN ? "exclamationmark.triangle.fill" : status.icon,
                        tint: otherVPN ? .orange : status.badgeTint
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Белые списки")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(otherVPN ? "Включён другой VPN — проверка не покажет, что блокирует оператор" : status.text)
                            .font(.caption)
                            .foregroundStyle(otherVPN ? Color.orange : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 12)
                    if !otherVPN {
                        TVWhitelistDot(status: status, checking: model.whitelistChecking)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, TVMetrics.cardPadding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TVCardButtonStyle())
            .sheet(isPresented: $showDetails) {
                TVWhitelistSheet()
                    .environmentObject(model)
                    .environmentObject(vpn)
            }
        }
    }
}

private struct TVWhitelistDot: View {
    var status: WhitelistStatus
    var checking: Bool

    var body: some View {
        ZStack {
            if checking {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/** Detailed whitelist probe results in a remote-scrollable list. */
private struct TVWhitelistSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let check = model.whitelistCheck
        let status = check?.status ?? .unknown
        TVSidePanelScreen(
            systemImage: status.icon,
            title: "Белые списки",
            subtitle: status.text,
            tint: status.badgeTint
        ) {
            List {
                if model.otherVPN && vpn.state == .idle {
                    Section {
                        Button {} label: {
                            Label(
                                "Включён другой VPN. Пока он работает, сайты открываются через него, и проверка не покажет, что блокирует оператор. Выключите его или подключите FurkVPN — тогда проверит наш VPN.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.callout)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                TVWhitelistDot(status: status, checking: false)
                                Text(status.text)
                                    .font(.headline)
                                    .wraps()
                            }
                            if let check {
                                Text("Последняя проверка: \(Format.dateTime(check.time)) · сеть: \(networkName(check.network))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Проверки ещё не было")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let check {
                    probes("Закрываются белыми списками", check.blocked)
                    probes("Открыты и при белых списках", check.allowed)
                }
                Section(footer: Text("Если Google не отвечает, а VK и Яндекс открываются, значит, оператор включил белые списки.")) {
                    Button {} label: {
                        Label(
                            "Проверка выполняется без VPN — напрямую через вашего оператора, поэтому видно, что он блокирует на самом деле.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
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

                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func probes(_ title: String, _ results: [ProbeResult]) -> some View {
        Section(header: Text(title)) {
            ForEach(results, id: \.self) { probe in
                Button {} label: {
                    HStack(spacing: 16) {
                        Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(probe.ok ? Color.good : Color.red)
                        Text(probe.host)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(answer(probe))
                            .font(.callout)
                            .foregroundStyle(probe.ok ? Color.secondary : Color.red)
                    }
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
