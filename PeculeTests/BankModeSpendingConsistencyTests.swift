import XCTest
@testable import Pecule

// M006, mode bancaire : l'accueil, le budget, le graphique et Opérations passent par la même règle et donnent
// le même total pour un même mois, achats saisis à la main compris.
@MainActor
final class BankModeSpendingConsistencyTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let today = TestFixtures.referenceDate // 2026-09-14
    private var september: DateInterval { calendar.dateInterval(of: .month, for: today)! }

    private func makeBankState() throws -> (state: AppState, account: ExternalAccount) {
        let state = try TestFixtures.makeAppState(seeded: false)
        state.prefersBankAmounts = true
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(balance: 1000)]).first)
        return (state, account)
    }

    private func addPurchase(_ state: AppState, _ title: String, _ amount: Decimal, _ day: Int, month: Int = 9, category: ExpenseCategory = .groceries) throws -> Purchase {
        try state.addPurchase(title: title, amount: amount, date: TestFixtures.date(2026, month, day), category: category.storageValue, merchant: "Magasin", notes: nil)
        return try XCTUnwrap(state.purchases.first { $0.title == title })
    }

    // Les dépenses nettes qu'affiche Opérations pour un mois, comme l'écran les calcule : les enregistrements du
    // mois, filtrés sur la période et sur « uniquement les opérations incluses ».
    private func operationsNetExpenses(_ state: AppState, in month: DateInterval, category: ExpenseCategory? = nil) throws -> Decimal {
        let records = try state.operationRecords(in: month, calendar: calendar)
        var filter = OperationFilter()
        filter.dateFrom = month.start
        filter.dateUntil = month.end
        filter.includedOnly = true
        filter.category = category
        return OperationSearchService().search(records, filter: filter).netExpenses
    }

    private func budgetTotal(_ state: AppState, month: Date) -> Decimal {
        BudgetOverviewService.totals(of: state.budgetOverview(for: month, calendar: calendar)).spent
    }

    // MARK: Les trois cas demandés

    func testACashPurchaseNotYetMatchedGivesTheSameTotalInOperationsAndBudget() throws {
        let (state, account) = try makeBankState()
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "carrefour", amount: TestFixtures.decimal("42.10"), direction: .debit, dayOffset: -4, category: .groceries),
        ])
        _ = try addPurchase(state, "Marché (espèces)", 12, 12)
        state.reload()

        let summary = state.monthlyFinancialSummary(for: today, calendar: calendar)
        XCTAssertEqual(summary.dataSource, .bank)
        XCTAssertEqual(summary.totalExpenses, TestFixtures.decimal("54.10"), "42,10 € de banque et 12 € en espèces")
        XCTAssertEqual(try operationsNetExpenses(state, in: september), TestFixtures.decimal("54.10"), "Opérations")
        XCTAssertEqual(budgetTotal(state, month: today), TestFixtures.decimal("54.10"), "Budget")
        XCTAssertEqual(state.monthlyBudget(on: today, now: today, calendar: calendar).expenses, TestFixtures.decimal("54.10"), "accueil")
        let row = try XCTUnwrap(state.budgetOverview(for: today, calendar: calendar).first { $0.category == .groceries })
        XCTAssertEqual(row.spentAmount, TestFixtures.decimal("54.10"))
        XCTAssertEqual(try operationsNetExpenses(state, in: september, category: .groceries), row.spentAmount, "la liste d'une catégorie rend le montant de sa ligne")
    }

    func testAManualPurchaseDoubledByAPlausibleBankDebitIsCountedOnce() throws {
        let (state, account) = try makeBankState()
        let debit = TestFixtures.transaction(account: account, reference: "carrefour", amount: TestFixtures.decimal("42.10"), direction: .debit, dayOffset: -4, category: .groceries)
        try state.dataStore.importBankTransactions([debit])
        let manual = try addPurchase(state, "Courses", TestFixtures.decimal("42.10"), 11)
        state.reload()

        XCTAssertEqual(state.monthlyFinancialSummary(for: today, calendar: calendar).totalExpenses, TestFixtures.decimal("42.10"))
        XCTAssertEqual(try operationsNetExpenses(state, in: september), TestFixtures.decimal("42.10"))
        XCTAssertEqual(budgetTotal(state, month: today), TestFixtures.decimal("42.10"))
        XCTAssertEqual(state.monthlySpendingTrajectory(on: TestFixtures.date(2026, 9, 30), calendar: calendar).last?.amount, TestFixtures.decimal("42.10"))

        // L'achat reste consultable dans Opérations, signalé comme déjà compté, sans compter une seconde fois.
        let record = try XCTUnwrap(try state.operationRecords(in: september, calendar: calendar).first { $0.id == .purchase(manual.id) })
        XCTAssertTrue(record.representedByBankOperation)
        XCTAssertFalse(record.isIncluded)

        // Une fois rapproché par la synchronisation, le lien porte la même décision : toujours une seule fois.
        try state.setBankTransaction(debit, link: .purchase(manual.id))
        XCTAssertEqual(state.monthlyFinancialSummary(for: today, calendar: calendar).totalExpenses, TestFixtures.decimal("42.10"))
        XCTAssertEqual(try operationsNetExpenses(state, in: september), TestFixtures.decimal("42.10"))
    }

    func testAMonthWithoutAnyImportedOperationShowsNoOperationsInsteadOfZero() throws {
        let (state, account) = try makeBankState()
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "september", amount: 20, direction: .debit, dayOffset: -4),
        ])
        state.reload()
        let august = TestFixtures.date(2026, 8, 14)
        let augustInterval = try XCTUnwrap(calendar.dateInterval(of: .month, for: august))

        let empty = state.monthlyFinancialSummary(for: august, calendar: calendar)
        XCTAssertEqual(empty.totalExpenses, 0)
        XCTAssertTrue(empty.hasNoImportedOperations)
        XCTAssertTrue(empty.showsNoImportedOperations, "l'écran dit « aucune opération importée » à la place de 0 €")
        XCTAssertTrue(state.monthlyBudget(on: august, now: today, calendar: calendar).showsNoImportedOperations)
        XCTAssertTrue(state.hasNoImportedOperations(in: augustInterval), "Opérations, sur la même période")

        let covered = state.monthlyFinancialSummary(for: today, calendar: calendar)
        XCTAssertFalse(covered.hasNoImportedOperations)
        XCTAssertFalse(state.monthlyBudget(on: today, now: today, calendar: calendar).showsNoImportedOperations)
        XCTAssertFalse(state.hasNoImportedOperations(in: september))
    }

    // MARK: Cohérence complète

    func testHomeBudgetChartAndOperationsAgreeOnAMonthWithCashDoubledAndLinkedPurchases() throws {
        let (state, account) = try makeBankState()
        // Banque : 42,10 € de courses, 25 € d'achats le 20, 80 € ignorés (rattachés à « Casque »).
        let groceries = TestFixtures.transaction(account: account, reference: "carrefour", amount: TestFixtures.decimal("42.10"), direction: .debit, dayOffset: -4, category: .groceries)
        let laterShopping = TestFixtures.transaction(account: account, reference: "fnac", amount: 25, direction: .debit, dayOffset: 6, category: .shopping)
        let headphones = try addPurchase(state, "Casque", 80, 5, category: .shopping)
        let ignored = TestFixtures.transaction(account: account, reference: "casque", amount: 80, direction: .debit, dayOffset: -9, category: .shopping)
        ignored.isIgnored = true
        ignored.linkedPurchaseID = headphones.id
        try state.dataStore.importBankTransactions([groceries, laterShopping, ignored])
        // Saisies : doublon plausible du 11 (représenté), espèces du 12, cadeau du 13 sans débit à 3 jours.
        _ = try addPurchase(state, "Courses", TestFixtures.decimal("42.10"), 11)
        _ = try addPurchase(state, "Marché", 12, 12)
        _ = try addPurchase(state, "Cadeau", 25, 13, category: .shopping)
        state.reload()

        // Banque 67,10 € ; saisies qui comptent : 12 + 25 + 80 (le débit lié est ignoré, il ne masque pas l'achat).
        let expected = TestFixtures.decimal("184.10")
        let month = TestFixtures.date(2026, 9, 30)
        let summary = state.monthlyFinancialSummary(for: month, calendar: calendar)
        XCTAssertEqual(summary.totalExpenses, expected)
        XCTAssertEqual(state.monthlyBudget(on: month, now: month, calendar: calendar).expenses, expected)
        XCTAssertEqual(budgetTotal(state, month: month), expected)
        XCTAssertEqual(try operationsNetExpenses(state, in: september), expected)
        XCTAssertEqual(state.monthlySpendingTrajectory(on: month, calendar: calendar).last?.amount, expected, "la courbe finit sur le total affiché")

        for (category, amount) in [(ExpenseCategory.groceries, "54.10"), (.shopping, "130.00")] {
            let row = try XCTUnwrap(state.budgetOverview(for: month, calendar: calendar).first { $0.category == category })
            XCTAssertEqual(row.spentAmount, TestFixtures.decimal(amount), "\(category.rawValue) : Budget")
            XCTAssertEqual(try operationsNetExpenses(state, in: september, category: category), TestFixtures.decimal(amount), "\(category.rawValue) : Opérations")
        }
    }

    func testBudgetAndOperationsStayInStepAcrossAMonthBoundary() throws {
        let (state, account) = try makeBankState()
        // Achat du 31 août, débit équivalent du 2 septembre : août ne le compte pas (le débit le représente),
        // septembre compte le débit. Au total, une seule fois, et les deux mois voient ce qu'affiche Opérations.
        try state.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "september", amount: 60, direction: .debit, dayOffset: -12, category: .groceries),
        ])
        _ = try addPurchase(state, "Courses", 60, 31, month: 8)
        state.reload()
        let august = try XCTUnwrap(calendar.dateInterval(of: .month, for: TestFixtures.date(2026, 8, 15)))

        XCTAssertEqual(state.monthlyFinancialSummary(for: august.start, calendar: calendar).totalExpenses, 0)
        XCTAssertEqual(try operationsNetExpenses(state, in: august), 0)
        XCTAssertEqual(state.monthlyFinancialSummary(for: today, calendar: calendar).totalExpenses, 60)
        XCTAssertEqual(try operationsNetExpenses(state, in: september), 60)
    }

    func testAMonthWithOnlyManualPurchasesShowsTheirTotalAndNotTheNoOperationsState() throws {
        let (state, account) = try makeBankState()
        try state.dataStore.importBankTransactions([TestFixtures.transaction(account: account, reference: "september", amount: 20, direction: .debit, dayOffset: -4)])
        _ = try addPurchase(state, "Avant la liaison", 35, 14, month: 8)
        state.reload()
        let august = TestFixtures.date(2026, 8, 14)
        let summary = state.monthlyFinancialSummary(for: august, calendar: calendar)
        XCTAssertEqual(summary.totalExpenses, 35, "un achat saisi avant la liaison bancaire ne disparaît plus")
        XCTAssertTrue(summary.hasNoImportedOperations, "la banque ne couvre toujours pas ce mois")
        XCTAssertFalse(summary.showsNoImportedOperations, "mais le total n'est pas nul : on l'affiche")
        XCTAssertFalse(state.monthlyBudget(on: august, now: today, calendar: calendar).showsNoImportedOperations)
    }

    func testAnIgnoredOperationStillProvesTheMonthIsImported() throws {
        let (state, account) = try makeBankState()
        let ignored = TestFixtures.transaction(account: account, reference: "ignored", amount: 20, direction: .debit, dayOffset: -4)
        ignored.isIgnored = true
        try state.dataStore.importBankTransactions([ignored])
        state.reload()
        let summary = state.monthlyFinancialSummary(for: today, calendar: calendar)
        XCTAssertEqual(summary.totalExpenses, 0)
        XCTAssertFalse(summary.hasNoImportedOperations, "une opération ignorée a bien été importée : le zéro est réel")
    }

    // Sans compte inclus, ou en préférant les montants saisis, il n'y a pas de total bancaire à qualifier.
    func testManualModeNeverReportsMissingBankOperations() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        XCTAssertFalse(state.monthlyFinancialSummary(for: today, calendar: calendar).hasNoImportedOperations)
        XCTAssertFalse(state.hasNoImportedOperations(in: september))
        let (bankState, _) = try makeBankState()
        bankState.prefersBankAmounts = false
        let summary = bankState.monthlyFinancialSummary(for: today, calendar: calendar)
        XCTAssertEqual(summary.dataSource, .planned)
        XCTAssertFalse(summary.showsNoImportedOperations)
        XCTAssertFalse(bankState.monthlyBudget(on: today, now: today, calendar: calendar).showsNoImportedOperations)
    }

    // L'accueil et le budget d'un mois sans import n'affichent plus 0 € : les chaînes existent dans les deux langues.
    func testNewStringsExistInFrenchAndEnglish() {
        let expected: [String: (fr: String, en: String)] = [
            "overview.noImportedOperations": ("Aucune opération importée pour ce mois", "No transactions imported for this month"),
            "operations.representedByBank": ("Déjà compté via une opération bancaire", "Already counted through a bank transaction"),
            "budgetForm.appliesToAllMonths": ("S'applique à tous les mois", "Applies to every month"),
            "budgetLines.empty": ("Aucune dépense saisie ou prévue pour ce mois.", "No recorded or planned expense this month."),
            "budgetLines.subscription.monthly": ("Abonnement · mensuel", "Subscription · monthly"),
            "budgetLines.subscription.yearly": ("Abonnement · annuel, part mensuelle (1/12)", "Subscription · yearly, monthly share (1/12)"),
        ]
        for (key, values) in expected {
            XCTAssertEqual(AppLocalizer.string(key, locale: Locale(identifier: "fr")), values.fr, key)
            XCTAssertEqual(AppLocalizer.string(key, locale: Locale(identifier: "en")), values.en, key)
        }
    }
}
