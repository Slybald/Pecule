import Foundation

struct FinancialCalculatorService {
    func costPerDay(_ purchase: Purchase) -> Decimal {
        rawDailyCost(for: purchase).currencyRounded
    }

    func costPerMonth(_ subscription: Subscription) -> Decimal {
        switch subscription.billingCycle {
        case .monthly:
            return subscription.amount.currencyRounded
        case .yearly:
            return (subscription.amount / 12).currencyRounded
        }
    }

    func costPerYear(_ subscription: Subscription) -> Decimal {
        switch subscription.billingCycle {
        case .monthly:
            return (subscription.amount * 12).currencyRounded
        case .yearly:
            return subscription.amount.currencyRounded
        }
    }

    func lifetimeCost(_ subscription: Subscription, years: Int) -> Decimal {
        guard years > 0 else {
            return .zero
        }

        let yearMultiplier = NSDecimalNumber(value: years).decimalValue

        switch subscription.billingCycle {
        case .monthly:
            return (subscription.amount * 12 * yearMultiplier).currencyRounded
        case .yearly:
            return (subscription.amount * yearMultiplier).currencyRounded
        }
    }

    func costOverTime(_ purchase: Purchase, months: Int) -> Decimal {
        guard months > 0 else {
            return .zero
        }

        let monthMultiplier = NSDecimalNumber(value: months).decimalValue
        return (rawDailyCost(for: purchase) * 30 * monthMultiplier).currencyRounded
    }
}

private extension FinancialCalculatorService {
    func rawDailyCost(for purchase: Purchase) -> Decimal {
        purchase.amount / 30
    }
}
