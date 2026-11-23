import Foundation

/**
 * The site's API for this app (https://api.furkvpn.info/v1/app/…, the server's code is /root/global/v1/app on
 * furkvpn.info): signing in without the site's captcha, the account behind the key, App Store purchases.
 * An account is proven by its key, the subscription link: whoever has the key uses the VPN anyway.
 */
struct AppApiError: LocalizedError, Equatable {
    var status: Int
    /** For the app: "WAIT", "WRONG", "KEY_NOT_FOUND"… */
    var code: String
    /** For the person, in Russian. */
    var info: String
    var seconds: Int?

    var errorDescription: String? { info }

    static let offline = AppApiError(status: 0, code: "OFFLINE", info: "Не удалось связаться с сервером. Проверьте интернет и попробуйте ещё раз.")
}

/** A plan sold in the App Store: the server knows which plan a product gives, StoreKit knows its price. */
struct AppProduct: Codable, Equatable, Identifiable {
    var productId: String
    var plan: Int
    var name: String
    var features: [String]

    var id: String { productId }
}

/** The account of the key in the app, as the site sees it. */
struct AppAccount: Codable, Equatable {
    struct Plan: Codable, Equatable {
        var id: Int
        var name: String
        /** Unix seconds; 0 when the plan has no term. */
        var expire: Int64
        var paid: Bool
    }

    struct StoreSubscription: Codable, Equatable {
        var productId: String
        var expiresAt: Int64
        var autoRenew: Bool
        /** A TestFlight or App Review purchase: no money was taken. */
        var sandbox: Bool
    }

    /** False for a key that FurkVPN didn't issue (a partner's): nothing below is known then. */
    var own: Bool
    /** Nothing but the key leads to the account: the app offers to link an email, Apple or Telegram. */
    var anonymous: Bool?
    /** Masked: "m•••@icloud.com". */
    var email: String?
    var telegram: Bool?
    var apple: Bool?
    var plan: Plan?
    /** Who renews the plan: "appstore", "card", "balance" or "none". */
    var payment: String?
    var appstore: StoreSubscription?
    /** How deleting the account is confirmed: "code" (sent by email), "none" or "bot". */
    var deleteConfirm: String?
}

/** The account and whether a plan can be bought in the App Store for it now. */
struct AppOffer: Codable, Equatable {
    var account: AppAccount?
    var canBuy: Bool
    /** Why not: "FOREIGN_KEY", "APP_STORE_ACTIVE", "PLAN_ACTIVE". */
    var reason: String?
    var products: [AppProduct]
    var fetchedAt: Date?
}

enum AppApi {
    struct KeyAnswer: Decodable {
        var key: String
        var created: Bool?
    }

    struct PurchaseAnswer: Decodable {
        /** "active", "expired", "revoked" or "superseded". */
        var status: String
        /** The key of the account the subscription belongs to. */
        var key: String?
        /** False when the app holds another account's key. */
        var sameAccount: Bool?
        var newAccount: Bool?
        var expiresAt: Int64?
    }

    struct DeleteRequest: Decodable {
        var confirm: String
        var email: String?
    }

    struct Deleted: Decodable {
        var deleted: Bool
        var appstoreActive: Bool?
    }

    private struct Challenge: Decodable { var challenge: String }
    private struct Token: Decodable { var token: String }
    private struct Link: Decodable { var url: String }
    private struct Nothing: Decodable {}
    private struct Failure: Decodable {
        var code: String?
        var info: String?
        var seconds: Int?
    }

