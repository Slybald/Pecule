import Foundation
import SwiftData

struct MonthlyBudgetSummary {
    let limit: Decimal?
    let expenses: Decimal
    let upcoming: [CashflowForecast.UpcomingCharge]
    let source: FinancialSummaryDataSource
    var manualAdditionalCharges: Decimal = .zero
    // Faux quand la source est bancaire et qu'aucune opération n'a été importée pour le mois.
    var hasImportedOperations = true

    // The manual monthly plan already includes its subscriptions. Subtracting them again
    // would count the same charge twice. Bank summaries contain only booked movements.
    var additionalCharges: Decimal {
        source == .bank ? upcoming.reduce(.zero) { $0 + $1.amount }.currencyRounded : manualAdditionalCharges
    }
    var knownTotal: Decimal { (expenses + additionalCharges).currencyRounded }
    var margin: Decimal? { limit.map { ($0 - knownTotal).currencyRounded } }

    // Là où le total bancaire serait affiché à 0 € : sans opération importée ni achat saisi, ce zéro ne
    // prouve rien, l'écran dit donc qu'il n'y a pas d'opération importée.
    var showsNoImportedOperations: Bool {
        source == .bank && !hasImportedOperations && expenses == .zero
    }
}

enum MonthlyBudgetService {
    static func periodKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.era, .year, .month], from: date)
        return "\(calendar.identifier):\(parts.era ?? 1):\(parts.year ?? 0):\(parts.month ?? 0)"
    }

    struct Point: Identifiable {
        let date: Date
        let amount: Decimal
        var id: Date { date }
    }

    /// Hauteur utile du graphique. Cadrer systématiquement sur le plafond écrase la courbe en bas
    /// dès que l'on dépense peu : on ne voit plus rien de sa trajectoire. Tant que les dépenses
    /// n'atteignent pas le tiers du plafond, on cadre donc sur elles, et le plafond n'est plus
    /// tracé mais écrit sous le graphique, pour ne jamais laisser croire qu'on s'en approche.
    static func chartScale(points: [Point], knownTotal: Decimal, limit: Decimal?) -> (floor: Decimal, ceiling: Decimal, showsLimit: Bool) {
        // Un remboursement peut réduire le total après un pic, voire rendre le net négatif.
        // Garder toute la trajectoire visible, ainsi que zéro comme repère stable.
        let peak = max(knownTotal, points.map(\.amount).max() ?? .zero, .zero)
        let floor = min(points.map(\.amount).min() ?? .zero, .zero) * 5 / 4
        let fitted = max(peak * 5 / 4, 10)
        guard let limit, limit > .zero else { return (floor, fitted, false) }
        if peak * 3 >= limit { return (floor, max(limit, fitted), true) }
        return (floor, min(limit, fitted), false)
    }

    /// `manualPurchases` : les achats saisis qui comptent dans le mois (voir `ManualPurchaseCoverageService`),
    /// à leur jour, pour que la courbe finisse sur le total affiché au-dessus d'elle.
    static func trajectory(transactions: [BankTransaction], manualPurchases: [Purchase] = [], on date: Date, calendar: Calendar) -> [Point] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let today = calendar.startOfDay(for: date)
        var daily: [Date: Decimal] = [:]
        for transaction in transactions where transaction.bookingDate >= month.start && transaction.bookingDate < month.end && (transaction.isExpense || transaction.isRefund) {
            daily[calendar.startOfDay(for: transaction.bookingDate), default: .zero] += transaction.netExpenseAmount
        }
        for purchase in manualPurchases where purchase.date >= month.start && purchase.date < month.end {
            daily[calendar.startOfDay(for: purchase.date), default: .zero] += purchase.amount.currencyRounded
        }
        var points: [Point] = [], total = Decimal.zero, day = month.start
        while day <= today {
            total += daily[day, default: .zero]
            points.append(Point(date: day, amount: total.currencyRounded))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return points
    }
}

extension PeculeDataStore {
    func monthlySpendingLimits() throws -> [MonthlySpendingLimit] {
        try container.mainContext.fetch(FetchDescriptor<MonthlySpendingLimit>())
    }

    func setMonthlySpendingLimit(_ amount: Decimal?, for date: Date, calendar: Calendar) throws {
        if let amount, amount.isNaN || amount < .zero { throw BankTransactionEditError.unavailable }
        let context = container.mainContext
        let key = MonthlyBudgetService.periodKey(for: date, calendar: calendar)
        let record = try monthlySpendingLimits().first { $0.periodKey == key }
        if let amount {
            if let record { record.amount = amount.currencyRounded }
            else { context.insert(MonthlySpendingLimit(periodKey: key, amount: amount)) }
        } else if let record { context.delete(record) }
        try context.save()
    }
}

extension AppState {
    func monthlySpendingLimit(for date: Date, calendar: Calendar = .current) -> Decimal? {
        let key = MonthlyBudgetService.periodKey(for: date, calendar: calendar)
        return monthlySpendingLimits.first { $0.periodKey == key }?.amount
    }

    func setMonthlySpendingLimit(_ amount: Decimal?, for date: Date, calendar: Calendar = .current) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.setMonthlySpendingLimit(amount, for: date, calendar: calendar)
        reload()
    }

    func monthlyBudget(on date: Date = Date(), now: Date = Date(), calendar: Calendar = .current) -> MonthlyBudgetSummary {
        let summary = monthlyFinancialSummary(for: date, calendar: calendar)
        // Historical months never inherit today's remaining schedule.
        let upcoming = calendar.isDate(date, equalTo: now, toGranularity: .month)
            ? cashflowForecast(on: now, calendar: calendar)?.upcomingCharges ?? [] : []
        var result = MonthlyBudgetSummary(limit: monthlySpendingLimit(for: date, calendar: calendar),
                                    expenses: summary.totalExpenses, upcoming: upcoming, source: summary.dataSource)
        let subscriptionIDs = Set(subscriptions.map(\.id))
        result.manualAdditionalCharges = upcoming.filter { !subscriptionIDs.contains($0.id) }.reduce(.zero) { $0 + $1.amount }.currencyRounded
        result.hasImportedOperations = !summary.hasNoImportedOperations
        return result
    }
}
