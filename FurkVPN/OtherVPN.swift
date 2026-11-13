import CFNetwork
import Foundation

/**
 * Another app's VPN: iOS shows no other app's VPN profile, but while one is on its tunnel interface is listed
 * in the system's network settings ("utun5", "ipsec0", "ppp0"). Only one VPN runs at a time, so with ours
 * off such an interface is someone else's — and the app's own white list check would go through it and see
 * everything open.
 */
enum OtherVPN {
    /** The VPN interfaces traffic goes through now; empty when no VPN is on. */
    static func interfaces() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return [] }
        let kinds = ["tun", "tap", "ppp", "ipsec"]
        return scoped.keys.filter { name in kinds.contains { name.lowercased().contains($0) } }.sorted()
    }
}
