import XCTest
@testable import Pecule

final class DecisionMetricsServiceTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let service = DecisionMetricsService()

    private func summary(income: Decimal, fixed: Decimal, variable: Decimal, monthOf date: Date) throws -> MonthlyFinancialSummary {
        MonthlyFinancialSummary(
            month: try XCTUnwrap(calendar.dateInterval(of: .month, for: date)),
            recurringIncome: income,
            incomeComplements: 0,
            incomeOverrideDelta: 0,
            fixedCharges: fixed,
            variableExpenses: variable,
            categorySummaries: [],
            budgetStatuses: []
        )
    }

    func testDailyAllowanceSpreadsTheRemainderOverTheDaysLeft() throws {
        let march = try summary(income: 1500, fixed: 500, variable: 320, monthOf: TestFixtures.date(2026, 3, 1))

        let metrics = service.metrics(from: march, on: TestFixtures.date(2026, 3, 14), calendar: calendar)

        XCTAssertEqual(metrics.remainingToLive, 680)
        XCTAssertEqual(metrics.remainingDays, 18, "the 14th counts, up to the 31st")
        XCTAssertEqual(metrics.elapsedDays, 14)
        XCTAssertEqual(metrics.dailyAllowance, TestFixtures.decimal("37.78"))
        XCTAssertEqual(try XCTUnwrap(metrics.savingsRate), 680.0 / 1500.0, accuracy: 0.0001)
        XCTAssertFalse(metrics.isOverspent)
        XCTAssertEqual(metrics.allowanceState, .available)
    }

    func testOverspentMonthHasNoAllowanceAndNoSavingsRateWithoutIncome() throws {
        let march = try summary(income: 0, fixed: 100, variable: 50, monthOf: TestFixtures.date(2026, 3, 1))

        let metrics = service.metrics(from: march, on: TestFixtures.date(2026, 3, 31), calendar: calendar)

        XCTAssertEqual(metrics.remainingToLive, -150)
        XCTAssertTrue(metrics.isOverspent)
        XCTAssertEqual(metrics.allowanceState, .deficit)
        XCTAssertEqual(metrics.dailyAllowance, 0, "a negative remainder never becomes a negative allowance")
        XCTAssertEqual(metrics.remainingDays, 1, "the last day of the month still counts as one day")
        XCTAssertNil(metrics.savingsRate)
    }

    func testBalancedMonthIsDistinctFromDeficitEvenWithTheSameZeroAllowance() throws {
        let date = TestFixtures.date(2026, 9, 15)
        let balanced = try summary(income: 1200, fixed: 900, variable: 300, monthOf: date)
        let metrics = service.metrics(from: balanced, on: date, calendar: calendar)
        XCTAssertEqual(metrics.dailyAllowance, 0)
        XCTAssertEqual(metrics.allowanceState, .balanced)
        XCTAssertFalse(metrics.isOverspent)
    }

    func testSpendingPaceComparesDailyVariableAverages() throws {
        let february = try summary(income: 0, fixed: 0, variable: 280, monthOf: TestFixtures.date(2026, 2, 1))
        let march = try summary(income: 0, fixed: 0, variable: 150, monthOf: TestFixtures.date(2026, 3, 1))

        let ratio = service.spendingPaceRatio(current: march, previous: february, on: TestFixtures.date(2026, 3, 10), calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(ratio), 1.5, accuracy: 0.0001, "15 per day so far against 10 per day in February")

        let emptyPrevious = try summary(income: 0, fixed: 0, variable: 0, monthOf: TestFixtures.date(2026, 2, 1))
        XCTAssertNil(service.spendingPaceRatio(current: march, previous: emptyPrevious, on: TestFixtures.date(2026, 3, 10), calendar: calendar))
    }
}
