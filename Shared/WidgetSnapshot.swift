import Foundation
import Security
#if canImport(WidgetKit)
import WidgetKit
#endif

/**
 * What the home screen and Lock Screen widgets show: the VPN's state, the server, the plan and its end. The
 * widget extension has no App Group (its App ID has none, and only the developer portal can give it one), so
 * the app and the tunnel extension leave this in a keychain group the three of them share: the App Store
 * profiles allow any "<team>.*" group. Builds signed by someone else (or ad hoc, build.sh) don't have the
 * group; there the widget only says to open the app.
 */
struct WidgetSnapshot: Codable, Equatable {
    enum VPN: String, Codable {
        case off, connecting, on
    }

    var vpn: VPN = .off
    /** When the VPN connected (the widget counts the time from it). */
    var since: Date?
    /** The selected server with its flag. */
    var server: String?
    var hasKey = false
    /** "Тариф «Стандарт»", "Бесплатный тариф" or "Ваша подписка". */
    var plan: String?
    /** The plan's end; nil when it has none or is unknown. */
    var expires: Date?
    /** No end at all (shown as such); false on the free plan and when nothing is known. */
    var endless = false

    static func days(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word = mod10 == 1 && mod100 != 11 ? "день" : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "дня" : "дней"
        return "\(n) \(word)"
    }
}

enum WidgetState {
    /** The status widget (FurkWidget/StatusWidget.swift). */
    static let kind = "com.furkvpn.app.status"
    /** Listed in the keychain-access-groups of the app, the tunnel and the widget (Furry LLC's team). */
    static let accessGroup = "2N5KR68546.com.furkvpn.shared"

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.furkvpn.widget",
        kSecAttrAccount as String: "state",
        kSecAttrAccessGroup as String: accessGroup,
    ]
    /** The app and the tunnel extension may both write at once: one change at a time in each process. */
    private static let lock = NSLock()

    static func load() -> WidgetSnapshot? {
        var item: CFTypeRef?
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /** Changes what the widgets show; they are redrawn only when something did change. */
    static func change(_ edit: (inout WidgetSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let old = load()
        var new = old ?? WidgetSnapshot()
        edit(&new)
        if new.vpn != .on { new.since = nil }
        guard new != old, let data = try? JSONEncoder().encode(new) else { return }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // The Lock Screen widget is drawn while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        #if canImport(WidgetKit)
        if status == errSecSuccess { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        #endif
    }
}
