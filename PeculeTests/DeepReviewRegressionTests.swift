import Foundation
import XCTest
@testable import Pecule

// Reproductions from the code review, retained as regression coverage.
@MainActor
final class DeepReviewRegressionTests: XCTestCase {
    private let now = TestFixtures.referenceDate
    private let issuer = URL(string: "https://gateway-a.test")!

    func testIssuerChangeNeverReceivesOldSessionDuringLogout() async throws {
        let secret = InMemorySecretStore()
        let store = GatewaySessionStore(secretStore: secret)
        try store.save(GatewayUserSession(token: "synthetic-user-token", userId: "A", expiresAt: now.addingTimeInterval(3600)), issuedBy: issuer)
        let host = ReviewLockedValue(issuer)
        let requests = ReviewLockedValue<[URLRequest]>([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { request in
            requests.mutate { $0.append(request) }
            return (204, Data())
        }
        defer { StubURLProtocol.handler = nil }
        let client = LiveGatewayAuthClient(session: URLSession(configuration: configuration), baseURLProvider: { host.value })
        let date = now
        let coordinator = GatewaySessionCoordinator(authClient: client, sessionStore: store, issuerProvider: { host.value }, referenceDateProvider: { date })
        coordinator.restore()
        host.set(URL(string: "https://gateway-b.test")!)
        await coordinator.signOut()
        let leaked = requests.value.filter { $0.url?.host == "gateway-b.test" && $0.value(forHTTPHeaderField: "Authorization") != nil }
        XCTAssertTrue(leaked.isEmpty, "A session token was sent to gateway B during sign-out")
    }

    func testCancelledSignInDoesNotPersistOrAdoptSession() async throws {
        let store = GatewaySessionStore(secretStore: InMemorySecretStore())
        let date = now, url = issuer
        let client = StubGatewayAuthClient()
        let coordinator = GatewaySessionCoordinator(authClient: client, sessionStore: store, issuerProvider: { url }, referenceDateProvider: { date })
        let started = ReviewGate(), release = ReviewGate()
        let work = Task { @MainActor in
            try await coordinator.signIn { _ in
                await started.open()
                await release.wait()
                return "synthetic.apple.identity"
            }
        }
        await started.wait()
        work.cancel()
        await release.open()
        _ = try? await work.value
        XCTAssertEqual(coordinator.state, .signedOut, "Cancelled login adopted a session")
        XCTAssertNil(try store.load(issuedBy: issuer), "Cancelled login persisted a token")
    }

    func testUnauthorizedSessionIsInvalidated() async throws {
        let store = GatewaySessionStore(secretStore: InMemorySecretStore())
        let date = now, url = issuer
        let coordinator = GatewaySessionCoordinator(authClient: StubGatewayAuthClient(), sessionStore: store, issuerProvider: { url }, referenceDateProvider: { date })
        try await coordinator.signIn { _ in "synthetic.apple.identity" }
        do {
            _ = try await coordinator.withSession { _ -> String in throw GatewayAuthError.unauthorized }
        } catch {}
        XCTAssertEqual(coordinator.state, .signedOut, "A revoked server session still appears signed in")
        XCTAssertNil(try store.load(issuedBy: issuer))
    }

    func testExplicitZeroBudgetKeepsOverspendingVisible() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        try state.setBudgetRule(category: ExpenseCategory.insurance.storageValue, monthlyAmount: 0)
        try state.dataStore.importBankTransactions([TestFixtures.transaction(account: account, reference: "insurance", amount: 10, direction: .debit, dayOffset: 0, category: .insurance)])
        state.reload()
        state.prefersBankAmounts = true
        let row = try XCTUnwrap(state.budgetOverview(for: now).first { $0.category == .insurance })
        XCTAssertEqual(row.plannedAmount, Decimal.zero)
        XCTAssertEqual(row.remainingAmount, Decimal(-10))
        XCTAssertTrue(row.isOverspent)
    }

    func testRefundReducesExpensesInsteadOfBecomingIncome() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "purchase", amount: 100, direction: .debit, dayOffset: -2, label: "SHOP", category: .shopping),
            TestFixtures.transaction(account: account, reference: "refund", amount: 30, direction: .credit, dayOffset: 0, label: "REMBOURSEMENT SHOP", category: .shopping)
        ])
        state.reload()
        state.prefersBankAmounts = true
        let summary = state.monthlyFinancialSummary(for: now)
        XCTAssertEqual(summary.totalEstimatedIncome, 0)
        XCTAssertEqual(summary.totalExpenses, 70)
    }

    func testDisabledLinkedSubscriptionIsNotForecastAgain() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 1000)]).first)
        try state.addSubscription(name: "CURSOR", amount: 20, billingCycle: .monthly, category: ExpenseCategory.subscriptions.storageValue, nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: false)
        let subscription = try XCTUnwrap(state.subscriptions.first)
        let transactions = (6...8).map { month in
            BankTransaction(externalID: "cursor-\(month)", accountID: account.id, amount: 20, direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.date(2026, month, 20), label: "CURSOR", category: ExpenseCategory.subscriptions.storageValue, linkedSubscriptionID: subscription.id)
        }
        try state.dataStore.importBankTransactions(transactions)
        state.reload()
        let forecast = try XCTUnwrap(state.cashflowForecast(on: TestFixtures.date(2026, 9, 15), calendar: TestFixtures.utcCalendar()))
        XCTAssertTrue(state.activeSubscriptions.isEmpty)
        XCTAssertEqual(forecast.remainingFixedCharges, 0, "Inactive subscription was regenerated from bank history")
    }

    func testInterruptedInitialImportRetriesTheMissingHistory() async throws {
        let store = try TestFixtures.makeDataStore()
        let accounts = try store.saveExternalAccounts([TestFixtures.linkedAccount()])
        let gateway = ReviewInterruptedGateway(now: now)
        let date = now
        let sync = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { date })
        await sync.refresh(accounts, attended: true)
        XCTAssertNotNil(accounts.first?.lastSyncError)
        await sync.refresh(accounts, attended: true)
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.bankTransactions.count, 2, "The second import permanently skipped the missing older page")
    }
}

