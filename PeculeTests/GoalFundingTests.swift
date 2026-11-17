import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class GoalFundingTests: XCTestCase {
    func testDeadlineAndDurationAndUndatedPurchase() throws {
        let store = try TestFixtures.makeDataStore()
        for intention in GoalIntention.allCases {
            try store.saveGoalPlan(id: nil, title: intention.rawValue, target: 1200, current: 0, category: "Shopping", intention: intention, targetDate: TestFixtures.referenceDate, durationMonths: 6, showsHelp: true, now: TestFixtures.referenceDate)
        }
        let goals = try store.loadSnapshot().goals
        XCTAssertEqual(goals.first { $0.normalizedIntention == .deadline }?.deadline(), TestFixtures.referenceDate)
        XCTAssertEqual(goals.first { $0.normalizedIntention == .duration }?.deadline(calendar: TestFixtures.utcCalendar()), TestFixtures.utcCalendar().date(byAdding: .month, value: 6, to: TestFixtures.referenceDate))
        XCTAssertNil(goals.first { $0.normalizedIntention == .purchase }?.deadline())
    }

    func testReservationsAreDatedIdempotentReversibleAndDoNotChangeBankBalance() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        try store.saveExternalAccounts([account])
        let originalBalance = account.balance
        try store.saveGoalPlan(id: nil, title: "Laptop", target: 1000, current: 200, category: "Shopping", intention: .reserve, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false)
        let goal = try XCTUnwrap(store.loadSnapshot().goals.first)
        XCTAssertEqual(try store.goalContributions().count, 0)
        let id = UUID()
        try store.reserveForGoal(id: goal.id, amount: 100, date: TestFixtures.referenceDate, contributionID: id)
        try store.reserveForGoal(id: goal.id, amount: 100, date: TestFixtures.referenceDate, contributionID: id)
        try store.reserveForGoal(id: goal.id, amount: -30, date: TestFixtures.referenceDate)
        XCTAssertEqual(goal.currentAmount, 270)
        XCTAssertEqual(GoalFundingService().reserved(for: TestFixtures.referenceDate, contributions: try store.goalContributions(), calendar: TestFixtures.utcCalendar()), 70)
        XCTAssertEqual(account.balance, originalBalance)
        XCTAssertTrue(try store.loadSnapshot().bankTransactions.isEmpty)
        XCTAssertThrowsError(try store.reserveForGoal(id: goal.id, amount: -80, date: TestFixtures.referenceDate))
        XCTAssertThrowsError(try store.deleteGoal(goal))
    }

    func testV3MigrationPreservesLegacyGoalUnknownCategoryAndAnnotations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "v3.store"), id = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PeculeSchemaV3.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            container.mainContext.insert(PeculeSchemaV3.Goal(id: id, title: "Legacy", targetAmount: 1000, currentAmount: 250, targetDate: TestFixtures.referenceDate, category: "Catégorie Ω", isArchived: false))
            let transaction = PeculeSchemaV3.BankTransaction(externalID: "legacy-note", accountID: UUID(), amount: 30, direction: .credit, currencyCode: "EUR", bookingDate: TestFixtures.referenceDate, label: "Legacy")
            transaction.userNote = "Retain annotation"
            transaction.natureOverride = "refund"
            transaction.categoryOverride = "Catégorie Ω"
            container.mainContext.insert(transaction)
            try container.mainContext.save()
        }
        for _ in 0..<2 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let store = PeculeDataStore(container: container), snapshot = try store.loadSnapshot()
                let goal = try XCTUnwrap(snapshot.goals.first)
                XCTAssertEqual(goal.id, id); XCTAssertEqual(goal.currentAmount, 250)
                XCTAssertEqual(goal.category, "Catégorie Ω"); XCTAssertEqual(goal.normalizedIntention, .deadline)
                XCTAssertEqual(try store.goalContributions().count, 0)
                let transaction = try XCTUnwrap(snapshot.bankTransactions.first)
                XCTAssertEqual(transaction.userNote, "Retain annotation")
                XCTAssertEqual(transaction.natureOverride, "refund")
                XCTAssertEqual(transaction.categoryOverride, "Catégorie Ω")
                XCTAssertNil(transaction.internalTransferOverride)
                XCTAssertNil(transaction.installmentDecision)
                XCTAssertTrue(try store.categoryCatalog(preserving: snapshot).contains { $0.storageValue == "Catégorie Ω" })
            }
        }
    }
}

