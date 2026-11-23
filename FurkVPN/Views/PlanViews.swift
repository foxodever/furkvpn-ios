import SwiftUI
#if PURCHASES
import StoreKit
#endif

/** What the plan card and the plan sheet both say about the plan. */
struct PlanSummary {
    /** False while nothing is known yet: no card then. */
    var known: Bool
    var title: String
    var details: String?
    var expired: Bool
    var isFree: Bool
    var limit: Int64?
    var used: Int64?

    @MainActor
    init(_ model: AppModel) {
        let account = model.account
        let subscription = model.subscription
        let found = account?.found == true
        // Fall back to the expiry date from the subscription headers when the API is unreachable.
        let expiresAt = found ? account?.expiresAt : subscription?.expire
        let now = Int64(Date().timeIntervalSince1970)
        isFree = found && account?.isFree == true
        expired = expiresAt.map { $0 <= now } ?? false
        known = found || expiresAt != nil
        limit = (found ? account?.trafficLimit : subscription?.total).flatMap { $0 > 0 ? $0 : nil }
        used = found ? account?.trafficUsed : subscription.map { ($0.upload ?? 0) + ($0.download ?? 0) }

        // An active plan is shown by name; "Ваша подписка" only when there is none.
        if expired {
            title = "Ваша подписка"
        } else if isFree {
            title = "Бесплатный тариф"
        } else if found, let name = account?.planName {
            title = "Тариф «\(name)»"
        } else {
            title = "Ваша подписка"
        }

        if expired {
            details = "Подписка закончилась"
        } else if let expiresAt {
            let days = max(Int((expiresAt - now) / 86_400), 0)
            details = "Действует до \(Format.date(expiresAt)) · Осталось \(Format.days(days))"
        } else {
            details = isFree ? nil : "Без срока окончания"
        }
    }
}

/**
 * Plan, expiry and traffic on the main screen. A tap opens the plan sheet (PlanSheet): who pays for the plan,
 * the App Store purchase, the account. «Купить тариф» / «Продлить» shows when the plan is free or over and the
 * App Store may sell one for this account. There are no links to pay anywhere else: the App Store's rule 3.1.1.
 */
