import SwiftUI

struct IncomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    @State private var selectedMonth = Calendar.current.peculeMonthStart(for: Date())
    @State private var presentedSheet: IncomeSheet?
    @State private var errorMessage: String?
    @State private var overridePendingDeletion: MonthlyIncomeOverride?
    @State private var sourcePendingDeletion: IncomeSource?

    private let calendar = Calendar.current

    private var monthlySummary: MonthlyFinancialSummary {
        appState.monthlyFinancialSummary(for: selectedMonth, calendar: calendar)
    }

    private var selectedMonthOverrides: [MonthlyIncomeOverride] {
        appState.monthlyIncomeOverrides(for: selectedMonth, calendar: calendar)
            .sorted { left, right in
                let leftName = incomeSourceName(for: left.incomeSourceID)
                let rightName = incomeSourceName(for: right.incomeSourceID)

                if leftName != rightName {
                    return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
                }

                return left.id.uuidString < right.id.uuidString
            }
    }

    private var displayIncomeSources: [IncomeSource] {
        appState.incomeSources.sorted { left, right in
            if left.isActive != right.isActive {
                return left.isActive && !right.isActive
            }

            if left.type.sortOrder != right.type.sortOrder {
                return left.type.sortOrder < right.type.sortOrder
            }

            let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)

            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            return left.id.uuidString < right.id.uuidString
        }
    }

    var body: some View {
        Group {
            if appState.incomeSources.isEmpty && appState.linkedExternalAccounts.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("income.empty.title", locale: locale),
                    message: AppLocalizer.string("income.empty.message", locale: locale),
                    systemImage: "banknote.fill",
                    buttonTitle: AppLocalizer.string("income.action.addSource", locale: locale),
                    action: {
                        presentedSheet = .addSource
                    },
                    tint: AppColors.accent,
                    identifier: "income-empty-state"
                )
            } else {
                List {
                    Section {
                        MonthSelectorView(
                            monthLabel: Formatters.monthYearString(for: selectedMonth),
                            locale: locale,
                            identifierPrefix: "income",
                            onPreviousMonth: {
                                shiftMonth(by: -1)
                            },
                            onCurrentMonth: {
                                selectedMonth = calendar.peculeMonthStart(for: Date())
                            },
                            onNextMonth: {
                                shiftMonth(by: 1)
                            }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))

                        IncomeSummaryCardView(summary: monthlySummary, locale: locale)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("income-summary-card")
                            .glassCard(padding: AppSpacing.lg)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }

                    if !appState.linkedExternalAccounts.isEmpty {
                        Section(AppLocalizer.string("purchases.bank.section", locale: locale)) {
                            ForEach(appState.bankTransactions(in: selectedMonth, direction: .credit).filter(\.isIncome)) { transaction in
                                NavigationLink { BankTransactionDetailView(transaction: transaction) } label: {
                                    BankTransactionRowView(transaction: transaction, accountName: appState.externalAccount(id: transaction.accountID)?.name)
                                }
                            }
                        }
                    }

                    if !appState.incomeSources.isEmpty {
                    Section {
                        if selectedMonthOverrides.isEmpty {
                            Text(AppLocalizer.string("income.adjustments.empty", locale: locale))
                                .font(AppTypography.secondaryBody)
                                .foregroundStyle(AppColors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassCard(padding: AppSpacing.lg)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                        } else {
                            ForEach(selectedMonthOverrides) { monthlyIncomeOverride in
                                Button {
                                    presentedSheet = .editOverride(monthlyIncomeOverride)
                                } label: {
                                    MonthlyIncomeOverrideRowView(
                                        monthlyIncomeOverride: monthlyIncomeOverride,
                                        sourceName: incomeSourceName(for: monthlyIncomeOverride.incomeSourceID),
                                        locale: locale
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("income-override-row-\(monthlyIncomeOverride.id.uuidString)")
                                .glassCard(padding: AppSpacing.md)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        overridePendingDeletion = monthlyIncomeOverride
                                    } label: {
                                        Label(AppLocalizer.string("Delete", locale: locale), systemImage: "trash")
                                    }
                                    .tint(AppColors.error)
                                    .accessibilityIdentifier("income-override-delete-button")
                                }
                            }
                        }
                    } header: {
                        IncomeSectionHeaderView(
                            title: AppLocalizer.string("income.section.monthlyAdjustments", locale: locale),
                            actionTitle: AppLocalizer.string("income.action.addAdjustment", locale: locale),
                            actionIdentifier: "income-add-override-button",
                            action: {
                                presentedSheet = .addOverride(selectedMonth)
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))

                    Section(AppLocalizer.string("income.section.sources", locale: locale)) {
                        ForEach(displayIncomeSources) { incomeSource in
                            Button {
                                presentedSheet = .editSource(incomeSource)
                            } label: {
                                IncomeSourceRowView(incomeSource: incomeSource, locale: locale)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("income-source-row-\(incomeSource.id.uuidString)")
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    sourcePendingDeletion = incomeSource
                                } label: {
                                    Label(AppLocalizer.string("Delete", locale: locale), systemImage: "trash")
                                }
                                .tint(AppColors.error)
                                .accessibilityIdentifier("income-source-delete-button")
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColors.background.ignoresSafeArea())
                .accessibilityIdentifier("income-screen")
            }
        }
        .navigationTitle(AppLocalizer.string("income.title", locale: locale))
        .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BudgetRulesView()
                } label: {
                    Image(systemName: "chart.pie")
                }
                .accessibilityLabel(AppLocalizer.string("budgets.title", locale: locale))
                .accessibilityIdentifier("income-budgets-button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .addSource
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalizer.string("income.action.addSource", locale: locale))
                .accessibilityIdentifier("income-add-source-button")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .addSource:
                    IncomeSourceFormView(incomeSource: nil)
                case let .editSource(incomeSource):
                    IncomeSourceFormView(incomeSource: incomeSource)
                case let .addOverride(month):
                    MonthlyIncomeOverrideFormView(monthlyIncomeOverride: nil, defaultMonth: month)
                case let .editOverride(monthlyIncomeOverride):
                    MonthlyIncomeOverrideFormView(monthlyIncomeOverride: monthlyIncomeOverride)
                }
            }
            .environmentObject(appState)
        }
        .deleteConfirmation($overridePendingDeletion, name: { incomeSourceName(for: $0.incomeSourceID) }) { deleteOverride($0) }
        .deleteConfirmation($sourcePendingDeletion, name: \.name) { deleteIncomeSource($0) }
        .alert(
            AppLocalizer.string("income.alert.updateErrorTitle", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(errorMessage ?? AppLocalizer.string("Please try again.", locale: locale))
        }
    }

    private func shiftMonth(by value: Int) {
        let shiftedMonth = calendar.date(byAdding: .month, value: value, to: selectedMonth) ?? selectedMonth
        selectedMonth = calendar.peculeMonthStart(for: shiftedMonth)
    }

    private func deleteIncomeSource(_ incomeSource: IncomeSource) {
        do {
            try appState.deleteIncomeSource(incomeSource)
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func deleteOverride(_ monthlyIncomeOverride: MonthlyIncomeOverride) {
        do {
            try appState.deleteMonthlyIncomeOverride(monthlyIncomeOverride)
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func incomeSourceName(for incomeSourceID: UUID) -> String {
        appState.incomeSources.first(where: { $0.id == incomeSourceID })?.name ?? incomeSourceID.uuidString
    }
}

#Preview("Seeded Income") {
    NavigationStack {
        IncomeView()
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty Income") {
    let previewState = AppState.preview
    previewState.incomeSources = []
    previewState.monthlyIncomeOverrides = []

    return NavigationStack {
        IncomeView()
            .environmentObject(previewState)
    }
}

private enum IncomeSheet: Identifiable {
    case addSource
    case editSource(IncomeSource)
    case addOverride(Date)
    case editOverride(MonthlyIncomeOverride)

    var id: String {
        switch self {
        case .addSource:
            return "add-source"
        case let .editSource(incomeSource):
            return "edit-source-\(incomeSource.id.uuidString)"
        case let .addOverride(month):
            return "add-override-\(month.timeIntervalSinceReferenceDate)"
        case let .editOverride(monthlyIncomeOverride):
            return "edit-override-\(monthlyIncomeOverride.id.uuidString)"
        }
    }
}

private struct IncomeSummaryCardView: View {
    let summary: MonthlyFinancialSummary
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(Formatters.monthYearString(for: summary.monthStart))
                .font(AppTypography.rowTitle)
                .foregroundStyle(AppColors.primaryText)

            if summary.dataSource != .bank {
            IncomeSummaryMetricRow(
                title: AppLocalizer.string("income.summary.recurringIncome", locale: locale),
                value: Formatters.currencyString(for: summary.recurringIncome)
            )

            IncomeSummaryMetricRow(
                title: AppLocalizer.string("income.summary.monthlyAdjustments", locale: locale),
                value: Formatters.currencyString(for: summary.monthlyIncomeAdjustments)
            )

            Divider()
            }

            IncomeSummaryMetricRow(
                title: AppLocalizer.string(summary.dataSource == .bank ? "income.bank.total" : "income.summary.total", locale: locale),
                value: Formatters.currencyString(for: summary.totalEstimatedIncome),
                isEmphasized: true
            )

            Text(AppLocalizer.string(summary.dataSource == .bank ? "income.summary.source.bank" : "income.summary.source.planned", locale: locale))
                .font(AppTypography.rowMeta)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("income-summary-source")

            if summary.unmatchedIncome > .zero {
                Text(AppLocalizer.format("income.summary.unmatchedIncome %@", locale: locale, Formatters.currencyString(for: summary.unmatchedIncome)))
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("income-summary-unmatched")
            }
        }
    }
}

private struct IncomeSummaryMetricRow: View {
    let title: String
    let value: String
    var isEmphasized = false

    var body: some View {
        HStack {
            Text(title)
                .font(isEmphasized ? AppTypography.rowSubtitle.weight(.semibold) : AppTypography.rowSubtitle)
                .foregroundStyle(isEmphasized ? AppColors.primaryText : AppColors.secondaryText)

            Spacer()

            Text(value)
                .font(isEmphasized ? AppTypography.cardTitle : AppTypography.rowTitle)
                .foregroundStyle(AppColors.primaryText)
        }
    }
}

private struct MonthlyIncomeOverrideRowView: View {
    let monthlyIncomeOverride: MonthlyIncomeOverride
    let sourceName: String
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(sourceName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Text(
                    monthlyIncomeOverride.replacesSourceAmount
                    ? AppLocalizer.string("income.override.mode.replace", locale: locale)
                    : AppLocalizer.string("income.override.mode.adjustment", locale: locale)
                )
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(AppColors.secondaryText)
            }

            Spacer()

            Text(Formatters.currencyString(for: monthlyIncomeOverride.amount))
                .font(AppTypography.rowTitle)
                .foregroundStyle(AppColors.primaryText)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}

private struct IncomeSourceRowView: View {
    let incomeSource: IncomeSource
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(incomeSource.name)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Spacer()

                Text(Formatters.currencyString(for: incomeSource.amount))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
            }

            HStack {
                Text(incomeSource.type.displayName(locale: locale))
                Spacer()
                Text(scheduleDescription)
            }
            .font(AppTypography.rowSubtitle)
            .foregroundStyle(AppColors.secondaryText)

            HStack(spacing: AppSpacing.sm) {
                IncomePillView(
                    title: incomeSource.isRecurring
                    ? AppLocalizer.string("income.badge.recurring", locale: locale)
                    : AppLocalizer.string("income.badge.oneOff", locale: locale),
                    tint: AppColors.accent
                )

                IncomePillView(
                    title: incomeSource.isActive
                    ? AppLocalizer.string("Active", locale: locale)
                    : AppLocalizer.string("Inactive", locale: locale),
                    tint: incomeSource.isActive ? AppColors.success : AppColors.secondaryText
                )
            }
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private var scheduleDescription: String {
        if !incomeSource.isRecurring {
            return AppLocalizer.format(
                "income.source.schedule.oneOff",
                locale: locale,
                Formatters.monthYearString(for: incomeSource.startDate)
            )
        }

        guard let endDate = incomeSource.endDate else {
            return AppLocalizer.format(
                "income.source.schedule.starts",
                locale: locale,
                Formatters.monthYearString(for: incomeSource.startDate)
            )
        }

        return AppLocalizer.format(
            "income.source.schedule.startsEnds",
            locale: locale,
            Formatters.monthYearString(for: incomeSource.startDate),
            Formatters.monthYearString(for: endDate)
        )
    }
}

private struct IncomePillView: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(AppTypography.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.pill, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }
}

private struct IncomeSectionHeaderView: View {
    let title: String
    let actionTitle: String
    let actionIdentifier: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            Button(actionTitle, action: action)
                .font(.footnote.weight(.semibold))
                .textCase(.none)
                .accessibilityIdentifier(actionIdentifier)
        }
    }
}
