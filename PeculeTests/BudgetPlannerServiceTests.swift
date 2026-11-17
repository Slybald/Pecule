import XCTest
@testable import Pecule

@MainActor
final class BudgetPlannerServiceTests: XCTestCase {
    private enum DecimalParseError: Error {
        case invalidValue(String)
    }

    private func decimal(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Decimal {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            XCTFail("Unable to parse decimal literal: \(value)", file: file, line: line)
            throw DecimalParseError.invalidValue(value)
        }

        return decimal
    }

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        let calendar = fixedCalendar()

        return calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: 12
            )
        ) ?? Date()
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return calendar.date(
            from: DateComponents(
                timeZone: timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        ) ?? Date()
    }

    private func makeDataStore() throws -> PeculeDataStore {
        let container = try PeculeDataStore.makeInMemoryContainer()
        return PeculeDataStore(container: container)
    }

    private func removeSeededIncomeData(from state: AppState) throws {
        let existingOverrides = state.monthlyIncomeOverrides
        let existingSources = state.incomeSources

        for monthlyIncomeOverride in existingOverrides {
            try state.deleteMonthlyIncomeOverride(monthlyIncomeOverride)
        }

        for incomeSource in existingSources {
            try state.deleteIncomeSource(incomeSource)
        }
    }

    func testSummaryFromSnapshotAppliesBudgetOverrideAndCanonicalCategories() throws {
        let calendar = fixedCalendar()
        let service = BudgetPlannerService(
            calendar: calendar,
            referenceDateProvider: { self.makeDate(year: 2026, month: 3, day: 14) }
        )

        let snapshot = AppDataSnapshot(
            subscriptions: [
                Subscription(
                    name: "Netflix",
                    amount: try decimal("15.99"),
                    billingCycle: .monthly,
                    category: "Streaming",
                    nextBillingDate: makeDate(year: 2026, month: 3, day: 20),
                    isActive: true
                )
            ],
            purchases: [
                Purchase(
                    title: "Weekly groceries",
                    amount: try decimal("62.30"),
                    date: makeDate(year: 2026, month: 3, day: 12),
                    category: .groceries,
                    merchant: "Fresh Market",
                    notes: nil
                )
            ],
            goals: [],
            habits: [],
            incomeSources: [
                IncomeSource(
                    name: "Salary",
                    amount: try decimal("2300.00"),
                    type: .salary,
                    startDate: makeDate(year: 2026, month: 3, day: 1),
                    isRecurring: true,
                    isActive: true
                ),
                IncomeSource(
                    name: "Mobility support",
                    amount: try decimal("120.00"),
                    type: .mobility,
                    startDate: makeDate(year: 2026, month: 3, day: 5),
                    isRecurring: false,
                    isActive: true
                )
            ],
            monthlyIncomeOverrides: [
                MonthlyIncomeOverride(
                    incomeSourceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") ?? UUID(),
                    monthStartDate: makeDate(year: 2026, month: 3, day: 1),
                    amount: try decimal("-200.00"),
                    replacesSourceAmount: false
                )
            ],
            budgetRules: [
                BudgetRule(
                    category: "Food",
                    monthlyAmount: try decimal("400.00")
                )
            ],
            budgetOverrides: [
                BudgetOverride(
                    category: "Groceries",
                    year: 2026,
                    month: 3,
                    monthlyAmount: try decimal("450.00")
                )
            ]
        )

        snapshot.monthlyIncomeOverrides[0].incomeSourceID = snapshot.incomeSources[0].id

        let summary = service.summary(from: snapshot)

        XCTAssertEqual(summary.recurringIncome, try decimal("2300.00"))
        XCTAssertEqual(summary.incomeComplements, try decimal("120.00"))
        XCTAssertEqual(summary.incomeSupplements, try decimal("120.00"))
        XCTAssertEqual(summary.incomeOverrideDelta, try decimal("-200.00"))
        XCTAssertEqual(summary.totalEstimatedIncome, try decimal("2220.00"))
        XCTAssertEqual(summary.fixedCharges, try decimal("15.99"))
        XCTAssertEqual(summary.variableExpenses, try decimal("62.30"))

        let groceriesSummary = try XCTUnwrap(
            summary.categorySummaries.first(where: { $0.category == ExpenseCategory.groceries.storageValue })
        )
        XCTAssertEqual(groceriesSummary.fixedCharges, .zero)
        XCTAssertEqual(groceriesSummary.variableExpenses, try decimal("62.30"))

        let groceriesBudget = try XCTUnwrap(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.groceries.storageValue })
        )
        XCTAssertEqual(groceriesBudget.scope, .totalSpending)
        XCTAssertEqual(groceriesBudget.plannedAmount, try decimal("450.00"))
        XCTAssertEqual(groceriesBudget.spentAmount, try decimal("62.30"))
        XCTAssertEqual(groceriesBudget.remainingAmount, try decimal("387.70"))
    }

    func testSummaryFromAppStateUsesPersistedBudgetRulesAndOverrides() throws {
        let calendar = fixedCalendar()
        let service = BudgetPlannerService(
            calendar: calendar,
            referenceDateProvider: { self.makeDate(year: 2026, month: 4, day: 14) }
        )
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 4, day: 8),
            amount: try decimal("-200.00"),
            replacesSourceAmount: false
        )
        try state.setBudgetRule(
            category: "Groceries",
            monthlyAmount: try decimal("400.00")
        )
        try state.setBudgetOverride(
            category: "Groceries",
            month: makeDate(year: 2026, month: 4, day: 8),
            monthlyAmount: try decimal("500.00")
        )
        try state.addPurchase(
            title: "Weekly groceries",
            amount: try decimal("80.00"),
            date: makeDate(year: 2026, month: 4, day: 10),
            category: "Food",
            merchant: "Fresh Market",
            notes: nil
        )

        let summary = service.summary(from: state)

        XCTAssertTrue(
            calendar.isDate(
                summary.monthStart,
                equalTo: makeDate(year: 2026, month: 4, day: 1),
                toGranularity: .day
            )
        )
        XCTAssertEqual(summary.recurringIncome, try decimal("2300.00"))
        XCTAssertEqual(summary.incomeOverrideDelta, try decimal("-200.00"))

        let groceriesBudget = try XCTUnwrap(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.groceries.storageValue })
        )
        XCTAssertEqual(groceriesBudget.plannedAmount, try decimal("500.00"))
        XCTAssertEqual(groceriesBudget.spentAmount, try decimal("80.00"))
        XCTAssertEqual(groceriesBudget.remainingAmount, try decimal("420.00"))
    }

    func testSummaryFromAppStateMatchesBudgetAmountsForCanonicalCategories() throws {
        let calendar = fixedCalendar()
        let service = BudgetPlannerService(
            calendar: calendar,
            referenceDateProvider: { self.makeDate(year: 2026, month: 4, day: 14) }
        )
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetRule(
            category: "Food",
            monthlyAmount: try decimal("420.00")
        )
        try state.setBudgetOverride(
            category: "Essence",
            month: makeDate(year: 2026, month: 4, day: 5),
            monthlyAmount: try decimal("180.00")
        )
        try state.addPurchase(
            title: "Groceries run",
            amount: try decimal("95.00"),
            date: makeDate(year: 2026, month: 4, day: 10),
            category: "Food",
            merchant: "Fresh Market",
            notes: nil
        )
        try state.addPurchase(
            title: "Fuel top-up",
            amount: try decimal("70.00"),
            date: makeDate(year: 2026, month: 4, day: 12),
            category: "Essence",
            merchant: "Station One",
            notes: nil
        )

        let summary = service.summary(from: state)

        XCTAssertEqual(state.budgetAmount(for: "Groceries", in: summary.monthStart, calendar: calendar), try decimal("420.00"))
        XCTAssertEqual(state.budgetAmount(for: "Fuel", in: summary.monthStart, calendar: calendar), try decimal("180.00"))
        XCTAssertEqual(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.groceries.storageValue })?.plannedAmount,
            try decimal("420.00")
        )
        XCTAssertEqual(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.groceries.storageValue })?.spentAmount,
            try decimal("95.00")
        )
        XCTAssertEqual(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.fuel.storageValue })?.plannedAmount,
            try decimal("180.00")
        )
        XCTAssertEqual(
            summary.budgetStatuses.first(where: { $0.category == ExpenseCategory.fuel.storageValue })?.spentAmount,
            try decimal("70.00")
        )
    }

    func testSummaryFromAppStateUsesInjectedCalendarForIncomeOverrides() throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let boundaryDate = makeDate(
            year: 2026,
            month: 3,
            day: 31,
            hour: 23,
            minute: 30,
            timeZone: utcCalendar.timeZone
        )
        let service = BudgetPlannerService(
            calendar: utcCalendar,
            referenceDateProvider: { boundaryDate }
        )
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 3, day: 5),
            amount: try decimal("-200.00"),
            replacesSourceAmount: false
        )

        let summary = service.summary(from: state)

        XCTAssertTrue(
            utcCalendar.isDate(
                summary.monthStart,
                equalTo: makeDate(year: 2026, month: 3, day: 1),
                toGranularity: .day
            )
        )
        XCTAssertEqual(summary.recurringIncome, try decimal("2300.00"))
        XCTAssertEqual(summary.incomeOverrideDelta, try decimal("-200.00"))
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: salary, in: summary.monthStart, calendar: utcCalendar),
            try decimal("2100.00")
        )
    }
}