struct AccountCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let plan = PlanSummary(model)
        if plan.known {
            Button { model.planOpen = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title).font(.headline)
                    if let details = plan.details {
                        Text(details)
                            .font(.subheadline)
                            .foregroundColor(plan.expired ? .onErrorCard : .secondary)
                            .wraps()
                    }
                    if let limit = plan.limit, let used = plan.used {
                        ProgressView(value: min(max(Double(used) / Double(limit), 0), 1))
                            .padding(.top, 8)
                        Text("Использовано \(Format.bytes(used)) из \(Format.bytes(limit)) · осталось \(Format.bytes(max(limit - used, 0)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .wraps()
                    } else if let used = plan.used, used > 0 {
                        Text("Использовано \(Format.bytes(used))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    if canBuy(plan) {
                        Text(plan.isFree ? "Купить тариф" : "Продлить")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.onAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.accentColor))
                            .padding(.top, 8)
                    } else {
                        Text("Подробнее")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(plan.expired ? .onErrorCard : .accentColor)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(.primary)
                .card(plan.expired ? .errorCard : .card)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func canBuy(_ plan: PlanSummary) -> Bool {
        #if PURCHASES
        return model.offer?.canBuy == true && (plan.isFree || plan.expired)
        #else
        return false
        #endif
    }
}

/** The plan of the key in the app: its term, who renews it, the App Store purchase, and the account behind the key. */
struct PlanSheet: View {
    private struct CodeRequest: Identifiable {
        var email: String
        var id: String { email }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var linkingEmail = false
    @State private var working = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var deleteCode: CodeRequest?
    @State private var deleteInBot = false

    private var account: AppAccount? { model.offer?.account }

    var body: some View {
        NavigationView {
            List {
                planSection
                #if PURCHASES
                if let offer = model.offer, offer.canBuy, !offer.products.isEmpty {
                    PlansSection(shop: model.shop, products: offer.products, onBought: {})
                }
                if account?.payment == "appstore" {
                    Section(footer: Text("Отменить подписку или сменить тариф можно в App Store.")) {
                        Button("Управлять подпиской") { Task { await Shop.manage() } }
                    }
                }
                Section {
                    RestoreButton(shop: model.shop, onRestored: {})
                }
                #endif
                if let account {
                    if account.own {
                        accountSection(account)
                        Section {
                            Button("Удалить аккаунт", role: .destructive) { startDelete() }
                                .disabled(working)
                        }
                    } else {
                        Section {
                            Text("Этот ключ выдан не FurkVPN: его тарифом управляет тот, кто выдал ключ.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Тариф")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.confirmationAction) { Button("Закрыть") { dismiss() } }
        }
        .sheetGlass()
        .task { await model.refreshOffer(force: true) }
        .sheet(isPresented: $linkingEmail) { LinkEmailSheet().environmentObject(model) }
        .sheet(item: $deleteCode) { request in
            DeleteCodeSheet(email: request.email, appStore: account?.payment == "appstore").environmentObject(model)
        }
        .confirmationDialog("Удалить аккаунт?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить аккаунт", role: .destructive) { delete() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(DeleteText.warning(appStore: account?.payment == "appstore"))
        }
        .alert("Аккаунт привязан к Telegram", isPresented: $deleteInBot) {
            if let support = model.config.support.first {
                Button("Написать в поддержку") { openLink(support.url) }
            }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text("Такой аккаунт удаляет поддержка: напишите нам с этого Telegram-аккаунта.")
        }
        .alert("Не получилось", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .keyAlerts()
        .toast($model.toast)
    }

    private var planSection: some View {
        let plan = PlanSummary(model)
        return Section(footer: Text(paymentNote)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title).font(.headline)
                if let details = plan.details {
                    Text(details)
                        .font(.subheadline)
                        .foregroundColor(plan.expired ? .red : .secondary)
                        .wraps()
                }
            }
            if let payment = paymentLine {
                HStack {
                    Text("Оплата")
                    Spacer()
                    Text(payment).foregroundColor(.secondary)
                }
            }
        }
    }

    /** Who renews the plan. Nothing is said about where else it can be paid for. */
    private var paymentLine: String? {
        switch account?.payment {
        case "appstore": return "App Store"
        case "card": return "Банковская карта"
        case "balance": return "Баланс аккаунта"
        case "none": return account?.plan?.paid == true && (account?.plan?.expire ?? 0) > 0 ? "Автопродление выключено" : nil
        default: return nil
        }
    }

    private var paymentNote: String {
        guard let store = account?.appstore else { return "" }
        let date = Format.date(store.expiresAt)
        let note = store.autoRenew ? "Подписка App Store продлится \(date)." : "Автопродление в App Store выключено: тариф действует до \(date)."
        return store.sandbox ? note + " Это тестовая покупка, деньги не списаны." : note
    }

    private func accountSection(_ account: AppAccount) -> some View {
        let lonely = "Сейчас к аккаунту ведёт только ключ в этом приложении. Привяжите почту, Apple или Telegram: так вы войдёте на другом устройстве и не потеряете подписку, если удалите приложение."
        return Section(header: Text("Аккаунт"), footer: Text(account.anonymous == true ? lonely : "")) {
            if let email = account.email {
                linked("Почта", email)
            } else {
                Button("Привязать почту") { linkingEmail = true }
            }
            if account.telegram == true {
                linked("Telegram", "привязан")
            } else {
                Button("Привязать Telegram") { linkTelegram() }
                    .disabled(working)
            }
            if account.apple == true {
                linked("Apple", "привязан")
            } else {
                AppleSignInButton(linking: true) { linkApple() }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    private func linked(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await work()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
            }
        }
    }

    private func linkTelegram() {
        guard let key = model.subscription?.url else { return }
        // The bot binds the account when the link is opened; the next look at the sheet shows it.
        run {
            let url = try await AppApi.telegramLink(key: key)
            openLink(url)
        }
    }

    private func linkApple() {
        guard let key = model.subscription?.url else { return }
        run {
            guard let credential = try await AppleSignIn.run() else { return }
            let answer = try await AppApi.signInWithApple(identityToken: credential.identityToken, authorizationCode: credential.authorizationCode,
                                                          challenge: credential.challenge, key: key)
            model.signedIn(answer.key)
        }
    }

    private func startDelete() {
        guard let key = model.subscription?.url else { return }
        run {
            let request = try await AppApi.requestDeletion(key: key)
            switch request.confirm {
            case "code": deleteCode = CodeRequest(email: request.email ?? "")
            case "bot": deleteInBot = true
            default: confirmDelete = true
            }
        }
    }

    private func delete() {
        guard let key = model.subscription?.url else { return }
        run {
            _ = try await AppApi.deleteAccount(key: key, code: nil)
            model.accountDeleted()
        }
    }
}

private enum DeleteText {
    static func warning(appStore: Bool) -> String {
        let base = "Ключ перестанет работать, тариф и данные аккаунта будут удалены. Вернуть их будет нельзя."
        return appStore ? base + " Подписка App Store сама не отменится: отмените её в App Store, иначе Apple продолжит списывать оплату." : base
    }
}

/** Links an email to an account that has none: the address, then the code sent to it. */
private struct LinkEmailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Пришлём код на эту почту. По ней вы сможете войти в аккаунт на другом устройстве.")) {
                    EmailCodeFields(confirmTitle: "Привязать", send: { email in
                        guard let key = model.subscription?.url else { return }
                        try await AppApi.sendLinkCode(key: key, email: email)
                    }, confirm: { email, code in
                        guard let key = model.subscription?.url else { return }
                        try await AppApi.linkEmail(key: key, email: email, code: code)
                        await model.refreshOffer(force: true)
                        model.show("Почта привязана")
                        dismiss()
                    })
                }
            }
            .navigationTitle("Привязать почту")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Отмена") { dismiss() } }
        }
        .sheetGlass()
    }
}

