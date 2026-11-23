#if PURCHASES
import Combine
import Foundation
import StoreKit
import UIKit

/**
 * App Store purchases (StoreKit 2). Not in the build for outside testers (no PURCHASES flag): a TestFlight
 * purchase costs nothing, and that build would give the VPN away.
 *
 * The App Store only takes the money. Every signed transaction goes to the server (AppApi.purchase), which
 * checks Apple's signature, binds the subscription to an account and answers with that account's key. A
 * transaction is finished only after the server took it, so one it never heard of comes back at the next start.
 */
@MainActor
final class Shop: ObservableObject {
    enum Outcome {
        case bought(AppApi.PurchaseAnswer)
        /** Waits for somebody's approval (Ask to Buy) or for the bank: it comes later through the updates. */
        case pending
        case cancelled
    }

    /** The App Store's side of the plans on sale, by product id: the price and the period. */
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loading = false
    /** A purchase or a restore is going on. */
    @Published private(set) var busy = false

    private weak var model: AppModel?
    private var listening: Task<Void, Never>?

    /** Transactions that come by themselves: renewals, approved purchases, ones the server hasn't seen. */
    func start(_ model: AppModel) {
        self.model = model
        guard listening == nil else { return }
        listening = Task { [weak self] in
            for await update in StoreKit.Transaction.unfinished { await self?.deliver(update) }
            for await update in StoreKit.Transaction.updates { await self?.deliver(update) }
        }
    }

    /**
     * Asked every time the plans are shown, not once: until the Paid Apps agreement is in force the App
     * Store answers with nothing, and the same build starts to sell the day it is.
     */
    func load(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        loading = products.isEmpty
        defer { loading = false }
        guard let found = try? await Product.products(for: ids) else { return }
        products = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func buy(_ product: Product) async throws -> Outcome {
        busy = true
        defer { busy = false }
        let key = model?.subscription?.url
        let mark = try await AppApi.preparePurchase(key: key)
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(mark)])
        } catch {
            throw AppApiError(status: 0, code: "STORE", info: "App Store не оформил покупку. Попробуйте ещё раз.")
        }
        switch result {
        case let .success(verification):
            let answer = try await send([verification.jwsRepresentation], key: key)
            await verification.unsafePayloadValue.finish()
            return .bought(answer)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /** «Восстановить покупки»: what this Apple ID has now. nil when it has nothing. */
    func restore() async throws -> AppApi.PurchaseAnswer? {
        busy = true
        defer { busy = false }
        // Asks for the Apple ID password; closing that sheet is not an error, what is known is still sent.
        try? await AppStore.sync()
        var signed: [String] = []
        for await entitlement in StoreKit.Transaction.currentEntitlements { signed.append(entitlement.jwsRepresentation) }
        guard !signed.isEmpty else { return nil }
        return try await send(signed, key: model?.subscription?.url)
    }

    /** The money is taken by now: the server gets three tries before the person is told to restore. */
    private func send(_ signed: [String], key: String?) async throws -> AppApi.PurchaseAnswer {
        var last: Error = AppApiError.offline
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            do {
                return try await AppApi.purchase(transactions: signed, key: key)
            } catch let error as AppApiError where error.status == 0 || error.status >= 500 {
                last = error
            }
        }
        throw last
    }

    private func deliver(_ update: VerificationResult<StoreKit.Transaction>) async {
        guard let answer = try? await AppApi.purchase(transactions: [update.jwsRepresentation], key: model?.subscription?.url) else { return }
        await update.unsafePayloadValue.finish()
        model?.purchaseArrived(answer)
    }

    /** The App Store's own list of subscriptions, where one is cancelled. */
    static func manage() async {
        #if !targetEnvironment(macCatalyst)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
           (try? await AppStore.showManageSubscriptions(in: scene)) != nil {
            return
        }
        #endif
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") { _ = await UIApplication.shared.open(url) }
    }
}

extension Product {
    /** "149,00 ₽ в месяц". */
    var priceLine: String {
        guard let period = subscription?.subscriptionPeriod else { return displayPrice }
        let unit: String
        switch (period.unit, period.value) {
        case (.month, 1): unit = "в месяц"
        case (.year, 1): unit = "в год"
        case (.week, 1): unit = "в неделю"
        case (.day, 1): unit = "в день"
        case (.month, let n): unit = "за \(n) мес."
        case (.year, let n): unit = "за \(n) г."
        case (.week, let n): unit = "за \(n) нед."
        case (.day, let n): unit = "за \(n) дн."
        default: unit = ""
        }
        return unit.isEmpty ? displayPrice : "\(displayPrice) \(unit)"
    }
}
#endif
