import SwiftUI

/**
 * Main Apple TV dashboard: a widescreen evolution of the iPad/Mac WideLayout — the VPN hero (connect button,
 * status, live traffic), the selected server, plan, whitelist and announcement cards on one side and the live
 * filterable server list on the other, laid out edge to edge on the 1920×1080 canvas.
 * Treated as an extension of the mobile app: no external links, buy/renew buttons, support links or proxies.
 */
struct TVHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var showSettings = false
    @State private var announcementSheet: AnnouncementItem?
    @FocusState private var connectFocused: Bool

    /** The backdrop's glow sits behind the connect button, whichever side the dashboard is on. */
    private var glowCenter: UnitPoint {
        UnitPoint(x: model.serversOnLeft ? 0.76 : 0.24, y: 0.28)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBrandBackdrop(glow: glowCenter, intensity: vpn.isConnected ? 0.32 : 0.20)
                    .animation(.easeInOut(duration: 0.6), value: vpn.isConnected)
                VStack(spacing: 26) {
                    topBar
                    HStack(alignment: .top, spacing: TVMetrics.columnGap) {
                        if model.serversOnLeft {
                            TVServersPane()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        homePane
                            .frame(width: TVMetrics.homeColumn)
                            .frame(maxHeight: .infinity, alignment: .top)
                        if !model.serversOnLeft {
                            TVServersPane()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .padding(.horizontal, TVMetrics.sideMargin)
                .padding(.top, TVMetrics.topMargin)
                .padding(.bottom, TVMetrics.bottomMargin)
                .ignoresSafeArea()
            }
            .onAppear {
                connectFocused = true
                #if DEMO
                if Demo.settings { showSettings = true }
                #endif
            }
            .navigationDestination(isPresented: $showSettings) {
                TVSettingsView(onClose: { showSettings = false })
            }
            .sheet(item: $announcementSheet) { item in
                TVAnnouncementSheet(text: item.text)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 24) {
            HStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 48)
                    .foregroundStyle(.primary)
                if let title = model.subscription?.title,
                   !title.isEmpty,
                   title.caseInsensitiveCompare("FurkVPN") != .orderedSame {
                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 2, height: 40)
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 24)
            TVGlassGroup(spacing: 8) {
                HStack(spacing: 18) {
                    topBarButton("Пинг", icon: "bolt.horizontal.circle", busy: model.pinging) {
                        model.testPings()
                    }
                    topBarButton("Обновить", icon: "arrow.clockwise", busy: model.refreshing) {
                        model.refreshSubscription(showMessage: true)
                    }
                    .disabled(model.refreshing)
                    topBarButton("Настройки", icon: "gearshape") {
                        showSettings = true
                    }
                }
            }
        }
        .focusSection()
    }

    private func topBarButton(_ title: String, icon: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if busy {
                        ProgressView()
                            .scaleEffect(0.62)
                    } else {
                        Image(systemName: icon)
                            .font(.callout.weight(.semibold))
                    }
                }
                .frame(width: 32, height: 32)
                Text(title)
            }
        }
        .buttonStyle(TVPillButtonStyle())
    }

    /**
     * The dashboard column. It scrolls when it has to (a long announcement, large text), and the scroll view
     * reaches [TVMetrics.focusRoom] past the column on every side so the focus lift is never cut.
     */
    private var homePane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                TVHeroRow(state: vpn.state, action: toggleVPN)
                    .focused($connectFocused)
                    .padding(.bottom, 4)

                TVSelectedServerCard(
                    server: model.selectedServer,
                    ping: model.selectedServer.flatMap { model.pings[$0.key] }
                )

                TVAccountCard()

                TVWhitelistCard()

                if let announce = model.subscription?.announce,
                   !announce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        announcementSheet = AnnouncementItem(text: announce)
                    } label: {
                        HStack(spacing: 20) {
                            TVIconBadge(systemImage: "megaphone.fill")
                            Text(announce)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, TVMetrics.cardPadding)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(TVCardButtonStyle())
                }
            }
            .padding(TVMetrics.focusRoom)
        }
        .tvFadeEdges(.vertical, leading: 0, trailing: TVMetrics.focusRoom)
        .padding(-TVMetrics.focusRoom)
        .focusSection()
    }

    private func toggleVPN() {
        if vpn.state == .idle {
            Task {
                await vpn.loaded()
                if vpn.state == .idle {
                    await vpn.connect()
                } else if vpn.state != .stopping {
                    vpn.disconnect()
                }
            }
        } else if vpn.state != .stopping {
            vpn.disconnect()
        }
    }
}

