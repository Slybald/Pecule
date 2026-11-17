import SwiftUI

struct DashboardAnalysisView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var presentedDestination: DashboardDestination?

    enum DashboardDestination: Hashable, Identifiable {
        case accounts
        case connection
        case budgets
        case income
        case cashflow
        case health
        case habits

        var id: Self { self }
    }

    private let columns = [
        GridItem(.flexible(), spacing: AppSpacing.lg),
        GridItem(.flexible(), spacing: AppSpacing.lg)
    ]

    var body: some View {
        Group {
            if isGloballyEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("dashboard.empty.title", locale: locale),
                    message: AppLocalizer.string("dashboard.empty.message", locale: locale),
                    systemImage: "square.grid.2x2.fill",
                    buttonTitle: AppLocalizer.string("bank.connection.title", locale: locale),
                    action: { presentedDestination = .connection },
                    tint: AppColors.accent,
                    identifier: "dashboard-empty-state"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl) {
                        Text(Formatters.monthYearString(for: Date()))
                            .font(AppTypography.screenSectionTitle)

                        bankFreshness

                        if !appState.externalAccounts.isEmpty {
                            VStack(alignment: .leading, spacing: AppSpacing.md) {
                                Text(AppLocalizer.string("dashboard.section.accounts.title", locale: locale))
                                    .font(AppTypography.screenSectionTitle)
                                    .foregroundStyle(AppColors.primaryText)

                                NavigationLink {
                                    BankAccountsView(bankSync: appState.bankSync)
                                } label: {
                                    MetricCardView(
                                        title: AppLocalizer.string("dashboard.metrics.totalBalance.title", locale: locale),
                                        value: appState.totalExternalBalance().map { Formatters.currencyString(for: $0, currencyCode: "EUR") }
                                            ?? AppLocalizer.string("bankAccount.balance.unknown", locale: locale),
                                        subtitle: AppLocalizer.pluralFormat("dashboard.metrics.totalBalance.subtitle %lld", locale: locale, appState.externalAccounts.count),
                                        systemImage: "building.columns.fill",
                                        tint: AppColors.accent
                                    )
                                }
                                .buttonStyle(.plain)
                                .privacySensitive()
                                .accessibilityIdentifier("dashboard-metric-total-balance")
                            }
                            .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard-accounts-section")
                        }

                        // Un seul résumé par rendu, et son titre vient de sa source : en mode manuel c'est un plan
                        // « saisi et prévu », pas un montant « dépensé » (mêmes clés que l'accueil).
                        let monthSummary = appState.monthlyFinancialSummary(for: Date())
                        LazyVGrid(columns: columns, spacing: AppSpacing.lg) {
                            dashboardMetric(
                                title: monthSummary.dataSource.spentLabelKey,
                                value: monthSummary.showsNoImportedOperations ? "–" : Formatters.currencyString(for: monthSummary.totalExpenses),
                                subtitle: monthSummary.showsNoImportedOperations ? "overview.noImportedOperations" : "dashboard.bank.month",
                                image: "chart.bar.fill", tint: AppColors.purchaseTint,
                                route: .budgets, identifier: "dashboard-metric-monthly-spending"
                            )
                            dashboardMetric(
                                title: "dashboard.bank.income", value: Formatters.currencyString(for: monthSummary.totalEstimatedIncome),
                                subtitle: "dashboard.bank.month", image: "banknote.fill", tint: AppColors.success,
                                route: .income, identifier: "dashboard-metric-income"
                            )
                            dashboardMetric(
                                title: "dashboard.metrics.remainingToLive.title", value: Formatters.currencyString(for: decisionMetrics.remainingToLive),
                                subtitle: "dashboard.metrics.remainingToLive.subtitle", image: "checkmark.seal.fill", tint: decisionMetrics.isOverspent ? AppColors.error : AppColors.success,
                                route: .budgets, identifier: "dashboard-metric-remaining-to-live"
                            )
                            dashboardMetric(
                                title: "dashboard.metrics.dailyAllowance.title", value: Formatters.currencyString(for: decisionMetrics.dailyAllowance),
                                subtitle: dailyAllowanceSubtitleKey, image: "sun.max.fill", tint: decisionMetrics.isOverspent ? AppColors.error : AppColors.accent,
                                route: .cashflow, identifier: "dashboard-metric-daily-allowance"
                            )
                        }

                        NavigationLink { AllowanceExplanationView(month: Date()) } label: {
                            Label(AppLocalizer.string("allowance.explanation", locale: locale), systemImage: "info.circle")
                        }.accessibilityIdentifier("dashboard-allowance-explanation")

                        // Not lazy: these two cards must exist in the hierarchy even below the fold.
                        HStack(alignment: .top, spacing: AppSpacing.lg) {
                        if let forecast = appState.cashflowForecast() {
                            NavigationLink {
                                CashflowView()
                            } label: {
                                MetricCardView(
                                    title: AppLocalizer.string("dashboard.metrics.cashflow.title", locale: locale),
                                    value: forecast.expectedClosingBalance.map { Formatters.currencyString(for: $0) }
                                        ?? (forecast.closingBalanceAvailability == .unknownBalance
                                            ? AppLocalizer.string("bankAccount.balance.unknown", locale: locale) : "–"),
                                    subtitle: cashflowSubtitle(forecast),
                                    systemImage: "chart.line.uptrend.xyaxis",
                                    tint: (forecast.expectedClosingBalance ?? .zero) < .zero ? AppColors.error : AppColors.subscriptionTint
                                )
                            }
                            .buttonStyle(.plain)
                            .privacySensitive()
                            .accessibilityIdentifier("dashboard-metric-cashflow")
                        }

                        NavigationLink {
                            FinancialHealthView()
                        } label: {
                            let score = appState.financialHealthScore()
                            MetricCardView(
                                title: AppLocalizer.string("dashboard.metrics.health.title", locale: locale),
                                value: score.grade.map { grade in
                                    score.total.map { "\(grade.rawValue) · \($0)" } ?? grade.rawValue
                                } ?? "–",
                                subtitle: score.weakestComponent.map {
                                    AppLocalizer.format("dashboard.metrics.health.subtitle %@", locale: locale, AppLocalizer.string("health.component.\($0.kind.rawValue)", locale: locale))
                                } ?? AppLocalizer.string("health.unmeasured", locale: locale),
                                systemImage: "heart.text.square.fill",
                                tint: AppColors.habitTint
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("dashboard-metric-health")
                        }



                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text(AppLocalizer.string("dashboard.section.insights.title", locale: locale))
                                .font(AppTypography.screenSectionTitle)
                                .foregroundStyle(AppColors.primaryText)

                            if appState.dashboardInsights.isEmpty {
                                Text(AppLocalizer.string("dashboard.section.insights.empty", locale: locale))
                                    .font(AppTypography.secondaryBody)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                            } else {
                                ForEach(Array(appState.dashboardInsights.prefix(1).enumerated()), id: \.element.id) { index, insight in
                                    if let route = insight.route {
                                        Button {
                                            navigation.open(route)
                                        } label: {
                                            InsightCardView(insight: insight)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityHint(AppLocalizer.string("dashboard.card.openHint", locale: locale))
                                        .accessibilityIdentifier("dashboard-insight-\(index)")
                                    } else {
                                        InsightCardView(insight: insight)
                                            .accessibilityIdentifier("dashboard-insight-\(index)")
                                    }
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard-insights-section")

                        DisclosureGroup {
                            NavigationLink { HabitsView() } label: {
                                Label(AppLocalizer.string("tab.habits", locale: locale), systemImage: "checkmark.circle")
                            }.accessibilityIdentifier("dashboard-habits-button")
                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text(AppLocalizer.string("dashboard.section.recommendations.title", locale: locale))
                                .font(AppTypography.screenSectionTitle)
                                .foregroundStyle(AppColors.primaryText)

                            if appState.dashboardRecommendations.isEmpty {
                                Text(AppLocalizer.string("dashboard.section.recommendations.empty", locale: locale))
                                    .font(AppTypography.secondaryBody)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                            } else {
                                ForEach(Array(appState.dashboardRecommendations.prefix(1).enumerated()), id: \.element.id) { index, recommendation in
                                    if let route = recommendation.route {
                                        Button {
                                            navigation.open(route)
                                        } label: {
                                            RecommendationCardView(recommendation: recommendation)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityHint(AppLocalizer.string("dashboard.card.openHint", locale: locale))
                                        .accessibilityIdentifier("dashboard-recommendation-\(index)")
                                    } else {
                                        RecommendationCardView(recommendation: recommendation)
                                            .accessibilityIdentifier("dashboard-recommendation-\(index)")
                                    }
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard-recommendations-section")

                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text(AppLocalizer.string("dashboard.section.billingSchedule.title", locale: locale))
                                .font(AppTypography.screenSectionTitle)
                                .foregroundStyle(AppColors.primaryText)

                            if appState.upcomingSubscriptions.isEmpty && appState.currentRecurringCharges.isEmpty {
                                Text(AppLocalizer.string("dashboard.section.billingSchedule.empty", locale: locale))
                                    .font(AppTypography.secondaryBody)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                            } else {
                                ForEach(appState.currentRecurringCharges.filter { $0.estimatedNextDate() >= Calendar.current.startOfDay(for: Date()) }) { charge in
                                    NavigationLink { RecurringChargeDetailView(charge: charge) } label: {
                                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                            Text(charge.label).font(AppTypography.rowTitle)
                                            Text(Formatters.currencyString(for: charge.latestAmount))
                                            Text(AppLocalizer.format("subscriptions.detected.next %@", locale: locale, Formatters.dateString(for: charge.estimatedNextDate())))
                                                .font(AppTypography.rowMeta)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(AppSpacing.lg)
                                        .appCardSurface()
                                    }.buttonStyle(.plain)
                                }
                                ForEach(appState.upcomingSubscriptions) { subscription in
                                    Button { navigation.open(.subscription(subscription.id)) } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                            Text(subscription.name)
                                                .font(AppTypography.rowTitle)
                                                .foregroundStyle(AppColors.primaryText)

                                            Text("\(subscription.category) • \(subscription.billingCycle.displayName)")
                                                .font(AppTypography.rowSubtitle)
                                                .foregroundStyle(AppColors.secondaryText)
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                                            Text(Formatters.currencyString(for: subscription.amount))
                                                .font(AppTypography.rowTitle)
                                                .foregroundStyle(AppColors.primaryText)

                                            Text(Formatters.dateString(for: subscription.nextBillingDate))
                                                .font(AppTypography.rowSubtitle)
                                                .foregroundStyle(AppColors.secondaryText)
                                        }
                                    }
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                                    }.buttonStyle(.plain)
                                    .accessibilityIdentifier("dashboard-billing-\(subscription.id.uuidString)")
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard-billing-schedule-section")

                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text(AppLocalizer.string("dashboard.section.goalsSnapshot.title", locale: locale))
                                .font(AppTypography.screenSectionTitle)
                                .foregroundStyle(AppColors.primaryText)

                            if appState.activeGoals.isEmpty {
                                Text(AppLocalizer.string("dashboard.section.goalsSnapshot.empty", locale: locale))
                                    .font(AppTypography.secondaryBody)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                            } else {
                                ForEach(appState.activeGoals) { goal in
                                    Button { navigation.open(.goal(goal.id)) } label: {
                                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                        HStack {
                                            Text(goal.title)
                                                .font(AppTypography.rowTitle)
                                                .foregroundStyle(AppColors.primaryText)

                                            Spacer()

                                            Text(Formatters.percentString(for: goal.progress))
                                                .font(AppTypography.rowSubtitle.weight(.medium))
                                                .foregroundStyle(AppColors.secondaryText)
                                        }

                                        ProgressView(value: goal.progress)
                                            .tint(AppColors.goalTint)
                                            .appAnimation(value: goal.progress)

                                        HStack {
                                            Text("\(Formatters.currencyString(for: goal.currentAmount)) of \(Formatters.currencyString(for: goal.targetAmount))")
                                            Spacer()
                                            if let date = goal.deadline() { Text(Formatters.dateString(for: date)) }
                                        }
                                        .font(AppTypography.rowMeta)
                                        .foregroundStyle(AppColors.secondaryText)
                                    }
                                    .padding(AppSpacing.lg)
                                    .appCardSurface()
                                    }.buttonStyle(.plain)
                                    .accessibilityIdentifier("dashboard-goal-\(goal.id.uuidString)")
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard-goals-snapshot-section")
                        } label: {
                            Text(AppLocalizer.string("dashboard.more", locale: locale))
                                .accessibilityIdentifier("dashboard-secondary-toggle")
                        }


                        AIAdvisorCardView(aiAdvisor: appState.aiAdvisor, appState: appState)
                    }
                    .padding(AppSpacing.lg)
                }
                .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
                .accessibilityIdentifier("dashboard-screen")
            }
        }
        .background(AppColors.groupedBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("tab.dashboard", locale: locale))
        .navigationDestination(item: $presentedDestination) { destination in
            switch destination {
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
            consumePendingRoute()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    IncomeView()
                } label: {
                    Label(AppLocalizer.string("income.title", locale: locale), systemImage: "banknote.fill")
                }
                .accessibilityLabel(AppLocalizer.string("income.title", locale: locale))
                .accessibilityIdentifier("dashboard-income-button")
            }

            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    BankAccountsView(bankSync: appState.bankSync)
                } label: {
                    Label(AppLocalizer.string("accounts.title", locale: locale), systemImage: "building.columns.fill")
                }
                .accessibilityLabel(AppLocalizer.string("accounts.title", locale: locale))
                .accessibilityIdentifier("dashboard-accounts-button")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { HabitsView() } label: { Text(AppLocalizer.string("tab.habits", locale: locale)) }
                        .accessibilityIdentifier("dashboard-habits-menu")
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(AppLocalizer.string("dashboard.more", locale: locale))
                .accessibilityIdentifier("dashboard-more-menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel(AppLocalizer.string("settings.title", locale: locale))
                .accessibilityIdentifier("dashboard-settings-button")
            }
        }
    }

    private func dashboardMetric(title: String, value: String, subtitle: String, image: String, tint: Color, route: AppNavigation.Route, identifier: String) -> some View {
        Button { navigation.open(route) } label: {
            MetricCardView(title: AppLocalizer.string(title, locale: locale), value: value,
                           subtitle: AppLocalizer.string(subtitle, locale: locale), systemImage: image, tint: tint)
        }
        .buttonStyle(.plain)
        .privacySensitive()
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var bankFreshness: some View {
        if !appState.linkedExternalAccounts.isEmpty {
            NavigationLink {
                BankDataStatusView(bankSync: appState.bankSync)
            } label: {
                BankFreshnessSummaryView(bankSync: appState.bankSync)
            }.buttonStyle(.plain).accessibilityIdentifier("dashboard-bank-freshness-button")
        }
    }

    private var decisionMetrics: DecisionMetrics {
        appState.decisionMetrics()
    }

    private var dailyAllowanceSubtitleKey: String {
        switch decisionMetrics.allowanceState {
        case .available: "dashboard.bank.daily"
        case .balanced: "dashboard.metrics.dailyAllowance.balanced"
        case .deficit: "dashboard.metrics.dailyAllowance.deficit"
        }
    }

    private func consumePendingRoute() {
        if case .habit = navigation.pendingRoute {
            presentedDestination = .habits
            return // HabitsView consumes the identifier after it appears.
        }
        guard let route = navigation.consume(where: { $0.tab == .today && $0.spendingSegment == nil }) else {
            return
        }
        switch route {
        case .income: presentedDestination = .income
        case .cashflow: presentedDestination = .cashflow
        case .health: presentedDestination = .health
        case .accounts, .budgets, .subscription, .purchase, .goal, .habit: break
        }
    }

    private func cashflowSubtitle(_ forecast: CashflowForecast) -> String {
        guard let worst = forecast.worstClosingBalance, let best = forecast.bestClosingBalance else {
            // Neither amount nor range: only why, in one sentence.
            return AppLocalizer.string(forecast.closingBalanceAvailability == .unknownBalance
                                       ? "dashboard.metrics.cashflow.noBalance" : "cashflow.forecastUnavailable", locale: locale)
        }
        guard forecast.hasDistinctClosingRange else {
            return AppLocalizer.string("dashboard.metrics.cashflow.pointEstimate", locale: locale)
        }
        return AppLocalizer.format(
            "dashboard.metrics.cashflow.subtitle %@ %@",
            locale: locale,
            Formatters.currencyString(for: worst),
            Formatters.currencyString(for: best)
        )
    }

    private var isGloballyEmpty: Bool {
        appState.subscriptions.isEmpty &&
            appState.purchases.isEmpty &&
            appState.goals.isEmpty &&
            appState.habits.isEmpty &&
            appState.externalAccounts.isEmpty
    }
}

#Preview("Dashboard") {
    NavigationStack {
        DashboardAnalysisView()
            .environmentObject(LocalizationManager())
            .environmentObject(AppNavigation())
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty Dashboard") {
    let previewState = AppState.preview
    previewState.subscriptions = []
    previewState.purchases = []
    previewState.goals = []
    previewState.habits = []

    return NavigationStack {
        DashboardAnalysisView()
            .environmentObject(LocalizationManager())
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}

#Preview("No Active Sections") {
    let previewState = AppState.preview
    previewState.subscriptions.forEach { $0.isActive = false }
    previewState.goals.forEach { $0.isArchived = true }

    return NavigationStack {
        DashboardAnalysisView()
            .environmentObject(LocalizationManager())
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}
