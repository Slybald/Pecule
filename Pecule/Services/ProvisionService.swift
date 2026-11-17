import Foundation
import SwiftData

struct ProvisionSummary {
    var goalID: UUID
    var title: String
    var target: Decimal
    var dueDate: Date
    var reserved: Decimal
    var paid: Decimal
    var monthlyNeeded: Decimal
    var renewal: String
}

extension PeculeDataStore {
    // Called inside planningWrite: the provision and its goal are one atomic edit.
    func saveProvision(id: UUID, title: String, target: Decimal, dueDate: Date, renewal: String, category: String, now: Date = Date()) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.isNaN, target.currencyRounded > 0, ["none", "yearly"].contains(renewal) else { throw BankTransactionEditError.unavailable }
        let goals = try planningFetch(Goal.self)
        let goal = goals.first { $0.id == id } ?? Goal(id: id, title: title, targetAmount: target, currentAmount: 0, targetDate: dueDate, category: category, isArchived: false)
        guard !goal.isArchived, try planningFetch(GoalProvision.self).first(where: { $0.goalID == id })?.renewal != "completed" else { throw BankTransactionEditError.unavailable }
        if !goals.contains(where: { $0.id == id }) { container.mainContext.insert(goal) }
        goal.title = title.trimmingCharacters(in: .whitespacesAndNewlines); goal.targetAmount = target.currencyRounded
        goal.targetDate = dueDate; goal.category = ExpenseCategory.formStorageValue(for: category)
        // String-backed intention: no change to the persisted schema or frozen enums.
        goal.intention = "plannedExpense"; goal.startedAt = goal.startedAt ?? now
        if let provision = try planningFetch(GoalProvision.self).first(where: { $0.goalID == id }) {
            provision.dueDate = dueDate; provision.renewal = renewal
        } else { container.mainContext.insert(GoalProvision(goalID: id, dueDate: dueDate, renewal: renewal)) }
    }

    func applyProvisionPayment(goalID: UUID, transactionID: UUID, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let goal = try planningFetch(Goal.self).first(where: { $0.id == goalID && !$0.isArchived }),
              try planningFetch(GoalProvision.self).contains(where: { $0.goalID == goalID }),
              try isTransactionFree(id: transactionID) else { throw BankTransactionEditError.unavailable }
        let tx = try editableBankTransaction(id: transactionID)
        guard Self.validProvisionPayment(tx, now: now, calendar: calendar) else { throw BankTransactionEditError.unavailable }
        let contributions = try goalContributions()
        let booked = calendar.startOfDay(for: tx.bookingDate)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: booked)!
        // A reserve made after the payment date cannot retroactively fund that payment.
        let available = GoalFundingService().totalReserved(goalID: goalID, contributions: contributions.filter { $0.date < nextDay })
        let current = GoalFundingService().totalReserved(goalID: goalID, contributions: contributions)
        let consumed = min(tx.amount, available, current).currencyRounded
        let contribution = GoalContribution(goalID: goalID, date: booked, amount: -consumed)
        container.mainContext.insert(contribution)
        container.mainContext.insert(ProvisionPayment(transactionID: transactionID, goalID: goalID, amount: consumed, contributionID: contribution.id))
        goal.currentAmount = max(0, goal.currentAmount - consumed).currencyRounded
    }

    static func validProvisionPayment(_ tx: BankTransaction, now: Date, calendar: Calendar) -> Bool {
        tx.countsInTotals && tx.isExpense && tx.currencyCode == "EUR" && calendar.startOfDay(for: tx.bookingDate) <= calendar.startOfDay(for: now)
    }

    func removeProvisionPayment(transactionID: UUID) throws {
        guard let payment = try planningFetch(ProvisionPayment.self).first(where: { $0.transactionID == transactionID }),
              let goal = try planningFetch(Goal.self).first(where: { $0.id == payment.goalID }) else { throw BankTransactionEditError.unavailable }
        if let entry = try goalContributions().first(where: { $0.id == payment.contributionID }) {
            goal.currentAmount -= entry.amount
            goal.isArchived = false
            container.mainContext.delete(entry)
        }
        container.mainContext.delete(payment)
    }

    // Bank corrections can reduce/withdraw a paid amount. Restore the affected reserve;
    // never create money by keeping a release without its corresponding booked expense.
    func reconcileProvisionPayments(now: Date = Date(), calendar: Calendar = .current) throws {
        let payments = try planningFetch(ProvisionPayment.self)
        guard !payments.isEmpty else { return }
        let entries = try goalContributions(), goals = try planningFetch(Goal.self)
        var changed = false
        for payment in payments {
            guard let entry = entries.first(where: { $0.id == payment.contributionID }),
                  let goal = goals.first(where: { $0.id == payment.goalID }) else { continue }
            let tx = try? editableBankTransaction(id: payment.transactionID)
            let actual = tx.flatMap { Self.validProvisionPayment($0, now: now, calendar: calendar) ? $0.amount : nil } ?? 0
            // Reappearing payments never consume funds already released elsewhere.
            let available = GoalFundingService().totalReserved(goalID: goal.id, contributions: entries) - entry.amount
            let bookingDay = tx.map { calendar.startOfDay(for: $0.bookingDate) } ?? entry.date
            let nextDay = calendar.date(byAdding: .day, value: 1, to: bookingDay)!
            let beforePayment = GoalFundingService().totalReserved(goalID: goal.id, contributions: entries.filter { $0.id != entry.id && $0.date < nextDay })
            let desired = -min(payment.amount, actual, available, beforePayment)
            if entry.amount != desired {
                if desired > entry.amount { goal.isArchived = false }
                goal.currentAmount = max(0, goal.currentAmount + desired - entry.amount)
                entry.amount = desired; changed = true
            }
            if entry.date != bookingDay { entry.date = bookingDay; changed = true }
        }
        if changed { try container.mainContext.save() }
    }

    func renewProvision(goalID: UUID, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let old = try planningFetch(Goal.self).first(where: { $0.id == goalID && !$0.isArchived }),
              let provision = try planningFetch(GoalProvision.self).first(where: { $0.goalID == goalID && $0.renewal == "yearly" }),
              let nextDate = calendar.date(byAdding: .year, value: 1, to: provision.dueDate) else { throw BankTransactionEditError.unavailable }
        let payments = try planningFetch(ProvisionPayment.self).filter { $0.goalID == goalID }
        let paid = payments.reduce(Decimal.zero) { amount, payment in
            guard let tx = try? editableBankTransaction(id: payment.transactionID), Self.validProvisionPayment(tx, now: now, calendar: calendar) else { return amount }
            return amount + tx.amount
        }
        guard paid >= old.targetAmount else { throw BankTransactionEditError.unavailable }
        let newID = UUID()
        try saveProvision(id: newID, title: old.title, target: old.targetAmount, dueDate: nextDate, renewal: "yearly", category: old.category, now: now)
        // History and associations remain on the old cycle. Carry the unused reserve
        // through two offsetting contributions; this creates no new monthly reservation.
        let remaining = GoalFundingService().totalReserved(goalID: goalID, contributions: try goalContributions())
        if remaining > 0, let new = try planningFetch(Goal.self).first(where: { $0.id == newID }) {
            container.mainContext.insert(GoalContribution(goalID: goalID, date: now, amount: -remaining))
            container.mainContext.insert(GoalContribution(goalID: newID, date: now, amount: remaining))
            old.currentAmount -= remaining; new.currentAmount += remaining
        }
        provision.renewal = "completed"
        old.isArchived = true
    }
}

