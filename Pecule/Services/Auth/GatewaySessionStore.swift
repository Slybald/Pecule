import Foundation

// The user session lives under its own Keychain key, never the administrator bearer's.
// It is written as a single item: three separate writes could tear and mix a fresh token with the
// previous identity's user id, and a partial clear() could leave a usable token behind.
struct GatewaySessionStore: Sendable {
    private static let recordKey = "gatewaySession.record"

    private struct Record: Codable {
        let session: GatewayUserSession
        // A session is only valid against the gateway that issued it.
        let issuer: String
    }

    private let secretStore: any SecretStore

    init(secretStore: any SecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    // A session stored for another gateway is dropped instead of being sent to the new one.
    func load(issuedBy issuer: URL?) throws -> GatewayUserSession? {
        guard
            let raw = try secretStore.secret(for: Self.recordKey),
            let record = try? JSONDecoder().decode(Record.self, from: Data(raw.utf8))
        else {
            return nil
        }
        guard let issuer, record.issuer == Self.canonicalIssuer(issuer) else {
            try clear()
            return nil
        }
        return record.session
    }

    func save(_ session: GatewayUserSession, issuedBy issuer: URL) throws {
        let record = Record(session: session, issuer: Self.canonicalIssuer(issuer))
        let data = try JSONEncoder().encode(record)
        try secretStore.setSecret(String(decoding: data, as: UTF8.self), for: Self.recordKey)
    }

    func clear() throws {
        try secretStore.setSecret(nil, for: Self.recordKey)
    }

    static func canonicalIssuer(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let normalized = components?.url?.absoluteString ?? url.absoluteString
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
}
