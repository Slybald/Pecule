import Foundation

// "What if I put X aside each month?" answered without touching the goal itself.
struct GoalSimulation: Equatable {
    let monthlyContribution: Decimal
    let monthsToReach: Int?
    let completionDate: Date?
    let monthlyNeededForTargetDate: Decimal?
    // Positive when the simulated pace lands after the target date.
    let slipMonths: Int?
}

struct GoalSimulator {
    static let suggestedShareOfRemaining = 0.2

    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func monthsToReach(target: Decimal, current: Decimal, monthlyContribution: Decimal) -> Int? {
        let remaining = target - current
        guard remaining > .zero else {
            return 0
        }
        guard monthlyContribution > .zero else {
            return nil
        }
        var months = remaining / monthlyContribution
        var rounded = Decimal()
        NSDecimalRound(&rounded, &months, 0, .up)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    func monthlyNeeded(target: Decimal, current: Decimal, targetDate: Date, now: Date) -> Decimal? {
        let remaining = target - current
        guard remaining > .zero else {
            return .zero
        }
        let months = max(calendar.dateComponents([.month], from: calendar.startOfDay(for: now), to: targetDate).month ?? 0, 1)
        return (remaining / Decimal(months)).currencyRounded
    }

    func simulate(target: Decimal, current: Decimal, targetDate: Date?, monthlyContribution: Decimal, now: Date) -> GoalSimulation {
        let months = monthsToReach(target: target, current: current, monthlyContribution: monthlyContribution)
        let completion = months.flatMap { calendar.date(byAdding: .month, value: $0, to: now) }
        let needed = targetDate.flatMap { monthlyNeeded(target: target, current: current, targetDate: $0, now: now) }
        let slip = targetDate.flatMap { deadline in completion.map { max(calendar.dateComponents([.month], from: deadline, to: $0).month ?? 0, 0) } }
        return GoalSimulation(
            monthlyContribution: monthlyContribution,
            monthsToReach: months,
            completionDate: completion,
            monthlyNeededForTargetDate: needed,
            slipMonths: slip
        )
    }

    // A fifth of what is left this month is a realistic default effort.
    func suggestedContribution(remainingToLive: Decimal) -> Decimal {
        max((remainingToLive * Decimal(Self.suggestedShareOfRemaining)).currencyRounded, .zero)
    }
}
