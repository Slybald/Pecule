import XCTest
@testable import Pecule

// m090 : revenus, plafonds et dépenses d'un même calcul se lisent dans un seul mois, celui du calendrier injecté.
// m091 : les dates de début et de fin d'un revenu, choisies et affichées en heure locale, se comparent en mois
// civils de ce calendrier. Avant, elles se lisaient en UTC : un revenu du 1er octobre saisi à 00 h 30 à Paris
// commençait en septembre, un revenu du 31 octobre saisi à 20 h à New York finissait en novembre.
@MainActor
final class MonthBoundaryTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func local(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func income(_ name: String = "Salaire", start: Date, end: Date? = nil, recurring: Bool = true, amount: Decimal = 2000) -> IncomeSource {
        IncomeSource(name: name, amount: amount, type: .salary, startDate: start, endDate: end, isRecurring: recurring, isActive: true)
    }

    // MARK: m091

    func testParisIncomeStartingOnTheFirstEnteredAfterMidnightBeginsInThatMonth() {
        let paris = calendar("Europe/Paris")
        let start = local(paris, 2026, 10, 1, 0, 30)
        XCTAssertEqual(start, instant("2026-09-30T22:30:00Z"), "00 h 30 à Paris, c'est encore le 30 septembre en UTC")
        let salary = income(start: start)
        XCTAssertFalse(salary.applies(toMonthContaining: local(paris, 2026, 9, 15), calendar: paris), "pas de revenu en septembre")
        XCTAssertTrue(salary.applies(toMonthContaining: local(paris, 2026, 10, 15), calendar: paris))

        let bonus = income("Prime", start: start, recurring: false)
        XCTAssertFalse(bonus.applies(toMonthContaining: local(paris, 2026, 9, 15), calendar: paris), "une prime d'octobre ne tombe pas en septembre")
        XCTAssertTrue(bonus.applies(toMonthContaining: local(paris, 2026, 10, 15), calendar: paris))
        XCTAssertFalse(bonus.applies(toMonthContaining: local(paris, 2026, 11, 15), calendar: paris))
    }

    func testNewYorkIncomeEndingOnTheLastDayEnteredInTheEveningEndsInThatMonth() {
        let newYork = calendar("America/New_York")
        let end = local(newYork, 2026, 10, 31, 20)
        XCTAssertEqual(end, instant("2026-11-01T00:00:00Z"), "20 h le 31 octobre à New York, c'est déjà novembre en UTC")
        let rent = income("Loyer perçu", start: local(newYork, 2026, 1, 1, 10), end: end)
        XCTAssertTrue(rent.applies(toMonthContaining: local(newYork, 2026, 10, 15), calendar: newYork))
        XCTAssertFalse(rent.applies(toMonthContaining: local(newYork, 2026, 11, 15), calendar: newYork), "il se termine fin octobre, comme l'écran l'affiche")
    }

    func testNewYorkIncomeStartingLateOnTheLastDayBeginsInThatMonth() {
        let newYork = calendar("America/New_York")
        let start = local(newYork, 2026, 10, 31, 21)
        XCTAssertEqual(start, instant("2026-11-01T01:00:00Z"))
        let salary = income(start: start)
        XCTAssertTrue(salary.applies(toMonthContaining: local(newYork, 2026, 10, 20), calendar: newYork))
        XCTAssertFalse(salary.applies(toMonthContaining: local(newYork, 2026, 9, 20), calendar: newYork))
    }

    func testAucklandIncomeStartingOnTheFirstBeforeMiddayBeginsInThatMonth() {
        let auckland = calendar("Pacific/Auckland")
        let start = local(auckland, 2026, 10, 1, 9)
        XCTAssertEqual(start, instant("2026-09-30T20:00:00Z"), "UTC+13 : 9 h le 1er octobre est encore septembre en UTC")
        let salary = income(start: start)
        XCTAssertFalse(salary.applies(toMonthContaining: local(auckland, 2026, 9, 20), calendar: auckland))
        XCTAssertTrue(salary.applies(toMonthContaining: local(auckland, 2026, 10, 20), calendar: auckland))
    }

    // Les revenus déjà enregistrés à midi UTC le 1er (saisie par date seule, ancrage de stockage) restent dans leur
    // mois pour tous les fuseaux, de UTC-12 à UTC+14.
    func testDateOnlyValuesStoredAtNoonUTCKeepTheirMonthInEveryTimeZone() {
        let start = instant("2026-10-01T12:00:00Z")
        for identifier in ["Etc/GMT+12", "Pacific/Honolulu", "America/New_York", "UTC", "Europe/Paris", "Asia/Kolkata", "Asia/Tokyo", "Pacific/Auckland", "Pacific/Kiritimati"] {
            let zone = calendar(identifier)
            let salary = income(start: start)
            XCTAssertFalse(salary.applies(toMonthContaining: local(zone, 2026, 9, 20), calendar: zone), identifier)
            XCTAssertTrue(salary.applies(toMonthContaining: local(zone, 2026, 10, 20), calendar: zone), identifier)
        }
    }

    func testAnEndBeforeTheStartStillCountsTheStartMonthOnly() {
        let paris = calendar("Europe/Paris")
        let odd = income(start: local(paris, 2026, 10, 5), end: local(paris, 2026, 9, 20))
        XCTAssertTrue(odd.applies(toMonthContaining: local(paris, 2026, 10, 10), calendar: paris))
        XCTAssertFalse(odd.applies(toMonthContaining: local(paris, 2026, 11, 10), calendar: paris))
        XCTAssertFalse(odd.applies(toMonthContaining: local(paris, 2026, 9, 10), calendar: paris))
    }

    func testAMonthlyOverrideAnchoredAtNoonUTCAppliesToTheMonthOfTheInjectedCalendar() {
        let paris = calendar("Europe/Paris"), newYork = calendar("America/New_York")
        let override = MonthlyIncomeOverride(incomeSourceID: UUID(), monthStartDate: instant("2026-10-01T12:00:00Z"), amount: -200, replacesSourceAmount: false)
        XCTAssertTrue(override.applies(toMonthContaining: instant("2026-09-30T22:30:00Z"), calendar: paris), "1er octobre, 00 h 30 à Paris")
        XCTAssertFalse(override.applies(toMonthContaining: instant("2026-09-30T21:30:00Z"), calendar: paris), "30 septembre, 23 h 30 à Paris")
        XCTAssertTrue(override.applies(toMonthContaining: instant("2026-11-01T01:00:00Z"), calendar: newYork), "31 octobre, 21 h à New York")
        XCTAssertFalse(override.applies(toMonthContaining: instant("2026-11-01T05:00:00Z"), calendar: newYork), "1er novembre, 1 h à New York")
    }

    // MARK: m090

    private func boundaryInputs() -> (salary: IncomeSource, ended: IncomeSource, override: MonthlyIncomeOverride, purchases: [Purchase]) {
        let salary = income(start: instant("2026-10-01T12:00:00Z"))
        let ended = income("Ancien", start: instant("2026-01-01T12:00:00Z"), end: instant("2026-09-30T12:00:00Z"), amount: 500)
        let override = MonthlyIncomeOverride(incomeSourceID: salary.id, monthStartDate: instant("2026-10-01T12:00:00Z"), amount: -200, replacesSourceAmount: false)
        // Minuit pile à Paris : octobre seulement. Une minute avant : septembre.
        let purchases = [
            Purchase(title: "Minuit", amount: 50, date: instant("2026-09-30T22:00:00Z"), category: ExpenseCategory.groceries, merchant: "Shop", notes: nil),
            Purchase(title: "Veille", amount: 20, date: instant("2026-09-30T21:59:00Z"), category: ExpenseCategory.groceries, merchant: "Shop", notes: nil),
        ]
        return (salary, ended, override, purchases)
    }

    // Paris, 1er octobre à 00 h 30 (= 30 septembre 22 h 30 UTC) : le mois est octobre pour les revenus, les plafonds
    // et les dépenses. Avant, revenus et plafonds étaient ceux de septembre face aux achats d'octobre.
    func testParisJustAfterMidnightOnTheFirstSummarisesOctoberEverywhere() throws {
        let paris = calendar("Europe/Paris")
        let now = instant("2026-09-30T22:30:00Z")
        let inputs = boundaryInputs()
        let rules = [BudgetRule(category: ExpenseCategory.groceries.storageValue, monthlyAmount: 200)]
        let caps = [
            BudgetOverride(category: ExpenseCategory.groceries.storageValue, year: 2026, month: 10, monthlyAmount: 300),
            BudgetOverride(category: ExpenseCategory.groceries.storageValue, year: 2026, month: 9, monthlyAmount: 150),
        ]
        let service = BudgetPlannerService(calendar: paris, referenceDateProvider: { now })

        let direct = service.summary(
            subscriptions: [], purchases: inputs.purchases, incomeSources: [inputs.salary, inputs.ended],
            monthlyIncomeOverrides: [inputs.override], budgetRules: rules, budgetOverrides: caps
        )
        let snapshot = AppDataSnapshot(
            subscriptions: [], purchases: inputs.purchases, goals: [], habits: [], incomeSources: [inputs.salary, inputs.ended],
            monthlyIncomeOverrides: [inputs.override], budgetRules: rules, budgetOverrides: caps
        )
        let fromSnapshot = service.summary(from: snapshot)

        for (name, summary) in [("résumé direct", direct), ("instantané", fromSnapshot)] {
            XCTAssertEqual(summary.monthStart, paris.date(from: DateComponents(year: 2026, month: 10, day: 1)), name)
            XCTAssertEqual(summary.recurringIncome, 2000, "\(name) : le salaire d'octobre compte, l'ancien revenu fini le 30 septembre non")
            XCTAssertEqual(summary.incomeOverrideDelta, -200, "\(name) : l'ajustement d'octobre s'applique")
            XCTAssertEqual(summary.totalEstimatedIncome, 1800, name)
            XCTAssertEqual(summary.variableExpenses, 50, "\(name) : seul l'achat de minuit pile est d'octobre")
            let groceries = try XCTUnwrap(summary.budgetStatuses.first { $0.category == ExpenseCategory.groceries.storageValue })
            XCTAssertEqual(groceries.plannedAmount, 300, "\(name) : le plafond d'octobre, ni la règle ni celui de septembre")
            XCTAssertEqual(groceries.spentAmount, 50, name)
        }

        // Une minute plus tôt, c'est septembre pour tout le monde.
        let september = BudgetPlannerService(calendar: paris, referenceDateProvider: { self.instant("2026-09-30T21:59:00Z") }).summary(
            subscriptions: [], purchases: inputs.purchases, incomeSources: [inputs.salary, inputs.ended],
            monthlyIncomeOverrides: [inputs.override], budgetRules: rules, budgetOverrides: caps
        )
        XCTAssertEqual(september.recurringIncome, 500, "en septembre, l'ancien revenu compte et le salaire n'a pas commencé")
        XCTAssertEqual(september.incomeOverrideDelta, 0)
        XCTAssertEqual(september.variableExpenses, 20)
        XCTAssertEqual(september.budgetStatuses.first { $0.category == ExpenseCategory.groceries.storageValue }?.plannedAmount, 150)
    }

    // Le même instant par le chemin de l'application : revenus, ajustements et plafonds lus dans l'état.
    func testTheAppStateSummaryUsesTheSameMonthForIncomeOverridesAndCaps() throws {
        let paris = calendar("Europe/Paris")
        let now = instant("2026-09-30T22:30:00Z")
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addIncomeSource(name: "Salaire", amount: 2000, type: .salary, startDate: instant("2026-10-01T12:00:00Z"), endDate: nil, isRecurring: true, isActive: true)
        let salary = try XCTUnwrap(state.incomeSources.first)
        try state.addMonthlyIncomeOverride(incomeSourceID: salary.id, month: instant("2026-10-01T12:00:00Z"), amount: -200, replacesSourceAmount: false)
        try state.setBudgetOverride(category: ExpenseCategory.groceries.storageValue, month: instant("2026-10-15T12:00:00Z"), monthlyAmount: 300)
        try state.addPurchase(title: "Minuit", amount: 50, date: instant("2026-09-30T22:00:00Z"), category: ExpenseCategory.groceries.storageValue, merchant: "Shop", notes: nil)

        XCTAssertEqual(state.monthlyIncomeOverrides(for: now, calendar: paris).count, 1, "l'ajustement d'octobre est celui du mois affiché")
        let summary = state.monthlyFinancialSummary(for: now, calendar: paris)
        XCTAssertEqual(summary.dataSource, .planned)
        XCTAssertEqual(summary.totalEstimatedIncome, 1800)
        XCTAssertEqual(summary.variableExpenses, 50)
        XCTAssertEqual(summary.budgetStatuses.first { $0.category == ExpenseCategory.groceries.storageValue }?.plannedAmount, 300)
        XCTAssertEqual(state.resolvedMonthlyIncomeAmount(for: salary, in: now, calendar: paris), 1800)
    }

    // New York, 31 octobre à 21 h (= 1er novembre 01 h UTC) : le mois est octobre. Un revenu qui se termine le
    // 31 octobre (saisi à 20 h) y compte encore ; en novembre, il ne compte plus.
    func testNewYorkLastEveningOfOctoberIsOctoberAndAnIncomeEndingThatDayStillCounts() {
        let newYork = calendar("America/New_York")
        let now = instant("2026-11-01T01:00:00Z")
        let rent = income("Loyer perçu", start: local(newYork, 2026, 1, 1, 10), end: local(newYork, 2026, 10, 31, 20), amount: 700)
        let october = BudgetPlannerService(calendar: newYork, referenceDateProvider: { now })
            .summary(subscriptions: [], purchases: [], incomeSources: [rent])
        XCTAssertEqual(october.monthStart, newYork.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(october.recurringIncome, 700)

        let november = BudgetPlannerService(calendar: newYork, referenceDateProvider: { self.instant("2026-11-15T17:00:00Z") })
            .summary(subscriptions: [], purchases: [], incomeSources: [rent])
        XCTAssertEqual(november.recurringIncome, 0, "le revenu s'est terminé fin octobre")
    }

    func testAucklandFirstMorningOfOctoberIsOctober() {
        let auckland = calendar("Pacific/Auckland")
        let salary = income(start: local(auckland, 2026, 10, 1, 9))
        let october = BudgetPlannerService(calendar: auckland, referenceDateProvider: { self.instant("2026-09-30T20:00:00Z") })
            .summary(subscriptions: [], purchases: [], incomeSources: [salary])
        XCTAssertEqual(october.recurringIncome, 2000)
        let september = BudgetPlannerService(calendar: auckland, referenceDateProvider: { self.instant("2026-09-15T00:00:00Z") })
            .summary(subscriptions: [], purchases: [], incomeSources: [salary])
        XCTAssertEqual(september.recurringIncome, 0, "le revenu du 1er octobre n'est pas compté en septembre")
    }
}
