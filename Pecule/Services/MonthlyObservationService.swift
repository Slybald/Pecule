import Foundation

// One month of bank evidence: what came in, what went out, how the variable spending was spread over the days.
struct ObservedMonth: Equatable, Identifiable {
    let month: DateInterval
    let income: Decimal
    let fixedCharges: Decimal
    let variableExpenses: Decimal
    let byCategory: [ExpenseCategory: Decimal]
    let dailyVariableMedian: Decimal
    let transactionCount: Int
    // Fully elapsed and backed by at least one transaction: safe to use as a baseline.
    let isComplete: Bool

    var id: Date { month.start }

    var totalExpenses: Decimal {
        (fixedCharges + variableExpenses).currencyRounded
    }

    var remaining: Decimal {
        (income - totalExpenses).currencyRounded
    }

    var savingsRate: Double? {
        guard income > .zero else {
            return nil
        }
        return NSDecimalNumber(decimal: remaining).doubleValue / NSDecimalNumber(decimal: income).doubleValue
    }
}

struct CategoryTrend: Equatable, Identifiable {
    let category: ExpenseCategory
    let recentMonthlyAverage: Decimal
    let baselineMonthlyAverage: Decimal

    var id: String { category.rawValue }

    // 1.0 means "same as before"; 1.3 means 30 % more per month lately.
    var ratio: Double {
        NSDecimalNumber(decimal: recentMonthlyAverage).doubleValue / NSDecimalNumber(decimal: baselineMonthlyAverage).doubleValue
    }
}

struct MonthlyObservationService {
    // Debits in these categories are treated as fixed charges even when no subscription is linked.
    static let fixedCategories: Set<ExpenseCategory> = [.subscriptions, .insurance, .housing]

    let calendar: Calendar
    let referenceDateProvider: @Sendable () -> Date
    let monthCount: Int

    init(calendar: Calendar = .current, referenceDateProvider: @escaping @Sendable () -> Date = Date.init, monthCount: Int = 12) {
        self.calendar = calendar
        self.referenceDateProvider = referenceDateProvider
        self.monthCount = monthCount
    }

    // Oldest month first, the current (partial) month last. Only booked EUR rows of included accounts count.
    func observe(transactions: [BankTransaction], includedAccountIDs: Set<UUID>) -> [ObservedMonth] {
        let referenceDate = referenceDateProvider()
        guard let currentMonth = calendar.dateInterval(of: .month, for: referenceDate) else {
            return []
        }
        let intervals: [DateInterval] = (0 ..< max(monthCount, 1)).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonth.start) else {
                return nil
            }
            return calendar.dateInterval(of: .month, for: start)
        }
        guard let earliest = intervals.first?.start else {
            return []
        }

        var buckets: [Date: [BankTransaction]] = [:]
        for transaction in transactions
        where transaction.countsInTotals
            && includedAccountIDs.contains(transaction.accountID)
            && transaction.bookingDate >= earliest
            && transaction.bookingDate < currentMonth.end {
            if let start = calendar.dateInterval(of: .month, for: transaction.bookingDate)?.start {
                buckets[start, default: []].append(transaction)
            }
        }

        return intervals.map { interval in
            observe(interval: interval, transactions: buckets[interval.start] ?? [], referenceDate: referenceDate)
        }
    }

    // Average of the last `recent` complete months against the `baseline` complete months before them.
    func categoryTrends(in months: [ObservedMonth], recent: Int = 3, baseline: Int = 6) -> [CategoryTrend] {
        let complete = months.filter(\.isComplete)
        guard complete.count >= recent + 1, recent > 0 else {
            return []
        }
        let recentMonths = complete.suffix(recent)
        let baselineMonths = complete.dropLast(recent).suffix(baseline)
        guard !baselineMonths.isEmpty else {
            return []
        }

        return ExpenseCategory.allCases.compactMap { category in
            let recentAverage = average(recentMonths.map { $0.byCategory[category] ?? .zero })
            let baselineAverage = average(baselineMonths.map { $0.byCategory[category] ?? .zero })
            guard baselineAverage > .zero else {
                return nil
            }
            return CategoryTrend(category: category, recentMonthlyAverage: recentAverage, baselineMonthlyAverage: baselineAverage)
        }
        .sorted { abs($0.ratio - 1) > abs($1.ratio - 1) }
    }

    func median(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else {
            return .zero
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return ((sorted[middle - 1] + sorted[middle]) / 2).currencyRounded
        }
        return sorted[middle].currencyRounded
    }

    private func observe(interval: DateInterval, transactions: [BankTransaction], referenceDate: Date) -> ObservedMonth {
        var income: Decimal = .zero
        var fixed: Decimal = .zero
        var variable: Decimal = .zero
        var byCategory: [ExpenseCategory: Decimal] = [:]
        var dailyVariable: [Date: Decimal] = [:]

        for transaction in transactions {
            if transaction.isIncome {
                income += transaction.amount
            } else {
                let category = ExpenseCategory.canonicalCategory(for: transaction.category)
                byCategory[category, default: .zero] += transaction.netExpenseAmount
                if transaction.linkedSubscriptionID != nil || Self.fixedCategories.contains(category) {
                    fixed += transaction.netExpenseAmount
                } else {
                    variable += transaction.netExpenseAmount
                    dailyVariable[calendar.startOfDay(for: transaction.bookingDate), default: .zero] += transaction.netExpenseAmount
                }
            }
        }

        // Days with no spending count as zero so the median reflects a typical day, not a typical purchase.
        let lastObservedDay = min(interval.end, referenceDate)
        let dayCount = max(calendar.dateComponents([.day], from: interval.start, to: lastObservedDay).day ?? 0, dailyVariable.isEmpty ? 0 : 1)
        let dailyValues = (0 ..< dayCount).map { offset -> Decimal in
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else {
                return .zero
            }
            return dailyVariable[calendar.startOfDay(for: day)] ?? .zero
        }

        return ObservedMonth(
            month: interval,
            income: income.currencyRounded,
            fixedCharges: fixed.currencyRounded,
            variableExpenses: variable.currencyRounded,
            byCategory: byCategory.mapValues(\.currencyRounded),
            dailyVariableMedian: median(dailyValues),
            transactionCount: transactions.count,
            isComplete: interval.end <= referenceDate && !transactions.isEmpty
        )
    }

    private func average(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else {
            return .zero
        }
        return (values.reduce(.zero, +) / Decimal(values.count)).currencyRounded
    }
}
