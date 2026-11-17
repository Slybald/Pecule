import XCTest
@testable import Pecule

final class GoalSimulatorTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let now = TestFixtures.referenceDate // 2026-09-14

    func testMonthsRoundUpAndZeroOrNegativeContributionsNeverReach() {
        let simulator = GoalSimulator(calendar: calendar)

        XCTAssertEqual(simulator.monthsToReach(target: 1000, current: 100, monthlyContribution: 300), 3, "900 / 300")
        XCTAssertEqual(simulator.monthsToReach(target: 1000, current: 100, monthlyContribution: 250), 4, "3.6 months rounds up")
        XCTAssertEqual(simulator.monthsToReach(target: 1000, current: 1000, monthlyContribution: 0), 0)
        XCTAssertNil(simulator.monthsToReach(target: 1000, current: 100, monthlyContribution: 0))
    }

    func testSimulationReportsCompletionSlipAndNeededEffort() throws {
        let simulator = GoalSimulator(calendar: calendar)
        let targetDate = TestFixtures.date(2026, 12, 14, hour: 0)

        let simulation = simulator.simulate(target: 1000, current: 100, targetDate: targetDate, monthlyContribution: 150, now: now)

        XCTAssertEqual(simulation.monthsToReach, 6)
        XCTAssertEqual(simulation.completionDate, calendar.date(byAdding: .month, value: 6, to: now))
        XCTAssertEqual(simulation.monthlyNeededForTargetDate, 300, "900 over the 3 months left")
        XCTAssertEqual(simulation.slipMonths, 3, "six months of effort against a three-month horizon")

        let onTime = simulator.simulate(target: 1000, current: 100, targetDate: targetDate, monthlyContribution: 300, now: now)
        XCTAssertEqual(onTime.slipMonths, 0)
        XCTAssertEqual(simulator.suggestedContribution(remainingToLive: 800), 160)
        XCTAssertEqual(simulator.suggestedContribution(remainingToLive: -50), 0)
    }
}
