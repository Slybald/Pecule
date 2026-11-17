import Foundation
import SwiftUI

// Single routing point: cards, widgets, intents and notifications all open screens through here.
@MainActor
final class AppNavigation: ObservableObject {
    enum SpendingSegment: String, CaseIterable, Identifiable {
        case budgets
        case purchases
        case subscriptions

        var id: String { rawValue }
    }

    enum Route: Hashable {
        case subscription(UUID?)
        case purchase(UUID?)
        case goal(UUID?)
        case habit(UUID?)
        case accounts
        case budgets
        case income
        case cashflow
        case health

        var tab: RootTabView.Destination {
            switch self {
            case .subscription, .purchase, .budgets: .spending
            case .goal: .goals
            case .habit: .today
            case .accounts: .accounts
            case .income, .cashflow, .health: .today
            }
        }

        var spendingSegment: SpendingSegment? {
            switch self {
            case .subscription: .subscriptions
            case .purchase: .purchases
            case .budgets: .budgets
            default: nil
            }
        }
    }

    @Published var selectedTab: RootTabView.Destination = .today
    @Published var spendingSegment: SpendingSegment = .budgets
    @Published var pendingRoute: Route?

    func open(_ route: Route) {
        selectedTab = route.tab
        if let segment = route.spendingSegment {
            spendingSegment = segment
        }
        pendingRoute = route
    }

    // Each screen takes the route meant for it and clears it, so a stale route never re-fires.
    func consume(where matches: (Route) -> Bool) -> Route? {
        guard let route = pendingRoute, matches(route) else {
            return nil
        }
        pendingRoute = nil
        return route
    }
}

extension RecommendationItem {
    var route: AppNavigation.Route? {
        switch relatedEntityType {
        case .subscription: .subscription(relatedEntityID)
        case .purchase: .purchase(relatedEntityID)
        case .goal: .goal(relatedEntityID)
        case .habit: .habit(relatedEntityID)
        case nil:
            switch type {
            case .subscription: .subscription(nil)
            case .purchase: .purchase(nil)
            case .goal: .goal(nil)
            case .habit: .habit(nil)
            case .summary, .positive: nil
            }
        }
    }
}
