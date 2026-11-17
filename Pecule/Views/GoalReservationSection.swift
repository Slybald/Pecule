import SwiftUI

struct GoalReservationSection: View {
    let goalID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var amountText = ""
    @State private var errorMessage: String?
    private var reserved: Decimal { GoalFundingService().totalReserved(goalID: goalID, contributions: appState.goalContributions) }
    private var amount: Decimal? { Formatters.decimalValue(from: amountText).flatMap { $0 > 0 ? $0.currencyRounded : nil } }
    var body: some View {
        Section(AppLocalizer.string("goal.reservations", locale: locale)) {
            LabeledContent(AppLocalizer.string("goal.reserved", locale: locale), value: Formatters.currencyString(for: reserved))
            Text(AppLocalizer.string("goal.reservation.explanation", locale: locale)).font(.footnote)
            TextField(Formatters.amountPlaceholder(locale: locale), text: $amountText).keyboardType(.decimalPad)
                .accessibilityLabel(AppLocalizer.string("goal.reservation.amount", locale: locale))
                .accessibilityIdentifier("goal-reservation-amount")
            if appState.goals.first(where: { $0.id == goalID })?.showsFundingHelp == true,
               let amount, amount > appState.monthlyFinancialSummary(for: Date()).remainingToLive {
                Text(AppLocalizer.string("goal.help.insufficient", locale: locale)).foregroundStyle(AppColors.warning)
                    .accessibilityIdentifier("goal-reservation-guidance")
            }
            Button(AppLocalizer.string("goal.reserve", locale: locale)) { save(release: false) }
                .disabled(amount == nil).accessibilityIdentifier("goal-reserve")
            Button(AppLocalizer.string("goal.release", locale: locale)) { save(release: true) }
                .disabled(amount == nil || (amount ?? 0) > reserved).accessibilityIdentifier("goal-release")
            ForEach(appState.goalContributions.filter { $0.goalID == goalID }.reversed()) { entry in
                LabeledContent(Formatters.dateString(for: entry.date), value: Formatters.currencyString(for: entry.amount))
            }
            if let errorMessage { Text(errorMessage) }
        }
    }
    private func save(release: Bool) {
        guard appState.isProfileActive, let amount else { return }
        do {
            try appState.dataStore.reserveForGoal(id: goalID, amount: release ? -amount : amount, date: Date())
            appState.reload(); amountText = ""
        } catch { errorMessage = error.userMessage }
    }
}
