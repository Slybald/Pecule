import Foundation

struct AppDataSnapshot {
    let subscriptions: [Subscription]
    let purchases: [Purchase]
    let goals: [Goal]
    let habits: [Habit]
    let incomeSources: [IncomeSource]
    let monthlyIncomeOverrides: [MonthlyIncomeOverride]
    let budgetRules: [BudgetRule]
    let budgetOverrides: [BudgetOverride]
    let externalAccounts: [ExternalAccount]
    let bankTransactions: [BankTransaction]

    init(
        subscriptions: [Subscription],
        purchases: [Purchase],
        goals: [Goal],
        habits: [Habit],
        incomeSources: [IncomeSource] = [],
        monthlyIncomeOverrides: [MonthlyIncomeOverride] = [],
        budgetRules: [BudgetRule] = [],
        budgetOverrides: [BudgetOverride] = [],
        externalAccounts: [ExternalAccount] = [],
        bankTransactions: [BankTransaction] = []
    ) {
        self.subscriptions = subscriptions
        self.purchases = purchases
        self.goals = goals
        self.habits = habits
        self.incomeSources = incomeSources
        self.monthlyIncomeOverrides = monthlyIncomeOverrides
        self.budgetRules = budgetRules
        self.budgetOverrides = budgetOverrides
        self.externalAccounts = externalAccounts
        self.bankTransactions = bankTransactions
    }

    var budgetCategories: [String] {
        BudgetRule.defaultCategories
    }

    func budgetRule(for category: String) -> BudgetRule? {
        let categoryKey = BudgetRule.categoryKey(for: category)
        return budgetRules.first { BudgetRule.categoryKey(for: $0.category) == categoryKey }
    }

    func budgetOverride(
        for category: String,
        in monthDate: Date,
        calendar: Calendar = .current
    ) -> BudgetOverride? {
        let monthComponents = monthComponents(from: monthDate, calendar: calendar)
        let categoryKey = BudgetRule.categoryKey(for: category)

        return budgetOverrides.first { budgetOverride in
            BudgetRule.categoryKey(for: budgetOverride.category) == categoryKey &&
            budgetOverride.matches(year: monthComponents.year, month: monthComponents.month)
        }
    }

    func budgetAmount(
        for category: String,
        in monthDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        if let budgetOverride = budgetOverride(for: category, in: monthDate, calendar: calendar) {
            return budgetOverride.monthlyAmount.currencyRounded
        }

        return budgetRule(for: category)?.monthlyAmount.currencyRounded ?? .zero
    }

    func monthlyBudget(
        for monthDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        budgetCategories.reduce(.zero) { partialResult, category in
            partialResult + budgetAmount(for: category, in: monthDate, calendar: calendar)
        }
        .currencyRounded
    }
}

private extension AppDataSnapshot {
    func monthComponents(
        from date: Date,
        calendar: Calendar
    ) -> (year: Int, month: Int) {
        let components = calendar.dateComponents([.year, .month], from: date)
        return (components.year ?? 0, components.month ?? 1)
    }
}
