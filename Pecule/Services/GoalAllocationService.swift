import Foundation
import SwiftData

struct AllocationTarget: Identifiable, Equatable {
    var id: UUID
    var title: String
    var target: Decimal
    var current: Decimal
    var deadline: Date?
    var remaining: Decimal { max(0, target - current).currencyRounded }
}

struct AllocationEntry: Identifiable, Equatable {
    var goalID: UUID
    var amount: Decimal
    var id: UUID { goalID }
}

struct AllocationDraft: Equatable {
    var capacity: Decimal
    // Array order is the priority; it is saved only on confirmation.
    var entries: [AllocationEntry]
    var allocated: Decimal { entries.reduce(0) { $0 + $1.amount.currencyRounded }.currencyRounded }
    var unallocated: Decimal { (capacity.currencyRounded - allocated).currencyRounded }
}

struct AllocationComparison: Identifiable {
    var target: AllocationTarget
    var before: GoalSimulation
    var after: GoalSimulation
    var id: UUID { target.id }
}

enum AllocationError: LocalizedError {
    case invalidAmount, overCapacity, changedGoals, exceedsGoal
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidAmount: key = "allocation.invalidAmount"
        case .overCapacity: key = "allocation.overCapacity"
        case .changedGoals: key = "allocation.changedGoals"
        case .exceedsGoal: key = "allocation.exceedsGoal"
        }
        return AppLocalizer.string(key)
    }
}

enum GoalAllocationService {
    @MainActor
    static func targets(goals: [Goal], planning: PlanningSnapshot, now: Date, calendar: Calendar) -> [AllocationTarget] {
        let transactions = Dictionary(planning.paymentTransactions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let provisionIDs = Set(planning.provisions.map(\.goalID))
        var paid: [UUID: Decimal] = [:]
        for payment in planning.provisionPayments {
            if let tx = transactions[payment.transactionID], PeculeDataStore.validProvisionPayment(tx, now: now, calendar: calendar) {
                paid[payment.goalID, default: 0] += tx.amount
            }
        }
        return goals.filter { !$0.isArchived }.compactMap { goal in
            // A paid portion of a provision no longer needs funding, even though its
            // consumed reserve is no longer part of currentAmount.
            let target = max(0, goal.targetAmount - (provisionIDs.contains(goal.id) ? paid[goal.id, default: 0] : 0))
            let value = AllocationTarget(id: goal.id, title: goal.title, target: target,
                                         current: goal.currentAmount, deadline: goal.deadline(calendar: calendar))
            return value.remaining > 0 ? value : nil
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func draft(capacity: Decimal, saved: [GoalAllocation], targets: [AllocationTarget]) -> AllocationDraft {
        let ids = Set(targets.map(\.id))
        let ordered = saved.filter { ids.contains($0.goalID) }.sorted {
            $0.priority == $1.priority ? $0.goalID.uuidString < $1.goalID.uuidString : $0.priority < $1.priority
        }
        let storedIDs = Set(ordered.map(\.goalID))
        let entries = ordered.map { AllocationEntry(goalID: $0.goalID, amount: $0.amount) }
            + targets.filter { !storedIDs.contains($0.id) }.map { AllocationEntry(goalID: $0.id, amount: 0) }
        return .init(capacity: capacity, entries: entries)
    }

    static func normalized(_ draft: AllocationDraft, targets: [AllocationTarget]) throws -> AllocationDraft {
        guard !draft.capacity.isNaN, draft.capacity >= 0,
              draft.entries.allSatisfy({ !$0.amount.isNaN && $0.amount >= 0 }) else { throw AllocationError.invalidAmount }
        guard draft.entries.count == targets.count,
              Set(draft.entries.map(\.goalID)) == Set(targets.map(\.id)) else { throw AllocationError.changedGoals }
        let value = AllocationDraft(capacity: draft.capacity.currencyRounded,
                                    entries: draft.entries.map { .init(goalID: $0.goalID, amount: $0.amount.currencyRounded) })
        guard value.allocated <= value.capacity else { throw AllocationError.overCapacity }
        let remaining = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.remaining) })
        guard value.entries.allSatisfy({ $0.amount <= remaining[$0.goalID, default: 0] }) else { throw AllocationError.exceedsGoal }
        return value
    }

    static func distribute(_ draft: AllocationDraft, targets: [AllocationTarget]) throws -> AllocationDraft {
        guard !draft.capacity.isNaN, draft.capacity >= 0 else { throw AllocationError.invalidAmount }
        let remaining = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.remaining) })
        var available = draft.capacity.currencyRounded
        let entries = draft.entries.map { row in
            let amount = min(available, remaining[row.goalID, default: 0])
            available -= amount
            return AllocationEntry(goalID: row.goalID, amount: amount)
        }
        return try normalized(.init(capacity: draft.capacity, entries: entries), targets: targets)
    }

    static func compare(before: AllocationDraft, after: AllocationDraft, targets: [AllocationTarget], now: Date, calendar: Calendar) throws -> [AllocationComparison] {
        let after = try normalized(after, targets: targets)
        let simulator = GoalSimulator(calendar: calendar)
        let previous = Dictionary(before.entries.map { ($0.goalID, $0.amount) }, uniquingKeysWith: { _, last in last })
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        return after.entries.compactMap { row in
            guard let goal = byID[row.goalID] else { return nil }
            return .init(target: goal,
                         before: simulator.simulate(target: goal.target, current: goal.current, targetDate: goal.deadline, monthlyContribution: previous[goal.id, default: 0], now: now),
                         after: simulator.simulate(target: goal.target, current: goal.current, targetDate: goal.deadline, monthlyContribution: row.amount, now: now))
        }
    }
}

extension PeculeDataStore {
    // Caller uses planningWrite so replacement is atomic and profile-scoped.
    func saveAllocationPlan(_ draft: AllocationDraft, now: Date = Date(), calendar: Calendar = .current) throws {
        let targets = try GoalAllocationService.targets(goals: planningFetch(Goal.self), planning: planningSnapshot(), now: now, calendar: calendar)
        let value = try GoalAllocationService.normalized(draft, targets: targets)
        let plans = try planningFetch(GoalAllocationPlan.self)
        if let plan = plans.first(where: { $0.key == "shared" }) { plan.capacity = value.capacity }
        else { container.mainContext.insert(GoalAllocationPlan(capacity: value.capacity)) }
        try planningFetch(GoalAllocation.self).forEach(container.mainContext.delete)
        for (index, entry) in value.entries.enumerated() {
            container.mainContext.insert(GoalAllocation(goalID: entry.goalID, amount: entry.amount, priority: index))
        }
    }
}

extension AppState {
    func allocationTargets(on now: Date = Date(), calendar: Calendar = .current) -> [AllocationTarget] {
        GoalAllocationService.targets(goals: goals, planning: planning, now: now, calendar: calendar)
    }
    func allocationDraft(on now: Date = Date(), calendar: Calendar = .current) -> AllocationDraft {
        GoalAllocationService.draft(capacity: planning.allocationPlans.first { $0.key == "shared" }?.capacity ?? 0,
                                    saved: planning.allocations, targets: allocationTargets(on: now, calendar: calendar))
    }
}
