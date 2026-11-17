import Foundation
import SwiftData

struct PurchaseSimulationDraft: Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var amount: Decimal = 0
    var date: Date
    var accountID: UUID?
    var isExisting = false

    init(now: Date = Date()) { date = now }
    init(_ scenario: PurchaseScenario) {
        id = scenario.id; title = scenario.title; amount = scenario.amount
        date = scenario.date; accountID = scenario.accountID; isExisting = true
    }
}

enum PurchaseSimulationError: LocalizedError {
    case invalidAmount, invalidDate, unavailableAccount, missingScenario, emptyTitle, inactiveProfile
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidAmount: key = "simulation.invalidAmount"
        case .invalidDate: key = "simulation.invalidDate"
        case .unavailableAccount: key = "simulation.unavailableAccount"
        case .missingScenario: key = "simulation.missing"
        case .emptyTitle: key = "simulation.emptyTitle"
        case .inactiveProfile: key = "accounts.transaction.unavailable"
        }
        return AppLocalizer.string(key)
    }
}

struct SimulationMonthComparison {
    let month: Date
    let budgetBefore: Decimal?
    let budgetAfter: Decimal?
    let projectsBefore: Decimal
    let projectsAfter: Decimal
    let reservedInMonth: Decimal
    let usesBankAmounts: Bool
}

struct PurchaseSimulationResult {
    let reference: PlanningForecast
    let scenario: PlanningForecast
    let month: SimulationMonthComparison
    let accountBefore: Decimal?
    let accountAfter: Decimal?
    let end: Date
    let afterSalaryDate: Date?
    let afterSalaryForecast: PlanningForecast?
    let afterSalaryMonth: SimulationMonthComparison?
}

enum PurchaseSimulationService {
    static func latestDate(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 365, to: calendar.startOfDay(for: now))!
    }
    static func validate(_ draft: PurchaseSimulationDraft, now: Date, calendar: Calendar,
                         accountIDs: Set<UUID>) throws {
        guard !draft.amount.isNaN, draft.amount.currencyRounded > 0 else { throw PurchaseSimulationError.invalidAmount }
        let day = calendar.startOfDay(for: draft.date), today = calendar.startOfDay(for: now)
        guard day >= today, day <= latestDate(now: now, calendar: calendar) else { throw PurchaseSimulationError.invalidDate }
        if let account = draft.accountID, !accountIDs.contains(account) { throw PurchaseSimulationError.unavailableAccount }
    }
    static func event(_ draft: PurchaseSimulationDraft, date: Date? = nil, calendar: Calendar) -> ForecastEvent {
        .init(id: "scenario:\(draft.id)", commitmentID: draft.id, title: draft.title,
              amount: -draft.amount.currencyRounded, date: calendar.startOfDay(for: date ?? draft.date),
              accountID: draft.accountID, confirmed: true, category: ExpenseCategory.other.storageValue)
    }
    static func accountMinimum(_ forecast: PlanningForecast, id: UUID?) -> Decimal? {
        guard let id else { return nil }
        return forecast.days.compactMap { $0.balances[id] }.min()
    }
}

extension PeculeDataStore {
    func savePurchaseScenario(_ draft: PurchaseSimulationDraft, now: Date = Date(), calendar: Calendar = .current) throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PurchaseSimulationError.emptyTitle }
        let accounts = try planningFetch(ExternalAccount.self).filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }
        try PurchaseSimulationService.validate(draft, now: now, calendar: calendar, accountIDs: Set(accounts.map(\.id)))
        let existing = try planningFetch(PurchaseScenario.self).first { $0.id == draft.id }
        if draft.isExisting, existing == nil { throw PurchaseSimulationError.missingScenario }
        if let existing {
            existing.title = title; existing.amount = draft.amount.currencyRounded
            existing.date = calendar.startOfDay(for: draft.date); existing.accountID = draft.accountID
        } else {
            container.mainContext.insert(PurchaseScenario(id: draft.id, title: title, amount: draft.amount,
                                                         date: calendar.startOfDay(for: draft.date), accountID: draft.accountID))
        }
    }
    func deletePurchaseScenario(id: UUID) throws {
        guard let row = try planningFetch(PurchaseScenario.self).first(where: { $0.id == id }) else { throw PurchaseSimulationError.missingScenario }
        container.mainContext.delete(row)
    }
}

