import SwiftUI

@main
struct FurkTVApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(model)
                .environmentObject(model.vpn)
                .task { model.onResume() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.onResume() }
                }
        }
    }
}

private struct TVRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.consent == .ask {
                TVConsentView()
            } else if model.consent == .declined {
                TVConsentDeclinedView()
            } else if model.subscription == nil {
                TVOnboardingView()
            } else {
                TVHomeView()
            }
        }
        .tvToast($model.toast)
        .tint(.accentColor)
        .alert("Ключ не добавлен", isPresented: Binding(get: { model.keyError != nil }, set: { if !$0 { model.keyError = nil } })) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(model.keyError ?? "")
        }
        .alert("Заменить ключ?", isPresented: Binding(get: { model.pendingReplace != nil }, set: { if !$0 { model.pendingReplace = nil } })) {
            Button("Заменить", role: .destructive) { model.confirmReplace() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий ключ будет заменён новым.")
        }
        #if DEMO
        .preferredColorScheme(Demo.colorScheme)
        .onAppear { Demo.snapshotLater() }
        #endif
    }
}
