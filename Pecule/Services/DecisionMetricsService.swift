import Foundation

// The two numbers a person checks before spending: what is left this month, and what that means per day.
struct DecisionMetrics: Equatable {
    enum AllowanceState: Equatable {
        case available
        case balanced
        case deficit
    }

    let remainingToLive: Decimal
    let dailyAllowance: Decimal
    let remainingDays: Int
    let elapsedDays: Int
    // remainingToLive / estimated income; nil when nothing is expected this month.
    let savingsRate: Double?

    var isOverspent: Bool {
        remainingToLive < .zero
    }

    // Zero allowance can mean a balanced month or a deficit, not an unknown bank balance.
    var allowanceState: AllowanceState {
        if isOverspent { return .deficit }
        return remainingToLive == .zero ? .balanced : .available
    }
}

struct DecisionMetricsService {
    func metrics(
        from summary: MonthlyFinancialSummary,
        on date: Date,
        calendar: Calendar = .current
    ) -> DecisionMetrics {
        let dayStart = calendar.startOfDay(for: date)
        let remainingDays = max(calendar.dateComponents([.day], from: dayStart, to: summary.monthEnd).day ?? 1, 1)
        let elapsedDays = max((calendar.dateComponents([.day], from: calendar.startOfDay(for: summary.monthStart), to: dayStart).day ?? 0) + 1, 1)
        let remaining = summary.remainingToLive
        let dailyAllowance = (max(remaining, .zero) / Decimal(remainingDays)).currencyRounded
        let income = summary.totalEstimatedIncome
        let savingsRate = income > .zero
            ? NSDecimalNumber(decimal: remaining).doubleValue / NSDecimalNumber(decimal: income).doubleValue
            : nil

        return DecisionMetrics(
            remainingToLive: remaining,
            dailyAllowance: dailyAllowance,
            remainingDays: remainingDays,
            elapsedDays: elapsedDays,
            savingsRate: savingsRate
        )
    }

    // Daily variable spending so far this month compared with the previous month's daily average.
    // nil when the previous month has no variable spending to compare against.
    func spendingPaceRatio(
        current: MonthlyFinancialSummary,
        previous: MonthlyFinancialSummary,
        on date: Date,
        calendar: Calendar = .current
    ) -> Double? {
        guard previous.variableExpenses > .zero else {
            return nil
        }
        let elapsedDays = Double(metrics(from: current, on: date, calendar: calendar).elapsedDays)
        let previousDays = Double(max(calendar.dateComponents([.day], from: previous.monthStart, to: previous.monthEnd).day ?? 30, 1))
        let currentDaily = NSDecimalNumber(decimal: current.variableExpenses).doubleValue / elapsedDays
        let previousDaily = NSDecimalNumber(decimal: previous.variableExpenses).doubleValue / previousDays
        return currentDaily / previousDaily
    }
}

extension AppState {
    func decisionMetrics(on date: Date = Date(), calendar: Calendar = .current) -> DecisionMetrics {
        DecisionMetricsService().metrics(
            from: monthlyFinancialSummary(for: date, calendar: calendar),
            on: date,
            calendar: calendar
        )
    }
}
