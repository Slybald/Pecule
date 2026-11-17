import XCTest
@testable import Pecule

@MainActor
final class AIAdvisorPromptBuilderTests: XCTestCase {
    func testPromptCarriesAggregatesButNeverLabelsAccountsOrIdentifiers() throws {
        let appState = try TestFixtures.makeAppState(seeded: false)
        try appState.addIncomeSource(name: "Salaire ACME SECRET", amount: 1500, type: .salary, startDate: TestFixtures.date(2026, 1, 1), endDate: nil, isRecurring: true, isActive: true)
        let account = try XCTUnwrap(try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(name: "TITULAIRE TEST", balance: 800, maskedIBAN: "FR76…0189")]).first)
        try appState.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "cb-1", amount: 42, direction: .debit, dayOffset: -2, label: "CB NETFLIX SECRETLABEL", category: .subscriptions),
            TestFixtures.transaction(account: account, reference: "cb-2", amount: 60, direction: .debit, dayOffset: -1, label: "CB CARREFOUR HIDDEN", category: .groceries),
        ])
        appState.reload()

        let context = appState.aiAdvisorContext(on: TestFixtures.referenceDate, calendar: TestFixtures.utcCalendar(), locale: Locale(identifier: "fr_FR"))
        let prompt = AIAdvisorPromptBuilder().prompt(for: context)

        XCTAssertTrue(context.usesBankData)
        XCTAssertEqual(context.variableExpenses, 60, "groceries are observed variable expenses")
        XCTAssertEqual(context.fixedCharges, 42, "subscription debits are fixed even without a manual plan")
        XCTAssertEqual(context.topCategories.map(\.name), ["Courses", "Abonnements"])
        for forbidden in ["NETFLIX", "SECRETLABEL", "CARREFOUR", "HIDDEN", "TITULAIRE", "0189", "ACME SECRET", "cb-1"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(forbidden), "the prompt leaked \(forbidden)")
        }
        XCTAssertTrue(prompt.contains("real bank statements"))
        XCTAssertTrue(prompt.contains("Biggest spending categories: Courses"))
        XCTAssertTrue(prompt.contains("Financial health grade"))
    }

    // M004 : le solde prévu de fin de mois n'est pas transmis au modèle tant que la prévision est absente.
    func testPromptCarriesNoMonthEndBalanceWhileTheForecastIsWithheld() throws {
        let appState = try TestFixtures.makeAppState(seeded: false)
        try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 800)])
        appState.reload()

        let context = appState.aiAdvisorContext(on: TestFixtures.referenceDate, calendar: TestFixtures.utcCalendar(), locale: Locale(identifier: "fr_FR"))

        XCTAssertNil(context.expectedClosingBalance)
        XCTAssertFalse(AIAdvisorPromptBuilder().prompt(for: context).contains("Expected balance at month end"))
    }

    func testInstructionsForbidInventingNames() {
        let instructions = AIAdvisorPromptBuilder().instructions(responseLanguage: "French")

        XCTAssertTrue(instructions.contains("never invent, guess or mention merchant names"))
        XCTAssertTrue(instructions.contains("Respond in French"))
    }
}
