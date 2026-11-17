import Foundation
import SwiftData
import XCTest
@testable import Pecule

// M014, m002, m089, m031: what points at an operation, an account or an entry must go, or be reset, with it.
// Planning rows and operation links are keyed on identifiers, so nothing cascades by itself.
@MainActor
final class OrphanedReferenceTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let now = TestFixtures.date(2026, 9, 14)

    private func makeLinkedState(balance: Decimal = 500) throws -> (AppState, ExternalAccount) {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount(balance: balance)
        try state.dataStore.saveExternalAccounts([account])
        return (state, account)
    }

    // What the month adds up to when the bank is the evidence: planned entries replaced by what was really debited.
    private func monthSummary(_ state: AppState, month: Date) throws -> MonthlyFinancialSummary {
        BudgetPlannerService(calendar: calendar, referenceDateProvider: { month })
            .summary(forMonthContaining: month, from: try state.dataStore.loadSnapshot(), prefersBankAmounts: true)
    }

    private func recurringDebits(on account: ExternalAccount, label: String = "STREAM FIXTURE") -> [BankTransaction] {
        (0..<3).map { index in
            let row = TestFixtures.transaction(account: account, reference: "r\(index)", amount: 10, direction: .debit, dayOffset: 0, label: label)
            row.bookingDate = TestFixtures.date(2026, index + 7, 1)
            return row
        }
    }

    // MARK: M014 - deleting an entry frees the operations that settled it

    func testDeletingASubscriptionFreesItsOperationsAndTheChargeIsUntrackedAgain() throws {
        let (state, account) = try makeLinkedState()
        let rows = recurringDebits(on: account)
        try state.dataStore.importBankTransactions(rows)
        try state.addSubscription(name: "Stream", amount: 10, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 10, 1), isActive: true)
        let subscription = try XCTUnwrap(state.subscriptions.first)
        try state.setBankTransaction(rows[2], link: .subscription(subscription.id))
        XCTAssertEqual(state.recurringCharges.first?.isLinkedToSubscription, true)
        let september = TestFixtures.date(2026, 9, 15)
        let before = try monthSummary(state, month: september)
        XCTAssertEqual(before.totalExpenses, 10)

        try state.deleteSubscription(subscription)

        XCTAssertTrue(rows.allSatisfy { $0.linkedSubscriptionID == nil }, "no operation keeps pointing at the deleted subscription")
        XCTAssertEqual(state.recurringCharges.first?.isLinkedToSubscription, false, "the detected charge is untracked again")
        XCTAssertEqual(RecurringChargeDetector().untracked(state.recurringCharges, subscriptions: state.subscriptions).count, 1)
        let after = try monthSummary(state, month: september)
        XCTAssertEqual(after.totalExpenses, before.totalExpenses, "the money really debited is still counted, as a spending now")
    }

    func testDeletingAPurchaseFreesItsOperation() throws {
        let (state, account) = try makeLinkedState()
        try state.addPurchase(title: "Machine à café", amount: 20, date: TestFixtures.date(2026, 9, 10), category: "Shopping", merchant: "Darty", notes: nil)
        let purchase = try XCTUnwrap(state.purchases.first)
        let debit = TestFixtures.transaction(account: account, reference: "darty", amount: 20, direction: .debit, dayOffset: 0, label: "CB DARTY")
        debit.bookingDate = TestFixtures.date(2026, 9, 10)
        try state.dataStore.importBankTransactions([debit])
        try state.setBankTransaction(debit, link: .purchase(purchase.id))
        let september = TestFixtures.date(2026, 9, 15)
        let before = try monthSummary(state, month: september)
        XCTAssertEqual(before.totalExpenses, 20)

        try state.deletePurchase(purchase)

        XCTAssertNil(debit.linkedPurchaseID)
        XCTAssertNil(debit.link)
        XCTAssertEqual(try monthSummary(state, month: september).totalExpenses, before.totalExpenses)
        XCTAssertNil(state.linkedEntityName(for: debit))
    }

    func testDeletingAnIncomeSourceFreesTheCreditsItSettled() throws {
        let (state, account) = try makeLinkedState()
        try state.addIncomeSource(name: "Salaire ACME", amount: 1500, type: .salary, startDate: TestFixtures.date(2026, 1, 1), endDate: nil, isRecurring: true, isActive: true)
        let source = try XCTUnwrap(state.incomeSources.first)
        let credit = TestFixtures.transaction(account: account, reference: "pay", amount: 1500, direction: .credit, dayOffset: 0, label: "VIR SALAIRE ACME")
        credit.bookingDate = TestFixtures.date(2026, 9, 1)
        try state.dataStore.importBankTransactions([credit])
        try state.setBankTransaction(credit, link: .income(source.id))
        let september = TestFixtures.date(2026, 9, 15)
        XCTAssertEqual(try monthSummary(state, month: september).unmatchedIncome, 0)

        try state.deleteIncomeSource(source)

        XCTAssertNil(credit.linkedIncomeSourceID)
        let after = try monthSummary(state, month: september)
        XCTAssertEqual(after.unmatchedIncome, 1500, "the credit is unmatched income again instead of vanishing behind a deleted source")
        XCTAssertEqual(after.totalExpenses, 0)
    }

    func testDeletingAGoalDetachesTheHabitsAimingAtIt() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addGoal(title: "Voyage", targetAmount: 1000, currentAmount: 0, targetDate: TestFixtures.date(2027, 6, 1), category: "Travel")
        try state.addGoal(title: "Vélo", targetAmount: 500, currentAmount: 0, targetDate: TestFixtures.date(2027, 6, 1), category: "Shopping")
        let trip = try XCTUnwrap(state.goals.first { $0.title == "Voyage" }), bike = try XCTUnwrap(state.goals.first { $0.title == "Vélo" })
        try state.addHabit(title: "Épargner", frequency: .weekly, targetCount: 1, completedCount: 0, linkedGoalID: trip.id)
        try state.addHabit(title: "Pédaler", frequency: .daily, targetCount: 1, completedCount: 0, linkedGoalID: bike.id)

        try state.deleteGoal(trip)

        XCTAssertNil(state.habits.first { $0.title == "Épargner" }?.linkedGoalID)
        XCTAssertEqual(state.habits.first { $0.title == "Pédaler" }?.linkedGoalID, bike.id, "a habit of another goal is left alone")
        XCTAssertEqual(state.habits.count, 2, "no habit is deleted")
    }

    // MARK: m002 - removing operations or an account removes the planning rows that pointed at them

    func testUnlinkingAnAccountReleasesItsProvisionPaymentsSoTheGoalCanBeDeleted() async throws {
        let (state, account) = try makeLinkedState(balance: 1000)
        let goalID = UUID()
        try state.planningWrite { try $0.saveProvision(id: goalID, title: "Insurance", target: 100, dueDate: TestFixtures.date(2027, 3, 14), renewal: "none", category: "other", now: now) }
        try state.dataStore.reserveForGoal(id: goalID, amount: 100, date: TestFixtures.date(2026, 8, 14))
        let tx = TestFixtures.transaction(account: account, reference: "insurance", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: tx.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.provisionPayments.count, 1)
        XCTAssertEqual(GoalFundingService().totalReserved(goalID: goalID, contributions: state.goalContributions), 0, "the payment consumed the reserve")

        let removed = await state.bankSync.unlink(account)

        XCTAssertTrue(removed)
        XCTAssertTrue(state.planning.provisionPayments.isEmpty, "no payment is left pointing at a vanished operation")
        XCTAssertEqual(state.goals.first?.currentAmount, 100, "the reserve its expense justified comes back")
        XCTAssertEqual(GoalFundingService().totalReserved(goalID: goalID, contributions: state.goalContributions), 100)
        XCTAssertEqual(state.goalContributions.count, 1, "only the original reservation remains")
        // A reserve is real money set aside: it is released first, like for any goal.
        let goal = try XCTUnwrap(state.goals.first)
        XCTAssertThrowsError(try state.deleteGoal(goal))
        try state.dataStore.reserveForGoal(id: goalID, amount: -100, date: Date())
        state.reload()

        try state.deleteGoal(goal)

        XCTAssertTrue(state.goals.isEmpty, "the orphan payment no longer blocks the deletion")
        XCTAssertTrue(state.planning.provisions.isEmpty)
    }

    func testUnlinkingAnAccountReleasesItsCommitmentPaymentsAndLetsTheCommitmentBeEditedAgain() async throws {
        let (state, account) = try makeLinkedState()
        var value = CommitmentDraft(); value.title = "Loyer"; value.amount = 100; value.category = ExpenseCategory.other.storageValue
        value.dueDate = now; value.accountID = account.id; value.count = 1
        let tx = TestFixtures.transaction(account: account, reference: "rent", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx])
        try state.planningWrite { try $0.saveCommitment(value) }
        try state.planningWrite { try $0.saveThreshold(accountID: account.id, amount: 50) }
        let event = try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first)
        try state.planningWrite { try $0.reconcilePayment(event: event, transactionID: tx.id, now: now, calendar: calendar) }
        var moved = CommitmentDraft(try XCTUnwrap(state.planning.commitments.first))
        moved.dueDate = TestFixtures.date(2026, 9, 16)
        XCTAssertThrowsError(try state.planningWrite { try $0.saveCommitment(moved) }, "a payment attached to the commitment locks its schedule")

        let removed = await state.bankSync.unlink(account)

        XCTAssertTrue(removed)
        XCTAssertTrue(state.planning.payments.isEmpty)
        XCTAssertTrue(state.planning.settings.isEmpty, "the alert threshold of a vanished account goes with it")
        let row = try XCTUnwrap(state.planning.commitments.first)
        XCTAssertNil(row.accountID, "the commitment falls back to no account instead of pointing at a ghost")
        var edited = CommitmentDraft(row)
        edited.dueDate = TestFixtures.date(2026, 9, 16)
        try state.planningWrite { try $0.saveCommitment(edited) }
        XCTAssertEqual(state.planning.commitments.first?.dueDate, TestFixtures.date(2026, 9, 16), "the schedule can move again")
    }

    func testRetentionAndPurgeAlsoRemoveWhatWasPlannedOnTheOperationsTheyDelete() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let old = TestFixtures.transaction(account: account, reference: "old", amount: 20, direction: .debit, dayOffset: -800)
        old.automaticCategory = old.category
        let vanishing = TestFixtures.transaction(account: account, reference: "vanishing", amount: 30, direction: .debit, dayOffset: -2)
        let kept = TestFixtures.transaction(account: account, reference: "kept", amount: 40, direction: .debit, dayOffset: -2)
        try store.importBankTransactions([old, vanishing, kept])
        let context = store.container.mainContext
        let refund = ExpectedRefund(transactionID: old.id, amount: 20, party: "Alice", dueDate: nil)
        context.insert(refund)
        context.insert(RefundReceipt(transactionID: UUID(), refundID: refund.id, amount: 5))
        context.insert(TransactionSplit(transactionID: vanishing.id, category: "Other", amount: 30))
        context.insert(RuleApplication(batchID: UUID(), transactionID: vanishing.id, ruleID: UUID(), previousCategory: "Other", appliedCategory: "Shopping", date: now))
        context.insert(TransactionSplit(transactionID: kept.id, category: "Other", amount: 40))
        try context.save()

        let report = try store.applyBankRetention(now: TestFixtures.referenceDate, calendar: calendar)

        XCTAssertEqual(report.purgedTransactions, 1)
        XCTAssertTrue(try store.planningFetch(ExpectedRefund.self).isEmpty, "the expected refund of a purged operation goes")
        XCTAssertTrue(try store.planningFetch(RefundReceipt.self).isEmpty, "...with its receipts")
        XCTAssertEqual(try store.planningFetch(TransactionSplit.self).count, 2, "rows of operations that still exist stay")

        // The bank no longer returns two recent operations: the window purge removes them like any other path.
        XCTAssertEqual(try store.pruneBankTransactions(accountID: account.id, bookedOnOrAfter: TestFixtures.day(offset: -10), keeping: [kept.externalID]), 1)
        XCTAssertEqual(try store.planningFetch(TransactionSplit.self).map(\.transactionID), [kept.id])
        XCTAssertTrue(try store.planningFetch(RuleApplication.self).isEmpty)
    }

    // MARK: m002 - the load-time repair

    func testTheLoadTimeRepairResetsOrphanedReferencesAndNeverDeletesAnEntryOfTheUser() throws {
        let store = try TestFixtures.makeDataStore()
        let context = store.container.mainContext
        let account = try XCTUnwrap(store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        try store.addSubscription(name: "Netflix", amount: 15, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: now, isActive: true)
        let subscription = try XCTUnwrap(store.loadSnapshot().subscriptions.first)
        let healthy = TestFixtures.transaction(account: account, reference: "healthy", amount: 15, direction: .debit, dayOffset: 0)
        healthy.apply(.subscription(subscription.id))
        let danglingLinks = TestFixtures.transaction(account: account, reference: "dangling", amount: 9, direction: .debit, dayOffset: -1)
        danglingLinks.linkedSubscriptionID = UUID(); danglingLinks.linkedPurchaseID = UUID(); danglingLinks.linkedIncomeSourceID = UUID()
        let paid = TestFixtures.transaction(account: account, reference: "paid", amount: 100, direction: .debit, dayOffset: -2)
        try store.importBankTransactions([healthy, danglingLinks, paid])

        // A provision paid with an operation that was later deleted without its payment.
        let goalID = UUID()
        try store.saveProvision(id: goalID, title: "Insurance", target: 100, dueDate: TestFixtures.date(2027, 3, 14), renewal: "none", category: "other", now: now)
        try context.save()
        try store.reserveForGoal(id: goalID, amount: 100, date: TestFixtures.date(2026, 8, 14))
        try store.applyProvisionPayment(goalID: goalID, transactionID: paid.id, now: now, calendar: calendar)
        try context.save()
        context.delete(paid)
        // Habits: one aims at a goal that no longer exists, one at a goal that does.
        try store.addHabit(title: "Ghost goal", frequency: .daily, targetCount: 1, completedCount: 0, linkedGoalID: UUID())
        try store.addHabit(title: "Live goal", frequency: .daily, targetCount: 1, completedCount: 0, linkedGoalID: goalID)
        // Planning rows of operations and of an account that do not exist, and rows of ones that do.
        let ghostAccount = UUID()
        context.insert(CommitmentPayment(transactionID: UUID(), commitmentID: UUID(), occurrenceKey: "ghost", amount: 10))
        context.insert(CommitmentPayment(transactionID: healthy.id, commitmentID: UUID(), occurrenceKey: "alive", amount: 15))
        context.insert(PlanningAccountSetting(accountID: ghostAccount, threshold: 100))
        context.insert(PlanningAccountSetting(accountID: account.id, threshold: 50))
        let commitment = PlannedCommitment(title: "Loyer", amount: 500, accountID: ghostAccount)
        context.insert(commitment)
        context.insert(PurchaseScenario(title: "Écran", amount: 300, date: now, accountID: ghostAccount))
        let rule = TransactionRule(title: "Courses", accountID: ghostAccount, merchant: "Carrefour", text: "", category: "Groceries", priority: 1)
        context.insert(rule)
        try context.save()
        XCTAssertEqual(try store.planningFetch(ProvisionPayment.self).count, 1)

        let repaired = try store.repairOrphanedReferences()

        XCTAssertGreaterThan(repaired, 0)
        XCTAssertEqual(healthy.linkedSubscriptionID, subscription.id, "a link to an entry that exists is never touched")
        XCTAssertNil(danglingLinks.link, "links to deleted entries are reset")
        XCTAssertNil(try store.loadSnapshot().habits.first { $0.title == "Ghost goal" }?.linkedGoalID)
        XCTAssertEqual(try store.loadSnapshot().habits.first { $0.title == "Live goal" }?.linkedGoalID, goalID)
        XCTAssertEqual(try store.planningFetch(CommitmentPayment.self).map(\.occurrenceKey), ["alive"])
        XCTAssertTrue(try store.planningFetch(ProvisionPayment.self).isEmpty)
        XCTAssertEqual(try store.planningFetch(Goal.self).first?.currentAmount, 100, "the reserve the vanished expense had consumed is back")
        XCTAssertEqual(GoalFundingService().totalReserved(goalID: goalID, contributions: try store.goalContributions()), 100)
        XCTAssertEqual(try store.planningFetch(PlanningAccountSetting.self).map(\.accountID), [account.id])
        XCTAssertNil(commitment.accountID, "the commitment itself is kept, without its ghost account")
        XCTAssertEqual(try store.planningFetch(PlannedCommitment.self).count, 1)
        XCTAssertNil(try store.planningFetch(PurchaseScenario.self).first?.accountID)
        XCTAssertFalse(rule.isEnabled, "a rule scoped to a vanished account is disabled, not widened to every account")
        XCTAssertEqual(rule.accountID, ghostAccount)
        XCTAssertEqual(try store.loadSnapshot().subscriptions.count, 1, "no entry of the user is deleted")

        XCTAssertEqual(try store.repairOrphanedReferences(), 0, "idempotent: a repaired base has nothing left to repair")
    }

    func testOpeningTheAppRepairsAnOrphanedBaseOnce() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let operation = TestFixtures.transaction(account: account, reference: "legacy", amount: 12, direction: .debit, dayOffset: 0)
        operation.linkedPurchaseID = UUID()
        try store.importBankTransactions([operation])
        store.container.mainContext.insert(CommitmentPayment(transactionID: UUID(), commitmentID: UUID(), occurrenceKey: "ghost", amount: 12))
        try store.container.mainContext.save()

        let state = AppState(dataStore: store, shouldSeedOnReload: false)

        XCTAssertNil(state.bankTransactions.first?.link, "the first load repairs the base")
        XCTAssertTrue(state.planning.payments.isEmpty)
        XCTAssertEqual(try store.repairOrphanedReferences(), 0)
    }

    // MARK: m089 - one billing date for the subscription and the commitment drawn from it

    func testAnAutomaticAdvanceMovesThePlannedCommitmentAndSavingItDoesNotRevertTheDate() throws {
        let (state, account) = try makeLinkedState()
        try state.addSubscription(name: "Netflix", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.date(2026, 9, 20), isActive: true)
        let subscription = try XCTUnwrap(state.subscriptions.first)
        // A planned commitment exists for the subscription as soon as the user works with it in the commitments screen.
        let initial = try XCTUnwrap(state.commitmentDrafts(on: now, calendar: calendar).first { $0.sourceKind == "subscription" })
        try state.planningWrite { try $0.saveCommitment(initial) }
        XCTAssertEqual(state.planning.commitments.first?.dueDate, TestFixtures.date(2026, 9, 20))

        // The bank settles it on the 19th: the reconciliation links the operation and advances the billing date.
        let tx = TestFixtures.transaction(account: account, reference: "nflx", amount: 20, direction: .debit, dayOffset: 0, label: "PRLV NETFLIX")
        tx.bookingDate = TestFixtures.date(2026, 9, 19)
        try state.dataStore.importBankTransactions([tx])
        let applied = try state.dataStore.applyReconciliation([.init(externalID: tx.externalID, link: .subscription(subscription.id))], advancingBillingDates: true, referenceDate: now, calendar: calendar)
        state.reload()

        XCTAssertEqual(applied, 1)
        let advanced = TestFixtures.date(2026, 10, 20)
        XCTAssertEqual(state.subscriptions.first?.nextBillingDate, advanced)
        XCTAssertEqual(state.planning.commitments.first?.dueDate, advanced, "the planned commitment follows the subscription")
        let drafts = state.commitmentDrafts(on: now, calendar: calendar).filter { $0.sourceKind == "subscription" }
        XCTAssertEqual(drafts.count, 1, "one commitment for the subscription")
        XCTAssertEqual(drafts.first?.dueDate, advanced, "and one date")

        // Saving the commitment from its screen must keep the advance instead of restoring the old date.
        let draft = try XCTUnwrap(drafts.first)
        try state.planningWrite { try $0.saveCommitment(draft) }
        XCTAssertEqual(state.subscriptions.first?.nextBillingDate, advanced)
        XCTAssertEqual(state.planning.commitments.first?.dueDate, advanced)
    }

    // MARK: m031 - an operation is assigned once

    func testAnOperationAssignedToACommitmentIsRefusedByAProvisionAndConversely() throws {
        let (state, account) = try makeLinkedState(balance: 1000)
        let goalID = UUID()
        try state.planningWrite { try $0.saveProvision(id: goalID, title: "Insurance", target: 100, dueDate: TestFixtures.date(2027, 3, 14), renewal: "none", category: "other", now: now) }
        try state.dataStore.reserveForGoal(id: goalID, amount: 100, date: TestFixtures.date(2026, 8, 14))
        func commitment(_ title: String) -> CommitmentDraft {
            var value = CommitmentDraft(); value.title = title; value.amount = 100; value.category = ExpenseCategory.other.storageValue
            value.dueDate = now; value.accountID = account.id; value.count = 1
            return value
        }
        let first = commitment("Premier"), second = commitment("Second")
        let forCommitment = TestFixtures.transaction(account: account, reference: "to-commitment", amount: 100, direction: .debit, dayOffset: 0)
        let forProvision = TestFixtures.transaction(account: account, reference: "to-provision", amount: 100, direction: .debit, dayOffset: 0)
        let spare = TestFixtures.transaction(account: account, reference: "spare", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([forCommitment, forProvision, spare])
        try state.planningWrite { try $0.saveCommitment(first); try $0.saveCommitment(second) }
        func event(of draft: CommitmentDraft) throws -> ForecastEvent {
            try XCTUnwrap(state.planningEvents(on: now, until: TestFixtures.date(2026, 10, 1), calendar: calendar).first { $0.commitmentID == draft.id })
        }
        XCTAssertTrue(try state.dataStore.isTransactionFree(id: forCommitment.id))

        // Assigned to a commitment first: the provision refuses it.
        try state.planningWrite { try $0.reconcilePayment(event: try event(of: first), transactionID: forCommitment.id, now: now, calendar: calendar) }
        XCTAssertFalse(try state.dataStore.isTransactionFree(id: forCommitment.id))
        XCTAssertThrowsError(try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: forCommitment.id, now: now, calendar: calendar) })
        XCTAssertTrue(state.planning.provisionPayments.isEmpty, "nothing was consumed")
        XCTAssertEqual(GoalFundingService().totalReserved(goalID: goalID, contributions: state.goalContributions), 100)

        // Assigned to a provision first: a commitment refuses it, and accepts a free operation.
        try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: forProvision.id, now: now, calendar: calendar) }
        XCTAssertFalse(try state.dataStore.isTransactionFree(id: forProvision.id))
        XCTAssertThrowsError(try state.planningWrite { try $0.reconcilePayment(event: try event(of: second), transactionID: forProvision.id, now: now, calendar: calendar) })
        XCTAssertEqual(state.planning.payments.count, 1, "the second commitment received nothing")
        try state.planningWrite { try $0.reconcilePayment(event: try event(of: second), transactionID: spare.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.payments.count, 2, "the refusal was about the operation, not the commitment")

        // The selection lists ask the same question of the same snapshot.
        let assigned = state.planning.assignedTransactionIDs
        XCTAssertEqual(assigned, [forCommitment.id, forProvision.id, spare.id])
        XCTAssertTrue([forCommitment, forProvision, spare].allSatisfy { !PeculeDataStore.isTransactionFree($0, assignedTransactionIDs: assigned) })
    }

    func testAnOperationLinkedToAnEntryOrExpectingARefundIsNotFree() throws {
        let (state, account) = try makeLinkedState(balance: 1000)
        let goalID = UUID()
        try state.planningWrite { try $0.saveProvision(id: goalID, title: "Insurance", target: 100, dueDate: TestFixtures.date(2027, 3, 14), renewal: "none", category: "other", now: now) }
        let linked = TestFixtures.transaction(account: account, reference: "linked", amount: 30, direction: .debit, dayOffset: 0)
        linked.apply(.subscription(UUID()))
        let expecting = TestFixtures.transaction(account: account, reference: "expecting", amount: 30, direction: .debit, dayOffset: 0)
        let free = TestFixtures.transaction(account: account, reference: "free", amount: 30, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([linked, expecting, free])
        let refund = ExpectedRefund(transactionID: expecting.id, amount: 30, party: "Alice", dueDate: nil)
        state.dataStore.container.mainContext.insert(refund)
        try state.dataStore.container.mainContext.save()
        state.reload()

        XCTAssertFalse(try state.dataStore.isTransactionFree(id: linked.id))
        XCTAssertFalse(try state.dataStore.isTransactionFree(id: expecting.id))
        XCTAssertTrue(try state.dataStore.isTransactionFree(id: free.id))
        XCTAssertThrowsError(try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: linked.id, now: now, calendar: calendar) },
                             "a debit already linked to a subscription cannot also consume a reserve")
        XCTAssertThrowsError(try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: expecting.id, now: now, calendar: calendar) })
        XCTAssertThrowsError(try state.dataStore.isTransactionFree(id: UUID()), "an operation that no longer exists is not free either")

        refund.isAbandoned = true
        try state.dataStore.container.mainContext.save()
        XCTAssertTrue(try state.dataStore.isTransactionFree(id: expecting.id), "a refund the user gave up on no longer holds the operation")
        try state.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: free.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.provisionPayments.count, 1)
    }
}
