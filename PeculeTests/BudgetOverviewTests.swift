import XCTest
@testable import Pecule

@MainActor
final class BudgetOverviewTests: XCTestCase {
    func testRowsCoverEveryCategoryWithTheGivenSource() throws {
        let service = BudgetOverviewService()
        let planned: (ExpenseCategory) -> Decimal? = { $0 == .groceries ? 300 : nil }
        let spending: [ExpenseCategory: Decimal] = [.groceries: TestFixtures.decimal("330.5"), .fuel: 60]

        let rows = service.rows(plannedAmount: planned, spending: spending, source: .bank)
        XCTAssertEqual(rows.count, ExpenseCategory.allCases.count)
        let groceries = try XCTUnwrap(rows.first { $0.category == .groceries })
        XCTAssertEqual(groceries.plannedAmount, 300)
        XCTAssertEqual(groceries.spentAmount, TestFixtures.decimal("330.5"))
        XCTAssertEqual(groceries.source, .bank)
        XCTAssertTrue(groceries.isOverspent)
        XCTAssertEqual(groceries.remainingAmount, TestFixtures.decimal("-30.5"))
        XCTAssertEqual(groceries.utilizationRatio, 1.1017, accuracy: 0.001)
        XCTAssertNil(rows.first { $0.category == .fuel }?.plannedAmount, "an absent rule means no budget")
        XCTAssertEqual(rows.first { $0.category == .fuel }?.utilizationRatio, 1, "spending without a plan saturates the gauge")
        XCTAssertEqual(rows.first { $0.category == .leisure }?.spentAmount, 0)

        let totals = BudgetOverviewService.totals(of: rows)
        XCTAssertEqual(totals.planned, 300)
        XCTAssertEqual(totals.spent, TestFixtures.decimal("390.5"))
    }

    func testAppStateOverviewSwitchesToBankAmountsWhenAnAccountIsLinked() throws {
        let appState = try TestFixtures.makeAppState()
        try appState.setBudgetRule(category: ExpenseCategory.groceries.storageValue, monthlyAmount: 100)
        let month = TestFixtures.referenceDate
        let calendar = TestFixtures.utcCalendar()
        XCTAssertEqual(appState.budgetOverview(for: month, calendar: calendar).first { $0.category == .groceries }?.source, .manual)

        let account = try XCTUnwrap(try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 50)]).first)
        try appState.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "cb-1", amount: 42, direction: .debit, dayOffset: 0, label: "CB CARREFOUR", category: .groceries),
            TestFixtures.transaction(account: account, reference: "cb-2", amount: 8, direction: .debit, dayOffset: 0, label: "CAFE", category: .leisure),
        ])
        appState.reload()

        let rows = appState.budgetOverview(for: month, calendar: calendar)
        let groceries = try XCTUnwrap(rows.first { $0.category == .groceries })
        XCTAssertEqual(groceries.source, .bank)
        XCTAssertEqual(groceries.plannedAmount, 100)
        XCTAssertEqual(groceries.spentAmount, 42, "orphan bank debits count as variable spending in their category")
        XCTAssertEqual(rows.first { $0.category == .leisure }?.spentAmount, 8)

        appState.prefersBankAmounts = false
        let plannedRows = appState.budgetOverview(for: month, calendar: calendar)
        XCTAssertEqual(plannedRows.first { $0.category == .groceries }?.source, .manual)
        XCTAssertEqual(plannedRows.first { $0.category == .groceries }?.spentAmount, 0, "the preference restores the manual-only calculation")
        appState.prefersBankAmounts = true

        let rule = try XCTUnwrap(appState.budgetRule(for: ExpenseCategory.groceries.storageValue))
        try appState.deleteBudgetRule(rule)
        XCTAssertNil(appState.budgetOverview(for: month, calendar: calendar).first { $0.category == .groceries }?.plannedAmount)
    }
}
