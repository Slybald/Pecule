import XCTest
@testable import Pecule

@MainActor
final class MonthlyObservationServiceTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let accountID = UUID()
    private let excludedAccountID = UUID()

    private func makeService(monthCount: Int = 12) -> MonthlyObservationService {
        MonthlyObservationService(calendar: calendar, referenceDateProvider: { TestFixtures.referenceDate }, monthCount: monthCount)
    }

    private func transaction(_ ref: String, _ amount: String, _ direction: BankTransactionDirection, on date: Date, account: UUID? = nil, category: ExpenseCategory = .other, status: BankTransactionStatus = .booked, subscriptionID: UUID? = nil) -> BankTransaction {
        BankTransaction(
            externalID: "obs#\(ref)",
            accountID: account ?? accountID,
            amount: TestFixtures.decimal(amount),
            direction: direction,
            currencyCode: "EUR",
            bookingDate: date,
            label: ref,
            status: status,
            category: category.storageValue,
            linkedSubscriptionID: subscriptionID
        )
    }

    func testObservesTwelveMonthsOfIncludedBookedRows() throws {
        let netflixID = UUID()
        let transactions = [
            transaction("salary", "1500", .credit, on: TestFixtures.date(2026, 8, 1)),
            transaction("netflix", "15.99", .debit, on: TestFixtures.date(2026, 8, 3), category: .other, subscriptionID: netflixID),
            transaction("rent", "600", .debit, on: TestFixtures.date(2026, 8, 4), category: .housing),
            transaction("groceries-1", "40", .debit, on: TestFixtures.date(2026, 8, 5), category: .groceries),
            transaction("groceries-2", "10", .debit, on: TestFixtures.date(2026, 8, 5, hour: 18), category: .groceries),
            transaction("cinema", "30", .debit, on: TestFixtures.date(2026, 8, 20), category: .leisure),
            transaction("card-mirror", "999", .debit, on: TestFixtures.date(2026, 8, 10), account: excludedAccountID, category: .fuel),
            transaction("pending", "200", .debit, on: TestFixtures.date(2026, 8, 12), category: .fuel, status: .pending),
            transaction("september", "20", .debit, on: TestFixtures.date(2026, 9, 2), category: .groceries),
            transaction("too-old", "5", .debit, on: TestFixtures.date(2025, 8, 15), category: .groceries),
        ]

        let months = makeService().observe(transactions: transactions, includedAccountIDs: [accountID])

        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first?.month.start, TestFixtures.date(2025, 10, 1, hour: 0))
        XCTAssertEqual(months.last?.month.start, TestFixtures.date(2026, 9, 1, hour: 0))
        XCTAssertEqual(months.map(\.transactionCount).reduce(0, +), 7, "excluded account, pending and out-of-window rows never count")

        let august = try XCTUnwrap(months.first { $0.month.start == TestFixtures.date(2026, 8, 1, hour: 0) })
        XCTAssertEqual(august.income, 1500)
        XCTAssertEqual(august.fixedCharges, TestFixtures.decimal("615.99"), "a linked subscription and a housing debit are fixed")
        XCTAssertEqual(august.variableExpenses, 80)
        XCTAssertEqual(august.byCategory[.groceries], 50)
        XCTAssertEqual(august.byCategory[.leisure], 30)
        XCTAssertEqual(august.byCategory[.housing], 600)
        XCTAssertEqual(august.remaining, TestFixtures.decimal("804.01"))
        XCTAssertEqual(try XCTUnwrap(august.savingsRate), 804.01 / 1500, accuracy: 0.0001)
        XCTAssertEqual(august.dailyVariableMedian, 0, "two spending days out of thirty-one: the typical day is a zero day")
        XCTAssertTrue(august.isComplete)

        let september = try XCTUnwrap(months.last)
        XCTAssertEqual(september.variableExpenses, 20)
        XCTAssertFalse(september.isComplete, "the current month is still running")
        XCTAssertNil(september.savingsRate, "no income booked yet")
        XCTAssertFalse(try XCTUnwrap(months.first).isComplete, "an elapsed month without rows is not a baseline")
    }

    func testMedianHandlesOddAndEvenCounts() {
        let service = makeService()

        XCTAssertEqual(service.median([3, 1, 2]), 2)
        XCTAssertEqual(service.median([4, 1, 3, 2]), TestFixtures.decimal("2.5"))
        XCTAssertEqual(service.median([]), 0)
    }

    func testCategoryTrendsCompareRecentMonthsWithTheBaseline() throws {
        func month(_ offset: Int, groceries: Decimal, fuel: Decimal = 0, complete: Bool = true) -> ObservedMonth {
            let start = calendar.date(byAdding: .month, value: offset, to: TestFixtures.date(2025, 10, 1, hour: 0))!
            return ObservedMonth(
                month: calendar.dateInterval(of: .month, for: start)!,
                income: 1500,
                fixedCharges: 0,
                variableExpenses: groceries + fuel,
                byCategory: [.groceries: groceries, .fuel: fuel],
                dailyVariableMedian: 0,
                transactionCount: 3,
                isComplete: complete
            )
        }
        let months = (0 ..< 5).map { month($0, groceries: 100) }
            + (5 ..< 8).map { month($0, groceries: 150, fuel: 40) }
            + [month(8, groceries: 999, complete: false)]

        let trends = makeService().categoryTrends(in: months)

        let groceries = try XCTUnwrap(trends.first { $0.category == .groceries })
        XCTAssertEqual(groceries.recentMonthlyAverage, 150)
        XCTAssertEqual(groceries.baselineMonthlyAverage, 100)
        XCTAssertEqual(groceries.ratio, 1.5, accuracy: 0.0001)
        XCTAssertNil(trends.first { $0.category == .fuel }, "no baseline spending, no trend")
        XCTAssertTrue(makeService().categoryTrends(in: Array(months.prefix(3))).isEmpty, "too few complete months")
    }
}
