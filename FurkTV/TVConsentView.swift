import SwiftUI

/**
 * Data processing consent on Apple TV (App Store rule 5.4, matching FurkVPN/Views/ConsentView.swift):
 * shown at the root level before anything is sent anywhere, with no external links to open.
 */
struct TVConsentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDetails = false
    @FocusState private var defaultFocus: Bool

    var body: some View {
        ZStack {
            TVBrandBackdrop()
            VStack(spacing: 40) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 52)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 24) {
                        TVIconBadge(systemImage: "hand.raised.fill", size: 84)
                        Text(ConsentText.title)
                            .font(.title3.weight(.bold))
                            .wraps()
                    }
                    Text(ConsentText.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .wraps()

                    HStack(spacing: 24) {
                        Button {
                            showDetails = true
                        } label: {
                            Label("Подробнее", systemImage: "info.circle")
                        }
                        .buttonStyle(TVActionButtonStyle())

                        Spacer()

                        TVGlassGroup(spacing: 8) {
                            HStack(spacing: 24) {
                                Button {
                                    model.declineConsent()
                                } label: {
                                    Text("Отказаться")
                                        .frame(minWidth: 200)
                                }
                                .buttonStyle(TVActionButtonStyle())

                                Button {
                                    model.acceptConsent()
                                } label: {
                                    Text("Согласиться")
                                        .frame(minWidth: 240)
                                }
                                .buttonStyle(TVActionButtonStyle(prominent: true))
                                .focused($defaultFocus)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .tvCard(.card, padding: 52, cornerRadius: 44)
                .frame(maxWidth: 1240)
            }
            .padding(.horizontal, TVMetrics.sideMargin)
            .padding(.vertical, 60)
        }
        .onAppear { defaultFocus = true }
        .sheet(isPresented: $showDetails) {
            TVConsentDetailsSheet()
        }
    }
}

/** Full consent details in a remote-scrollable list; no external privacy link on Apple TV. */
private struct TVConsentDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSidePanelScreen(
            systemImage: "hand.raised.fill",
            title: "Обработка данных",
            subtitle: "Какие данные нужны FurkVPN и зачем"
        ) {
            List {
                ForEach(ConsentText.details, id: \.self) { item in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(item.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .wraps()
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

/** Shown instead of the app while consent is declined. */
struct TVConsentDeclinedView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var defaultFocus: Bool

    var body: some View {
        ZStack {
            TVBrandBackdrop()
            VStack(spacing: 28) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 56)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 8)
                TVIconBadge(systemImage: "hand.raised.slash.fill", size: 120)
                Text("Без согласия VPN не работает")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                Text("Эти данные нужны, чтобы загрузить серверы по ключу и подключиться к ним. Пока согласия нет, FurkVPN ничего никуда не отправляет.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .wraps()
                    .frame(maxWidth: 920)
                Button {
                    model.reviewConsent()
                } label: {
                    Text("Посмотреть ещё раз")
                        .padding(.horizontal, 16)
                }
                .buttonStyle(TVActionButtonStyle(prominent: true))
                .focused($defaultFocus)
                .padding(.top, 12)
            }
            .padding(80)
        }
        .onAppear { defaultFocus = true }
    }
}
