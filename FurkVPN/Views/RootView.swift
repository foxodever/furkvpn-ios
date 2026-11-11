import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.subscription == nil {
                OnboardingView()
            } else {
                HomeView()
            }
        }
        .keyAlerts()
        .toast($model.toast)
        .tint(.accentColor)
        #if DEMO
        .preferredColorScheme(Demo.colorScheme)
        .onAppear { Demo.snapshotLater() }
        #endif
    }
}