extension GoalFundingTests {
    func testAllowanceExplainsReservationWithoutChangingExpensesOrForecast() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let date = TestFixtures.referenceDate, calendar = TestFixtures.utcCalendar()
        let before = state.monthlyFinancialSummary(for: date, calendar: calendar)
        let forecastBefore = state.cashflowForecast(on: date, calendar: calendar)
        try state.addGoal(title: "Trip", targetAmount: 1000, currentAmount: 0, targetDate: date, category: "Travel")
        let goal = try XCTUnwrap(state.goals.first)
        try state.dataStore.reserveForGoal(id: goal.id, amount: 80, date: date)
        state.reload()
        let after = state.monthlyFinancialSummary(for: date, calendar: calendar)
        XCTAssertEqual(after.reservedForGoals, 80)
        XCTAssertEqual(after.remainingToLive, before.remainingToLive - 80)
        XCTAssertEqual(after.totalExpenses, before.totalExpenses)
        XCTAssertEqual(after.totalEstimatedIncome, before.totalEstimatedIncome)
        XCTAssertEqual(state.decisionMetrics(on: date, calendar: calendar).remainingToLive, after.remainingToLive)
        XCTAssertEqual(state.cashflowForecast(on: date, calendar: calendar), forecastBefore)
        let nextMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: date))
        XCTAssertEqual(state.monthlyFinancialSummary(for: nextMonth, calendar: calendar).reservedForGoals, 0)
    }

    // M025 : renommer un objectif dont la réservation a des centimes relisait le montant courant tronqué (83,34 devenait 83),
    // au-dessous de la réservation : l'enregistrement était refusé. Les textes sont ceux que le formulaire préremplit.
    func testRenamingAGoalReservedWithCentsKeepsItsCurrentAmountAndSaves() throws {
        let store = try TestFixtures.makeDataStore()
        try store.saveGoalPlan(id: nil, title: "Voyage", target: TestFixtures.decimal("1000.50"), current: 0, category: "Travel", intention: .reserve, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false)
        let goal = try XCTUnwrap(store.loadSnapshot().goals.first)
        try store.reserveForGoal(id: goal.id, amount: TestFixtures.decimal("83.34"), date: TestFixtures.referenceDate)
        XCTAssertEqual(goal.currentAmount, TestFixtures.decimal("83.34"))
        for identifier in ["fr_FR", "en_US"] {
            let locale = Locale(identifier: identifier)
            let targetText = Formatters.decimalString(for: goal.targetAmount, locale: locale)
            let currentText = Formatters.decimalString(for: goal.currentAmount, locale: locale)
            let amounts = try XCTUnwrap(GoalFormView.amountsToSave(targetText: targetText, currentText: currentText, goal: goal), identifier)
            XCTAssertEqual(amounts.target, TestFixtures.decimal("1000.50"), identifier)
            XCTAssertEqual(amounts.current, TestFixtures.decimal("83.34"), identifier)
            try store.saveGoalPlan(id: goal.id, title: "Voyage en Italie (\(identifier))", target: amounts.target, current: amounts.current, category: "Travel", intention: .reserve, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false)
        }
        XCTAssertEqual(goal.title, "Voyage en Italie (en_US)")
        XCTAssertEqual(goal.targetAmount, TestFixtures.decimal("1000.50"))
        XCTAssertEqual(goal.currentAmount, TestFixtures.decimal("83.34"))
        XCTAssertEqual(GoalFundingService().totalReserved(goalID: goal.id, contributions: try store.goalContributions()), TestFixtures.decimal("83.34"))
    }

    func testRenamingAGoalWithCentsInItsAmountsDoesNotLoseThem() throws {
        let store = try TestFixtures.makeDataStore()
        try store.saveGoalPlan(id: nil, title: "Épargne", target: TestFixtures.decimal("5000.50"), current: TestFixtures.decimal("2500.75"), category: "Savings", intention: .reserve, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false)
        let goal = try XCTUnwrap(store.loadSnapshot().goals.first)
        let french = Locale(identifier: "fr_FR")
        let amounts = try XCTUnwrap(GoalFormView.amountsToSave(
            targetText: Formatters.decimalString(for: goal.targetAmount, locale: french),
            currentText: Formatters.decimalString(for: goal.currentAmount, locale: french),
            goal: goal
        ))
        try store.saveGoalPlan(id: goal.id, title: "Épargne vacances", target: amounts.target, current: amounts.current, category: "Savings", intention: .reserve, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false)
        XCTAssertEqual(goal.targetAmount, TestFixtures.decimal("5000.50"))
        XCTAssertEqual(goal.currentAmount, TestFixtures.decimal("2500.75"))
        // Un montant modifié est bien relu du champ, et un champ invalide refuse l'enregistrement.
        let edited = try XCTUnwrap(GoalFormView.amountsToSave(targetText: "6 000,25", currentText: "2500,75", goal: goal))
        XCTAssertEqual(edited.target, TestFixtures.decimal("6000.25"))
        XCTAssertNil(GoalFormView.amountsToSave(targetText: "abc", currentText: "2500,75", goal: goal))
        XCTAssertNil(GoalFormView.amountsToSave(targetText: "6000", currentText: "-1", goal: goal))
        XCTAssertNil(GoalFormView.amountsToSave(targetText: "0", currentText: "0", goal: nil))
    }
}
