import XCTest
@testable import Pecule

final class ScriptedGateway: BankGatewayClient, @unchecked Sendable {
    var requiresConfiguration = true
    var startResult: Result<BankLinkStart, Error> = .success(
        BankLinkStart(linkId: "link-1", authUrl: URL(string: "https://bank.test/authorize")!, validUntil: .distantFuture)
    )
    var linkResult: Result<BankLink, Error> = .success(
        BankLink(
            id: "link-1",
            status: .authorized,
            aspsp: BankAspsp(name: "Mock ASPSP", country: "FR"),
            validUntil: .distantFuture,
            errorCode: nil,
            accounts: [
                BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: "FR7630006000011234567890189", name: "Courant", currency: "EUR", product: nil, cashAccountType: "CACC", usage: "PRIV"),
                BankLinkAccount(uid: "uid-2", identificationHash: nil, iban: nil, name: nil, currency: nil, product: nil, cashAccountType: "CARD", usage: nil),
            ]
        )
    )
    var deleteError: Error?
    // Every revocation the app asked for, failed or not: a link must never be asked to go while an account still uses it.
    var deleteRequests: [String] = []
    var balancesResult: Result<[BankBalance], Error> = .success([
        BankBalance(name: nil, balanceType: "XPCD", amount: 10, currency: "EUR"),
        BankBalance(name: nil, balanceType: "CLBD", amount: Decimal(string: "20.5")!, currency: "EUR"),
    ])
    var balanceRequests: [(uid: String, attended: Bool)] = []
    var transactionPages: [String?: BankTransactionsPage] = [nil: BankTransactionsPage(transactions: [], continuationKey: nil)]
    var transactionPagesByAccount: [String: [String?: BankTransactionsPage]] = [:]
    var transactionQueries: [BankTransactionsQuery] = []
    // Keyed by continuation key (nil is the first page): that request fails with this error instead of returning its page.
    var transactionErrors: [String?: Error] = [:]

    func startLink(institution: BankInstitution) async throws -> BankLinkStart { try startResult.get() }
    func link(id: String) async throws -> BankLink { try linkResult.get() }
    func deleteLink(id: String) async throws {
        deleteRequests.append(id)
        if let deleteError { throw deleteError }
    }
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        balanceRequests.append((accountUID, attended))
        return try balancesResult.get()
    }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        transactionQueries.append(query)
        if let error = transactionErrors[query.continuationKey] { throw error }
        let pages = transactionPagesByAccount[accountUID] ?? transactionPages
        return pages[query.continuationKey] ?? BankTransactionsPage(transactions: [], continuationKey: nil)
    }
}

