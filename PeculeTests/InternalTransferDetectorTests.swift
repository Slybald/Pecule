import XCTest
@testable import Pecule

final class InternalTransferDetectorTests: XCTestCase {
    private let detector = InternalTransferDetector()
    private let accountA = UUID()
    private let accountB = UUID()
    private let accountC = UUID()

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_789_371_262 + TimeInterval(offset) * 86_400)
    }

    private func candidate(_ id: String, _ account: UUID, _ amount: Decimal, _ direction: BankTransactionDirection, day offset: Int) -> InternalTransferDetector.Candidate {
        InternalTransferDetector.Candidate(externalID: id, accountID: account, amount: amount, direction: direction, bookingDate: day(offset))
    }

    func testPairsDebitAndCreditAcrossAccountsWithinTheWindow() {
        let matched = detector.pairedTransferIDs(in: [
            candidate("a-debit", accountA, 50, .debit, day: 0),
            candidate("b-credit", accountB, 50, .credit, day: 1),
            candidate("a-groceries", accountA, 42, .debit, day: 0),
        ])
        XCTAssertEqual(matched, ["a-debit", "b-credit"])
    }

    func testIgnoresSameAccountDifferentAmountOrTooFarApart() {
        let matched = detector.pairedTransferIDs(in: [
            candidate("same-debit", accountA, 50, .debit, day: 0),
            candidate("same-credit", accountA, 50, .credit, day: 0),
            candidate("far-debit", accountA, 20, .debit, day: 0),
            candidate("far-credit", accountB, 20, .credit, day: 5),
            candidate("amount-debit", accountA, 30, .debit, day: 0),
            candidate("amount-credit", accountB, 31, .credit, day: 0),
        ])
        XCTAssertTrue(matched.isEmpty)
    }

    func testPrefersTheClosestCreditAndUsesEachOnce() {
        let matched = detector.pairedTransferIDs(in: [
            candidate("debit-1", accountA, 100, .debit, day: 0),
            candidate("debit-2", accountA, 100, .debit, day: 10),
            candidate("credit-far", accountB, 100, .credit, day: 3),
            candidate("credit-near", accountC, 100, .credit, day: 0),
        ])
        XCTAssertEqual(matched, ["debit-1", "credit-near"])

        let reused = detector.pairedTransferIDs(in: [
            candidate("debit-1", accountA, 100, .debit, day: 0),
            candidate("debit-2", accountC, 100, .debit, day: 1),
            candidate("credit", accountB, 100, .credit, day: 0),
        ])
        XCTAssertEqual(reused, ["debit-1", "credit"], "a credit can only settle one debit")
    }
}
