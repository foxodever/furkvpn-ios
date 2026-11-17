import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var showServers = false
    @State private var showSupport = false
    @State private var showProxies = false
    /** The list stands next to the main screen: no sheet for it, and Settings can move it to the other side. */
    @State private var wide = false

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                Group {
                    if WideLayout.fits(geo.size) {
                        wideLayout(geo)
                    } else {
                        ScrollView {
                            homeColumn.padding(.horizontal, 20)
                        }
                        .refreshable { await model.refreshSubscriptionNow(showMessage: true) }
                    }
                }
                .onAppear {
                    wide = WideLayout.fits(geo.size)
                    #if DEMO
                    showServers = Demo.servers && !wide
                    model.settingsOpen = Demo.settings
                    #endif
                }
                .onChange(of: geo.size) { wide = WideLayout.fits($0) }
            }
            .background(BrandBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("Logo").resizable().scaledToFit().frame(height: 26).foregroundColor(.primary)
                }
            }
            .barItem(.navigationBarTrailing) {
                // Title and icon: on the iPhone Duo the bar may stand vertically at the side.
                Button { model.settingsOpen = true } label: { Label("Настройки", systemImage: "gearshape") }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showServers) {
            ServersView().environmentObject(model).environmentObject(vpn).resizableSheet()
        }
        .sheet(isPresented: $model.settingsOpen) {
            SettingsView(wide: wide).environmentObject(model).environmentObject(vpn)
        }
        .sheet(isPresented: $showSupport) {
            SupportSheet(contacts: model.config.support, subscriptionSupport: model.subscription?.supportUrl, links: model.config.links)
        }
        .sheet(isPresented: $showProxies) {
            TelegramProxiesSheet(proxies: model.config.telegramProxies)
        }
    }

    /**
     * Unfolded iPhone Duo, iPad, Mac: the main screen on one half, the server list on the other, the gap
     * between them in the middle, where the Duo folds. The list is on the right unless moved to the left.
     */
    private func wideLayout(_ geo: GeometryProxy) -> some View {
        HStack(spacing: WideLayout.gap) {
            if model.serversOnLeft { ServersPane().frame(maxWidth: .infinity) }
            ScrollView {
                homeColumn
            }
            .refreshable { await model.refreshSubscriptionNow(showMessage: true) }
            .frame(maxWidth: .infinity)
            if !model.serversOnLeft { ServersPane().frame(maxWidth: .infinity) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: WideLayout.maxWidth)
        .padding(WideLayout.centering(geo))
        .frame(maxWidth: .infinity)
    }

    /** The main screen itself: state, the connect button and the speed, then the cards under them. */
    private var homeColumn: some View {
        VStack(spacing: 0) {
            StatusHeader(state: vpn.state).padding(.top, 12)
            Spacer().frame(height: 20)
            ConnectButton(state: vpn.state) {
                if vpn.state == .idle {
                    Task { await vpn.connect() }
                } else {
                    vpn.disconnect()
                }
            }
            TrafficRow()
            Spacer().frame(height: 20)
            cards
        }
        .padding(.bottom, 16)
        // On big tablets the cards would get too wide.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    /** The server card opens the list only where it isn't on screen already. */
    private var openServers: (() -> Void)? {
        wide ? nil : { showServers = true }
    }

    /** Server, plan, announcement, links and the Telegram proxies. */
    private var cards: some View {
        VStack(spacing: 0) {
            ServerCard(server: model.selectedServer, ping: model.selectedServer.flatMap { model.pings[$0.key] }, onTap: openServers)
            WhitelistCard()
                .padding(.top, 12)
            AccountCard()
                .padding(.top, 12)
            if let announce = model.subscription?.announce {
                Text(Linkify.text(announce))
                    .font(.subheadline)
                    .wraps()
                    .card()
                    .padding(.top, 12)
            }
            QuickActions(onSupport: { showSupport = true })
                .padding(.top, 20)
            if !model.config.telegramProxies.isEmpty {
                Button { showProxies = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Прокси для Telegram").font(.subheadline.weight(.semibold))
                            Text("Telegram без VPN").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                    .foregroundColor(.primary)
                    .padding(16)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .padding(.top, 8)
            }
        }
    }
}

private struct StatusHeader: View {
    var state: VPNController.State

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            if case let .connected(since) = state {
                Text(since, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text(" ").font(.subheadline)
            }
        }
    }

    private var title: String {
        switch state {
        case .idle: return "Не подключено"
        case .connecting: return "Подключение…"
        case .connected: return "Подключено"
        case .stopping: return "Отключение…"
        }
    }
}

private struct ConnectButton: View {
    var state: VPNController.State
    var action: () -> Void
    @State private var pulse = false

    private var connected: Bool {
        if case .connected = state { return true }
        return false
    }

    private var busy: Bool { state == .connecting || state == .stopping }

    var body: some View {
        ZStack {
            if connected {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 220, height: 220)
                    .scaleEffect(pulse ? 1.06 : 0.92)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(2.2)
                    .offset(y: 120)
            }
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 54, weight: .medium))
                    Text(state == .idle ? "Подключиться" : "Отключиться").font(.callout.weight(.medium))
                }
                .foregroundColor(connected ? .onAccent : .primary)
                .frame(width: 176, height: 176)
                .contentShape(Circle())
                .contentShape(.hoverEffect, Circle())
                .glassSurface(Circle(), tint: connected ? .accentColor : nil, interactive: true, fallback: .cardHigh)
                .shadow(color: .black.opacity(connected ? 0.25 : 0), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .animation(.easeInOut(duration: 0.3), value: connected)
        }
        .frame(width: 232, height: 232)
        .padding(.bottom, busy ? 16 : 0)
    }
}

