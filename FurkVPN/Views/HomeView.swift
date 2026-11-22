import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var showServers = false
    #if !os(tvOS)
    @State private var showSupport = false
    @State private var showProxies = false
    #else
    @FocusState private var connectFocused: Bool
    @State private var showAnnouncement = false
    #endif
    /** The list stands next to the main screen: no sheet for it, and Settings can move it to the other side. */
    @State private var wide = false

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            ZStack {
                BrandBackdrop()
                VStack(spacing: 12) {
                    tvTopBar
                    tvWideLayout
                }
                .padding(.horizontal, 80)
                .padding(.top, 24)
                .padding(.bottom, 30)
                .ignoresSafeArea()
            }
            .onAppear {
                wide = true
                connectFocused = true
            }
            #if DEMO
            .task {
                if Demo.settings { model.settingsOpen = true }
            }
            #endif
            .navigationDestination(isPresented: $model.settingsOpen) {
                SettingsView(wide: true)
            }
        }
        .fullScreenCover(isPresented: $showAnnouncement) {
            if let announce = model.subscription?.announce {
                TVAnnouncementSheet(text: announce)
            }
        }
        #else
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
        #endif
    }

    #if os(tvOS)
    /** Centered brand mark and trailing glass gear button, matching the wide iPhone Duo / iPad / Mac header. */
    private var tvTopBar: some View {
        ZStack {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 46)
                .foregroundColor(.primary)
            HStack {
                Spacer()
                Button { model.settingsOpen = true } label: {
                    Image(systemName: "gearshape")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.primary)
                        .frame(width: 60, height: 60)
                        .glassSurface(Circle(), fallback: .cardHigh)
                }
                .glassInteractiveButton(Circle(), scale: 1.08)
                .accessibilityLabel("Настройки")
            }
        }
        .frame(height: 64)
        .focusSection()
    }

    /** Equal two-half layout (same 50/50 split as the unfolded iPhone Duo, iPad and Mac). */
    private var tvWideLayout: some View {
        HStack(spacing: WideLayout.gap) {
            if model.serversOnLeft {
                ServersPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
            }
            ScrollView(.vertical, showsIndicators: false) {
                homeColumn
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            .padding(.horizontal, -18)
            .padding(.vertical, -14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
            if !model.serversOnLeft {
                ServersPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
            }
        }
        .frame(maxWidth: WideLayout.maxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
    #else
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
    #endif

    /** The main screen itself: state, the connect button and the speed, then the cards under them. */
    private var homeColumn: some View {
        VStack(spacing: 0) {
            StatusHeader(state: vpn.state).padding(.top, homeTopPadding)
            Spacer().frame(height: connectTopGap)
            let connect = ConnectButton(state: vpn.state) {
                toggleVPN()
            }
            #if os(tvOS)
            connect.focused($connectFocused)
            #else
            connect
            #endif
            TrafficRow()
            Spacer().frame(height: cardsTopGap)
            cards
        }
        .padding(.bottom, 16)
        // On big tablets and Apple TV the cards stay within a comfortable column width.
        .frame(maxWidth: WideLayout.homeColumnMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func toggleVPN() {
        if vpn.state == .idle {
            Task {
                #if os(tvOS)
                await vpn.loaded()
                if vpn.state == .idle {
                    await vpn.connect()
                } else if vpn.state != .stopping {
                    vpn.disconnect()
                }
                #else
                await vpn.connect()
                #endif
            }
        } else if vpn.state != .stopping {
            vpn.disconnect()
        }
    }

    /** The server card opens the list only where it isn't on screen already. */
    private var openServers: (() -> Void)? {
        wide ? nil : { showServers = true }
    }

    /** Server, white lists, plan, announcement (and on iOS/Mac: quick links and Telegram proxies). */
    private var cards: some View {
        VStack(spacing: 0) {
            ServerCard(server: model.selectedServer, ping: model.selectedServer.flatMap { model.pings[$0.key] }, onTap: openServers)
            WhitelistCard()
                .padding(.top, cardGap)
            AccountCard()
                .padding(.top, cardGap)
            if let announce = model.subscription?.announce,
               !announce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #if os(tvOS)
                Button { showAnnouncement = true } label: {
                    Text(announce)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .card()
                }
                .glassInteractiveButton(RoundedRectangle(cornerRadius: 26, style: .continuous), scale: 1.03, ringColor: .accentColor, ringOpacity: 0.9)
                .padding(.top, cardGap)
                #else
                Text(Linkify.text(announce))
                    .font(.subheadline)
                    .wraps()
                    .card()
                    .padding(.top, cardGap)
                #endif
            }
            #if !os(tvOS)
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
                    .pointerHoverShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
                }
                .glassInteractiveButton(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.top, 8)
            }
            #endif
        }
    }

    #if os(tvOS)
    private var homeTopPadding: CGFloat { 0 }
    private var connectTopGap: CGFloat { 8 }
    private var cardsTopGap: CGFloat { 12 }
    private var cardGap: CGFloat { 12 }
    #else
    private var homeTopPadding: CGFloat { 12 }
    private var connectTopGap: CGFloat { 20 }
    private var cardsTopGap: CGFloat { 20 }
    private var cardGap: CGFloat { 12 }
    #endif
}

#if os(tvOS)
private struct TVAnnouncementSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BrandBackdrop()
                List {
                    Section {
                        Button {} label: {
                            Text(text)
                                .font(.callout)
                                .foregroundColor(.primary)
                                .wraps()
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Section {
                        Button("Закрыть") { dismiss() }
                    }
                }
                .tint(.primary)
                .frame(maxWidth: 1040)
                .padding(.vertical, 32)
            }
            .navigationTitle("Объявление")
        }
    }
}
#endif

