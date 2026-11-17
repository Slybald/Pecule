import Foundation
import SwiftData
import XCTest
@testable import Pecule

// m005 : les annotations d'une opération en attente suivent sa recomptabilisation sous une autre référence.
@MainActor
final class BankRebookedPendingTests: XCTestCase {
    private struct Fixture {
        let store: PeculeDataStore
        let account: ExternalAccount
    }

    private let windowStart = TestFixtures.day(offset: -10)

    private func makeFixture() throws -> Fixture {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        return Fixture(store: store, account: account)
    }

    private func entry(
        _ f: Fixture,
        _ reference: String,
        status: BankTransactionStatus,
        amount: String = "12.50",
        direction: BankTransactionDirection = .debit,
        day: Int = 0
    ) -> BankTransaction {
        let row = TestFixtures.transaction(account: f.account, reference: reference, amount: TestFixtures.decimal(amount), direction: direction, dayOffset: day, label: "CB RESTO")
        row.status = status.rawValue
        row.automaticCategory = row.category
        return row
    }

    private func storedRows(_ f: Fixture) throws -> [BankTransaction] {
        try f.store.container.mainContext.fetch(FetchDescriptor<BankTransaction>(sortBy: [SortDescriptor(\.externalID)]))
    }

    // Imports the booked rows, then prunes exactly like the synchronization does at the end of a window.
    @discardableResult
    private func rebook(_ f: Fixture, as successors: [BankTransaction], createdByThisWindow: Bool = true) throws -> Int {
        let inserted = try f.store.importBankTransactionsReturningInsertedIDs(successors)
        return try f.store.pruneBankTransactions(
            accountID: f.account.id,
            bookedOnOrAfter: windowStart,
            keeping: Set(successors.map(\.externalID)),
            insertedExternalIDs: createdByThisWindow ? Set(inserted) : []
        )
    }

    private func annotatedPending(_ f: Fixture, _ reference: String = "pending-1", amount: String = "12.50", day: Int = 0) throws -> BankTransaction {
        let pending = entry(f, reference, status: .pending, amount: amount, day: day)
        try f.store.importBankTransactions([pending])
        try f.store.updateBankTransactionNote(id: pending.id, note: "Dîner client")
        return pending
    }