private struct AnnouncementItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct TVAnnouncementSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSidePanelScreen(systemImage: "megaphone.fill", title: "Объявление", subtitle: "Сообщение от FurkVPN для вашей подписки") {
            List {
                Section {
                    Button {} label: {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .wraps()
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

/** The connect button with the status, timer and live traffic beside it: the dashboard's focal point. */
private struct TVHeroRow: View {
    var state: VPNController.State
    var action: () -> Void

    var body: some View {
        HStack(spacing: 36) {
            TVConnectButton(state: state, action: action)
            TVStatusPanel(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 280)
    }
}

private struct TVStatusPanel: View {
    var state: VPNController.State

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 16, height: 16)
                    .shadow(color: dotColor.opacity(0.7), radius: 6)
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
            }
            if case let .connected(since) = state {
                Text(since, style: .timer)
                    .font(.system(size: 66, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.top, 2)
                TVTrafficRow()
                    .padding(.top, 12)
            } else {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .wraps()
                    .padding(.top, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private var title: String {
        switch state {
        case .idle: return "Не подключено"
        case .connecting: return "Подключение…"
        case .connected: return "Подключено"
        case .stopping: return "Отключение…"
        }
    }

    private var hint: String {
        switch state {
        case .idle: return "Нажмите на кнопку, чтобы включить VPN"
        case .connecting: return "Соединяемся с сервером"
        case .stopping: return "Выключаем VPN"
        case .connected: return ""
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: return .good
        case .connecting, .stopping: return .orange
        case .idle: return .secondary
        }
    }
}

private struct TVConnectButton: View {
    var state: VPNController.State
    var action: () -> Void
    @State private var pulse = false
    @State private var spin = false

    private var connected: Bool {
        if case .connected = state { return true }
        return false
    }

    private var busy: Bool { state == .connecting || state == .stopping }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.accentColor.opacity(connected ? 0.34 : 0.0), .clear],
                    center: .center,
                    startRadius: 100,
                    endRadius: 140
                ))
                .frame(width: 280, height: 280)
                .animation(.easeInOut(duration: 0.4), value: connected)
            if connected {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 2)
                    .frame(width: 248, height: 248)
                    .scaleEffect(pulse ? 1.1 : 0.96)
                    .opacity(pulse ? 0.1 : 0.9)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
            if busy {
                Circle()
                    .trim(from: 0, to: 0.26)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 248, height: 248)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            }
            Button(action: action) {
                VStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 56, weight: .semibold))
                        .opacity(busy ? 0.45 : 1)
                    Text(state == .idle ? "Подключиться" : "Отключиться")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 20)
                }
                .foregroundStyle(connected ? Color.onAccent : Color.primary)
                .frame(width: 222, height: 222)
            }
            .buttonStyle(TVConnectButtonStyle(connected: connected))
            .disabled(state == .stopping)
        }
        .frame(width: 280, height: 280)
    }
}

private struct TVConnectButtonStyle: ButtonStyle {
    var connected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tvGlassSurface(
                Circle(),
                tint: connected ? .accentColor : (isFocused ? .tvFocusFill : nil),
                fallback: connected ? .accentColor : (isFocused ? .tvFocusFill : .cardHigh)
            )
            .overlay(
                Circle().strokeBorder(
                    Color.primary.opacity(isFocused ? (connected ? 0.8 : 0.5) : 0),
                    lineWidth: 3
                )
            )
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.08 : 1.0))
            .shadow(
                color: (connected ? Color.accentColor : Color.black).opacity(isFocused ? 0.45 : 0.22),
                radius: isFocused ? 34 : 14,
                y: isFocused ? 14 : 6
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.28), value: connected)
    }
}

/** Live download/upload speed and session bytes, polled from the tunnel extension every second while connected. */
private struct TVTrafficRow: View {
    @EnvironmentObject private var vpn: VPNController
    @State private var stats: TunnelStats?
    @State private var speed = (up: Int64(0), down: Int64(0))

