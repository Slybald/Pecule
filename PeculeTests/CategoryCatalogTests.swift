import XCTest
@testable import Pecule

@MainActor
final class CategoryCatalogTests: XCTestCase {
    func testCustomCategoryReusedByBudgetGoalAndBankOperation() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let category = try state.dataStore.createCategory(name: "Animaux")
        let duplicate = try state.dataStore.createCategory(name: " animaux ")
        XCTAssertEqual(category.id, duplicate.id)
        try state.setBudgetRule(category: category.storageValue, monthlyAmount: 75)
        try state.addGoal(title: "Réserve", targetAmount: 300, currentAmount: 0, targetDate: TestFixtures.referenceDate, category: category.storageValue)
        let account = TestFixtures.linkedAccount()
        let transaction = TestFixtures.transaction(account: account, reference: "pet", amount: 25, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([transaction])
        try state.setBankTransaction(transaction, category: category)
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: state.goals[0].category), category.id)
        XCTAssertEqual(state.budgetRule(for: "Animaux")?.monthlyAmount, 75)
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: transaction.category), category.id)
        XCTAssertNotEqual(category, .other)
        XCTAssertEqual(state.availableCategories.filter { $0.id == category.id }.count, 1)
        let rows = BudgetOverviewService().rows(plannedAmount: { $0 == category ? 75 : nil }, spending: [category: 25], source: .bank, catalog: state.availableCategories)
        XCTAssertEqual(rows.first { $0.category == category }?.remainingAmount, 50)
    }

    func testUnknownHistoricalCategoriesRemainDistinct() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addPurchase(title: "Legacy", amount: 10, date: TestFixtures.referenceDate, category: "Catégorie historique Ω", merchant: "", notes: nil)
        state.reload()
        XCTAssertEqual(state.purchases[0].category, "Catégorie historique Ω")
        XCTAssertTrue(state.availableCategories.contains { $0.storageValue == "Catégorie historique Ω" })
        XCTAssertNotEqual(ExpenseCategory.canonicalKey(for: "Catégorie historique Ω"), ExpenseCategory.other.id)
    }
}
