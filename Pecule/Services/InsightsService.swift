import Foundation

@MainActor
struct InsightsService {
    private let financialCalculator: FinancialCalculatorService
    private let calendar: Calendar
    private let referenceDateProvider: () -> Date

    init(
        financialCalculator: FinancialCalculatorService = FinancialCalculatorService(),
        calendar: Calendar = .current,
        referenceDateProvider: @escaping () -> Date = Date.init
    ) {
        self.financialCalculator = financialCalculator
        self.calendar = calendar
        self.referenceDateProvider = referenceDateProvider
    }

    func generateInsights(from appState: AppState) -> [InsightItem] {
        var insights: [InsightItem] = []
        var hasWarning = false
        var hasSubscriptionSpendingInsight = false

        // Money decisions come first: they depend on real bank amounts once accounts are linked.
        let financialInsights = financialInsights(from: appState)
        insights.append(contentsOf: financialInsights)
        if financialInsights.contains(where: { $0.type == .warning }) {
            hasWarning = true
        }

        if let untracked = appState.untrackedRecurringCharges.first {
            let value = Formatters.currencyString(for: untracked.latestAmount)
            insights.append(InsightItem(
                title: AppLocalizer.string("insights.untrackedCharge.title"),
                message: AppLocalizer.format("insights.untrackedCharge.message %@ %@", untracked.label, value),
                type: .warning,
                optionalValue: value,
                route: .subscription(nil)
            ))
            hasWarning = true
        }

        if let increased = appState.recurringChargesWithPriceIncrease.first, let increase = increased.priceIncrease {
            let value = Formatters.currencyString(for: increase)
            insights.append(InsightItem(
                title: AppLocalizer.string("insights.priceIncrease.title"),
                message: AppLocalizer.format(
                    "insights.priceIncrease.message %@ %@ %@",
                    increased.label,
                    Formatters.currencyString(for: increased.previousAmount),
                    Formatters.currencyString(for: increased.latestAmount)
                ),
                type: .warning,
                optionalValue: value,
                route: .subscription(nil)
            ))
            hasWarning = true
        }

        if let highSubscriptionInsight = highSubscriptionSpendingInsight(from: appState) {
            insights.append(highSubscriptionInsight)
            hasWarning = true
            hasSubscriptionSpendingInsight = true
        }

        if let recentPurchaseInsight = recentPurchaseInsight(from: appState) {
            insights.append(recentPurchaseInsight)
            hasWarning = true
        }

        if let goalInsight = goalInsight(from: appState) {
            insights.append(goalInsight)

            if goalInsight.type == .warning {
                hasWarning = true
            }
        }

        if let lowHabitInsight = lowHabitInsight(from: appState) {
            insights.append(lowHabitInsight)
            hasWarning = true
        }

        if !hasSubscriptionSpendingInsight,
           let subscriptionSpendingSummary = subscriptionSpendingSummary(from: appState) {
            insights.append(subscriptionSpendingSummary)
        }

        if let activeSubscriptionsSummary = activeSubscriptionsSummary(from: appState) {
            insights.append(activeSubscriptionsSummary)
        }

        if !hasWarning, let positiveSummaryInsight = positiveSummaryInsight(from: appState) {
            insights.append(positiveSummaryInsight)
        }

        return Array(insights.prefix(5))
    }
}

private extension InsightsService {
    static let paceAlertRatio = 1.2
    static let savingsRateTarget = 0.2

