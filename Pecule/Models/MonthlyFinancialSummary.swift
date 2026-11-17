import Foundation

enum BudgetPlannerBudgetScope: String, Codable, CaseIterable {
    case totalSpending
    case fixedOnly
    case variableOnly
}

enum FinancialSummaryDataSource: Equatable {
    case planned
    case bank

    /// Libellé du montant dépensé, commun à l'accueil, au budget et aux analyses : une somme bancaire est
    /// « dépensée », un plan manuel (abonnements compris) est « saisi et prévu ».
    var spentLabelKey: String {
        self == .bank ? "overview.budget.spent" : "overview.budget.planned"
    }
}

struct MonthlyFinancialSummary: Equatable {
    let month: DateInterval
    let recurringIncome: Decimal
    let incomeComplements: Decimal
    let incomeOverrideDelta: Decimal
    let fixedCharges: Decimal
    let variableExpenses: Decimal
    let categorySummaries: [CategorySpendingSummary]
    let budgetStatuses: [BudgetStatus]
    var dataSource: FinancialSummaryDataSource = .planned
    // Booked credits that no income source claims; informational, never added to the estimate.
    var unmatchedIncome: Decimal = .zero
    var reservedForGoals: Decimal = .zero
    // Opérations importées sur les comptes inclus pour ce mois (source bancaire seulement).
    var importedOperationCount = 0

    // Un total bancaire à zéro sans aucune opération importée dit « pas de données », pas « rien dépensé ».
    var hasNoImportedOperations: Bool {
        dataSource == .bank && importedOperationCount == 0
    }

    // Les écrans disent « aucune opération importée » à la place de ce zéro, jamais à la place d'un total
    // que des achats saisis rendent non nul.
    var showsNoImportedOperations: Bool {
        hasNoImportedOperations && totalExpenses == .zero
    }

    var monthStart: Date {
        month.start
    }

    var monthEnd: Date {
        month.end
    }

    var incomeSupplements: Decimal {
        incomeComplements
    }

    var monthlyIncomeAdjustments: Decimal {
        (incomeComplements + incomeOverrideDelta).currencyRounded
    }

    var totalEstimatedIncome: Decimal {
        (recurringIncome + monthlyIncomeAdjustments).currencyRounded
    }

    var totalExpenses: Decimal {
        (fixedCharges + variableExpenses).currencyRounded
    }

    var beforeGoalReservations: Decimal { (totalEstimatedIncome - totalExpenses).currencyRounded }

    var remainingToLive: Decimal {
        (beforeGoalReservations - reservedForGoals).currencyRounded
    }

    var potentialSavings: Decimal {
        max(remainingToLive, .zero).currencyRounded
    }

    var spendingByCategory: [String: Decimal] {
        Dictionary(uniqueKeysWithValues: categorySummaries.map { summary in
            (summary.category, summary.totalSpent)
        })
    }

    var availableBudgetByCategory: [String: Decimal] {
        var amounts: [String: Decimal] = [:]

        for status in budgetStatuses {
            amounts[status.category, default: .zero] += status.availableAmount
        }

        return amounts.mapValues(\.currencyRounded)
    }
}

struct CategorySpendingSummary: Equatable {
    let category: String
    let fixedCharges: Decimal
    let variableExpenses: Decimal

    var totalSpent: Decimal {
        (fixedCharges + variableExpenses).currencyRounded
    }
}

struct BudgetStatus: Equatable {
    let category: String
    let scope: BudgetPlannerBudgetScope
    let plannedAmount: Decimal
    let spentAmount: Decimal

    var remainingAmount: Decimal {
        (plannedAmount - spentAmount).currencyRounded
    }

    var availableAmount: Decimal {
        max(remainingAmount, .zero).currencyRounded
    }

    var overspentAmount: Decimal {
        max(-remainingAmount, .zero).currencyRounded
    }

    var utilizationRatio: Double {
        let plannedValue = NSDecimalNumber(decimal: plannedAmount).doubleValue
        let spentValue = NSDecimalNumber(decimal: spentAmount).doubleValue

        guard plannedValue > 0 else {
            return spentValue > 0 ? 1 : 0
        }

        return spentValue / plannedValue
    }

    var isOverspent: Bool {
        remainingAmount < .zero
    }
}
