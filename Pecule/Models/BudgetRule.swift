import Foundation
import SwiftData

@Model
final class BudgetRule: Identifiable {
    static let defaultCategories: [String] = ExpenseCategory.budgetCategories

    var id: UUID
    var category: String
    var monthlyAmount: Decimal

    init(
        id: UUID = UUID(),
        category: String,
        monthlyAmount: Decimal
    ) {
        self.id = id
        self.category = category
        self.monthlyAmount = monthlyAmount
    }

    static func categoryKey(for category: String) -> String {
        ExpenseCategory.canonicalKey(for: category)
    }
}
