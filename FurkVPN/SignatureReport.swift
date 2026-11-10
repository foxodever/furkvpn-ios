import Foundation
import Libxray

/**
 * How the re-signing tool signed the app and the VPN extension (Settings → Диагностика): iOS matches the
 * extension and the app that controls it by the signing identifier, team and application-identifier, and
 * lets only a recognised provider's own connections past its tunnel.
 */
enum SignatureReport {
    static let app: String = describe(executable: Bundle.main.executableURL)
    static let tunnel: String = describe(executable: TunnelExtension.bundleURL.flatMap { Bundle(url: $0)?.executableURL })
    static let appProfile: String = profile(in: Bundle.main.bundleURL)
    static let tunnelProfile: String = TunnelExtension.bundleURL.map(profile(in:)) ?? "расширение не найдено"

    private struct Info: Decodable {
        var identifier: String?
        var team: String?
        var entitlements: String?
        var error: String?
    }

    private static func describe(executable: URL?) -> String {
        guard let path = executable?.path else { return "файл не найден" }
        guard let info = try? JSONDecoder().decode(Info.self, from: Data(LibxraySignatureInfo(path).utf8)) else { return "не прочитать" }
        if let error = info.error { return error }
        var lines = ["ID подписи: \(info.identifier ?? "—"), команда: \(info.team ?? "—")"]
        guard let xml = info.entitlements,
              let ents = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] else {
            return (lines + ["entitlements нет"]).joined(separator: "\n")
        }
        lines.append(entitlements(ents))
        return lines.joined(separator: "\n")
    }

    private static func entitlements(_ ents: [String: Any]) -> String {
        func list(_ key: String) -> String { (ents[key] as? [String])?.joined(separator: ", ") ?? "нет" }
        var parts = [
            "application-identifier: \(ents["application-identifier"] as? String ?? "нет")",
            "team-identifier: \(ents["com.apple.developer.team-identifier"] as? String ?? "нет")",
            "networkextension: \(list("com.apple.developer.networking.networkextension"))",
            "app groups: \(list("com.apple.security.application-groups"))",
        ]
        if ents["get-task-allow"] as? Bool == true { parts.append("get-task-allow") }
        parts.append("ключей: \(ents.count)")
        return parts.joined(separator: "\n")
    }

    /** The embedded provisioning profile: a CMS-signed plist, the XML sits in it as plain text. */
    private static func profile(in bundle: URL) -> String {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision")) else {
            return "нет embedded.mobileprovision"
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any] else {
            return "не прочитать"
        }
        let ents = plist["Entitlements"] as? [String: Any] ?? [:]
        let kind: String
        if plist["ProvisionsAllDevices"] as? Bool == true {
            kind = "enterprise"
        } else if let devices = plist["ProvisionedDevices"] as? [String] {
            kind = (ents["get-task-allow"] as? Bool == true ? "development" : "ad hoc") + ", устройств \(devices.count)"
        } else {
            kind = "App Store / TestFlight"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        let expires = (plist["ExpirationDate"] as? Date).map(formatter.string(from:)) ?? "—"
        let teams = (plist["TeamIdentifier"] as? [String])?.joined(separator: ", ") ?? "—"
        return "«\(plist["Name"] as? String ?? "—")», \(kind), команда \(teams), до \(expires)\n" + entitlements(ents)
    }
}
