import Foundation
import SwiftData

/// An explicit EUR spending target for one civil month, independent of category limits.
@Model
final class MonthlySpendingLimit {
    @Attribute(.unique) var periodKey: String
    var amount: Decimal

    init(periodKey: String, amount: Decimal) {
        self.periodKey = periodKey
        self.amount = amount.currencyRounded
    }
}
