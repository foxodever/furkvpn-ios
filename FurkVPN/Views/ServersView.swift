import SwiftUI

/** Server list: sections from the subscription's separators, tabs by emoji, pings. */
struct ServersView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
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
        NavigationView {
            List {
                if !filters.isEmpty {
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
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                ForEach(sections) { section in
                    Section(header: section.title.map { Text($0) }) {
                        ForEach(section.servers) { server in
                            row(server)
                        }
                    }
                }
                Section(footer: Text("Удерживайте сервер, чтобы проверить только его")) {}
            }
            .listStyle(.insetGrouped)
            .refreshable { model.refreshSubscription(showMessage: true) }
            .navigationTitle("Серверы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.pinging { ProgressView() }
                    // Stays enabled while pinging: pressing it again starts over.
                    Button { model.testPings() } label: { Label("Проверить пинг", systemImage: "bolt.horizontal.circle") }
                }
            }
            .task {
                // The first look at the list checks the servers, like the Android app.
                if model.pings.isEmpty { model.testPings() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ server: ServerEntry) -> some View {
        Button {
            model.select(server.key)
            dismiss()
        } label: {
            HStack {
                ServerTitle(server: server)
                Spacer()
                PingLabel(ping: model.pings[server.key], kind: server.kind)
                if server.key == model.selectedServer?.key {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
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
    }
}
