import Foundation
import SwiftData

// Planning rows and operation links are keyed on identifiers, not on SwiftData relationships: whoever removes an
// operation or an account has to remove what points at it, or the orphan keeps blocking later edits (a payment of
// a vanished operation refuses any change of its commitment, and the deletion of its goal). This file is that one
// place, plus the load-time repair for the bases earlier versions already left in that state.
extension PeculeDataStore {
    // Every way a bank operation leaves the store goes through here: account removal, retention and window purge.
    // The rows planned on those operations go with them. Does not save.
    func deleteBankTransactions(_ transactions: [BankTransaction]) throws {
        guard !transactions.isEmpty else { return }
        try removePlanningRows(pointingAt: Set(transactions.map(\.id)))
        transactions.forEach(container.mainContext.delete)
    }

    // Drops the association rows of operations that are gone: commitment and provision payments, expected
    // refunds and their receipts, rule applications and splits. A provision payment gives back the reserve it
    // consumed, as when it is withdrawn by hand: the expense that justified the release no longer exists.
    // Everything is read before anything changes, so a failed read leaves nothing half done. Does not save.
    @discardableResult
    func removePlanningRows(pointingAt transactionIDs: Set<UUID>) throws -> Int {
        guard !transactionIDs.isEmpty else { return 0 }
        let context = container.mainContext
        let commitmentPayments = try planningFetch(CommitmentPayment.self).filter { transactionIDs.contains($0.transactionID) }
        let provisionPayments = try planningFetch(ProvisionPayment.self).filter { transactionIDs.contains($0.transactionID) }
        let entries = try provisionPayments.isEmpty ? [] : goalContributions()
        let goals = try provisionPayments.isEmpty ? [] : planningFetch(Goal.self)
        let refunds = try planningFetch(ExpectedRefund.self).filter { transactionIDs.contains($0.transactionID) }
        let refundIDs = Set(refunds.map(\.id))
        let receipts = try planningFetch(RefundReceipt.self).filter { transactionIDs.contains($0.transactionID) || refundIDs.contains($0.refundID) }
        let applications = try planningFetch(RuleApplication.self).filter { transactionIDs.contains($0.transactionID) }
        let splits = try planningFetch(TransactionSplit.self).filter { transactionIDs.contains($0.transactionID) }

        for payment in provisionPayments {
            if let entry = entries.first(where: { $0.id == payment.contributionID }) {
                if entry.amount < 0, let goal = goals.first(where: { $0.id == payment.goalID }) {
                    goal.currentAmount = (goal.currentAmount - entry.amount).currencyRounded
                    goal.isArchived = false
                }
                context.delete(entry)
            }
            context.delete(payment)
        }
        commitmentPayments.forEach(context.delete)
        receipts.forEach(context.delete)
        refunds.forEach(context.delete)
        applications.forEach(context.delete)
        splits.forEach(context.delete)
        return commitmentPayments.count + provisionPayments.count + refunds.count + receipts.count + applications.count + splits.count
    }

    // What is planned on an account that is gone: its alert threshold goes, a commitment or a scenario falls
    // back to "no account" (the user picks another one), and a rule that applied to that account alone is
    // disabled rather than widened to every account. Does not save.
    func detachPlanningRows(fromAccount accountID: UUID) throws {
        try detachPlanningRows { $0 == accountID }
    }

    @discardableResult
    private func detachPlanningRows(where isGone: (UUID) -> Bool) throws -> Int {
        let settings = try planningFetch(PlanningAccountSetting.self).filter { isGone($0.accountID) }
        let commitments = try planningFetch(PlannedCommitment.self).filter { $0.accountID.map(isGone) == true }
        let scenarios = try planningFetch(PurchaseScenario.self).filter { $0.accountID.map(isGone) == true }
        let rules = try planningFetch(TransactionRule.self).filter { $0.isEnabled && $0.accountID.map(isGone) == true }
        settings.forEach(container.mainContext.delete)
        commitments.forEach { $0.accountID = nil }
        scenarios.forEach { $0.accountID = nil }
        rules.forEach { $0.isEnabled = false }
        return settings.count + commitments.count + scenarios.count + rules.count
    }

