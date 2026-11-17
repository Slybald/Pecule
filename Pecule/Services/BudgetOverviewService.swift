import Foundation

struct BudgetOverviewRow: Identifiable, Equatable {
    enum Source: Equatable {
        case bank
        case manual
    }

    let category: ExpenseCategory
    let plannedAmount: Decimal?
    let spentAmount: Decimal
    let source: Source
    var refundedAmount: Decimal = .zero
    var grossSpentAmount: Decimal { (spentAmount + refundedAmount).currencyRounded }

    var id: String { category.rawValue }

    var remainingAmount: Decimal? {
        plannedAmount.map { ($0 - spentAmount).currencyRounded }
    }

    var isOverspent: Bool {
        (remainingAmount ?? .zero) < .zero
    }

    var utilizationRatio: Double {
        let spent = NSDecimalNumber(decimal: spentAmount).doubleValue
        guard let plannedAmount, plannedAmount > .zero else {
            return spent > 0 ? 1 : 0
        }
        return spent / NSDecimalNumber(decimal: plannedAmount).doubleValue
    }
}

// One row per category from the month's summary, which already merges real bank amounts with planned entries.
struct BudgetOverviewService {
    /// Opérations importées sur les comptes inclus pour ce mois, quel que soit leur statut : ce qui prouve que
    /// la banque couvre le mois. Un mois à zéro sans aucune opération importée n'est pas un mois sans dépense.
    static func importedOperationCount(in transactions: [BankTransaction], month: DateInterval, includedAccountIDs: Set<UUID>) -> Int {
        transactions.filter {
            $0.bookingDate >= month.start && $0.bookingDate < month.end &&
            includedAccountIDs.contains($0.accountID) && !$0.isAbsentFromBank
        }.count
    }

    /// `manualPurchases` : achats saisis à la main qui comptent dans le mois, déjà jugés par
    /// `ManualPurchaseCoverageService` (aucun rattachement, aucun débit plausible). Ils s'ajoutent aux opérations
    /// comme dépenses variables de leur catégorie.
    func recordedSummary(
        month: DateInterval,
        transactions: [BankTransaction],
        includedAccountIDs: Set<UUID>,
        plannedAmount: (ExpenseCategory) -> Decimal?,
        catalog: [ExpenseCategory] = ExpenseCategory.allCases,
        manualPurchases: [Purchase] = []
    ) -> MonthlyFinancialSummary {
        let included = transactions.filter {
            $0.bookingDate >= month.start && $0.bookingDate < month.end &&
            includedAccountIDs.contains($0.accountID) && $0.countsInTotals
        }
        let spending = Dictionary(grouping: included.filter { $0.isExpense || $0.isRefund }) {
            ExpenseCategory.canonicalCategory(for: $0.category)
        }
        let manualByCategory = Dictionary(grouping: manualPurchases.filter { $0.date >= month.start && $0.date < month.end }) {
            ExpenseCategory.canonicalCategory(for: $0.category)
        }.mapValues { $0.reduce(Decimal.zero) { $0 + $1.amount.currencyRounded } }
        let categories = Set(spending.keys).union(manualByCategory.keys).map { category in
            let rows = spending[category, default: []]
            let fixed = rows.filter { $0.linkedSubscriptionID != nil || MonthlyObservationService.fixedCategories.contains(category) }
                .reduce(Decimal.zero) { $0 + $1.netExpenseAmount }.currencyRounded
            let banked = rows.reduce(Decimal.zero) { $0 + $1.netExpenseAmount }.currencyRounded
            let variable = (banked - fixed + manualByCategory[category, default: .zero]).currencyRounded
            return CategorySpendingSummary(category: category.storageValue, fixedCharges: fixed, variableExpenses: variable)
        }.sorted { $0.category < $1.category }
        let budgets = catalog.compactMap { category -> BudgetStatus? in
            guard let planned = plannedAmount(category)?.currencyRounded else { return nil }
            let banked = spending[category, default: []].reduce(Decimal.zero) { $0 + $1.netExpenseAmount }
            let spent = (banked + manualByCategory[category, default: .zero]).currencyRounded
            return BudgetStatus(category: category.storageValue, scope: .totalSpending, plannedAmount: planned, spentAmount: spent)
        }
        var summary = MonthlyFinancialSummary(
            month: month,
            recurringIncome: included.filter(\.isIncome).reduce(Decimal.zero) { $0 + $1.amount }.currencyRounded,
            incomeComplements: .zero, incomeOverrideDelta: .zero,
            fixedCharges: categories.reduce(Decimal.zero) { $0 + $1.fixedCharges }.currencyRounded,
            variableExpenses: categories.reduce(Decimal.zero) { $0 + $1.variableExpenses }.currencyRounded,
            categorySummaries: categories, budgetStatuses: budgets, dataSource: .bank
        )
        summary.importedOperationCount = Self.importedOperationCount(in: transactions, month: month, includedAccountIDs: includedAccountIDs)
        return summary
    }

    func rows(
        plannedAmount: (ExpenseCategory) -> Decimal?,
        spending: [ExpenseCategory: Decimal],
        source: BudgetOverviewRow.Source,
        refunds: [ExpenseCategory: Decimal] = [:],
        catalog: [ExpenseCategory] = ExpenseCategory.allCases
    ) -> [BudgetOverviewRow] {
        Array(Set(catalog + Array(spending.keys) + Array(refunds.keys))).sorted { $0.id < $1.id }.map { category in
            let planned = plannedAmount(category)?.currencyRounded
            return BudgetOverviewRow(
                category: category,
                plannedAmount: planned,
                spentAmount: (spending[category] ?? .zero).currencyRounded,
                source: source,
                refundedAmount: (refunds[category] ?? .zero).currencyRounded
            )
        }
    }

    static func totals(of rows: [BudgetOverviewRow]) -> (planned: Decimal, spent: Decimal) {
        (
            rows.compactMap(\.plannedAmount).reduce(.zero, +).currencyRounded,
            rows.map(\.spentAmount).reduce(.zero, +).currencyRounded
        )
    }
}
