import Foundation
import SwiftData

@Model
final class Goal: Identifiable {
    var id: UUID
    var title: String
    var targetAmount: Decimal
    var currentAmount: Decimal
    var targetDate: Date
    var category: String
    var intention: String = "deadline"
    var durationMonths: Int?
    var startedAt: Date?
    var showsFundingHelp: Bool = false
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String,
        isArchived: Bool
    ) {
        self.id = id
        self.title = title
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.targetDate = targetDate
        self.category = category
        self.isArchived = isArchived
    }

    var progress: Double {
        let targetValue = NSDecimalNumber(decimal: targetAmount).doubleValue

        guard targetValue > 0 else {
            return 0
        }

        let currentValue = NSDecimalNumber(decimal: currentAmount).doubleValue

        return min(max(currentValue / targetValue, 0), 1)
    }
}


enum GoalIntention: String, CaseIterable, Identifiable {
    case purchase, duration, deadline, reserve, plannedExpense
    var id: String { rawValue }
}

extension Goal {
    var normalizedIntention: GoalIntention { GoalIntention(rawValue: intention) ?? .deadline }
    func deadline(calendar: Calendar = .current) -> Date? {
        switch normalizedIntention {
        case .deadline, .plannedExpense: return targetDate
        case .duration:
            guard let startedAt, let durationMonths else { return nil }
            return calendar.date(byAdding: .month, value: durationMonths, to: startedAt)
        case .purchase, .reserve: return nil
        }
    }
}
