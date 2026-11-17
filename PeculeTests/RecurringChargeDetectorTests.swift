import XCTest
@testable import Pecule

@MainActor
final class RecurringChargeDetectorTests: XCTestCase {
    func testFebruaryHistoryIsNotCurrentInSeptemberAndFutureRowsAreExcluded() throws {
        let rows = [12, 1, 2].map { month in
            row("CURSOR", "20", TestFixtures.date(month == 12 ? 2025 : 2026, month, 5))
        }
        let detector = RecurringChargeDetector(calendar: calendar)
        let charge = try XCTUnwrap(detector.detect(in: rows, includedAccountIDs: [accountID], asOf: TestFixtures.date(2026, 9, 15)).first)
        XCTAssertFalse(charge.isCurrent(on: TestFixtures.date(2026, 9, 15), calendar: calendar))
        XCTAssertTrue(charge.isCurrent(on: TestFixtures.date(2026, 2, 15), calendar: calendar))
        XCTAssertEqual(charge.estimatedNextDate(calendar: calendar), TestFixtures.date(2026, 3, 5))
        XCTAssertTrue(detector.detect(in: rows, includedAccountIDs: [accountID], asOf: TestFixtures.date(2026, 1, 15)).isEmpty)
    }

    func testSeparateAccountsAndIrregularIntervalsCannotCreateFalseRecurrence() {
        let secondAccount = UUID()
        let detector = RecurringChargeDetector(calendar: calendar)
        let split = [
            row("CURSOR", "20", TestFixtures.date(2026, 6, 5)),
            row("CURSOR", "20", TestFixtures.date(2026, 7, 5), account: secondAccount),
            row("CURSOR", "20", TestFixtures.date(2026, 8, 5)),
        ]
        XCTAssertTrue(detector.detect(in: split, includedAccountIDs: [accountID, secondAccount], asOf: TestFixtures.referenceDate).isEmpty)
        let irregular = [
            row("SHOP", "20", TestFixtures.date(2026, 6, 1)),
            row("SHOP", "20", TestFixtures.date(2026, 6, 2)),
            row("SHOP", "20", TestFixtures.date(2026, 8, 1)),
        ]
        XCTAssertTrue(detector.detect(in: irregular, includedAccountIDs: [accountID], asOf: TestFixtures.referenceDate).isEmpty)
    }

    func testBookingDatesAreComparedByDayRatherThanArbitraryBankTime() throws {
        let rows = (1...3).map { row("CURSOR", "20", TestFixtures.date(2026, $0, 5, hour: 12)) }
        let morning = TestFixtures.date(2026, 3, 5, hour: 0)
        let charge = try XCTUnwrap(RecurringChargeDetector(calendar: calendar).detect(in: rows, includedAccountIDs: [accountID], asOf: morning).first)
        XCTAssertEqual(charge.occurrences, 3)
        XCTAssertTrue(charge.isCurrent(on: morning, calendar: calendar))
    }

    private let calendar = TestFixtures.utcCalendar()
    private let accountID = UUID()

    private func row(_ label: String, _ amount: String, _ date: Date, purchaseID: UUID? = nil, subscriptionID: UUID? = nil, account: UUID? = nil) -> BankTransaction {
        BankTransaction(
            externalID: "rc#\(label)#\(date.timeIntervalSince1970)",
            accountID: account ?? accountID,
            amount: TestFixtures.decimal(amount),
            direction: .debit,
            currencyCode: "EUR",
            bookingDate: date,
            label: label,
            category: ExpenseCategory.subscriptions.storageValue,
            linkedPurchaseID: purchaseID,
            linkedSubscriptionID: subscriptionID
        )
    }

    func testMerchantKeyDropsNoiseDatesAndCorporateSuffixes() {
        XCTAssertEqual(RecurringChargeDetector.merchantKey(for: "PRLV SEPA NETFLIX INTERNATIONAL B.V."), "netflix")
        XCTAssertEqual(RecurringChargeDetector.merchantKey(for: "NETFLIX.COM"), "netflix")
        XCTAssertEqual(RecurringChargeDetector.merchantKey(for: "CB SPOTIFY AB 12/08"), "spotify")
        XCTAssertEqual(RecurringChargeDetector.merchantKey(for: "Carrefour Market Lyon"), "carrefour market")
        XCTAssertEqual(RecurringChargeDetector.merchantKey(for: "CB 12/08"), "")
    }

