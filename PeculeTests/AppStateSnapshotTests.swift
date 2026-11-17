import XCTest
@testable import Pecule

@MainActor
final class AppStateSnapshotTests: XCTestCase {
    func testNormalLaunchIsEmptyAndNeverReseedsAfterReload() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        state.reload()
        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertTrue(state.purchases.isEmpty)
        XCTAssertTrue(state.habits.isEmpty)
        XCTAssertTrue(state.goals.isEmpty)
        XCTAssertTrue(state.incomeSources.isEmpty)
        XCTAssertFalse(AppAutomationConfiguration.inert.shouldSeedOnReload)
    }

    func testLegacyDemoCleanupPreservesBankRowsAndPersonalEntries() throws {
        let store = try TestFixtures.makeDataStore()
        try store.seedIfNeeded()
        let seed = try store.loadSnapshot()
        let modified = try XCTUnwrap(seed.purchases.first { $0.title == "Running Shoes" })
        try store.updatePurchase(modified, title: "Mes chaussures", amount: 99, date: modified.date, category: modified.category, merchant: "Mon magasin", notes: nil)
        try store.addSubscription(name: "Netflix", amount: 15.99, billingCycle: .monthly, category: "Streaming", nextBillingDate: TestFixtures.referenceDate, isActive: true)
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let transaction = TestFixtures.transaction(account: account, reference: "maif", amount: 74.86, direction: .debit, dayOffset: 0, category: .insurance)
        transaction.linkedSubscriptionID = seed.subscriptions.first { $0.name == "Netflix" }?.id
        try store.importBankTransactions([transaction])

        let state = AppState(dataStore: store)
        state.reload()

        XCTAssertEqual(state.subscriptions.map(\.name), ["Netflix"], "a personal entry sharing a demo merchant is retained")
        XCTAssertEqual(state.purchases.map(\.title), ["Mes chaussures"], "an edited fixture is retained")
        XCTAssertTrue(state.habits.isEmpty)
        XCTAssertTrue(state.goals.isEmpty)
        XCTAssertTrue(state.incomeSources.isEmpty)
        XCTAssertTrue(state.monthlyIncomeOverrides.isEmpty)
        XCTAssertEqual(state.bankTransactions.count, 1)
        XCTAssertEqual(state.bankTransactions.first?.amount, 74.86)
        XCTAssertNil(state.bankTransactions.first?.link)
        XCTAssertEqual(state.externalAccounts.count, 1)
    }

    // Le nettoyage des données de démonstration ne tourne plus qu'une fois par lancement : il
    // relisait sinon un instantané complet à chaque rechargement, donc à chaque annotation
    // d'opération. Ce test vérifie que l'économie ne change rien à ce que voit l'utilisateur.
    func testReloadingTwiceLeavesTheSameDataAsReloadingOnce() throws {
        let store = try TestFixtures.makeDataStore()
        try store.seedIfNeeded()
        let seed = try store.loadSnapshot()
        let kept = try XCTUnwrap(seed.purchases.first { $0.title == "Running Shoes" })
        try store.updatePurchase(kept, title: "Mes chaussures", amount: 99, date: kept.date, category: kept.category, merchant: "Mon magasin", notes: nil)

        let state = AppState(dataStore: store)
        state.reload()
        let afterFirst = (
            purchases: state.purchases.map(\.title).sorted(),
            subscriptions: state.subscriptions.map(\.name).sorted(),
            goals: state.goals.map(\.title).sorted(),
            incomes: state.incomeSources.map(\.name).sorted()
        )

        state.reload()

        XCTAssertEqual(state.purchases.map(\.title).sorted(), afterFirst.purchases)
        XCTAssertEqual(state.subscriptions.map(\.name).sorted(), afterFirst.subscriptions)
        XCTAssertEqual(state.goals.map(\.title).sorted(), afterFirst.goals)
        XCTAssertEqual(state.incomeSources.map(\.name).sorted(), afterFirst.incomes)
        XCTAssertEqual(state.purchases.map(\.title), ["Mes chaussures"], "l'entrée modifiée survit aux deux passes")
    }

    func testLinkedBankSpendingUsesActualDebitEvenWithOldManualPlan() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        try state.addSubscription(name: "MAIF", amount: 50, billingCycle: .monthly, category: ExpenseCategory.insurance.storageValue, nextBillingDate: TestFixtures.date(2026, 2, 1), isActive: true)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let transaction = TestFixtures.transaction(account: account, reference: "maif", amount: 74.86, direction: .debit, dayOffset: 0, category: .insurance)
        try state.dataStore.importBankTransactions([transaction])
        state.reload()
        state.prefersBankAmounts = true
        let row = try XCTUnwrap(state.budgetOverview(for: TestFixtures.referenceDate).first { $0.category == .insurance })
        XCTAssertEqual(row.spentAmount, 74.86)
        XCTAssertNil(row.plannedAmount)
        XCTAssertFalse(row.isOverspent)
        XCTAssertTrue(state.upcomingSubscriptions(on: TestFixtures.referenceDate).isEmpty)
    }

    func testBankRecurrenceNeedsConfirmationAndManualSubscriptionDoesNotDoubleCount() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 1000)]).first)
        let transactions = (6...8).map { month in
            BankTransaction(externalID: "cursor-\(month)", accountID: account.id, amount: 20, direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.date(2026, month, 20), label: "CURSOR", category: ExpenseCategory.subscriptions.storageValue)
        }
        try state.dataStore.importBankTransactions(transactions)
        state.reload()
        let date = TestFixtures.date(2026, 9, 15)
        let forecast = try XCTUnwrap(state.cashflowForecast(on: date, calendar: TestFixtures.utcCalendar()))
        XCTAssertEqual(forecast.remainingFixedCharges, 0, "Unconfirmed bank detection is a hypothesis")
        var draft = try XCTUnwrap(state.commitmentDrafts(on: date).first { $0.sourceKind == "detected" })
        draft.status = "confirmed"
        try state.planningWrite { try $0.saveCommitment(draft) }
        XCTAssertEqual(state.cashflowForecast(on: date)?.remainingFixedCharges, 20)

        try state.addSubscription(name: "CURSOR", amount: 19, billingCycle: .monthly, category: ExpenseCategory.subscriptions.storageValue, nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: true)
        XCTAssertEqual(state.cashflowForecast(on: date)?.remainingFixedCharges, 19, "Explicit manual subscription supersedes its detected counterpart without counting both")
    }

    // M004 : trois mois complets de courses sont importés, mais aucun n'est certifié par la passerelle (ni un premier mouvement
    // ni un import terminé ne prouvent un mois complet). Le solde prévu est absent, comme la lecture habituelle du calendrier.
    func testMonthEndBalanceIsWithheldUntilTheBankCoverageIsCertified() throws {
        let calendar = TestFixtures.utcCalendar(), date = TestFixtures.date(2026, 9, 14)
        let observation = MonthlyObservationService(calendar: calendar, referenceDateProvider: { date })
        let state = AppState(dataStore: try TestFixtures.makeDataStore(), observationService: observation)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 1000)]).first)
        let groceries = [(6, 300), (7, 310), (8, 310)].map { month, amount -> BankTransaction in
            let row = TestFixtures.transaction(account: account, reference: "groceries-\(month)", amount: Decimal(amount), direction: .debit, dayOffset: 0, category: .groceries)
            row.bookingDate = TestFixtures.date(2026, month, 10); return row
        }
        try state.dataStore.importBankTransactions(groceries); state.reload()
        XCTAssertEqual(state.observedMonths.filter(\.isComplete).count, 3)

        let withheld = try XCTUnwrap(state.cashflowForecast(on: date, calendar: calendar))
        XCTAssertEqual(withheld.openingBalance, 1000)
        XCTAssertEqual(withheld.completeMonthsUsed, 0)
        XCTAssertEqual(withheld.closingBalanceAvailability, .insufficientHistory)
        XCTAssertNil(withheld.expectedClosingBalance); XCTAssertNil(withheld.bestClosingBalance); XCTAssertNil(withheld.worstClosingBalance)
        XCTAssertFalse(state.planningForecast(on: date, habitual: true, calendar: calendar).estimationAvailable, "même décision que la lecture habituelle du calendrier")

        // Les mêmes mois, une fois certifiés : les dépenses variables observées font partie de la prévision.
        let certified = try XCTUnwrap(state.cashflowForecast(on: date, calendar: calendar, baselineMonths: state.observedMonths))
        XCTAssertEqual(certified.completeMonthsUsed, 3)
        XCTAssertEqual(certified.dailyVariableRate, 10)
        XCTAssertEqual(certified.expectedClosingBalance, 830, "1 000 € − 17 jours à 10 €")
    }

    func testMonthEndBalanceIsUnknownWithoutAnyAccount() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        let forecast = try XCTUnwrap(state.cashflowForecast(on: TestFixtures.date(2026, 9, 14), calendar: TestFixtures.utcCalendar()))
        XCTAssertEqual(forecast.closingBalanceAvailability, .unknownBalance)
        XCTAssertNil(forecast.expectedClosingBalance)
    }

    func testUnlinkedSalaryCountsAndManualPlansDoNotInflateObservedTotals() throws {
        let state = AppState(dataStore: try TestFixtures.makeDataStore())
        try state.addIncomeSource(name: "Ancien salaire", amount: 3000, type: .salary, startDate: TestFixtures.date(2026, 1, 1), endDate: nil, isRecurring: true, isActive: true)
        try state.addSubscription(name: "Ancien abonnement", amount: 20, billingCycle: .monthly, category: ExpenseCategory.subscriptions.storageValue, nextBillingDate: TestFixtures.date(2026, 2, 1), isActive: true)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "salary", amount: 1500, direction: .credit, dayOffset: 0),
            TestFixtures.transaction(account: account, reference: "maif", amount: 74.86, direction: .debit, dayOffset: 0, category: .insurance),
        ])
        state.reload()
        state.prefersBankAmounts = true
        let summary = state.monthlyFinancialSummary(for: TestFixtures.referenceDate)
        XCTAssertEqual(summary.totalEstimatedIncome, 1500)
        XCTAssertEqual(summary.totalExpenses, 74.86)
        XCTAssertEqual(summary.remainingToLive, 1425.14)
        XCTAssertEqual(state.decisionMetrics(on: TestFixtures.referenceDate).remainingToLive, 1425.14)
        let emptyMonth = state.monthlyFinancialSummary(for: TestFixtures.date(2026, 8, 1))
        XCTAssertEqual(emptyMonth.totalExpenses, 0)
        XCTAssertEqual(emptyMonth.totalEstimatedIncome, 0)
    }

    func testCurrentSnapshotCarriesBankDataAlongsideManualEntries() throws {
        let appState = try TestFixtures.makeAppState()
        let account = try XCTUnwrap(try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 100)]).first)
        try appState.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "cb-1", amount: TestFixtures.decimal("12.50"), direction: .debit, dayOffset: -1),
        ])
        appState.reload()

        let snapshot = appState.currentSnapshot

        XCTAssertEqual(snapshot.subscriptions.count, appState.subscriptions.count)
        XCTAssertEqual(snapshot.budgetRules.count, appState.budgetRules.count)
        XCTAssertEqual(snapshot.externalAccounts.map(\.id), [account.id])
        XCTAssertEqual(snapshot.bankTransactions.map(\.externalID), ["hash-1#cb-1"])
        XCTAssertEqual(snapshot.budgetCategories, BudgetRule.defaultCategories)
    }

    func testSnapshotDefaultsKeepBankCollectionsEmpty() {
        let snapshot = AppDataSnapshot(subscriptions: [], purchases: [], goals: [], habits: [])

        XCTAssertTrue(snapshot.externalAccounts.isEmpty)
        XCTAssertTrue(snapshot.bankTransactions.isEmpty)
    }
}
