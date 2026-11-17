import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var presentedSheet: SubscriptionSheet?
    @State private var errorMessage: String?
    @State private var subscriptionPendingDeletion: Subscription?

    var body: some View {
        Group {
            if appState.subscriptions.isEmpty && appState.recurringCharges.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("No subscriptions yet", locale: locale),
                    message: AppLocalizer.string("Track your recurring expenses to understand your monthly commitments.", locale: locale),
                    systemImage: "repeat.circle.fill",
                    buttonTitle: AppLocalizer.string("Add Subscription", locale: locale),
                    action: {
                        presentedSheet = .add
                    },
                    tint: AppColors.subscriptionTint,
                    identifier: "subscriptions-empty-state"
                )
            } else {
                List {
                    Section(AppLocalizer.string("Alerts", locale: locale)) {
                        SubscriptionInsightRow(
                            title: AppLocalizer.string(appState.linkedExternalAccounts.isEmpty ? "Annual Total" : "subscriptions.detected.annual", locale: locale),
                            message: Formatters.currencyString(for: appState.linkedExternalAccounts.isEmpty ? appState.annualSubscriptionCost : appState.estimatedAnnualRecurringCost),
                            tint: AppColors.accent
                        )
                        .glassCard(padding: AppSpacing.md)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))

                        if !appState.expensiveSubscriptions.isEmpty {
                            SubscriptionInsightRow(
                                title: AppLocalizer.string("Heads Up", locale: locale),
                                message: AppLocalizer.format(
                                    "Expensive subscriptions: %@",
                                    locale: locale,
                                    appState.expensiveSubscriptions.map(\.name).joined(separator: ", ")
                                ),
                                tint: AppColors.warning
                            )
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                        }

                        if !appState.untrackedRecurringCharges.isEmpty {
                            SubscriptionInsightRow(
                                title: AppLocalizer.string("subscriptions.alerts.untracked.title", locale: locale),
                                message: AppLocalizer.format(
                                    "subscriptions.alerts.untracked %@",
                                    locale: locale,
                                    appState.untrackedRecurringCharges.map(\.label).joined(separator: ", ")
                                ),
                                tint: AppColors.warning
                            )
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            .accessibilityIdentifier("subscriptions-alert-untracked")
                        }

                        if !appState.recurringChargesWithPriceIncrease.isEmpty {
                            SubscriptionInsightRow(
                                title: AppLocalizer.string("subscriptions.alerts.priceIncrease.title", locale: locale),
                                message: AppLocalizer.format(
                                    "subscriptions.alerts.priceIncrease %@",
                                    locale: locale,
                                    appState.recurringChargesWithPriceIncrease.map { charge in
                                        "\(charge.label) \(Formatters.currencyString(for: charge.previousAmount)) → \(Formatters.currencyString(for: charge.latestAmount))"
                                    }.joined(separator: ", ")
                                ),
                                tint: AppColors.error
                            )
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            .accessibilityIdentifier("subscriptions-alert-price-increase")
                        }

                        if !appState.duplicateSubscriptionGroups.isEmpty {
                            SubscriptionInsightRow(
                                title: AppLocalizer.string("Potential Duplicates", locale: locale),
                                message: AppLocalizer.format(
                                    "Potential duplicates: %@",
                                    locale: locale,
                                    duplicateNames.joined(separator: ", ")
                                ),
                                tint: AppColors.error
                            )
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                        }
                    }
                    .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))

                    if !appState.currentRecurringCharges.isEmpty {
                        Section(AppLocalizer.string("subscriptions.detected.section", locale: locale)) {
                            ForEach(appState.currentRecurringCharges) { charge in
                                NavigationLink {
                                    RecurringChargeDetailView(charge: charge)
                                } label: {
                                RecurringChargeRowView(charge: charge, isUntracked: appState.untrackedRecurringCharges.contains { $0.id == charge.id })
                                }
                                    .glassCard(padding: AppSpacing.md)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                                    .accessibilityIdentifier("subscriptions-detected-\(charge.id)")
                            }
                        }
                    }

                    if !appState.historicalRecurringCharges.isEmpty {
                        Section {
                            ForEach(appState.historicalRecurringCharges) { charge in
                                NavigationLink { RecurringChargeDetailView(charge: charge) } label: {
                                    RecurringChargeRowView(charge: charge, isUntracked: false)
                                }
                            }
                        } header: {
                            Text(AppLocalizer.string("subscriptions.history.title", locale: locale))
                        } footer: {
                            Text(AppLocalizer.string("subscriptions.history.message", locale: locale))
                        }
                    }

                    Section(AppLocalizer.string("Subscriptions", locale: locale)) {
                        ForEach(appState.displaySubscriptions) { subscription in
                            Button {
                                presentedSheet = .edit(subscription)
                            } label: {
                                SubscriptionRowView(subscription: subscription)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("subscription-row-\(subscription.id.uuidString)")
                            .glassCard(padding: AppSpacing.md)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    subscriptionPendingDeletion = subscription
                                } label: {
                                    Label(AppLocalizer.string("Delete", locale: locale), systemImage: "trash")
                                }
                                .tint(AppColors.error)
                                .accessibilityIdentifier("subscriptions-delete-button")
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColors.background.ignoresSafeArea())
                .accessibilityIdentifier("subscriptions-list")
            }
        }
        .navigationTitle(AppLocalizer.string("Subscriptions", locale: locale))
        .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalizer.string("Add Subscription", locale: locale))
                .accessibilityIdentifier("subscriptions-add-button")
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            consumePendingRoute()
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .add:
                    SubscriptionFormView(subscription: nil)
                case let .edit(subscription):
                    SubscriptionFormView(subscription: subscription)
                }
            }
            .environmentObject(appState)
        }
        .deleteConfirmation($subscriptionPendingDeletion, name: \.name) { deleteSubscription($0) }
        .alert(
            AppLocalizer.string("Unable to Update Subscription", locale: locale),
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

    private var duplicateNames: [String] {
        appState.duplicateSubscriptionGroups.compactMap { group in
            group.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func deleteSubscription(_ subscription: Subscription) {
        do {
            try appState.deleteSubscription(subscription)
        } catch {
            errorMessage = error.userMessage
        }
    }
    private func consumePendingRoute() {
        guard let route = navigation.consume(where: { if case .subscription = $0 { return true } else { return false } }),
              case .subscription(let id) = route,
              let id,
              let item = appState.subscriptions.first(where: { $0.id == id }) else {
            return
        }
        presentedSheet = .edit(item)
    }

}

private struct SubscriptionInsightRow: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(AppTypography.rowSubtitle.weight(.semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(AppTypography.secondaryBody)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
            .environmentObject(AppNavigation())
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty") {
    let previewState = AppState.preview
    previewState.subscriptions = []

    return NavigationStack {
        SubscriptionsView()
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}

private enum SubscriptionSheet: Identifiable {
    case add
    case edit(Subscription)

    var id: String {
        switch self {
        case .add:
            return "add"
        case let .edit(subscription):
            return subscription.id.uuidString
        }
    }
}

private struct SubscriptionRowView: View {
    let subscription: Subscription
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(subscription.name)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Spacer()

                Text(subscription.isActive ? AppLocalizer.string("Active", locale: locale) : AppLocalizer.string("Paused", locale: locale))
                    .font(AppTypography.badge)
                    .padding(.horizontal, 10)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.pill, style: .continuous)
                            .fill(
                                subscription.isActive
                                ? AppColors.success.opacity(0.15)
                                : AppColors.secondaryText.opacity(0.12)
                            )
                    )
                    .foregroundStyle(subscription.isActive ? AppColors.success : AppColors.secondaryText)
            }

            HStack {
                Text(subscription.categoryDisplayName(locale: locale))
                Spacer()
                Text(subscription.billingCycle.displayName)
            }
            .font(AppTypography.rowSubtitle)
            .foregroundStyle(AppColors.secondaryText)

            HStack {
                Text(Formatters.currencyString(for: subscription.amount))
                    .font(AppTypography.rowSubtitle.weight(.medium))
                    .foregroundStyle(AppColors.primaryText)
                Spacer()
                Text(AppLocalizer.format(subscription.nextBillingDate < Calendar.current.startOfDay(for: Date()) ? "subscriptions.manual.overdue %@" : "Next: %@", locale: locale, Formatters.dateString(for: subscription.nextBillingDate)))
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

private struct RecurringChargeRowView: View {
    let charge: RecurringCharge
    let isUntracked: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(charge.label)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
                    .lineLimit(1)
                Text(AppLocalizer.format(
                    "subscriptions.detected.meta %@ %lld %@",
                    locale: locale,
                    AppLocalizer.string(charge.cadence == .monthly ? "subscriptions.detected.cadence.monthly" : "subscriptions.detected.cadence.yearly", locale: locale),
                    charge.occurrences,
                    Formatters.dateString(for: charge.lastDate)
                ))
                .font(AppTypography.rowMeta)
                .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                Text(Formatters.currencyString(for: charge.latestAmount))
                    .font(AppTypography.rowTitle.weight(.semibold))
                    .foregroundStyle(AppColors.primaryText)
                HStack(spacing: AppSpacing.xs) {
                    if let increase = charge.priceIncrease {
                        StatusPillView(text: AppLocalizer.format("subscriptions.detected.increase %@", locale: locale, Formatters.currencyString(for: increase)), tint: AppColors.error)
                    }
                    if !charge.isCurrent(on: Date()) {
                        StatusPillView(text: AppLocalizer.string("subscriptions.history.status", locale: locale), tint: AppColors.neutral)
                    } else if isUntracked {
                        StatusPillView(text: AppLocalizer.string("subscriptions.detected.untracked", locale: locale), tint: AppColors.warning)
                    } else {
                        StatusPillView(text: AppLocalizer.string("subscriptions.detected.tracked", locale: locale), tint: AppColors.success)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecurringChargeDetailView: View {
    let charge: RecurringCharge
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section {
                Text(AppLocalizer.string(charge.isCurrent(on: Date()) ? "subscriptions.detected.explanation" : "subscriptions.history.message", locale: locale))
                if charge.isCurrent(on: Date()), charge.estimatedNextDate() >= Calendar.current.startOfDay(for: Date()) {
                    Text(AppLocalizer.format("subscriptions.detected.next %@", locale: locale, Formatters.dateString(for: charge.estimatedNextDate())))
                }
            }
            Section(AppLocalizer.string("purchases.bank.section", locale: locale)) {
                ForEach(appState.transactions(for: charge)) { transaction in
                    NavigationLink { BankTransactionDetailView(transaction: transaction) } label: {
                        BankTransactionRowView(transaction: transaction, accountName: appState.externalAccount(id: transaction.accountID)?.name)
                    }
                }
            }
        }
        .navigationTitle(charge.label)
        .accessibilityIdentifier("recurring-charge-detail")
    }
}
