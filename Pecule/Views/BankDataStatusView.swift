import SwiftUI

struct BankDataStatusView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @ObservedObject var bankSync: BankSyncService
    var accountID: UUID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let statuses = appState.bankFreshness(now: timeline.date, syncingAccountID: bankSync.activeAccountID)
                .filter { accountID == nil || $0.id == accountID }
            List {
                ForEach(statuses) { status in
                    Section(appState.externalAccount(id: status.id)?.name ?? "") {
                        Text(AppLocalizer.string("bank.freshness." + status.state.rawValue, locale: locale))
                            .foregroundStyle(status.needsAttention ? AppColors.warning : AppColors.primaryText)
                        if appState.externalAccount(id: status.id)?.isIncludedInTotals == false {
                            Text(AppLocalizer.string("bankAccount.excludedFromTotals", locale: locale)).foregroundStyle(.secondary)
                        }
                        if status.state == .awaitingSelection {
                            NavigationLink { BankConnectionView(bankSync: bankSync) } label: {
                                Text(AppLocalizer.string("bank.connection.selection", locale: locale))
                            }
                        }
                        if let cause = status.lastError {
                            LabeledContent(AppLocalizer.string("bank.freshness.lastError", locale: locale), value: cause)
                                .accessibilityIdentifier("bank-data-status-error-\(status.id)")
                        }
                        recoveryAction(for: status)
                        if status.state != .manual {
                            dateRow("bank.freshness.lastSuccess", date: status.lastSuccessfulAt)
                            dateRow("bank.freshness.lastAttempt", date: status.lastAttemptAt)
                            if let failed = status.lastFailedAt { dateRow("bank.freshness.lastFailure", date: failed) }
                            dateRow("bank.freshness.requestedFrom", date: status.requestedHistoryStart, includesTime: false)
                            dateRow("bank.freshness.firstReceived", date: status.firstReceivedAt, includesTime: false)
                            dateRow("bank.freshness.lastReceived", date: status.lastReceivedAt, includesTime: false)
                            Text(AppLocalizer.string(status.initialImportCompleted ? "bank.freshness.coverageLimited" : "bank.freshness.coverageUnknown", locale: locale))
                                .font(AppTypography.rowMeta).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("bank-data-status-\(status.id)")
                }
                if statuses.isEmpty {
                    ContentUnavailableView(AppLocalizer.string("accounts.empty.title", locale: locale), systemImage: "building.columns")
                }
            }
        }
        .navigationTitle(AppLocalizer.string("bank.freshness.title", locale: locale))
        .accessibilityIdentifier("bank-data-status-screen")
        .refreshable {
            await bankSync.refresh(appState.linkedExternalAccounts.filter { accountID == nil || $0.id == accountID }, attended: true)
        }
    }

    // A lost link is cured by a new authorization; any other failure by trying again.
    @ViewBuilder private func recoveryAction(for status: BankAccountFreshness) -> some View {
        switch status.state {
        case .needsReconnect:
            NavigationLink { BankConnectionView(bankSync: bankSync) } label: {
                Text(AppLocalizer.string("error.action.reconnect", locale: locale))
            }
            .accessibilityIdentifier("bank-data-status-reconnect-\(status.id)")
        case .failed, .partial, .stale, .notSynced:
            Button {
                let accounts = appState.linkedExternalAccounts.filter { $0.id == status.id }
                Task { await bankSync.refresh(accounts, attended: true) }
            } label: {
                Text(AppLocalizer.string("error.action.retry", locale: locale))
            }
            .disabled(bankSync.isBusy)
            .accessibilityIdentifier("bank-data-status-retry-\(status.id)")
        case .manual, .awaitingSelection, .syncing, .current, .unverified:
            EmptyView()
        }
    }

    private func dateRow(_ key: String, date: Date?, includesTime: Bool = true) -> some View {
        LabeledContent(AppLocalizer.string(key, locale: locale), value: date.map {
            includesTime ? Formatters.dateTimeString(for: $0) : Formatters.dateString(for: $0)
        } ?? AppLocalizer.string("bank.freshness.unknown", locale: locale))
    }
}

struct BankFreshnessSummaryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @ObservedObject var bankSync: BankSyncService
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let ids = Set(appState.linkedExternalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }.map(\.id))
            let statuses = appState.bankFreshness(now: timeline.date, syncingAccountID: bankSync.activeAccountID).filter { ids.contains($0.id) }
            let attention = statuses.filter(\.needsAttention).count
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if !compact { Text(AppLocalizer.string("bank.freshness.title", locale: locale)) }
                if statuses.isEmpty {
                    Text(AppLocalizer.string("bank.freshness.noIncludedAccounts", locale: locale))
                } else if attention > 0 {
                    Text(AppLocalizer.pluralFormat("bank.freshness.attention %lld %lld", locale: locale, Int64(attention), Int64(statuses.count)))
                        .foregroundStyle(AppColors.warning)
                } else {
                    Text(AppLocalizer.string(compact ? "overview.accounts.current" : "bank.freshness.allCurrent", locale: locale))
                }
                if !compact, statuses.allSatisfy({ $0.lastSuccessfulAt != nil }), let oldest = statuses.compactMap(\.lastSuccessfulAt).min() {
                    Text(AppLocalizer.format("bank.freshness.oldestSuccess %@", locale: locale, Formatters.dateTimeString(for: oldest)))
                }
            }
            .font(AppTypography.rowMeta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bank-freshness-summary")
    }
}
