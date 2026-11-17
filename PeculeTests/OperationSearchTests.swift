import XCTest
@testable import Pecule

@MainActor
final class OperationSearchTests: XCTestCase {
    private let service = OperationSearchService()

    func testFiltersCombineAcrossMerchantAccountDatesCategoryDirectionStatusAndAmount() throws {
        let account = TestFixtures.linkedAccount()
        let other = TestFixtures.linkedAccount(stableIdentifier: "other")
        let target = TestFixtures.transaction(account: account, reference: "maif", amount: TestFixtures.decimal("74.86"), direction: .debit, dayOffset: 0, label: "PRÉLÈVEMENT MAIF", category: .insurance)
        target.counterpartyName = "Société MAIF"
        let outside = TestFixtures.transaction(account: account, reference: "old", amount: 74, direction: .debit, dayOffset: -40, label: "MAIF", category: .insurance)
        let wrongAccount = TestFixtures.transaction(account: other, reference: "other", amount: 74, direction: .debit, dayOffset: 0, label: "MAIF", category: .insurance)
        let pending = TestFixtures.transaction(account: account, reference: "pending", amount: 74, direction: .debit, dayOffset: 0, label: "MAIF", category: .insurance)
        pending.status = "pending"
        let records = service.records(transactions: [target, outside, wrongAccount, pending], purchases: [], accounts: [account, other])
        var filter = OperationFilter()
        filter.text = "prelevement societe"
        filter.accountID = account.id
        filter.category = .insurance
        filter.direction = .debit
        filter.status = .booked
        filter.dateFrom = TestFixtures.referenceDate
        filter.dateUntil = TestFixtures.day(offset: 1)
        filter.minimumAmount = 70
        filter.maximumAmount = 75
        let result = service.search(records, filter: filter)
        XCTAssertEqual(result.records.map(\.id), [.bank(target.id)])
        XCTAssertEqual(result.netExpenses, TestFixtures.decimal("74.86"))
        filter.maximumAmount = 74
        XCTAssertTrue(service.search(records, filter: filter).records.isEmpty)
        XCTAssertEqual(service.search(records, filter: OperationFilter()).records.count, 4)
    }

    func testFilteredTotalsSeparateRefundsIncomeAndExcludedTransactions() {
        let account = TestFixtures.linkedAccount()
        let expense = TestFixtures.transaction(account: account, reference: "expense", amount: 100, direction: .debit, dayOffset: -1, category: .shopping)
        let refund = TestFixtures.transaction(account: account, reference: "refund", amount: 30, direction: .credit, dayOffset: 0, label: "REMBOURSEMENT", category: .shopping)
        let salary = TestFixtures.transaction(account: account, reference: "salary", amount: 1200, direction: .credit, dayOffset: 0)
        let ignored = TestFixtures.transaction(account: account, reference: "ignored", amount: 900, direction: .debit, dayOffset: 0)
        ignored.isIgnored = true
        let pending = TestFixtures.transaction(account: account, reference: "pending", amount: 800, direction: .debit, dayOffset: 0)
        pending.status = "pending"
        let result = service.search(service.records(transactions: [expense, refund, salary, ignored, pending], purchases: [], accounts: [account]), filter: OperationFilter())
        XCTAssertEqual(result.records.count, 5, "Excluded evidence remains inspectable")
        XCTAssertEqual(result.grossExpenses, 100)
        XCTAssertEqual(result.refunds, 30)
        XCTAssertEqual(result.netExpenses, 70)
        XCTAssertEqual(result.income, 1200)
    }

    func testMatchedManualPurchaseIsRepresentedOnceAndBudgetScopeExcludesOtherSources() {
        let account = TestFixtures.linkedAccount()
        let matched = Purchase(title: "Matched", amount: 100, date: TestFixtures.referenceDate, category: .shopping, merchant: "Shop", notes: nil)
        let manual = Purchase(title: "Manual", amount: 20, date: TestFixtures.referenceDate, category: .shopping, merchant: "Shop", notes: nil)
        let debit = TestFixtures.transaction(account: account, reference: "purchase", amount: 100, direction: .debit, dayOffset: 0, category: .shopping)
        debit.linkedPurchaseID = matched.id
        let records = service.records(transactions: [debit], purchases: [matched, manual], accounts: [account])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(service.search(records, filter: OperationFilter()).netExpenses, 120)
        var filter = OperationFilter()
        filter.source = .bank
        filter.includedOnly = true
        XCTAssertEqual(service.search(records, filter: filter).netExpenses, 100)
        filter.source = .manual
        XCTAssertEqual(service.search(records, filter: filter).records.map(\.id), [.purchase(manual.id)])
    }

