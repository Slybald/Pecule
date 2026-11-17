import Foundation

// Authentication is deliberately separate from BankGatewayClient: it must never send the
// administrator bearer, and it has to work before any session exists.
protocol GatewayAuthClient: Sendable {
    func scoped(to issuer: URL) -> any GatewayAuthClient
    func startChallenge() async throws -> GatewayAuthChallenge
    func completeSignIn(challengeId: String, identityToken: String) async throws -> GatewayUserSession
    func currentUserID(token: String) async throws -> String
    func signOut(token: String) async throws
}

extension GatewayAuthClient {
    // Stateless test doubles can share their script; live clients must freeze their destination.
    func scoped(to issuer: URL) -> any GatewayAuthClient { self }
}

final class LiveGatewayAuthClient: GatewayAuthClient {
    private let session: URLSession
    private let userAgent: String
    private let baseURLProvider: @Sendable () throws -> URL?

    init(
        session: URLSession = .shared,
        userAgent: String = "Pecule/1.0 (iOS)",
        baseURLProvider: @escaping @Sendable () throws -> URL?
    ) {
        self.session = session
        self.userAgent = userAgent
        self.baseURLProvider = baseURLProvider
    }

    func scoped(to issuer: URL) -> any GatewayAuthClient {
        LiveGatewayAuthClient(session: session, userAgent: userAgent, baseURLProvider: { issuer })
    }

    func startChallenge() async throws -> GatewayAuthChallenge {
        let payload = try await send("POST", "/v1/auth/apple/challenge")
        let body = try decode(ChallengeBody.self, from: payload)
        return GatewayAuthChallenge(
            challengeId: body.challengeId,
            nonce: body.nonce,
            expiresAt: GatewayAuthTimestamp.date(fromMilliseconds: body.expiresAt)
        )
    }

    func completeSignIn(challengeId: String, identityToken: String) async throws -> GatewayUserSession {
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "challengeId": challengeId,
            "identityToken": identityToken,
        ])
        let payload = try await send("POST", "/v1/auth/apple/session", body: requestBody)
        let body = try decode(SessionBody.self, from: payload)
        return GatewayUserSession(
            token: body.token,
            userId: body.userId,
            expiresAt: GatewayAuthTimestamp.date(fromMilliseconds: body.expiresAt)
        )
    }

    func currentUserID(token: String) async throws -> String {
        try decode(IdentityBody.self, from: try await send("GET", "/v1/session", token: token)).userId
    }

    func signOut(token: String) async throws {
        _ = try await send("DELETE", "/v1/session", token: token)
    }

    private struct ChallengeBody: Decodable {
        let challengeId: String
        let nonce: String
        let expiresAt: Double
    }

    private struct SessionBody: Decodable {
        let token: String
        let userId: String
        let expiresAt: Double
    }

    private struct IdentityBody: Decodable {
        let userId: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: String?
        let retryAfterSeconds: Int?
    }

    // `token` is a user session token only. The administrator bearer never reaches these routes.
    private func send(_ method: String, _ path: String, body: Data? = nil, token: String? = nil) async throws -> Data {
        guard let baseURL = try baseURLProvider() else {
            throw GatewayAuthError.notConfigured
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GatewayAuthError.notConfigured
        }
        components.path = components.path.trimmingGatewaySuffix("/") + path
        guard let url = components.url else {
            throw GatewayAuthError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GatewayAuthError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayAuthError.transport("Non-HTTP response")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Self.error(status: httpResponse.statusCode, body: data)
        }
        return data
    }

    static func error(status: Int, body: Data) -> GatewayAuthError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        switch (status, envelope?.error) {
        case (401, "invalid_identity"):
            return .invalidIdentity
        case (401, _):
            return .unauthorized
        case (429, _):
            return .rateLimited(retryAfterSeconds: envelope?.retryAfterSeconds ?? 60)
        case (503, _):
            return .unavailable
        default:
            return .http(status: status, code: envelope?.error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GatewayAuthError.decoding(String(describing: error))
        }
    }
}

private extension String {
    func trimmingGatewaySuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
