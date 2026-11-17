import Foundation

extension AppState {
    func budgetOverview(for month: Date, calendar: Calendar = .current) -> [BudgetOverviewRow] {
        let summary = monthlyFinancialSummary(for: month, calendar: calendar)
        let refunds = summary.dataSource == .bank
            ? bankTransactions(in: month, calendar: calendar).filter(\.isRefund).reduce(into: [ExpenseCategory: Decimal]()) {
                $0[ExpenseCategory.canonicalCategory(for: $1.category), default: .zero] += $1.amount
            } : [:]
        // Spending is booked money, not monthly amortisation or an unpaid manual subscription. In bank mode
        // the summary holds the booked operations plus the manual purchases no operation represents, the same
        // total as Operations and the home chart; in manual mode, the plan of the month.
        let spending = summary.categorySummaries.reduce(into: [ExpenseCategory: Decimal]()) { partial, item in
            partial[ExpenseCategory.canonicalCategory(for: item.category), default: .zero] += item.totalSpent
        }
        return BudgetOverviewService().rows(
            plannedAmount: { budgetLimit(for: $0.storageValue, in: month, calendar: calendar) },
            spending: spending,
            source: summary.dataSource == .bank ? .bank : .manual,
            refunds: refunds, catalog: availableCategories
        ).sorted {
            if $0.spentAmount != $1.spentAmount { return $0.spentAmount > $1.spentAmount }
            if ($0.plannedAmount ?? .zero) != ($1.plannedAmount ?? .zero) { return ($0.plannedAmount ?? .zero) > ($1.plannedAmount ?? .zero) }
            return $0.category.rawValue < $1.category.rawValue
        }
    }
}
