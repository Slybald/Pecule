import Foundation
import SwiftData

@Model
final class Purchase: Identifiable {
    var id: UUID
    var title: String
    var amount: Decimal
    var date: Date
    var category: String
    var merchant: String
    var notes: String?

    init(
        id: UUID = UUID(),
        title: String,
        amount: Decimal,
        date: Date,
        category: String,
        merchant: String,
        notes: String?
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.merchant = merchant
        self.notes = notes
    }
}

extension Purchase {
    convenience init(
        id: UUID = UUID(),
        title: String,
        amount: Decimal,
        date: Date,
        category: ExpenseCategory,
        merchant: String,
        notes: String?
    ) {
        self.init(
            id: id,
            title: title,
            amount: amount,
            date: date,
            category: category.storageValue,
            merchant: merchant,
            notes: notes
        )
    }

    var normalizedCategory: ExpenseCategory {
        ExpenseCategory(matching: category) ?? .other
    }

    var normalizedCategoryKey: String {
        normalizedCategory.rawValue
    }

    func categoryDisplayName(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        ExpenseCategory.displayName(forStoredValue: category, locale: locale)
    }
}
