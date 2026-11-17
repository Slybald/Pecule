import XCTest
@testable import Pecule

@MainActor
final class ExternalAccountStoreTests: XCTestCase {
    private func makeDataStore() throws -> PeculeDataStore {
        PeculeDataStore(container: try PeculeDataStore.makeInMemoryContainer())
    }

    private func makeAccount(stableIdentifier: String = "hash-1", name: String = "Compte courant", linkID: String = "link-1") -> ExternalAccount {
        ExternalAccount(
            stableIdentifier: stableIdentifier,
            currentUID: "uid-\(linkID)",
            linkID: linkID,
            institution: .mock,
            name: name,
            currencyCode: "EUR",
            consentValidUntil: StubBankGatewayClient.consentValidUntil
        )
    }

    // L'échantillon du stub est daté à partir de « aujourd'hui » : avec l'horloge réelle, son ordre et
    // ses fenêtres changeaient du 1er au 12 du mois. Date fixe (le 14, aucun décalage ne sort du mois),
    // la même que le « aujourd'hui » des assertions ci-dessous.
    private func sampleTransactions(for account: ExternalAccount) -> [BankTransaction] {
        StubBankGatewayClient.sampleTransactions(now: TestFixtures.referenceDate).compactMap {
            BankTransaction(dto: $0, accountID: account.id, accountStableIdentifier: account.stableIdentifier)
        }
    }

    func testSeededAppStateHasNoExternalDataAndKeepsSeedCounts() throws {
        let appState = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        XCTAssertEqual(appState.subscriptions.count, 4)
        XCTAssertEqual(appState.purchases.count, 4)
        XCTAssertTrue(appState.externalAccounts.isEmpty)
        XCTAssertTrue(appState.bankTransactions.isEmpty)
        XCTAssertTrue(appState.bankGateway is StubBankGatewayClient)
    }

    func testSaveExternalAccountsUpsertsByStableIdentifier() throws {
        let dataStore = try makeDataStore()

        let first = try dataStore.saveExternalAccounts([makeAccount(name: "Ancien nom")])
        let firstID = try XCTUnwrap(first.first?.id)
        let second = try dataStore.saveExternalAccounts([makeAccount(name: "Nouveau nom", linkID: "link-2")])

        let snapshot = try dataStore.loadSnapshot()
        XCTAssertEqual(snapshot.externalAccounts.count, 1)
        XCTAssertEqual(second.first?.id, firstID)
        XCTAssertEqual(snapshot.externalAccounts.first?.name, "Nouveau nom")
        XCTAssertEqual(snapshot.externalAccounts.first?.linkID, "link-2")
        XCTAssertEqual(snapshot.externalAccounts.first?.currentUID, "uid-link-2")
        XCTAssertEqual(snapshot.externalAccounts.first?.normalizedStatus, .active)
    }

    func testSaveExternalAccountsRekeysLegacyIBANIdentifiersAndTheirTransactions() throws {
        let dataStore = try makeDataStore()
        let iban = "FR7630006000011234567890189"
        let legacy = ExternalAccount(
            stableIdentifier: iban,
            currentUID: "uid-old",
            linkID: "link-old",
            institution: .boursorama,
            name: "CAV",
            maskedIBAN: ExternalAccount.maskedIBAN(from: iban),
            currencyCode: "EUR"
        )
        try dataStore.saveExternalAccounts([legacy])
        try dataStore.importBankTransactions([
            BankTransaction(externalID: "\(iban)#ref-1", accountID: legacy.id, amount: 5, direction: .debit, currencyCode: "EUR", bookingDate: Date(), label: "x"),
        ])

        let relinked = ExternalAccount(
            stableIdentifier: "lifeos-sha256:abc",
            currentUID: "uid-new",
            linkID: "link-new",
            institution: .boursorama,
            name: "CAV",
            maskedIBAN: "FR76…0189",
            currencyCode: "EUR"
        )
        let saved = try dataStore.saveExternalAccounts([relinked])

        let snapshot = try dataStore.loadSnapshot()
        XCTAssertEqual(saved.first?.id, legacy.id, "the existing account is kept, not recreated")
        XCTAssertEqual(snapshot.externalAccounts.map(\.stableIdentifier), ["lifeos-sha256:abc"])
        XCTAssertEqual(snapshot.externalAccounts.first?.currentUID, "uid-new")
        XCTAssertEqual(snapshot.bankTransactions.map(\.externalID), ["lifeos-sha256:abc#ref-1"])
        XCTAssertEqual(try dataStore.importBankTransactions([
            BankTransaction(externalID: "lifeos-sha256:abc#ref-1", accountID: legacy.id, amount: 5, direction: .debit, currencyCode: "EUR", bookingDate: Date(), label: "x"),
        ]), 0, "re-imports under the new key are deduplicated")
    }

