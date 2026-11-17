import Foundation

@MainActor
struct RecommendationService {
    private let financialCalculator: FinancialCalculatorService
    private let subscriptionAnalyzer: SubscriptionAnalyzerService
    private let calendar: Calendar
    private let referenceDateProvider: () -> Date

    init(
        financialCalculator: FinancialCalculatorService = FinancialCalculatorService(),
        subscriptionAnalyzer: SubscriptionAnalyzerService = SubscriptionAnalyzerService(),
        calendar: Calendar = .current,
        referenceDateProvider: @escaping () -> Date = Date.init
    ) {
        self.financialCalculator = financialCalculator
        self.subscriptionAnalyzer = subscriptionAnalyzer
        self.calendar = calendar
        self.referenceDateProvider = referenceDateProvider
    }

    func generateRecommendations(from appState: AppState) -> [RecommendationItem] {
        let hasAnyData =
            !appState.subscriptions.isEmpty ||
            !appState.purchases.isEmpty ||
            !appState.goals.isEmpty ||
            !appState.habits.isEmpty

        guard hasAnyData else {
            return []
        }

        var recommendations: [(item: RecommendationItem, order: Int)] = []
        var duplicateSubscriptionIDs: Set<UUID> = []

        if let duplicateRec = duplicateSubscriptionRecommendation(from: appState, trackedIDs: &duplicateSubscriptionIDs) {
            recommendations.append((duplicateRec, 0))
        }

        if let expensiveRec = expensiveSubscriptionRecommendation(from: appState, excludingIDs: duplicateSubscriptionIDs) {
            recommendations.append((expensiveRec, 1))
        }

        let closeGoalRec = closeGoalRecommendation(from: appState)

        if let closeGoalRec {
            recommendations.append((closeGoalRec, 2))
        } else if let weakGoalRec = weakGoalRecommendation(from: appState) {
            recommendations.append((weakGoalRec, 3))
        }

        if let habitRec = linkedHabitRecommendation(from: appState) {
            recommendations.append((habitRec, 4))
        }

        if let purchaseRec = expensiveRecentPurchaseRecommendation(from: appState) {
            recommendations.append((purchaseRec, 5))
        }

        if recommendations.isEmpty {
            if let positiveRec = positiveRecommendation(from: appState) {
                recommendations.append((positiveRec, 6))
            }
        }

        let sorted = recommendations.sorted { left, right in
            if left.item.priority != right.item.priority {
                return left.item.priority < right.item.priority
            }

            return left.order < right.order
        }

        return Array(sorted.prefix(5).map(\.item))
    }
}

private extension RecommendationService {

    func duplicateSubscriptionRecommendation(
        from appState: AppState,
        trackedIDs: inout Set<UUID>
    ) -> RecommendationItem? {
        guard let firstGroup = appState.duplicateSubscriptionGroups.first,
              !firstGroup.isEmpty else {
            return nil
        }

        for sub in firstGroup {
            trackedIDs.insert(sub.id)
        }

        let lowestMonthlyCost = firstGroup
            .map { financialCalculator.costPerMonth($0) }
            .min() ?? .zero

        let impactValue = Formatters.currencyString(for: lowestMonthlyCost)
        let groupName = firstGroup.first?.name ?? AppLocalizer.string("subscription")

        return RecommendationItem(
            title: AppLocalizer.string("Duplicate Subscriptions"),
            message: AppLocalizer.format("You have multiple \"%@\" subscriptions. Consider reviewing the overlap and removing one.", groupName),
            type: .subscription,
            priority: .high,
            relatedEntityID: firstGroup.first?.id,
            relatedEntityType: .subscription,
            estimatedImpact: impactValue
        )
    }

    func expensiveSubscriptionRecommendation(
        from appState: AppState,
        excludingIDs: Set<UUID>
    ) -> RecommendationItem? {
        guard let subscription = appState.expensiveSubscriptions
            .first(where: { !excludingIDs.contains($0.id) }) else {
            return nil
        }

        let annualCost = financialCalculator.costPerYear(subscription)
        let impactValue = Formatters.currencyString(for: annualCost)

        return RecommendationItem(
            title: AppLocalizer.string("Expensive Subscription"),
            message: AppLocalizer.format("\"%@\" is a high-cost subscription. Consider reviewing or suspending it.", subscription.name),
            type: .subscription,
            priority: .high,
            relatedEntityID: subscription.id,
            relatedEntityType: .subscription,
            estimatedImpact: impactValue
        )
    }

    func closeGoalRecommendation(from appState: AppState) -> RecommendationItem? {
        guard let goal = appState.activeGoals
            .filter({ $0.progress >= 0.85 && $0.progress < 1 })
            .sorted(by: { left, right in
                if left.progress != right.progress {
                    return left.progress > right.progress
                }

                if left.targetDate != right.targetDate {
                    return left.targetDate < right.targetDate
                }

                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            })
            .first else {
            return nil
        }

        let remaining = goal.targetAmount - goal.currentAmount
        let impactValue = Formatters.currencyString(for: max(remaining, .zero))

        return RecommendationItem(
            title: AppLocalizer.string("Goal Nearly Complete"),
            message: AppLocalizer.format("Your goal \"%@\" is close to being reached. Focus your next effort here to finish it.", goal.title),
            type: .goal,
            priority: .medium,
            relatedEntityID: goal.id,
            relatedEntityType: .goal,
            estimatedImpact: impactValue
        )
    }

