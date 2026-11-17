import Foundation

enum RecommendationType: String, Hashable, CaseIterable {
    case subscription
    case purchase
    case goal
    case habit
    case summary
    case positive
}

enum RecommendationPriority: String, Hashable, CaseIterable, Comparable {
    case high
    case medium
    case low

    var sortOrder: Int {
        switch self {
        case .high:
            return 0
        case .medium:
            return 1
        case .low:
            return 2
        }
    }

    static func < (lhs: RecommendationPriority, rhs: RecommendationPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

enum RecommendationEntityType: String, Hashable, CaseIterable {
    case subscription
    case purchase
    case goal
    case habit
}

struct RecommendationItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let message: String
    let type: RecommendationType
    let priority: RecommendationPriority
    let relatedEntityID: UUID?
    let relatedEntityType: RecommendationEntityType?
    let estimatedImpact: String?

    init(
        id: UUID = UUID(),
        title: String,
        message: String,
        type: RecommendationType,
        priority: RecommendationPriority,
        relatedEntityID: UUID? = nil,
        relatedEntityType: RecommendationEntityType? = nil,
        estimatedImpact: String? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.type = type
        self.priority = priority
        self.relatedEntityID = relatedEntityID
        self.relatedEntityType = relatedEntityType
        self.estimatedImpact = estimatedImpact
    }
}
