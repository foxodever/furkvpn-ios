import CryptoKit
import DeviceCheck
import Foundation

/**
 * App Attest: proof for the server that a request comes from this app on a real Apple device. It stands in
 * for the site's captcha where a request makes the server send a letter. The device makes a key once, Apple
 * certifies it, the server remembers it; then the key signs each such request (time, method, path and body).
 * Where App Attest is missing (a Mac, a simulator) the request goes unsigned and the server counts such
 * requests much more strictly.
 */
actor Attest {
    static let shared = Attest()

    private let service = DCAppAttestService.shared
    private let stored = "attestKeyId"

    /** Headers for the request, or none when the device can't sign it. Never throws: unsigned is allowed. */
    func headers(method: String, path: String, body: Data) async -> [String: String] {
        guard service.isSupported else { return [:] }
        for attempt in 0..<2 {
            do {
                let id = try await registeredKey()
                let time = String(Int(Date().timeIntervalSince1970))
                var signed = Data("\(time)\n\(method)\n\(path)\n".utf8)
                signed.append(body)
                let assertion = try await service.generateAssertion(id, clientDataHash: Data(SHA256.hash(data: signed)))
                return ["X-App-Key": id, "X-App-Time": time, "X-App-Assertion": assertion.base64EncodedString()]
            } catch let error as DCError where error.code == .invalidKey {
                // The key is gone (the app was reinstalled or came from a backup): a new one, once.
                UserDefaults.standard.removeObject(forKey: stored)
                if attempt == 1 { return [:] }
            } catch {
                return [:]
            }
        }
        return [:]
    }

    private func registeredKey() async throws -> String {
        if let id = UserDefaults.standard.string(forKey: stored) { return id }
        let id = try await service.generateKey()
        let challenge = try await AppApi.challenge()
        let attestation = try await service.attestKey(id, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        try await AppApi.registerDevice(keyId: id, attestation: attestation.base64EncodedString(), challenge: challenge)
        UserDefaults.standard.set(id, forKey: stored)
        return id
    }
}
