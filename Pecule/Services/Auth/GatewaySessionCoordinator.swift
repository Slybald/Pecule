import Foundation

// Owns the current identity and makes sure no response produced for a previous identity is ever applied.
// Every sign-in and sign-out bumps an epoch; work started under an older epoch is cancelled and its
// result discarded rather than handed back to the caller.
@MainActor
final class GatewaySessionCoordinator: ObservableObject {
    enum State: Equatable {
        case signedOut
        case signedIn(userId: String, expiresAt: Date)

        var userId: String? {
            if case .signedIn(let userId, _) = self { return userId }
            return nil
        }
    }

    enum SessionError: Error, Equatable {
        case signedOut
        case expired
        // The identity changed while the request was in flight; the result belongs to nobody.
        case sessionChanged
    }

    @Published private(set) var state: State = .signedOut
    private(set) var epoch: UInt64 = 0

    private let authClient: any GatewayAuthClient
    private let sessionStore: GatewaySessionStore
    private let issuerProvider: @Sendable () throws -> URL?
    private let referenceDateProvider: @Sendable () -> Date
    private var session: GatewayUserSession?
    private var sessionIssuer: URL?
    private var sessionClient: (any GatewayAuthClient)?
    private var cancelHandlers: [UUID: () -> Void] = [:]

    init(
        authClient: any GatewayAuthClient,
        sessionStore: GatewaySessionStore = GatewaySessionStore(),
        issuerProvider: @escaping @Sendable () throws -> URL? = { try BankGatewayConfigurationStore().loadBaseURL() },
        referenceDateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authClient = authClient
        self.sessionStore = sessionStore
        self.issuerProvider = issuerProvider
        self.referenceDateProvider = referenceDateProvider
    }

    var isSignedIn: Bool {
        state != .signedOut
    }

    // Called at launch. An expired stored session is dropped instead of being presented as valid.
    func restore() {
        guard let issuer = try? issuerProvider(),
              let stored = try? sessionStore.load(issuedBy: issuer) else {
            invalidate()
            return
        }
        guard !stored.isExpired(at: referenceDateProvider()) else {
            invalidate()
            return
        }
        adopt(stored, issuer: issuer, client: authClient.scoped(to: issuer))
    }

    // The closure receives the server challenge and must hand `challenge.nonce` to Apple verbatim:
    // the gateway compares the nonce it issued with the one Apple signed, so hashing it would fail.
    @discardableResult
    func signIn(identityToken: @Sendable (GatewayAuthChallenge) async throws -> String) async throws -> String {
        guard let issuer = try issuerProvider() else {
            throw GatewayAuthError.notConfigured
        }
        // Sign-in spans several awaits; if the identity changed meanwhile, the session minted here
        // belongs to nobody. Revoke it server-side instead of letting it live out its hour.
        try Task.checkCancellation()
        let client = authClient.scoped(to: issuer)
        let startEpoch = epoch
        let challenge = try await client.startChallenge()
        try Task.checkCancellation()
        guard !challenge.isExpired(at: referenceDateProvider()) else {
            throw GatewayAuthError.challengeExpired
        }
        let token = try await identityToken(challenge)
        try Task.checkCancellation()
        let session = try await client.completeSignIn(challengeId: challenge.challengeId, identityToken: token)
        do {
            try Task.checkCancellation()
            guard startEpoch == epoch, issuerMatches(issuer) else { throw SessionError.sessionChanged }
            guard !session.isExpired(at: referenceDateProvider()) else { throw SessionError.expired }
            try sessionStore.save(session, issuedBy: issuer)
        } catch {
            // Cleanup must not inherit the cancelled login task's cancellation.
            await Task.detached { try? await client.signOut(token: session.token) }.value
            throw error
        }
        adopt(session, issuer: issuer, client: client)
        return session.userId
    }

    // Local state is cleared first: nothing in flight can be applied to the next profile, even if the
    // server-side revocation fails. The session also expires on its own within the hour.
    func signOut() async {
        let revokedToken = session?.token
        let client = sessionClient
        invalidate()
        guard let revokedToken else {
            return
        }
        try? await client?.signOut(token: revokedToken)
    }

    // Runs authenticated work and refuses to return a result that outlived its identity.
    func withSession<T: Sendable>(_ operation: @escaping @Sendable (String) async throws -> T) async throws -> T {
        let token = try activeToken()
        let startEpoch = epoch
        let id = UUID()
        let task = Task { try await operation(token) }
        cancelHandlers[id] = { task.cancel() }
        defer { cancelHandlers[id] = nil }

        do {
            // The handler forwards the caller's cancellation; awaiting task.value alone would not.
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard startEpoch == epoch else {
                throw SessionError.sessionChanged
            }
            _ = try activeToken()
            try Task.checkCancellation()
            return value
        } catch {
            guard startEpoch == epoch else {
                throw SessionError.sessionChanged
            }
            if error as? GatewayAuthError == .unauthorized || error as? BankGatewayError == .unauthorized {
                invalidate()
            }
            throw error
        }
    }

    // Freeze the bank client's destination together with its bearer before suspension.
    func withCredentials<T: Sendable>(_ operation: @escaping @Sendable (BankGatewayConfiguration) async throws -> T) async throws -> T {
        _ = try activeToken()
        guard let issuer = sessionIssuer else { throw SessionError.signedOut }
        return try await withSession { token in
            try await operation(BankGatewayConfiguration(baseURL: issuer, bearerToken: token))
        }
    }

    func validateRestoredSession() async throws {
        guard let client = sessionClient else { throw SessionError.signedOut }
        let expected = state.userId
        let actual = try await withSession { try await client.currentUserID(token: $0) }
        guard actual == expected else { invalidate(); throw SessionError.sessionChanged }
    }

    private func issuerMatches(_ issuer: URL) -> Bool {
        guard let current = try? issuerProvider() else { return false }
        return GatewaySessionStore.canonicalIssuer(current) == GatewaySessionStore.canonicalIssuer(issuer)
    }

    private func activeToken() throws -> String {
        guard let session else {
            throw SessionError.signedOut
        }
        guard let issuer = sessionIssuer, issuerMatches(issuer) else {
            invalidate()
            throw SessionError.sessionChanged
        }
        guard !session.isExpired(at: referenceDateProvider()) else {
            invalidate()
            throw SessionError.expired
        }
        return session.token
    }

    private func adopt(_ session: GatewayUserSession, issuer: URL, client: any GatewayAuthClient) {
        cancelInFlight()
        self.session = session
        sessionIssuer = issuer
        sessionClient = client
        epoch &+= 1
        state = .signedIn(userId: session.userId, expiresAt: session.expiresAt)
    }

    private func invalidate() {
        cancelInFlight()
        session = nil
        sessionIssuer = nil
        sessionClient = nil
        epoch &+= 1
        state = .signedOut
        try? sessionStore.clear()
    }

    private func cancelInFlight() {
        for cancel in cancelHandlers.values {
            cancel()
        }
        cancelHandlers.removeAll()
    }
}
