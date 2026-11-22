import CoreImage.CIFilterBuiltins
import SwiftUI

/**
 * QR code pairing flow with the FurkVPN mobile app (/api/v1/tv/session & /api/v1/tv/wait).
 * Used both from OnboardingView and from SettingsView → «Сменить ключ по QR-коду» on Apple TV.
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
            BrandBackdrop()
            HStack(spacing: WideLayout.gap) {
                VStack(alignment: .leading, spacing: 26) {
                    Text(title)
                        .font(.title2.weight(.bold))

                    VStack(alignment: .leading, spacing: 18) {
                        stepRow(1, "Откройте FurkVPN на телефоне")
                        stepRow(2, "Перейдите в Настройки → «Подключить телевизор»")
                        stepRow(3, "Наведите камеру на QR-код и подтвердите код")
                    }

                    if let pairCode, errorMessage == nil {
                        HStack(spacing: 20) {
                            Text("Код телевизора")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundColor(.secondary)
                            Text(Format.tvCode(pairCode))
                                .font(.title3.monospaced().weight(.bold))
                                .tracking(4)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 16)
                        .cardSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), color: .cardHigh)
                    }

                    statusLine

                    GlassGroup(spacing: 12) {
                        HStack(spacing: 18) {
                            Button {
                                attempt += 1
                            } label: {
                                Label(errorMessage == nil ? "Новый QR-код" : "Получить новый код", systemImage: "arrow.clockwise")
                            }
                            .glassButtonStyle(prominent: errorMessage != nil)
                            .disabled(importing)

                            Button("Назад") { dismiss() }
                                .glassButtonStyle()
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                qrPanel
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: WideLayout.maxWidth)
        }
        .task(id: attempt) { await pair() }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.onAccent)
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
                .wraps()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .wraps()
            }
            .card()
        } else if importing {
            HStack(spacing: 16) {
                ProgressView()
                Text("Ключ получен. Загружаем серверы…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        } else if qrCode != nil {
            HStack(spacing: 16) {
                ProgressView()
                Text("Ожидаем ключ с телефона…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(qrCode != nil && errorMessage == nil ? Color.white : Color.card)
                .frame(width: 440, height: 440)
                .padding(18)
                .glassSurface(RoundedRectangle(cornerRadius: 48, style: .continuous), fallback: .cardHigh)
                .shadow(color: .black.opacity(0.24), radius: 28, y: 12)

            if errorMessage != nil {
                Image(systemName: "qrcode")
                    .font(.system(size: 120, weight: .light))
                    .foregroundColor(.secondary)
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
                        .foregroundColor(.secondary)
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
