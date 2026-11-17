import Foundation

enum InsightType: String, Hashable, CaseIterable {
    case subscription
    case purchase
    case goal
    case habit
    case summary
    case warning
    case positive
}

struct InsightItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let message: String
    let type: InsightType
    let optionalValue: String?
    // Where a tap on the card leads; nil keeps the card informational.
    let route: AppNavigation.Route?

    init(
        id: UUID = UUID(),
        title: String,
        message: String,
        type: InsightType,
        optionalValue: String? = nil,
        route: AppNavigation.Route? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.type = type
        self.optionalValue = optionalValue
        self.route = route
    }
}