    func financialInsights(from appState: AppState) -> [InsightItem] {
        let referenceDate = referenceDateProvider()
        let decisionService = DecisionMetricsService()
        let summary = appState.monthlyFinancialSummary(for: referenceDate, calendar: calendar)
        // A savings rate without a single expense is vacuous; wait for real spending data.
        guard summary.totalExpenses > .zero else {
            return []
        }
        let metrics = decisionService.metrics(from: summary, on: referenceDate, calendar: calendar)
        var insights: [InsightItem] = []

        if metrics.isOverspent {
            // The balance is negative; the amount by which expenses exceed income is positive.
            let value = Formatters.currencyString(for: -metrics.remainingToLive)
            insights.append(InsightItem(
                title: AppLocalizer.string("insights.remainingToLive.negative.title"),
                message: AppLocalizer.format("insights.remainingToLive.negative.message %@", value),
                type: .warning,
                optionalValue: value,
                route: .budgets
            ))
        } else if let savingsRate = metrics.savingsRate, savingsRate >= Self.savingsRateTarget {
            let value = Formatters.percentString(for: savingsRate)
            insights.append(InsightItem(
                title: AppLocalizer.string("insights.savingsRate.title"),
                message: AppLocalizer.format("insights.savingsRate.message %@ %@", value, Formatters.currencyString(for: metrics.remainingToLive)),
                type: .positive,
                optionalValue: value,
                route: .cashflow
            ))
        }

        if let previousMonth = calendar.date(byAdding: .month, value: -1, to: referenceDate) {
            let previous = appState.monthlyFinancialSummary(for: previousMonth, calendar: calendar)
            if let ratio = decisionService.spendingPaceRatio(current: summary, previous: previous, on: referenceDate, calendar: calendar),
               ratio > Self.paceAlertRatio {
                let value = String(format: "%.1f×", locale: .current, ratio)
                insights.append(InsightItem(
                    title: AppLocalizer.string("insights.pace.title"),
                    message: AppLocalizer.format("insights.pace.message %@ %@", value, Formatters.monthYearString(for: previous.monthStart)),
                    type: .warning,
                    optionalValue: value,
                    route: .accounts
                ))
            }
        }

        return insights
    }

    func highSubscriptionSpendingInsight(from appState: AppState) -> InsightItem? {
        guard appState.monthlySubscriptionCost >= Decimal(35) else {
            return nil
        }

        let value = Formatters.currencyString(for: appState.monthlySubscriptionCost)

        return InsightItem(
            title: AppLocalizer.string("Subscription Spending"),
            message: AppLocalizer.format("You are spending %@/month on active subscriptions.", value),
            type: .warning,
            optionalValue: value,
            route: .subscription(nil)
        )
    }

    func subscriptionSpendingSummary(from appState: AppState) -> InsightItem? {
        guard appState.activeSubscriptionsCount > 0 else {
            return nil
        }

        let value = Formatters.currencyString(for: appState.monthlySubscriptionCost)

        return InsightItem(
            title: AppLocalizer.string("Subscription Spending"),
            message: AppLocalizer.format("You are spending %@/month on active subscriptions.", value),
            type: .summary,
            optionalValue: value,
            route: .subscription(nil)
        )
    }

    func activeSubscriptionsSummary(from appState: AppState) -> InsightItem? {
        guard appState.activeSubscriptionsCount > 0 else {
            return nil
        }

        return InsightItem(
            title: AppLocalizer.string("Active Subscriptions"),
            message: AppLocalizer.format("You have %lld active subscriptions.", Int64(appState.activeSubscriptionsCount)),
            type: .subscription,
            optionalValue: "\(appState.activeSubscriptionsCount)",
            route: .subscription(nil)
        )
    }

    func recentPurchaseInsight(from appState: AppState) -> InsightItem? {
        let referenceDate = referenceDateProvider()
        let lowerBound = calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate

        guard let purchase = appState.recentPurchases.first(where: { purchase in
            purchase.date >= lowerBound &&
            purchase.date <= referenceDate &&
            financialCalculator.costOverTime(purchase, months: 12) >= Decimal(1000)
        }) else {
            return nil
        }

        let projectedCost = financialCalculator.costOverTime(purchase, months: 12)
        let projectedCostValue = Formatters.currencyString(for: projectedCost)

        return InsightItem(
            title: AppLocalizer.string("Recent Purchase"),
            message: AppLocalizer.format("\"%@\" has a projected 12-month cost of %@.", purchase.title, projectedCostValue),
            type: .warning,
            optionalValue: projectedCostValue,
            route: .purchase(purchase.id)
        )
    }

