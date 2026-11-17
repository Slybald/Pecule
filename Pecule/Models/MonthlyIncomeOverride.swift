import Foundation
import SwiftData

@Model
final class MonthlyIncomeOverride: Identifiable {
    var id: UUID
    var incomeSourceID: UUID
    var monthStartDate: Date
    var amount: Decimal
    var replacesSourceAmount: Bool

    init(
        id: UUID = UUID(),
        incomeSourceID: UUID,
        monthStartDate: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) {
        self.id = id
        self.incomeSourceID = incomeSourceID
        self.monthStartDate = monthStartDate
        self.amount = amount
        self.replacesSourceAmount = replacesSourceAmount
    }

    // `monthStartDate` est un ancrage midi UTC le 1er du mois : lu dans le calendrier fourni, il tombe dans le
    // bon mois de UTC-12 à UTC+14. La comparaison se fait en mois de ce calendrier, comme pour les revenus.
    func applies(toMonthContaining date: Date, calendar: Calendar = .current) -> Bool {
        calendar.peculeCalendarMonthStart(containing: monthStartDate) == calendar.peculeCalendarMonthStart(containing: date)
    }

    func resolvedAmount(for baseAmount: Decimal) -> Decimal {
        let value = replacesSourceAmount ? amount : (baseAmount + amount)
        return value.currencyRounded
    }
}