private final class ReviewLockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: T) { lock.lock(); defer { lock.unlock() }; storage = value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}

private actor ReviewInterruptedGateway: BankGatewayClient {
    nonisolated var requiresConfiguration: Bool { false }
    private let now: Date
    private var didFail = false
    init(now: Date) { self.now = now }
    func startLink(institution: BankInstitution) async throws -> BankLinkStart { throw BankGatewayError.notConfigured }
    func link(id: String) async throws -> BankLink { throw BankGatewayError.notConfigured }
    func deleteLink(id: String) async throws {}
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        [BankBalance(name: nil, balanceType: "CLBD", amount: 1000, currency: "EUR")]
    }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        if query.continuationKey != nil && !didFail {
            didFail = true
            throw BankGatewayError.transport("Synthetic interruption on second page")
        }
        let recent = BankTransactionDTO(entryReference: "recent", amount: 10, currency: "EUR", creditDebitIndicator: .debit, bookingDate: now.addingTimeInterval(-86400), creditorName: "SHOP")
        let oldDate = now.addingTimeInterval(-90 * 86400)
        let old = BankTransactionDTO(entryReference: "old", amount: 15, currency: "EUR", creditDebitIndicator: .debit, bookingDate: oldDate, creditorName: "SHOP")
        if !didFail { return BankTransactionsPage(transactions: [recent], continuationKey: "older-page") }
        return BankTransactionsPage(transactions: query.dateFrom.map { $0 <= oldDate } == true ? [recent, old] : [recent], continuationKey: nil)
    }
}

private actor ReviewGate {
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
        for continuation in pending { continuation.resume() }
    }
}
