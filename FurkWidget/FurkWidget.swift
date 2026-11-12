import AppIntents
import SwiftUI
import WidgetKit

/**
 * iOS 18 controls: the FurkVPN button for Control Center, the Lock Screen and the Action button. A button,
 * not a toggle: the widget extension has no App Group to read the VPN's state from, and the status bar shows
 * "VPN" anyway. The intent runs in the app's process (ControlIntent.swift).
 */
@main
struct FurkWidgets: WidgetBundle {
    var body: some Widget {
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
