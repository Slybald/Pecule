import Foundation
import SwiftData

enum HabitFrequency: String, Codable, Hashable, CaseIterable {
    case daily
    case weekly

    var displayName: String {
        switch self {
        case .daily:
            return AppLocalizer.string("Daily")
        case .weekly:
            return AppLocalizer.string("Weekly")
        }
    }
}

@Model
final class Habit: Identifiable {
    var id: UUID
    var title: String
    var frequency: HabitFrequency
    var targetCount: Int
    var completedCount: Int
    var linkedGoalID: UUID?
    var isActive: Bool

    init(
        id: UUID = UUID(),
        title: String,
        frequency: HabitFrequency,
        targetCount: Int,
        completedCount: Int,
        linkedGoalID: UUID?,
        isActive: Bool
    ) {
        self.id = id
        self.title = title
        self.frequency = frequency
        self.targetCount = targetCount
        self.completedCount = completedCount
        self.linkedGoalID = linkedGoalID
        self.isActive = isActive
    }

    var progress: Double {
        guard targetCount > 0 else {
            return 0
        }

        let ratio = Double(completedCount) / Double(targetCount)
        return min(max(ratio, 0), 1)
    }
}
