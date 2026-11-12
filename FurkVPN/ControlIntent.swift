import AppIntents

/**
 * What the FurkVPN control (FurkWidget: Control Center, Lock Screen, Action button) does: VPN on when off,
 * off when on. Built into the app and the widget extension. A control's intent would run in the widget
 * extension, which can't touch the VPN; a LiveActivityIntent is performed in the app's process (started in
 * the background if needed), and only the app's copy (FURK_APP) does the work.
 */
@available(iOS 18.0, *)
struct ToggleVPNControlIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Включить или выключить FurkVPN"
    // Shortcuts already have "Включить или выключить VPN".
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if FURK_APP
        _ = try await TunnelSwitch.toggle()
        #endif
        return .result()
    }
}
