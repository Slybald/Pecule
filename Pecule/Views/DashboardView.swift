import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var showsBudgetForm = false
    @State private var destination: DashboardAnalysisView.DashboardDestination?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            let summary = appState.monthlyBudget(on: now, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    Text(Formatters.monthYearString(for: now))
                        .font(AppTypography.screenSectionTitle)
                    budgetHero(summary, month: now)
                    if !appState.linkedExternalAccounts.isEmpty {
                        NavigationLink { BankDataStatusView(bankSync: appState.bankSync) } label: {
                            BankFreshnessSummaryView(bankSync: appState.bankSync, compact: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("dashboard-bank-freshness-button")
                    }
                    if !appState.externalAccounts.isEmpty {
                        Button { navigation.open(.accounts) } label: {
                            HStack {
                                Text(AppLocalizer.string("accounts.totalBalance", locale: locale))
                                Spacer()
                                Text(appState.totalExternalBalance().map { Formatters.currencyString(for: $0) }
                                     ?? AppLocalizer.string("bankAccount.balance.unknown", locale: locale))
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                            }.font(AppTypography.secondaryBody)
                        }.accessibilityIdentifier("dashboard-accounts-button").privacySensitive()
                    }
                    Divider()
                    trajectory(summary, on: now)
                    NavigationLink { TreasuryCalendarView() } label: {
                        Label(AppLocalizer.string("treasury.title", locale: locale), systemImage: "calendar")
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("dashboard-calendar")
                    upcoming(summary)
                    if appState.externalAccounts.isEmpty {
                        NavigationLink { BankConnectionView(bankSync: appState.bankSync) } label: {
                            Label(AppLocalizer.string("bank.connection.title", locale: locale), systemImage: "building.columns")
                                .frame(minHeight: 44)
                        }.accessibilityIdentifier("dashboard-connect-bank")
                        // La version longue reste dans l'explication du calcul, à la demande.
                        Text(AppLocalizer.string("monthlyBudget.manualBasisShort", locale: locale))
                            .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("dashboard-empty-state")
                    }
                }
                .padding(AppSpacing.lg)
            }
            .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
            .accessibilityIdentifier("dashboard-screen")
        }
        .background(AppColors.overviewBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("tab.today", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { HabitsView() } label: { Text(AppLocalizer.string("tab.habits", locale: locale)) }
                        .accessibilityIdentifier("dashboard-habits-menu")
                    NavigationLink { IncomeView() } label: { Text(AppLocalizer.string("income.title", locale: locale)) }
                        .accessibilityIdentifier("dashboard-income-button")
                    NavigationLink { DashboardAnalysisView() } label: { Text(AppLocalizer.string("monthlyBudget.analyses", locale: locale)) }
                        .accessibilityIdentifier("dashboard-analyses-button")
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(AppLocalizer.string("dashboard.more", locale: locale))
                .accessibilityIdentifier("dashboard-more-menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(AppLocalizer.string("settings.title", locale: locale))
                    .accessibilityIdentifier("dashboard-settings-button")
            }
        }
        .sheet(isPresented: $showsBudgetForm) {
            NavigationStack { MonthlyBudgetFormView(month: Date()) }
        }
        .navigationDestination(item: $destination) { target in
            switch target {
            case .accounts: BankAccountsView(bankSync: appState.bankSync)
            case .connection: BankConnectionView(bankSync: appState.bankSync)
            case .budgets: BudgetRulesView()
            case .income: IncomeView()
            case .cashflow: CashflowView()
            case .health: FinancialHealthView()
            case .habits: HabitsView()
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            if case .habit = navigation.pendingRoute { destination = .habits; return }
            guard let route = navigation.consume(where: { $0.tab == .today && $0.spendingSegment == nil }) else { return }
            switch route {
            case .income: destination = .income
            case .cashflow: destination = .cashflow
            case .health: destination = .health
            default: break
            }
        }
    }

    private func budgetHero(_ summary: MonthlyBudgetSummary, month: Date) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            if let margin = summary.margin {
                Text(AppLocalizer.string(margin < 0 ? "monthlyBudget.overrun" : "monthlyBudget.margin", locale: locale))
                    .font(AppTypography.secondaryBody).foregroundStyle(AppColors.secondaryText)
                NavigationLink { MonthlyBudgetExplanationView(month: month) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        OverviewAmountView(value: Formatters.currencyString(for: abs(margin)), tint: margin < 0 ? AppColors.error : AppColors.primaryText)
                        Image(systemName: "info.circle").font(.body)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("dashboard-budget-margin")
                Text(AppLocalizer.string(summary.source == .bank ? "monthlyBudget.afterCharges" : "monthlyBudget.manualBasis", locale: locale))
                    .font(AppTypography.secondaryBody).foregroundStyle(AppColors.secondaryText)
                Button { showsBudgetForm = true } label: {
                    Text(AppLocalizer.format("monthlyBudget.edit %@", locale: locale, Formatters.currencyString(for: summary.limit ?? .zero)))
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("dashboard-budget-edit")
            } else {
                Text(AppLocalizer.string("monthlyBudget.noLimit", locale: locale))
                    .font(AppTypography.sectionTitle)
                Button { showsBudgetForm = true } label: {
                    Label(AppLocalizer.string("monthlyBudget.set", locale: locale), systemImage: "plus")
                        .frame(minHeight: 44)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("dashboard-budget-edit")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func trajectory(_ summary: MonthlyBudgetSummary, on date: Date) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Button { navigation.open(.budgets) } label: {
                HStack {
                    Text(AppLocalizer.string(summary.source.spentLabelKey, locale: locale))
                    Spacer()
                    if summary.showsNoImportedOperations {
                        // Un zéro sans aucune opération importée ne dit pas « rien dépensé » : il dit « pas de données ».
                        Text(AppLocalizer.string("overview.noImportedOperations", locale: locale))
                            .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(Formatters.currencyString(for: summary.expenses)).monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                }.font(AppTypography.rowTitle).frame(minHeight: 44)
            }.accessibilityIdentifier("dashboard-metric-monthly-spending")
            if summary.source == .bank && !summary.showsNoImportedOperations {
                let points = appState.monthlySpendingTrajectory(on: date)
                let scale = MonthlyBudgetService.chartScale(points: points, knownTotal: summary.knownTotal, limit: summary.limit)
                let caption = scale.showsLimit || summary.limit == nil
                    ? AppLocalizer.format("monthlyBudget.knownTotal %@", locale: locale, Formatters.currencyString(for: summary.knownTotal))
                    : AppLocalizer.format("monthlyBudget.knownTotalOfLimit %@ %@", locale: locale,
                                          Formatters.currencyString(for: summary.knownTotal),
                                          Formatters.currencyString(for: summary.limit ?? .zero))
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("EUR", NSDecimalNumber(decimal: point.amount).doubleValue))
                            .foregroundStyle(AppColors.accent)
                            .accessibilityLabel(Formatters.dateString(for: point.date))
                            .accessibilityValue(Formatters.currencyString(for: point.amount))
                    }
                    if let limit = summary.limit, scale.showsLimit {
                        RuleMark(y: .value("EUR", NSDecimalNumber(decimal: limit).doubleValue))
                            .foregroundStyle(AppColors.secondaryText)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .accessibilityLabel(AppLocalizer.string("monthlyBudget.limit", locale: locale))
                            .accessibilityValue(Formatters.currencyString(for: limit))
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                .chartYScale(domain: NSDecimalNumber(decimal: scale.floor).doubleValue ... NSDecimalNumber(decimal: scale.ceiling).doubleValue)
                .frame(height: 150)
                .accessibilityChartDescriptor(AmountOverTimeChartDescriptor(
                    title: AppLocalizer.string("chart.spending.title", locale: locale),
                    summary: caption,
                    seriesName: AppLocalizer.string("chart.spending.title", locale: locale),
                    xTitle: AppLocalizer.string("chart.axis.date", locale: locale),
                    yTitle: AppLocalizer.string("chart.axis.amount", locale: locale),
                    points: points.map { .init(date: $0.date, amount: NSDecimalNumber(decimal: $0.amount).doubleValue) }
                ))
                .accessibilityIdentifier("dashboard-spending-trajectory")
                Text(caption)
                    .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private func upcoming(_ summary: MonthlyBudgetSummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            NavigationLink { CommitmentsView() } label: {
                Text(AppLocalizer.string("monthlyBudget.upcoming", locale: locale)).font(AppTypography.screenSectionTitle)
            }.accessibilityIdentifier("dashboard-commitments")
            if summary.upcoming.isEmpty {
                Text(AppLocalizer.string("monthlyBudget.noUpcoming", locale: locale))
                    .font(AppTypography.secondaryBody).foregroundStyle(AppColors.secondaryText)
            }
            ForEach(summary.upcoming) { charge in
                NavigationLink { CommitmentDetailView(commitmentID: charge.id) } label: {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack {
                            Text(charge.name)
                            Spacer()
                            Text(Formatters.currencyString(for: charge.amount)).monospacedDigit()
                        }.font(AppTypography.rowTitle)
                        Text(Formatters.dateString(for: charge.date))
                            .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
                    }.padding(.vertical, AppSpacing.sm).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("dashboard-charge-\(charge.id)")
                Divider()
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("dashboard-billing-schedule-section")
    }
}
