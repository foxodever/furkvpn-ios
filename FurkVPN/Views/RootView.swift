import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.consent == .declined {
                ConsentDeclinedView()
            } else if model.subscription == nil {
                OnboardingView()
            } else {
                HomeView()
            }
        }
        .keyAlerts()
        .toast($model.toast)
        .accessibilityHidden(model.consent == .ask)
        // Asked over the screen before anything is sent anywhere.
        .overlay {
            if model.consent == .ask {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ConsentCard()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.consent)
        .tint(.accentColor)
        #if DEMO
        .preferredColorScheme(Demo.colorScheme)
        .onAppear { Demo.snapshotLater() }
        #endif
    }
}
