import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class PurchaseSimulationTests: XCTestCase {
    private let now = TestFixtures.date(2026, 9, 14)
    private let calendar = TestFixtures.utcCalendar()
    private func draft(amount: Decimal = 150, date: Date? = nil, accountID: UUID? = nil) -> PurchaseSimulationDraft {
        var value = PurchaseSimulationDraft(now: date ?? now)
        value.title = "Computer"; value.amount = amount; value.accountID = accountID
        return value
    }
    private func state(balance: Decimal? = 1000) throws -> (AppState, ExternalAccount) {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount(balance: balance)
        try state.dataStore.saveExternalAccounts([account]); state.reload()
        return (state, account)
    }
    private func salary(_ state: AppState, date: Date?, accountID: UUID?) throws {
        try state.addIncomeSource(name: "Salary", amount: 1500, type: .salary, startDate: now, endDate: nil, isRecurring: true, isActive: true)
        var value = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first { $0.sourceKind == "income" })
        value.dueDate = date; value.accountID = accountID
        try state.planningWrite { try $0.saveCommitment(value) }
    }
    func testSharedForecastAndAnOverdrawnAccountAreVisibleDespitePositiveTotal() throws {
        let (state, account) = try state(balance: 100)
        let other = TestFixtures.linkedAccount(stableIdentifier: "second", balance: 1000)
        try state.dataStore.saveExternalAccounts([other]); state.reload()
        let result = try state.simulatePurchase(draft(accountID: account.id), on: now, calendar: calendar)
        let baseline = state.planningForecast(on: now, until: result.end, calendar: calendar)
        XCTAssertEqual(result.reference.days.map(\.total), baseline.days.map(\.total))
        XCTAssertEqual(result.reference.minimum, 1100); XCTAssertEqual(result.scenario.minimum, 950)
        XCTAssertEqual(result.accountBefore, 100); XCTAssertEqual(result.accountAfter, -50)
        XCTAssertEqual(result.scenario.alerts.first?.accountID, account.id)
        XCTAssertEqual(result.reference.days.map(\.date), result.scenario.days.map(\.date))
    }
    func testMissingBudgetIsNotZeroAndNextMonthDoesNotInheritItsLimit() throws {
        let (state, _) = try state()
        XCTAssertNil(try state.simulatePurchase(draft(), on: now, calendar: calendar).month.budgetAfter)
        try state.setMonthlySpendingLimit(0, for: now, calendar: calendar)
        XCTAssertEqual(try state.simulatePurchase(draft(), on: now, calendar: calendar).month.budgetAfter, -150)
        try state.setMonthlySpendingLimit(1000, for: now, calendar: calendar)
        let october = TestFixtures.date(2026, 10, 1)
        XCTAssertNil(try state.simulatePurchase(draft(date: october), on: now, calendar: calendar).month.budgetBefore)
        try state.setMonthlySpendingLimit(700, for: october, calendar: calendar)
        var charge = CommitmentDraft(); charge.title = "Bill"; charge.amount = 200; charge.dueDate = october; charge.cadence = "once"
        try state.planningWrite { try $0.saveCommitment(charge) }
        let future = try state.simulatePurchase(draft(date: october), on: now, calendar: calendar)
        XCTAssertEqual(future.month.budgetBefore, 500); XCTAssertEqual(future.month.budgetAfter, 350)
        XCTAssertEqual(try state.simulatePurchase(draft(), on: now, calendar: calendar).month.budgetBefore, 1000)
    }
    func testManualSubscriptionsAndIncomeAreCountedOnceAndMatchBudget() throws {
        let (state, _) = try state()
        state.prefersBankAmounts = false
        try salary(state, date: now, accountID: nil)
        try state.addSubscription(name: "Insurance", amount: 100, billingCycle: .monthly, category: "other", nextBillingDate: now, isActive: true)
        try state.setMonthlySpendingLimit(1000, for: now, calendar: calendar)
        let result = try state.simulatePurchase(draft(), on: now, calendar: calendar)
        XCTAssertEqual(result.month.budgetBefore, state.monthlyBudget(on: now, now: now, calendar: calendar).margin)
        XCTAssertEqual(result.month.budgetBefore, 900); XCTAssertEqual(result.month.projectsBefore, 1400)
        XCTAssertEqual(result.month.projectsAfter, 1250)
    }
    func testBankPaymentsAndConfirmedRemainingChargesMatchBudgetWithoutDoubleCounting() throws {
        let (state, account) = try state()
        try state.setMonthlySpendingLimit(1000, for: now, calendar: calendar)
        var charge = CommitmentDraft(); charge.title = "Bill"; charge.amount = 100; charge.dueDate = now; charge.cadence = "once"; charge.accountID = account.id
        let tx = TestFixtures.transaction(account: account, reference: "paid", amount: 40, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx])
        try state.planningWrite { try $0.saveCommitment(charge) }
        let key = PlanningEngine(calendar: calendar).occurrenceKey(charge.id, date: now)
        try state.planningWrite { store in
            store.container.mainContext.insert(CommitmentPayment(transactionID: tx.id, commitmentID: charge.id, occurrenceKey: key, amount: 40))
        }
        let result = try state.simulatePurchase(draft(accountID: account.id), on: now, calendar: calendar)
        XCTAssertEqual(result.month.budgetBefore, state.monthlyBudget(on: now, now: now, calendar: calendar).margin)
        XCTAssertEqual(result.month.budgetBefore, 900); XCTAssertEqual(result.month.budgetAfter, 750)
        XCTAssertEqual(result.scenario.minimum, 790) // 1000 - remaining 60 - hypothetical 150.
    }
    func testAfterSalaryUsesNextCivilDayAndItsOwnMonthWithoutInventingMissingDates() throws {
        let (state, account) = try state(balance: 100)
        try salary(state, date: nil, accountID: account.id)
        XCTAssertNil(try state.simulatePurchase(draft(), on: now, calendar: calendar).afterSalaryDate)
        var value = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first)
        value.dueDate = TestFixtures.date(2026, 9, 30)
        try state.planningWrite { try $0.saveCommitment(value) }
        try state.setMonthlySpendingLimit(1000, for: now, calendar: calendar)
        let result = try state.simulatePurchase(draft(accountID: account.id), on: now, calendar: calendar)
        XCTAssertEqual(result.afterSalaryDate, calendar.startOfDay(for: TestFixtures.date(2026, 10, 1)))
        XCTAssertEqual(result.scenario.minimum, -50); XCTAssertEqual(result.afterSalaryForecast?.minimum, 100)
        XCTAssertNil(result.afterSalaryMonth?.budgetAfter)
        XCTAssertEqual(result.afterSalaryForecast?.days.map(\.date), result.reference.days.map(\.date))
        account.isIncludedInTotals = false; try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertNil(try state.simulatePurchase(draft(), on: now, calendar: calendar).afterSalaryDate)
    }
    func testUnassignedPurchaseChangesOnlyGlobalProjectionAndUnknownBalanceStaysUnknown() throws {
        let (state, account) = try state()
        let result = try state.simulatePurchase(draft(), on: now, calendar: calendar)
        XCTAssertEqual(result.scenario.minimum, 850); XCTAssertNil(result.accountAfter)
        XCTAssertEqual(result.scenario.days.first?.balances[account.id], 1000)
        XCTAssertTrue(result.scenario.incomplete)
        account.balance = nil; try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertNil(try state.simulatePurchase(draft(accountID: account.id), on: now, calendar: calendar).scenario.minimum)
        let habitual = try state.simulatePurchase(draft(), on: now, habitual: true, calendar: calendar)
        XCTAssertFalse(habitual.scenario.estimationAvailable); XCTAssertNil(habitual.scenario.minimum)
    }
    func testValidationRejectsPastBeyondHorizonInvalidAmountsAndUnavailableAccounts() throws {
        let (state, account) = try state()
        for amount: Decimal in [0, -1, .nan, TestFixtures.decimal("0.001")] {
            XCTAssertThrowsError(try state.simulatePurchase(draft(amount: amount), on: now, calendar: calendar))
        }
        for date in [TestFixtures.date(2026, 9, 13), TestFixtures.date(2027, 9, 15)] {
            XCTAssertThrowsError(try state.simulatePurchase(draft(date: date), on: now, calendar: calendar))
        }
        XCTAssertThrowsError(try state.simulatePurchase(draft(accountID: UUID()), on: now, calendar: calendar))
        account.currencyCode = "USD"; try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertThrowsError(try state.simulatePurchase(draft(accountID: account.id), on: now, calendar: calendar))
        let last = PurchaseSimulationService.latestDate(now: now, calendar: calendar)
        let result = try state.simulatePurchase(draft(date: last), on: now, calendar: calendar)
        XCTAssertEqual(result.scenario.days.count, 366)
        XCTAssertEqual(result.scenario.days.last?.events.first?.amount, -150)
    }
    func testSimulationSaveEditDeleteNeverChangeFinancesAndDeletedDraftCannotReturn() throws {
        let (state, account) = try state()
        try state.addGoal(title: "Trip", targetAmount: 1000, currentAmount: 0, targetDate: TestFixtures.date(2027, 1, 1), category: "other")
        let goal = try XCTUnwrap(state.goals.first)
        try state.dataStore.reserveForGoal(id: goal.id, amount: 100, date: now); state.reload()
        try state.setMonthlySpendingLimit(1000, for: now, calendar: calendar)
        let financial = state.monthlyFinancialSummary(for: now, calendar: calendar)
        let beforeEvents = state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 14), calendar: calendar)
        let value = draft(amount: TestFixtures.decimal("150.126"), accountID: account.id)
        for _ in 0..<3 { _ = try state.simulatePurchase(value, on: now, calendar: calendar) }
        XCTAssertTrue(state.planning.scenarios.isEmpty)
        try state.planningWrite { try $0.savePurchaseScenario(value, now: now, calendar: calendar) }
        var saved = PurchaseSimulationDraft(try XCTUnwrap(state.planning.scenarios.first))
        XCTAssertEqual(saved.amount, TestFixtures.decimal("150.13"))
        saved.amount = 300
        try state.planningWrite { try $0.savePurchaseScenario(saved, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.scenarios.count, 1)
        XCTAssertEqual(try state.simulatePurchase(saved, on: now, calendar: calendar).month.reservedInMonth, 100)
        try state.planningWrite { try $0.deletePurchaseScenario(id: saved.id) }
        XCTAssertThrowsError(try state.planningWrite { try $0.savePurchaseScenario(saved, now: now, calendar: calendar) })
        XCTAssertTrue(state.planning.scenarios.isEmpty)
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive, financial.remainingToLive)
        XCTAssertEqual(state.externalAccount(id: account.id)?.balance, 1000)
        XCTAssertEqual(state.goals.first?.currentAmount, 100); XCTAssertEqual(state.goalContributions.count, 1)
        XCTAssertTrue(state.purchases.isEmpty); XCTAssertTrue(state.bankTransactions.isEmpty)
        XCTAssertEqual(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 14), calendar: calendar), beforeEvents)
        XCTAssertEqual(state.monthlySpendingLimit(for: now, calendar: calendar), 1000)
    }
    func testSavedScenarioRecalculatesFromCurrentBalancesAndProfileInvalidationStopsWrites() throws {
        let (state, account) = try state()
        let value = draft(accountID: account.id)
        try state.planningWrite { try $0.savePurchaseScenario(value, now: now, calendar: calendar) }
        account.balance = 2000; try state.dataStore.container.mainContext.save(); state.reload()
        let saved = PurchaseSimulationDraft(try XCTUnwrap(state.planning.scenarios.first))
        XCTAssertEqual(try state.simulatePurchase(saved, on: now, calendar: calendar).scenario.minimum, 1850)
        state.invalidateProfile()
        XCTAssertThrowsError(try state.simulatePurchase(saved, on: now, calendar: calendar))
        XCTAssertThrowsError(try state.planningWrite { try $0.deletePurchaseScenario(id: saved.id) })
    }
    func testPersistentReopeningAndActualProfileStoresKeepScenariosIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuer = URL(string: "https://gateway.test")!
        let value = draft()
        for (user, creates, expected) in [("first", true, 1), ("first", false, 1), ("second", false, 0), ("first", false, 1)] {
            try autoreleasepool {
                let location = ProfileStoreLocation(issuer: issuer, userID: user)
                let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: location, root: directory))
                if creates { try store.savePurchaseScenario(value, now: now, calendar: calendar); try store.container.mainContext.save() }
                let rows = try store.planningSnapshot().scenarios
                XCTAssertEqual(rows.count, expected)
                if expected == 1 { XCTAssertEqual(rows.first?.id, value.id); XCTAssertEqual(rows.first?.amount, 150) }
            }
        }
    }
}
