import SwiftUI

struct InstallmentReviewSection: View {
    let transactionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var number = 1
    @State private var count = 3
    @State private var errorMessage: String?
    @State private var scheduleDraft: CommitmentDraft?
    private var transaction: BankTransaction? { appState.bankTransaction(id: transactionID) }

    var body: some View {
        Section(AppLocalizer.string("installment.title", locale: locale)) {
            Text(AppLocalizer.string("installment." + (transaction?.installmentDecision ?? "suggested"), locale: locale))
            Text(AppLocalizer.string("installment.explanation", locale: locale)).font(.footnote)
            Stepper(AppLocalizer.pluralFormat("installment.count %lld", locale: locale, Int64(count)), value: $count, in: 2...36)
                .accessibilityIdentifier("installment-count")
                .onChange(of: count) { _, value in number = min(number, value) }
            Stepper(AppLocalizer.format("installment.number %lld", locale: locale, Int64(number)), value: $number, in: 1...count)
                .accessibilityIdentifier("installment-number")
            Button(AppLocalizer.string("installment.confirm", locale: locale)) { decide("confirmed") }
                .accessibilityIdentifier("installment-confirm")
            Button(AppLocalizer.string("installment.reject", locale: locale)) { decide("rejected") }
                .accessibilityIdentifier("installment-reject")
            if transaction?.installmentDecision != nil {
                Button(AppLocalizer.string("installment.reset", locale: locale)) { decide("suggested") }
                    .accessibilityIdentifier("installment-reset")
            }
            if let draft = appState.installmentDraft(for: transactionID), transaction?.installmentDecision == "confirmed" {
                Button(AppLocalizer.string("commitments.planInstallments", locale: locale)) { scheduleDraft = draft }
                    .accessibilityIdentifier("installment-schedule")
            }
            if let errorMessage { Text(errorMessage) }
        }
        .sheet(item: $scheduleDraft) { draft in NavigationStack { CommitmentFormView(draft: draft) } }
        .onAppear {
            if let evidence = transaction?.installmentEvidence { count = evidence.count; number = evidence.number }
        }
    }

    private func decide(_ decision: String) {
        guard appState.isProfileActive else { return }
        do {
            try appState.dataStore.decideInstallment(id: transactionID, decision: decision, number: number, count: count)
            appState.reload()
        } catch { errorMessage = error.userMessage }
    }
}