    func weakGoalRecommendation(from appState: AppState) -> RecommendationItem? {
        let referenceDate = referenceDateProvider()

        // Only a goal that genuinely carries a deadline can be "behind schedule": a purchase or a
        // reserve has none, and a duration goal counts from its start, not from a leftover column.
        let candidates = appState.activeGoals.compactMap { goal -> (goal: Goal, deadline: Date)? in
            guard !goal.isArchived, goal.progress <= 0.35,
                  let deadline = goal.deadline(calendar: calendar), deadline > referenceDate else {
                return nil
            }
            return (goal, deadline)
        }

        guard let entry = candidates
            .sorted(by: { left, right in
                if left.deadline != right.deadline {
                    return left.deadline < right.deadline
                }

                if left.goal.progress != right.goal.progress {
                    return left.goal.progress < right.goal.progress
                }

                return left.goal.title.localizedCaseInsensitiveCompare(right.goal.title) == .orderedAscending
            })
            .first else {
            return nil
        }
        let goal = entry.goal

        let remainingAmount = max(goal.targetAmount - goal.currentAmount, .zero)
        let referenceMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? referenceDate
        let targetMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: entry.deadline)) ?? entry.deadline
        let monthsUntilTarget = max(
            calendar.dateComponents([.month], from: referenceMonthStart, to: targetMonthStart).month ?? 1,
            1
        )

        let rawContribution = NSDecimalNumber(decimal: remainingAmount).doubleValue / Double(monthsUntilTarget)
        let roundedContribution = ceil(rawContribution / 5.0) * 5.0
        let suggestedAmount = Decimal(roundedContribution)
        let impactValue = Formatters.currencyString(for: suggestedAmount)

        return RecommendationItem(
            title: AppLocalizer.string("Goal Behind Schedule"),
            message: AppLocalizer.format("Your goal \"%@\" is progressing slowly. Consider contributing about %@/month to stay on track.", goal.title, impactValue),
            type: .goal,
            priority: .medium,
            relatedEntityID: goal.id,
            relatedEntityType: .goal,
            estimatedImpact: impactValue
        )
    }

    func linkedHabitRecommendation(from appState: AppState) -> RecommendationItem? {
        guard let habit = appState.activeHabits
            .filter({ $0.linkedGoalID != nil && $0.progress < 0.75 })
            .sorted(by: { left, right in
                if left.progress != right.progress {
                    return left.progress < right.progress
                }

                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            })
            .first else {
            return nil
        }

        let remaining = habit.targetCount - habit.completedCount
        let goalTitle = appState.goalTitle(for: habit.linkedGoalID) ?? AppLocalizer.string("your linked goal")

        return RecommendationItem(
            title: AppLocalizer.string("Habit Needs Attention"),
            message: AppLocalizer.format(
                "\"%@\" is at %lld/%lld completions. Complete the remaining %lld to better support \"%@\".",
                habit.title,
                Int64(habit.completedCount),
                Int64(habit.targetCount),
                Int64(remaining),
                goalTitle
            ),
            type: .habit,
            priority: .medium,
            relatedEntityID: habit.id,
            relatedEntityType: .habit,
            estimatedImpact: AppLocalizer.format("%lld remaining", Int64(remaining))
        )
    }

    func expensiveRecentPurchaseRecommendation(from appState: AppState) -> RecommendationItem? {
        let referenceDate = referenceDateProvider()
        let lowerBound = calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate

        let candidates = appState.recentPurchases
            .filter { purchase in
                purchase.date >= lowerBound &&
                purchase.date <= referenceDate &&
                financialCalculator.costOverTime(purchase, months: 12) >= Decimal(1000)
            }

        guard let purchase = candidates
            .sorted(by: { left, right in
                let leftCost = financialCalculator.costOverTime(left, months: 12)
                let rightCost = financialCalculator.costOverTime(right, months: 12)

                if leftCost != rightCost {
                    return leftCost > rightCost
                }

                return left.date > right.date
            })
            .first else {
            return nil
        }

        let projectedCost = financialCalculator.costOverTime(purchase, months: 12)
        let impactValue = Formatters.currencyString(for: projectedCost)

        return RecommendationItem(
            title: AppLocalizer.string("High-Cost Purchase"),
            message: AppLocalizer.format("\"%@\" has a projected 12-month cost of %@. Compare your actual need over a longer usage horizon.", purchase.title, impactValue),
            type: .purchase,
            priority: .low,
            relatedEntityID: purchase.id,
            relatedEntityType: .purchase,
            estimatedImpact: impactValue
        )
    }

    func positiveRecommendation(from appState: AppState) -> RecommendationItem? {
        let hasStrongGoal = appState.activeGoals.contains { $0.progress >= 0.60 }
        let hasStrongHabits = !appState.activeHabits.isEmpty && appState.activeHabits.allSatisfy { $0.progress >= 0.75 }
        let hasLeanSubscriptions = appState.activeSubscriptionsCount > 0 &&
            appState.activeSubscriptionsCount <= 3 &&
            appState.monthlySubscriptionCost < Decimal(20)

        guard hasStrongGoal || hasStrongHabits || hasLeanSubscriptions else {
            return nil
        }

        return RecommendationItem(
            title: AppLocalizer.string("Looking Good"),
            message: AppLocalizer.string("No urgent financial changes stand out right now. Keep up the good work!"),
            type: .positive,
            priority: .low
        )
    }
}