/** Deleting an account that has an email: the code sent to it confirms that the owner asks. */
private struct DeleteCodeSheet: View {
    var email: String
    var appStore: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Код из письма"), footer: Text("Мы отправили код на \(email). " + DeleteText.warning(appStore: appStore))) {
                    TextField("Код", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if let error {
                        Text(error).font(.subheadline).foregroundColor(.red).wraps()
                    }
                }
                Section {
                    Button("Удалить аккаунт", role: .destructive) { delete() }
                        .disabled(working || code.trimmingCharacters(in: .whitespaces).count < 6)
                }
            }
            .navigationTitle("Удаление аккаунта")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Отмена") { dismiss() } }
        }
        .sheetGlass()
    }

    private func delete() {
        guard let key = model.subscription?.url else { return }
        working = true
        error = nil
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await AppApi.deleteAccount(key: key, code: code.trimmingCharacters(in: .whitespaces))
                dismiss()
                model.accountDeleted()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
            }
        }
    }
}

#if PURCHASES
/** The plans on sale, each with its price and a button; under them what the App Store wants said about a subscription. */
struct PlansSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shop: Shop
    var products: [AppProduct]
    /** A purchase went through: the sheet that showed the plans may close. */
    var onBought: () -> Void
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        Section(header: Text("Купить в App Store"), footer: terms) {
            ForEach(products) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.headline)
                    ForEach(item.features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let product = shop.products[item.productId] {
                        Button { buy(product) } label: {
                            Text("Купить · \(product.priceLine)")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButtonStyle(prominent: true)
                        .disabled(shop.busy)
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            if shop.loading || shop.busy {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(shop.busy ? "Оформляем…" : "Загружаем цены…").foregroundColor(.secondary)
                }
            } else if products.allSatisfy({ shop.products[$0.productId] == nil }) {
                Text("Тарифы пока недоступны в App Store. Попробуйте позже.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let note {
                Text(note).font(.subheadline).wraps()
            }
            if let error {
                Text(error).font(.subheadline).foregroundColor(.red).wraps()
            }
        }
        // Every time the plans come on screen, see Shop.load.
        .task { await shop.load(products.map(\.productId)) }
    }

    private var terms: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Подписка на месяц. Она продлевается автоматически по той же цене, пока вы её не отмените. Отменить можно в настройках App Store не позже чем за сутки до конца оплаченного периода. Оплата списывается с вашего Apple ID.")
            HStack(spacing: 16) {
                Button("Пользовательское соглашение") { openLink(model.config.site.termsUrl) }
                Button("Политика конфиденциальности") { openLink(model.config.site.privacyUrl) }
            }
            .font(.footnote)
        }
    }

    private func buy(_ product: Product) {
        error = nil
        note = nil
        Task { @MainActor in
            do {
                switch try await shop.buy(product) {
                case let .bought(answer):
                    guard answer.status == "active" else {
                        error = "App Store принял оплату, но подписка не включилась. Нажмите «Восстановить покупки» или напишите в поддержку."
                        return
                    }
                    onBought()
                    model.show("Подписка оформлена")
                    model.purchaseArrived(answer)
                case .pending:
                    note = "Покупка ждёт подтверждения. Тариф включится сам, когда её одобрят."
                case .cancelled:
                    break
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
            }
        }
    }
}

