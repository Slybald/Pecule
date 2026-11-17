import Foundation

// Every bank request receives one immutable issuer/token pair from the coordinator.
struct SessionBankGatewayClient: BankGatewayClient {
    let coordinator: GatewaySessionCoordinator
    var requiresConfiguration: Bool { false }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (LiveBankGatewayClient) async throws -> T) async throws -> T {
        try await coordinator.withCredentials { credentials in
            try await operation(LiveBankGatewayClient(configurationProvider: { credentials }))
        }
    }
    func startLink(institution: BankInstitution) async throws -> BankLinkStart {
        try await perform { try await $0.startLink(institution: institution) }
    }
    func link(id: String) async throws -> BankLink { try await perform { try await $0.link(id: id) } }
    func deleteLink(id: String) async throws { try await perform { try await $0.deleteLink(id: id) } }
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        try await perform { try await $0.balances(accountUID: accountUID, attended: attended) }
    }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        try await perform { try await $0.transactions(accountUID: accountUID, query: query, attended: attended) }
    }
}

// Manual mode has no bank transport. It must never create a simulated bank in production.
struct OfflineBankGatewayClient: BankGatewayClient {
    var requiresConfiguration: Bool { true }
    func startLink(institution: BankInstitution) async throws -> BankLinkStart { throw BankGatewayError.notConfigured }
    func link(id: String) async throws -> BankLink { throw BankGatewayError.notConfigured }
    func deleteLink(id: String) async throws { throw BankGatewayError.notConfigured }
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] { throw BankGatewayError.notConfigured }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage { throw BankGatewayError.notConfigured }
}
