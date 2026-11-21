import CoreImage.CIFilterBuiltins
import SwiftUI

/**
 * Welcome screen on Apple TV: treated as an extension of the mobile FurkVPN app (pair via phone QR code,
 * or type/paste a key manually via Apple TV Keyboard). No external website or Telegram links.
 */
struct TVOnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPairing = false
    @State private var showManual = false
    @State private var pendingManualKey: String?
    @FocusState private var defaultFocus: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TVBrandBackdrop()
                HStack(spacing: 96) {
                    VStack(alignment: .leading, spacing: 24) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 80)
                            .foregroundStyle(.primary)
                        Text("Добро пожаловать")
                            .font(.title.weight(.bold))
                            .padding(.top, 16)
                        Text("Подключите Apple TV к вашей подписке FurkVPN из мобильного приложения.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .wraps()
                        VStack(alignment: .leading, spacing: 18) {
                            feature("bolt.shield.fill", "Те же серверы и пинг, что на телефоне")
                            feature("list.bullet.rectangle.fill", "Белые списки и свои правила маршрутизации")
                            feature("arrow.triangle.2.circlepath", "Подписка обновляется сама")
                        }
                        .padding(.top, 18)
                    }
                    .frame(maxWidth: 720, alignment: .leading)

                    VStack(spacing: 24) {
                        HStack(spacing: 20) {
                            TVIconBadge(systemImage: "iphone.gen3", size: 72)
                            Text("Подключение")
                                .font(.title3.weight(.bold))
                            Spacer()
                        }
                        .padding(.bottom, 4)
                        if model.importing {
                            ProgressView("Загружаем подписку…")
                                .font(.callout)
                                .padding(.vertical, 16)
                        }
                        Button {
                            showPairing = true
                        } label: {
                            Label("Подключить через телефон", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TVActionButtonStyle(prominent: true))
                        .focused($defaultFocus)
                        .disabled(model.importing)

                        Text("Откройте FurkVPN на телефоне → Настройки → «Подключить телевизор» и отсканируйте QR-код")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .wraps()

                        HStack(spacing: 18) {
                            Capsule().fill(Color.primary.opacity(0.12)).frame(height: 2)
                            Text("или")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Capsule().fill(Color.primary.opacity(0.12)).frame(height: 2)
                        }
                        .padding(.vertical, 4)

                        Button {
                            pendingManualKey = nil
                            showManual = true
                        } label: {
                            Label("Ввести ключ вручную", systemImage: "keyboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TVActionButtonStyle())
                        .disabled(model.importing)
                    }
                    .tvCard(.card, padding: 48, cornerRadius: 44)
                    .frame(maxWidth: 700)
                }
                .padding(.horizontal, TVMetrics.sideMargin + 20)
                .padding(.vertical, 60)
            }
            .onAppear { defaultFocus = true }
            .navigationDestination(isPresented: $showPairing) {
                TVPairingView(title: "Подключить телевизор") {
                    showPairing = false
                }
            }
            .sheet(isPresented: $showManual, onDismiss: submitPendingManualKey) {
                TVManualKeyView { key in
                    pendingManualKey = key
                }
            }
        }
    }

    private func submitPendingManualKey() {
        guard let key = pendingManualKey else { return }
        pendingManualKey = nil
        model.submitKey(key)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 20) {
            TVIconBadge(systemImage: icon, size: 56)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .wraps()
        }
    }
}

/**
 * QR code pairing flow with the FurkVPN mobile app (/api/v1/tv/session & /api/v1/tv/wait).
 * Used both on onboarding and from Settings → «Сменить ключ по QR-коду».
 */
struct TVPairingView: View {
    private struct Session: Decodable {
        let code: String
        let token: String
        let url: String
    }

    private struct Reply: Decodable {
        let status: String?
        let key: String?
    }

    private enum PairingError: LocalizedError {
        case expired

        var errorDescription: String? {
            "Срок действия кода истёк. Запросите новый QR-код."
        }
    }

