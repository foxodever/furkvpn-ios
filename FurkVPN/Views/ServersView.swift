import SwiftUI
import UIKit

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

/**
 * The server list next to the main screen on wide windows (iPad, Mac, the unfolded iPhone Duo), like the
 * Android app. It stands on the right; the swap button or Settings → Интерфейс moves it to the left.
 */
struct ServersPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Серверы").font(.title3.weight(.semibold))
                Spacer()
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
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 10)
            ServerList(inPane: true) { model.select($0.key) }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func headerButton(_ title: String, icon: String, busy: Bool = false, _ action: @escaping () -> Void) -> some View {
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
    }
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

    private var sections: [ServerSection] {
        var result: [ServerSection] = []
        var current = ServerSection(id: "top", title: nil, servers: [])
        for entry in model.subscription?.servers ?? [] {
            if entry.kind == .separator {
                if !current.servers.isEmpty { result.append(current) }
                current = ServerSection(id: entry.key, title: entry.title, servers: [])
            } else if filter.map({ entry.remarks.contains($0) || entry.remarks.contains($0.replacingOccurrences(of: "\u{FE0F}", with: "")) }) ?? true {
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
        List {
            if !filters.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassGroup(spacing: 8) {
                            HStack(spacing: 8) {
                                chip("Все", selected: filter == nil) { filter = nil }
                                ForEach(filters, id: \.self) { f in
                                    chip("\(f.emoji) \(f.title)", selected: filter == f.emoji) { filter = f.emoji }
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
    }

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

    private func chip(_ title: String, selected: Bool, _ onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundColor(selected ? .onAccent : .primary)
                .contentShape(Capsule())
                .glassSurface(Capsule(), tint: selected ? .accentColor : nil, interactive: true, fallback: .cardHigh)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

private extension Color {
    /** Rows of the pane's list: lighter than the pane in both themes. */
    static let paneRow = Color(UIColor { traits in
        UIColor(named: traits.userInterfaceStyle == .dark ? "CardHigh" : "Background") ?? .secondarySystemGroupedBackground
    })
}

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
