import XCTest
@testable import Pecule

// Ce que le mois « réserve » se soustrait du reste à vivre. Deux bords de mois le faussaient, et
// aucun test ne les couvrait : l'argent rendu restait invisible, et une réservation datée du 1er
// à minuit était comptée deux fois, dans le mois qui finit comme dans celui qui commence.
@MainActor
final class GoalReservationMonthEdgeTests: XCTestCase {
    private let service = GoalFundingService()
    private var calendar: Calendar { TestFixtures.utcCalendar() }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMoneyReleasedTheFollowingMonthComesBackToThatMonth() {
        let goal = UUID()
        let contributions = [
            GoalContribution(goalID: goal, date: date(2026, 9, 10), amount: 200),
            GoalContribution(goalID: goal, date: date(2026, 10, 5), amount: -200),
        ]

        XCTAssertEqual(service.reserved(for: date(2026, 9, 15), contributions: contributions, calendar: calendar), 200)
        XCTAssertEqual(
            service.reserved(for: date(2026, 10, 15), contributions: contributions, calendar: calendar),
            -200,
            "la somme libérée revient au reste à vivre du mois où elle est rendue"
        )
    }

    // Le garde-fou reste : on ne peut pas libérer ce qui n'a jamais été mis de côté.
    func testAReleaseWithoutAPriorReservationGivesNothingBack() {
        let contributions = [GoalContribution(goalID: UUID(), date: date(2026, 10, 5), amount: -150)]
        XCTAssertEqual(service.reserved(for: date(2026, 10, 15), contributions: contributions, calendar: calendar), 0)
    }

    func testAReleaseCannotGiveBackMoreThanWasReservedBefore() {
        let goal = UUID()
        let contributions = [
            GoalContribution(goalID: goal, date: date(2026, 9, 10), amount: 80),
            GoalContribution(goalID: goal, date: date(2026, 10, 5), amount: -300),
        ]
        XCTAssertEqual(service.reserved(for: date(2026, 10, 15), contributions: contributions, calendar: calendar), -80)
    }

    // `DateInterval.contains` est fermé aux deux bouts : minuit le 1er tombait dans les deux mois.
    func testAReservationDatedAtMidnightOnTheFirstBelongsToItsMonthOnly() {
        let goal = UUID()
        let midnight = date(2026, 10, 1, hour: 0)
        let contributions = [GoalContribution(goalID: goal, date: midnight, amount: 120)]

        XCTAssertEqual(
            service.reserved(for: date(2026, 9, 15), contributions: contributions, calendar: calendar),
            0,
            "le mois qui se termine ne compte pas la réservation du 1er suivant"
        )
        XCTAssertEqual(service.reserved(for: date(2026, 10, 15), contributions: contributions, calendar: calendar), 120)
    }

    func testSeveralGoalsInTheSameMonthAreSummedIndependently() {
        let first = UUID(), second = UUID()
        let contributions = [
            GoalContribution(goalID: first, date: date(2026, 9, 3), amount: 100),
            GoalContribution(goalID: second, date: date(2026, 9, 4), amount: 50),
            GoalContribution(goalID: second, date: date(2026, 9, 20), amount: -20),
        ]
        XCTAssertEqual(service.reserved(for: date(2026, 9, 15), contributions: contributions, calendar: calendar), 130)
    }
}
