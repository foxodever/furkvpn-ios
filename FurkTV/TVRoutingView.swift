import SwiftUI

/** Settings → Маршрутизация on Apple TV: same rules and storage format as iOS and Android. */
struct TVRoutingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding: RouteAction?

    var body: some View {
        TVSidePanelScreen(
            systemImage: "arrow.triangle.branch",
            title: "Маршрутизация",
            subtitle: "Свои правила: какие сайты открывать напрямую, через VPN или блокировать"
        ) {
            form
        }
        .sheet(item: $adding) { action in
            TVAddRulesView(action: action)
                .environmentObject(model)
        }
    }

    private var form: some View {
        Form {
            Section(footer: Text("Они важнее правил сервера")) {
                Toggle("Использовать свои правила", isOn: $model.routing.enabled)
            }
            if model.routing.enabled {
                Section(header: Text("Быстрые настройки")) {
                    Toggle(isOn: $model.routing.lanDirect) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Локальная сеть напрямую")
                            Text("Роутер, AirPlay и другие устройства дома")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $model.routing.ruDirect) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Сайты .ru, .рф и .su напрямую")
                            Text("Эти сайты будут видеть ваш настоящий адрес")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach([RouteAction.direct, .proxy, .block]) { action in
                    TVRuleSection(action: action, onAdd: { adding = action })
                }
            }
        }
    }
}

private struct TVRuleSection: View {
    @EnvironmentObject private var model: AppModel
    var action: RouteAction
    var onAdd: () -> Void
    @State private var showAll = false
    @State private var ruleToDelete: String?
    @State private var confirmClear = false

    var body: some View {
        let entries = model.routing.rules(action)
        let visible = showAll ? entries : Array(entries.prefix(5))
        Section(header: Text(action.title), footer: Text(action.hint)) {
            if entries.isEmpty {
                Label("Пока пусто", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
            ForEach(visible, id: \.self) { entry in
                Button {
                    ruleToDelete = entry
                } label: {
                    HStack(spacing: 16) {
                        Text(Core.routeDisplay(entry))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        if let kind = kindLabel(entry) {
                            Text(kind)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        model.removeRoutingRule(entry, from: action)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
            if entries.count > 5 {
                Button(showAll ? "Свернуть" : "Показать все · \(entries.count)") {
                    showAll.toggle()
                }
            }
            Button {
                onAdd()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            if entries.count > 1 {
                Button("Удалить все", role: .destructive) {
                    confirmClear = true
                }
            }
        }
        .alert("Удалить правило?", isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }), presenting: ruleToDelete) { entry in
            Button("Удалить", role: .destructive) {
                model.removeRoutingRule(entry, from: action)
                ruleToDelete = nil
            }
            Button("Отмена", role: .cancel) { ruleToDelete = nil }
        } message: { entry in
            Text("Правило «\(Core.routeDisplay(entry))» будет удалено из списка «\(action.title)».")
        }
        .alert("Очистить список «\(action.title)»?", isPresented: $confirmClear) {
            Button("Удалить все", role: .destructive) {
                model.clearRoutingRules(action)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены все записи: \(entries.count).")
        }
    }

    private func kindLabel(_ entry: String) -> String? {
        if entry.hasPrefix("keyword:") { return "слово" }
        if entry.hasPrefix("full:") { return "точно" }
        if entry.hasPrefix("regexp:") { return "regexp" }
        return nil
    }
}

private struct TVAddRulesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var action: RouteAction
    @State private var text = ""
    @State private var invalid: [String] = []

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBrandBackdrop()
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 22) {
                        TVIconBadge(systemImage: "plus", size: 72)
                        Text("Добавить в «\(action.title)»")
                            .font(.title2.weight(.bold))
                            .wraps()
                    }
                    Text("Укажите сайты или IP-адреса через запятую или пробел: youtube.com, .ru, 1.2.3.4, 10.0.0.0/8. Сайт включает все поддомены.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .wraps()

                    TextField("youtube.com, .ru, 1.2.3.4", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onSubmit {
                            if canAdd { add() }
                        }

                    TVGlassGroup(spacing: 8) {
                        HStack(spacing: 16) {
                            prefixButton("+ слово", "keyword:")
                            prefixButton("+ точно", "full:")
                            prefixButton("+ regexp", "regexp:")
                        }
                    }

                    if !invalid.isEmpty {
                        Text("Не распознано: \(invalid.joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .wraps()
                    }

                    HStack(spacing: 24) {
                        Spacer()
                        Button("Отмена") { dismiss() }
                            .buttonStyle(TVActionButtonStyle())
                        Button("Добавить") { add() }
                            .buttonStyle(TVActionButtonStyle(prominent: true))
                            .disabled(!canAdd)
                    }
                    .padding(.top, 8)
                }
                .tvCard(.card, padding: 52, cornerRadius: 40)
                .frame(maxWidth: 1120)
                .padding(80)
            }
        }
    }

    private func prefixButton(_ title: String, _ prefix: String) -> some View {
        Button(title) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let last = text.last, !",; \t".contains(last) {
                text += ", "
            }
            text += prefix
        }
        .buttonStyle(TVPillButtonStyle())
    }

    private func add() {
        let (valid, rejected) = Core.parseRouteList(text)
        if !valid.isEmpty { model.addRoutingRules(valid, to: action) }
        if rejected.isEmpty {
            dismiss()
        } else {
            invalid = rejected
            text = rejected.joined(separator: ", ")
        }
    }
}