    /** "api.furkvpn.info": from the remote config (site.apiDomain), set by AppModel. */
    static var host = SiteConfig().apiDomain

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func call<T: Decodable>(_ type: T.Type, _ path: String, _ body: [String: Any]? = [:], attested: Bool = false) async throws -> T {
        guard let url = URL(string: "https://\(host)\(path)") else { throw AppApiError.offline }
        var request = URLRequest(url: url)
        var payload = Data()
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            request.httpBody = payload
        }
        if attested {
            // The device signs exactly the bytes that are sent.
            for (name, value) in await Attest.shared.headers(method: request.httpMethod ?? "GET", path: path, body: payload) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Http.session.data(for: request)
        } catch {
            throw AppApiError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), let value = try? decoder.decode(T.self, from: data) { return value }
        if let failure = try? decoder.decode(Failure.self, from: data), let info = failure.info, !(200..<300).contains(status) {
            throw AppApiError(status: status, code: failure.code ?? "", info: info, seconds: failure.seconds)
        }
        throw AppApiError(status: status, code: "BAD_ANSWER", info: "Сервер ответил непонятно. Попробуйте позже.")
    }

    // MARK: App Attest

    static func challenge() async throws -> String {
        try await call(Challenge.self, "/v1/app/challenge", nil).challenge
    }

    static func registerDevice(keyId: String, attestation: String, challenge: String) async throws {
        _ = try await call(Nothing.self, "/v1/app/attest", ["key_id": keyId, "attestation": attestation, "challenge": challenge])
    }

    // MARK: Sign-in

    /** Sends a code to the address. */
    static func sendSignInCode(email: String) async throws {
        _ = try await call(Nothing.self, "/v1/app/auth/email", ["email": email], attested: true)
    }

    /** The key of the account with this email; the account is made when there was none. */
    static func signIn(email: String, code: String) async throws -> KeyAnswer {
        try await call(KeyAnswer.self, "/v1/app/auth/code", ["email": email, "code": code])
    }

    /** With a key: the Apple account is bound to the key's account. */
    static func signInWithApple(identityToken: String, authorizationCode: String?, challenge: String, key: String?) async throws -> KeyAnswer {
        var body: [String: Any] = ["identity_token": identityToken, "challenge": challenge]
        if let authorizationCode { body["authorization_code"] = authorizationCode }
        if let key { body["key"] = key }
        return try await call(KeyAnswer.self, "/v1/app/auth/apple", body)
    }

    // MARK: Account

    /** Without a key: just the plans on sale (a purchase then makes a new account). */
    static func offer(key: String?) async throws -> AppOffer {
        var offer = try await call(AppOffer.self, "/v1/app/account", key.map { ["key": $0] } ?? [:])
        offer.fetchedAt = Date()
        return offer
    }

    static func sendLinkCode(key: String, email: String) async throws {
        _ = try await call(Nothing.self, "/v1/app/link/email", ["key": key, "email": email], attested: true)
    }

    static func linkEmail(key: String, email: String, code: String) async throws {
        _ = try await call(Nothing.self, "/v1/app/link/code", ["key": key, "email": email, "code": code])
    }

    /** A one-time link to the bot that binds Telegram to the account. */
    static func telegramLink(key: String) async throws -> String {
        try await call(Link.self, "/v1/app/link/telegram", ["key": key]).url
    }

    static func requestDeletion(key: String) async throws -> DeleteRequest {
        try await call(DeleteRequest.self, "/v1/app/account/delete/request", ["key": key], attested: true)
    }

    static func deleteAccount(key: String, code: String?) async throws -> Deleted {
        var body: [String: Any] = ["key": key]
        if let code { body["code"] = code }
        return try await call(Deleted.self, "/v1/app/account/delete", body)
    }

    // MARK: Purchases

    /** The mark of a purchase about to start (StoreKit's appAccountToken): by it Apple tells the server whose it is. */
    static func preparePurchase(key: String?) async throws -> UUID {
        let token = try await call(Token.self, "/v1/app/purchase/prepare", key.map { ["key": $0] } ?? [:]).token
        guard let uuid = UUID(uuidString: token) else { throw AppApiError(status: 200, code: "BAD_ANSWER", info: "Сервер ответил непонятно. Попробуйте позже.") }
        return uuid
    }

    /** Signed transactions from StoreKit (after a purchase, or all of them for a restore) and the key in the app. */
    static func purchase(transactions: [String], key: String?) async throws -> PurchaseAnswer {
        var body: [String: Any] = ["transactions": transactions]
        if let key { body["key"] = key }
        return try await call(PurchaseAnswer.self, "/v1/app/purchase", body)
    }
}