    private func assertGhostStays(_ pending: BankTransaction, _ successors: [BankTransaction], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pending.isAbsentFromBank, "the annotated entry stays as an excluded ghost", file: file, line: line)
        XCTAssertEqual(pending.userNote, "Dîner client", file: file, line: line)
        for successor in successors {
            XCTAssertNil(successor.userNote, "no annotation is moved when pairing is doubtful", file: file, line: line)
            XCTAssertFalse(successor.hasUserAnnotations, file: file, line: line)
        }
    }

    func testAnnotationsFollowAPendingEntryRebookedUnderANewReference() throws {
        let f = try makeFixture()
        let purchaseID = UUID()
        let pending = entry(f, "pending-1", status: .pending)
        try f.store.importBankTransactions([pending])
        try f.store.updateBankTransaction(pending, category: .leisure)
        try f.store.updateBankTransactionNote(id: pending.id, note: "Dîner client")
        try f.store.updateBankTransaction(pending, link: .purchase(purchaseID))
        XCTAssertTrue(pending.hasUserAnnotations)

        let booked = entry(f, "booked-1", status: .booked, day: 1)
        let removed = try rebook(f, as: [booked])

        XCTAssertEqual(removed, 1, "the pending ghost goes once its annotations have moved")
        XCTAssertEqual(try storedRows(f).map(\.externalID), ["hash-1#booked-1"])
        XCTAssertEqual(booked.categoryOverride, ExpenseCategory.leisure.storageValue)
        XCTAssertEqual(booked.category, ExpenseCategory.leisure.storageValue)
        XCTAssertEqual(booked.classificationSource, "manual")
        XCTAssertEqual(booked.userNote, "Dîner client")
        XCTAssertEqual(booked.link, .purchase(purchaseID))
        XCTAssertEqual(booked.normalizedStatus, .booked)
        XCTAssertTrue(booked.countsInTotals)
        XCTAssertFalse(booked.isAbsentFromBank)
    }

    func testNatureTransferAndIgnoreDecisionsOfAPendingCreditFollowIt() throws {
        let f = try makeFixture()
        let pending = entry(f, "pending-credit", status: .pending, amount: "300", direction: .credit)
        try f.store.importBankTransactions([pending])
        try f.store.updateBankTransaction(pending, nature: "salary")
        try f.store.updateBankTransaction(pending, isIgnored: true)
        XCTAssertEqual(pending.internalTransferOverride, false)

        let booked = entry(f, "booked-credit", status: .booked, amount: "300", direction: .credit, day: -2)
        try rebook(f, as: [booked])

        XCTAssertEqual(try storedRows(f).map(\.externalID), ["hash-1#booked-credit"], "-2 days is inside the tolerance")
        XCTAssertEqual(booked.natureOverride, "salary")
        XCTAssertEqual(booked.internalTransferOverride, false)
        XCTAssertFalse(booked.isInternalTransfer)
        XCTAssertTrue(booked.isIgnored)
    }

    func testEveryAnnotationFieldMovesAndBankEvidenceStaysWithTheNewRow() {
        let accountID = UUID()
        let refundTarget = UUID(), purchase = UUID(), subscription = UUID(), income = UUID(), application = UUID()
        let previous = BankTransaction(externalID: "a#old", accountID: accountID, amount: 12, direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.day(offset: 0), label: "OLD", status: .pending)
        previous.categoryOverride = ExpenseCategory.housing.storageValue
        previous.category = ExpenseCategory.housing.storageValue
        previous.userNote = "note"
        previous.natureOverride = "refund"
        previous.refundOfTransactionID = refundTarget
        previous.internalTransferOverride = true
        previous.isInternalTransfer = true
        previous.isIgnored = true
        previous.linkedPurchaseID = purchase
        previous.linkedSubscriptionID = subscription
        previous.linkedIncomeSourceID = income
        previous.installmentDecision = "confirmed"
        previous.installmentNumber = 2
        previous.installmentCount = 4
        previous.ruleCategory = ExpenseCategory.leisure.storageValue
        previous.ruleApplicationID = application

        let successor = BankTransaction(externalID: "a#new", accountID: accountID, amount: 12, direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.day(offset: 1), label: "NEW", status: .booked)
        successor.automaticCategory = ExpenseCategory.shopping.storageValue
        successor.category = ExpenseCategory.shopping.storageValue
        let identity = successor.id

        successor.adoptAnnotations(from: previous)

        XCTAssertEqual(successor.categoryOverride, ExpenseCategory.housing.storageValue)
        XCTAssertEqual(successor.category, ExpenseCategory.housing.storageValue)
        XCTAssertEqual(successor.userNote, "note")
        XCTAssertEqual(successor.natureOverride, "refund")
        XCTAssertEqual(successor.refundOfTransactionID, refundTarget)
        XCTAssertEqual(successor.internalTransferOverride, true)
        XCTAssertTrue(successor.isInternalTransfer)
        XCTAssertTrue(successor.isIgnored)
        XCTAssertEqual(successor.linkedPurchaseID, purchase)
        XCTAssertEqual(successor.linkedSubscriptionID, subscription)
        XCTAssertEqual(successor.linkedIncomeSourceID, income)
        XCTAssertEqual(successor.installmentDecision, "confirmed")
        XCTAssertEqual(successor.installmentNumber, 2)
        XCTAssertEqual(successor.installmentCount, 4)
        XCTAssertEqual(successor.ruleCategory, ExpenseCategory.leisure.storageValue)
        XCTAssertEqual(successor.ruleApplicationID, application)
        // What the bank said about the new row is left alone.
        XCTAssertEqual(successor.id, identity)
        XCTAssertEqual(successor.externalID, "a#new")
        XCTAssertEqual(successor.label, "NEW")
        XCTAssertEqual(successor.normalizedStatus, .booked)
        XCTAssertEqual(successor.bookingDate, TestFixtures.day(offset: 1))
        XCTAssertEqual(successor.automaticCategory, ExpenseCategory.shopping.storageValue)
        XCTAssertFalse(successor.isAbsentFromBank)
    }

    func testAnAutomaticTransferVerdictOfTheNewRowSurvivesWhenThePendingEntryHadNoOverride() {
        let accountID = UUID()
        let previous = BankTransaction(externalID: "a#old", accountID: accountID, amount: 5, direction: .debit, currencyCode: "EUR", bookingDate: Date(), label: "OLD", status: .pending)
        previous.userNote = "note"
        let successor = BankTransaction(externalID: "a#new", accountID: accountID, amount: 5, direction: .debit, currencyCode: "EUR", bookingDate: Date(), label: "NEW", status: .booked)
        successor.isInternalTransfer = true
        successor.transferEvidence = ClassificationEvidence.knownAccount.rawValue

        successor.adoptAnnotations(from: previous)

        XCTAssertNil(successor.internalTransferOverride)
        XCTAssertTrue(successor.isInternalTransfer, "the automatic detection of the new row is not an annotation of the old one")
        XCTAssertEqual(successor.transferEvidence, ClassificationEvidence.knownAccount.rawValue)
        XCTAssertEqual(successor.userNote, "note")
    }

    func testTheToleranceIsThreeDaysInBothDirections() throws {
        for (offset, pairs) in [(-3, true), (3, true), (-4, false), (4, false)] {
            let f = try makeFixture()
            let pending = try annotatedPending(f)
            let booked = entry(f, "booked-\(offset)", status: .booked, day: offset)

            let removed = try rebook(f, as: [booked])

            if pairs {
                XCTAssertEqual(removed, 1, "offset \(offset)")
                XCTAssertEqual(booked.userNote, "Dîner client", "offset \(offset)")
            } else {
                XCTAssertEqual(removed, 0, "offset \(offset)")
                assertGhostStays(pending, [booked])
            }
        }
    }

    func testAmountDirectionAndCurrencyMustMatch() throws {
        let variants: [(String, (BankTransaction) -> Void)] = [
            ("amount", { $0.amount = TestFixtures.decimal("12.51") }),
            ("direction", { $0.direction = BankTransactionDirection.credit.rawValue }),
            ("currency", { $0.currencyCode = "USD" }),
        ]
        for (name, change) in variants {
            let f = try makeFixture()
            let pending = try annotatedPending(f)
            let booked = entry(f, "booked-\(name)", status: .booked, day: 1)
            change(booked)

            let removed = try rebook(f, as: [booked])

            XCTAssertEqual(removed, 0, name)
            assertGhostStays(pending, [booked])
        }
    }

    func testTwoLookAlikesAreAmbiguousSoNothingMoves() throws {
        let f = try makeFixture()
        let pending = try annotatedPending(f)
        let first = entry(f, "booked-1", status: .booked, day: 0)
        let second = entry(f, "booked-2", status: .booked, day: 1)

        let removed = try rebook(f, as: [first, second])

        XCTAssertEqual(removed, 0)
        assertGhostStays(pending, [first, second])
    }

    func testTwoPendingEntriesCompetingForOneSuccessorMoveNothing() throws {
        let f = try makeFixture()
        let firstPending = try annotatedPending(f, "pending-1")
        let secondPending = try annotatedPending(f, "pending-2")
        let booked = entry(f, "booked-1", status: .booked, day: 1)

        let removed = try rebook(f, as: [booked])

        XCTAssertEqual(removed, 0)
        assertGhostStays(firstPending, [booked])
        assertGhostStays(secondPending, [booked])
    }

    func testARowThatExistedBeforeTheWindowIsNeverTheSuccessor() throws {
        let f = try makeFixture()
        let pending = try annotatedPending(f)
        let older = entry(f, "booked-earlier", status: .booked, day: 1)

        let removed = try rebook(f, as: [older], createdByThisWindow: false)

        XCTAssertEqual(removed, 0, "an unrelated booked operation of the same amount must not inherit the note")
        assertGhostStays(pending, [older])
    }

    func testOnlyPendingEntriesMoveAnnotationsABookedOneIsJustFlaggedAbsent() throws {
        let f = try makeFixture()
        let booked = entry(f, "booked-annotated", status: .booked)
        try f.store.importBankTransactions([booked])
        try f.store.updateBankTransactionNote(id: booked.id, note: "Dîner client")
        let other = entry(f, "booked-other", status: .booked, day: 1)

        let removed = try rebook(f, as: [other])

        XCTAssertEqual(removed, 0)
        assertGhostStays(booked, [other])
    }

    func testAPendingEntryReferencedElsewhereStaysWhereItIs() throws {
        let f = try makeFixture()
        let pending = try annotatedPending(f)
        let refund = entry(f, "refund-1", status: .booked, amount: "5", direction: .credit, day: -1)
        refund.refundOfTransactionID = pending.id
        try f.store.importBankTransactions([refund])
        let booked = entry(f, "booked-1", status: .booked, day: 1)

        let removed = try rebook(f, as: [booked, refund])

        XCTAssertEqual(removed, 0, "something points at the pending row: it is not deleted from under it")
        assertGhostStays(pending, [booked])
        XCTAssertEqual(refund.refundOfTransactionID, pending.id)
    }

    func testASuccessorThatIsAlreadyAnnotatedIsLeftAlone() throws {
        let f = try makeFixture()
        let pending = try annotatedPending(f)
        let booked = entry(f, "booked-1", status: .booked, day: 1)
        booked.userNote = "Déjà annoté"

        let removed = try rebook(f, as: [booked])

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(pending.isAbsentFromBank)
        XCTAssertEqual(booked.userNote, "Déjà annoté")
    }

    func testAnUnannotatedPendingEntryIsStillSimplyRemoved() throws {
        let f = try makeFixture()
        let pending = entry(f, "pending-plain", status: .pending)
        try f.store.importBankTransactions([pending])
        let booked = entry(f, "booked-1", status: .booked, day: 1)

        let removed = try rebook(f, as: [booked])

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try storedRows(f).map(\.externalID), ["hash-1#booked-1"])
        XCTAssertFalse(booked.hasUserAnnotations)
    }

    func testPruningWithoutCreatedRowsBehavesAsBefore() throws {
        let f = try makeFixture()
        let pending = try annotatedPending(f)

        let removed = try f.store.pruneBankTransactions(accountID: f.account.id, bookedOnOrAfter: windowStart, keeping: [])

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(pending.isAbsentFromBank)
        XCTAssertEqual(try storedRows(f).count, 1)
    }

    // Le parcours complet : deux synchronisations, la banque ressert l'opération sous une autre référence.
    func testASynchronizationCarriesAnnotationsOverToTheBookedVersion() async throws {
        let gateway = ScriptedGateway()
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let service = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { TestFixtures.referenceDate })
        func dto(_ reference: String, status: String, day: Int) -> BankTransactionDTO {
            BankTransactionDTO(entryReference: reference, amount: TestFixtures.decimal("12.50"), currency: "EUR", creditDebitIndicator: .debit, status: status, bookingDate: TestFixtures.day(offset: day), creditorName: "RESTO", remittanceInformation: ["CB RESTO"])
        }

        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [dto("p1", status: "PDNG", day: -1)], continuationKey: nil)]
        await service.refresh([account], attended: true)
        let pending = try XCTUnwrap(try store.container.mainContext.fetch(FetchDescriptor<BankTransaction>()).first)
        XCTAssertEqual(pending.externalID, "hash-1#p1")
        XCTAssertEqual(pending.normalizedStatus, .pending)
        try store.updateBankTransaction(pending, category: .leisure)
        try store.updateBankTransactionNote(id: pending.id, note: "Dîner client")

        gateway.transactionPages = [nil: BankTransactionsPage(transactions: [dto("b1", status: "BOOK", day: 0)], continuationKey: nil)]
        await service.refresh([account], attended: true)

        XCTAssertNil(account.lastSyncError)
        let rows = try store.container.mainContext.fetch(FetchDescriptor<BankTransaction>())
        XCTAssertEqual(rows.map(\.externalID), ["hash-1#b1"], "no annotated ghost is left behind")
        let booked = try XCTUnwrap(rows.first)
        XCTAssertEqual(booked.normalizedStatus, .booked)
        XCTAssertEqual(booked.userNote, "Dîner client")
        XCTAssertEqual(booked.categoryOverride, ExpenseCategory.leisure.storageValue)
        XCTAssertEqual(booked.category, ExpenseCategory.leisure.storageValue)
        XCTAssertTrue(booked.countsInTotals)
    }
}
