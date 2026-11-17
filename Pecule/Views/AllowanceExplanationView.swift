import SwiftUI

struct AllowanceExplanationView: View {
    let month: Date
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    var body: some View {
        let summary = appState.monthlyFinancialSummary(for: month)
        List {
            Section(Formatters.monthYearString(for: month)) {
                row("operations.income", summary.totalEstimatedIncome)
                if summary.showsNoImportedOperations {
                    LabeledContent(
                        AppLocalizer.string("operations.netExpenses", locale: locale),
                        value: AppLocalizer.string("overview.noImportedOperations", locale: locale)
                    )
                } else {
                    row("operations.netExpenses", summary.totalExpenses)
                }
                row("allowance.beforeGoals", summary.beforeGoalReservations)
                LabeledContent(AppLocalizer.string("allowance.goalReservations", locale: locale)) {
                    Text(Formatters.currencyString(for: summary.reservedForGoals))
                        .accessibilityIdentifier("allowance-goal-reservations-value")
                }
                row("dashboard.metrics.remainingToLive.title", summary.remainingToLive)
                Text(AppLocalizer.string("allowance.formula", locale: locale)).font(.footnote)
            }
            Section(AppLocalizer.string("goal.reservations", locale: locale)) {
                ForEach(appState.goals) { goal in
                    let entries = appState.budgetGoalContributions().filter { $0.goalID == goal.id }
                    let amount = GoalFundingService().reserved(for: month, contributions: entries)
                    // Non nul, et non « positif » : un mois où l'on rend de l'argent compte dans
                    // le total, il doit donc apparaître aussi dans le détail qui l'explique.
                    if amount != 0 {
                        NavigationLink {
                            if goal.normalizedIntention == .plannedExpense { ProvisionDetailView(goalID: goal.id) }
                            else { GoalFormView(goal: goal) }
                        } label: {
                            LabeledContent(goal.title, value: Formatters.currencyString(for: amount))
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLocalizer.string("allowance.explanation", locale: locale))
        .accessibilityIdentifier("allowance-explanation-screen")
    }
    private func row(_ key: String, _ amount: Decimal) -> some View {
        LabeledContent(AppLocalizer.string(key, locale: locale), value: Formatters.currencyString(for: amount))
    }
}
