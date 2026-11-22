import SwiftUI

/** Settings → Routing: the user's rules over the server's ones (same storage format as Android). */
struct RoutingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding: RouteAction?

    var body: some View {
        let form = Form {
            Section(footer: Text("Они важнее правил сервера")) {
                Toggle("Использовать свои правила", isOn: $model.routing.enabled)
            }
            if model.routing.enabled {
                Section(header: Text("Быстрые настройки")) {
                    Toggle(isOn: $model.routing.lanDirect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Локальная сеть напрямую")
                            Text("Роутер, принтеры, телевизоры и другие устройства дома").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $model.routing.ruDirect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Сайты .ru, .рф и .su напрямую")
                            Text("Эти сайты будут видеть ваш настоящий адрес").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                ForEach([RouteAction.direct, .proxy, .block]) { action in
                    RuleSection(action: action, onAdd: { adding = action })
                }
            }
        }
        .navigationTitle("Маршрутизация")
        .inlineNavigationBar()
        #if os(tvOS)
        .fullScreenCover(item: $adding) { action in
            AddRulesSheet(action: action).environmentObject(model)
        }
        #else
        .sheet(item: $adding) { action in
            AddRulesSheet(action: action).environmentObject(model)
        }
        #endif

        #if os(tvOS)
        TVDetailLayout(icon: "arrow.triangle.branch", caption: "Свои правила важнее правил сервера: напрямую, через VPN или блокировать") {
            form
        }
        #else
        form
        #endif
    }
}

private struct RuleSection: View {
    @EnvironmentObject private var model: AppModel
    var action: RouteAction
    var onAdd: () -> Void
    @State private var showAll = false
    @State private var confirmClear = false
    #if os(tvOS)
    @State private var ruleToDelete: String?
    #endif

    var body: some View {
        let entries = model.routing.rules(action)
        let visible = showAll ? entries : Array(entries.prefix(5))
        let section = Section(header: Text(action.title), footer: Text(action.hint)) {
            if entries.isEmpty {
                Text("Пока пусто").foregroundColor(.secondary)
            }
            #if os(tvOS)
            ForEach(visible, id: \.self) { entry in
                Button {
                    ruleToDelete = entry
                } label: {
                    HStack {
                        Text(Core.routeDisplay(entry))
                        Spacer()
                        if let kind = kindLabel(entry) {
                            Text(kind).font(.caption).foregroundColor(.secondary)
                        }
                        Image(systemName: "trash").font(.caption).foregroundColor(.secondary)
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
            #else
            ForEach(visible, id: \.self) { entry in
                HStack {
                    Text(Core.routeDisplay(entry))
                    Spacer()
                    if let kind = kindLabel(entry) {
                        Text(kind).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { visible[$0] }.forEach { model.removeRoutingRule($0, from: action) }
            }
            #endif
            if entries.count > 5 {
                Button(showAll ? "Свернуть" : "Показать все · \(entries.count)") { showAll.toggle() }
            }
            Button { onAdd() } label: { Label("Добавить", systemImage: "plus") }
            if entries.count > 1 {
                Button("Удалить все", role: .destructive) { confirmClear = true }
            }
        }
        #if os(tvOS)
        section
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
                Button("Удалить все", role: .destructive) { model.clearRoutingRules(action) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут удалены все записи: \(entries.count).")
            }
        #else
        section
            .confirmationDialog("Очистить список «\(action.title)»?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Удалить все", role: .destructive) { model.clearRoutingRules(action) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут удалены все записи: \(entries.count).")
            }
        #endif
    }

    private func kindLabel(_ entry: String) -> String? {
        if entry.hasPrefix("keyword:") { return "слово" }
        if entry.hasPrefix("full:") { return "точно" }
        if entry.hasPrefix("regexp:") { return "regexp" }
        return nil
    }
}

private struct AddRulesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var action: RouteAction
    @State private var text = ""
    @State private var invalid: [String] = []

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            ZStack {
                BrandBackdrop()
                VStack(alignment: .leading, spacing: 24) {
                    TVSheetHeader(icon: "plus", title: "Добавить в «\(action.title)»")
                    Text("Укажите сайты или IP-адреса через запятую или пробел: youtube.com, .ru, 1.2.3.4, 10.0.0.0/8. Сайт включает все поддомены.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .wraps()
                    TextField("youtube.com, .ru, 1.2.3.4", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit {
                            if canAdd { add() }
                        }
                    GlassGroup(spacing: 10) {
                        HStack(spacing: 14) {
                            prefixButton("+ слово", "keyword:")
                            prefixButton("+ точно", "full:")
                            prefixButton("+ regexp", "regexp:")
                        }
                    }
                    if !invalid.isEmpty {
                        Text("Не распознано: \(invalid.joined(separator: ", "))")
                            .font(.callout)
                            .foregroundColor(.red)
                            .wraps()
                    }
                    GlassGroup(spacing: 12) {
                        HStack(spacing: 20) {
                            Spacer()
                            Button("Отмена") { dismiss() }
                                .glassButtonStyle()
                            Button("Добавить") { add() }
                                .glassButtonStyle(prominent: true)
                                .disabled(!canAdd)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(44)
                .cardSurface(RoundedRectangle(cornerRadius: 36, style: .continuous), color: .card)
                .frame(maxWidth: 1040)
                .padding(60)
            }
        }
        #else
        NavigationView {
            Form {
                Section(header: Text("Сайты или IP-адреса"),
                        footer: Text("По одному в строке или через запятую: youtube.com, .ru, 1.2.3.4, 10.0.0.0/8. Сайт включает все поддомены. keyword:yandex — все адреса со словом yandex.")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    HStack {
                        prefixButton("+ слово", "keyword:")
                        prefixButton("+ точно", "full:")
                        prefixButton("+ regexp", "regexp:")
                    }
                }
                if !invalid.isEmpty {
                    Section {
                        Text("Не распознано: \(invalid.joined(separator: ", "))").foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Добавить в «\(action.title)»")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Отмена") { dismiss() } }
            .barItem(.confirmationAction) {
                Button("Добавить") { add() }.disabled(!canAdd)
            }
        }
        .sheetGlass()
        #endif
    }

    private func prefixButton(_ title: String, _ prefix: String) -> some View {
        Button(title) {
            #if os(tvOS)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let last = text.last, !",; \t".contains(last) { text += ", " }
            #else
            if let last = text.last, !"\n ,;\t".contains(last) { text += "\n" }
            #endif
            text += prefix
        }
        #if os(tvOS)
        .glassButtonStyle()
        #else
        .buttonStyle(.bordered)
        .font(.caption)
        #endif
    }

    private func add() {
        let (valid, rejected) = Core.parseRouteList(text)
        if !valid.isEmpty { model.addRoutingRules(valid, to: action) }
        if rejected.isEmpty {
            dismiss()
        } else {
            invalid = rejected
            #if os(tvOS)
            text = rejected.joined(separator: ", ")
            #else
            text = rejected.joined(separator: "\n")
            #endif
        }
    }
}
