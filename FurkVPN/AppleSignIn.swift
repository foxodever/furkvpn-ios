import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit

/**
 * Sign in with Apple, one request: the system sheet, then Apple's identity token for the server. The
 * server's one-time challenge goes into the request as its nonce (SHA-256, hex), so a token caught on the
 * way can't be sent again.
 */
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential {
        var identityToken: String
        var authorizationCode: String?
        var challenge: String
    }

    private var continuation: CheckedContinuation<Credential?, Error>?
    private var challenge = ""
    /** Keeps the request alive while the system sheet is on screen. */
    private static var running: AppleSignIn?

    /** nil when the person closed the sheet. */
    @MainActor
    static func run() async throws -> Credential? {
        let challenge = try await AppApi.challenge()
        let flow = AppleSignIn()
        flow.challenge = challenge
        running = flow
        defer { running = nil }
        return try await withCheckedThrowingContinuation { continuation in
            flow.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.email]
            request.nonce = SHA256.hash(data: Data(challenge.utf8)).map { String(format: "%02x", $0) }.joined()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = flow
            controller.presentationContextProvider = flow
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credential?, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            finish(.failure(AppApiError(status: 0, code: "NO_TOKEN", info: "Apple не передал данные для входа. Попробуйте ещё раз.")))
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        finish(.success(Credential(identityToken: token, authorizationCode: code, challenge: challenge)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.success(nil))
        } else {
            finish(.failure(AppApiError(status: 0, code: "APPLE_FAILED", info: "Не удалось войти через Apple. Попробуйте ещё раз.")))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

/** Apple's own button, as its guidelines want it: black on a light screen, white on a dark one. */
struct AppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    /** «Продолжить с Apple» for an account that is there already, «Войти с Apple» otherwise. */
    var linking = false
    var action: () -> Void

    var body: some View {
        Representable(dark: colorScheme == .dark, linking: linking, action: action)
            // The button keeps its look for the life of the view: a new one for the other appearance.
            .id(colorScheme)
            .frame(height: 48)
    }

    private struct Representable: UIViewRepresentable {
        var dark: Bool
        var linking: Bool
        var action: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(action: action) }

        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let button = ASAuthorizationAppleIDButton(type: linking ? .continue : .signIn, style: dark ? .white : .black)
            button.cornerRadius = 12
            button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
            return button
        }

        func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) {
            context.coordinator.action = action
        }

        final class Coordinator: NSObject {
            var action: () -> Void

            init(action: @escaping () -> Void) { self.action = action }

            @objc func tapped() { action() }
        }
    }
}