private struct StatusHeader: View {
    var state: VPNController.State

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                #if os(tvOS)
                .font(.title3.weight(.semibold))
                #else
                .font(.title2.weight(.semibold))
                #endif
            if case let .connected(since) = state {
                Text(since, style: .timer)
                    #if os(tvOS)
                    .font(.caption.monospacedDigit())
                    #else
                    .font(.subheadline.monospacedDigit())
                    #endif
                    .foregroundColor(.secondary)
            } else {
                Text(" ")
                    #if os(tvOS)
                    .font(.caption)
                    #else
                    .font(.subheadline)
                    #endif
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
                    .frame(width: pulseSize, height: pulseSize)
                    .scaleEffect(pulse ? 1.06 : 0.92)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(busyScale)
                    .offset(y: busyOffset)
            }
            Button(action: action) {
                VStack(spacing: labelSpacing) {
                    Image(systemName: "power").font(.system(size: iconSize, weight: .medium))
                    Text(state == .idle ? "Подключиться" : "Отключиться")
                        .font(labelFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        #if os(tvOS)
                        .padding(.horizontal, 18)
                        #endif
                }
                .foregroundColor(connected ? .onAccent : .primary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
                .pointerHoverShape(Circle())
                .glassSurface(Circle(), tint: connected ? .accentColor : nil, interactive: true, fallback: .cardHigh)
                .shadow(color: .black.opacity(connected ? 0.25 : 0), radius: 8, y: 4)
            }
            .glassInteractiveButton(Circle(), scale: 1.07, ringOpacity: connected ? 0.8 : 0.55, liftHover: true)
            .disabled(state == .stopping)
            .animation(.easeInOut(duration: 0.3), value: connected)
        }
        .frame(width: containerSize, height: containerSize)
        .padding(.bottom, busy ? 16 : 0)
    }

    #if os(tvOS)
    private var buttonSize: CGFloat { 202 }
    private var pulseSize: CGFloat { 238 }
    private var containerSize: CGFloat { 244 }
    private var iconSize: CGFloat { 52 }
    private var labelSpacing: CGFloat { 6 }
    private var labelFont: Font { .caption.weight(.semibold) }
    private var busyScale: CGFloat { 1.4 }
    private var busyOffset: CGFloat { 130 }
    #else
    private var buttonSize: CGFloat { 176 }
    private var pulseSize: CGFloat { 220 }
    private var containerSize: CGFloat { 232 }
    private var iconSize: CGFloat { 54 }
    private var labelSpacing: CGFloat { 6 }
    private var labelFont: Font { .callout.weight(.medium) }
    private var busyScale: CGFloat { 2.2 }
    private var busyOffset: CGFloat { 120 }
    #endif
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
                    #if os(tvOS)
                    .font(.caption.monospacedDigit())
                    #else
                    .font(.subheadline.monospacedDigit())
                    #endif
                    if let stats {
                        Text("За сессию: ↓ \(Format.bytes(stats.down)) · ↑ \(Format.bytes(stats.up))")
                            #if os(tvOS)
                            .font(.caption2.monospacedDigit())
                            #else
                            .font(.caption)
                            #endif
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
                    .pointerHoverShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            }
            .glassInteractiveButton(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content(chevron: false).card()
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Сервер")
                    #if os(tvOS)
                    .font(.caption2)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundColor(.secondary)
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
 * Russia (PurchaseRegion): elsewhere the App Store doesn't allow links to pay outside it. Never shown on tvOS.
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
        #if !os(tvOS)
        let endsSoon = expiresAt.map { $0 - now < 2 * 24 * 3600 } ?? false
        #endif
        let limit = (found ? account?.trafficLimit : subscription?.total).flatMap { $0 > 0 ? $0 : nil }
        let used = found ? account?.trafficUsed : subscription.map { ($0.upload ?? 0) + ($0.download ?? 0) }

        if found || expiresAt != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(planTitle(account, expired: expired, isFree: isFree))
                    .font(titleFont)
                    .foregroundColor(expired ? .onErrorCard : .primary)
                if let details = details(expiresAt: expiresAt, expired: expired, isFree: isFree, now: now) {
                    Text(details)
                        .font(detailFont)
                        .foregroundColor(expired ? .onErrorCard : .secondary)
                        .wraps()
                }
                if let limit, let used {
                    ProgressView(value: min(max(Double(used) / Double(limit), 0), 1))
                        .padding(.top, 8)
                    Text("Использовано \(Format.bytes(used)) из \(Format.bytes(limit)) · осталось \(Format.bytes(max(limit - used, 0)))")
                        .font(captionFont)
                        .foregroundColor(expired ? .onErrorCard : .secondary)
                        .wraps()
                } else if let used, used > 0 {
                    Text("Использовано \(Format.bytes(used))")
                        .font(captionFont)
                        .foregroundColor(expired ? .onErrorCard : .secondary)
                        .padding(.top, 2)
                }
                #if !os(tvOS)
                if (isFree || endsSoon) && model.showBuy {
                    Button(isFree ? "Купить тариф" : "Продлить") { openLink(model.renewUrl?.absoluteString) }
                        .glassButtonStyle(prominent: true)
                        .padding(.top, 8)
                }
                #endif
            }
            .card(expired ? .errorCard : .card)
        }
    }

    #if os(tvOS)
    private var titleFont: Font { .callout.weight(.semibold) }
    private var detailFont: Font { .caption }
    private var captionFont: Font { .caption2 }
    #else
    private var titleFont: Font { .headline }
    private var detailFont: Font { .subheadline }
    private var captionFont: Font { .caption }
    #endif

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

#if !os(tvOS)
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
            .pointerHoverShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        }
        .glassInteractiveButton(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif
