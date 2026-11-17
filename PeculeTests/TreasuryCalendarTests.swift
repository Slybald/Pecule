import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class TreasuryCalendarTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let now = TestFixtures.date(2026, 9, 14)
    private var engine: PlanningEngine { .init(calendar: calendar) }
    private func event(amount: Decimal, date: Date?, accountID: UUID?, confirmed: Bool = true) -> ForecastEvent {
        .init(id: UUID().uuidString, commitmentID: UUID(), title: "Fixture", amount: amount,
              date: date, accountID: accountID, confirmed: confirmed, category: "other")
    }
    func testOneOverdrawnAccountAlertsEvenWhenTheTotalIsPositiveAndIDIsStable() {
        let first = UUID(), second = UUID()
        let accounts = [ForecastAccount(id: first, name: "First", balance: 100, threshold: 0, dailyVariable: nil),
                        ForecastAccount(id: second, name: "Second", balance: 1000, threshold: 0, dailyVariable: nil)]
        let events = [event(amount: -150, date: now, accountID: first)]
        let result = engine.forecast(accounts: accounts, events: events, from: now, until: TestFixtures.date(2026, 9, 16), habitual: false)
        XCTAssertEqual(result.minimum, 950); XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(result.alerts.first?.amount, -50); XCTAssertEqual(result.alerts.first?.id, first)
        XCTAssertEqual(result.days.first?.events, events)
        let refreshed = engine.forecast(accounts: accounts, events: events, from: now, until: TestFixtures.date(2026, 9, 17), habitual: false)
        XCTAssertEqual(result.alerts.first?.id, refreshed.alerts.first?.id)
    }
    func testMissingDateAndUnassignedAccountNeverFabricateAccountMovements() {
        let id = UUID(), excluded = UUID()
        let accounts = [ForecastAccount(id: id, name: "Fixture", balance: 200, threshold: 0, dailyVariable: nil)]
        let result = engine.forecast(accounts: accounts, events: [event(amount: 1500, date: nil, accountID: id), event(amount: -40, date: now, accountID: nil), event(amount: -500, date: now, accountID: excluded)], from: now, until: TestFixtures.date(2026, 9, 15), habitual: false)
        XCTAssertEqual(result.days.first?.balances[id], 200)
        XCTAssertEqual(result.days.first?.total, 160)
        XCTAssertEqual(result.unresolved.count, 3); XCTAssertTrue(result.incomplete)
    }
    func testUnknownBalanceDoesNotProduceAPartialTotalDisguisedAsComplete() {
        let accounts = [ForecastAccount(id: UUID(), name: "Known", balance: 500, threshold: 0, dailyVariable: nil),
                        ForecastAccount(id: UUID(), name: "Unknown", balance: nil, threshold: 0, dailyVariable: nil)]
        let result = engine.forecast(accounts: accounts, events: [], from: now, until: TestFixtures.date(2026, 9, 15), habitual: false)
        XCTAssertNil(result.minimum); XCTAssertNil(result.days.first?.total); XCTAssertTrue(result.incomplete)
    }
    func testHabitualReadingIsUnavailableInsteadOfShowingZeroVariableSpending() {
        let account = ForecastAccount(id: UUID(), name: "Fixture", balance: 200, threshold: 0, dailyVariable: nil)
        let result = engine.forecast(accounts: [account], events: [], from: now, until: TestFixtures.date(2026, 9, 15), habitual: true)
        XCTAssertFalse(result.estimationAvailable); XCTAssertTrue(result.days.isEmpty); XCTAssertNil(result.minimum)
    }
    func testHabitualReadingExplainsVariableSpendingAndSuggestionsWhileConfirmedExcludesThem() {
        let id = UUID()
        let account = ForecastAccount(id: id, name: "Fixture", balance: 100, threshold: 0, dailyVariable: 10)
        let events = [event(amount: -30, date: now, accountID: id, confirmed: false)]
        let confirmed = engine.forecast(accounts: [account], events: events, from: now, until: TestFixtures.date(2026, 9, 15), habitual: false)
        let habitual = engine.forecast(accounts: [account], events: events, from: now, until: TestFixtures.date(2026, 9, 15), habitual: true)
        XCTAssertEqual(confirmed.days.first?.total, 100)
        XCTAssertEqual(habitual.days.first?.total, 60)
        XCTAssertEqual(habitual.days.first?.estimatedExpenses[id], 10)
    }
    func testForecastUsesCivilDaysAcrossDaylightSavingAndThirtyDayHorizon() {
        var paris = calendar; paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        let start = paris.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let end = paris.date(byAdding: .day, value: 30, to: start)!
        let result = PlanningEngine(calendar: paris).forecast(accounts: [.init(id: UUID(), name: "Fixture", balance: 1000, threshold: 0, dailyVariable: 1)], events: [], from: start, until: end, habitual: true)
        XCTAssertEqual(result.days.count, 30); XCTAssertEqual(result.days.last?.total, 970)
        XCTAssertEqual(paris.component(.hour, from: result.days[2].date), 0)
    }
    func testUndatedSalaryDoesNotInventAnEncashmentAndCompletedImportDoesNotProveCoverage() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 500)
        try state.dataStore.saveExternalAccounts([account])
        try state.addIncomeSource(name: "Salary", amount: 1500, type: .salary, startDate: now, endDate: nil, isRecurring: true, isActive: true)
        let checkpoint = BankImportCheckpoint(accountID: account.id)
        checkpoint.initialImportCompleted = true; checkpoint.requestedHistoryStart = TestFixtures.date(2026, 1, 1)
        checkpoint.lastCompletedAt = now
        state.dataStore.container.mainContext.insert(checkpoint)
        try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertNil(state.nextPlannedSalary(on: now, calendar: calendar))
        XCTAssertEqual(state.cashflowForecast(on: now, calendar: calendar)?.remainingIncome, 0)
        XCTAssertFalse(state.planningForecast(on: now, habitual: true, calendar: calendar).estimationAvailable)
        let forecast = state.planningForecast(on: now, calendar: calendar)
        XCTAssertEqual(forecast.minimum, 500); XCTAssertEqual(forecast.unresolved.count, 1)
    }
    func testIncomeScheduleUsesCurrentSourceAndMonthlyOverridesAndStopsWhenInactive() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 500)
        try state.dataStore.saveExternalAccounts([account])
        try state.addIncomeSource(name: "Salary", amount: 1500, type: .salary, startDate: now, endDate: TestFixtures.date(2026, 10, 31), isRecurring: true, isActive: true)
        let source = try XCTUnwrap(state.incomeSources.first)
        var draft = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first)
        draft.dueDate = TestFixtures.date(2026, 9, 30); draft.accountID = account.id
        try state.planningWrite { try $0.saveCommitment(draft) }
        try state.addMonthlyIncomeOverride(incomeSourceID: source.id, month: TestFixtures.date(2026, 10, 1), amount: 1600, replacesSourceAmount: true)
        let entries = state.planningEvents(on: now, until: TestFixtures.date(2026, 12, 1), calendar: calendar)
        XCTAssertEqual(entries.map(\.amount), [1500, 1600]); XCTAssertEqual(entries.first?.accountID, account.id)
        XCTAssertEqual(state.nextPlannedSalary(on: now, calendar: calendar), calendar.startOfDay(for: draft.dueDate!))
        try state.updateIncomeSource(source, name: "Changed", amount: 1700, type: .salary, startDate: now, endDate: nil, isRecurring: true, isActive: false)
        XCTAssertTrue(state.planningEvents(on: now, until: TestFixtures.date(2026, 12, 1), calendar: calendar).isEmpty)
    }
    func testAlreadyReceivedPartialIncomeIsNotAddedTwiceAndOtherAccountsStayExcluded() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 500)
        try state.dataStore.saveExternalAccounts([account])
        try state.addIncomeSource(name: "Salary", amount: 1500, type: .salary, startDate: now, endDate: nil, isRecurring: true, isActive: true)
        let source = try XCTUnwrap(state.incomeSources.first)
        var draft = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first)
        draft.dueDate = now; draft.accountID = account.id
        let tx = TestFixtures.transaction(account: account, reference: "received", amount: 400, direction: .credit, dayOffset: 0)
        tx.linkedIncomeSourceID = source.id
        try state.dataStore.importBankTransactions([tx])
        try state.planningWrite { try $0.saveCommitment(draft) }
        XCTAssertEqual(state.cashflowForecast(on: now, calendar: calendar)?.remainingIncome, 1100)
        XCTAssertEqual(state.planningForecast(on: now, calendar: calendar).days.first?.total, 1600)
        account.isIncludedInTotals = false; try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertNil(state.planningForecast(on: now, calendar: calendar).minimum)
    }
    func testIncomeScheduleAndThresholdSurviveReopeningAndRemainProfileLocal() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store"), incomeID = UUID(), accountID = UUID()
        for pass in 0..<2 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let store = PeculeDataStore(container: container)
                if pass == 0 {
                    container.mainContext.insert(ExternalAccount(id: accountID, stableIdentifier: "fixture", currentUID: "", linkID: "", institution: .manual, name: "Fixture", currencyCode: "EUR", balance: 500))
                    var draft = CommitmentDraft(); draft.id = incomeID; draft.sourceKey = "income:\(incomeID)"; draft.sourceKind = "income"; draft.sourceID = incomeID
                    draft.title = "Salary"; draft.amount = 1500; draft.direction = "credit"; draft.accountID = accountID; draft.dueDate = now
                    try store.saveCommitment(draft); try store.saveThreshold(accountID: accountID, amount: 200)
                    try container.mainContext.save()
                } else {
                    XCTAssertEqual(try store.planningSnapshot().commitments.first?.dueDate, now)
                    XCTAssertEqual(try store.planningSnapshot().settings.first?.threshold, 200)
                }
            }
        }
        let other = try TestFixtures.makeAppState(seeded: false)
        XCTAssertTrue(other.planning.settings.isEmpty); XCTAssertTrue(other.planning.commitments.isEmpty)
    }
    // m029 : un loyer saisi avec sa prochaine date au mois de mars laissait six lignes en retard au calendrier en septembre,
    // puis une de plus chaque mois, et rendait la projection définitivement « incomplète ».
    func testOnlyTheLast45DaysOfUnmatchedOccurrencesReachTheCalendar() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 500)
        try state.dataStore.saveExternalAccounts([account])
        var rent = CommitmentDraft(); rent.title = "Loyer"; rent.amount = 800; rent.category = ExpenseCategory.other.storageValue
        rent.dueDate = TestFixtures.date(2026, 3, 5); rent.accountID = account.id
        try state.planningWrite { try $0.saveCommitment(rent) }
        let forecast = state.planningForecast(on: now, calendar: calendar)
        XCTAssertEqual(forecast.unresolved.compactMap(\.date), [(8, 5), (9, 5)].map { calendar.startOfDay(for: TestFixtures.date(2026, $0.0, $0.1)) },
                       "mars à juillet ne sont plus listés comme en retard")
        XCTAssertTrue(forecast.incomplete, "deux occurrences récentes restent à rapprocher : la projection le dit")
        XCTAssertEqual(state.planningForecast(on: TestFixtures.date(2026, 10, 12), calendar: calendar).unresolved.compactMap(\.date),
                       [(9, 5), (10, 5)].map { calendar.startOfDay(for: TestFixtures.date(2026, $0.0, $0.1)) },
                       "un mois plus tard, la liste ne grossit pas : la plus ancienne sort de la fenêtre")
    }
    func testTheUnresolvedListShownIsCappedWhileTheForecastStaysIncomplete() {
        let id = UUID(), accounts = [ForecastAccount(id: id, name: "Fixture", balance: 100, threshold: 0, dailyVariable: nil)]
        let many = (0..<12).map { _ in event(amount: -10, date: nil, accountID: id) }
        let result = engine.forecast(accounts: accounts, events: many, from: now, until: TestFixtures.date(2026, 9, 15), habitual: false)
        XCTAssertEqual(result.unresolved.count, 12, "la liste complète reste disponible")
        XCTAssertEqual(result.displayedUnresolved, Array(many.prefix(PlanningForecast.displayedUnresolvedLimit)))
        XCTAssertEqual(result.hiddenUnresolvedCount, 12 - PlanningForecast.displayedUnresolvedLimit)
        XCTAssertTrue(result.incomplete)
        let few = engine.forecast(accounts: accounts, events: Array(many.prefix(3)), from: now, until: TestFixtures.date(2026, 9, 15), habitual: false)
        XCTAssertEqual(few.displayedUnresolved.count, 3); XCTAssertEqual(few.hiddenUnresolvedCount, 0)
    }
}
