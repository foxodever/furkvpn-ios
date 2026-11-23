import SwiftUI

/**
 * «Войти через сайт» of the welcome screen: the site's page that adds the key to the app, a code sent by
 * email, or Sign in with Apple. Each one ends with a key, which the app takes like a pasted one.
 */
struct SignInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var appleError: String?
    @State private var appleWorking = false

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Откроется сайт: войдите в аккаунт, и кнопка на странице добавит ключ в приложение.")) {
                    Button {
                        dismiss()
                        openLink(model.config.site.installUrl)
                    } label: {
                        Label("Добавить ключ через сайт", systemImage: "globe")
                    }
                }
                Section(header: Text("Войти по почте"), footer: Text("Пришлём код на почту. Если аккаунта с ней ещё нет, он появится после ввода кода.")) {
                    EmailCodeFields(confirmTitle: "Войти", send: { email in
                        try await AppApi.sendSignInCode(email: email)
                    }, confirm: { email, code in
                        let answer = try await AppApi.signIn(email: email, code: code)
                        dismiss()
                        model.signedIn(answer.key)
                    })
                }
                Section(footer: appleFooter) {
                    AppleSignInButton { apple() }
                        .disabled(appleWorking)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Вход")
            .navigationBarTitleDisplayMode(.inline)
            .barItem(.cancellationAction) { Button("Отмена") { dismiss() } }
        }
        .sheetGlass()
    }

    private var appleFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let appleError {
                Text(appleError).foregroundColor(.red)
            }
            Text("Почту можно скрыть: тогда письма придут через адрес-пересылку Apple.")
        }
    }

    private func apple() {
        appleError = nil
        appleWorking = true
        Task { @MainActor in
            defer { appleWorking = false }
            do {
                guard let credential = try await AppleSignIn.run() else { return }
                let answer = try await AppApi.signInWithApple(identityToken: credential.identityToken, authorizationCode: credential.authorizationCode,
                                                              challenge: credential.challenge, key: nil)
                dismiss()
                model.signedIn(answer.key)
            } catch {
                appleError = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
            }
        }
    }
}

/**
 * Rows of a form: an email, the button that sends a code to it, then the code and what to do with it.
 * [send] and [confirm] throw what the server answered; the text is shown under the rows.
 */
struct EmailCodeFields: View {
    var confirmTitle: String
    var send: @MainActor (String) async throws -> Void
    var confirm: @MainActor (String, String) async throws -> Void
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var error: String?

    private var address: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        TextField("Почта", text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .disabled(sent || working)
        if sent {
            TextField("Код из письма", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            row(confirmTitle, enabled: digits.count == 6) {
                try await confirm(address, digits)
            }
            Button("Другая почта или новый код") {
                sent = false
                code = ""
                error = nil
            }
            .disabled(working)
        } else {
            row("Получить код", enabled: address.contains("@") && address.contains(".")) {
                try await send(address)
                sent = true
            }
        }
        if let error {
            Text(error).font(.subheadline).foregroundColor(.red).wraps()
        }
    }

    private func row(_ title: String, enabled: Bool, _ work: @escaping @MainActor () async throws -> Void) -> some View {
        Button {
            working = true
            error = nil
            Task { @MainActor in
                defer { working = false }
                do {
                    try await work()
                } catch {
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Попробуйте ещё раз."
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if working { ProgressView() }
            }
        }
        .disabled(working || !enabled)
    }
}
