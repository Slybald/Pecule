import Foundation
import Synchronization

// Deterministic double for previews and tests: never reaches a network or an Apple service.
final class StubGatewayAuthClient: GatewayAuthClient {
    struct Script: Sendable {
        var challenge: GatewayAuthChallenge
        var session: GatewayUserSession
        var challengeError: GatewayAuthError?
        var sessionError: GatewayAuthError?

        static func make(
            userId: String = "apple_stub-user",
            nonce: String = String(repeating: "a", count: 64),
            issuedAt: Date = Date(timeIntervalSince1970: 1_789_371_262)
        ) -> Script {
            Script(
                challenge: GatewayAuthChallenge(
                    challengeId: "challenge-1",
                    nonce: nonce,
                    expiresAt: issuedAt.addingTimeInterval(5 * 60)
                ),
                session: GatewayUserSession(
                    token: String(repeating: "b", count: 64),
                    userId: userId,
                    expiresAt: issuedAt.addingTimeInterval(3600)
                )
            )
        }
    }

    private let script: Mutex<Script>
    private let calls = Mutex<[String]>([])

    init(script: Script = .make()) {
        self.script = Mutex(script)
    }

    var recordedCalls: [String] {
        calls.withLock { $0 }
    }

    var lastNonce: String? {
        script.withLock { $0.challenge.nonce }
    }

    func startChallenge() async throws -> GatewayAuthChallenge {
        calls.withLock { $0.append("challenge") }
        let current = script.withLock { $0 }
        if let error = current.challengeError {
            throw error
        }
        return current.challenge
    }

    func completeSignIn(challengeId: String, identityToken: String) async throws -> GatewayUserSession {
        calls.withLock { $0.append("session:\(challengeId)") }
        let current = script.withLock { $0 }
        if let error = current.sessionError {
            throw error
        }
        return current.session
    }

    func currentUserID(token: String) async throws -> String {
        calls.withLock { $0.append("identity") }
        return script.withLock { $0.session.userId }
    }

    func signOut(token: String) async throws {
        calls.withLock { $0.append("signOut:\(token.prefix(4))") }
    }
}
