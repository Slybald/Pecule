import XCTest
@testable import Pecule

@MainActor
final class GatewaySessionCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_371_262)
    private let issuer = URL(string: "https://gateway.test")!
    private let otherIssuer = URL(string: "https://other-gateway.test")!

    private func makeCoordinator(
        client: StubGatewayAuthClient = StubGatewayAuthClient(),
        secretStore: InMemorySecretStore = InMemorySecretStore(),
        issuer: URL? = nil,
        date: Date? = nil
    ) -> (GatewaySessionCoordinator, StubGatewayAuthClient, GatewaySessionStore) {
        let store = GatewaySessionStore(secretStore: secretStore)
        let reference = date ?? now
        let host = issuer ?? self.issuer
        let coordinator = GatewaySessionCoordinator(
            authClient: client,
            sessionStore: store,
            issuerProvider: { host },
            referenceDateProvider: { reference }
        )
        return (coordinator, client, store)
    }

    func testSignInHandsTheServerNonceToAppleVerbatimAndStoresTheSession() async throws {
        let (coordinator, client, store) = makeCoordinator()
        let seenNonce = NonceRecorder()

        let userId = try await coordinator.signIn { challenge in
            seenNonce.record(challenge.nonce)
            return "apple.identity.token"
        }

        XCTAssertEqual(userId, "apple_stub-user")
        XCTAssertEqual(seenNonce.value, client.lastNonce, "the nonce must reach Apple unhashed, exactly as issued")
        XCTAssertEqual(coordinator.state, .signedIn(userId: "apple_stub-user", expiresAt: now.addingTimeInterval(3600)))
        XCTAssertEqual(try store.load(issuedBy: issuer)?.userId, "apple_stub-user")
        XCTAssertEqual(client.recordedCalls, ["challenge", "session:challenge-1"])
    }

    func testFailedSignInLeavesNoSessionBehind() async throws {
        var script = StubGatewayAuthClient.Script.make()
        script.sessionError = .invalidIdentity
        let (coordinator, _, store) = makeCoordinator(client: StubGatewayAuthClient(script: script))

        do {
            _ = try await coordinator.signIn { _ in "apple.identity.token" }
            XCTFail("expected invalidIdentity")
        } catch let error as GatewayAuthError {
            XCTAssertEqual(error, .invalidIdentity)
        }

        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertNil(try store.load(issuedBy: issuer))
    }

    func testAnExpiredChallengeIsRefusedBeforeAskingApple() async throws {
        let issuedAt = now.addingTimeInterval(-600)
        let script = StubGatewayAuthClient.Script.make(issuedAt: issuedAt)
        let (coordinator, client, _) = makeCoordinator(client: StubGatewayAuthClient(script: script))
        let asked = NonceRecorder()

        do {
            _ = try await coordinator.signIn { challenge in
                asked.record(challenge.nonce)
                return "apple.identity.token"
            }
            XCTFail("expected challengeExpired")
        } catch let error as GatewayAuthError {
            XCTAssertEqual(error, .challengeExpired)
        }

        XCTAssertNil(asked.value, "an expired challenge never reaches Apple")
        XCTAssertEqual(client.recordedCalls, ["challenge"], "and no session is requested with it")
    }

    func testSignInWithoutAConfiguredGatewayIsRefused() async {
        let client = StubGatewayAuthClient()
        let reference = now
        let unconfigured = GatewaySessionCoordinator(
            authClient: client,
            sessionStore: GatewaySessionStore(secretStore: InMemorySecretStore()),
            issuerProvider: { nil },
            referenceDateProvider: { reference }
        )

        do {
            _ = try await unconfigured.signIn { _ in "apple.identity.token" }
            XCTFail("expected notConfigured")
        } catch let error as GatewayAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(client.recordedCalls.isEmpty, "no challenge is requested without a gateway")
    }

    func testRestoreDropsAnExpiredStoredSession() throws {
        let secretStore = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secretStore)
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(-1)), issuedBy: issuer)
        let (coordinator, _, _) = makeCoordinator(secretStore: secretStore)

        coordinator.restore()

        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertNil(try store.load(issuedBy: issuer), "an expired session is cleared, never presented as valid")
    }

    func testRestoreAdoptsAValidStoredSession() throws {
        let secretStore = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secretStore)
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)
        let (coordinator, _, _) = makeCoordinator(secretStore: secretStore)

        coordinator.restore()

        XCTAssertEqual(coordinator.state.userId, "apple_1")
    }

    func testASessionIsNeverSentToAGatewayThatDidNotIssueIt() throws {
        let secretStore = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secretStore)
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)

        // The gateway address changed: the stored token means nothing to the new host.
        XCTAssertNil(try store.load(issuedBy: otherIssuer))
        XCTAssertNil(try store.load(issuedBy: issuer), "and the orphan record is dropped, not left behind")

        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)
        let (coordinator, _, _) = makeCoordinator(secretStore: secretStore, issuer: otherIssuer)
        coordinator.restore()
        XCTAssertEqual(coordinator.state, .signedOut)
    }

    func testATrailingSlashIsNotADifferentGateway() throws {
        let store = GatewaySessionStore(secretStore: InMemorySecretStore())
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)

        XCTAssertNotNil(try store.load(issuedBy: URL(string: "https://gateway.test/")!))
    }

    func testWithSessionRefusesWorkWhenSignedOut() async throws {
        let (coordinator, _, _) = makeCoordinator()

        do {
            _ = try await coordinator.withSession { $0 }
            XCTFail("expected signedOut")
        } catch let error as GatewaySessionCoordinator.SessionError {
            XCTAssertEqual(error, .signedOut)
        }
    }

    func testASessionThatExpiresWhileSignedInIsRefusedAndCleared() async throws {
        let secretStore = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secretStore)
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(60)), issuedBy: issuer)
        // The clock moves past the expiry between restore and use, as it would while the app sits idle.
        let clock = MovableClock(now)
        let host = issuer
        let coordinator = GatewaySessionCoordinator(
            authClient: StubGatewayAuthClient(),
            sessionStore: store,
            issuerProvider: { host },
            referenceDateProvider: { clock.now }
        )
        coordinator.restore()
        XCTAssertTrue(coordinator.isSignedIn)

        clock.advance(by: 120)

        do {
            _ = try await coordinator.withSession { $0 }
            XCTFail("expected expired")
        } catch let error as GatewaySessionCoordinator.SessionError {
            XCTAssertEqual(error, .expired)
        }
        XCTAssertEqual(coordinator.state, .signedOut, "an expired session signs the user out")
        XCTAssertNil(try store.load(issuedBy: issuer), "and is removed from the Keychain")
    }

    func testTheExpiryLeewayRefusesASessionAboutToDie() async throws {
        let secretStore = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secretStore)
        // Ten seconds of life left: inside the 30 s leeway, so it must not start new work.
        try store.save(GatewayUserSession(token: "t", userId: "apple_1", expiresAt: now.addingTimeInterval(10)), issuedBy: issuer)
        let (coordinator, _, _) = makeCoordinator(secretStore: secretStore)

        coordinator.restore()

        XCTAssertEqual(coordinator.state, .signedOut)
    }

    func testAResponseArrivingAfterSignOutIsDiscarded() async throws {
        let (coordinator, client, store) = makeCoordinator()
        try await coordinator.signIn { _ in "apple.identity.token" }
        let started = Gate()
        let release = Gate()

        let work = Task { @MainActor in
            try await coordinator.withSession { token in
                await started.open()
                await release.wait()
                return token
            }
        }
        await started.wait()

        await coordinator.signOut()
        await release.open()

        do {
            _ = try await work.value
            XCTFail("a response produced for the previous identity must never be returned")
        } catch let error as GatewaySessionCoordinator.SessionError {
            XCTAssertEqual(error, .sessionChanged)
        }
        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertNil(try store.load(issuedBy: issuer), "sign-out clears the stored session")
        XCTAssertTrue(client.recordedCalls.contains { $0.hasPrefix("signOut:") }, "the server session is revoked too")
    }

    func testAResponseArrivingAfterAProfileChangeIsDiscarded() async throws {
        let (coordinator, _, _) = makeCoordinator()
        try await coordinator.signIn { _ in "apple.identity.token" }
        let started = Gate()
        let release = Gate()

        let work = Task { @MainActor in
            try await coordinator.withSession { token in
                await started.open()
                await release.wait()
                return token
            }
        }
        await started.wait()

        // Signing in again while the request is in flight: even the same person gets a fresh session,
        // so the earlier response belongs to a session that no longer exists.
        try await coordinator.signIn { _ in "apple.identity.token" }
        await release.open()

        do {
            _ = try await work.value
            XCTFail("expected sessionChanged")
        } catch let error as GatewaySessionCoordinator.SessionError {
            XCTAssertEqual(error, .sessionChanged)
        }
    }

    func testASignInLandingAfterASignOutNeverResurrectsTheSession() async throws {
        let (coordinator, client, store) = makeCoordinator()
        try await coordinator.signIn { _ in "apple.identity.token" }
        let started = Gate()
        let release = Gate()

        // A second sign-in is held open at the Apple step, then the user signs out.
        let late = Task { @MainActor in
            try await coordinator.signIn { _ in
                await started.open()
                await release.wait()
                return "apple.identity.token"
            }
        }
        await started.wait()
        await coordinator.signOut()
        await release.open()

        do {
            _ = try await late.value
            XCTFail("a sign-in that lands after a sign-out must not sign the user back in")
        } catch let error as GatewaySessionCoordinator.SessionError {
            XCTAssertEqual(error, .sessionChanged)
        }
        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertNil(try store.load(issuedBy: issuer))
        // The session the server minted during that race is revoked instead of living out its hour.
        XCTAssertEqual(client.recordedCalls.filter { $0.hasPrefix("signOut:") }.count, 2)
    }

    func testCallerCancellationReachesTheOperation() async throws {
        let (coordinator, _, _) = makeCoordinator()
        try await coordinator.signIn { _ in "apple.identity.token" }
        let started = Gate()
        let observed = CancellationRecorder()

        let work = Task { @MainActor in
            try await coordinator.withSession { _ -> String in
                await started.open()
                while !Task.isCancelled {
                    await Task.yield()
                }
                observed.record()
                throw CancellationError()
            }
        }
        await started.wait()
        work.cancel()

        do {
            _ = try await work.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(observed.wasCancelled, "the operation must see the caller's cancellation")
        }
    }

    func testWorkCompletedUnderTheSameIdentityIsReturned() async throws {
        let (coordinator, _, _) = makeCoordinator()
        try await coordinator.signIn { _ in "apple.identity.token" }

        let token = try await coordinator.withSession { $0 }

        XCTAssertEqual(token, String(repeating: "b", count: 64))
    }

    func testSignOutWithoutASessionDoesNotCallTheServer() async {
        let (coordinator, client, _) = makeCoordinator()

        await coordinator.signOut()

        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertTrue(client.recordedCalls.isEmpty)
    }

    func testTheSessionStoreNeverTouchesTheGatewayConfiguration() throws {
        // Both live in the Keychain; clearing one must not sign the other out.
        let secretStore = InMemorySecretStore()
        let configuration = BankGatewayConfigurationStore(secretStore: secretStore)
        try configuration.save(BankGatewayConfiguration(baseURL: issuer, bearerToken: "admin-bearer"))
        let sessions = GatewaySessionStore(secretStore: secretStore)
        try sessions.save(GatewayUserSession(token: "user-session", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)

        try sessions.clear()

        XCTAssertNil(try sessions.load(issuedBy: issuer))
        XCTAssertEqual(try configuration.load()?.bearerToken, "admin-bearer", "the administrator bearer survives a sign-out")

        try sessions.save(GatewayUserSession(token: "user-session", userId: "apple_1", expiresAt: now.addingTimeInterval(600)), issuedBy: issuer)
        try configuration.clear()

        XCTAssertNil(try configuration.load())
        XCTAssertEqual(try sessions.load(issuedBy: issuer)?.token, "user-session", "and the session survives a gateway reset")
        XCTAssertNil(try configuration.loadBaseURL())
    }
}

// Lets a test hold an operation open across a sign-out without polling. Supports several waiters.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class NonceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ nonce: String) {
        lock.lock()
        storage = nonce
        lock.unlock()
    }
}

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func record() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
