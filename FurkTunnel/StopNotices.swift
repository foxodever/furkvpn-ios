import Foundation
import NetworkExtension
#if os(tvOS)
enum StopNotices {
    static func arm() {}
    static func disarm() {}
    static func post(_ title: String, _ body: String, done: (() -> Void)? = nil) { done?() }
    static func stopped(_ reason: NEProviderStopReason, done: @escaping () -> Void) { done() }
}
#else
import UserNotifications

/**
 * Settings → «Уведомлять об отключении VPN» (like Shadowrocket): iOS sometimes stops the VPN, and without
 * a word it is a mystery why sites stopped opening. The extension tells why when it is stopped by anything
 * but the user, when it gives up by itself, and when a white list check changes the server.
 * When iOS kills it outright (memory) nothing is called, so it keeps a notification scheduled a minute
 * ahead and moves it on every 20 s: it goes off only when the extension is gone without a clean stop.
 */
enum StopNotices {
    private static let watchdogId = "com.furkvpn.vpn-watchdog"
    private static let watchdogDelay: TimeInterval = 60
    private static let center = UNUserNotificationCenter.current()

    static var enabled: Bool { Store.notifyStops }

    /** Posts now; [done] once iOS has it (the process may end right after a stop). */
    static func post(_ title: String, _ body: String, done: (() -> Void)? = nil) {
        guard enabled else {
            done?()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done?() }
    }

    /** The VPN stopped: tells why (nothing when the user stopped it), then [done]. */
    static func stopped(_ reason: NEProviderStopReason, done: @escaping () -> Void) {
        disarm()
        guard let why = describe(reason) else {
            done()
            return
        }
        post("FurkVPN отключён", why, done: done)
    }

    /** Schedules (or moves on) the notification for an extension that disappears without a stop. */
    static func arm() {
        guard enabled else {
            disarm()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "FurkVPN отключён"
        content.body = "Похоже, iOS остановила VPN. Откройте FurkVPN, чтобы подключиться снова."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: watchdogDelay, repeats: false)
        // The same id replaces the pending one.
        center.add(UNNotificationRequest(identifier: watchdogId, content: content, trigger: trigger))
    }

    static func disarm() {
        center.removePendingNotificationRequests(withIdentifiers: [watchdogId])
    }

    /** Why iOS stopped the VPN, in words; nil when the user did. */
    private static func describe(_ reason: NEProviderStopReason) -> String? {
        switch reason {
        case .userInitiated: return nil
        case .providerFailed: return "Ошибка VPN. Откройте FurkVPN, чтобы подключиться снова."
        case .noNetworkAvailable: return "Пропал интернет. Подключитесь снова, когда сеть появится."
        case .unrecoverableNetworkChange: return "Сменилась сеть, и VPN не смог продолжить. Подключитесь снова."
        case .providerDisabled, .configurationDisabled: return "VPN-профиль FurkVPN выключен в настройках iOS."
        case .configurationRemoved: return "VPN-профиль FurkVPN удалён из настроек iOS."
        case .superceded: return "Включён другой VPN."
        case .idleTimeout: return "VPN отключён по бездействию."
        case .userLogout, .userSwitch: return "Пользователь устройства сменился."
        case .connectionFailed, .configurationFailed, .authenticationCanceled:
            return "Не удалось подключиться. Откройте FurkVPN, чтобы попробовать снова."
        default:
            // 16 is .appUpdate: an update of the app stops its VPN.
            if reason.rawValue == 16 { return "Приложение обновилось. Подключитесь снова." }
            return "iOS остановила VPN (причина \(reason.rawValue)). Откройте FurkVPN, чтобы подключиться снова."
        }
    }
}
#endif