extension AppState {
    func provisionSummaries(on now: Date = Date(), calendar: Calendar = .current) -> [ProvisionSummary] {
        let transactions = Dictionary((bankTransactions + planning.paymentTransactions).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return planning.provisions.compactMap { provision in
            guard let goal = goals.first(where: { $0.id == provision.goalID && !$0.isArchived }) else { return nil }
            let reserved = GoalFundingService().totalReserved(goalID: goal.id, contributions: goalContributions)
            let paid = planning.provisionPayments.filter { $0.goalID == goal.id }.reduce(Decimal.zero) { total, payment in
                guard let tx = transactions[payment.transactionID], PeculeDataStore.validProvisionPayment(tx, now: now, calendar: calendar) else { return total }
                return total + tx.amount
            }
            return .init(goalID: goal.id, title: goal.title, target: goal.targetAmount, dueDate: provision.dueDate, reserved: reserved, paid: paid,
                         monthlyNeeded: PlanningEngine(calendar: calendar).provisionContribution(target: max(0, goal.targetAmount - paid), reserved: reserved, due: provision.dueDate, now: now), renewal: provision.renewal)
        }.sorted { $0.dueDate < $1.dueDate }
    }

    // Consumption offsets a booked expense only in the bank budget containing it.
    // In manual mode or for excluded accounts, do not manufacture available income.
    func budgetGoalContributions() -> [GoalContribution] {
        let ids = Set(externalAccounts.filter { $0.isIncludedInTotals && !$0.isManual }.map(\.id))
        let transactions = Dictionary((bankTransactions + planning.paymentTransactions).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let excluded = Set(planning.provisionPayments.filter { payment in
            !prefersBankAmounts || (transactions[payment.transactionID].map { !ids.contains($0.accountID) || !$0.countsInTotals } ?? true)
        }.map(\.contributionID))
        return goalContributions.filter { !excluded.contains($0.id) }
    }
}
