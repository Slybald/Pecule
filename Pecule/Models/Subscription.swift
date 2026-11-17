import Foundation
import SwiftData

enum BillingCycle: String, Codable, Hashable, CaseIterable {
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .monthly:
            return AppLocalizer.string("Monthly")
        case .yearly:
            return AppLocalizer.string("Yearly")
        }
    }
}

@Model
final class Subscription: Identifiable {
    var id: UUID
    var name: String
    var amount: Decimal
    var billingCycle: BillingCycle
    var category: String
    var nextBillingDate: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: String,
        nextBillingDate: Date,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.billingCycle = billingCycle
        self.category = category
        self.nextBillingDate = nextBillingDate
        self.isActive = isActive
    }
}

extension Subscription {
    convenience init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: ExpenseCategory,
        nextBillingDate: Date,
        isActive: Bool
    ) {
        self.init(
            id: id,
            name: name,
            amount: amount,
            billingCycle: billingCycle,
            category: category.storageValue,
            nextBillingDate: nextBillingDate,
            isActive: isActive
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
