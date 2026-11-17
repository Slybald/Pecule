import XCTest
@testable import Pecule

@MainActor
final class InstallmentTests: XCTestCase {
    func testBookingDatesAreNotInstallmentsAndSuggestionsFitEditableRange() {
        for label in ["SHOP 12/12/2026", "SHOP 2026/12/12", "SHOP 12 / 12 / 2026", "SHOP 1/39", "SHOP 39 FOIS",
                      "CARTE 11/12 NETFLIX", "CB 10/11 CARREFOUR", "CARTE 12/26"] {
            XCTAssertNil(InstallmentService.evidence(label: label), label)
        }
        XCTAssertEqual(InstallmentService.evidence(label: "SHOP ECHEANCE 2/3"), .init(number: 2, count: 3))
        XCTAssertEqual(InstallmentService.evidence(label: "SHOP 36 FOIS"), .init(number: 1, count: 36))
        XCTAssertEqual(InstallmentService.evidence(label: "FNAC ÉCHÉANCE 2/4"), .init(number: 2, count: 4), "accents count as the same word")
        XCTAssertEqual(InstallmentService.evidence(label: "VERSEMENT N 3/10"), .init(number: 3, count: 10))
    }

    // Seul chemin de retour vers « à vérifier » : ni le bouton ni la valeur n'étaient testés.
    func testResettingADecisionRestoresTheLabelHypothesis() throws {
        let store = try TestFixtures.makeDataStore(), account = TestFixtures.linkedAccount()
        let transaction = TestFixtures.transaction(account: account, reference: "p1", amount: 100, direction: .debit, dayOffset: 0, label: "FNAC ECHEANCE 2/4")
        try store.importBankTransactions([transaction])
        XCTAssertEqual(transaction.installmentEvidence, .init(number: 2, count: 4))

        try store.decideInstallment(id: transaction.id, decision: "rejected", number: 2, count: 4)
        XCTAssertFalse(transaction.excludesInfiniteRecurrence)

        try store.decideInstallment(id: transaction.id, decision: "suggested", number: 2, count: 4)
        XCTAssertEqual(transaction.installmentDecision, "suggested")
        XCTAssertEqual(transaction.installmentEvidence, .init(number: 2, count: 4), "l'hypothèse du libellé revient")
        XCTAssertTrue(transaction.excludesInfiniteRecurrence)
        XCTAssertEqual(transaction.netExpenseAmount, 100, "et la dépense comptée ne bouge jamais")
    }

    func testThreePaymentsRemainHypothesesUntilConfirmedAndNeverCountTwice() throws {
        let store = try TestFixtures.makeDataStore(), account = TestFixtures.linkedAccount()
        let transactions = (1...3).map { TestFixtures.transaction(account: account, reference: "part\($0)", amount: 100, direction: .debit, dayOffset: ($0 - 3) * 30, label: "SHOP ECHEANCE \($0)/3") }
        try store.importBankTransactions(transactions)
        XCTAssertEqual(transactions[0].installmentEvidence, .init(number: 1, count: 3))
        XCTAssertNil(transactions[0].installmentDecision)
        XCTAssertTrue(RecurringChargeDetector(calendar: TestFixtures.utcCalendar()).detect(in: transactions, includedAccountIDs: [account.id], asOf: TestFixtures.referenceDate).isEmpty)
        try store.decideInstallment(id: transactions[0].id, decision: "confirmed", number: 1, count: 3)
        // Les trois versements reçus restent les seules dépenses comptées : confirmer un échéancier
        // n'ajoute pas les versements à venir. L'assertion porte sur ce qui distingue les branches.
        XCTAssertEqual(transactions.reduce(Decimal.zero) { $0 + $1.netExpenseAmount }, 300)
        XCTAssertEqual(transactions[0].installmentDecision, "confirmed")
        XCTAssertTrue(transactions[0].excludesInfiniteRecurrence, "un échéancier confirmé sort de la détection de récurrence")
        try store.decideInstallment(id: transactions[1].id, decision: "rejected", number: 2, count: 3)
        let revised = TestFixtures.transaction(account: account, reference: "part2", amount: 100, direction: .debit, dayOffset: -30, label: "SHOP ECHEANCE 2/3")
        try store.importBankTransactions([revised])
        XCTAssertEqual(transactions[1].installmentDecision, "rejected")
        XCTAssertFalse(transactions[1].excludesInfiniteRecurrence, "un échéancier refusé redevient une charge ordinaire")
        XCTAssertEqual(transactions.reduce(Decimal.zero) { $0 + $1.netExpenseAmount }, 300)
        XCTAssertNil(InstallmentService.evidence(label: "SHOP MONTHLY"))
        XCTAssertThrowsError(try store.decideInstallment(id: transactions[0].id, decision: "confirmed", number: 4, count: 3))
    }
}