    // One idempotent pass for what earlier versions left behind: operations linked to a subscription, a purchase or
    // an income source that was deleted, habits aiming at a deleted goal, planning rows pointing at operations or
    // accounts that no longer exist. It resets references and drops the association rows that point at nothing;
    // it never deletes an entry of the user's own. Returns how many references it repaired (0 when nothing is left).
    @discardableResult
    func repairOrphanedReferences() throws -> Int {
        let context = container.mainContext
        do {
            var repaired = 0
            let linked = try context.fetch(FetchDescriptor<BankTransaction>(
                predicate: #Predicate { $0.linkedPurchaseID != nil || $0.linkedSubscriptionID != nil || $0.linkedIncomeSourceID != nil }
            ))
            if !linked.isEmpty {
                let subscriptionIDs = Set(try context.fetch(FetchDescriptor<Subscription>()).map(\.id))
                let purchaseIDs = Set(try context.fetch(FetchDescriptor<Purchase>()).map(\.id))
                let incomeSourceIDs = Set(try context.fetch(FetchDescriptor<IncomeSource>()).map(\.id))
                for transaction in linked {
                    if let id = transaction.linkedSubscriptionID, !subscriptionIDs.contains(id) { transaction.linkedSubscriptionID = nil; repaired += 1 }
                    if let id = transaction.linkedPurchaseID, !purchaseIDs.contains(id) { transaction.linkedPurchaseID = nil; repaired += 1 }
                    if let id = transaction.linkedIncomeSourceID, !incomeSourceIDs.contains(id) { transaction.linkedIncomeSourceID = nil; repaired += 1 }
                }
            }

            let habits = try context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.linkedGoalID != nil }))
            if !habits.isEmpty {
                let goalIDs = Set(try context.fetch(FetchDescriptor<Goal>()).map(\.id))
                for habit in habits {
                    if let id = habit.linkedGoalID, !goalIDs.contains(id) { habit.linkedGoalID = nil; repaired += 1 }
                }
            }

            repaired += try removePlanningRows(pointingAt: try missingTransactionIDs())
            let refundIDs = Set(try planningFetch(ExpectedRefund.self).map(\.id))
            let strayReceipts = try planningFetch(RefundReceipt.self).filter { !refundIDs.contains($0.refundID) }
            strayReceipts.forEach(context.delete)
            repaired += strayReceipts.count

            let accountIDs = Set(try context.fetch(FetchDescriptor<ExternalAccount>()).map(\.id))
            repaired += try detachPlanningRows { !accountIDs.contains($0) }

            if context.hasChanges { try context.save() }
            return repaired
        } catch {
            context.rollback()
            throw error
        }
    }

    // The operations that planning rows point at but that are no longer stored. Operation identifiers are checked
    // in chunks: a store can hold tens of thousands of rows, and the referenced ones are the few that matter.
    private func missingTransactionIDs() throws -> Set<UUID> {
        var referenced = Set(try planningFetch(CommitmentPayment.self).map(\.transactionID))
        referenced.formUnion(try planningFetch(ProvisionPayment.self).map(\.transactionID))
        referenced.formUnion(try planningFetch(ExpectedRefund.self).map(\.transactionID))
        referenced.formUnion(try planningFetch(RefundReceipt.self).map(\.transactionID))
        referenced.formUnion(try planningFetch(RuleApplication.self).map(\.transactionID))
        referenced.formUnion(try planningFetch(TransactionSplit.self).map(\.transactionID))
        guard !referenced.isEmpty else { return [] }
        let ids = Array(referenced)
        var present = Set<UUID>()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start ..< min(start + 400, ids.count)])
            present.formUnion(try container.mainContext.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { chunk.contains($0.id) })).map(\.id))
        }
        return referenced.subtracting(present)
    }
}
