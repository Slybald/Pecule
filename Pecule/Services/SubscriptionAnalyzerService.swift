import Foundation

struct SubscriptionAnalyzerService {
    private let financialCalculator: FinancialCalculatorService
    private let expensiveMonthlyThreshold: Decimal

    init(
        financialCalculator: FinancialCalculatorService = FinancialCalculatorService(),
        expensiveMonthlyThreshold: Decimal = 15
    ) {
        self.financialCalculator = financialCalculator
        self.expensiveMonthlyThreshold = expensiveMonthlyThreshold
    }

    func expensiveSubscriptions(in subscriptions: [Subscription]) -> [Subscription] {
        activeSubscriptions(from: subscriptions)
            .filter { financialCalculator.costPerMonth($0) > expensiveMonthlyThreshold }
            .sorted { left, right in
                let leftMonthlyCost = financialCalculator.costPerMonth(left)
                let rightMonthlyCost = financialCalculator.costPerMonth(right)

                if leftMonthlyCost != rightMonthlyCost {
                    return leftMonthlyCost > rightMonthlyCost
                }

                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func duplicateGroups(in subscriptions: [Subscription]) -> [[Subscription]] {
        Dictionary(grouping: activeSubscriptions(from: subscriptions), by: normalizedName(for:))
            .values
            .filter { $0.count > 1 }
            .map { group in
                group.sorted { left, right in
                    if left.nextBillingDate != right.nextBillingDate {
                        return left.nextBillingDate < right.nextBillingDate
                    }

                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
            .sorted { left, right in
                let leftName = left.first.map(normalizedName(for:)) ?? ""
                let rightName = right.first.map(normalizedName(for:)) ?? ""
                return leftName < rightName
            }
    }

    func annualTotal(for subscriptions: [Subscription]) -> Decimal {
        activeSubscriptions(from: subscriptions)
            .reduce(.zero) { partialResult, subscription in
                partialResult + annualCost(for: subscription)
            }
            .currencyRounded
    }
}

private extension SubscriptionAnalyzerService {
    func activeSubscriptions(from subscriptions: [Subscription]) -> [Subscription] {
        subscriptions.filter(\.isActive)
    }

    func normalizedName(for subscription: Subscription) -> String {
        subscription.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func annualCost(for subscription: Subscription) -> Decimal {
        financialCalculator.costPerYear(subscription)
    }
}
