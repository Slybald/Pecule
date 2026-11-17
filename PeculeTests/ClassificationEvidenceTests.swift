import XCTest
@testable import Pecule

// Les règles financières que le plan directeur impose ne tenaient jusqu'ici qu'à la relecture du code :
// chacune pouvait être remise à l'envers sans qu'un seul test tombe. Ce fichier les verrouille.
@MainActor
final class ClassificationEvidenceTests: XCTestCase {
    private func credit(
        _ reference: String,
        label: String,
        code: String? = nil,
        amount: Decimal = 1200,
        dayOffset: Int = 0
    ) -> BankTransaction {
        TestFixtures.transaction(
            account: TestFixtures.linkedAccount(),
            reference: reference,
            amount: amount,
            direction: .credit,
            dayOffset: dayOffset,
            label: label,
            bankTransactionCode: code
        )
    }

    // Une banque qui écrit « Salaires » plutôt que « SALA » doit être reconnue, et la provenance
    // annoncée doit correspondre à ce qui a réellement décidé : le code, pas le libellé.
    func testASalaryBankCodeIsReadWithoutRegardToItsCase() {
        for code in ["SALAIRE", "Salaires", "salaire mensuel", "PMNT/SALA"] {
            let transaction = credit("c-\(code)", label: "VIR RECU", code: code)
            XCTAssertEqual(transaction.creditNature, .salary, "code refusé : \(code)")
            XCTAssertEqual(transaction.natureEvidence, .bankCode, "provenance fausse pour : \(code)")
            XCTAssertEqual(transaction.natureConfidence, .high)
        }
    }

    // Sans code, seul le libellé peut conclure, et il l'annonce.
    func testASalaryProvenByItsLabelOnlySaysSo() {
        let transaction = credit("label", label: "VIREMENT SALAIRE ACME")
        XCTAssertEqual(transaction.creditNature, .salary)
        XCTAssertEqual(transaction.natureEvidence, .label)
        XCTAssertEqual(transaction.natureConfidence, .medium)
    }

    // Règle du plan : jamais de salaire déduit d'une simple périodicité. Douze crédits mensuels
    // du même montant et du même émetteur restent « à vérifier » tant que rien ne les prouve.
    func testTwelveIdenticalMonthlyCreditsNeverBecomeASalary() {
        let monthly = (0 ..< 12).map { credit("m\($0)", label: "VIR M DUPONT", dayOffset: -30 * $0) }

        for transaction in monthly {
            XCTAssertEqual(transaction.creditNature, .needsReview, "la périodicité ne prouve rien")
            XCTAssertEqual(transaction.natureEvidence, .insufficient)
            XCTAssertEqual(transaction.natureConfidence, .low)
            XCTAssertTrue(transaction.needsClassificationReview)
        }
    }

    // Un remboursement détecté tout seul, que rien ne rattache à une dépense et que le catégoriseur
    // n'a pas su classer, est une hypothèse : il doit rester dans la file « à vérifier ».
    func testAnUnattributedRefundStaysInTheReviewQueue() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let refund = TestFixtures.transaction(
            account: account,
            reference: "refund",
            amount: 62.40,
            direction: .credit,
            dayOffset: 0,
            label: "REMBOURSEMENT",
            // Le catégoriseur a bien tourné mais n'a rien su conclure : c'est ce qui distingue
            // une ligne récente non classée d'une ligne ancienne antérieure à la classification.
            automaticCategory: ExpenseCategory.other.storageValue
        )
        try store.importBankTransactions([refund])
        try store.updateBankTransaction(refund, nature: "refund")

        XCTAssertEqual(refund.creditNature, .refund)
        XCTAssertNil(refund.refundOfTransactionID)
        XCTAssertEqual(refund.categoryEvidence, .insufficient)
        XCTAssertTrue(refund.needsClassificationReview, "un remboursement orphelin se vérifie")
        XCTAssertFalse(refund.isIncome, "et ne devient jamais un revenu")

        // Rattaché à sa dépense, il sort de la file : le doute est levé.
        let expense = TestFixtures.transaction(account: account, reference: "pharma", amount: 62.40, direction: .debit, dayOffset: -3, label: "PHARMACIE", category: .health)
        try store.importBankTransactions([expense])
        try store.updateBankTransaction(refund, nature: "refund", refundOf: expense.id)

        XCTAssertNotNil(refund.refundOfTransactionID)
        XCTAssertFalse(refund.needsClassificationReview)

        // Une ligne antérieure à la classification annonce « legacy » et n'encombre pas la file.
        let legacy = TestFixtures.transaction(account: account, reference: "old", amount: 20, direction: .credit, dayOffset: -400, label: "REMBOURSEMENT")
        try store.importBankTransactions([legacy])
        try store.updateBankTransaction(legacy, nature: "refund")
        XCTAssertEqual(legacy.categoryEvidence, .legacy)
        XCTAssertFalse(legacy.needsClassificationReview)
    }

    // L'échelle de confiance est ce que l'utilisateur lit pour décider s'il doit vérifier.
    // Permuter deux niveaux ne casserait rien aujourd'hui ; ce test l'interdit.
    func testTheConfidenceScaleFollowsTheEvidence() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()

        // Virement prouvé par un IBAN connu : le niveau le plus haut sans intervention humaine.
        let known = TestFixtures.transaction(account: account, reference: "known", amount: 500, direction: .credit, dayOffset: 0, label: "VIREMENT")
        known.isInternalTransfer = true
        known.transferEvidence = ClassificationEvidence.knownAccount.rawValue
        try store.importBankTransactions([known])
        XCTAssertEqual(known.natureEvidence, .knownAccount)
        XCTAssertEqual(known.natureConfidence, .high)

        // Apparié par montant et date : plausible, pas prouvé.
        let paired = TestFixtures.transaction(account: account, reference: "paired", amount: 500, direction: .credit, dayOffset: -1, label: "VIREMENT")
        try store.importBankTransactions([paired])
        try store.reconcileInternalTransfers(consideredIDs: [paired.externalID], pairedIDs: [paired.externalID])
        XCTAssertEqual(paired.transferEvidence, ClassificationEvidence.pairedAccounts.rawValue)
        XCTAssertEqual(paired.natureConfidence, .medium)

        // Une décision de l'utilisateur prime sur toute détection.
        try store.updateBankTransaction(paired, nature: "personalTransfer")
        XCTAssertEqual(paired.natureEvidence, .user)
        XCTAssertEqual(paired.natureConfidence, .confirmed)
    }
}
