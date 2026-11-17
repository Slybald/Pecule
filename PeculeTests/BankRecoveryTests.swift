import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class BankRecoveryTests: XCTestCase {
    private let now = TestFixtures.referenceDate

    func testAuthorizationSurvivesStoreReopenAndRejectsUnrelatedCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ProfileStoreLocation(issuer: URL(string: "https://gateway.test")!, userID: "recovery")
        try await persistPendingAuthorization(location: location, root: root)
        let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: location, root: root))
        let gateway = ScriptedGateway()
        let date = now
        let service = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { date })
        XCTAssertEqual(service.pendingLink?.institution, .boursorama)
        await service.handleIncomingURL(URL(string: "lifeos://link/error?linkId=other&code=denied")!)
        await service.handleIncomingURL(URL(string: "lifeos://link/done?linkId=other")!)
        XCTAssertEqual(service.pendingLink?.linkID, "link-1")
        XCTAssertTrue(try store.loadSnapshot().externalAccounts.isEmpty)
        await service.handleIncomingURL(URL(string: "lifeos://link/done?linkId=link-1")!)
        XCTAssertEqual(try store.loadSnapshot().externalAccounts.count, 2)
        XCTAssertNil(try store.pendingBankAuthorization())
        XCTAssertNil(service.pendingLink)
    }

    private func persistPendingAuthorization(location: ProfileStoreLocation, root: URL) async throws {
        let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: location, root: root))
        let date = now
        let service = BankSyncService(gateway: ScriptedGateway(), dataStore: store, referenceDateProvider: { date })
        let url = await service.startExternalLink(institution: .boursorama)
        XCTAssertNotNil(url)
        XCTAssertEqual(try store.pendingBankAuthorization()?.linkID, "link-1")
    }

    func testExpiredAndCancelledAuthorizationsCannotResumeAfterRestart() async throws {
        let store = try TestFixtures.makeDataStore()
        try store.savePendingBankAuthorization(linkID: "expired", institution: .mock, expiresAt: now)
        let date = now
        let service = BankSyncService(gateway: ScriptedGateway(), dataStore: store, referenceDateProvider: { date })
        XCTAssertNil(service.pendingLink)
        XCTAssertNil(try store.pendingBankAuthorization())
        _ = await service.startExternalLink(institution: .mock)
        service.cancelPendingLink()
        let restarted = BankSyncService(gateway: ScriptedGateway(), dataStore: store, referenceDateProvider: { date })
        XCTAssertNil(restarted.pendingLink)
        await restarted.handleIncomingURL(URL(string: "lifeos://link/done?linkId=link-1")!)
        XCTAssertTrue(try store.loadSnapshot().externalAccounts.isEmpty)
    }

    func testInterruptedImportResumesPersistedPageAndPreservesEarlierPages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ProfileStoreLocation(issuer: URL(string: "https://gateway.test")!, userID: "pages")
        let accountID = try await persistInterruptedImport(location: location, root: root)
        let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: location, root: root))
        let gateway = ScriptedGateway()
        gateway.transactionPages = ["page-2": BankTransactionsPage(transactions: [
            BankTransactionDTO(entryReference: "old", amount: 30, currency: "EUR", creditDebitIndicator: .debit, bookingDate: now.addingTimeInterval(-90 * 86400))
        ], continuationKey: nil)]
        let date = now
        let service = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { date })
        await service.refresh(try store.loadSnapshot().externalAccounts, attended: true)
        XCTAssertEqual(gateway.transactionQueries.first?.continuationKey, "page-2")
        XCTAssertEqual(gateway.transactionQueries.first?.dateFrom, now.addingTimeInterval(-365 * 86400))
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.bankTransactions.count, 2, "Completing page 2 must preserve page 1 during pruning")
        XCTAssertNil(snapshot.externalAccounts.first?.lastSyncError)
        let checkpoint = try store.importCheckpoint(accountID: accountID)
        XCTAssertTrue(checkpoint.initialImportCompleted)
        XCTAssertNil(checkpoint.continuationKey)
        XCTAssertNil(checkpoint.windowStart)
    }

    private func persistInterruptedImport(location: ProfileStoreLocation, root: URL) async throws -> UUID {
        let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: location, root: root))
        let accounts = try store.saveExternalAccounts([TestFixtures.linkedAccount(balance: 777)])
        let date = now
        let service = BankSyncService(gateway: InterruptedPagesGateway(now: now), dataStore: store, referenceDateProvider: { date })
        await service.refresh(accounts, attended: true)
        XCTAssertEqual(accounts[0].balance, 10, "Audit 2026-11-09 constat 3 : le solde lu avant l'échec de l'import est enregistré, la synchronisation reste en échec")
        XCTAssertNil(accounts[0].lastSyncedAt)
        XCTAssertNotNil(accounts[0].lastSyncError)
        XCTAssertEqual(try store.loadSnapshot().bankTransactions.count, 1)
        XCTAssertFalse(try store.importCheckpoint(accountID: accounts[0].id).initialImportCompleted)
        return accounts[0].id
    }

    func testResponseAfterProfileInvalidationCannotWriteBalanceOrTransactions() async throws {
        let store = try TestFixtures.makeDataStore()
        let accounts = try store.saveExternalAccounts([TestFixtures.linkedAccount(balance: 777)])
        let gateway = SuspendedBalanceGateway()
        let service = BankSyncService(gateway: gateway, dataStore: store)
        let work = Task { await service.refresh(accounts, attended: true) }
        await gateway.waitForRequest()
        service.invalidate()
        await gateway.release()
        await work.value
        XCTAssertEqual(accounts[0].balance, 777)
        XCTAssertNil(accounts[0].lastSyncedAt)
        XCTAssertNil(accounts[0].lastSyncError)
        XCTAssertTrue(try store.loadSnapshot().bankTransactions.isEmpty)
    }
}

private actor InterruptedPagesGateway: BankGatewayClient {
    nonisolated var requiresConfiguration: Bool { false }
    let now: Date
    init(now: Date) { self.now = now }
    func startLink(institution: BankInstitution) async throws -> BankLinkStart { throw BankGatewayError.notConfigured }
    func link(id: String) async throws -> BankLink { throw BankGatewayError.notConfigured }
    func deleteLink(id: String) async throws {}
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        [BankBalance(name: nil, balanceType: "CLBD", amount: 10, currency: "EUR")]
    }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        if query.continuationKey != nil { throw BankGatewayError.transport("interrupted") }
        return BankTransactionsPage(transactions: [BankTransactionDTO(entryReference: "recent", amount: 10, currency: "EUR", creditDebitIndicator: .debit, bookingDate: now)], continuationKey: "page-2")
    }
}

private actor SuspendedBalanceGateway: BankGatewayClient {
    nonisolated var requiresConfiguration: Bool { false }
    private var pending: CheckedContinuation<[BankBalance], Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func startLink(institution: BankInstitution) async throws -> BankLinkStart { throw BankGatewayError.notConfigured }
    func link(id: String) async throws -> BankLink { throw BankGatewayError.notConfigured }
    func deleteLink(id: String) async throws {}
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(returning: [BankBalance(name: nil, balanceType: "CLBD", amount: 5, currency: "EUR")]); pending = nil }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        XCTFail("Invalidated profile must not request transactions")
        return BankTransactionsPage(transactions: [], continuationKey: nil)
    }
}
