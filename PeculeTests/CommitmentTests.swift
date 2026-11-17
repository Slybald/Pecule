import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class CommitmentTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let now = TestFixtures.date(2026, 9, 14)
    private func draft(amount: Decimal = 100, date: Date? = TestFixtures.date(2026, 9, 15), count: Int? = nil) -> CommitmentDraft {
        var value = CommitmentDraft(); value.title = "Fixture"; value.amount = amount; value.category = ExpenseCategory.other.storageValue
        value.dueDate = date; value.count = count
        return value
    }
    private func events(_ value: CommitmentDraft, start: Date? = nil, end: Date = TestFixtures.date(2027, 1, 1)) -> [ForecastEvent] {
        PlanningEngine(calendar: calendar).events(for: value, from: start ?? now, until: end, paid: [:])
    }
    func testFiniteScheduleStopsAndMonthEndDoesNotDrift() {
        let value = draft(date: TestFixtures.date(2028, 1, 31), count: 3)
        let dates = events(value, start: TestFixtures.date(2028, 1, 1), end: TestFixtures.date(2028, 6, 1)).compactMap(\.date)
        XCTAssertEqual(dates, [31, 29, 31].enumerated().map { calendar.startOfDay(for: TestFixtures.date(2028, $0.offset + 1, $0.element)) })
        XCTAssertNil(value.annualCost, "A finite plan must not be advertised as an infinite annual cost")
    }
    func testOverdueFinitePaymentStaysInspectableWithoutChangingItsDate() {
        let value = draft(date: TestFixtures.date(2026, 8, 31), count: 2)
        let entries = events(value)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.date, calendar.startOfDay(for: TestFixtures.date(2026, 8, 31)))
    }
    func testUnknownDateRemainsUnknownAndRejectedOrStoppedEventsDisappear() {
        var value = draft(date: nil)
        XCTAssertEqual(events(value).count, 1); XCTAssertNil(events(value).first?.date)
        for status in ["rejected", "stopped"] { value.status = status; XCTAssertTrue(events(value).isEmpty) }
    }
    func testPartialPaymentsRevalidateRemainderAndCannotBeAssignedTwice() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount(balance: 500)
        try state.dataStore.saveExternalAccounts([account])
        var value = draft(date: now); value.accountID = account.id; value.count = 1
        let first = TestFixtures.transaction(account: account, reference: "first", amount: 40, direction: .debit, dayOffset: 0)
        let second = TestFixtures.transaction(account: account, reference: "second", amount: 60, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([first, second])
        try state.planningWrite { try $0.saveCommitment(value) }
        let event = try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first)
        try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: first.id, now: now, calendar: calendar) }
        let partial = try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first)
        XCTAssertEqual(partial.amount, -60)
        XCTAssertThrowsError(try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: second.id, now: now, calendar: calendar) }, "stale displayed remainder is rejected")
        XCTAssertThrowsError(try state.planningWrite { try $0.reconcilePayment(event: partial, transactionID: first.id, now: now, calendar: calendar) })
        try state.planningWrite { try $0.reconcilePayment(event: partial, transactionID: second.id, now: now, calendar: calendar) }
        XCTAssertTrue(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).isEmpty)
        XCTAssertEqual(state.externalAccounts.first?.balance, 500)
        try state.planningWrite { try $0.removeCommitmentPayment(transactionID: first.id) }
        XCTAssertEqual(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first?.amount, -40)
    }
    func testWrongAccountPendingTransferAndOverpaymentAreRejected() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount(), other = TestFixtures.linkedAccount(stableIdentifier: "other")
        try state.dataStore.saveExternalAccounts([account, other])
        var value = draft(date: now); value.accountID = account.id
        try state.planningWrite { try $0.saveCommitment(value) }
        let event = try XCTUnwrap(events(value, start: calendar.startOfDay(for: now)).first)
        for index in 0..<5 {
            let tx = TestFixtures.transaction(account: index == 0 ? other : account, reference: "bad\(index)", amount: index == 3 ? 101 : 50, direction: .debit, dayOffset: 0)
            if index == 1 { tx.status = "pending" }; if index == 2 { tx.isInternalTransfer = true }
            if index == 4 { tx.bookingDate = TestFixtures.date(2026, 9, 20) }
            try state.dataStore.importBankTransactions([tx])
            XCTAssertThrowsError(try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: tx.id, now: now, calendar: calendar) })
        }
        XCTAssertTrue(state.planning.payments.isEmpty)
    }
    func testAssociationSurvivesImportAndWithdrawnPaymentReopensTheRemainder() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        var value = draft(date: now); value.accountID = account.id; value.count = 1
        let tx = TestFixtures.transaction(account: account, reference: "paid", amount: 100, direction: .debit, dayOffset: 0, automaticCategory: ExpenseCategory.other.storageValue)
        try state.dataStore.importBankTransactions([tx])
        try state.planningWrite { try $0.saveCommitment(value) }
        let event = try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first)
        try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: tx.id, now: now, calendar: calendar) }
        let changed = TestFixtures.transaction(account: account, reference: "paid", amount: 80, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([changed]); state.reload()
        XCTAssertEqual(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first?.amount, -20)
        _ = try state.dataStore.pruneBankTransactions(accountID: account.id, bookedOnOrAfter: TestFixtures.date(2026, 9, 1), keeping: [])
        state.reload()
        XCTAssertEqual(state.planning.paymentTransactions.count, 1, "Keep reconciliation evidence even when a bank withdraws it")
        XCTAssertEqual(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first?.amount, -100)
    }
    func testDecisionSurvivesNewEvidenceAndKeepsAccountIdentity() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        let rows = (0..<3).map { index -> BankTransaction in
            let row = TestFixtures.transaction(account: account, reference: "r\(index)", amount: 10, direction: .debit, dayOffset: 0, label: "STREAM FIXTURE")
            row.bookingDate = TestFixtures.date(2026, index + 7, 1); return row
        }
        try state.dataStore.importBankTransactions(rows); state.reload()
        var suggestion = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first { $0.sourceKind == "detected" })
        let originalID = suggestion.id
        XCTAssertEqual(suggestion.status, "suggested")
        XCTAssertTrue(state.confirmedUpcomingCharges(on: now, calendar: calendar).isEmpty)
        suggestion.status = "rejected"; try state.planningWrite { try $0.saveCommitment(suggestion) }
        let next = TestFixtures.transaction(account: account, reference: "r-new", amount: 11, direction: .debit, dayOffset: 0, label: "STREAM FIXTURE")
        next.bookingDate = TestFixtures.date(2026, 9, 20)
        try state.dataStore.importBankTransactions([next]); state.reload()
        let restored = state.commitmentDrafts(on: now, calendar: calendar).filter { $0.sourceKind == "detected" }
        XCTAssertEqual(restored.count, 1); XCTAssertEqual(restored.first?.id, originalID); XCTAssertEqual(restored.first?.status, "rejected")
        XCTAssertTrue(state.planningEvents(on: now, until: TestFixtures.date(2026, 11, 1), calendar: calendar).isEmpty)
        XCTAssertNotEqual(CommitmentDraft.stableID(for: "detected:a:stream"), CommitmentDraft.stableID(for: "detected:b:stream"))
    }
    func testEditedSubscriptionAndStoppedDecisionStayConsistentWithLegacyForm() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.dataStore.addSubscription(name: "Fixture", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: true)
        state.reload()
        var value = try XCTUnwrap(state.commitmentDrafts(on: now).first)
        value.amount = 25; try state.planningWrite { try $0.saveCommitment(value) }
        XCTAssertEqual(state.subscriptions.first?.amount, 25)
        let sub = try XCTUnwrap(state.subscriptions.first)
        try state.dataStore.updateSubscription(sub, name: "Renamed", amount: 30, billingCycle: .yearly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 9, 21), isActive: false)
        state.reload()
        XCTAssertEqual(state.commitmentDrafts().first?.title, "Renamed")
        XCTAssertEqual(state.commitmentDrafts().first?.status, "stopped")
        XCTAssertTrue(state.confirmedUpcomingCharges(on: now, calendar: calendar).isEmpty)
    }
    func testExplicitScheduleCannotMoveWhilePaymentsAreAttached() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        var value = draft(date: now); value.accountID = account.id
        let tx = TestFixtures.transaction(account: account, reference: "paid", amount: 50, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx])
        try state.planningWrite { try $0.saveCommitment(value) }
        let event = try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first)
        try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: tx.id, now: now, calendar: calendar) }
        value.dueDate = TestFixtures.date(2026, 9, 16)
        XCTAssertThrowsError(try state.planningWrite { try $0.saveCommitment(value) })
        XCTAssertEqual(state.planning.commitments.first?.dueDate, now)
    }
    func testManualMarginAddsNewCommitmentWithoutCountingSubscriptionTwice() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        state.prefersBankAmounts = false
        try state.dataStore.addSubscription(name: "Fixture", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: now, isActive: true)
        let value = draft(date: now, count: 1)
        try state.planningWrite { try $0.saveCommitment(value) }
        try state.setMonthlySpendingLimit(500, for: now, calendar: calendar)
        let summary = state.monthlyBudget(on: now, now: now, calendar: calendar)
        XCTAssertEqual(summary.additionalCharges, 100)
        XCTAssertEqual(summary.margin, 380)
    }
    func testInstallmentMarkerDoesNotInventTheNextDate() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        let tx = TestFixtures.transaction(account: account, reference: "split", amount: 50, direction: .debit, dayOffset: 0, label: "SHOP ECHEANCE 2/4")
        try state.dataStore.importBankTransactions([tx]); state.reload()
        let value = try XCTUnwrap(state.installmentDraft(for: tx.id))
        XCTAssertEqual(value.count, 2); XCTAssertNil(value.dueDate); XCTAssertEqual(value.status, "suggested")
    }
    func testV5MigrationReopensCommitmentsAndPreservesExistingAnnotationsAndBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store"), txID = UUID(), accountID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PeculeSchemaV5.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let tx = PeculeSchemaV5.BankTransaction(id: txID, externalID: "fixture", accountID: accountID, amount: 40, direction: .debit, currencyCode: "EUR", bookingDate: now, label: "Fixture", category: "Shopping")
            tx.userNote = "Keep annotation"; tx.categoryOverride = "Shopping"
            container.mainContext.insert(tx)
            container.mainContext.insert(PeculeSchemaV5.MonthlySpendingLimit(periodKey: "fixture-month", amount: 500))
            try container.mainContext.save()
        }
        let value = draft(date: now)
        for pass in 0..<2 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let store = PeculeDataStore(container: container)
                let tx = try store.editableBankTransaction(id: txID)
                XCTAssertEqual(tx.userNote, "Keep annotation"); XCTAssertEqual(tx.categoryOverride, "Shopping")
                XCTAssertEqual(try store.monthlySpendingLimits().first?.amount, 500)
                if pass == 0 {
                    try store.saveCommitment(value)
                    try store.reconcilePayment(event: XCTUnwrap(events(value, start: calendar.startOfDay(for: now)).first), transactionID: txID, now: now, calendar: calendar)
                    try container.mainContext.save()
                } else {
                    XCTAssertEqual(try store.planningFetch(PlannedCommitment.self).first?.id, value.id)
                    XCTAssertEqual(try store.planningSnapshot().payments.first?.transactionID, txID)
                }
            }
        }
    }
    func testProfileIsolationAndInvalidationAlsoProtectPlanningWrites() throws {
        let first = try TestFixtures.makeAppState(seeded: false), second = try TestFixtures.makeAppState(seeded: false)
        let value = draft()
        try first.planningWrite { try $0.saveCommitment(value) }
        XCTAssertTrue(second.planning.commitments.isEmpty)
        first.invalidateProfile()
        XCTAssertTrue(first.planning.commitments.isEmpty)
        XCTAssertThrowsError(try first.planningWrite { try $0.saveCommitment(value) })
    }
    // M022 : confirmer un engagement ou un abonnement à centimes écrivait le montant tronqué (49,90 devenait 49)
    // dans l'engagement ET dans l'abonnement dont il recopie le montant.
    func testConfirmingASubscriptionCommitmentWithoutEditingKeepsItsCentsAndThoseOfTheSourceSubscription() throws {
        let amount = TestFixtures.decimal("49.90")
        // Le texte du champ : celui que le formulaire préremplit (locale fixée), « 49.9 » (la forme que l'ancien
        // préremplissage écrivait) et « 49,90 » (le même montant retapé).
        let prefilledTexts = ["fr_FR", "en_US"].map { Formatters.decimalString(for: amount, locale: Locale(identifier: $0)) }
        let fieldTexts: [String] = prefilledTexts + ["49.9", "49,90"]
        for text in fieldTexts {
            let state = try TestFixtures.makeAppState(seeded: false)
            try state.dataStore.addSubscription(name: "Abonnement fixture", amount: amount, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: true)
            state.reload()
            let opened = try XCTUnwrap(state.commitmentDrafts(on: now).first { $0.sourceKind == "subscription" })
            XCTAssertEqual(opened.amount, amount)
            let confirmed = try XCTUnwrap(CommitmentFormView.confirmedDraft(from: opened, amountText: text, dueDate: opened.dueDate, count: opened.count), text)
            XCTAssertEqual(confirmed.amount, amount, "brouillon confirmé, champ « \(text) »")
            XCTAssertEqual(confirmed.status, "confirmed")
            try state.planningWrite { try $0.saveCommitment(confirmed) }
            XCTAssertEqual(state.planning.commitments.first?.amount, amount, "engagement, champ « \(text) »")
            XCTAssertEqual(state.subscriptions.first?.amount, amount, "abonnement source, champ « \(text) »")
        }
    }
    func testConfirmingASuggestedRecurringChargeWithoutEditingKeepsItsCents() throws {
        let amount = TestFixtures.decimal("49.90")
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        let rows = (0..<3).map { index -> BankTransaction in
            let row = TestFixtures.transaction(account: account, reference: "r\(index)", amount: amount, direction: .debit, dayOffset: 0, label: "STREAM FIXTURE")
            row.bookingDate = TestFixtures.date(2026, index + 7, 1); return row
        }
        try state.dataStore.importBankTransactions(rows); state.reload()
        let suggestion = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first { $0.sourceKind == "detected" })
        XCTAssertEqual(suggestion.status, "suggested"); XCTAssertEqual(suggestion.amount, amount)
        let text = Formatters.decimalString(for: suggestion.amount, locale: Locale(identifier: "fr_FR"))
        let confirmed = try XCTUnwrap(CommitmentFormView.confirmedDraft(from: suggestion, amountText: text, dueDate: suggestion.dueDate, count: nil))
        try state.planningWrite { try $0.saveCommitment(confirmed) }
        let saved = try XCTUnwrap(state.planning.commitments.first)
        XCTAssertEqual(saved.amount, amount); XCTAssertEqual(saved.status, "confirmed")
    }
    func testAnEditedAmountIsStillReadFromTheFieldAndAnInvalidOneIsRefused() throws {
        var opened = draft(amount: TestFixtures.decimal("49.90")); opened.status = "suggested"
        let edited = try XCTUnwrap(CommitmentFormView.confirmedDraft(from: opened, amountText: "59,95", dueDate: nil, count: nil))
        XCTAssertEqual(edited.amount, TestFixtures.decimal("59.95")); XCTAssertEqual(edited.status, "confirmed"); XCTAssertNil(edited.dueDate)
        XCTAssertNil(CommitmentFormView.confirmedDraft(from: opened, amountText: "49,9x", dueDate: nil, count: nil))
        XCTAssertNil(CommitmentFormView.confirmedDraft(from: opened, amountText: "", dueDate: nil, count: nil))
        var once = opened; once.cadence = "once"
        XCTAssertNil(CommitmentFormView.confirmedDraft(from: once, amountText: "49,9", dueDate: nil, count: 3)?.count, "une échéance unique n'a pas de nombre d'échéances")
    }

    // M024 : une échéance du jour, ou prélevée en avance, était déduite deux fois de la marge tant qu'elle n'était pas
    // rapprochée à la main : une fois comme échéance restante, une fois dans les dépenses comptabilisées.
    private func bankState() throws -> (state: AppState, account: ExternalAccount) {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 2000)
        state.prefersBankAmounts = true
        try state.dataStore.saveExternalAccounts([account])
        try state.setMonthlySpendingLimit(1500, for: now, calendar: calendar)
        return (state, account)
    }
    private func saveCharge(_ state: AppState, account: ExternalAccount?, amount: Decimal = 800, due: Date, title: String = "Loyer") throws {
        var value = draft(amount: amount, date: due); value.title = title; value.accountID = account?.id
        try state.planningWrite { try $0.saveCommitment(value) }
    }
    private func debit(_ account: ExternalAccount, _ reference: String, amount: Decimal = 800, dayOffset: Int = 0) -> BankTransaction {
        TestFixtures.transaction(account: account, reference: reference, amount: amount, direction: .debit, dayOffset: dayOffset, label: "VIR LOYER")
    }
    private func chargesToCome(_ state: AppState) -> [CashflowForecast.UpcomingCharge] {
        state.confirmedUpcomingCharges(on: now, calendar: calendar)
    }
    func testAChargeDueTodayThatTheBankAlreadyDebitedIsCountedOnce() throws {
        let (state, account) = try bankState()
        try saveCharge(state, account: account, due: now)
        XCTAssertEqual(chargesToCome(state).map(\.amount), [800])
        XCTAssertEqual(state.monthlyBudget(on: now, now: now, calendar: calendar).margin, 700)
        try state.dataStore.importBankTransactions([debit(account, "rent")]); state.reload()
        let summary = state.monthlyBudget(on: now, now: now, calendar: calendar)
        XCTAssertEqual(summary.expenses, 800)
        XCTAssertTrue(summary.upcoming.isEmpty)
        XCTAssertEqual(summary.margin, 700, "800 € sont déduits une fois, comme dépense, et plus une seconde fois comme échéance à venir")
        XCTAssertTrue(state.planning.payments.isEmpty, "calcul seulement : aucun paiement n'est écrit")
        XCTAssertEqual(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).count, 1,
                       "l'occurrence reste listée et rapprochable à la main")
    }
    func testAChargeDebitedUpToFiveDaysBeforeItsDueDateIsCountedOnce() throws {
        // (jour de l'échéance, jour du prélèvement, tous deux en jours depuis aujourd'hui ; encore comptée comme échéance à venir ?)
        for (due, booked, stillCounted) in [(0, -2, false), (2, 0, false), (0, -5, false), (0, -6, true), (7, 0, true)] {
            let (state, account) = try bankState()
            try saveCharge(state, account: account, due: TestFixtures.date(2026, 9, 14 + due))
            try state.dataStore.importBankTransactions([debit(account, "rent", dayOffset: booked)]); state.reload()
            XCTAssertEqual(chargesToCome(state).count, stillCounted ? 1 : 0, "échéance à J\(due), prélèvement à J\(booked)")
        }
    }
    func testAmbiguousCandidatesSettleNothing() throws {
        // Deux prélèvements identiques : impossible de dire lequel a payé le loyer, le comportement actuel est conservé.
        let (state, account) = try bankState()
        try saveCharge(state, account: account, due: now)
        try state.dataStore.importBankTransactions([debit(account, "first"), debit(account, "second", dayOffset: -1)]); state.reload()
        XCTAssertEqual(chargesToCome(state).map(\.amount), [800])
        // Deux échéances de même montant pour un seul prélèvement : il n'a pas pu les payer toutes les deux.
        let (other, otherAccount) = try bankState()
        try saveCharge(other, account: otherAccount, due: now, title: "Loyer A")
        try saveCharge(other, account: otherAccount, due: TestFixtures.date(2026, 9, 15), title: "Loyer B")
        try other.dataStore.importBankTransactions([debit(otherAccount, "only")]); other.reload()
        XCTAssertEqual(chargesToCome(other).count, 2)
    }
    func testOnlyAnUnassignedBookedDebitOfTheSameAccountAndAmountSettlesTheCharge() throws {
        func chargesLeft(amount: Decimal = 800, debitedOnOtherAccount: Bool = false, chargeAccountKnown: Bool = true,
                         prefersBankAmounts: Bool = true, adjust: (BankTransaction) -> Void = { _ in }) throws -> Int {
            let (state, account) = try bankState()
            let other = TestFixtures.linkedAccount(stableIdentifier: "other", name: "Autre compte", balance: 100)
            try state.dataStore.saveExternalAccounts([other])
            try saveCharge(state, account: chargeAccountKnown ? account : nil, due: now)
            let row = debit(debitedOnOtherAccount ? other : account, "rent", amount: amount); adjust(row)
            try state.dataStore.importBankTransactions([row]); state.reload()
            state.prefersBankAmounts = prefersBankAmounts
            return chargesToCome(state).count
        }
        XCTAssertEqual(try chargesLeft(), 0, "référence : le prélèvement règle l'échéance")
        XCTAssertEqual(try chargesLeft(debitedOnOtherAccount: true), 1, "un autre compte ne règle rien")
        XCTAssertEqual(try chargesLeft(debitedOnOtherAccount: true, chargeAccountKnown: false), 0, "compte de l'échéance inconnu : tout compte inclus convient")
        XCTAssertEqual(try chargesLeft(amount: TestFixtures.decimal("800.01")), 0, "un centime d'écart reste le même montant")
        XCTAssertEqual(try chargesLeft(amount: TestFixtures.decimal("800.02")), 1, "deux centimes d'écart, non")
        XCTAssertEqual(try chargesLeft(adjust: { $0.linkedPurchaseID = UUID() }), 1, "une opération déjà associée ailleurs n'est pas libre")
        XCTAssertEqual(try chargesLeft(adjust: { $0.status = "pending" }), 1, "une opération en attente n'est pas comptabilisée")
        XCTAssertEqual(try chargesLeft(adjust: { $0.isInternalTransfer = true }), 1, "un virement interne n'est pas une dépense")
        XCTAssertEqual(try chargesLeft(prefersBankAmounts: false), 1, "en mode manuel le prélèvement n'est pas dans les dépenses : l'échéance reste due")
    }
    func testAPaymentAssignedToAnotherCommitmentIsNotACandidate() throws {
        let (state, account) = try bankState()
        try saveCharge(state, account: account, due: now, title: "Loyer")
        try saveCharge(state, account: account, due: TestFixtures.date(2026, 10, 20), title: "Autre")
        let row = debit(account, "rent"); try state.dataStore.importBankTransactions([row]); state.reload()
        XCTAssertTrue(chargesToCome(state).isEmpty, "référence : seul candidat du loyer du jour")
        let other = try XCTUnwrap(state.planning.commitments.first { $0.title == "Autre" })
        try state.planningWrite { $0.container.mainContext.insert(CommitmentPayment(transactionID: row.id, commitmentID: other.id, occurrenceKey: "elsewhere", amount: 800)) }
        XCTAssertEqual(chargesToCome(state).map(\.name), ["Loyer"], "assigné à un engagement, le prélèvement n'est plus libre : le loyer du jour redevient dû")
    }

    func testTheSettlementWindowFollowsCivilDaysAcrossTheDaylightSavingChange() throws {
        var paris = calendar; paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        // Le 26 octobre 2026, les horloges ont reculé la veille : le 21 est à cinq jours civils, quelle que soit la durée en heures.
        let today = paris.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        for (booked, stillCounted) in [(21, false), (20, true)] {
            let (state, account) = try bankState()
            var value = draft(amount: 800, date: paris.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!)
            value.title = "Loyer"; value.accountID = account.id
            try state.planningWrite { try $0.saveCommitment(value) }
            let row = debit(account, "rent"); row.bookingDate = TestFixtures.date(2026, 10, booked)
            try state.dataStore.importBankTransactions([row]); state.reload()
            XCTAssertEqual(state.confirmedUpcomingCharges(on: today, calendar: paris).count, stillCounted ? 1 : 0, "prélèvement du \(booked) octobre")
        }
    }
    func testOnlyConfirmedDebitsDueTodayOrLaterAreEverSettled() throws {
        let account = TestFixtures.linkedAccount(), paid = debit(account, "rent")
        func due(_ amount: Decimal, _ date: Date, confirmed: Bool = true) -> ForecastEvent {
            .init(id: UUID().uuidString, commitmentID: UUID(), title: "Fixture", amount: amount, date: calendar.startOfDay(for: date),
                  accountID: account.id, confirmed: confirmed, category: "other")
        }
        let engine = PlanningEngine(calendar: calendar)
        func kept(_ events: [ForecastEvent]) -> [ForecastEvent] {
            engine.removingSettledCharges(from: events, transactions: [paid], includedAccountIDs: [account.id], assignedTransactionIDs: [], now: now)
        }
        let untouched = [due(-800, now, confirmed: false), due(800, now), due(-800, TestFixtures.date(2026, 9, 10))]
        XCTAssertEqual(kept(untouched), untouched, "une suggestion, un crédit et une échéance déjà passée ne sont jamais réglés ainsi")
        XCTAssertTrue(kept([due(-800, now)]).isEmpty, "référence : l'échéance confirmée du jour l'est")
        XCTAssertEqual(engine.removingSettledCharges(from: [due(-800, now)], transactions: [paid], includedAccountIDs: [], assignedTransactionIDs: [], now: now).count, 1,
                       "un compte exclu des totaux ne règle rien")
        XCTAssertEqual(engine.removingSettledCharges(from: [due(-800, now)], transactions: [paid], includedAccountIDs: [account.id], assignedTransactionIDs: [paid.id], now: now).count, 1,
                       "une opération déjà affectée ne règle rien")
    }

    // m029 : les occurrences passées non rapprochées s'accumulaient, une ligne en retard de plus chaque mois, pour toujours.
    func testARecurringScheduleListsOnlyTheLast45DaysOfOverdueOccurrences() {
        // Chaque 5 du mois depuis mars : aujourd'hui (14/09), seuls août et septembre sont dans les 45 derniers jours.
        let value = draft(date: TestFixtures.date(2026, 3, 5))
        XCTAssertEqual(events(value, end: TestFixtures.date(2026, 11, 1)).compactMap(\.date),
                       [(8, 5), (9, 5), (10, 5)].map { calendar.startOfDay(for: TestFixtures.date(2026, $0.0, $0.1)) })
        // Limite : le 31 juillet est à 45 jours, le 30 à 46.
        XCTAssertEqual(events(draft(date: TestFixtures.date(2026, 7, 31))).first?.date, calendar.startOfDay(for: TestFixtures.date(2026, 7, 31)))
        XCTAssertEqual(events(draft(date: TestFixtures.date(2026, 7, 30))).first?.date, calendar.startOfDay(for: TestFixtures.date(2026, 8, 30)))
    }
    func testTheOverdueWindowKeepsTheLengthOfAFiniteScheduleAndNeverDropsASingleOccurrence() {
        // Huit mensualités depuis mars : les trois dernières seulement sont listées, et il n'y en a pas de neuvième.
        let finite = draft(date: TestFixtures.date(2026, 3, 5), count: 8)
        XCTAssertEqual(events(finite, end: TestFixtures.date(2027, 6, 1)).compactMap(\.date),
                       [(8, 5), (9, 5), (10, 5)].map { calendar.startOfDay(for: TestFixtures.date(2026, $0.0, $0.1)) })
        // Une échéance unique ne s'accumule pas : elle reste visible, très en retard, tant qu'elle n'est pas réglée.
        var once = draft(date: TestFixtures.date(2026, 3, 5)); once.cadence = "once"
        XCTAssertEqual(events(once).compactMap(\.date), [calendar.startOfDay(for: TestFixtures.date(2026, 3, 5))])
    }

    // m030 : une hausse de prix rouvrait un reliquat sur chaque occurrence passée déjà payée à l'ancien prix.
    func testAPriceIncreaseDoesNotReopenPastOccurrencesThatWerePaid() throws {
        let state = try TestFixtures.makeAppState(seeded: false), account = TestFixtures.linkedAccount(balance: 2000)
        try state.dataStore.saveExternalAccounts([account])
        var rent = draft(amount: 800, date: TestFixtures.date(2026, 8, 5)); rent.title = "Loyer"; rent.accountID = account.id
        try state.planningWrite { try $0.saveCommitment(rent) }
        let august = TestFixtures.transaction(account: account, reference: "august", amount: 800, direction: .debit, dayOffset: -40)
        let september = TestFixtures.transaction(account: account, reference: "september", amount: 800, direction: .debit, dayOffset: -9)
        try state.dataStore.importBankTransactions([august, september]); state.reload()
        let until = TestFixtures.date(2026, 11, 1), today = calendar.startOfDay(for: now)
        let overdue = state.planningEvents(on: now, until: until, calendar: calendar).filter { ($0.date ?? .distantFuture) < today }
        XCTAssertEqual(overdue.count, 2, "août et septembre, en retard avant d'être rapprochés")
        for (event, transaction) in zip(overdue, [august, september]) {
            try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: transaction.id, now: now, calendar: calendar) }
        }
        XCTAssertEqual(state.planningEvents(on: now, until: until, calendar: calendar).map(\.amount), [-800], "reste octobre")

        var increased = CommitmentDraft(try XCTUnwrap(state.planning.commitments.first)); increased.amount = 820
        try state.planningWrite { try $0.saveCommitment(increased) }

        let after = state.planningEvents(on: now, until: until, calendar: calendar)
        XCTAssertEqual(after.map(\.amount), [-820], "seule l'échéance à venir porte le nouveau prix : aucun reliquat de 20 € sur août ni septembre")
        XCTAssertTrue(state.planningForecast(on: now, calendar: calendar).unresolved.isEmpty)
    }
}
