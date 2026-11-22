import SwiftUI

/** Overscan-safe 10-foot margins shared by every Apple TV tab. */
enum TVLayout {
    static let horizontalMargin: CGFloat = 90
    static let verticalMargin: CGFloat = 60
}

enum TVTab: Hashable {
    case home, servers, settings
}

/**
 * Apple TV's main screen, tvOS HIG first: the system's top tab bar (floating Liquid Glass on tvOS 26) with
 * Главная, Серверы and Настройки, each a full-canvas page built from the shared FurkVPN/Views components.
 */
struct TVMainTabs: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: TVTab = Self.initialTab

    private static var initialTab: TVTab {
        #if DEMO
        if Demo.settings { return .settings }
        if Demo.servers { return .servers }
        #endif
        return .home
    }

    var body: some View {
        TabView(selection: $tab) {
            TVHomeTab(tab: $tab)
                .tabItem { Label("Главная", systemImage: "power.circle") }
                .tag(TVTab.home)
            TVServersTab()
                .tabItem { Label("Серверы", systemImage: "globe") }
                .tag(TVTab.servers)
            TVSettingsTab()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(TVTab.settings)
        }
        // Anything that asks for Settings (as the gear did on iOS) selects its tab instead.
        .onChange(of: model.settingsOpen) { _, open in
            guard open else { return }
            tab = .settings
            model.settingsOpen = false
        }
    }
}

// MARK: - Главная

private struct TVHomeTab: View {
    @Binding var tab: TVTab
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: VPNController
    @State private var showAnnouncement = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case connect }

    var body: some View {
        ZStack {
            BrandBackdrop()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 60) {
                    hero
                    cardsRow
                }
                .padding(.horizontal, TVLayout.horizontalMargin)
                .padding(.top, 56)
                .padding(.bottom, TVLayout.verticalMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
        .defaultFocus($focus, .connect)
        .onAppear {
            if focus == nil { focus = .connect }
        }
        .fullScreenCover(isPresented: $showAnnouncement) {
            if let announcement {
                TVAnnouncementSheet(text: announcement)
            }
        }
    }

    /** The connect button as the page's hero, with the state, timer and speed beside it, then the server. */
    private var hero: some View {
        HStack(alignment: .center, spacing: 72) {
            ConnectButton(state: vpn.state) { toggleVPN() }
                .focused($focus, equals: .connect)
            VStack(alignment: .leading, spacing: 20) {
                StatusHeader(state: vpn.state, alignment: .leading)
                TrafficRow(rowAlignment: .leading)
                ServerCard(
                    server: model.selectedServer,
                    ping: model.selectedServer.flatMap { model.pings[$0.key] },
                    onTap: { tab = .servers }
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    /** White lists, plan and announcement side by side, equal in height: one glance from the couch. */
    private var cardsRow: some View {
        HStack(alignment: .top, spacing: 40) {
            if model.whitelistDetect {
                WhitelistCard().frame(maxWidth: .infinity)
            }
            AccountCard().frame(maxWidth: .infinity)
            if let announcement {
                Button { showAnnouncement = true } label: {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Объявление", systemImage: "megaphone.fill")
                                .font(.callout.weight(.semibold))
                            Text(announcement)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        TVCardChevron()
                            .padding(.top, 6)
                    }
                    .foregroundColor(.primary)
                    .card()
                }
                .glassInteractiveButton(RoundedRectangle(cornerRadius: 26, style: .continuous), scale: 1.03, ringColor: .accentColor, ringOpacity: 0.9)
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.tvCardFillsHeight, true)
        .focusSection()
    }

    private var announcement: String? {
        guard let text = model.subscription?.announce,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
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

private struct TVAnnouncementSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TVDetailLayout(icon: "megaphone.fill", caption: "Объявление подписки FurkVPN") {
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
            }
            .navigationTitle("Объявление")
        }
    }
}

// MARK: - Серверы

private struct TVServersTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.horizontal, TVLayout.horizontalMargin)
                    .padding(.top, 20)
                ServerList(columns: 3) { model.select($0.key) }
            }
            .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
    }

    /** What the list is and its two actions as labeled pills (no cryptic icon-only circles). */
    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.subscription?.title ?? "Серверы")
                    .font(.headline)
                    .lineLimit(1)
                Text(countText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 24)
            GlassGroup(spacing: 12) {
                HStack(spacing: 24) {
                    // Stays enabled while pinging: pressing it again starts over.
                    Button { model.testPings() } label: {
                        pill("Пинг", icon: "bolt.horizontal.fill", busy: model.pinging)
                    }
                    .glassButtonStyle()
                    Button { model.refreshSubscription(showMessage: true) } label: {
                        pill("Обновить", icon: "arrow.clockwise", busy: model.refreshing)
                    }
                    .glassButtonStyle()
                    .disabled(model.refreshing)
                }
            }
        }
        .focusSection()
    }

    private func pill(_ title: String, icon: String, busy: Bool) -> some View {
        HStack(spacing: 12) {
            if busy {
                ProgressView().scaleEffect(0.6).frame(width: 32, height: 32)
            } else {
                Image(systemName: icon).frame(width: 32, height: 32)
            }
            Text(title)
        }
    }

    private var countText: String {
        let count = model.subscription?.selectable.count ?? 0
        let mod10 = count % 10, mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "сервер"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "сервера"
        } else {
            word = "серверов"
        }
        return "\(count) \(word) · выбранный отмечен галочкой"
    }
}

// MARK: - Настройки

/** Apple TV Settings layout: the app's emblem and details on the left, the shared settings form on the right. */
private struct TVSettingsTab: View {
    var body: some View {
        NavigationStack {
            ZStack {
                BrandBackdrop()
                HStack(alignment: .top, spacing: 80) {
                    TVSettingsSidebar()
                        .frame(width: 560)
                        .frame(maxHeight: .infinity)
                    SettingsView(embedded: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, TVLayout.horizontalMargin)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
    }
}

private struct TVSettingsSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            // App-icon proportions (5:3), the brand mark on the card color, like the system's Settings.
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 132)
                .foregroundColor(.primary)
                .frame(width: 480, height: 288)
                .cardSurface(RoundedRectangle(cornerRadius: 36, style: .continuous), color: .card)
                .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
                .accessibilityLabel("FurkVPN")
            VStack(spacing: 8) {
                Text(model.subscription?.title ?? "FurkVPN")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let plan {
                    Text(plan)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Text("Версия \(Http.appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, TVLayout.verticalMargin)
    }

    private var plan: String? {
        guard let account = model.account, account.found else { return nil }
        if account.isFree { return "Бесплатный тариф" }
        return account.planName.map { "Тариф «\($0)»" }
    }
}
