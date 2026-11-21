import SwiftUI

/** Settings → Routing: the user's rules over the server's ones (same storage format as Android). */
struct RoutingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding: RouteAction?

    var body: some View {
        Form {
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
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { action in
            AddRulesSheet(action: action).environmentObject(model)
        }
    }
}

private struct RuleSection: View {
    @EnvironmentObject private var model: AppModel
    var action: RouteAction
    var onAdd: () -> Void
    @State private var showAll = false
    @State private var confirmClear = false

    var body: some View {
        let entries = model.routing.rules(action)
        let visible = showAll ? entries : Array(entries.prefix(5))
        Section(header: Text(action.title), footer: Text(action.hint)) {
            if entries.isEmpty {
                Text("Пока пусто").foregroundColor(.secondary)
            }
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
            if entries.count > 5 {
                Button(showAll ? "Свернуть" : "Показать все · \(entries.count)") { showAll.toggle() }
            }
            Button { onAdd() } label: { Label("Добавить", systemImage: "plus") }
            if entries.count > 1 {
                Button("Удалить все", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Очистить список «\(action.title)»?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить все", role: .destructive) { model.clearRoutingRules(action) }
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

private struct AddRulesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var action: RouteAction
    @State private var text = ""
    @State private var invalid: [String] = []

    var body: some View {
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
                Button("Добавить") { add() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheetGlass()
    }

    private func prefixButton(_ title: String, _ prefix: String) -> some View {
        Button(title) {
            if let last = text.last, !"\n ,;\t".contains(last) { text += "\n" }
            text += prefix
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func add() {
        let (valid, rejected) = Core.parseRouteList(text)
        if !valid.isEmpty { model.addRoutingRules(valid, to: action) }
        if rejected.isEmpty {
            dismiss()
        } else {
            invalid = rejected
            text = rejected.joined(separator: "\n")
        }
    }
}