    // Lorsque la liste ne lit qu'une fenêtre de dates, le rattachement d'un achat à une opération
    // bancaire peut pointer hors de cette fenêtre. Sans l'ensemble des liens fourni séparément,
    // l'achat réapparaîtrait comme opération manuelle et serait compté deux fois.
    func testAPurchaseLinkedOutsideTheLoadedWindowIsStillRepresentedOnce() {
        let account = TestFixtures.linkedAccount()
        let matched = Purchase(title: "Matched", amount: 100, date: TestFixtures.referenceDate, category: .shopping, merchant: "Shop", notes: nil)
        let outsideWindow = TestFixtures.transaction(account: account, reference: "old", amount: 100, direction: .debit, dayOffset: -90, category: .shopping)
        outsideWindow.linkedPurchaseID = matched.id
        let insideWindow = TestFixtures.transaction(account: account, reference: "recent", amount: 12, direction: .debit, dayOffset: 0, category: .groceries)

        // Ce que voit la vue : la seule opération de la fenêtre, plus l'ensemble exact des liens.
        let windowed = service.records(
            transactions: [insideWindow],
            purchases: [matched],
            accounts: [account],
            linkedPurchaseIDs: [matched.id]
        )
        XCTAssertEqual(windowed.map(\.id), [.bank(insideWindow.id)], "l'achat rattaché reste masqué")

        // Sans l'ensemble des liens, la déduction à partir de la fenêtre le laisserait passer :
        // c'est précisément la régression que ce test verrouille.
        let deduced = service.records(transactions: [insideWindow], purchases: [matched], accounts: [account])
        XCTAssertTrue(deduced.contains { $0.id == .purchase(matched.id) })
    }

    func testClassificationCorrectionSurvivesSyncAndRefreshesSearch() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let transaction = TestFixtures.transaction(account: account, reference: "maif", amount: TestFixtures.decimal("74.86"), direction: .debit, dayOffset: 0, label: "MAIF", category: .other)
        try state.dataStore.importBankTransactions([transaction])
        state.reload()
        var filter = OperationFilter()
        filter.needsReview = true
        XCTAssertEqual(service.search(service.records(transactions: state.bankTransactions, purchases: [], accounts: state.externalAccounts), filter: filter).records.count, 1)
        let revision = state.dataRevision
        try state.setBankTransaction(transaction, category: .insurance)
        XCTAssertGreaterThan(state.dataRevision, revision)
        try state.dataStore.importBankTransactions([TestFixtures.transaction(account: account, reference: "maif", amount: TestFixtures.decimal("74.86"), direction: .debit, dayOffset: 0, label: "MAIF BANQUE", category: .other)])
        state.reload()
        XCTAssertTrue(service.search(service.records(transactions: state.bankTransactions, purchases: [], accounts: state.externalAccounts), filter: filter).records.isEmpty)
        filter.needsReview = false
        filter.category = .insurance
        XCTAssertEqual(service.search(service.records(transactions: state.bankTransactions, purchases: [], accounts: state.externalAccounts), filter: filter).netExpenses, TestFixtures.decimal("74.86"))
    }

    func testBudgetShowsGrossRefundAndNetAndKeepsZeroLimit() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "expense", amount: 100, direction: .debit, dayOffset: 0, category: .shopping),
            TestFixtures.transaction(account: account, reference: "refund", amount: 30, direction: .credit, dayOffset: 0, label: "REFUND", category: .shopping)
        ])
        try state.setBudgetRule(category: ExpenseCategory.shopping.storageValue, monthlyAmount: 0)
        state.reload()
        state.prefersBankAmounts = true
        let row = try XCTUnwrap(state.budgetOverview(for: TestFixtures.referenceDate).first { $0.category == .shopping })
        XCTAssertEqual(row.grossSpentAmount, 100)
        XCTAssertEqual(row.refundedAmount, 30)
        XCTAssertEqual(row.spentAmount, 70)
        XCTAssertEqual(row.remainingAmount, -70)
    }
}
