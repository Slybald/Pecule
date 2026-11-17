import Foundation

// Everything the on-device model is allowed to see: aggregates only, never a merchant, label, IBAN or account name.
struct AIAdvisorContext: Equatable {
    struct CategoryShare: Equatable {
        let name: String
        let amount: Decimal
    }

    let activeSubscriptions: Int
    let monthlySubscriptionCost: Decimal
    let purchaseCount: Int
    let totalPurchaseAmount: Decimal
    let activeGoals: Int
    let goalProgress: Double
    let activeHabits: Int
    let estimatedIncome: Decimal
    let fixedCharges: Decimal
    let variableExpenses: Decimal
    let remainingToLive: Decimal
    let dailyAllowance: Decimal
    let remainingDays: Int
    let savingsRate: Double?
    let topCategories: [CategoryShare]
    let expectedClosingBalance: Decimal?
    let healthGrade: String?
    let weakestLever: String?
    let untrackedChargeCount: Int
    let usesBankData: Bool
}

struct AIAdvisorPromptBuilder {
    static let maximumCategories = 3

    func instructions(responseLanguage: String) -> String {
        """
        You are a friendly, encouraging, and expert financial advisor within the Pecule app.
        Your goal is to provide a single, highly personalized piece of advice based on the user's current data.
        You only receive aggregated figures: never invent, guess or mention merchant names, account names or identifiers.
        Keep it concise, actionable, and positive. Never use markdown formatting.
        Respond in \(responseLanguage).
        """
    }

    func prompt(for context: AIAdvisorContext) -> String {
        var lines: [String] = [
            "Analyze the following aggregated user data and provide a quick insight:",
            "- Active subscriptions: \(context.activeSubscriptions) (\(currency(context.monthlySubscriptionCost))/month)",
            "- Logged purchases: \(context.purchaseCount) (\(currency(context.totalPurchaseAmount)) total)",
            "- Active goals: \(context.activeGoals) (overall progress \(Formatters.percentString(for: context.goalProgress)))",
            "- Active habits: \(context.activeHabits)",
            "- This month: income \(currency(context.estimatedIncome)), fixed charges \(currency(context.fixedCharges)), variable spending \(currency(context.variableExpenses))",
            "- Left to live on: \(currency(context.remainingToLive)), that is \(currency(context.dailyAllowance)) per day over \(context.remainingDays) remaining days",
            "- Amounts come from \(context.usesBankData ? "real bank statements" : "planned entries")",
        ]
        if let savingsRate = context.savingsRate {
            lines.append("- Savings rate: \(Formatters.percentString(for: savingsRate))")
        }
        if !context.topCategories.isEmpty {
            let shares = context.topCategories.prefix(Self.maximumCategories).map { "\($0.name) \(currency($0.amount))" }
            lines.append("- Biggest spending categories: \(shares.joined(separator: ", "))")
        }
        if let expected = context.expectedClosingBalance {
            lines.append("- Expected balance at month end: \(currency(expected))")
        }
        if let grade = context.healthGrade {
            lines.append("- Financial health grade: \(grade)" + (context.weakestLever.map { " (weakest area: \($0))" } ?? ""))
        }
        if context.untrackedChargeCount > 0 {
            lines.append("- Recurring charges without a recorded subscription: \(context.untrackedChargeCount)")
        }
        lines.append("")
        lines.append("Provide a catchy title, a 2-sentence advice, and a matching emoji.")
        return lines.joined(separator: "\n")
    }

    private func currency(_ value: Decimal) -> String {
        Formatters.currencyString(for: value)
    }
}

extension AppState {
    func aiAdvisorContext(on date: Date = Date(), calendar: Calendar = .current, locale: Locale = LocalizationManager.currentAppLocale) -> AIAdvisorContext {
        let summary = monthlyFinancialSummary(for: date, calendar: calendar)
        let metrics = DecisionMetricsService().metrics(from: summary, on: date, calendar: calendar)
        let health = financialHealthScore(on: date, calendar: calendar)
        let categories = summary.categorySummaries
            .sorted { $0.totalSpent > $1.totalSpent }
            .prefix(AIAdvisorPromptBuilder.maximumCategories)
            .map { AIAdvisorContext.CategoryShare(name: ExpenseCategory.canonicalCategory(for: $0.category).displayName(locale: locale), amount: $0.totalSpent) }

        return AIAdvisorContext(
            activeSubscriptions: activeSubscriptionsCount,
            monthlySubscriptionCost: monthlySubscriptionCost,
            purchaseCount: purchaseCount,
            totalPurchaseAmount: totalPurchaseAmount,
            activeGoals: activeGoals.count,
            goalProgress: overallGoalProgress,
            activeHabits: activeHabits.count,
            estimatedIncome: summary.totalEstimatedIncome,
            fixedCharges: summary.fixedCharges,
            variableExpenses: summary.variableExpenses,
            remainingToLive: summary.remainingToLive,
            dailyAllowance: metrics.dailyAllowance,
            remainingDays: metrics.remainingDays,
            savingsRate: metrics.savingsRate,
            topCategories: Array(categories),
            expectedClosingBalance: cashflowForecast(on: date, calendar: calendar)?.expectedClosingBalance,
            healthGrade: health.grade?.rawValue,
            weakestLever: health.weakestComponent.map { AppLocalizer.string("health.component.\($0.kind.rawValue)", locale: locale) },
            untrackedChargeCount: untrackedRecurringCharges.count,
            usesBankData: summary.dataSource == .bank
        )
    }
}
