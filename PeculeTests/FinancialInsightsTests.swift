import XCTest
@testable import Pecule

@MainActor
final class FinancialInsightsTests: XCTestCase {
    private let march10 = TestFixtures.date(2026, 3, 10)

    private func makeState() throws -> AppState {
        AppState(
            dataStore: try TestFixtures.makeDataStore(),
            shouldSeedOnReload: false,
            insightsService: InsightsService(calendar: TestFixtures.utcCalendar(), referenceDateProvider: { [march10] in march10 })
        )
    }

    private func localized(_ key: String) -> String {
        AppLocalizer.string(key, locale: LocalizationManager.currentAppLocale)
    }

    func testNegativeRemainingToLiveComesFirstAsAWarning() throws {
        let state = try makeState()
        try state.addPurchase(title: "Ordinateur", amount: 1200, date: TestFixtures.date(2026, 3, 3), category: ExpenseCategory.other.storageValue, merchant: "Apple", notes: nil)

        let insights = state.dashboardInsights

        XCTAssertEqual(insights.first?.title, localized("insights.remainingToLive.negative.title"))
        XCTAssertEqual(insights.first?.type, .warning)
        XCTAssertFalse(insights.contains { $0.title == localized("insights.savingsRate.title") }, "overspent and saving are exclusive")
        XCTAssertFalse(insights.contains { $0.title == localized("Positive Summary") }, "a money warning suppresses the positive summary")
    }

    func testHealthySavingsRateIsCelebrated() throws {
        let state = try makeState()
        try state.addIncomeSource(name: "Salaire", amount: 1500, type: .salary, startDate: TestFixtures.date(2025, 9, 1), endDate: nil, isRecurring: true, isActive: true)
        try state.addPurchase(title: "Courses", amount: 100, date: TestFixtures.date(2026, 3, 3), category: ExpenseCategory.groceries.storageValue, merchant: "Carrefour", notes: nil)

        let insight = try XCTUnwrap(state.dashboardInsights.first)

        XCTAssertEqual(insight.title, localized("insights.savingsRate.title"))
        XCTAssertEqual(insight.type, .positive)
        XCTAssertEqual(insight.optionalValue, Formatters.percentString(for: 1400.0 / 1500.0))
    }

    func testOverspendingWarningUsesPositiveMagnitudeInBothLanguages() throws {
        let previousLanguage = UserDefaults.standard.object(forKey: LocalizationManager.userDefaultsKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: LocalizationManager.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalizationManager.userDefaultsKey)
            }
        }
        let state = try makeState()
        try state.addIncomeSource(name: "Salaire", amount: 1200, type: .salary, startDate: TestFixtures.date(2026, 1, 1), endDate: nil, isRecurring: true, isActive: true)
        try state.addPurchase(title: "Dépenses", amount: 1450, date: TestFixtures.date(2026, 3, 3), category: ExpenseCategory.other.storageValue, merchant: "Test", notes: nil)

        for language in ["fr", "en"] {
            UserDefaults.standard.set(language, forKey: LocalizationManager.userDefaultsKey)
            let insight = try XCTUnwrap(state.dashboardInsights.first)
            let positiveAmount = Formatters.currencyString(for: 250)
            XCTAssertEqual(insight.optionalValue, positiveAmount)
            XCTAssertTrue(insight.message.contains(positiveAmount))
            XCTAssertFalse(insight.message.contains(Formatters.currencyString(for: -250)))
            XCTAssertEqual(state.monthlyFinancialSummary(for: march10, calendar: TestFixtures.utcCalendar()).remainingToLive, -250)
        }
    }

    func testDashboardZeroAllowanceAndPointEstimateExplanationsAreLocalized() {
        let keys = [
            "dashboard.metrics.dailyAllowance.balanced",
            "dashboard.metrics.dailyAllowance.deficit",
            "dashboard.metrics.cashflow.limitedHistory",
            "dashboard.metrics.cashflow.pointEstimate",
        ]
        for key in keys {
            let french = AppLocalizer.string(key, locale: Locale(identifier: "fr_FR"))
            let english = AppLocalizer.string(key, locale: Locale(identifier: "en_GB"))
            XCTAssertNotEqual(french, key)
            XCTAssertNotEqual(english, key)
            XCTAssertNotEqual(french, english)
        }
    }

    func testSpendingPaceWarnsWhenVariableSpendingRunsFasterThanLastMonth() throws {
        let state = try makeState()
        try state.addIncomeSource(name: "Salaire", amount: 5000, type: .salary, startDate: TestFixtures.date(2025, 9, 1), endDate: nil, isRecurring: true, isActive: true)
        try state.addPurchase(title: "Février", amount: 280, date: TestFixtures.date(2026, 2, 10), category: ExpenseCategory.groceries.storageValue, merchant: "Carrefour", notes: nil)
        try state.addPurchase(title: "Mars", amount: 150, date: TestFixtures.date(2026, 3, 5), category: ExpenseCategory.groceries.storageValue, merchant: "Carrefour", notes: nil)

        let pace = try XCTUnwrap(state.dashboardInsights.first { $0.title == localized("insights.pace.title") })

        XCTAssertEqual(pace.type, .warning)
        XCTAssertEqual(pace.optionalValue, String(format: "%.1f×", locale: .current, 1.5))
        XCTAssertTrue(pace.message.contains(Formatters.monthYearString(for: TestFixtures.date(2026, 2, 1))))
    }

    func testNoPaceInsightWithoutAPreviousMonth() throws {
        let state = try makeState()
        try state.addPurchase(title: "Mars", amount: 150, date: TestFixtures.date(2026, 3, 5), category: ExpenseCategory.groceries.storageValue, merchant: "Carrefour", notes: nil)

        XCTAssertFalse(state.dashboardInsights.contains { $0.title == localized("insights.pace.title") })
    }
}
