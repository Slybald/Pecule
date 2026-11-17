import SwiftUI

struct BudgetRulesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var showsMonthlyBudget = false
    @State private var editingCategory: ExpenseCategory?
    @State private var errorMessage: String?
    @State private var month = Calendar.current.peculeMonthStart(for: Date())

    private let calendar = Calendar.current

    private var rows: [BudgetOverviewRow] {
        appState.budgetOverview(for: month, calendar: calendar)
    }

    var body: some View {
        let rows = rows
        let totals = BudgetOverviewService.totals(of: rows)
        let monthBudget = appState.monthlyBudget(on: month)
        let visibleRows = rows.filter { $0.plannedAmount != nil || $0.spentAmount != .zero || $0.refundedAmount != .zero }
        List {
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    SpendingMonthPicker(month: $month)
                    Button { showsMonthlyBudget = true } label: {
                        Text(appState.monthlySpendingLimit(for: month).map {
                            AppLocalizer.format("monthlyBudget.edit %@", locale: locale, Formatters.currencyString(for: $0))
                        } ?? AppLocalizer.string("monthlyBudget.set", locale: locale))
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("budget-monthly-limit")
                    if let margin = monthBudget.margin {
                        NavigationLink { MonthlyBudgetExplanationView(month: month) } label: {
                            Text(AppLocalizer.format(margin < 0 ? "budgets.overrun %@" : "budgets.remaining %@", locale: locale, Formatters.currencyString(for: abs(margin))))
                        }.accessibilityIdentifier("budget-monthly-margin")
                    }
                    Text(AppLocalizer.string(monthBudget.source.spentLabelKey, locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                    if monthBudget.showsNoImportedOperations {
                        // Un zéro sans aucune opération importée ne dit pas « rien dépensé » : il dit « pas de données ».
                        Text(AppLocalizer.string("overview.noImportedOperations", locale: locale))
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("budget-no-imported-operations")
                    } else {
                        OverviewAmountView(value: Formatters.currencyString(for: totals.spent))
                            .accessibilityIdentifier("budget-overview-amount")
                    }
                    Text(rows.contains(where: { $0.plannedAmount != nil })
                         ? AppLocalizer.format("overview.budget.categoryLimits %@", locale: locale, Formatters.currencyString(for: totals.planned))
                         : AppLocalizer.string("budgets.summary.noLimits", locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                    // Nommer la destination plutôt que poser une notice : l'écran existe, il n'explique
                    // pas celui-ci.
                    NavigationLink { AllowanceExplanationView(month: month) } label: {
                        Text(AppLocalizer.string("dashboard.metrics.remainingToLive.title", locale: locale))
                            .font(AppTypography.rowMeta)
                    }.accessibilityIdentifier("budget-allowance-explanation")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("budgets-summary")
            }

            Section {
                NavigationLink { GoalAllocationView() } label: {
                    Label(AppLocalizer.string("allocation.title", locale: locale), systemImage: "arrow.triangle.branch")
                }.accessibilityIdentifier("budget-allocation")
                NavigationLink { ProvisionsView() } label: {
                    LabeledContent(AppLocalizer.string("provision.title", locale: locale), value: Formatters.currencyString(for: appState.provisionSummaries().reduce(0) { $0 + $1.reserved }))
                }.accessibilityIdentifier("budget-provisions")
                NavigationLink { PurchaseSimulationsView() } label: {
                    Label(AppLocalizer.string("simulation.title", locale: locale), systemImage: "slider.horizontal.3")
                }.accessibilityIdentifier("budget-simulations")
                NavigationLink { CommitmentsView() } label: {
                    Label(AppLocalizer.string("commitments.title", locale: locale), systemImage: "calendar.badge.clock")
                }.accessibilityIdentifier("budget-commitments")
            }
            Section(AppLocalizer.string("overview.budget.categories", locale: locale)) {
                ForEach(visibleRows) { row in
                    NavigationLink {
                        BudgetSpendingListView(month: month, category: row.category, source: monthBudget.source)
                    } label: {
                        BudgetRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("budget-row-\(row.category.rawValue)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            editingCategory = row.category
                        } label: {
                            Label(AppLocalizer.string("Edit", locale: locale), systemImage: "pencil")
                        }
                        .accessibilityIdentifier("budget-edit-\(row.category.rawValue)")
                        if let rule = appState.budgetRule(for: row.category.storageValue) {
                            Button(role: .destructive) {
                                do {
                                    try appState.deleteBudgetRule(rule)
                                } catch {
                                    errorMessage = error.userMessage
                                }
                            } label: {
                                Label(AppLocalizer.string("budgetForm.remove", locale: locale), systemImage: "trash")
                            }
                            .accessibilityIdentifier("budget-remove-\(row.category.rawValue)")
                        }
                    }
                }
                if visibleRows.isEmpty {
                    Text(AppLocalizer.string("overview.budget.empty", locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                NavigationLink {
                    BudgetSpendingListView(month: month, category: nil, source: monthBudget.source)
                } label: {
                    Text(AppLocalizer.string("overview.operations.all", locale: locale))
                }
                .accessibilityIdentifier("budget-all-operations")
                .listRowBackground(Color.clear)
                // Une ligne de liste, et non plus un lien flottant qui recouvrait la dernière
                // catégorie au défilement.
                NavigationLink { CategoryCatalogView() } label: {
                    Label(AppLocalizer.string("category.manage", locale: locale), systemImage: "tag")
                }
                .accessibilityIdentifier("budget-category-catalog")
                .listRowBackground(Color.clear)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(appState.availableCategories) { category in
                        Button(category.displayName(locale: locale)) { editingCategory = category }
                    }
                } label: { Label(AppLocalizer.string("budgets.editLimit", locale: locale), systemImage: "gauge.with.needle") }
                .accessibilityIdentifier("budgets-edit-menu")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.overviewBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("budgets.title", locale: locale))
        .accessibilityIdentifier("budgets-screen")
        .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            _ = navigation.consume(where: { $0 == .budgets })
        }
        .sheet(isPresented: $showsMonthlyBudget) {
            NavigationStack { MonthlyBudgetFormView(month: month) }
        }
        .sheet(item: $editingCategory) { category in
            NavigationStack {
                BudgetRuleFormView(category: category)
            }
            .environmentObject(appState)
        }
        .alert(
            AppLocalizer.string("common.error.save", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct BudgetRowView: View {
    let row: BudgetOverviewRow
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.category.displayName(locale: locale))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
                Spacer()
                Text(amountText)
                    .font(AppTypography.rowSubtitle.weight(.semibold))
                    .foregroundStyle(row.isOverspent ? AppColors.error : AppColors.primaryText)
                    .accessibilityIdentifier("budget-amount-\(row.category.rawValue)")
            }
            if row.plannedAmount != nil {
                ProgressView(value: max(0, min(row.utilizationRatio, 1)))
                    .tint(tint)
            } else if row.spentAmount > .zero {
                Text(AppLocalizer.string("budgets.row.noLimit", locale: locale))
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
            }
            if let remaining = row.remainingAmount {
                Text(AppLocalizer.format(remaining < 0 ? "budgets.overrun %@" : "budgets.remaining %@", locale: locale, Formatters.currencyString(for: abs(remaining))))
                    .font(AppTypography.rowMeta).foregroundStyle(row.isOverspent ? AppColors.error : AppColors.secondaryText)
            }
            if row.refundedAmount != .zero {
                Text(AppLocalizer.format("budgets.refundDetail %@ %@", locale: locale, Formatters.currencyString(for: row.grossSpentAmount), Formatters.currencyString(for: row.refundedAmount)))
                    .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .padding(.vertical, AppSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var amountText: String {
        let spent = Formatters.currencyString(for: row.spentAmount)
        guard let planned = row.plannedAmount else {
            return AppLocalizer.format("budgets.row.spent %@", locale: locale, spent)
        }
        return AppLocalizer.format("budgets.row.spentOf %@ %@", locale: locale, spent, Formatters.currencyString(for: planned))
    }

    private var tint: Color {
        if row.isOverspent {
            return AppColors.error
        }
        return row.utilizationRatio >= 0.8 ? AppColors.warning : AppColors.accent
    }
}

struct BudgetRuleFormView: View {
    let category: ExpenseCategory

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var isAmountFocused: Bool
    @State private var amountText = ""
    @State private var touched = false
    @State private var errorMessage: String?

    private var existingRule: BudgetRule? {
        appState.budgetRule(for: category.storageValue)
    }

    private var parsedAmount: Decimal? {
        guard let value = Formatters.decimalValue(from: amountText, prefilledWith: existingRule?.monthlyAmount), value >= .zero else {
            return nil
        }
        return value
    }

    var body: some View {
        Form {
            Section {
                TextField(Formatters.amountPlaceholder(locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)
                    .accessibilityLabel(AppLocalizer.string("budgetForm.amount.label", locale: locale))
                    .accessibilityIdentifier("budget-form-amount-field")
                if touched, parsedAmount == nil {
                    FormValidationMessageView(message: AppLocalizer.string("budgetForm.amount.error", locale: locale))
                        .accessibilityIdentifier("budget-form-amount-error")
                }
            } header: {
                Text(AppLocalizer.string("budgetForm.amount.label", locale: locale))
            } footer: {
                // La règle n'est pas datée : la modifier depuis un mois la change pour tous les mois (m070).
                Text(AppLocalizer.string("budgetForm.appliesToAllMonths", locale: locale))
                    .accessibilityIdentifier("budget-form-applies-to-all-months")
            }

            if let existingRule {
                Section {
                    Button(role: .destructive) {
                        do {
                            try appState.deleteBudgetRule(existingRule)
                            dismiss()
                        } catch {
                            errorMessage = error.userMessage
                        }
                    } label: {
                        Label(AppLocalizer.string("budgetForm.remove", locale: locale), systemImage: "trash")
                    }
                    .accessibilityIdentifier("budget-form-remove-button")
                }
            }
        }
        .navigationTitle("\(AppLocalizer.string("budgetForm.title", locale: locale)) · \(category.displayName(locale: locale))")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("budget-form-cancel-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    save()
                }
                .disabled(parsedAmount == nil)
                .accessibilityIdentifier("budget-form-save-button")
            }
        }
        .onChange(of: isAmountFocused) { previous, _ in
            if previous {
                touched = true
            }
        }
        .onAppear {
            if let existingRule {
                amountText = Formatters.decimalString(for: existingRule.monthlyAmount)
            }
        }
        .alert(
            AppLocalizer.string("common.error.save", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        guard let parsedAmount else {
            return
        }
        do {
            try appState.setBudgetRule(category: category.storageValue, monthlyAmount: parsedAmount)
            AppHaptics.play(.success)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
