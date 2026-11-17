import AuthenticationServices
import UIKit

@MainActor
final class AppleSignInProvider: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var controller: ASAuthorizationController?
    private var presentationWindow: UIWindow?

    func identityToken(for challenge: GatewayAuthChallenge) async throws -> String {
        try Task.checkCancellation()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { throw GatewayAuthError.unavailable }
        presentationWindow = window
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.nonce = challenge.nonce
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            finish(.failure(GatewayAuthError.invalidIdentity)); return
        }
        finish(.success(token))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Set before performRequests and retained until this provider is released.
        return presentationWindow!
    }
    private func finish(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}
