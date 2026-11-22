import SwiftUI
import UIKit

#if !os(tvOS)
/** The server list as a sheet: narrow windows open it from the server card. */
struct ServersView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ServerList { server in
                model.select(server.key)
                dismiss()
            }
            .navigationTitle("Серверы")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Закрыть") { dismiss() } }
            .barGroup(.primaryAction) {
                if model.pinging { ProgressView() }
                // Stays enabled while pinging: pressing it again starts over.
                Button { model.testPings() } label: { Label("Проверить пинг", systemImage: "bolt.horizontal.circle") }
            }
        }
        .navigationViewStyle(.stack)
        .sheetGlass()
    }
}
#endif

/**
 * The server list next to the main screen on wide windows (iPad, Mac, the unfolded iPhone Duo, Apple TV),
 * like the Android app. It stands on the right; the swap button or Settings → Интерфейс moves it to the left.
 */
struct ServersPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: headerSpacing) {
                Text("Серверы").font(.title3.weight(.semibold))
                Spacer()
                headerActions
            }
            .padding(.leading, headerLeading)
            .padding(.trailing, headerTrailing)
            .padding(.top, headerTop)
            .padding(.bottom, headerBottom)
            #if os(tvOS)
            .focusSection()
            #endif
            ServerList(inPane: true) { model.select($0.key) }
        }
        #if os(tvOS)
        .cardSurface(RoundedRectangle(cornerRadius: paneRadius, style: .continuous), color: .card)
        .clipShape(RoundedRectangle(cornerRadius: paneRadius, style: .continuous))
        #else
        .background(Color.card, in: RoundedRectangle(cornerRadius: paneRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: paneRadius, style: .continuous))
        #endif
    }

    @ViewBuilder
    private var headerActions: some View {
        let buttons = Group {
            headerButton("Поменять местами", icon: "arrow.left.arrow.right") {
                withAnimation(.easeInOut(duration: 0.3)) { model.serversOnLeft.toggle() }
            }
            // Stays enabled while pinging: pressing it again starts over.
            headerButton("Проверить пинг", icon: "bolt.horizontal.circle", busy: model.pinging) { model.testPings() }
            headerButton("Обновить подписку", icon: "arrow.clockwise", busy: model.refreshing) {
                model.refreshSubscription(showMessage: true)
            }
            .disabled(model.refreshing)
        }
        #if os(tvOS)
        GlassGroup(spacing: 8) {
            HStack(spacing: 12) { buttons }
        }
        #else
        buttons
        #endif
    }

    private func headerButton(_ title: String, icon: String, busy: Bool = false, _ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Image(systemName: icon).font(.callout.weight(.medium))
                }
            }
            .foregroundColor(.primary)
            .frame(width: 56, height: 56)
            .glassSurface(Circle(), fallback: .cardHigh)
        }
        .glassInteractiveButton(Circle(), scale: 1.08)
        .accessibilityLabel(title)
        #else
        Button(action: action) {
            ZStack {
                if busy { ProgressView() } else { Image(systemName: icon).font(.title3) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
        .help(title)
        #endif
    }

    #if os(tvOS)
    private var paneRadius: CGFloat { 36 }
    private var headerSpacing: CGFloat { 12 }
    private var headerLeading: CGFloat { 32 }
    private var headerTrailing: CGFloat { 28 }
    private var headerTop: CGFloat { 24 }
    private var headerBottom: CGFloat { 4 }
    #else
    private var paneRadius: CGFloat { 28 }
    private var headerSpacing: CGFloat { 2 }
    private var headerLeading: CGFloat { 20 }
    private var headerTrailing: CGFloat { 8 }
    private var headerTop: CGFloat { 10 }
    private var headerBottom: CGFloat { 0 }
    #endif
}

/** Server list: sections from the subscription's separators, tabs by emoji, pings. */
struct ServerList: View {
    @EnvironmentObject private var model: AppModel
    /** On the main screen's pane: the pane's color shows through, the rows a step lighter. */
    var inPane = false
    var onPick: (ServerEntry) -> Void
    @State private var filter: String?

    private struct ServerSection: Identifiable {
        var id: String
        var title: String?
        var servers: [ServerEntry]
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

    /** Only the tabs that have servers. */
    private var filters: [ServerFilter] {
        let servers = model.subscription?.selectable ?? []
        return model.config.serverFilters.filter { f in
            let plain = f.emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
            return servers.contains { $0.remarks.contains(f.emoji) || $0.remarks.contains(plain) }
        }
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            if !filters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 12) {
                            chip("Все", selected: activeFilter == nil) { filter = nil }
                            ForEach(filters, id: \.self) { f in
                                chip("\(f.emoji) \(f.title)", selected: activeFilter == f.emoji) { filter = f.emoji }
                            }
                        }
                    }
                    .padding(.leading, 32)
                    .padding(.trailing, 56)
                    .padding(.vertical, 14)
                }
                .mask(horizontalFade)
                .focusSection()
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        if let title = section.title, !title.isEmpty {
                            Text(title)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                                .padding(.top, section.id == sections.first?.id ? 2 : 18)
                                .padding(.bottom, 2)
                                .padding(.horizontal, 8)
                        }
                        ForEach(section.servers) { server in
                            tvRow(server)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if model.pingWhitelistOnly {
                            Text("Включены белые списки — пинг проверяет только серверы для обхода")
                        }
                        Text("Удерживайте кнопку выбора или нажмите Play/Pause на сервере, чтобы проверить только его")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 14)
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .mask(verticalFade)
            .focusSection()
        }
        .task(id: model.subscription?.url) {
            if model.pingOnOpen, model.pings.isEmpty { model.testPings() }
        }
        #else
        List {
            if !filters.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassGroup(spacing: 8) {
                            HStack(spacing: 8) {
                                chip("Все", selected: activeFilter == nil) { filter = nil }
                                ForEach(filters, id: \.self) { f in
                                    chip("\(f.emoji) \(f.title)", selected: activeFilter == f.emoji) { filter = f.emoji }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(sections) { section in
                Section(header: section.title.map { Text($0) }) {
                    ForEach(section.servers) { server in
                        row(server).listRowBackground(inPane ? Color.paneRow : nil)
                    }
                }
            }
            Section(footer: VStack(alignment: .leading, spacing: 6) {
                if model.pingWhitelistOnly { Text("Включены белые списки — пинг проверяет только серверы для обхода") }
                Text(Platform.isMac ? "Правый клик по серверу — проверить только его" : "Удерживайте сервер, чтобы проверить только его")
            }) {}
        }
        .listStyle(.insetGrouped)
        .compactSections()
        .paneBackground(inPane)
        .refreshable { await model.refreshSubscriptionNow(showMessage: true) }
        .task {
            // The first look at the list checks the servers, like the Android app (unless turned off in Settings).
            if model.pingOnOpen, model.pings.isEmpty { model.testPings() }
        }
        #endif
    }

    #if os(tvOS)
    private func tvRow(_ server: ServerEntry) -> some View {
        let isSelected = server.key == model.selectedServer?.key
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Button {
            onPick(server)
        } label: {
            HStack(spacing: 14) {
                ServerTitle(server: server)
                Spacer(minLength: 10)
                PingLabel(ping: model.pings[server.key], kind: server.kind)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(Color.paneRow, in: shape)
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 2))
        }
        .glassInteractiveButton(shape, scale: 1.025, ringColor: .accentColor, ringOpacity: 0.9)
        .contextMenu {
            Button { model.pingServer(server) } label: { Label("Проверить пинг", systemImage: "bolt.horizontal") }
        }
        .onPlayPauseCommand { model.pingServer(server) }
    }

    private var horizontalFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 48)
        }
    }

    private var verticalFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
        }
    }
    #else
    private func row(_ server: ServerEntry) -> some View {
        Button {
            onPick(server)
        } label: {
            HStack {
                ServerTitle(server: server)
                Spacer()
                PingLabel(ping: model.pings[server.key], kind: server.kind)
                if server.key == model.selectedServer?.key {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button { model.pingServer(server) } label: { Label("Проверить пинг", systemImage: "bolt.horizontal") }
        }
    }
    #endif

    private func chip(_ title: String, selected: Bool, _ onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(title)
                #if os(tvOS)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                #else
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                #endif
                .foregroundColor(selected ? .onAccent : .primary)
                .contentShape(Capsule())
                .glassSurface(Capsule(), tint: selected ? .accentColor : nil, interactive: true, fallback: .cardHigh)
        }
        .glassInteractiveButton(Capsule(), scale: 1.06, ringOpacity: selected ? 0.85 : 0.55)
    }
}

private extension Color {
    /** Rows of the pane's list: lighter than the pane in both themes. */
    static let paneRow = Color(UIColor { traits in
        #if os(tvOS)
        UIColor(named: traits.userInterfaceStyle == .dark ? "CardHigh" : "Background")
            ?? (traits.userInterfaceStyle == .dark ? .darkGray : .white)
        #else
        UIColor(named: traits.userInterfaceStyle == .dark ? "CardHigh" : "Background") ?? .secondarySystemGroupedBackground
        #endif
    })
}

#if !os(tvOS)
private extension View {
    /**
     * insetGrouped leaves a big gap above the first section and between sections (the tabs under the title
     * and the list under the tabs stood far apart): tighter from iOS 17.
     */
    @ViewBuilder
    func compactSections() -> some View {
        if #available(iOS 17.0, *) {
            self.listSectionSpacing(.compact).contentMargins(.top, 6, for: .scrollContent)
        } else {
            self
        }
    }

    /** The pane's own color behind the list (iOS 16+; before, the list keeps its grouped background). */
    @ViewBuilder
    func paneBackground(_ inPane: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(inPane ? .hidden : .automatic)
        } else {
            self
        }
    }
}
#endif
