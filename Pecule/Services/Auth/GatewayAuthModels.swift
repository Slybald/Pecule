import Foundation

// Contract of the multi-user gateway: POST /v1/auth/apple/challenge then POST /v1/auth/apple/session.
// The server issues the nonce; the app must hand that exact string to Apple, unhashed, because the
// server compares the nonce it stored with the one Apple signed into the identity token.
struct GatewayAuthChallenge: Equatable, Sendable {
    let challengeId: String
    let nonce: String
    let expiresAt: Date

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

// An application session, not an Apple token: the identity token is never stored on the device.
struct GatewayUserSession: Codable, Equatable, Sendable {
    let token: String
    let userId: String
    let expiresAt: Date

    func isExpired(at date: Date, leeway: TimeInterval = 30) -> Bool {
        date.addingTimeInterval(leeway) >= expiresAt
    }
}

enum GatewayAuthError: Error, Equatable {
    case notConfigured
    // The challenge was consumed, the identity token was refused, or the nonce did not match.
    // Every failure consumes the challenge server-side: always start a fresh one.
    case invalidIdentity
    case unauthorized
    case rateLimited(retryAfterSeconds: Int)
    // Multi-user mode is not provisioned on this gateway (no vault, no Apple audience, no rate limiter).
    case unavailable
    case challengeExpired
    case transport(String)
    case decoding(String)
    case http(status: Int, code: String?)
}

extension GatewayAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured: AppLocalizer.string("auth.error.notConfigured")
        case .invalidIdentity: AppLocalizer.string("auth.error.invalidIdentity")
        case .unauthorized: AppLocalizer.string("auth.error.unauthorized")
        case .rateLimited: AppLocalizer.string("auth.error.rateLimited")
        case .unavailable: AppLocalizer.string("auth.error.unavailable")
        case .challengeExpired: AppLocalizer.string("auth.error.challengeExpired")
        case .transport, .decoding, .http: AppLocalizer.string("auth.error.generic")
        }
    }
}

// Unix milliseconds on the wire, as the gateway sends them.
enum GatewayAuthTimestamp {
    static func date(fromMilliseconds value: Double) -> Date {
        Date(timeIntervalSince1970: value / 1000)
    }
}