@MainActor
final class BankSyncServiceTests: XCTestCase {
    func testStressBankEvidenceExercisesEveryFinancialHealthAdviceBranch() async throws {
        let state = try TestFixtures.makeAppState(seeded: false, gateway: StubBankGatewayClient(stressesFinancialHealth: true))
        let accounts = await state.bankSync.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }
        XCTAssertEqual(accounts.count, 1)
        let summary = state.monthlyFinancialSummary(for: Date())
        XCTAssertEqual(summary.totalEstimatedIncome, 1200)
        XCTAssertEqual(summary.totalExpenses, 1450)
        for component in state.financialHealthScore().components {
            XCTAssertNotNil(component.measured, component.kind.rawValue)
            XCTAssertGreaterThan(try XCTUnwrap(component.leverAmount), 0, component.kind.rawValue)
        }
    }

    func testBackgroundRefreshUsesUnattendedBankRequests() async throws {
        let gateway = ScriptedGateway()
        let (service, store, _) = try makeService(gateway: gateway)
        let accounts = try store.saveExternalAccounts([TestFixtures.linkedAccount()])
        await service.refreshIfStale(accounts, maxAge: BankRefreshPolicy.staleAfter, attended: false)
        XCTAssertEqual(gateway.balanceRequests.map(\.attended), [false])
        XCTAssertEqual(service.phase, .idle)
    }

    func testBackgroundExpirationCanCancelWorkOffMainActor() async {
        let work = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
        }
        let cancel = BankBackgroundRefresh.cancellationHandler(for: work)
        await Task.detached { cancel() }.value
        await work.value
        XCTAssertTrue(work.isCancelled)
    }

    func testFreshAccountDoesNotPreventRefreshingStaleAndNeverSyncedAccounts() async throws {
        let gateway = ScriptedGateway()
        let (service, store, _) = try makeService(gateway: gateway)
        let accounts = try store.saveExternalAccounts([
            TestFixtures.linkedAccount(stableIdentifier: "fresh"),
            TestFixtures.linkedAccount(stableIdentifier: "stale"),
            TestFixtures.linkedAccount(stableIdentifier: "new"),
        ])
        try store.updateExternalAccountBalance(accounts[0], balance: 10, balanceType: nil, balanceDate: nil, syncedAt: syncDate)
        try store.updateExternalAccountBalance(accounts[1], balance: 10, balanceType: nil, balanceDate: nil, syncedAt: syncDate.addingTimeInterval(-7200))
        await service.refreshIfStale(accounts, maxAge: 3600)
        XCTAssertEqual(Set(gateway.balanceRequests.map(\.uid)), ["uid-stale", "uid-new"])
        XCTAssertEqual(accounts[1].lastSyncedAt, syncDate)
        XCTAssertEqual(accounts[2].lastSyncedAt, syncDate)
    }

    private let syncDate = Date(timeIntervalSince1970: 1_789_371_262)

    private func makeService(gateway: any BankGatewayClient) throws -> (BankSyncService, PeculeDataStore, () -> Int) {
        let dataStore = PeculeDataStore(container: try PeculeDataStore.makeInMemoryContainer())
        let service = BankSyncService(gateway: gateway, dataStore: dataStore, referenceDateProvider: { [syncDate] in syncDate })
        let counter = ChangeCounter()
        service.onDataChanged = { counter.count += 1 }
        return (service, dataStore, { counter.count })
    }

    func testFreshnessStatesUseSyncEvidenceInsteadOfLatestTransactionDate() throws {
        let freshness = BankFreshnessService()
        let account = TestFixtures.linkedAccount()
        let progress = BankImportProgress(
            initialImportCompleted: true,
            pendingWindowStart: nil,
            requestedHistoryStart: syncDate.addingTimeInterval(-365 * 86_400),
            lastAttemptAt: syncDate.addingTimeInterval(-60),
            lastFailedAt: nil
        )
        account.lastSyncedAt = syncDate.addingTimeInterval(-300)
        let current = freshness.status(account: account, progress: progress, transactions: [], now: syncDate)
        XCTAssertEqual(current.state, .current)
        XCTAssertEqual(current.lastSuccessfulAt, syncDate.addingTimeInterval(-300))
        XCTAssertEqual(current.lastAttemptAt, syncDate.addingTimeInterval(-60))
        XCTAssertNil(current.lastReceivedAt, "an empty bank history can still have a successful, current sync")

        account.lastSyncedAt = syncDate.addingTimeInterval(-BankFreshnessService.staleAfter)
        XCTAssertEqual(freshness.status(account: account, progress: progress, transactions: [], now: syncDate).state, .stale)

        account.lastSyncedAt = syncDate.addingTimeInterval(-300)
        let unverified = BankImportProgress(initialImportCompleted: false, pendingWindowStart: nil, requestedHistoryStart: nil, lastAttemptAt: nil, lastFailedAt: nil)
        XCTAssertEqual(freshness.status(account: account, progress: unverified, transactions: [], now: syncDate).state, .unverified)
    }

    func testFreshnessPrioritizesSelectionSyncReconnectPartialAndFailureStates() {
        let freshness = BankFreshnessService()
        let account = TestFixtures.linkedAccount()
        let completed = BankImportProgress(initialImportCompleted: true, pendingWindowStart: nil, requestedHistoryStart: nil, lastAttemptAt: nil, lastFailedAt: nil)

        account.requiresInclusionReview = true
        XCTAssertEqual(freshness.status(account: account, progress: completed, transactions: [], now: syncDate, isSyncing: true).state, .awaitingSelection)

        account.requiresInclusionReview = false
        XCTAssertEqual(freshness.status(account: account, progress: completed, transactions: [], now: syncDate, isSyncing: true).state, .syncing)

        account.status = ExternalAccountStatus.needsReconnect.rawValue
        XCTAssertEqual(freshness.status(account: account, progress: completed, transactions: [], now: syncDate).state, .needsReconnect)

        account.status = ExternalAccountStatus.active.rawValue
        let partial = BankImportProgress(initialImportCompleted: false, pendingWindowStart: syncDate.addingTimeInterval(-86_400), requestedHistoryStart: nil, lastAttemptAt: syncDate, lastFailedAt: nil)
        XCTAssertEqual(freshness.status(account: account, progress: partial, transactions: [], now: syncDate).state, .partial)

        account.lastSyncError = "offline"
        XCTAssertEqual(freshness.status(account: account, progress: completed, transactions: [], now: syncDate).state, .failed)

        account.lastSyncError = nil
        XCTAssertEqual(freshness.status(account: account, progress: completed, transactions: [], now: syncDate).state, .notSynced)

        let manual = ExternalAccount(manualName: "Espèces", balance: 20)
        XCTAssertEqual(freshness.status(account: manual, progress: nil, transactions: [], now: syncDate, isSyncing: true).state, .manual)
    }

    func testFreshnessCoverageIgnoresWithdrawnAndOtherAccountTransactions() {
        let freshness = BankFreshnessService()
        let account = TestFixtures.linkedAccount()
        let other = TestFixtures.linkedAccount(stableIdentifier: "other")
        let first = TestFixtures.transaction(account: account, reference: "first", amount: 10, direction: .debit, dayOffset: -30)
        let last = TestFixtures.transaction(account: account, reference: "last", amount: 12, direction: .debit, dayOffset: -2)
        let withdrawn = TestFixtures.transaction(account: account, reference: "withdrawn", amount: 14, direction: .debit, dayOffset: -90)
        withdrawn.isAbsentFromBank = true
        let unrelated = TestFixtures.transaction(account: other, reference: "unrelated", amount: 16, direction: .debit, dayOffset: 0)

        let status = freshness.status(account: account, progress: nil, transactions: [withdrawn, unrelated, last, first], now: syncDate)

        XCTAssertEqual(status.firstReceivedAt, first.bookingDate)
        XCTAssertEqual(status.lastReceivedAt, last.bookingDate)
    }

    func testSyncAttemptAndFailureDatesPersistIndependently() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let attemptedAt = syncDate.addingTimeInterval(-120)
        let failedAt = syncDate.addingTimeInterval(-60)

        try store.recordBankSyncAttempt(accountID: account.id, at: attemptedAt)
        try store.recordBankSyncAttempt(accountID: account.id, at: failedAt, failed: true)

        let progress = try XCTUnwrap(try store.bankImportProgress()[account.id])
        XCTAssertEqual(progress.lastAttemptAt, attemptedAt)
        XCTAssertEqual(progress.lastFailedAt, failedAt)
    }

    func testConnectionCanDeferSyncUntilEveryNewAccountIsReviewed() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)

        let accounts = await service.linkAccount(institution: .boursorama, syncImmediately: false) { _ in
            URL(string: "lifeos://link/done?linkId=link-1")!
        }

        XCTAssertEqual(accounts.count, 2)
        XCTAssertTrue(accounts.allSatisfy(\.requiresInclusionReview))
        XCTAssertTrue(gateway.balanceRequests.isEmpty)
        XCTAssertTrue(gateway.transactionQueries.isEmpty)
        XCTAssertNil(service.pendingLink)

        try dataStore.confirmAccountSelection([accounts[0].id: true, accounts[1].id: false])
        XCTAssertFalse(accounts[0].requiresInclusionReview)
        XCTAssertFalse(accounts[1].requiresInclusionReview)
        XCTAssertTrue(accounts[0].isIncludedInTotals)
        XCTAssertFalse(accounts[1].isIncludedInTotals)

        await service.refresh(accounts, attended: true)
        XCTAssertEqual(gateway.balanceRequests.map(\.uid), ["uid-1", "uid-2"])
        XCTAssertEqual(accounts.map(\.lastSyncedAt), [syncDate, syncDate])
        XCTAssertEqual(service.lastSyncDate, syncDate)
    }

    func testLinkAccountWithStubCompletesWithoutWebAuthentication() async throws {
        let (service, dataStore, changes) = try makeService(gateway: StubBankGatewayClient())

        let accounts = await service.linkAccount(institution: .mock) { _ in
            XCTFail("the stub callback must bypass web authentication")
            throw BankLinkError.cancelled
        }

        XCTAssertEqual(accounts.count, 1)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.stableIdentifier, StubBankGatewayClient.accountIdentificationHash)
        XCTAssertEqual(account.currentUID, StubBankGatewayClient.accountUID)
        XCTAssertEqual(account.balance, Decimal(string: "53.51"))
        XCTAssertEqual(account.balanceType, "CLBD")
        XCTAssertEqual(account.lastSyncedAt, syncDate)
        XCTAssertEqual(account.consentValidUntil, StubBankGatewayClient.consentValidUntil)
        XCTAssertEqual(account.normalizedStatus, .active)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.lastSyncDate, syncDate)
        XCTAssertEqual(changes(), 2)
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.count, 1)
    }

    func testLinkAccountUsesWebAuthenticationAndSavesEveryAccount() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let presented = ChangeCounter()

        let accounts = await service.linkAccount(institution: .boursorama) { url in
            presented.count += 1
            XCTAssertEqual(url.absoluteString, "https://bank.test/authorize")
            return URL(string: "lifeos://link/done?linkId=link-1")!
        }

        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(accounts.map(\.stableIdentifier), ["hash-1", "uid-2"])
        XCTAssertEqual(accounts[0].maskedIBAN, "FR76…0189")
        XCTAssertEqual(accounts[0].institution, "boursorama")
        XCTAssertEqual(accounts[1].name, BankInstitution.boursorama.displayName())
        XCTAssertEqual(accounts[1].currencyCode, "EUR")
        XCTAssertTrue(accounts[0].isIncludedInTotals)
        XCTAssertFalse(accounts[1].isIncludedInTotals, "card mirrors are excluded from totals by default")
        XCTAssertEqual(accounts.map(\.balance), [Decimal(10), Decimal(10)], "XPCD (real-time) wins over CLBD")
        XCTAssertEqual(gateway.balanceRequests.map(\.attended), [true, true])
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.count, 2)
    }

    func testLinkAccountReportsBankRefusalAndSavesNothing() async throws {
        let (service, dataStore, changes) = try makeService(gateway: ScriptedGateway())

        let accounts = await service.linkAccount(institution: .revolut) { _ in
            URL(string: "lifeos://link/error?linkId=link-1&code=access_denied")!
        }

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(service.errorMessage, BankSyncService.message(for: BankLinkError.refused(code: "access_denied")))
        XCTAssertFalse(service.errorMessage?.contains("access_denied") ?? true, "the bank code never reaches the screen")
        XCTAssertEqual(changes(), 0)
        XCTAssertTrue(try dataStore.loadSnapshot().externalAccounts.isEmpty)
    }

    func testLinkAccountIsSilentWhenUserCancels() async throws {
        let (service, _, changes) = try makeService(gateway: ScriptedGateway())

        let accounts = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(changes(), 0)
        XCTAssertEqual(service.phase, .idle)
    }

    func testLinkAccountRejectsUnauthorizedLinks() async throws {
        let gateway = ScriptedGateway()
        gateway.linkResult = .success(
            BankLink(id: "link-1", status: .pending, aspsp: BankAspsp(name: "x", country: "FR"), validUntil: nil, errorCode: nil, accounts: [])
        )
        let (service, _, _) = try makeService(gateway: gateway)

        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(service.errorMessage, BankSyncService.message(for: BankLinkError.notAuthorized(.pending)))
    }

    func testLinkAccountImportsTransactionsFromTheStub() async throws {
        let (service, dataStore, _) = try makeService(gateway: StubBankGatewayClient())

        _ = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }

        let transactions = try dataStore.loadSnapshot().bankTransactions
        XCTAssertEqual(transactions.count, 4)
        XCTAssertEqual(transactions.filter(\.isExpense).map(\.amount).reduce(0, +), Decimal(string: "50.19"))
        XCTAssertEqual(transactions.filter(\.isIncome).map(\.amount).reduce(0, +), Decimal(string: "1204.49"))
    }

    func testRefreshImportsIncrementallyWithOverlapAndPagination() async throws {
        let gateway = ScriptedGateway()
        let day = { (offset: Int) in BankGatewayDateParser.parseDay(BankGatewayJSON.dayString(from: Date(timeIntervalSince1970: 1_789_371_262).addingTimeInterval(TimeInterval(offset) * 86_400)))! }
        let dto = { (reference: String, offset: Int) in
            BankTransactionDTO(entryReference: reference, amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(offset), creditorName: "Shop")
        }
        gateway.transactionPages = [
            nil: BankTransactionsPage(transactions: [dto("a", -1), dto("b", -30)], continuationKey: "page2"),
            "page2": BankTransactionsPage(transactions: [dto("c", -60)], continuationKey: nil),
        ]
        let (service, dataStore, _) = try makeService(gateway: gateway)

        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        XCTAssertEqual(accounts.count, 2)

        let initialQueries = gateway.transactionQueries.filter { $0.continuationKey == nil }
        XCTAssertEqual(initialQueries.count, 2, "one initial query per account")
        XCTAssertEqual(initialQueries.first?.strategy, "longest")
        XCTAssertEqual(initialQueries.first?.dateFrom.map(BankGatewayJSON.dayString), BankGatewayJSON.dayString(from: day(-365)))
        XCTAssertEqual(gateway.transactionQueries.filter { $0.continuationKey == "page2" }.count, 2)
        XCTAssertEqual(try dataStore.loadSnapshot().bankTransactions.count, 6)

        gateway.transactionQueries = []
        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [dto("a", -1), dto("d", 0)], continuationKey: nil)]
        await service.refresh(accounts, attended: true)

        let incremental = try XCTUnwrap(gateway.transactionQueries.first)
        XCTAssertNil(incremental.strategy)
        XCTAssertNil(incremental.continuationKey)
        XCTAssertEqual(incremental.dateFrom.map(BankGatewayJSON.dayString), BankGatewayJSON.dayString(from: day(-8)), "latest booking (-1 day) minus the 7-day overlap")
        XCTAssertEqual(try dataStore.loadSnapshot().bankTransactions.count, 8, "'a' is deduplicated, 'd' is new, for both accounts")
        XCTAssertNil(service.errorMessage)
    }

    func testRefreshPrunesTransactionsTheBankNoLongerReturns() async throws {
        let gateway = ScriptedGateway()
        let day = { (offset: Int) in BankGatewayDateParser.parseDay(BankGatewayJSON.dayString(from: Date(timeIntervalSince1970: 1_789_371_262).addingTimeInterval(TimeInterval(offset) * 86_400)))! }
        let dto = { (reference: String, offset: Int) in
            BankTransactionDTO(entryReference: reference, amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(offset), creditorName: "Shop")
        }
        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [dto("recent", -1), dto("old", -200)], continuationKey: nil)]
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        XCTAssertEqual(try dataStore.loadSnapshot().bankTransactions.count, 4)

        // Incremental window starts at latest (-1 day) minus 7 days: "recent" vanished, "old" is outside the window.
        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [dto("newer", 0)], continuationKey: nil)]
        await service.refresh(accounts, attended: true)
        var ids = Set(try dataStore.loadSnapshot().bankTransactions.filter { $0.accountID == accounts[0].id }.map(\.externalID))
        XCTAssertEqual(ids, ["hash-1#old", "hash-1#newer"])

        // An incomplete window (continuation never resolves, page cap reached) must not prune anything.
        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [], continuationKey: "loop"), "loop": BankTransactionsPage(transactions: [], continuationKey: "loop")]
        await service.refresh(accounts, attended: true)
        ids = Set(try dataStore.loadSnapshot().bankTransactions.filter { $0.accountID == accounts[0].id }.map(\.externalID))
        XCTAssertEqual(ids, ["hash-1#old", "hash-1#newer"])
        XCTAssertEqual(gateway.transactionQueries.filter { $0.continuationKey == "loop" }.count, (BankSyncService.maxTransactionPages - 1) * 2)
    }

    func testRefreshMarksExpiredSessionsForReconnection() async throws {
        let gateway = StubBankGatewayClient()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }
        gateway.failNextCalls(with: .sessionExpired)

        await service.refresh(accounts, attended: false)

        let account = try XCTUnwrap(try dataStore.loadSnapshot().externalAccounts.first)
        XCTAssertEqual(account.normalizedStatus, .needsReconnect)
        XCTAssertEqual(account.lastSyncError, "session_expired")
        XCTAssertEqual(account.balance, Decimal(string: "53.51"), "the cached balance survives a failed refresh")
        XCTAssertEqual(service.errorMessage, BankSyncService.message(for: BankGatewayError.sessionExpired))
        XCTAssertTrue(service.errorOffersReconnect, "an expired consent is cured by a reconnection: the alert offers it")
        service.errorMessage = nil
        XCTAssertFalse(service.errorOffersReconnect, "dismissing the alert clears the offer")
    }

    func testRefreshTreatsAMissingBankAccountAsALostLink() async throws {
        let gateway = StubBankGatewayClient()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }
        gateway.failNextCalls(with: .upstream(status: 404, code: "ACCOUNT_DOES_NOT_EXIST"))

        await service.refresh(accounts, attended: true)

        let account = try XCTUnwrap(try dataStore.loadSnapshot().externalAccounts.first)
        XCTAssertEqual(account.normalizedStatus, .needsReconnect)
        XCTAssertTrue(service.errorOffersReconnect)
        XCTAssertFalse(service.errorMessage?.contains("ACCOUNT_DOES_NOT_EXIST") ?? true, "the API code never reaches the screen")
        XCTAssertFalse(service.errorMessage?.contains("404") ?? true)
    }

    func testRefreshRecoversStatusAfterSuccess() async throws {
        let gateway = StubBankGatewayClient()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }
        gateway.failNextCalls(with: .rateLimited(retryAfterSeconds: 10))
        await service.refresh(accounts, attended: true)
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.first?.normalizedStatus, .error)

        gateway.failNextCalls(with: nil)
        service.errorMessage = nil
        await service.refresh(accounts, attended: true)

        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.first?.normalizedStatus, .active)
        XCTAssertNil(service.errorMessage)
    }

    func testUnlinkDeletesLocallyEvenWhenTheLinkIsAlreadyGoneRemotely() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        // The first account still has a sibling on the link: the server is not asked anything.
        let first = await service.unlink(accounts[0])
        XCTAssertTrue(first)
        // The last account of the link revokes it; "already gone" is not a reason to keep the local copy.
        gateway.deleteError = BankGatewayError.linkNotFound

        let removed = await service.unlink(accounts[1])

        XCTAssertTrue(removed)
        XCTAssertNil(service.errorMessage)
        XCTAssertTrue(try dataStore.loadSnapshot().externalAccounts.isEmpty)
        XCTAssertEqual(gateway.deleteRequests, ["link-1"])
    }

    func testUnlinkKeepsTheLastAccountWhenItsConsentCannotBeRevoked() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        let first = await service.unlink(accounts[0])
        XCTAssertTrue(first)
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.map(\.stableIdentifier), ["uid-2"])

        gateway.deleteError = BankGatewayError.transport("offline")
        let removedOffline = await service.unlink(accounts[1])

        XCTAssertFalse(removedOffline)
        XCTAssertEqual(service.errorMessage, BankSyncService.message(for: BankGatewayError.transport("offline")))
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.count, 1, "an account whose consent is still active is never dropped locally")
    }

    // M013: a link is one consent carrying every account the customer authorized. Unlinking one account must not
    // revoke it for its siblings; only the last account of the link revokes it.
    func testUnlinkingOneAccountOfASharedLinkKeepsTheConsentAndTheSiblingSynchronizing() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        XCTAssertEqual(accounts.map(\.linkID), ["link-1", "link-1"])
        let sibling = accounts[1]

        let removed = await service.unlink(accounts[0])

        XCTAssertTrue(removed)
        XCTAssertEqual(gateway.deleteRequests, [], "the consent still covers the second account")
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.map(\.stableIdentifier), ["uid-2"])

        gateway.balanceRequests = []
        await service.refresh([sibling], attended: true)
        XCTAssertEqual(gateway.balanceRequests.map(\.uid), ["uid-2"], "the sibling is still synchronized")
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(sibling.normalizedStatus, .active)

        let removedLast = await service.unlink(sibling)
        XCTAssertTrue(removedLast)
        XCTAssertEqual(gateway.deleteRequests, ["link-1"], "the last account of the link revokes the consent")
        XCTAssertTrue(try dataStore.loadSnapshot().externalAccounts.isEmpty)
    }

    func testAnAccountAloneOnItsLinkRevokesTheConsentAndAManualAccountNeverDoes() async throws {
        let gateway = ScriptedGateway()
        gateway.linkResult = .success(
            BankLink(id: "link-1", status: .authorized, aspsp: BankAspsp(name: "Mock ASPSP", country: "FR"), validUntil: .distantFuture, errorCode: nil, accounts: [
                BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: nil, name: "Courant", currency: "EUR", product: nil, cashAccountType: "CACC", usage: "PRIV"),
            ])
        )
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        let manual = try dataStore.addManualAccount(name: "Livret", balance: 10)
        XCTAssertEqual(try dataStore.linkSiblings(of: accounts[0]).count, 0, "a manual account carries no consent")

        let manualRemoved = await service.unlink(manual)
        XCTAssertTrue(manualRemoved)
        XCTAssertEqual(gateway.deleteRequests, [])

        let removed = await service.unlink(accounts[0])
        XCTAssertTrue(removed)
        XCTAssertEqual(gateway.deleteRequests, ["link-1"])
    }

    // The same rule backs the confirmation sentence: it announces a revocation only for the last account of a link.
    func testSharesLinkIgnoresManualAccountsAndOtherLinks() throws {
        let store = try TestFixtures.makeDataStore()
        let first = TestFixtures.linkedAccount(stableIdentifier: "a"), second = TestFixtures.linkedAccount(stableIdentifier: "b")
        second.linkID = first.linkID
        let other = TestFixtures.linkedAccount(stableIdentifier: "c")
        let manual = try store.addManualAccount(name: "Livret", balance: 1)
        manual.linkID = first.linkID
        XCTAssertTrue(first.sharesLink(with: second))
        XCTAssertFalse(first.sharesLink(with: first))
        XCTAssertFalse(first.sharesLink(with: other))
        XCTAssertFalse(first.sharesLink(with: manual))
        XCTAssertFalse(manual.sharesLink(with: first))
    }

    func testExternalLinkCompletesWhenTheCallbackArrives() async throws {
        let gateway = ScriptedGateway()
        gateway.linkResult = .success(
            BankLink(id: "link-1", status: .pending, aspsp: BankAspsp(name: "x", country: "FR"), validUntil: nil, errorCode: nil, accounts: [])
        )
        let (service, dataStore, _) = try makeService(gateway: gateway)

        let url = await service.startExternalLink(institution: .boursorama)
        XCTAssertEqual(url?.absoluteString, "https://bank.test/authorize")
        XCTAssertEqual(service.pendingLink?.linkID, "link-1")

        _ = await service.completePendingLink()
        XCTAssertNotNil(service.pendingLink, "a still-pending link stays pending")
        XCTAssertEqual(service.errorMessage, AppLocalizer.string("bank.error.linkStillPending"))
        service.errorMessage = nil

        await service.handleIncomingURL(URL(string: "lifeos://link/done?linkId=other")!)
        XCTAssertNotNil(service.pendingLink, "callbacks for another link are ignored")

        gateway.linkResult = ScriptedGateway().linkResult
        await service.handleIncomingURL(URL(string: "https://not-a-callback.test")!)
        XCTAssertNotNil(service.pendingLink)
        await service.handleIncomingURL(URL(string: "lifeos://link/done?linkId=link-1")!)

        XCTAssertNil(service.pendingLink)
        XCTAssertNil(service.errorMessage)
        let accounts = try dataStore.loadSnapshot().externalAccounts
        XCTAssertEqual(accounts.map(\.institution), ["boursorama", "boursorama"])
        XCTAssertEqual(accounts.first?.balance, Decimal(10))
    }

    func testExternalLinkIsDroppedWhenTheBankRefuses() async throws {
        let (service, dataStore, _) = try makeService(gateway: ScriptedGateway())
        _ = await service.startExternalLink(institution: .mock)

        await service.handleIncomingURL(URL(string: "lifeos://link/error?linkId=link-1&code=access_denied")!)

        XCTAssertNil(service.pendingLink)
        XCTAssertFalse(service.errorMessage?.contains("access_denied") ?? true, "the bank code never reaches the screen")
        XCTAssertTrue(try dataStore.loadSnapshot().externalAccounts.isEmpty)

        _ = await service.startExternalLink(institution: .mock)
        service.cancelPendingLink()
        XCTAssertNil(service.pendingLink)
        let leftover = await service.completePendingLink()
        XCTAssertTrue(leftover.isEmpty)
    }

    func testManualAccountsAreNeverSyncedAndUnlinkLocallyOnly() async throws {
        let gateway = ScriptedGateway()
        gateway.deleteError = BankGatewayError.transport("must not be called")
        let (service, dataStore, changes) = try makeService(gateway: gateway)
        let manual = try dataStore.addManualAccount(name: "Livret", balance: 383)

        await service.refresh([manual], attended: true)
        XCTAssertTrue(gateway.balanceRequests.isEmpty)
        XCTAssertTrue(gateway.transactionQueries.isEmpty)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(try dataStore.loadSnapshot().externalAccounts.first?.balance, 383)

        let removed = await service.unlink(manual)
        XCTAssertTrue(removed)
        XCTAssertNil(service.errorMessage)
        XCTAssertTrue(try dataStore.loadSnapshot().externalAccounts.isEmpty)
        XCTAssertEqual(changes(), 2)
    }

    func testImportCategorizesTransactionsFromTheStub() async throws {
        let (service, dataStore, _) = try makeService(gateway: StubBankGatewayClient())

        _ = await service.linkAccount(institution: .mock) { _ in throw BankLinkError.cancelled }

        let byReference = Dictionary(uniqueKeysWithValues: try dataStore.loadSnapshot().bankTransactions.map { ($0.externalID.split(separator: "#").last.map(String.init) ?? "", $0.category) })
        XCTAssertEqual(byReference["q7m2a"], ExpenseCategory.groceries.storageValue, "CB CARREFOUR")
        XCTAssertEqual(byReference["s1p9k"], ExpenseCategory.other.storageValue, "SALAIRE")
        XCTAssertEqual(byReference["dkx1z"], ExpenseCategory.other.storageValue)
    }

    func testSyncMarksInternalTransfersByAmountPairingAndByIBAN() async throws {
        let gateway = ScriptedGateway()
        let day = { (offset: Int) in BankGatewayDateParser.parseDay(BankGatewayJSON.dayString(from: Date(timeIntervalSince1970: 1_789_371_262).addingTimeInterval(TimeInterval(offset) * 86_400)))! }
        gateway.transactionPagesByAccount = [
            "uid-1": [nil: BankTransactionsPage(transactions: [
                BankTransactionDTO(entryReference: "out", amount: 150, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-2), creditorName: "Camille Durand", remittanceInformation: ["VIR INST Revolut"]),
                BankTransactionDTO(entryReference: "shop", amount: 42, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-2), creditorName: "Carrefour"),
                BankTransactionDTO(entryReference: "iban-out", amount: 20, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-30), creditorName: "Moi", creditorAccountIBAN: "FR7611111111111111111111111"),
            ], continuationKey: nil)],
            "uid-2": [nil: BankTransactionsPage(transactions: [
                BankTransactionDTO(entryReference: "in", amount: 150, currency: "EUR", creditDebitIndicator: .credit, bookingDate: day(-1), debtorName: "DURAND CAMILLE"),
            ], continuationKey: nil)],
        ]
        gateway.linkResult = .success(
            BankLink(
                id: "link-1",
                status: .authorized,
                aspsp: BankAspsp(name: "Boursorama Banque", country: "FR"),
                validUntil: .distantFuture,
                errorCode: nil,
                accounts: [
                    BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: "FR7612345123451234567890146", name: "CAV", currency: "EUR", product: nil, cashAccountType: "CACC", usage: "PRIV"),
                    BankLinkAccount(uid: "uid-2", identificationHash: "hash-2", iban: "FR7611111111111111111111111", name: "Revolut", currency: "EUR", product: nil, cashAccountType: "CACC", usage: "PRIV"),
                ]
            )
        )
        let (service, dataStore, _) = try makeService(gateway: gateway)

        _ = await service.linkAccount(institution: .boursorama) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let transactions = Dictionary(uniqueKeysWithValues: try dataStore.loadSnapshot().bankTransactions.map { ($0.externalID, $0) })
        XCTAssertEqual(transactions["hash-1#out"]?.isInternalTransfer, true)
        XCTAssertEqual(transactions["hash-2#in"]?.isInternalTransfer, true)
        XCTAssertEqual(transactions["hash-1#shop"]?.isInternalTransfer, false)
        XCTAssertEqual(transactions["hash-1#iban-out"]?.isInternalTransfer, true, "counterparty IBAN belongs to another linked account")
        XCTAssertEqual(transactions["hash-1#shop"]?.category, ExpenseCategory.groceries.storageValue)
        XCTAssertFalse(try XCTUnwrap(transactions["hash-1#out"]).isExpense)
        XCTAssertFalse(try XCTUnwrap(transactions["hash-2#in"]).isIncome)
    }

    func testRefreshIfStaleOnlySyncsWhenTheLastSyncIsOld() async throws {
        let gateway = ScriptedGateway()
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        let requestsAfterLink = gateway.balanceRequests.count

        await service.refreshIfStale(accounts, maxAge: 3600)
        XCTAssertEqual(gateway.balanceRequests.count, requestsAfterLink, "synced seconds ago: nothing to do")

        try dataStore.updateExternalAccountBalance(accounts[0], balance: 1, balanceType: "CLBD", balanceDate: nil, syncedAt: syncDate.addingTimeInterval(-7200))
        try dataStore.updateExternalAccountBalance(accounts[1], balance: 1, balanceType: "CLBD", balanceDate: nil, syncedAt: syncDate.addingTimeInterval(-7200))
        await service.refreshIfStale(accounts, maxAge: 3600)
        XCTAssertEqual(gateway.balanceRequests.count, requestsAfterLink + 2)

        let manual = try dataStore.addManualAccount(name: "Livret", balance: 1)
        await service.refreshIfStale([manual], maxAge: 0)
        XCTAssertEqual(gateway.balanceRequests.count, requestsAfterLink + 2, "manual accounts never trigger a sync")
    }

    func testSyncLinksSettledSubscriptionsAndSalariesAndAdvancesBillingDates() async throws {
        let gateway = ScriptedGateway()
        let day = { (offset: Int) in TestFixtures.day(offset: offset, from: Date(timeIntervalSince1970: 1_789_371_262)) }
        gateway.transactionPagesByAccount = [
            "uid-1": [nil: BankTransactionsPage(transactions: [
                BankTransactionDTO(entryReference: "netflix", amount: TestFixtures.decimal("15.99"), currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-1), creditorName: "NETFLIX.COM", remittanceInformation: ["PRLV NETFLIX"]),
                BankTransactionDTO(entryReference: "salary", amount: 1500, currency: "EUR", creditDebitIndicator: .credit, bookingDate: day(-2), debtorName: "ACME SAS", remittanceInformation: ["VIR SALAIRE"]),
                BankTransactionDTO(entryReference: "coffee", amount: TestFixtures.decimal("2.10"), currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-1), creditorName: "CAFE"),
            ], continuationKey: nil)],
        ]
        gateway.linkResult = .success(
            BankLink(id: "link-1", status: .authorized, aspsp: BankAspsp(name: "x", country: "FR"), validUntil: .distantFuture, errorCode: nil, accounts: [
                BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: nil, name: "CAV", currency: "EUR", product: nil, cashAccountType: "CACC", usage: nil),
            ])
        )
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let netflix = Subscription(name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, category: .subscriptions, nextBillingDate: day(1), isActive: true)
        let salary = IncomeSource(name: "Salaire ACME", amount: 1500, type: .salary, startDate: day(-400), isRecurring: true, isActive: true)
        try dataStore.addSubscription(name: netflix.name, amount: netflix.amount, billingCycle: netflix.billingCycle, category: netflix.category, nextBillingDate: netflix.nextBillingDate, isActive: true)
        try dataStore.addIncomeSource(name: salary.name, amount: salary.amount, type: salary.type, startDate: salary.startDate, endDate: nil, isRecurring: true, isActive: true)

        _ = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let snapshot = try dataStore.loadSnapshot()
        let byRef = Dictionary(uniqueKeysWithValues: snapshot.bankTransactions.map { ($0.externalID, $0) })
        let storedNetflix = try XCTUnwrap(snapshot.subscriptions.first { $0.name == "Netflix" })
        let storedSalary = try XCTUnwrap(snapshot.incomeSources.first { $0.name == "Salaire ACME" })
        XCTAssertEqual(byRef["hash-1#netflix"]?.link, .subscription(storedNetflix.id))
        XCTAssertEqual(byRef["hash-1#salary"]?.link, .income(storedSalary.id))
        XCTAssertNil(byRef["hash-1#coffee"]?.link)
        XCTAssertGreaterThan(storedNetflix.nextBillingDate, day(1), "the settled cycle advances the next billing date")
        XCTAssertLessThanOrEqual(storedNetflix.nextBillingDate, day(32))

        await service.refresh(snapshot.externalAccounts, attended: true)
        XCTAssertEqual(try dataStore.loadSnapshot().bankTransactions.filter(\.isLinked).count, 2, "re-syncing never links twice")
    }

    // MARK: reconciliation through the synchronization (M017, m087, m088)

    private func singleAccountGateway(_ transactions: [BankTransactionDTO]) -> ScriptedGateway {
        let gateway = ScriptedGateway()
        gateway.transactionPagesByAccount = ["uid-1": [nil: BankTransactionsPage(transactions: transactions, continuationKey: nil)]]
        gateway.linkResult = .success(
            BankLink(id: "link-1", status: .authorized, aspsp: BankAspsp(name: "x", country: "FR"), validUntil: .distantFuture, errorCode: nil, accounts: [
                BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: nil, name: "CAV", currency: "EUR", product: nil, cashAccountType: "CACC", usage: nil),
            ])
        )
        return gateway
    }

    private func netflixDebit(_ reference: String, on date: Date, label: String = "PRLV NETFLIX", creditor: String = "NETFLIX.COM") -> BankTransactionDTO {
        BankTransactionDTO(entryReference: reference, amount: TestFixtures.decimal("15.99"), currency: "EUR", creditDebitIndicator: .debit, bookingDate: date, creditorName: creditor, remittanceInformation: [label])
    }

    func testSyncNeverLinksAnUnrelatedDebitNearADueDateNorAdvancesTheDate() async throws {
        let day = { (offset: Int) in TestFixtures.day(offset: offset, from: self.syncDate) }
        let gateway = singleAccountGateway([
            BankTransactionDTO(entryReference: "bakery", amount: TestFixtures.decimal("15.99"), currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-2), creditorName: "BOULANGERIE PAUL", remittanceInformation: ["CB BOULANGERIE PAUL"]),
            BankTransactionDTO(entryReference: "atm", amount: 50, currency: "EUR", creditDebitIndicator: .debit, bookingDate: day(-1), remittanceInformation: ["RETRAIT DAB PARIS"]),
        ])
        let (service, dataStore, _) = try makeService(gateway: gateway)
        try dataStore.addSubscription(name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, category: "Subscriptions", nextBillingDate: day(1), isActive: true)
        try dataStore.addSubscription(name: "Basic Fit", amount: 50, billingCycle: .monthly, category: "Health", nextBillingDate: day(0), isActive: true)

        _ = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let snapshot = try dataStore.loadSnapshot()
        XCTAssertEqual(snapshot.bankTransactions.count, 2)
        XCTAssertTrue(snapshot.bankTransactions.allSatisfy { !$0.isLinked }, "the amount and the date alone link nothing")
        XCTAssertEqual(Set(snapshot.subscriptions.map(\.nextBillingDate)), [day(1), day(0)], "without a link the due dates do not advance")
    }

    func testSyncLinksAnUnnamedDebitWhenItsCreditorIsDetectedAsRecurring() async throws {
        let day = { (offset: Int) in TestFixtures.day(offset: offset, from: self.syncDate) }
        let gateway = singleAccountGateway([-92, -61, -30, -2].map { netflixDebit("stream\($0)", on: day($0), label: "PRLV SEPA STREAMCO 4412", creditor: "STREAMCO SAS") })
        let (service, dataStore, _) = try makeService(gateway: gateway)
        try dataStore.addSubscription(name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, category: "Subscriptions", nextBillingDate: day(0), isActive: true)

        _ = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let snapshot = try dataStore.loadSnapshot()
        let linked = snapshot.bankTransactions.filter(\.isLinked)
        XCTAssertEqual(Set(linked.map(\.externalID)), ["hash-1#stream-30", "hash-1#stream-2"], "each cycle of the recurring charge in the window is settled once")
        let storedNetflix = try XCTUnwrap(snapshot.subscriptions.first)
        XCTAssertGreaterThan(storedNetflix.nextBillingDate, day(-2))
        XCTAssertLessThanOrEqual(storedNetflix.nextBillingDate, day(31))
    }

    func testSyncCatchesUpABillingDateLeftThreeMonthsBehind() async throws {
        let day = { (offset: Int) in TestFixtures.day(offset: offset, from: self.syncDate) }
        let gateway = singleAccountGateway([netflixDebit("late", on: day(-2))])
        let (service, dataStore, _) = try makeService(gateway: gateway)
        let threeMonthsLate = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -3, to: day(0)))
        try dataStore.addSubscription(name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, category: "Subscriptions", nextBillingDate: threeMonthsLate, isActive: true)

        _ = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let snapshot = try dataStore.loadSnapshot()
        let storedNetflix = try XCTUnwrap(snapshot.subscriptions.first)
        XCTAssertEqual(snapshot.bankTransactions.first?.link, .subscription(storedNetflix.id))
        XCTAssertGreaterThan(storedNetflix.nextBillingDate, day(-2), "the date is brought to the first cycle after the operation")
        XCTAssertLessThanOrEqual(storedNetflix.nextBillingDate, day(31), "...and no further than one cycle")
    }

    func testASettledCycleStaysTakenAcrossSynchronizationsAndMonthBoundaries() async throws {
        let day = { (offset: Int) in TestFixtures.day(offset: offset, from: self.syncDate) }
        // Today is 14 September: day(-14) is 31 August, day(-13) is 1 September, day(-12) is 2 September.
        let august31 = netflixDebit("aug-31", on: day(-14)), september2 = netflixDebit("sep-02", on: day(-12))
        let gateway = singleAccountGateway([august31])
        let (service, dataStore, _) = try makeService(gateway: gateway)
        try dataStore.addSubscription(name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, category: "Subscriptions", nextBillingDate: day(-13), isActive: true)

        let accounts = await service.linkAccount(institution: .mock) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }
        let afterFirst = try dataStore.loadSnapshot()
        XCTAssertEqual(afterFirst.bankTransactions.filter(\.isLinked).map(\.externalID), ["hash-1#aug-31"])
        let advanced = try XCTUnwrap(afterFirst.subscriptions.first).nextBillingDate
        XCTAssertGreaterThan(advanced, day(-13))

        // The next synchronization brings a second 15,99 debit three days later, on the other side of the month boundary.
        gateway.transactionPagesByAccount = ["uid-1": [nil: BankTransactionsPage(transactions: [august31, september2], continuationKey: nil)]]
        await service.refresh(accounts, attended: true)

        let afterSecond = try dataStore.loadSnapshot()
        XCTAssertEqual(afterSecond.bankTransactions.count, 2)
        XCTAssertEqual(afterSecond.bankTransactions.filter(\.isLinked).map(\.externalID), ["hash-1#aug-31"], "the 2 September debit does not settle the same cycle again")
        XCTAssertEqual(try XCTUnwrap(afterSecond.subscriptions.first).nextBillingDate, advanced)
    }

    func testCallbackParsing() {
        XCTAssertEqual(BankLinkCallback(url: URL(string: "lifeos://link/done?linkId=abc")!), .done(linkID: "abc"))
        XCTAssertEqual(BankLinkCallback(url: URL(string: "lifeos://link/error?linkId=abc&code=access_denied")!), .error(code: "access_denied"))
        XCTAssertEqual(BankLinkCallback(url: URL(string: "lifeos://link/error")!), .error(code: "unknown"))
        XCTAssertNil(BankLinkCallback(url: URL(string: "lifeos://link/done")!))
        XCTAssertNil(BankLinkCallback(url: URL(string: "https://link/done?linkId=abc")!))
        XCTAssertNil(BankLinkCallback(url: URL(string: "lifeos://other/done?linkId=abc")!))
    }

    func testPreferredBalancePrefersRealTimeExpectedThenBooked() {
        let expected = BankBalance(name: "Balance temps réél", balanceType: "XPCD", amount: Decimal(string: "123.76")!, currency: "EUR")
        let booked = BankBalance(name: "Balance", balanceType: "CLBD", amount: Decimal(string: "222.97")!, currency: "EUR")
        let other = BankBalance(name: "Balance", balanceType: "OTHR", amount: 0, currency: "EUR")

        XCTAssertEqual(BankSyncService.preferredBalance(in: [booked, expected]), expected)
        XCTAssertEqual(BankSyncService.preferredBalance(in: [other, booked]), booked)
        XCTAssertEqual(BankSyncService.preferredBalance(in: [other]), other)
        XCTAssertNil(BankSyncService.preferredBalance(in: []))
    }

    func testCurrencyFallsBackToTheBalanceCurrencyWhenTheAccountReportsNone() async throws {
        let gateway = ScriptedGateway()
        gateway.linkResult = .success(
            BankLink(
                id: "link-1",
                status: .authorized,
                aspsp: BankAspsp(name: "Boursorama Banque", country: "FR"),
                validUntil: .distantFuture,
                errorCode: nil,
                accounts: [
                    BankLinkAccount(uid: "uid-1", identificationHash: "hash-1", iban: "FR7612345123451234567890146", name: "M DURAND CAMILLE", currency: "XXX", product: "CAV - BOURSOBANK", cashAccountType: "CACC", usage: "PRIV"),
                ]
            )
        )
        gateway.balancesResult = .success([
            BankBalance(name: "Balance", balanceType: "CLBD", amount: Decimal(string: "222.97")!, currency: "EUR"),
            BankBalance(name: "Balance temps réél", balanceType: "XPCD", amount: Decimal(string: "123.76")!, currency: "EUR"),
        ])
        let (service, dataStore, _) = try makeService(gateway: gateway)

        let accounts = await service.linkAccount(institution: .boursorama) { _ in URL(string: "lifeos://link/done?linkId=link-1")! }

        let account = try XCTUnwrap(try dataStore.loadSnapshot().externalAccounts.first)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(account.currencyCode, "EUR")
        XCTAssertEqual(account.balance, Decimal(string: "123.76"))
        XCTAssertEqual(account.balanceType, "XPCD")
        XCTAssertEqual(BankSyncService.normalizedCurrency(" eur "), "EUR")
        XCTAssertNil(BankSyncService.normalizedCurrency("XXX"))
        XCTAssertNil(BankSyncService.normalizedCurrency(nil))
        XCTAssertNil(BankSyncService.normalizedCurrency("EURO"))
    }
}

private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}
