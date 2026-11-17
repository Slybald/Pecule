import Foundation
import SwiftData

@Model
final class GoalContribution {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var date: Date
    var amount: Decimal // positive reservation, negative release; never a bank movement
    init(id: UUID = UUID(), goalID: UUID, date: Date, amount: Decimal) {
        self.id = id; self.goalID = goalID; self.date = date; self.amount = amount.currencyRounded
    }
}
