import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class GoalAllocationTests: XCTestCase {
    private let now = TestFixtures.date(2026, 9, 14)
    private let calendar = TestFixtures.utcCalendar()
    private func setup() throws -> AppState {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addGoal(title: "Trip", targetAmount: 1000, currentAmount: 100, targetDate: TestFixtures.date(2027, 1, 14), category: "other")
        try state.addGoal(title: "Bike", targetAmount: 200, currentAmount: 0, targetDate: TestFixtures.date(2026, 12, 14), category: "other")
        return state
    }
    func testPriorityProposalSharesOneCapacityAndLeavesSurplusUnassigned() throws {
        let state = try setup(), targets = state.allocationTargets(on: now, calendar: calendar)
        let bike = try XCTUnwrap(targets.first { $0.title == "Bike" })
        let trip = try XCTUnwrap(targets.first { $0.title == "Trip" })
        let input = AllocationDraft(capacity: 300, entries: [.init(goalID: bike.id, amount: 0), .init(goalID: trip.id, amount: 0)])
        let result = try GoalAllocationService.distribute(input, targets: targets)
        XCTAssertEqual(result.entries.map(\.amount), [200, 100]); XCTAssertEqual(result.unallocated, 0)
        var reversed = input; reversed.entries.reverse()
        XCTAssertEqual(try GoalAllocationService.distribute(reversed, targets: targets).entries.map(\.amount), [300, 0])
        var surplus = input; surplus.capacity = 2000
        XCTAssertEqual(try GoalAllocationService.distribute(surplus, targets: targets).unallocated, 900)
    }
    func testMoneyIsRoundedBeforeCheckingSharedCapacityAndZeroIsValid() throws {
        let state = try setup(), targets = state.allocationTargets(on: now, calendar: calendar)
        var draft = state.allocationDraft(on: now, calendar: calendar)
        draft.capacity = TestFixtures.decimal("0.67")
        for index in draft.entries.indices { draft.entries[index].amount = TestFixtures.decimal("0.335") }
        XCTAssertThrowsError(try GoalAllocationService.normalized(draft, targets: targets))
        draft.capacity = TestFixtures.decimal("0.68")
        XCTAssertEqual(try GoalAllocationService.normalized(draft, targets: targets).allocated, TestFixtures.decimal("0.68"))
        draft.capacity = 0
        for index in draft.entries.indices { draft.entries[index].amount = 0 }
        XCTAssertEqual(try GoalAllocationService.normalized(draft, targets: targets).unallocated, 0)
        for value: Decimal in [-1, .nan] {
            draft.capacity = value
            XCTAssertThrowsError(try GoalAllocationService.normalized(draft, targets: targets))
        }
        draft.capacity = 100; draft.entries[0].amount = .nan
        XCTAssertThrowsError(try GoalAllocationService.normalized(draft, targets: targets))
    }
    func testComparisonUsesExistingSimulatorAcrossLeapMonthAndNoRateHasNoDate() throws {
        let id = UUID(), start = TestFixtures.date(2028, 1, 31)
        let target = AllocationTarget(id: id, title: "Trip", target: 1000, current: 100, deadline: TestFixtures.date(2028, 4, 30))
        let before = AllocationDraft(capacity: 0, entries: [.init(goalID: id, amount: 0)])
        let after = AllocationDraft(capacity: 900, entries: [.init(goalID: id, amount: 900)])
        let value = try XCTUnwrap(GoalAllocationService.compare(before: before, after: after, targets: [target], now: start, calendar: calendar).first)
        XCTAssertNil(value.before.completionDate)
        XCTAssertEqual(value.after.completionDate, TestFixtures.date(2028, 2, 29))
        XCTAssertEqual(value.after, GoalSimulator(calendar: calendar).simulate(target: 1000, current: 100, targetDate: target.deadline, monthlyContribution: 900, now: start))
    }
    func testPreviewSaveEditAndRejectedPlanNeverChangeActualFinances() throws {
        let state = try setup()
        let account = TestFixtures.linkedAccount(balance: 2000)
        try state.dataStore.saveExternalAccounts([account]); state.reload()
        let goal = try XCTUnwrap(state.goals.first)
        try state.dataStore.reserveForGoal(id: goal.id, amount: 10, date: now); state.reload()
        let actual = state.goals.map { $0.currentAmount }
        let budget = state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive
        let initial = state.allocationDraft(on: now, calendar: calendar)
        var draft = initial; draft.capacity = 100; draft.entries[0].amount = 80
        _ = try GoalAllocationService.compare(before: initial, after: draft, targets: state.allocationTargets(on: now, calendar: calendar), now: now, calendar: calendar)
        XCTAssertTrue(state.planning.allocations.isEmpty)
        try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) }
        XCTAssertEqual(state.planning.allocationPlans.count, 1)
        draft.entries.reverse(); draft.entries[0].amount = 10
        try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) }
        XCTAssertEqual(state.allocationDraft(on: now, calendar: calendar), draft)
        var bad = draft; bad.capacity = 1
        XCTAssertThrowsError(try state.planningWrite { try $0.saveAllocationPlan(bad, now: now, calendar: calendar) })
        XCTAssertEqual(state.allocationDraft(on: now, calendar: calendar), draft)
        XCTAssertEqual(state.goals.map { $0.currentAmount }, actual)
        XCTAssertEqual(state.goalContributions.count, 1); XCTAssertTrue(state.bankTransactions.isEmpty)
        XCTAssertTrue(state.purchases.isEmpty); XCTAssertTrue(state.planning.commitments.isEmpty)
        XCTAssertEqual(state.externalAccount(id: account.id)?.balance, 2000)
        XCTAssertEqual(state.monthlyFinancialSummary(for: now, calendar: calendar).remainingToLive, budget)
    }
    func testChangedOrDuplicatedGoalsCannotBeSavedAndDeletingGoalRemovesItsAllocation() throws {
        let state = try setup()
        var draft = state.allocationDraft(on: now, calendar: calendar); draft.capacity = 100; draft.entries[0].amount = 100
        try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) }
        var duplicate = draft; duplicate.entries[1] = duplicate.entries[0]
        XCTAssertThrowsError(try state.planningWrite { try $0.saveAllocationPlan(duplicate, now: now, calendar: calendar) })
        let goal = try XCTUnwrap(state.goals.first { $0.id == draft.entries[0].goalID })
        goal.isArchived = true; try state.dataStore.container.mainContext.save(); state.reload()
        XCTAssertThrowsError(try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) })
        XCTAssertEqual(state.allocationDraft(on: now, calendar: calendar).allocated, 0)
        try state.deleteGoal(goal)
        XCTAssertFalse(state.planning.allocations.contains { $0.goalID == goal.id })
    }
    func testProvisionPaidPortionIsNotFundedAgainAndCompletedGoalsAreExcluded() throws {
        let state = try TestFixtures.makeAppState(seeded: false), id = UUID()
        let account = TestFixtures.linkedAccount(balance: 1000)
        try state.dataStore.saveExternalAccounts([account])
        try state.planningWrite { try $0.saveProvision(id: id, title: "Insurance", target: 600, dueDate: TestFixtures.date(2027, 3, 14), renewal: "yearly", category: "other", now: now) }
        try state.dataStore.reserveForGoal(id: id, amount: 200, date: TestFixtures.date(2026, 8, 1))
        let tx = TestFixtures.transaction(account: account, reference: "insurance", amount: 100, direction: .debit, dayOffset: 0)
        try state.dataStore.importBankTransactions([tx]); state.reload()
        try state.planningWrite { try $0.applyProvisionPayment(goalID: id, transactionID: tx.id, now: now, calendar: calendar) }
        XCTAssertEqual(state.allocationTargets(on: now, calendar: calendar).first?.remaining, 400)
        var draft = state.allocationDraft(on: now, calendar: calendar); draft.capacity = 500; draft.entries[0].amount = 500
        XCTAssertThrowsError(try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) })
        try state.dataStore.reserveForGoal(id: id, amount: 400, date: now); state.reload()
        XCTAssertTrue(state.allocationTargets(on: now, calendar: calendar).isEmpty)
    }
    func testPersistentProfilesKeepCapacityOrderAndAmountsWithoutCreatingContributions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuer = URL(string: "https://gateway.test")!, id = UUID()
        for (user, create, expected) in [("first", true, 1), ("first", false, 1), ("second", false, 0), ("first", false, 1)] {
            try autoreleasepool {
                let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: ProfileStoreLocation(issuer: issuer, userID: user), root: directory))
                if create {
                    store.container.mainContext.insert(Goal(id: id, title: "Trip", targetAmount: 1000, currentAmount: 100, targetDate: now, category: "other", isArchived: false))
                    try store.saveAllocationPlan(.init(capacity: 100, entries: [.init(goalID: id, amount: 90)]), now: now, calendar: calendar)
                    try store.container.mainContext.save()
                }
                let snapshot = try store.planningSnapshot()
                XCTAssertEqual(snapshot.allocationPlans.count, expected); XCTAssertEqual(snapshot.allocations.count, expected)
                if expected == 1 {
                    XCTAssertEqual(snapshot.allocationPlans.first?.capacity, 100)
                    XCTAssertEqual(snapshot.allocations.first?.amount, 90); XCTAssertEqual(snapshot.allocations.first?.priority, 0)
                }
                XCTAssertTrue(try store.goalContributions().isEmpty)
            }
        }
    }
    func testInvalidatedProfileCannotSaveAPlan() throws {
        let state = try setup(), draft = state.allocationDraft(on: now, calendar: calendar)
        state.invalidateProfile()
        XCTAssertThrowsError(try state.planningWrite { try $0.saveAllocationPlan(draft, now: now, calendar: calendar) })
    }
}
