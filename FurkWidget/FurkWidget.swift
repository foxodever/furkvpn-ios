import AppIntents
import SwiftUI
import WidgetKit

/**
 * The widgets (iOS 18+): the FurkVPN widget for the home screen and the Lock Screen (StatusWidget.swift), and
 * the FurkVPN control for Control Center, the Lock Screen and the Action button. The control is a button, not
 * a toggle: a control's state is asked for when it is drawn and not pushed, and the status bar shows "VPN"
 * anyway. Both run their intent in the app's process (ControlIntent.swift).
 */
@main
struct FurkWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        VPNControl()
    }
}

struct VPNControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.furkvpn.app.vpn-toggle") {
            ControlWidgetButton(action: ToggleVPNControlIntent()) {
                Label("FurkVPN", systemImage: "power")
            }
        }
        .displayName("FurkVPN")
        .description("Включает VPN, а если он включён — выключает.")
    }
}