extension AppState {
    func simulatePurchase(_ draft: PurchaseSimulationDraft, on now: Date = Date(), habitual: Bool = false,
                          calendar: Calendar = .current) throws -> PurchaseSimulationResult {
        guard isProfileActive else { throw PurchaseSimulationError.inactiveProfile }
        let accounts = externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }
        try PurchaseSimulationService.validate(draft, now: now, calendar: calendar, accountIDs: Set(accounts.map(\.id)))
        let today = calendar.startOfDay(for: now)
        let afterSalary = nextPlannedSalary(on: now, calendar: calendar)
            .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            .flatMap { $0 <= PurchaseSimulationService.latestDate(now: now, calendar: calendar) ? $0 : nil }
        // All alternatives share an identical window, including both possible purchase dates.
        let lastPurchaseDay = max(calendar.startOfDay(for: draft.date), afterSalary ?? today)
        let end = max(calendar.date(byAdding: .day, value: 30, to: today)!, calendar.date(byAdding: .day, value: 1, to: lastPurchaseDay)!)
        let reference = planningForecast(on: now, until: end, habitual: habitual, calendar: calendar)
        let scenario = planningForecast(on: now, until: end, habitual: habitual,
                                        extra: [PurchaseSimulationService.event(draft, calendar: calendar)], calendar: calendar)
        let alternative = afterSalary.map { date in
            planningForecast(on: now, until: end, habitual: habitual,
                             extra: [PurchaseSimulationService.event(draft, date: date, calendar: calendar)], calendar: calendar)
        }
        return .init(reference: reference, scenario: scenario,
                     month: purchaseSimulationMonth(date: draft.date, amount: draft.amount, now: now, calendar: calendar),
                     accountBefore: PurchaseSimulationService.accountMinimum(reference, id: draft.accountID),
                     accountAfter: PurchaseSimulationService.accountMinimum(scenario, id: draft.accountID), end: end,
                     afterSalaryDate: afterSalary, afterSalaryForecast: alternative,
                     afterSalaryMonth: afterSalary.map { purchaseSimulationMonth(date: $0, amount: draft.amount, now: now, calendar: calendar) })
    }

    private func purchaseSimulationMonth(date: Date, amount: Decimal, now: Date, calendar: Calendar) -> SimulationMonthComparison {
        let month = calendar.dateInterval(of: .month, for: date)!
        let summary = monthlyFinancialSummary(for: date, calendar: calendar)
        let bank = summary.dataSource == .bank
        let included = Set(externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }.map(\.id))
        // Same remaining charges as the margin of the home screen: the figures must agree.
        let events = remainingPlanningEvents(on: now, until: month.end, calendar: calendar).filter { event in
            event.confirmed && event.date.map { $0 >= max(month.start, calendar.startOfDay(for: now)) && $0 < month.end } == true &&
            (event.accountID.map(included.contains) ?? true)
        }
        let subscriptionIDs = Set(subscriptions.map(\.id))
        // Manual totals already include recurring subscriptions and planned income.
        let charges = events.filter { $0.amount < 0 && (bank || !subscriptionIDs.contains($0.commitmentID)) }
            .reduce(Decimal.zero) { $0 - $1.amount }
        let credits = bank ? events.filter { $0.amount > 0 }.reduce(Decimal.zero) { $0 + $1.amount } : 0
        let budget = monthlySpendingLimit(for: date, calendar: calendar).map { ($0 - summary.totalExpenses - charges).currencyRounded }
        let projects = (summary.remainingToLive - charges + credits).currencyRounded
        return .init(month: month.start, budgetBefore: budget, budgetAfter: budget.map { ($0 - amount.currencyRounded).currencyRounded },
                     projectsBefore: projects, projectsAfter: (projects - amount.currencyRounded).currencyRounded,
                     reservedInMonth: summary.reservedForGoals, usesBankAmounts: bank)
    }
}
