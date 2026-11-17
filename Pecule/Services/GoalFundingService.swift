import Foundation
import SwiftData

struct GoalFundingService {
    // Ce que le mois met de côté, une libération comprise. Deux pièges de bord de mois :
    // `DateInterval.contains` est fermé aux deux bouts, donc une réservation datée du 1er à minuit
    // appartenait au mois précédent et au suivant ; et borner chaque mois à zéro annulait les
    // libérations, si bien qu'une somme rendue le mois suivant ne revenait jamais au reste à vivre.
    func reserved(for month: Date, contributions: [GoalContribution], calendar: Calendar = .current) -> Decimal {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return 0 }
        let inMonth = Dictionary(
            grouping: contributions.filter { $0.date >= interval.start && $0.date < interval.end },
            by: \.goalID
        )
        return inMonth.reduce(Decimal.zero) { total, entry in
            let (goalID, entries) = entry
            let movement = entries.reduce(Decimal.zero) { $0 + $1.amount }
            // Une libération ne peut rendre que ce qui avait été réservé auparavant.
            let reservedBefore = max(
                contributions
                    .filter { $0.goalID == goalID && $0.date < interval.start }
                    .reduce(Decimal.zero) { $0 + $1.amount },
                0
            )
            return total + max(movement, -reservedBefore)
        }.currencyRounded
    }
    func totalReserved(goalID: UUID, contributions: [GoalContribution]) -> Decimal {
        max(contributions.filter { $0.goalID == goalID }.reduce(Decimal.zero) { $0 + $1.amount }, 0).currencyRounded
    }
}

extension PeculeDataStore {
    func goalContributions() throws -> [GoalContribution] {
        try container.mainContext.fetch(FetchDescriptor<GoalContribution>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.id)]))
    }

    func saveGoalPlan(id: UUID?, title: String, target: Decimal, current: Decimal, category: String,
                      intention: GoalIntention, targetDate: Date, durationMonths: Int, showsHelp: Bool, now: Date = Date()) throws {
        guard target > 0, current >= 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...120).contains(durationMonths) else { throw BankTransactionEditError.unavailable }
        let goal: Goal
        if let id {
            guard let existing = try container.mainContext.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })).first else { throw BankTransactionEditError.unavailable }
            goal = existing
            let reserved = GoalFundingService().totalReserved(goalID: id, contributions: try goalContributions())
            guard current >= reserved else { throw BankTransactionEditError.unavailable }
        } else {
            goal = Goal(title: title, targetAmount: target, currentAmount: current, targetDate: targetDate, category: category, isArchived: false)
            container.mainContext.insert(goal)
        }
        goal.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        goal.targetAmount = target.currencyRounded; goal.currentAmount = current.currencyRounded
        goal.category = ExpenseCategory.formStorageValue(for: category)
        goal.intention = intention.rawValue; goal.targetDate = targetDate
        goal.durationMonths = intention == .duration ? durationMonths : nil
        goal.startedAt = goal.startedAt ?? now
        goal.showsFundingHelp = showsHelp
        try container.mainContext.save()
    }

    func reserveForGoal(id: UUID, amount: Decimal, date: Date, contributionID: UUID = UUID()) throws {
        let rounded = amount.currencyRounded
        guard rounded != 0, let goal = try container.mainContext.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })).first else { throw BankTransactionEditError.unavailable }
        if try container.mainContext.fetchCount(FetchDescriptor<GoalContribution>(predicate: #Predicate { $0.id == contributionID })) > 0 { return }
        let reserved = GoalFundingService().totalReserved(goalID: id, contributions: try goalContributions())
        guard rounded > 0 || -rounded <= reserved else { throw BankTransactionEditError.unavailable }
        container.mainContext.insert(GoalContribution(id: contributionID, goalID: id, date: date, amount: rounded))
        goal.currentAmount = (goal.currentAmount + rounded).currencyRounded
        try container.mainContext.save()
    }
}