    func testDetectsMonthlyAndYearlyChargesWithStableAmountsAndFlagsIncreases() throws {
        let rows = [
            row("PRLV SEPA NETFLIX INTERNATIONAL B.V.", "9.99", TestFixtures.date(2026, 6, 5)),
            row("NETFLIX.COM", "9.99", TestFixtures.date(2026, 7, 5)),
            row("Netflix", "10.99", TestFixtures.date(2026, 8, 6)),
            row("CARREFOUR MARKET", "42", TestFixtures.date(2026, 8, 1)),
            row("CARREFOUR MARKET", "38", TestFixtures.date(2026, 8, 8)),
            row("CARREFOUR MARKET", "45", TestFixtures.date(2026, 8, 15)),
            row("CARREFOUR MARKET", "40", TestFixtures.date(2026, 8, 22)),
            row("EDF", "30", TestFixtures.date(2026, 6, 10)),
            row("EDF", "80", TestFixtures.date(2026, 7, 10)),
            row("EDF", "31", TestFixtures.date(2026, 8, 10)),
            row("AMAZON PRIME", "69.90", TestFixtures.date(2025, 9, 10)),
            row("AMAZON PRIME", "69.90", TestFixtures.date(2026, 9, 10)),
            row("BASIC FIT", "29.99", TestFixtures.date(2026, 6, 3), purchaseID: UUID()),
            row("BASIC FIT", "29.99", TestFixtures.date(2026, 7, 3)),
            row("BASIC FIT", "29.99", TestFixtures.date(2026, 8, 3)),
            row("CANAL PLUS", "20", TestFixtures.date(2026, 6, 3), account: UUID()),
            row("CANAL PLUS", "20", TestFixtures.date(2026, 7, 3), account: UUID()),
            row("CANAL PLUS", "20", TestFixtures.date(2026, 8, 3), account: UUID()),
        ]

        let charges = RecurringChargeDetector(calendar: calendar).detect(in: rows, includedAccountIDs: [accountID], asOf: TestFixtures.referenceDate)

        XCTAssertEqual(charges.map(\.key), ["amazon prime", "netflix"], "weekly groceries, unstable EDF, a purchase-linked gym row and an excluded account never qualify")
        let netflix = try XCTUnwrap(charges.first { $0.key == "netflix" })
        XCTAssertEqual(netflix.cadence, .monthly)
        XCTAssertEqual(netflix.occurrences, 3)
        XCTAssertEqual(netflix.label, "Netflix", "the latest label is shown")
        XCTAssertEqual(netflix.latestAmount, TestFixtures.decimal("10.99"))
        XCTAssertEqual(netflix.previousAmount, TestFixtures.decimal("9.99"))
        XCTAssertEqual(netflix.priceIncrease, 1)
        let prime = try XCTUnwrap(charges.first { $0.key == "amazon prime" })
        XCTAssertEqual(prime.cadence, .yearly)
        XCTAssertNil(prime.priceIncrease)
    }

    func testUntrackedExcludesLinkedChargesAndSubscriptionsSharingAWord() {
        let subscriptionID = UUID()
        let rows = [
            row("Netflix", "9.99", TestFixtures.date(2026, 6, 5)),
            row("Netflix", "9.99", TestFixtures.date(2026, 7, 5)),
            row("Netflix", "9.99", TestFixtures.date(2026, 8, 5)),
            row("Spotify AB", "10.99", TestFixtures.date(2026, 6, 9), subscriptionID: subscriptionID),
            row("Spotify AB", "10.99", TestFixtures.date(2026, 7, 9), subscriptionID: subscriptionID),
            row("Spotify AB", "10.99", TestFixtures.date(2026, 8, 9)),
            row("Disney Plus", "8.99", TestFixtures.date(2026, 6, 12)),
            row("Disney Plus", "8.99", TestFixtures.date(2026, 7, 12)),
            row("Disney Plus", "8.99", TestFixtures.date(2026, 8, 12)),
        ]
        let detector = RecurringChargeDetector(calendar: calendar)
        let charges = detector.detect(in: rows, includedAccountIDs: [accountID], asOf: TestFixtures.referenceDate)
        XCTAssertEqual(charges.count, 3)

        let netflix = Subscription(name: "Netflix Premium", amount: TestFixtures.decimal("9.99"), billingCycle: .monthly, category: .subscriptions, nextBillingDate: TestFixtures.date(2026, 9, 5), isActive: true)
        let paused = Subscription(name: "Disney+", amount: TestFixtures.decimal("8.99"), billingCycle: .monthly, category: .subscriptions, nextBillingDate: TestFixtures.date(2026, 9, 12), isActive: false)

        let untracked = detector.untracked(charges, subscriptions: [netflix, paused])

        XCTAssertEqual(untracked.map(\.key), ["disney plus"], "Netflix matches by name, Spotify is linked, the paused Disney plan does not count")
    }
}