    var title: String
    var onPaired: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var qrCode: CGImage?
    @State private var pairCode: String?
    @State private var errorMessage: String?
    @State private var importing = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            TVBrandBackdrop()
            HStack(spacing: 84) {
                VStack(alignment: .leading, spacing: 28) {
                    Text(title)
                        .font(.title2.weight(.bold))

                    VStack(alignment: .leading, spacing: 20) {
                        stepRow(1, "Откройте FurkVPN на телефоне")
                        stepRow(2, "Перейдите в Настройки → «Подключить телевизор»")
                        stepRow(3, "Наведите камеру на QR-код и подтвердите код")
                    }

                    if let pairCode, errorMessage == nil {
                        HStack(spacing: 22) {
                            Text("Код телевизора")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Text(Format.tvCode(pairCode))
                                .font(.title3.monospaced().weight(.bold))
                                .tracking(4)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .tvCardSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), color: .cardHigh)
                    }

                    statusLine

                    TVGlassGroup(spacing: 8) {
                        HStack(spacing: 20) {
                            Button {
                                attempt += 1
                            } label: {
                                Label(errorMessage == nil ? "Новый QR-код" : "Получить новый код", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(TVActionButtonStyle(prominent: errorMessage != nil))
                            .disabled(importing)

                            Button("Назад") { dismiss() }
                                .buttonStyle(TVActionButtonStyle())
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 780, alignment: .leading)

                qrPanel
            }
            .padding(.horizontal, TVMetrics.sideMargin + 20)
            .padding(.vertical, 60)
        }
        .task(id: attempt) { await pair() }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .wraps()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .wraps()
            }
            .padding(20)
            .tvCardSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), color: .card)
        } else if importing {
            HStack(spacing: 16) {
                ProgressView()
                Text("Ключ получен. Загружаем серверы…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if qrCode != nil {
            HStack(spacing: 16) {
                ProgressView()
                Text("Ожидаем ключ с телефона…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(qrCode != nil && errorMessage == nil ? Color.white : Color.card)
                .frame(width: 440, height: 440)
                .padding(18)
                .tvGlassSurface(RoundedRectangle(cornerRadius: 50, style: .continuous), fallback: .cardHigh)
                .shadow(color: .black.opacity(0.24), radius: 30, y: 14)

            if errorMessage != nil {
                Image(systemName: "qrcode")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(.secondary)
            } else if importing {
                ProgressView()
                    .scaleEffect(1.6)
            } else if let qrCode {
                Image(qrCode, scale: 1, label: Text("QR-код для подключения телевизора"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 376, height: 376)
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Получаем QR-код…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pair() async {
        errorMessage = nil
        qrCode = nil
        pairCode = nil
        importing = false
        do {
            let session = try await request(Session.self, "session", body: [:])
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(session.url.utf8)
            guard let image = filter.outputImage,
                  let qr = CIContext().createCGImage(image, from: image.extent) else {
                throw URLError(.cannotDecodeContentData)
            }
            qrCode = qr
            pairCode = session.code
            while !Task.isCancelled {
                let reply = try await request(Reply.self, "wait", body: ["code": session.code, "token": session.token])
                if reply.status == "ready", let key = reply.key, !key.isEmpty {
                    importing = true
                    try await model.importPairedKey(key)
                    guard !Task.isCancelled else { return }
                    onPaired()
                    return
                }
                if reply.status == "expired" || reply.status == "not_found" {
                    throw PairingError.expired
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            guard !Task.isCancelled else { return }
            importing = false
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                errorMessage = description
            } else {
                errorMessage = "Не удалось получить ключ. Проверьте интернет и запросите новый QR-код."
            }
        }
    }

    private func request<T: Decodable>(_ type: T.Type, _ endpoint: String, body: [String: String]) async throws -> T {
        let url = URL(string: Http.apiBase + "/api/v1/tv/" + endpoint)!
        return try JSONDecoder().decode(type, from: await Http.postJSON(url, body: body))
    }
}

/** Manual subscription URL input (works with iPhone Apple TV Remote keyboard for quick pasting). */
struct TVManualKeyView: View {
    var onAdd: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVBrandBackdrop()
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 22) {
                        TVIconBadge(systemImage: "keyboard", size: 72)
                        Text("Введите ключ FurkVPN")
                            .font(.title2.weight(.bold))
                    }
                    Text("Удобно вставить ссылку с iPhone через уведомление клавиатуры Apple TV.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .wraps()
                    TextField("https://sub.furkvpn.com/…", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onSubmit {
                            if canSubmit { submit() }
                        }
                    HStack(spacing: 24) {
                        Spacer()
                        Button("Отмена") { dismiss() }
                            .buttonStyle(TVActionButtonStyle())
                        Button("Добавить") { submit() }
                            .buttonStyle(TVActionButtonStyle(prominent: true))
                            .disabled(!canSubmit)
                    }
                    .padding(.top, 8)
                }
                .tvCard(.card, padding: 52, cornerRadius: 40)
                .frame(maxWidth: 1020)
                .padding(80)
            }
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onAdd(value)
        dismiss()
    }
}
