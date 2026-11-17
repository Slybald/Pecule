import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class MonthlyBudgetTests: XCTestCase {
    private let date = TestFixtures.referenceDate
    private let calendar = TestFixtures.utcCalendar()

    func testMarginUsesNetSpendingAndKnownChargesWithAbsentZeroAndOverrunStates() {
        let charges = [CashflowForecast.UpcomingCharge(id: UUID(), name: "Mobile", amount: 190, date: date)]
        XCTAssertNil(MonthlyBudgetSummary(limit: nil, expenses: 925, upcoming: charges, source: .bank).margin)
        XCTAssertEqual(MonthlyBudgetSummary(limit: 1500, expenses: 925, upcoming: charges, source: .bank).margin, 385)
        XCTAssertEqual(MonthlyBudgetSummary(limit: 1000, expenses: 925, upcoming: charges, source: .bank).margin, -115)
        XCTAssertEqual(MonthlyBudgetSummary(limit: 0, expenses: 925, upcoming: charges, source: .bank).margin, -1115)
        XCTAssertEqual(MonthlyBudgetSummary(limit: 1500, expenses: 1115, upcoming: charges, source: .planned).margin, 385)
    }

    func testLimitIsScopedToMonthNotCategoriesOrAnotherProfile() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let other = try TestFixtures.makeAppState(seeded: false)
        try state.setBudgetRule(category: "Courses", monthlyAmount: 300)
        try state.setMonthlySpendingLimit(0, for: date, calendar: calendar)
        XCTAssertEqual(state.monthlySpendingLimit(for: date, calendar: calendar), 0)
        XCTAssertNil(state.monthlySpendingLimit(for: TestFixtures.date(2026, 10, 1), calendar: calendar))
        XCTAssertNil(other.monthlySpendingLimit(for: date, calendar: calendar))
        XCTAssertEqual(state.budgetRule(for: "Courses")?.monthlyAmount, 300)
        try state.setMonthlySpendingLimit(1234.567, for: date, calendar: calendar)
        XCTAssertEqual(state.monthlySpendingLimit(for: date, calendar: calendar), TestFixtures.decimal("1234.57"))
        XCTAssertEqual(try state.dataStore.monthlySpendingLimits().count, 1)
        XCTAssertThrowsError(try state.setMonthlySpendingLimit(-1, for: date, calendar: calendar))
        XCTAssertThrowsError(try state.setMonthlySpendingLimit(.nan, for: date, calendar: calendar))
        try state.setMonthlySpendingLimit(nil, for: date, calendar: calendar)
        XCTAssertNil(state.monthlySpendingLimit(for: date, calendar: calendar))
        state.invalidateProfile()
        XCTAssertThrowsError(try state.setMonthlySpendingLimit(100, for: date, calendar: calendar))
    }

    func testRecordedRefundsAndReservationsDoNotChangeBudgetOrBankBalance() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        state.prefersBankAmounts = true
        let account = TestFixtures.linkedAccount(balance: 1240)
        try state.dataStore.saveExternalAccounts([account])
        let debit = TestFixtures.transaction(account: account, reference: "expense", amount: 100, direction: .debit, dayOffset: -1)
        let refund = TestFixtures.transaction(account: account, reference: "refund", amount: 30, direction: .credit, dayOffset: 0)
        refund.natureOverride = "refund"
        let internalTransfer = TestFixtures.transaction(account: account, reference: "transfer", amount: 400, direction: .debit, dayOffset: 0)
        internalTransfer.isInternalTransfer = true
        [debit, refund, internalTransfer].forEach(state.dataStore.container.mainContext.insert)
        try state.dataStore.container.mainContext.save()
        try state.setMonthlySpendingLimit(1000, for: date, calendar: calendar)
        let before = state.monthlyBudget(on: date, now: date, calendar: calendar)
        XCTAssertEqual(before.expenses, 70)
        XCTAssertEqual(before.margin, 930)
        try state.addGoal(title: "Trip", targetAmount: 1000, currentAmount: 0, targetDate: date, category: "Travel")
        let goal = try XCTUnwrap(state.goals.first)
        try state.dataStore.reserveForGoal(id: goal.id, amount: 80, date: date)
        state.reload()
        XCTAssertEqual(state.monthlyBudget(on: date, now: date, calendar: calendar).margin, 930)
        XCTAssertEqual(state.monthlyFinancialSummary(for: date, calendar: calendar).reservedForGoals, 80)
        XCTAssertEqual(account.balance, 1240)
    }

    func testAlreadyBookedLinkedChargeIsNotSubtractedAgain() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        state.prefersBankAmounts = true
        let account = TestFixtures.linkedAccount(balance: 900)
        try state.dataStore.saveExternalAccounts([account])
        try state.addSubscription(name: "Mobile", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: date, isActive: true)
        let subscription = try XCTUnwrap(state.subscriptions.first)
        let payment = TestFixtures.transaction(account: account, reference: "paid", amount: 20, direction: .debit, dayOffset: 0)
        payment.linkedSubscriptionID = subscription.id
        state.dataStore.container.mainContext.insert(payment)
        try state.dataStore.container.mainContext.save()
        try state.setMonthlySpendingLimit(100, for: date, calendar: calendar)
        let summary = state.monthlyBudget(on: date, now: date, calendar: calendar)
        XCTAssertEqual(summary.expenses, 20)
        XCTAssertTrue(summary.upcoming.isEmpty)
        XCTAssertEqual(summary.margin, 80)
    }

    func testTrajectoryRespectsDaysRefundsAndMonthBoundary() throws {
        let account = TestFixtures.linkedAccount()
        func transaction(_ amount: Decimal, _ day: Int, refund: Bool = false) -> BankTransaction {
            let t = BankTransaction(externalID: UUID().uuidString, accountID: account.id, amount: amount,
                                    direction: refund ? .credit : .debit, currencyCode: "EUR",
                                    bookingDate: TestFixtures.date(2026, 9, day), label: "Test")
            if refund { t.natureOverride = "refund" }
            return t
        }
        let points = MonthlyBudgetService.trajectory(transactions: [transaction(100, 2), transaction(30, 3, refund: true), transaction(999, 20)], on: TestFixtures.date(2026, 9, 14), calendar: calendar)
        XCTAssertEqual(points.count, 14)
        XCTAssertEqual(points.first?.amount, 0)
        XCTAssertEqual(points.last?.amount, 70)
        XCTAssertEqual(points[1].amount, 100)
    }

    // Le graphique de l'accueil et le montant dépensé affiché au-dessus sont calculés par deux
    // chemins distincts : la courbe à partir des opérations du mois, le total à partir du résumé
    // mensuel. S'ils divergent, la courbe s'arrête sur un autre montant que celui qu'elle illustre.
    func testTrajectoryEndsOnTheSpentTotalShownAboveIt() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        state.prefersBankAmounts = true
        let accounts = try state.dataStore.saveExternalAccounts([
            TestFixtures.linkedAccount(stableIdentifier: "hash-1", balance: 1240),
            TestFixtures.linkedAccount(stableIdentifier: "hash-2", balance: 300),
        ])
        let included = try XCTUnwrap(accounts.first { $0.stableIdentifier == "hash-1" })
        let excluded = try XCTUnwrap(accounts.first { $0.stableIdentifier == "hash-2" })

        let expense = TestFixtures.transaction(account: included, reference: "expense", amount: 100, direction: .debit, dayOffset: -1)
        let refund = TestFixtures.transaction(account: included, reference: "refund", amount: 30, direction: .credit, dayOffset: 0)
        refund.natureOverride = "refund"
        let transfer = TestFixtures.transaction(account: included, reference: "transfer", amount: 400, direction: .debit, dayOffset: 0)
        transfer.isInternalTransfer = true
        let pending = TestFixtures.transaction(account: included, reference: "pending", amount: 50, direction: .debit, dayOffset: 0)
        pending.status = "pending"
        let foreign = TestFixtures.transaction(account: included, reference: "foreign", amount: 20, direction: .debit, dayOffset: 0)
        foreign.currencyCode = "USD"
        let ignored = TestFixtures.transaction(account: included, reference: "ignored", amount: 15, direction: .debit, dayOffset: 0)
        ignored.isIgnored = true
        let elsewhere = TestFixtures.transaction(account: excluded, reference: "elsewhere", amount: 60, direction: .debit, dayOffset: -2)
        [expense, refund, transfer, pending, foreign, ignored, elsewhere].forEach(state.dataStore.container.mainContext.insert)
        try state.dataStore.container.mainContext.save()
        try state.setExternalAccount(excluded, includedInTotals: false)

        let summary = state.monthlyBudget(on: date, now: date, calendar: calendar)
        XCTAssertEqual(summary.expenses, 70, "seuls la dépense et son remboursement comptent")

        let points = MonthlyBudgetService.trajectory(
            transactions: state.bankTransactions(in: date, calendar: calendar),
            on: date,
            calendar: calendar
        )
        XCTAssertEqual(points.last?.amount, summary.expenses, "la courbe finit sur le montant affiché")
    }

    // Cadrer le graphique sur le plafond écrase la courbe en bas quand on dépense peu. On cadre
    // alors sur les dépenses, et le plafond cesse d'être tracé pour être écrit : jamais de ligne
    // hors échelle qui laisserait croire que la limite est proche.
    func testChartFitsSpendingWhileTheLimitStaysFarAbove() {
        let low = MonthlyBudgetService.chartScale(points: [], knownTotal: TestFixtures.decimal("50.19"), limit: 1500)
        XCTAssertFalse(low.showsLimit, "le plafond n'est pas tracé tant qu'il reste hors de portée")
        XCTAssertEqual(low.ceiling, TestFixtures.decimal("62.7375"))

        let engaged = MonthlyBudgetService.chartScale(points: [], knownTotal: 600, limit: 1500)
        XCTAssertTrue(engaged.showsLimit, "dès le tiers dépensé, le plafond redevient le repère")
        XCTAssertEqual(engaged.ceiling, 1500)

        let overrun = MonthlyBudgetService.chartScale(points: [], knownTotal: 1800, limit: 1500)
        XCTAssertTrue(overrun.showsLimit)
        XCTAssertEqual(overrun.ceiling, 2250, "un dépassement reste visible au-dessus de la limite")

        XCTAssertEqual(MonthlyBudgetService.chartScale(points: [], knownTotal: 80, limit: nil).ceiling, 100)
        XCTAssertFalse(MonthlyBudgetService.chartScale(points: [], knownTotal: 80, limit: nil).showsLimit)
        XCTAssertEqual(MonthlyBudgetService.chartScale(points: [], knownTotal: 0, limit: 1500).ceiling, 10,
                       "un mois sans dépense garde une hauteur minimale plutôt qu'un graphique plat")
    }

    func testRefundDoesNotHideEarlierSpendingPeakOrBudgetCrossing() {
        let points = [MonthlyBudgetService.Point(date: date, amount: 1200),
                      MonthlyBudgetService.Point(date: date.addingTimeInterval(86400), amount: 50)]
        let scale = MonthlyBudgetService.chartScale(points: points, knownTotal: 50, limit: 1000)
        XCTAssertEqual(scale.floor, 0)
        XCTAssertEqual(scale.ceiling, 1500, "le pic avant remboursement reste visible")
        XCTAssertTrue(scale.showsLimit, "le dépassement passé garde son repère budgétaire")
    }

    func testRefundLargerThanMonthSpendingRemainsVisibleBelowZero() {
        let refund = BankTransaction(externalID: "refund-prior-month", accountID: UUID(), amount: 200,
                                     direction: .credit, currencyCode: "EUR", bookingDate: date, label: "Refund")
        refund.natureOverride = "refund"
        let points = MonthlyBudgetService.trajectory(transactions: [refund], on: date, calendar: calendar)
        XCTAssertEqual(points.last?.amount, -200)
        for limit: Decimal? in [nil, 0, 1500] {
            let scale = MonthlyBudgetService.chartScale(points: points, knownTotal: -200, limit: limit)
            XCTAssertEqual(scale.floor, -250)
            XCTAssertGreaterThan(scale.ceiling, 0, "zéro reste dans le domaine visible")
            XCTAssertTrue(points.allSatisfy { $0.amount >= scale.floor && $0.amount <= scale.ceiling })
        }
    }

    func testChartKeepsNegativeTroughAfterSpendingRecoversAndIncludesKnownCharges() {
        let points = [MonthlyBudgetService.Point(date: date, amount: -200),
                      MonthlyBudgetService.Point(date: date.addingTimeInterval(86400), amount: 50)]
        let scale = MonthlyBudgetService.chartScale(points: points, knownTotal: 300, limit: nil)
        XCTAssertEqual(scale.floor, -250, "le remboursement passé reste visible après la reprise des dépenses")
        XCTAssertEqual(scale.ceiling, 375, "les échéances connues restent prises en compte dans le cadrage")
        XCTAssertFalse(scale.showsLimit)
    }

    func testHistoricalMonthDoesNotUseCurrentUpcomingSchedule() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addSubscription(name: "Next", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: true)
        XCTAssertEqual(state.monthlyBudget(on: date, now: date, calendar: calendar).upcoming.count, 1)
        XCTAssertTrue(state.monthlyBudget(on: TestFixtures.date(2026, 8, 14), now: date, calendar: calendar).upcoming.isEmpty)
    }

    // This reproduces the actual pre-change schema using the original current model types,
    // V6 changed BankTransaction, so that type now comes from its frozen V4 shape.
    // The other model shapes still match the original pre-V5 production types.
    enum OriginalV4: VersionedSchema {
        typealias BankTransaction = PeculeSchemaV4.BankTransaction
        static var versionIdentifier: Schema.Version { .init(4, 0, 0) }
        static var models: [any PersistentModel.Type] {
            [Subscription.self, Purchase.self, Goal.self, Habit.self, IncomeSource.self,
             MonthlyIncomeOverride.self, BudgetRule.self, BudgetOverride.self, ExternalAccount.self,
             BankTransaction.self, BankImportCheckpoint.self, BankPendingAuthorization.self, CategoryRecord.self, GoalContribution.self]
        }
    }

    func testActualV4StoreMigratesWithoutLosingAnnotationsCategoriesOrReservationsThenReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "v4.store"), goalID = UUID(), transactionID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: OriginalV4.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            let goal = Goal(id: goalID, title: "Trip", targetAmount: 1000, currentAmount: 250, targetDate: date, category: "Catégorie Ω", isArchived: false)
            goal.intention = "duration"; goal.durationMonths = 6; goal.startedAt = date; goal.showsFundingHelp = true
            let transaction = OriginalV4.BankTransaction(id: transactionID, externalID: "installment", accountID: UUID(), amount: 70, direction: .debit, currencyCode: "EUR", bookingDate: date, label: "Test")
            transaction.userNote = "Keep"; transaction.internalTransferOverride = false
            transaction.installmentDecision = "confirmed"; transaction.installmentCount = 3; transaction.installmentNumber = 1
            context.insert(goal); context.insert(transaction)
            context.insert(CategoryRecord(name: "Catégorie Ω"))
            context.insert(GoalContribution(goalID: goalID, date: date, amount: 80))
            context.insert(BudgetRule(category: "Catégorie Ω", monthlyAmount: 200))
            try context.save()
        }
        for index in 0..<2 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let store = PeculeDataStore(container: container)
                let snapshot = try store.loadSnapshot()
                let goal = try XCTUnwrap(snapshot.goals.first), transaction = try XCTUnwrap(snapshot.bankTransactions.first)
                XCTAssertEqual(goal.id, goalID); XCTAssertEqual(goal.currentAmount, 250)
                XCTAssertEqual(goal.intention, "duration"); XCTAssertEqual(goal.durationMonths, 6); XCTAssertTrue(goal.showsFundingHelp)
                XCTAssertEqual(transaction.id, transactionID); XCTAssertEqual(transaction.userNote, "Keep")
                XCTAssertEqual(transaction.installmentCount, 3); XCTAssertEqual(transaction.installmentDecision, "confirmed")
                XCTAssertEqual(transaction.internalTransferOverride, false)
                XCTAssertEqual(try store.goalContributions().first?.amount, 80)
                XCTAssertEqual(snapshot.budgetRules.first?.monthlyAmount, 200)
                XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CategoryRecord>()).first?.name, "Catégorie Ω")
                if index == 0 {
                    XCTAssertTrue(try store.monthlySpendingLimits().isEmpty)
                    try store.setMonthlySpendingLimit(1500, for: date, calendar: calendar)
                } else { XCTAssertEqual(try store.monthlySpendingLimits().first?.amount, 1500) }
            }
        }
    }
}
