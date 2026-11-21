import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct FurkTVApp: App {
    var body: some Scene {
        WindowGroup { TVHomeView() }
    }
}

private struct TVHomeView: View {
    @AppStorage("consentVersion", store: Store.defaults) private var consentVersion = 0
    @StateObject private var vpn = VPNController()
    @State private var subscription = Store.loadSubscription()
    @State private var selected = Store.selectedServer
    @State private var pairing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 34) {
                Text("FurkVPN").font(.largeTitle.bold())
                if consentVersion < Store.consentCurrent {
                    Text(ConsentText.title).font(.headline)
                    Text(ConsentText.summary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 980)
                    Button("Согласиться") { consentVersion = Store.consentCurrent }
                } else if let subscription {
                    Text(status).font(.title2)
                    Button(vpn.isActive ? "Отключить" : "Подключить") {
                        message = nil
                        Task {
                            await vpn.loaded()
                            await vpn.toggle()
                        }
                    }
                    .disabled(vpn.state == .connecting || vpn.state == .stopping)
                    NavigationLink {
                        List(subscription.selectable) { server in
                            Button {
                                Store.selectedServer = server.key
                                selected = server.key
                                if vpn.isActive { Task { await vpn.reload() } }
                            } label: {
                                HStack {
                                    Text(server.displayName)
                                    Spacer()
                                    if server.key == (selected ?? subscription.selectable.first?.key) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        .navigationTitle("Серверы")
                    } label: {
                        Label(subscription.selectable.first { $0.key == selected }?.displayName
                              ?? subscription.selectable.first?.displayName ?? "Серверы",
                              systemImage: "server.rack")
                    }
                    Button("Сменить ключ") { pairing = true }
                        .disabled(vpn.state != .idle)
                    if let message { Text(message).font(.callout) }
                } else {
                    Button("Добавить ключ") { pairing = true }
                }
            }
            .padding(60)
            .task { vpn.onError = { message = $0 } }
            .navigationDestination(isPresented: $pairing) {
                TVPairingView { info in
                    subscription = info
                    selected = Store.selectedServer
                    message = nil
                    pairing = false
                }
            }
        }
    }

    private var status: String {
        switch vpn.state {
        case .idle: return "VPN отключён"
        case .connecting: return "Подключение…"
        case .connected: return "VPN подключён"
        case .stopping: return "Отключение…"
        }
    }
}

private struct TVPairingView: View {
    private struct Session: Decodable {
        let code: String
        let token: String
        let url: String
    }

    private struct Reply: Decodable {
        let status: String?
        let key: String?
    }

    let paired: (SubscriptionInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var qrCode: CGImage?
    @State private var errorMessage: String?
    @State private var importing = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 32) {
            Text("Добавить ключ").font(.largeTitle.bold())
            if let errorMessage {
                Text(errorMessage)
                Button("Получить новый код") { attempt += 1 }
            } else if importing {
                ProgressView("Ключ получен. Загружаем серверы…")
            } else if let qrCode {
                Text("Отсканируйте QR-код")
                Image(qrCode, scale: 1, label: Text("QR-код для подключения телевизора"))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
                    .padding(22)
                    .background(.white)
                Text("Ожидаем ключ").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView("Получаем QR-код…")
            }
            Button("Назад") { dismiss() }
        }
        .padding(60)
        .task(id: attempt) { await pair() }
    }

    private func pair() async {
        errorMessage = nil
        qrCode = nil
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
            while !Task.isCancelled {
                let reply = try await request(Reply.self, "wait", body: ["code": session.code, "token": session.token])
                if reply.status == "ready", let key = reply.key, !key.isEmpty {
                    importing = true
                    let config = await remoteConfig()
                    guard case let .ok(parsed) = Core.parseKey(key, allowedHosts: config.allowedSubscriptionHosts) else {
                        throw SubscriptionError.foreign
                    }
                    let result = try await SubscriptionLoader.download(parsed, config: config)
                    try Task.checkCancellation()
                    let info = SubscriptionLoader.info(for: parsed, result)
                    guard Store.saveSubscription(info, configs: result.configs) else {
                        throw URLError(.cannotWriteToFile)
                    }
                    Store.saveRemoteConfig(config)
                    Store.whitelistDetect = false
                    Store.selectedServer = info.selectable.first?.key
                    paired(info)
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            guard !Task.isCancelled else { return }
            if let error = error as? SubscriptionError {
                errorMessage = error.localizedDescription
            } else if (error as? URLError)?.code == .cannotWriteToFile {
                errorMessage = "Apple TV не удалось сохранить серверы. Попробуйте снова."
            } else {
                errorMessage = "Не удалось получить ключ. Запросите новый QR-код."
            }
        }
    }

    private func request<T: Decodable>(_ type: T.Type, _ endpoint: String, body: [String: String]) async throws -> T {
        let url = URL(string: Http.apiBase + "/api/v1/tv/" + endpoint)!
        return try JSONDecoder().decode(type, from: await Http.postJSON(url, body: body))
    }

    private func remoteConfig() async -> RemoteConfig {
        let url = URL(string: Http.apiBase + "/api/v1/config")!
        if let (data, response) = try? await Http.get(url), (200..<300).contains(response.statusCode),
           let config = try? JSONDecoder().decode(RemoteConfig.self, from: data) {
            return config.sanitized()
        }
        return Store.loadRemoteConfig() ?? RemoteConfig()
    }
}
