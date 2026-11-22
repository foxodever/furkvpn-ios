import Foundation
import UIKit

/** Where the app runs: an iPhone or an iPad, or a Mac (the Mac Catalyst build, or the iPad app on an Apple silicon Mac). */
enum Platform {
    /** True for both kinds of Mac: isMacCatalystApp is also set for iOS apps running on a Mac. */
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    /** For the panel's device list and the User-Agent. */
    #if os(tvOS)
    static let osName = "tvOS"
    #else
    static let osName = isMac ? "macOS" : "iOS"
    #endif

    /** "26.1": on a Mac the version of macOS, not of the iOS it imitates. */
    static let osVersion: String = {
        guard isMac else { return UIDevice.current.systemVersion }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    /** "iPhone15,3", "Mac15,3": what Remnawave shows as the device model (on a Mac uname only says "arm64"). */
    static let model: String = {
        if isMac, let model = sysctl("hw.model") { return model }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.isEmpty ? UIDevice.current.model : machine
    }()

    /**
     * Installed from the App Store: then the app has no «Диагностика VPN» and no debug mode, they are for
     * TestFlight and for re-signed IPAs. The App Store leaves a receipt named "receipt" in the app; TestFlight
     * and App Review a "sandboxReceipt"; Xcode and re-signing tools none. (A Mac's TestFlight receipt is named
     * "receipt" too: if the Mac app goes to the App Store, tell them apart with AppTransaction.environment.)
     */
    static let fromAppStore: Bool = {
        #if DEMO
        // The App Store's screenshots show the app as it is there.
        return true
        #else
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return receipt.lastPathComponent == "receipt" && FileManager.default.fileExists(atPath: receipt.path)
        #endif
    }()

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }
}
