import Foundation
import SwiftData

@Model
final class BudgetOverride: Identifiable {
    var id: UUID
    var category: String
    var year: Int
    var month: Int
    var monthlyAmount: Decimal

    init(
        id: UUID = UUID(),
        category: String,
        year: Int,
        month: Int,
        monthlyAmount: Decimal
    ) {
        self.id = id
        self.category = category
        self.year = year
        self.month = month
        self.monthlyAmount = monthlyAmount
    }

    func matches(year: Int, month: Int) -> Bool {
        self.year == year && self.month == month
    }
}