    func goalInsight(from appState: AppState) -> InsightItem? {
        if let closeGoal = appState.activeGoals
            .filter({ $0.progress >= 0.85 && $0.progress < 1 })
            .sorted(by: preferredGoalOrder)
            .first {
            let progressValue = Formatters.percentString(for: closeGoal.progress)

            return InsightItem(
                title: AppLocalizer.string("Goal Progress"),
                message: AppLocalizer.format("Your goal \"%@\" is %@ complete and close to being reached.", closeGoal.title, progressValue),
                type: .positive,
                optionalValue: progressValue,
                route: .goal(closeGoal.id)
            )
        }

        if let goodGoal = appState.activeGoals
            .filter({ $0.progress >= 0.60 })
            .sorted(by: preferredGoalOrder)
            .first {
            let progressValue = Formatters.percentString(for: goodGoal.progress)

            return InsightItem(
                title: AppLocalizer.string("Goal Progress"),
                message: AppLocalizer.format("Your goal \"%@\" is %@ complete.", goodGoal.title, progressValue),
                type: .positive,
                optionalValue: progressValue,
                route: .goal(goodGoal.id)
            )
        }

        if let lowGoal = appState.activeGoals
            .filter({ $0.progress <= 0.35 })
            .sorted(by: lowProgressGoalOrder)
            .first {
            let progressValue = Formatters.percentString(for: lowGoal.progress)

            return InsightItem(
                title: AppLocalizer.string("Goal Progress"),
                message: AppLocalizer.format("Your goal \"%@\" is only %@ complete so far.", lowGoal.title, progressValue),
                type: .warning,
                optionalValue: progressValue,
                route: .goal(lowGoal.id)
            )
        }

        return nil
    }

    func lowHabitInsight(from appState: AppState) -> InsightItem? {
        guard let lowHabit = appState.activeHabits
            .filter({ $0.progress <= 0.50 })
            .sorted(by: lowHabitOrder)
            .first else {
            return nil
        }

        let completionValue = "\(lowHabit.completedCount)/\(lowHabit.targetCount)"

        return InsightItem(
            title: AppLocalizer.string("Habit Progress"),
            message: AppLocalizer.format("\"%@\" is at %@ completions.", lowHabit.title, completionValue),
            type: .warning,
            optionalValue: completionValue,
            route: .habit(lowHabit.id)
        )
    }

    func positiveSummaryInsight(from appState: AppState) -> InsightItem? {
        let hasAnyData =
            !appState.subscriptions.isEmpty ||
            !appState.purchases.isEmpty ||
            !appState.goals.isEmpty ||
            !appState.habits.isEmpty

        guard hasAnyData else {
            return nil
        }

        let hasStrongGoal = appState.activeGoals.contains { $0.progress >= 0.60 }
        let hasStrongHabits = !appState.activeHabits.isEmpty && appState.activeHabits.allSatisfy { $0.progress >= 0.75 }
        let hasLeanSubscriptions = appState.activeSubscriptionsCount > 0 &&
            appState.activeSubscriptionsCount <= 3 &&
            appState.monthlySubscriptionCost < Decimal(20)

        guard hasStrongGoal || hasStrongHabits || hasLeanSubscriptions else {
            return nil
        }

        return InsightItem(
            title: AppLocalizer.string("Positive Summary"),
            message: AppLocalizer.string("Your current entries look balanced overall."),
            type: .positive
        )
    }

    func preferredGoalOrder(_ left: Goal, _ right: Goal) -> Bool {
        if left.progress != right.progress {
            return left.progress > right.progress
        }

        if left.targetDate != right.targetDate {
            return left.targetDate < right.targetDate
        }

        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    func lowProgressGoalOrder(_ left: Goal, _ right: Goal) -> Bool {
        if left.targetDate != right.targetDate {
            return left.targetDate < right.targetDate
        }

        if left.progress != right.progress {
            return left.progress < right.progress
        }

        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    func lowHabitOrder(_ left: Habit, _ right: Habit) -> Bool {
        if left.progress != right.progress {
            return left.progress < right.progress
        }

        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }
}
