import XCTest
@testable import Pecule

@MainActor
final class ProductClassificationTests: XCTestCase {
    func testSalaryPersonalTransferAndUnknownCreditAreDistinct() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let salary = TestFixtures.transaction(account: account, reference: "s", amount: 1500, direction: .credit, dayOffset: 0, label: "SALAIRE ENTREPRISE")
        let person = TestFixtures.transaction(account: account, reference: "p", amount: 1500, direction: .credit, dayOffset: 0, label: "VIR PAUL")
        try store.importBankTransactions([salary, person])
        XCTAssertEqual(salary.creditNature, .salary)
        XCTAssertEqual(person.creditNature, .needsReview)
        try store.updateBankTransaction(person, nature: "personalTransfer")
        XCTAssertEqual(person.creditNature, .personalTransfer)
        XCTAssertEqual(person.natureEvidence, .user)
    }

    func testTransferRefusalAndNatureCorrectionSurviveImportAndDetection() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let original = TestFixtures.transaction(account: account, reference: "t", amount: 100, direction: .credit, dayOffset: 0)
        try store.importBankTransactions([original])
        try store.updateBankTransaction(original, isInternalTransfer: false)
        try store.reconcileInternalTransfers(consideredIDs: [original.externalID], pairedIDs: [original.externalID])
        XCTAssertFalse(original.isInternalTransfer)
        try store.updateBankTransaction(original, nature: "personalTransfer")
        let incoming = TestFixtures.transaction(account: account, reference: "t", amount: 100, direction: .credit, dayOffset: 0)
        incoming.isInternalTransfer = true
        incoming.transferEvidence = ClassificationEvidence.knownAccount.rawValue
        try store.importBankTransactions([incoming])
        XCTAssertEqual(original.creditNature, .personalTransfer)
        XCTAssertFalse(original.isInternalTransfer)
        try store.updateBankTransaction(original, nature: "refund")
        XCTAssertFalse(original.isIncome)
        XCTAssertEqual(original.netExpenseAmount, -100)
    }

    // Le rapprochement lit quelques jours de plus que la fenêtre pour garder une paire appariable
    // à cheval sur le bord. Ces lignes de contexte ne doivent jamais être candidates à la révocation.
    func testARowOutsideTheConsideredSetKeepsItsTransferMark() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let leg = TestFixtures.transaction(account: account, reference: "leg", amount: 1500, direction: .credit, dayOffset: -59)
        try store.importBankTransactions([leg])
        try store.reconcileInternalTransfers(consideredIDs: [leg.externalID], pairedIDs: [leg.externalID])
        XCTAssertTrue(leg.isInternalTransfer)
        XCTAssertEqual(leg.transferEvidence, ClassificationEvidence.pairedAccounts.rawValue)

        // Passe suivante : la contrepartie a vieilli hors fenêtre, la ligne n'est plus examinée.
        let changed = try store.reconcileInternalTransfers(consideredIDs: [], pairedIDs: [])
        XCTAssertEqual(changed, 0)
        XCTAssertTrue(leg.isInternalTransfer, "une jambe hors périmètre garde sa marque au lieu d'être révoquée en silence")
        XCTAssertEqual(leg.transferEvidence, ClassificationEvidence.pairedAccounts.rawValue)

        // En revanche, examinée et non appariée, elle est bien révoquée.
        XCTAssertEqual(try store.reconcileInternalTransfers(consideredIDs: [leg.externalID], pairedIDs: []), 1)
        XCTAssertFalse(leg.isInternalTransfer)
    }

    func testTheNatureToggleAndThePickerNeverDisagree() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let credit = TestFixtures.transaction(account: account, reference: "c", amount: 100, direction: .credit, dayOffset: 0)
        try store.importBankTransactions([credit])
        try store.updateBankTransaction(credit, nature: "salary")
        XCTAssertEqual(credit.creditNature, .salary)

        // Turning the transfer toggle on must move the single stored decision, not leave "salary" behind it.
        try store.updateBankTransaction(credit, isInternalTransfer: true)
        XCTAssertEqual(credit.natureOverride, "internalTransfer")
        XCTAssertEqual(credit.creditNature, .internalTransfer)

        try store.updateBankTransaction(credit, isInternalTransfer: false)
        XCTAssertEqual(credit.creditNature, .needsReview, "the stale salary decision never comes back")
    }
}

extension ProductClassificationTests {
    func testPersonalCreditWithSalaryAmountCannotSettleSalaryAutomatically() {
        let matches = BankReconciliationService().matches(transactions: [
            .init(externalID: "person", amount: 1500, direction: .credit, bookingDate: TestFixtures.referenceDate, label: "VIR PAUL", counterparty: "PAUL", isEligible: true)
        ], subscriptions: [], purchases: [], incomeSources: [
            .init(id: UUID(), name: "Salaire", amount: 1500, isActive: true)
        ])
        XCTAssertTrue(matches.isEmpty)
    }
}
