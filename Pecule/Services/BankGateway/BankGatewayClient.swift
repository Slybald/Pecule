import Foundation

protocol BankGatewayClient: Sendable {
    var requiresConfiguration: Bool { get }
    func startLink(institution: BankInstitution) async throws -> BankLinkStart
    func link(id: String) async throws -> BankLink
    func deleteLink(id: String) async throws
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance]
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage
}

struct BankGatewayConfigurationStore: Sendable {
    private static let baseURLKey = "bankGateway.baseURL"
    private static let tokenKey = "bankGateway.token"
    private let secretStore: any SecretStore

    init(secretStore: any SecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    func load() throws -> BankGatewayConfiguration? {
        guard
            let rawURL = try secretStore.secret(for: Self.baseURLKey),
            let baseURL = URL(string: rawURL),
            let token = try secretStore.secret(for: Self.tokenKey),
            !token.isEmpty
        else {
            return nil
        }
        return BankGatewayConfiguration(baseURL: baseURL, bearerToken: token)
    }

    // Authentication needs the gateway address before any token exists, so the URL is readable alone.
    func loadBaseURL() throws -> URL? {
        guard let rawURL = try secretStore.secret(for: Self.baseURLKey) else {
            return nil
        }
        return URL(string: rawURL)
    }

    func save(_ configuration: BankGatewayConfiguration) throws {
        try secretStore.setSecret(configuration.baseURL.absoluteString, for: Self.baseURLKey)
        try secretStore.setSecret(configuration.bearerToken, for: Self.tokenKey)
    }

    func clear() throws {
        try secretStore.setSecret(nil, for: Self.baseURLKey)
        try secretStore.setSecret(nil, for: Self.tokenKey)
    }
}

final class LiveBankGatewayClient: BankGatewayClient {
    private let session: URLSession
    private let userAgent: String
    private let configurationProvider: @Sendable () throws -> BankGatewayConfiguration?

    init(
        session: URLSession = .shared,
        userAgent: String = "Pecule/1.0 (iOS)",
        configurationProvider: @escaping @Sendable () throws -> BankGatewayConfiguration?
    ) {
        self.session = session
        self.userAgent = userAgent
        self.configurationProvider = configurationProvider
    }

    var requiresConfiguration: Bool { true }

    // Checks a candidate configuration without storing it: /healthz for the URL, /v1/aspsps for the bearer.
    func probe(_ configuration: BankGatewayConfiguration) async throws -> BankGatewayProbe {
        let health = try decode(HealthEnvelope.self, from: try await send("GET", "/healthz", configuration: configuration, authenticated: false))
        let aspsps = try decode(ASPSPEnvelope.self, from: try await send("GET", "/v1/aspsps", query: [URLQueryItem(name: "country", value: "FR")], configuration: configuration))
        return BankGatewayProbe(environment: health.environment ?? "unknown", aspspCount: aspsps.aspsps.count)
    }

    private struct HealthEnvelope: Decodable {
        let ok: Bool
        let environment: String?
    }

    private struct ASPSPEnvelope: Decodable {
        struct Entry: Decodable {
            let name: String
        }

        let aspsps: [Entry]
    }

    func startLink(institution: BankInstitution) async throws -> BankLinkStart {
        let body = ["aspspName": institution.aspspName, "aspspCountry": institution.aspspCountry]
        let data = try await send("POST", "/v1/links", body: try JSONSerialization.data(withJSONObject: body))
        return try decode(BankLinkStart.self, from: data)
    }

    func link(id: String) async throws -> BankLink {
        try decode(BankLink.self, from: try await send("GET", "/v1/links/\(id)"))
    }

    func deleteLink(id: String) async throws {
        _ = try await send("DELETE", "/v1/links/\(id)")
    }

    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        let data = try await send("GET", "/v1/accounts/\(accountUID)/balances", query: attendedQuery(attended))
        return try decode(BalancesEnvelope.self, from: data).balances
    }

    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        var items = attendedQuery(attended)
        if let dateFrom = query.dateFrom {
            items.append(URLQueryItem(name: "date_from", value: BankGatewayJSON.dayString(from: dateFrom)))
        }
        if let dateTo = query.dateTo {
            items.append(URLQueryItem(name: "date_to", value: BankGatewayJSON.dayString(from: dateTo)))
        }
        if let continuationKey = query.continuationKey {
            items.append(URLQueryItem(name: "continuation_key", value: continuationKey))
        }
        if let strategy = query.strategy {
            items.append(URLQueryItem(name: "strategy", value: strategy))
        }
        let data = try await send("GET", "/v1/accounts/\(accountUID)/transactions", query: items)
        return try decode(BankTransactionsPage.self, from: data)
    }

    private struct BalancesEnvelope: Decodable {
        let balances: [BankBalance]
    }

    private struct ErrorEnvelope: Decodable {
        let error: String?
        let retryAfterSeconds: Int?
        let upstreamStatus: Int?
        let upstreamCode: String?
    }

    private func attendedQuery(_ attended: Bool) -> [URLQueryItem] {
        attended ? [URLQueryItem(name: "attended", value: "1")] : []
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let configuration = try configurationProvider() else {
            throw BankGatewayError.notConfigured
        }
        return try await send(method, path, query: query, body: body, configuration: configuration)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        configuration: BankGatewayConfiguration,
        authenticated: Bool = true
    ) async throws -> Data {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw BankGatewayError.notConfigured
        }
        components.path = components.path.trimmingSuffix("/") + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw BankGatewayError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated {
            request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BankGatewayError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BankGatewayError.transport("Non-HTTP response")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Self.error(status: httpResponse.statusCode, body: data)
        }
        return data
    }

    static func error(status: Int, body: Data) -> BankGatewayError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        switch (status, envelope?.error) {
        case (401, _):
            return .unauthorized
        case (409, "session_expired"):
            return .sessionExpired
        case (429, _):
            return .rateLimited(retryAfterSeconds: envelope?.retryAfterSeconds ?? 6 * 3600)
        case (404, "link_not_found"):
            return .linkNotFound
        case (502, "upstream_error"):
            return .upstream(status: envelope?.upstreamStatus ?? 502, code: envelope?.upstreamCode ?? "unknown")
        default:
            return .http(status: status, code: envelope?.error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try BankGatewayJSON.makeDecoder().decode(type, from: data)
        } catch {
            throw BankGatewayError.decoding(String(describing: error))
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