/** «Восстановить покупки»: finds this Apple ID's subscription and the account it belongs to. */
struct RestoreButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shop: Shop
    var onRestored: () -> Void
    @State private var result: String?

    var body: some View {
        Button {
            restore()
        } label: {
            HStack {
                Text("Восстановить покупки")
                Spacer()
                if shop.busy { ProgressView() }
            }
        }
        .disabled(shop.busy)
        if let result {
            Text(result).font(.subheadline).foregroundColor(.secondary).wraps()
        }
    }

    private func restore() {
        result = nil
        Task { @MainActor in
            do {
                if let answer = try await shop.restore(), answer.status == "active", answer.key != nil {
                    onRestored()
                    model.show("Покупка восстановлена")
                    model.purchaseArrived(answer)
                } else {
                    result = "Действующих покупок на этом Apple ID нет."
                }
            } catch {
                result = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
            }
        }
    }
}

/** «Оформить подписку» of the welcome screen: a plan bought without a key. The server makes an account for it. */
struct SubscribeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var products: [AppProduct]?
    @State private var failed = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Выберите тариф. После оплаты приложение само получит ключ и подключит серверы — аккаунт заводить не нужно.")
                        .font(.subheadline)
                        .wraps()
                }
                if let products {
                    PlansSection(shop: model.shop, products: products, onBought: { dismiss() })
                } else if failed {
                    Section {
                        Text("Не удалось загрузить тарифы. Проверьте интернет.").foregroundColor(.secondary)
                        Button("Повторить") { load() }
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Загружаем тарифы…").foregroundColor(.secondary)
                        }
                    }
                }
                Section(footer: Text("Если вы уже покупали подписку с этим Apple ID, приложение найдёт её и вернёт доступ.")) {
                    RestoreButton(shop: model.shop, onRestored: { dismiss() })
                }
            }
            .navigationTitle("Оформить подписку")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Закрыть") { dismiss() } }
        }
        .sheetGlass()
        .task { load() }
        .keyAlerts()
        .toast($model.toast)
    }

    private func load() {
        failed = false
        Task { @MainActor in
            if let offer = try? await AppApi.offer(key: nil) {
                products = offer.products
            } else {
                failed = true
            }
        }
    }
}
#endif
