import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class ProvisionTests: XCTestCase {
    private let now = TestFixtures.date(2026, 9, 14)
    private let calendar = TestFixtures.utcCalendar()
    private func setup(target: Decimal = 600) throws -> (AppState, UUID, ExternalAccount) {
        let state = try TestFixtures.makeAppState(seeded: false), id = UUID()
        let account = TestFixtures.linkedAccount(balance: 1000)
        try state.dataStore.saveExternalAccounts([account])
        try state.planningWrite { try $0.saveProvision(id: id, title: "Insurance", target: target, dueDate: TestFixtures.date(2027, 3, 14), renewal: "yearly", category: "other", now: now) }
        state.prefersBankAmounts = true
        return (state, id, account)
    }
    func testSixMonthContributionAndCarryBetweenMonthsDoNotChangeBankBalance() throws {
        let (state, id, account) = try setup()
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.monthlyNeeded, 100)
        try state.dataStore.reserveForGoal(id: id, amount: 100, date: now); state.reload()
        XCTAssertEqual(state.provisionSummaries(on: TestFixtures.date(2026, 10, 14), calendar: calendar).first?.reserved, 100)
        XCTAssertEqual(state.provisionSummaries(on: TestFixtures.date(2026, 10, 14), calendar: calendar).first?.monthlyNeeded, 100)
        XCTAssertEqual(state.externalAccount(id: account.id)?.balance, 1000)
    }
    func testPaymentConsumesPriorReserveAtomicallyWithoutChargingTheMonthTwice() throws {
        let (state, id, account) = try setup(target: 100)
        try state.dataStore.reserveForGoal(id: id, amount: 100, date: TestFixtures.date(2026, 8, 14))
        let tx = TestFixtures.transaction(account: account, reference: "insurance", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        let before = state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 0)
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.paid, 100)
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive, before + 100)
        XCTAssertEqual(state.externalAccount(id: account.id)?.balance, 1000)
        XCTAssertThrowsError(try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) })
        XCTAssertEqual(state.planning.provisionPayments.count, 1)
        try state.planningWrite { try $0.removeProvisionPayment(transactionID: tx.id) }
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 100)
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive, before)
    }
    func testPartialPaymentOnlyConsumesAvailableReserveAndWithdrawnPaymentRestoresIt() throws {
        let (state, id, account) = try setup(target: 100)
        try state.dataStore.reserveForGoal(id: id, amount: 60, date: TestFixtures.date(2026, 8, 14))
        let tx = TestFixtures.transaction(account: account, reference: "partial", amount: 80, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.provisionPayments.first?.amount, 60)
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 0)
        let replacement = TestFixtures.transaction(account: account, reference: "partial", amount: 40, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([replacement]); state.reload()
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 20)
        _ = try state.dataStore.pruneBankTransactions(accountID: account.id, bookedOnOrAfter: TestFixtures.date(2026, 9, 1), keeping: [])
        state.reload()
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 60)
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.paid, 0)
        XCTAssertEqual(state.goals.first?.currentAmount, 60)
    }
    func testPendingIncomeForeignCurrencyAndFuturePaymentsAreRejectedWithoutMutation() throws {
        let (state, id, account) = try setup()
        for index in 0..<4 {
            let tx = TestFixtures.transaction(account: account, reference: "invalid-\(index)", amount: 100, direction: index == 0 ? .credit : .debit, dayOffset: 0)
            if index == 1 { tx.status = "pending" }
            if index == 2 { tx.currencyCode = "USD" }
            if index == 3 { tx.bookingDate = TestFixtures.date(2026, 9, 25) }
            try state.dataStore.importBankTransactions([tx]); state.reload()
            XCTAssertThrowsError(try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) })
        }
        XCTAssertTrue(state.planning.provisionPayments.isEmpty); XCTAssertTrue(state.goalContributions.isEmpty)
    }
    func testAReservationAfterAnOldPaymentDoesNotRetroactivelyFundIt() throws {
        let (state, id, account) = try setup()
        try state.dataStore.reserveForGoal(id: id, amount: 100, date: now)
        let tx = TestFixtures.transaction(account: account, reference: "old", amount: 100, direction: .debit, dayOffset: -5)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.provisionPayments.first?.amount, 0)
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 100)
    }
    func testExcludedAccountsAndManualBudgetDoNotGetAConsumptionCredit() throws {
        let (state, id, account) = try setup(target: 100)
        try state.dataStore.reserveForGoal(id: id, amount: 100, date: TestFixtures.date(2026, 8, 14))
        let tx = TestFixtures.transaction(account: account, reference: "paid", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        state.prefersBankAmounts = false
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).reservedForGoals, 0)
        state.prefersBankAmounts = true; account.isIncludedInTotals = false
        try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).reservedForGoals, 0)
    }
    func testRenewalKeepsOldEvidenceAndCarriesOnlyUnusedReserves() throws {
        let (state, id, account) = try setup(target: 100)
        try state.dataStore.reserveForGoal(id: id, amount: 120, date: TestFixtures.date(2026, 8, 14))
        let tx = TestFixtures.transaction(account: account, reference: "paid", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        XCTAssertThrowsError(try state.planningWrite { try $0.renewProvision(goalID: id, now: now, calendar: calendar) })
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        let budgetBefore = state.monthlyFinancialSummary(for: now, calendar: calendar).reservedForGoals
        try state.planningWrite { try $0.renewProvision(goalID: id, now: now, calendar: calendar) }
        let current = try XCTUnwrap(state.provisionSummaries(on: now, calendar: calendar).first)
        XCTAssertNotEqual(current.goalID, id); XCTAssertEqual(current.dueDate, TestFixtures.date(2028, 3, 14))
        XCTAssertEqual(current.reserved, 20); XCTAssertEqual(current.paid, 0)
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).reservedForGoals, budgetBefore)
        XCTAssertEqual(state.planning.provisionPayments.first?.goalID, id)
        XCTAssertThrowsError(try state.planningWrite { try $0.renewProvision(goalID: id, now: now, calendar: calendar) })
    }
    // M019 : l'écart de mois était mesuré entre deux instants à midi UTC, avec le calendrier de l'appareil. À Paris, le passage
    // à l'heure d'hiver faisait compter un mois de moins : la mensualité suggérée était surévaluée de 33 % à 100 %.
    private var paris: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
    }
    private func parisDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testMonthlyContributionCountsCalendarMonthsAcrossTheDaylightSavingChange() {
        let engine = PlanningEngine(calendar: paris)
        func monthly(now: Date, due: Date) -> Decimal { engine.provisionContribution(target: 1000, reserved: 0, due: due, now: now) }
        XCTAssertEqual(monthly(now: parisDate(2026, 10, 5), due: parisDate(2027, 2, 15)), 250, "octobre à février : 4 mois, 3 donnaient 333,34")
        XCTAssertEqual(monthly(now: parisDate(2026, 9, 10), due: parisDate(2026, 11, 20)), 500, "septembre à novembre : 2 mois, 1 donnait 1 000")
        XCTAssertEqual(monthly(now: parisDate(2026, 6, 1), due: parisDate(2026, 12, 31)), TestFixtures.decimal("166.67"), "juin à décembre : 6 mois")
        // Sens inverse (heure d'hiver vers heure d'été), qui était déjà juste.
        XCTAssertEqual(monthly(now: parisDate(2027, 2, 10), due: parisDate(2027, 6, 20)), 250)
        // Une échéance saisie à minuit le 1er (la veille à 23 h en UTC) appartient au mois local.
        XCTAssertEqual(monthly(now: parisDate(2026, 10, 5), due: parisDate(2027, 2, 1, hour: 0)), 250)
        // Dans le mois même, ou en retard : au moins un mois, jamais de division par zéro ni par un négatif.
        XCTAssertEqual(monthly(now: parisDate(2026, 10, 5), due: parisDate(2026, 10, 28)), 1000)
        XCTAssertEqual(monthly(now: parisDate(2026, 10, 5), due: parisDate(2026, 8, 1)), 1000)
        // L'année change : décembre à mars.
        XCTAssertEqual(monthly(now: parisDate(2026, 12, 20), due: parisDate(2027, 3, 14)), TestFixtures.decimal("333.34"))
    }
    func testProvisionSummaryUsesTheCalendarOfTheDevice() throws {
        let state = try TestFixtures.makeAppState(seeded: false), id = UUID()
        let now = parisDate(2026, 10, 5)
        try state.planningWrite { try $0.saveProvision(id: id, title: "Taxe", target: 1000, dueDate: parisDate(2027, 2, 15), renewal: "none", category: "other", now: now) }
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: paris).first?.monthlyNeeded, 250)
        try state.dataStore.reserveForGoal(id: id, amount: 400, date: now); state.reload()
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: paris).first?.monthlyNeeded, 150, "(1 000 − 400) / 4")
    }
    func testProfileInvalidationRefusesProvisionWrites() throws {
        let (state, id, _) = try setup()
        let second = try TestFixtures.makeAppState(seeded: false)
        XCTAssertTrue(second.planning.provisions.isEmpty)
        state.invalidateProfile()
        XCTAssertThrowsError(try state.planningWrite { try $0.saveProvision(id: id, title: "No", target: 10, dueDate: now, renewal: "none", category: "other") })
    }
    func testTemporaryStatesDoNotShareOrOverwritePersistentFinancialPreferences() throws {
        let key = "test.preferences." + UUID().uuidString
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let first = AppState(dataStore: try TestFixtures.makeDataStore(), preferenceKey: key)
        XCTAssertTrue(first.prefersBankAmounts)
        first.prefersBankAmounts = true
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        first.prefersBankAmounts = false
        let second = AppState(dataStore: try TestFixtures.makeDataStore(), preferenceKey: key)
        XCTAssertTrue(second.prefersBankAmounts)
    }

    func testProvisionAndPaymentReopenWithoutDuplicatingConsumption() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "provision.store"), goalID = UUID()
        for pass in 0..<3 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let store = PeculeDataStore(container: container)
                if pass == 0 {
                    let account = TestFixtures.linkedAccount(balance: 1000)
                    try store.saveExternalAccounts([account])
                    try store.saveProvision(id: goalID, title: "Insurance", target: 100, dueDate: now, renewal: "yearly", category: "other")
                    try container.mainContext.save()
                    try store.reserveForGoal(id: goalID, amount: 100, date: TestFixtures.date(2026, 8, 1))
                    let tx = TestFixtures.transaction(account: account, reference: "persist", amount: 40, direction: .debit, dayOffset: 0)
                    try store.importBankTransactions([tx])
                    try store.applyProvisionPayment(goalID: goalID, transactionID: tx.id, now: now, calendar: calendar)
                    try container.mainContext.save()
                } else {
                    try store.reconcileProvisionPayments(now: now, calendar: calendar)
                    XCTAssertEqual(try store.planningFetch(GoalProvision.self).first?.renewal, "yearly")
                    XCTAssertEqual(try store.planningFetch(ProvisionPayment.self).count, 1)
                    XCTAssertEqual(try store.goalContributions().count, 2)
                    XCTAssertEqual(try store.planningFetch(Goal.self).first?.currentAmount, 60)
                    XCTAssertEqual(GoalFundingService().totalReserved(goalID: goalID, contributions: try store.goalContributions()), 60)
                }
            }
        }
    }
    func testMovingPaymentBeforeItsReserveRestoresFundsWithoutMovingMoney() throws {
        let (state, id, account) = try setup(target: 100)
        try state.dataStore.reserveForGoal(id: id, amount: 100, date: TestFixtures.date(2026, 9, 10))
        let tx = TestFixtures.transaction(account: account, reference: "moved", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        let moved = TestFixtures.transaction(account: account, reference: "moved", amount: 100, direction: .debit, dayOffset: -7)
        try state.dataStore.importBankTransactions([moved]); state.reload()
        XCTAssertEqual(state.provisionSummaries(on: now, calendar: calendar).first?.reserved, 100)
        XCTAssertEqual(state.externalAccount(id: account.id)?.balance, 1000)
    }

}
