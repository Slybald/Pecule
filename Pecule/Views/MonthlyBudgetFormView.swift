import SwiftUI

struct MonthlyBudgetFormView: View {
    let month: Date
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var error: String?

    private var amount: Decimal? {
        guard let amount = Formatters.decimalValue(from: amountText, prefilledWith: appState.monthlySpendingLimit(for: month)), !amount.isNaN, amount >= 0 else { return nil }
        return amount
    }

    var body: some View {
        Form {
            Section {
                TextField(Formatters.amountPlaceholder(locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .accessibilityLabel(AppLocalizer.string("monthlyBudget.limit", locale: locale))
                    .accessibilityIdentifier("monthly-budget-amount")
            } header: {
                Text(Formatters.monthYearString(for: month))
            } footer: {
                Text(AppLocalizer.string("monthlyBudget.form.help", locale: locale))
            }
            if appState.monthlySpendingLimit(for: month) != nil {
                Button(role: .destructive) { save(nil) } label: {
                    Text(AppLocalizer.string("budgetForm.remove", locale: locale))
                }.accessibilityIdentifier("monthly-budget-remove")
            }
        }
        .navigationTitle(AppLocalizer.string("monthlyBudget.limit", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    if let amount { save(amount) }
                }.disabled(amount == nil).accessibilityIdentifier("monthly-budget-save")
            }
        }
        .onAppear { amountText = appState.monthlySpendingLimit(for: month).map { Formatters.decimalString(for: $0) } ?? "" }
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func save(_ amount: Decimal?) {
        do {
            try appState.setMonthlySpendingLimit(amount, for: month)
            dismiss()
        } catch { self.error = error.userMessage }
    }
}

struct MonthlyBudgetExplanationView: View {
    let month: Date
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    var body: some View {
        let summary = appState.monthlyBudget(on: month)
        List {
            Section(Formatters.monthYearString(for: month)) {
                if let limit = summary.limit {
                    LabeledContent(AppLocalizer.string("monthlyBudget.limit", locale: locale), value: Formatters.currencyString(for: limit))
                }
                LabeledContent(
                    AppLocalizer.string(summary.source.spentLabelKey, locale: locale),
                    value: summary.showsNoImportedOperations
                        ? AppLocalizer.string("overview.noImportedOperations", locale: locale)
                        : Formatters.currencyString(for: summary.expenses)
                )
                if summary.source == .bank {
                    LabeledContent(AppLocalizer.string("monthlyBudget.upcoming", locale: locale), value: Formatters.currencyString(for: summary.additionalCharges))
                }
                if let margin = summary.margin {
                    LabeledContent(AppLocalizer.string(margin < 0 ? "monthlyBudget.overrun" : "monthlyBudget.margin", locale: locale), value: Formatters.currencyString(for: abs(margin)))
                        .accessibilityIdentifier("monthly-budget-explained-margin")
                }
            }
            Section {
                Text(AppLocalizer.string(summary.source == .bank ? "monthlyBudget.explanation" : "monthlyBudget.manualExplanation", locale: locale))
                NavigationLink { AllowanceExplanationView(month: month) } label: {
                    Text(AppLocalizer.string("allowance.explanation", locale: locale))
                }
                NavigationLink { BudgetSpendingListView(month: month, category: nil, source: summary.source) } label: {
                    Text(AppLocalizer.string("overview.operations.all", locale: locale))
                }
            }
        }
        .navigationTitle(AppLocalizer.string("monthlyBudget.calculation", locale: locale))
        .accessibilityIdentifier("monthly-budget-explanation")
    }
}
