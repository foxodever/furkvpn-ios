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
    static let summary = "Чтобы VPN работал, мы обрабатываем ключ подписки, данные устройства, IP-адрес и объём трафика. Историю сайтов не храним, данные никому не передаём."

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
        Item(title: "Журналы",
             text: "Журналы подключений не ведём и историю сайтов не храним. Исключение — серверы в Германии: журнал подключений до 7 дней, чтобы отвечать на жалобы хостинга. Если через VPN качают торренты, сервер сообщает об этом, такой отчёт хранится 30 дней."),
        Item(title: "Третьи лица",
             text: "Рекламы и трекеров в приложении нет. Данные не продаём и не передаём третьим лицам. Удалить их можно по запросу в поддержку."),
    ]
}

struct ConsentCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var details = false
    #if os(tvOS)
    @FocusState private var acceptFocused: Bool
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(titleIconFont)
                    .foregroundColor(.accentColor)
                Text(ConsentText.title)
                    .font(.title3.weight(.semibold))
                    .wraps()
            }
            Text(ConsentText.summary)
                .font(summaryFont)
                .foregroundColor(.secondary)
                .wraps()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { details.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(details ? "Скрыть" : "Подробнее")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(details ? 180 : 0))
                }
                #if !os(tvOS)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.accentColor)
                #endif
            }
            #if os(tvOS)
            .glassButtonStyle()
            #else
            .buttonStyle(.plain)
            #endif
            if details {
                ScrollView {
                    VStack(alignment: .leading, spacing: detailSpacing) {
                        ForEach(ConsentText.details, id: \.self) { item in
                            detailRow(item)
                        }
                        #if !os(tvOS)
                        Button("Политика конфиденциальности") { openLink(model.config.site.privacyUrl) }
                            .font(.footnote.weight(.medium))
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: detailsMaxHeight)
                .transition(.opacity)
            }
            HStack(spacing: actionSpacing) {
                Button { model.declineConsent() } label: {
                    Text("Отказаться").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                let accept = Button { model.acceptConsent() } label: {
                    Text("Согласиться").frame(maxWidth: .infinity)
                }
                .glassButtonStyle(prominent: true)
                #if os(tvOS)
                accept.focused($acceptFocused)
                #else
                accept
                #endif
            }
            .largeControlSize()
            .padding(.top, 4)
        }
        .padding(cardPadding)
        .frame(maxWidth: cardMaxWidth)
        .cardSurface(RoundedRectangle(cornerRadius: cardRadius, style: .continuous), color: .card)
        .padding(outerPadding)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        #if os(tvOS)
        .onAppear { acceptFocused = true }
        #endif
    }

    @ViewBuilder
    private func detailRow(_ item: ConsentText.Item) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(detailTitleFont)
                .foregroundColor(.primary)
            Text(item.text)
                .font(detailBodyFont)
                .foregroundColor(.secondary)
                .wraps()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        Button {} label: {
            content.padding(14)
        }
        .glassInteractiveButton(RoundedRectangle(cornerRadius: 18, style: .continuous), scale: 1.01)
        #else
        content
        #endif
    }

    #if os(tvOS)
    private var spacing: CGFloat { 20 }
    private var detailSpacing: CGFloat { 14 }
    private var actionSpacing: CGFloat { 20 }
    private var cardPadding: CGFloat { 42 }
    private var outerPadding: CGFloat { 48 }
    private var cardMaxWidth: CGFloat { 1120 }
    private var cardRadius: CGFloat { 36 }
    private var detailsMaxHeight: CGFloat { 320 }
    private var titleIconFont: Font { .title2 }
    private var summaryFont: Font { .callout }
    private var detailTitleFont: Font { .callout.weight(.semibold) }
    private var detailBodyFont: Font { .caption }
    #else
    private var spacing: CGFloat { 14 }
    private var detailSpacing: CGFloat { 12 }
    private var actionSpacing: CGFloat { 10 }
    private var cardPadding: CGFloat { 20 }
    private var outerPadding: CGFloat { 20 }
    private var cardMaxWidth: CGFloat { 440 }
    private var cardRadius: CGFloat { 28 }
    private var detailsMaxHeight: CGFloat { 260 }
    private var titleIconFont: Font { .title2 }
    private var summaryFont: Font { .subheadline }
    private var detailTitleFont: Font { .footnote.weight(.semibold) }
    private var detailBodyFont: Font { .footnote }
    #endif
}

/** Instead of the app while the consent is declined: nothing is sent and the VPN doesn't connect. */
struct ConsentDeclinedView: View {
    @EnvironmentObject private var model: AppModel
    #if os(tvOS)
    @FocusState private var reviewFocused: Bool
    #endif

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: stackSpacing) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoWidth)
                    .foregroundColor(.primary)
                Text("Без согласия VPN не работает")
                    .font(headingFont)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Text("Эти данные нужны, чтобы загрузить серверы по ключу и подключиться к ним. Пока согласия нет, FurkVPN ничего никуда не отправляет.")
                    .font(bodyFont)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .wraps()
                let review = Button { model.reviewConsent() } label: {
                    Text("Посмотреть ещё раз").padding(.horizontal, 12)
                }
                .glassButtonStyle(prominent: true)
                .largeControlSize()
                .padding(.top, 8)
                #if os(tvOS)
                review.focused($reviewFocused)
                #else
                review
                #endif
            }
            .padding(outerPadding)
            .frame(maxWidth: maxWidth)
        }
        #if os(tvOS)
        .onAppear { reviewFocused = true }
        #endif
    }

    #if os(tvOS)
    private var stackSpacing: CGFloat { 24 }
    private var logoWidth: CGFloat { 170 }
    private var headingFont: Font { .title2.weight(.semibold) }
    private var bodyFont: Font { .callout }
    private var outerPadding: CGFloat { 60 }
    private var maxWidth: CGFloat { 920 }
    #else
    private var stackSpacing: CGFloat { 16 }
    private var logoWidth: CGFloat { 96 }
    private var headingFont: Font { .title3.weight(.semibold) }
    private var bodyFont: Font { .body }
    private var outerPadding: CGFloat { 24 }
    private var maxWidth: CGFloat { 480 }
    #endif
}