    var body: some View {
        Group {
            if vpn.isConnected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 32) {
                        rate(Format.speed(speed.down), icon: "arrow.down")
                        rate(Format.speed(speed.up), icon: "arrow.up")
                    }
                    if let stats {
                        Text("За сессию: ↓ \(Format.bytes(stats.down)) · ↑ \(Format.bytes(stats.up))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .task(id: vpn.isConnected) {
            stats = nil
            speed = (0, 0)
            var last: (TunnelStats, Date)?
            while vpn.isConnected, !Task.isCancelled {
                if let now = await vpn.stats() {
                    if let previousSample = last {
                        let (previous, at) = previousSample
                        let seconds = max(Date().timeIntervalSince(at), 0.001)
                        speed = (
                            max(Int64(Double(now.up - previous.up) / seconds), 0),
                            max(Int64(Double(now.down - previous.down) / seconds), 0)
                        )
                    }
                    last = (now, Date())
                    stats = now
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func rate(_ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct TVSelectedServerCard: View {
    var server: ServerEntry?
    var ping: Ping?

    var body: some View {
        HStack(spacing: 20) {
            Text(server?.flag ?? "🌐")
                .font(.system(size: 46))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("Сервер")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(server?.title ?? "—")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let summary = server?.summary {
                    Text(summary)
                        .font(.caption)
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            TVPingLabel(ping: ping, kind: server?.kind)
        }
        .padding(.vertical, -2)
        .tvCard()
    }
}

/** Plan, expiry and traffic status (same logic as iOS AccountCard, without external buy/renew buttons). */
private struct TVAccountCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let account = model.account
        let subscription = model.subscription
        let found = account?.found == true
        let expiresAt = found ? account?.expiresAt : subscription?.expire
        let isFree = found && account?.isFree == true
        let now = Int64(Date().timeIntervalSince1970)
        let expired = expiresAt.map { $0 <= now } ?? false
        let limit = (found ? account?.trafficLimit : subscription?.total).flatMap { $0 > 0 ? $0 : nil }
        let used = found ? account?.trafficUsed : subscription.map { ($0.upload ?? 0) + ($0.download ?? 0) }
        let secondary: Color = expired ? .onErrorCard : .secondary

        if found || expiresAt != nil {
            HStack(alignment: .top, spacing: 20) {
                TVIconBadge(
                    systemImage: expired ? "exclamationmark.triangle.fill" : (isFree ? "gift.fill" : "calendar"),
                    tint: expired ? .onErrorCard : .accentColor
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(planTitle(account, expired: expired, isFree: isFree))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(expired ? Color.onErrorCard : Color.primary)
                    if let details = details(expiresAt: expiresAt, expired: expired, isFree: isFree, now: now) {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(secondary)
                            .wraps()
                    }
                    if let limit, let used {
                        ProgressView(value: min(max(Double(used) / Double(limit), 0), 1))
                            .tint(expired ? .onErrorCard : .accentColor)
                            .padding(.vertical, 6)
                        Text("Использовано \(Format.bytes(used)) из \(Format.bytes(limit)) · осталось \(Format.bytes(max(limit - used, 0)))")
                            .font(.caption)
                            .foregroundStyle(secondary)
                            .wraps()
                    } else if let used, used > 0 {
                        Text("Использовано \(Format.bytes(used))")
                            .font(.caption)
                            .foregroundStyle(secondary)
                    }
                }
                .padding(.top, 2)
            }
            .tvCard(expired ? .errorCard : .card)
        }
    }

    private func planTitle(_ account: AccountStatus?, expired: Bool, isFree: Bool) -> String {
        if expired { return "Ваша подписка" }
        if isFree { return "Бесплатный тариф" }
        if account?.found == true, let name = account?.planName { return "Тариф «\(name)»" }
        return "Ваша подписка"
    }

    private func details(expiresAt: Int64?, expired: Bool, isFree: Bool, now: Int64) -> String? {
        if expired { return "Подписка закончилась" }
        if let expiresAt {
            let days = max(Int((expiresAt - now) / 86_400), 0)
            return "Действует до \(Format.date(expiresAt)) · Осталось \(Format.days(days))"
        }
        return isFree ? nil : "Без срока окончания"
    }
}

/**
 * Live server list pane on Apple TV: mirrors iPad/Mac ServersPane with emoji filter chips, subscription
 * separator sections, color-coded ping latency, and single-server ping via hold or Play/Pause.
 */
struct TVServersPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: String?

    private struct ServerSection: Identifiable {
        var id: String
        var title: String?
        var servers: [ServerEntry]
    }

    private var filters: [ServerFilter] {
        let servers = model.subscription?.selectable ?? []
        return model.config.serverFilters.filter { f in
            let plain = f.emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
            return servers.contains { $0.remarks.contains(f.emoji) || $0.remarks.contains(plain) }
        }
    }

    private var activeFilter: String? {
        guard let filter, filters.contains(where: { $0.emoji == filter }) else { return nil }
        return filter
    }

    private var sections: [ServerSection] {
        var result: [ServerSection] = []
        var current = ServerSection(id: "top", title: nil, servers: [])
        let currentFilter = activeFilter
        for entry in model.subscription?.servers ?? [] {
            if entry.kind == .separator {
                if !current.servers.isEmpty { result.append(current) }
                current = ServerSection(id: entry.key, title: entry.title, servers: [])
            } else if currentFilter.map({ entry.remarks.contains($0) || entry.remarks.contains($0.replacingOccurrences(of: "\u{FE0F}", with: "")) }) ?? true {
                current.servers.append(entry)
            }
        }
        if !current.servers.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        let sections = sections
        let total = sections.reduce(0) { $0 + $1.servers.count }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Серверы")
                    .font(.title3.weight(.bold))
                Text("\(total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                if model.pingWhitelistOnly {
                    Label("Только серверы обхода", systemImage: "shield.lefthalf.filled")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, filters.isEmpty ? 6 : 2)

            if !filters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    TVGlassGroup(spacing: 8) {
                        HStack(spacing: 14) {
                            Button("Все") { filter = nil }
                                .buttonStyle(TVPillButtonStyle(selected: activeFilter == nil))
                            ForEach(filters, id: \.self) { f in
                                Button("\(f.emoji) \(f.title)") { filter = f.emoji }
                                    .buttonStyle(TVPillButtonStyle(selected: activeFilter == f.emoji))
                            }
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 72)
                    .padding(.vertical, 18)
                }
                .tvFadeEdges(.horizontal, leading: 28, trailing: 64)
                .focusSection()
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        if let title = section.title, !title.isEmpty {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, section.id == sections.first?.id ? 2 : 22)
                                .padding(.bottom, 2)
                                .padding(.horizontal, 8)
                        }
                        ForEach(section.servers) { server in
                            serverRow(server)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if model.pingWhitelistOnly {
                            Text("Включены белые списки — пинг проверяет только серверы для обхода.")
                        }
                        Text("Удерживайте кнопку выбора или нажмите Play/Pause на сервере, чтобы проверить только его.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .padding(.bottom, 48)
            }
            .tvFadeEdges(.vertical, leading: 12, trailing: 44)
            .focusSection()
        }
        .tvCardSurface(RoundedRectangle(cornerRadius: 40, style: .continuous), color: .card)
        .task(id: model.subscription?.url) {
            if model.pingOnOpen, model.pings.isEmpty {
                model.testPings()
            }
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        let isSelected = server.key == model.selectedServer?.key
        return Button {
            model.select(server.key)
        } label: {
            HStack(spacing: 18) {
                TVServerTitle(server: server)
                Spacer(minLength: 12)
                TVPingLabel(ping: model.pings[server.key], kind: server.kind)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        }
        .buttonStyle(TVCardButtonStyle(
            cornerRadius: 24,
            fill: isSelected ? Color.accentColor.opacity(0.18) : .tvPaneRow,
            highlighted: isSelected,
            glass: false,
            focusScale: 1.025
        ))
        .contextMenu {
            Button {
                model.pingServer(server)
            } label: {
                Label("Проверить пинг", systemImage: "bolt.horizontal")
            }
        }
        .onPlayPauseCommand {
            model.pingServer(server)
        }
    }
}