/** Speed and the traffic of this connection, read from the tunnel once a second while visible. */
private struct TrafficRow: View {
    @EnvironmentObject private var vpn: VPNController
    @State private var stats: TunnelStats?
    @State private var speed = (up: Int64(0), down: Int64(0))

    var body: some View {
        Group {
            if vpn.isConnected {
                VStack(spacing: 4) {
                    HStack(spacing: 20) {
                        Label(Format.speed(speed.down), systemImage: "arrow.down")
                        Label(Format.speed(speed.up), systemImage: "arrow.up")
                    }
                    .font(.subheadline.monospacedDigit())
                    if let stats {
                        Text("За сессию: ↓ \(Format.bytes(stats.down)) · ↑ \(Format.bytes(stats.up))")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
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
                        speed = (Int64(Double(now.up - previous.up) / seconds), Int64(Double(now.down - previous.down) / seconds))
                    }
                    last = (now, Date())
                    stats = now
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct ServerCard: View {
    var server: ServerEntry?
    var ping: Ping?
    /** Opens the list; nil when the list is on screen anyway (wide windows): then it is just a card. */
    var onTap: (() -> Void)?

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                content(chevron: true)
                    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            content(chevron: false).card()
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Сервер").font(.caption).foregroundColor(.secondary)
                if let server {
                    ServerTitle(server: server)
                } else {
                    Text("—")
                }
            }
            Spacer()
            PingLabel(ping: ping, kind: server?.kind)
            if chevron { Image(systemName: "chevron.right").foregroundColor(.secondary) }
        }
        .padding(chevron ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/**
 * Plan, expiry and traffic; "Продлить" two days before the end, "Купить тариф" on the free plan — both only in
 * Russia (PurchaseRegion): elsewhere the App Store doesn't allow links to pay outside it.
 */
private struct AccountCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let account = model.account
        let subscription = model.subscription
        let found = account?.found == true
        // Fall back to the expiry date from the subscription headers when the API is unreachable.
        let expiresAt = found ? account?.expiresAt : subscription?.expire
        let isFree = found && account?.isFree == true
        let now = Int64(Date().timeIntervalSince1970)
        let expired = expiresAt.map { $0 <= now } ?? false
        let endsSoon = expiresAt.map { $0 - now < 2 * 24 * 3600 } ?? false
        let limit = (found ? account?.trafficLimit : subscription?.total).flatMap { $0 > 0 ? $0 : nil }
        let used = found ? account?.trafficUsed : subscription.map { ($0.upload ?? 0) + ($0.download ?? 0) }

        if found || expiresAt != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(planTitle(account, expired: expired, isFree: isFree)).font(.headline)
                if let details = details(expiresAt: expiresAt, expired: expired, isFree: isFree, now: now) {
                    Text(details)
                        .font(.subheadline)
                        .foregroundColor(expired ? .onErrorCard : .secondary)
                        .wraps()
                }
                if let limit, let used {
                    ProgressView(value: min(max(Double(used) / Double(limit), 0), 1))
                        .padding(.top, 8)
                    Text("Использовано \(Format.bytes(used)) из \(Format.bytes(limit)) · осталось \(Format.bytes(max(limit - used, 0)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .wraps()
                } else if let used, used > 0 {
                    Text("Использовано \(Format.bytes(used))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                if (isFree || endsSoon) && model.showBuy {
                    Button(isFree ? "Купить тариф" : "Продлить") { openLink(model.renewUrl?.absoluteString) }
                        .glassButtonStyle(prominent: true)
                        .padding(.top, 8)
                }
            }
            .card(expired ? .errorCard : .card)
        }
    }

    // An active plan is shown by name; "Ваша подписка" only when there is none.
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

/** "Наш сайт", "Наш бот" (links from the API) and "Поддержка". */
private struct QuickActions: View {
    @EnvironmentObject private var model: AppModel
    var onSupport: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(model.config.links, id: \.self) { link in
                    action(title(link), icon: link.type == "bot" ? "paperplane.fill" : "globe") { openLink(link.url) }
                }
                action("Поддержка", icon: "questionmark.bubble.fill", onSupport)
            }
        }
    }

    private func title(_ link: AppLink) -> String {
        if let title = link.title, !title.isEmpty { return title }
        switch link.type {
        case "website": return "Наш сайт"
        case "bot": return "Наш бот"
        default: return link.url
        }
    }

    private func action(_ label: String, icon: String, _ onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption.weight(.medium)).multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}