    func testImportBankTransactionsIsIdempotentAndSortedNewestFirst() throws {
        let dataStore = try makeDataStore()
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)

        XCTAssertEqual(try dataStore.importBankTransactions(sampleTransactions(for: account)), 4)
        XCTAssertEqual(try dataStore.importBankTransactions(sampleTransactions(for: account)), 0)
        XCTAssertEqual(try dataStore.importBankTransactions([]), 0)

        let snapshot = try dataStore.loadSnapshot()
        XCTAssertEqual(snapshot.bankTransactions.count, 4)
        XCTAssertEqual(Set(snapshot.bankTransactions.prefix(2).map(\.externalID)), ["hash-1#dkx1z", "hash-1#eo28j"])
        XCTAssertEqual(snapshot.bankTransactions.map(\.bookingDate), snapshot.bankTransactions.map(\.bookingDate).sorted(by: >))
        XCTAssertEqual(snapshot.bankTransactions.last?.label, "SALAIRE")
        XCTAssertEqual(snapshot.bankTransactions.filter(\.isExpense).count, 2)
        XCTAssertEqual(snapshot.bankTransactions.filter(\.isIncome).count, 2)
    }

    func testImportRefreshesAmountAndStatusOfKnownTransactions() throws {
        let dataStore = try makeDataStore()
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        let original = try XCTUnwrap(sampleTransactions(for: account).first)
        let revisedDate = TestFixtures.date(2026, 9, 12)
        let purchaseID = UUID()
        original.category = ExpenseCategory.insurance.storageValue
        original.linkedPurchaseID = purchaseID
        try dataStore.importBankTransactions([original])

        let revised = BankTransaction(
            externalID: original.externalID,
            accountID: account.id,
            amount: Decimal(string: "9.99")!,
            direction: .debit,
            currencyCode: "EUR",
            bookingDate: revisedDate,
            valueDate: revisedDate,
            label: "Updated bank label",
            status: .pending
        )
        XCTAssertEqual(try dataStore.importBankTransactions([revised]), 0)

        let stored = try XCTUnwrap(try dataStore.loadSnapshot().bankTransactions.first)
        XCTAssertEqual(stored.amount, Decimal(string: "9.99"))
        XCTAssertEqual(stored.normalizedStatus, .pending)
        XCTAssertEqual(stored.valueDate, revisedDate)
        XCTAssertEqual(stored.bookingDate, revisedDate)
        XCTAssertEqual(stored.label, "Updated bank label")
        XCTAssertEqual(stored.category, ExpenseCategory.insurance.storageValue, "personal classification survives bank revisions")
        XCTAssertEqual(stored.linkedPurchaseID, purchaseID)
    }

    func testImportSkipsDuplicatesAcrossAccountsOnlyByExternalID() throws {
        let dataStore = try makeDataStore()
        let accounts = try dataStore.saveExternalAccounts([makeAccount(), makeAccount(stableIdentifier: "hash-2", name: "Livret")])

        XCTAssertEqual(try dataStore.importBankTransactions(sampleTransactions(for: accounts[0])), 4)
        XCTAssertEqual(try dataStore.importBankTransactions(sampleTransactions(for: accounts[1])), 4)
        XCTAssertEqual(try dataStore.loadSnapshot().bankTransactions.count, 8)
    }

    func testBalanceAndStatusUpdatesArePersisted() throws {
        let dataStore = try makeDataStore()
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        let syncedAt = Date(timeIntervalSince1970: 1_789_371_262)

        try dataStore.updateExternalAccountBalance(account, balance: Decimal(string: "53.514"), balanceType: "CLBD", balanceDate: nil, syncedAt: syncedAt)
        var reloaded = try XCTUnwrap(try dataStore.loadSnapshot().externalAccounts.first)
        XCTAssertEqual(reloaded.balance, Decimal(string: "53.51"))
        XCTAssertEqual(reloaded.balanceType, "CLBD")
        XCTAssertEqual(reloaded.lastSyncedAt, syncedAt)

        try dataStore.updateExternalAccountStatus(account, status: .needsReconnect, error: "session_expired")
        reloaded = try XCTUnwrap(try dataStore.loadSnapshot().externalAccounts.first)
        XCTAssertEqual(reloaded.normalizedStatus, .needsReconnect)
        XCTAssertEqual(reloaded.lastSyncError, "session_expired")
        XCTAssertEqual(reloaded.balance, Decimal(string: "53.51"), "a status change must keep the cached balance")
    }

    func testPruneRemovesOnlyMissingTransactionsInsideTheWindow() throws {
        let dataStore = try makeDataStore()
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        let transactions = sampleTransactions(for: account)
        try dataStore.importBankTransactions(transactions)
        let windowStart = transactions.map(\.bookingDate).sorted()[1]
        let kept = Set(transactions.filter { $0.bookingDate >= windowStart }.prefix(1).map(\.externalID))

        let removed = try dataStore.pruneBankTransactions(accountID: account.id, bookedOnOrAfter: windowStart, keeping: kept)

        let remaining = try dataStore.loadSnapshot().bankTransactions
        XCTAssertEqual(removed, transactions.filter { $0.bookingDate >= windowStart }.count - 1)
        XCTAssertEqual(remaining.count, 4 - removed)
        XCTAssertTrue(remaining.allSatisfy { $0.bookingDate < windowStart || kept.contains($0.externalID) })
        XCTAssertEqual(try dataStore.pruneBankTransactions(accountID: UUID(), bookedOnOrAfter: .distantPast, keeping: []), 0)
    }

    func testDeleteExternalAccountCascadesItsTransactions() throws {
        let dataStore = try makeDataStore()
        let accounts = try dataStore.saveExternalAccounts([makeAccount(), makeAccount(stableIdentifier: "hash-2", name: "Livret")])
        try dataStore.importBankTransactions(sampleTransactions(for: accounts[0]) + sampleTransactions(for: accounts[1]))

        try dataStore.deleteExternalAccount(accounts[0])

        let snapshot = try dataStore.loadSnapshot()
        XCTAssertEqual(snapshot.externalAccounts.map(\.stableIdentifier), ["hash-2"])
        XCTAssertEqual(snapshot.bankTransactions.count, 4)
        XCTAssertTrue(snapshot.bankTransactions.allSatisfy { $0.accountID == accounts[1].id })
    }

    func testAppStateReloadExposesExternalData() throws {
        let dataStore = try makeDataStore()
        let appState = AppState(dataStore: dataStore)
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        try dataStore.importBankTransactions(sampleTransactions(for: account))

        appState.reload()

        XCTAssertEqual(appState.externalAccounts.count, 1)
        XCTAssertEqual(appState.bankTransactions.count, 4)
    }

    func testAppStateBankHelpersFilterByMonthAndDirection() throws {
        let dataStore = try makeDataStore()
        let appState = AppState(dataStore: dataStore)
        let accounts = try dataStore.saveExternalAccounts([makeAccount(), makeAccount(stableIdentifier: "hash-2", name: "Livret")])
        try dataStore.updateExternalAccountBalance(accounts[0], balance: Decimal(string: "53.51"), balanceType: "CLBD", balanceDate: nil, syncedAt: Date())
        try dataStore.updateExternalAccountBalance(accounts[1], balance: Decimal(string: "100"), balanceType: "CLBD", balanceDate: nil, syncedAt: Date())
        try dataStore.importBankTransactions(sampleTransactions(for: accounts[0]))
        appState.reload()

        XCTAssertEqual(appState.totalExternalBalance(), Decimal(string: "153.51"))
        XCTAssertNil(appState.totalExternalBalance(currencyCode: "USD"))

        let today = TestFixtures.referenceDate
        let debits = appState.bankTransactions(in: today, direction: .debit).map(\.externalID)
        XCTAssertTrue(debits.contains("hash-1#dkx1z"))
        XCTAssertFalse(debits.contains("hash-1#eo28j"))
        XCTAssertTrue(appState.bankTransactions(in: today, direction: .credit).contains { $0.externalID == "hash-1#eo28j" })
        XCTAssertTrue(appState.bankTransactions(in: today, accountID: accounts[1].id).isEmpty)
        XCTAssertGreaterThanOrEqual(appState.bankMonthlyTotal(in: today, direction: .credit), Decimal(string: "4.49")!)
        XCTAssertGreaterThanOrEqual(appState.bankMonthlyTotal(in: today, direction: .debit), Decimal(string: "8.19")!)

        try appState.setExternalAccount(accounts[0], includedInTotals: false)
        XCTAssertTrue(appState.bankTransactions(in: today).isEmpty, "excluded accounts drop out of the month view")
        XCTAssertFalse(appState.bankTransactions(in: today, accountID: accounts[0].id).isEmpty, "but stay reachable explicitly")
        XCTAssertEqual(appState.bankMonthlyTotal(in: today, direction: .debit), 0)
        XCTAssertEqual(appState.totalExternalBalance(), Decimal(string: "100"))
        XCTAssertEqual(try dataStore.latestBankTransactionDate(accountID: accounts[0].id), appState.bankTransactions.map(\.bookingDate).max())
        XCTAssertNil(try dataStore.latestBankTransactionDate(accountID: accounts[1].id))
    }

    func testTransactionFlagsCategoryAndSpendingByCategory() throws {
        let dataStore = try makeDataStore()
        let appState = AppState(dataStore: dataStore)
        let account = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        try dataStore.importBankTransactions(sampleTransactions(for: account))
        appState.reload()
        let today = TestFixtures.referenceDate
        let carrefour = try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#q7m2a" })
        let coffee = try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#dkx1z" })

        try appState.setBankTransaction(carrefour, category: .groceries)
        try appState.setBankTransaction(coffee, category: .leisure)
        let spending = appState.bankSpendingByCategory(in: today)
        XCTAssertTrue(spending.contains { $0.category == .leisure && $0.amount == Decimal(string: "8.19") })

        try appState.setBankTransaction(coffee, isIgnored: true)
        XCTAssertFalse(appState.bankSpendingByCategory(in: today).contains { $0.category == .leisure })
        XCTAssertFalse(try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#dkx1z" }).isExpense)

        let considered: Set<String> = ["hash-1#s1p9k", "unknown"]
        XCTAssertEqual(try dataStore.reconcileInternalTransfers(consideredIDs: considered, pairedIDs: ["hash-1#s1p9k", "unknown"]), 1)
        XCTAssertEqual(try dataStore.reconcileInternalTransfers(consideredIDs: considered, pairedIDs: ["hash-1#s1p9k"]), 0, "already marked")
        appState.reload()
        let salary = try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#s1p9k" })
        XCTAssertTrue(salary.isInternalTransfer)
        XCTAssertFalse(salary.isIncome)

        // The counterpart is gone from the window: an automatic verdict must be revoked, not kept for life.
        XCTAssertEqual(try dataStore.reconcileInternalTransfers(consideredIDs: considered, pairedIDs: []), 1)
        appState.reload()
        let revoked = try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#s1p9k" })
        XCTAssertFalse(revoked.isInternalTransfer, "a dissolved pair no longer proves an internal transfer")
        XCTAssertNil(revoked.transferEvidence)
        XCTAssertEqual(revoked.creditNature, .salary, "the label evidence takes over again")
        XCTAssertTrue(revoked.isIncome, "and the credit counts as income once more")
        try appState.setBankTransaction(salary, isInternalTransfer: false)
        XCTAssertTrue(try XCTUnwrap(appState.bankTransactions.first { $0.externalID == "hash-1#s1p9k" }).isIncome)

        let recent = try dataStore.recentBankTransactions(since: today.addingTimeInterval(-5 * 86_400))
        XCTAssertEqual(recent.count, 3)
    }

    func testManualAccountsAreStoredCountedAndEditable() throws {
        let dataStore = try makeDataStore()
        let appState = AppState(dataStore: dataStore)
        let linked = try XCTUnwrap(try dataStore.saveExternalAccounts([makeAccount()]).first)
        try dataStore.updateExternalAccountBalance(linked, balance: Decimal(string: "123.76"), balanceType: "XPCD", balanceDate: nil, syncedAt: Date())

        try appState.addManualAccount(name: "  Livret Jeune ", balance: Decimal(string: "383.004")!)

        let manual = try XCTUnwrap(appState.externalAccounts.first(where: \.isManual))
        XCTAssertEqual(manual.name, "Livret Jeune")
        XCTAssertEqual(manual.balance, Decimal(string: "383.00"))
        XCTAssertEqual(manual.balanceType, ExternalAccount.manualBalanceType)
        XCTAssertEqual(manual.currencyCode, "EUR")
        XCTAssertTrue(manual.stableIdentifier.hasPrefix("manual:"))
        XCTAssertEqual(appState.linkedExternalAccounts.map(\.id), [linked.id])
        XCTAssertEqual(appState.totalExternalBalance(), Decimal(string: "506.76"))

        try appState.updateManualAccount(manual, name: "Livret A", balance: 400)
        let updated = try XCTUnwrap(appState.externalAccounts.first(where: \.isManual))
        XCTAssertEqual(updated.name, "Livret A")
        XCTAssertEqual(updated.balance, 400)
        XCTAssertEqual(appState.totalExternalBalance(), Decimal(string: "523.76"))
        XCTAssertEqual(BankInstitution.linkableCases.contains(.manual), false)
    }

    func testStubGatewayRoundTrip() async throws {
        let gateway = StubBankGatewayClient()

        let start = try await gateway.startLink(institution: .mock)
        let link = try await gateway.link(id: start.linkId)
        let account = try XCTUnwrap(link.accounts.first)
        let balances = try await gateway.balances(accountUID: account.uid, attended: true)
        let page = try await gateway.transactions(accountUID: account.uid, query: BankTransactionsQuery(), attended: true)

        XCTAssertEqual(link.status, .authorized)
        XCTAssertEqual(gateway.startedLinks, ["mock"])
        XCTAssertEqual(balances.first?.amount, Decimal(string: "53.51"))
        XCTAssertEqual(page.transactions.count, 4)
        XCTAssertNil(page.continuationKey)

        gateway.failNextCalls(with: .sessionExpired)
        do {
            _ = try await gateway.balances(accountUID: account.uid, attended: false)
            XCTFail("expected failure")
        } catch let error as BankGatewayError {
            XCTAssertEqual(error, .sessionExpired)
        }
    }
}
