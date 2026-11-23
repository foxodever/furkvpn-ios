import SwiftUI

/**
 * The consent to the processing of data, asked for on the first start before anything is sent anywhere (and
 * again when the text says more: Store.consentCurrent). The App Store's rule 5.4 for VPN apps: what is
 * collected and what for, on a screen of the app before the service is used. A card over the screen: the short
 * version, «Подробнее» unfolds the rest (scrolled inside the card, so it never takes the whole screen), then
 * «Согласиться» or «Отказаться». Declined: ConsentDeclinedView instead of the app until the user changes their
 * mind. What it says must match furkvpn.info/privacy.
 */
enum ConsentText {
    static let title = "Мы обрабатываем ваши данные"
    static let summary = "Чтобы VPN работал, мы обрабатываем ключ подписки, данные устройства, IP-адрес и объём трафика, а если вы входите по почте или покупаете тариф в приложении — почту и сведения о покупке. Историю сайтов не храним, данные никому не передаём."

    struct Item: Hashable {
        var title: String
        var text: String
    }

    static let details = [
        Item(title: "Ключ подписки",
             text: "Чтобы загрузить серверы и показать тариф, срок и остаток трафика."),
        Item(title: "Устройство",
             text: "Случайный номер, который создаёт приложение, модель и версия системы — для лимита устройств в подписке. Устройство удаляется из подписки, если с него 60 дней не обновляли подписку."),
        Item(title: "IP-адрес и трафик",
             text: "Серверы видят ваш IP-адрес, пока вы подключены, и считают объём трафика для лимита тарифа."),
        Item(title: "Почта и вход через Apple",
             text: "Если вы входите по почте или через Apple, мы храним адрес почты (или адрес-пересылку Apple) и номер вашего входа через Apple — чтобы узнать ваш аккаунт. Пароль и другие данные Apple ID нам не передаются."),
        Item(title: "Покупки в App Store",
             text: "Если вы покупаете тариф в приложении, Apple сообщает нам номер подписки, тариф и срок. Данные карты и ваш Apple ID мы не получаем."),
        Item(title: "Проверка устройства",
             text: "Перед отправкой письма с кодом приложение подтверждает через Apple (App Attest), что запрос идёт с настоящего устройства. Данных о вас при этом не передаётся."),
        Item(title: "Журналы",
             text: "Журналы подключений не ведём и историю сайтов не храним. Исключение — серверы в Германии: журнал подключений до 7 дней, чтобы отвечать на жалобы хостинга. Если через VPN качают торренты, сервер сообщает об этом, такой отчёт хранится 30 дней."),
        Item(title: "Третьи лица",
             text: "Рекламы и трекеров в приложении нет. Данные не продаём и не передаём третьим лицам. Удалить аккаунт с данными можно в приложении (карточка тарифа → «Удалить аккаунт») или по запросу в поддержку."),
    ]
}

struct ConsentCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(ConsentText.title)
                    .font(.title3.weight(.semibold))
                    .wraps()
            }
            Text(ConsentText.summary)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .wraps()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { details.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(details ? "Скрыть" : "Подробнее")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(details ? 180 : 0))
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            if details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ConsentText.details, id: \.self) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.footnote.weight(.semibold))
                                Text(item.text).font(.footnote).foregroundColor(.secondary).wraps()
                            }
                        }
                        Button("Политика конфиденциальности") { openLink(model.config.site.privacyUrl) }
                            .font(.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .transition(.opacity)
            }
            HStack(spacing: 10) {
                Button { model.declineConsent() } label: {
                    Text("Отказаться").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                Button { model.acceptConsent() } label: {
                    Text("Согласиться").frame(maxWidth: .infinity)
                }
                .glassButtonStyle(prominent: true)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 440)
        .cardSurface(RoundedRectangle(cornerRadius: 28, style: .continuous), color: .card)
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/** Instead of the app while the consent is declined: nothing is sent and the VPN doesn't connect. */
struct ConsentDeclinedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96)
                    .foregroundColor(.primary)
                Text("Без согласия VPN не работает")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Text("Эти данные нужны, чтобы загрузить серверы по ключу и подключиться к ним. Пока согласия нет, FurkVPN ничего никуда не отправляет.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .wraps()
                Button { model.reviewConsent() } label: {
                    Text("Посмотреть ещё раз").padding(.horizontal, 8)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
    }
}
