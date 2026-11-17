import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class BankAnnotationTests: XCTestCase {
    func testNoteAndManualCategorySurviveBankRevisionAndCanBeReset() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let original = TestFixtures.transaction(account: account, reference: "insurance", amount: 74, direction: .debit, dayOffset: 0, label: "PRLV MAIF", category: .insurance)
        original.automaticCategory = original.category
        try state.dataStore.importBankTransactions([original])
        state.reload()
        try state.setBankTransaction(original, category: .housing)
        try state.setBankTransactionNote(id: original.id, note: "  Contrat logement  ")
        let revised = TestFixtures.transaction(account: account, reference: "insurance", amount: 75, direction: .debit, dayOffset: 0, label: "PRLV MAIF", category: .insurance)
        revised.automaticCategory = revised.category
        try state.dataStore.importBankTransactions([revised])
        state.reload()
        XCTAssertEqual(original.amount, 75)
        XCTAssertEqual(original.category, ExpenseCategory.housing.storageValue)
        XCTAssertEqual(original.classificationSource, "manual")
        XCTAssertEqual(original.userNote, "Contrat logement")
        try state.resetBankTransactionCategory(id: original.id)
        XCTAssertEqual(original.category, ExpenseCategory.insurance.storageValue)
        XCTAssertNil(original.categoryOverride)
        XCTAssertEqual(original.classificationSource, "automatic")
        XCTAssertEqual(original.userNote, "Contrat logement", "Resetting a category must not erase the note")
    }

    func testLegacyCategoryIsNotOverwrittenAndProvenanceIsNotInvented() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let legacy = TestFixtures.transaction(account: account, reference: "legacy", amount: 10, direction: .debit, dayOffset: 0, label: "MAIF", category: .housing)
        try store.importBankTransactions([legacy])
        let incoming = TestFixtures.transaction(account: account, reference: "legacy", amount: 12, direction: .debit, dayOffset: 0, label: "MAIF", category: .insurance)
        incoming.automaticCategory = incoming.category
        try store.importBankTransactions([incoming])
        XCTAssertEqual(legacy.category, ExpenseCategory.housing.storageValue)
        XCTAssertEqual(legacy.classificationSource, "legacy")
        XCTAssertEqual(legacy.amount, 12)
    }

    func testWithdrawnAnnotatedMovementIsExcludedAndCanReappearWithoutLosingNotes() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let transaction = TestFixtures.transaction(account: account, reference: "noted", amount: 10, direction: .debit, dayOffset: 0)
        try store.importBankTransactions([transaction])
        try store.updateBankTransactionNote(id: transaction.id, note: "Justificatif conservé")
        XCTAssertEqual(try store.pruneBankTransactions(accountID: account.id, bookedOnOrAfter: TestFixtures.day(offset: -1), keeping: []), 0)
        XCTAssertTrue(transaction.isAbsentFromBank)
        XCTAssertFalse(transaction.countsInTotals)
        XCTAssertEqual(try store.loadSnapshot().bankTransactions.count, 1)
        try store.importBankTransactions([TestFixtures.transaction(account: account, reference: "noted", amount: 11, direction: .debit, dayOffset: 0)])
        XCTAssertFalse(transaction.isAbsentFromBank)
        XCTAssertTrue(transaction.countsInTotals)
        XCTAssertEqual(transaction.userNote, "Justificatif conservé")
    }

    func testOldNotesAndRefundEvidenceSurviveRetentionAndUnlinkClearsDanglingReference() throws {
        let store = try TestFixtures.makeDataStore()
        let accounts = try store.saveExternalAccounts([TestFixtures.linkedAccount(stableIdentifier: "a"), TestFixtures.linkedAccount(stableIdentifier: "b")])
        let original = TestFixtures.transaction(account: accounts[0], reference: "original", amount: 100, direction: .debit, dayOffset: -800, category: .shopping)
        original.automaticCategory = original.category
        let refund = TestFixtures.transaction(account: accounts[1], reference: "refund", amount: 30, direction: .credit, dayOffset: -750, label: "REFUND", category: .shopping)
        refund.automaticCategory = refund.category
        let note = TestFixtures.transaction(account: accounts[1], reference: "note", amount: 10, direction: .debit, dayOffset: -800)
        note.automaticCategory = note.category
        try store.importBankTransactions([original, refund, note])
        try store.updateBankTransaction(refund, nature: "refund", refundOf: original.id)
        try store.updateBankTransactionNote(id: note.id, note: "Préserver")
        try store.updateBankTransaction(original, category: .insurance)
        XCTAssertEqual(refund.category, ExpenseCategory.insurance.storageValue)
        let report = try store.applyBankRetention(now: TestFixtures.referenceDate, calendar: TestFixtures.utcCalendar())
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try store.loadSnapshot().bankTransactions.count, 3)
        try store.deleteExternalAccount(accounts[0])
        XCTAssertNil(refund.refundOfTransactionID)
        XCTAssertEqual(refund.natureOverride, "refund")
        XCTAssertEqual(note.userNote, "Préserver")
    }

    func testDeletedMovementAndInactiveProfileRejectAnnotationWrites() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = try XCTUnwrap(try state.dataStore.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let transaction = TestFixtures.transaction(account: account, reference: "deleted", amount: 10, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([transaction])
        state.reload()
        try state.dataStore.deleteExternalAccount(account)
        XCTAssertThrowsError(try state.setBankTransactionNote(id: transaction.id, note: "Stale"))
        state.invalidateProfile()
        XCTAssertThrowsError(try state.setBankTransaction(transaction, category: .insurance))
        XCTAssertTrue(try state.dataStore.loadSnapshot().bankTransactions.isEmpty)
    }
}
