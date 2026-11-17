import SwiftUI

struct BankAccountsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject var bankSync: BankSyncService
    @Environment(\.locale) private var locale
    @State private var showsConnection = false
    var body: some View {
        Group {
            if appState.externalAccounts.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("accounts.empty.title", locale: locale),
                    message: AppLocalizer.string("accounts.empty.message", locale: locale),
                    systemImage: "building.columns.fill",
                    buttonTitle: AppLocalizer.string("bank.connection.title", locale: locale),
                    buttonIdentifier: "accounts-connect-bank",
                    action: { showsConnection = true },
                    tint: AppColors.accent,
                    identifier: "accounts-empty-state"
                )
            } else {
                List {
                    Section {
                        summaryCard
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(appState.externalAccounts) { account in
                            NavigationLink {
                                BankAccountHistoryView(accountID: account.id)
                            } label: {
                                BankAccountCardView(account: account, isSyncing: bankSync.activeAccountID == account.id)
                            }
                                .listRowBackground(Color.clear)
                        }
                    }

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .appHaptic(.success, trigger: bankSync.lastSyncDate)
                .appHaptic(.error, trigger: bankSync.errorMessage)
                .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
                    _ = navigation.consume(where: { $0 == .accounts })
                }
                .refreshable {
                    await bankSync.refresh(appState.linkedExternalAccounts, attended: true)
                }
                .accessibilityIdentifier("accounts-list")
            }
        }
        .sheet(isPresented: $showsConnection) {
            NavigationStack { BankConnectionView(bankSync: bankSync) }
        }
        .background(AppColors.overviewBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("accounts.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigation.selectedTab = .operations } label: {
                    Label(AppLocalizer.string("operations.title", locale: locale), systemImage: "magnifyingglass")
                }.accessibilityIdentifier("accounts-operations-button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts-screen")
        .bankSyncErrorAlert(bankSync) { showsConnection = true }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AppLocalizer.string("accounts.totalBalance", locale: locale))
                .font(AppTypography.cardTitle)
                .foregroundStyle(AppColors.secondaryText)
            if bankSync.isBusy && appState.totalExternalBalance() == nil {
                SkeletonView(lines: 1, lineHeight: 28, lastLineWidth: 140)
                    .accessibilityIdentifier("accounts-total-balance-skeleton")
            } else {
                OverviewAmountView(value: totalBalanceText)
                    .accessibilityIdentifier("accounts-total-balance")
            }
            HStack {
                NavigationLink {
                    BankDataStatusView(bankSync: bankSync)
                } label: {
                    BankFreshnessSummaryView(bankSync: bankSync, compact: true)
                }.buttonStyle(.plain)
                Spacer()
                if bankSync.isBusy {
                    ProgressView()
                        .tint(AppColors.accent)
                } else {
                    Button {
                        Task { await bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .accessibilityLabel(AppLocalizer.string("settings.bankAccounts.refresh", locale: locale))
                    .accessibilityIdentifier("accounts-refresh-button")
                }
            }
        }
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts-summary-card")
    }

    private var totalBalanceText: String {
        guard let total = appState.totalExternalBalance() else {
            return AppLocalizer.string("bankAccount.balance.unknown", locale: locale)
        }
        return Formatters.currencyString(for: total, currencyCode: "EUR")
    }

}

struct BankCategoryPickerView: View {
    let transaction: BankTransaction
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var errorMessage: String?

    var body: some View {
        List(appState.availableCategories) { category in
            Button {
                do {
                    try appState.setBankTransaction(transaction, category: category)
                    dismiss()
                } catch {
                    errorMessage = error.userMessage
                }
            } label: {
                HStack {
                    Text(category.displayName(locale: locale))
                        .foregroundStyle(.primary)
                    Spacer()
                    if ExpenseCategory.canonicalCategory(for: transaction.category) == category {
                        Image(systemName: "checkmark")
                            .foregroundStyle(AppColors.accent)
                    }
                }
            }
            .accessibilityIdentifier("bank-category-row-\(category.rawValue)")
        }
        .navigationTitle(AppLocalizer.string("accounts.action.category", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("bank-category-cancel-button")
            }
        }
        .alert(
            AppLocalizer.string("settings.bankAccounts.error.title", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityIdentifier("bank-category-picker")
    }
}

private struct BankAccountCardView: View {
    let account: ExternalAccount
    var isSyncing = false
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(account.shortDisplayName(locale: locale))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
                Text(account.normalizedInstitution?.displayName(locale: locale) ?? account.institution)
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                if account.balance == nil && isSyncing && !account.isManual {
                    SkeletonView(lines: 1, lineHeight: 18, lastLineWidth: 90)
                } else {
                    Text(balanceText)
                        .font(AppTypography.rowTitle.weight(.semibold))
                        .foregroundStyle(AppColors.primaryText)
                        .privacySensitive()
                }
                HStack(spacing: AppSpacing.xs) {
                    if !account.isIncludedInTotals {
                        StatusPillView(text: AppLocalizer.string("bankAccount.excludedFromTotals", locale: locale), tint: AppColors.neutral)
                    }
                    StatusPillView(text: statusText, tint: statusTint)
                }
            }
        }
        .padding(.vertical, AppSpacing.md)
        // One element named after its content (account, bank, balance, status): a card with no name reads "button".
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accounts-card-\(account.stableIdentifier)")
    }

    private var balanceText: String {
        guard let balance = account.balance else {
            return AppLocalizer.string("bankAccount.balance.unknown", locale: locale)
        }
        return Formatters.currencyString(for: balance, currencyCode: account.currencyCode)
    }

    private var statusText: String {
        account.isManual
            ? AppLocalizer.string("bankAccount.status.manual", locale: locale)
            : AppLocalizer.string("bankAccount.status.\(account.normalizedStatus.rawValue)", locale: locale)
    }

    private var statusTint: Color {
        if account.isManual {
            return AppColors.accent
        }
        switch account.normalizedStatus {
        case .active: return AppColors.success
        case .needsReconnect: return AppColors.warning
        case .error: return AppColors.error
        }
    }
}

struct BankTransactionDetailView: View {
    private let transactionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var errorMessage: String?
    @State private var noteDraft = ""

    init(transaction: BankTransaction) {
        transactionID = transaction.id
    }

    // A detail can stay on another tab while sync or unlink deletes its model.
    private var transaction: BankTransaction? {
        appState.bankTransaction(id: transactionID)
    }

    var body: some View {
        Form {
            if let transaction {
                identitySection(transaction)
                Section {
                    categoryControls(transaction)
                    if transaction.normalizedDirection == .credit {
                        creditNatureControls(transaction)
                    }
                    classificationActions(transaction)
                }
                if transaction.installmentEvidence != nil {
                    InstallmentReviewSection(transactionID: transaction.id)
                }
                notesSection(transaction)
            } else {
                ContentUnavailableView(AppLocalizer.string("accounts.transaction.unavailable", locale: locale), systemImage: "doc.questionmark")
                    .accessibilityIdentifier("bank-transaction-unavailable")
            }
        }
        .navigationTitle(transaction?.label ?? AppLocalizer.string("accounts.transaction.unavailable", locale: locale))
        .onChange(of: transaction?.id, initial: true) { _, _ in noteDraft = transaction?.userNote ?? "" }
        .accessibilityIdentifier("bank-transaction-detail")
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // Le corps mêlait identité, catégorie, nature, bascules et notes sur plus de cent lignes :
    // découpé par sujet, chaque bloc se relit et se modifie sans traverser les autres.
    @ViewBuilder private func identitySection(_ transaction: BankTransaction) -> some View {
        Section {
            BankTransactionRowView(transaction: transaction, accountName: appState.externalAccount(id: transaction.accountID)?.name)
            LabeledContent(AppLocalizer.string("transaction.originalLabel", locale: locale), value: transaction.label)
            if let merchant = transaction.counterpartyName {
                LabeledContent(AppLocalizer.string("Merchant", locale: locale), value: merchant)
            }
            LabeledContent(AppLocalizer.string("transaction.bookingDate", locale: locale), value: Formatters.dateString(for: transaction.bookingDate))
            if let date = transaction.valueDate {
                LabeledContent(AppLocalizer.string("transaction.valueDate", locale: locale), value: Formatters.dateString(for: date))
            }
            LabeledContent(AppLocalizer.string("operations.status", locale: locale), value: AppLocalizer.string("operations.status." + transaction.normalizedStatus.rawValue, locale: locale))
            Text(AppLocalizer.string(transaction.countsInTotals && appState.externalAccount(id: transaction.accountID)?.isIncludedInTotals == true ? "transaction.included" : "operations.excluded", locale: locale))
            if transaction.isAbsentFromBank {
                Text(AppLocalizer.string("transaction.withdrawn", locale: locale)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func categoryControls(_ transaction: BankTransaction) -> some View {
        CategorySelectionView(selection: Binding(
            get: { self.transaction?.category ?? ExpenseCategory.other.storageValue },
            set: { value in
                guard let current = self.transaction else { return }
                do { try appState.setBankTransaction(current, category: ExpenseCategory.canonicalCategory(for: value)) }
                catch { errorMessage = error.userMessage }
            }
        ), identifier: "transaction-category-picker")
        Text(AppLocalizer.string("transaction.classification." + transaction.classificationSource, locale: locale))
            .font(AppTypography.rowMeta).foregroundStyle(.secondary)
            .accessibilityIdentifier("transaction-classification-source")
        if transaction.categoryOverride != nil || transaction.automaticCategory == nil {
            Button(AppLocalizer.string("transaction.category.reset", locale: locale)) {
                do { try appState.resetBankTransactionCategory(id: transactionID) }
                catch { errorMessage = error.userMessage }
            }.accessibilityIdentifier("transaction-category-reset")
        }
        LabeledContent(AppLocalizer.string("transaction.classification.confidence", locale: locale), value: AppLocalizer.string(transaction.categoryConfidence.localizationKey, locale: locale))
        Text(AppLocalizer.string(transaction.categoryEvidence.localizationKey, locale: locale)).font(.footnote)
    }

    @ViewBuilder private func creditNatureControls(_ transaction: BankTransaction) -> some View {
        LabeledContent(AppLocalizer.string("transaction.nature", locale: locale), value: AppLocalizer.string("transaction.nature." + transaction.creditNature.rawValue, locale: locale))
        Text(AppLocalizer.string(transaction.natureEvidence.localizationKey, locale: locale)).font(.footnote)
        Text(AppLocalizer.string(transaction.natureConfidence.localizationKey, locale: locale)).font(.footnote)
        Picker(AppLocalizer.string("transaction.nature", locale: locale), selection: Binding(
            get: { self.transaction?.natureOverride ?? "automatic" },
            set: { nature in
                guard let current = self.transaction else { return }
                do { try appState.setBankTransaction(current, nature: nature) }
                catch { errorMessage = error.userMessage }
            }
        )) {
            ForEach(["automatic", "salary", "personalTransfer", "internalTransfer", "refund", "otherIncome", "needsReview"], id: \.self) { value in
                Text(AppLocalizer.string("transaction.nature." + value, locale: locale)).tag(value)
            }
        }.accessibilityIdentifier("transaction-nature-picker")
        if transaction.isRefund {
            NavigationLink {
                RefundExpensePickerView(transactionID: transaction.id)
            } label: {
                Text(AppLocalizer.string("transaction.refund.link", locale: locale))
            }
        }
    }

    @ViewBuilder private func classificationActions(_ transaction: BankTransaction) -> some View {
        Toggle(AppLocalizer.string("accounts.action.markTransfer", locale: locale), isOn: Binding(
            get: { self.transaction?.isInternalTransfer ?? false },
            set: { value in
                guard let current = self.transaction else { return }
                do { try appState.setBankTransaction(current, isInternalTransfer: value) }
                catch { errorMessage = error.userMessage }
            }
        )).accessibilityIdentifier("transaction-internal-transfer-toggle")
        Toggle(AppLocalizer.string("accounts.action.ignore", locale: locale), isOn: Binding(
            get: { self.transaction?.isIgnored ?? false },
            set: { value in
                guard let current = self.transaction else { return }
                do { try appState.setBankTransaction(current, isIgnored: value) }
                catch { errorMessage = error.userMessage }
            }
        )).accessibilityIdentifier("transaction-ignore-toggle")
        NavigationLink {
            BankTransactionLinkPickerView(transaction: transaction)
        } label: {
            Text(appState.linkedEntityName(for: transaction) ?? AppLocalizer.string("accounts.action.link", locale: locale))
        }
        .accessibilityIdentifier("bank-transaction-link-button")
    }

    @ViewBuilder private func notesSection(_ transaction: BankTransaction) -> some View {
        Section(AppLocalizer.string("Notes", locale: locale)) {
            TextField(AppLocalizer.string("transaction.note.placeholder", locale: locale), text: $noteDraft, axis: .vertical)
                .lineLimit(3...8).accessibilityIdentifier("transaction-note-field")
            Button(AppLocalizer.string("Save", locale: locale)) {
                do { try appState.setBankTransactionNote(id: transactionID, note: noteDraft) }
                catch { errorMessage = error.userMessage }
            }
            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (transaction.userNote ?? ""))
            .accessibilityIdentifier("transaction-note-save")
            if noteDraft != (transaction.userNote ?? "") {
                Button(AppLocalizer.string("Cancel", locale: locale)) { noteDraft = transaction.userNote ?? "" }
            }
        }
    }

}

struct BankTransactionRowView: View {
    let transaction: BankTransaction
    let accountName: String?
    var linkedEntityName: String? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(transaction.label.isEmpty ? (transaction.counterpartyName ?? "—") : transaction.label)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
                    .lineLimit(2)
                Text(subtitle)
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                Text(amountText)
                    .font(AppTypography.rowTitle.weight(.semibold))
                    .foregroundStyle(amountTint)
                    .strikethrough(transaction.isIgnored)
                HStack(spacing: AppSpacing.xs) {
                    if transaction.normalizedStatus == .pending {
                        StatusPillView(text: AppLocalizer.string("accounts.transaction.pending", locale: locale), tint: AppColors.warning)
                    }
                    if transaction.isInternalTransfer {
                        StatusPillView(text: AppLocalizer.string("accounts.transaction.transfer", locale: locale), tint: AppColors.neutral)
                            .accessibilityIdentifier("bank-transaction-transfer-pill-\(transaction.externalID)")
                    }
                    if transaction.isIgnored {
                        StatusPillView(text: AppLocalizer.string("accounts.transaction.ignored", locale: locale), tint: AppColors.neutral)
                            .accessibilityIdentifier("bank-transaction-ignored-pill-\(transaction.externalID)")
                    }
                    if transaction.isLinked {
                        StatusPillView(text: AppLocalizer.string("accounts.transaction.linked", locale: locale), tint: AppColors.accent)
                            .accessibilityIdentifier("bank-transaction-linked-pill-\(transaction.externalID)")
                    }
                }
            }
        }
        .glassCard(padding: AppSpacing.md)
        // Label, date · category, amount and status pills read as one sentence, in that order.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bank-transaction-row-\(transaction.externalID)")
    }

    private var amountTint: Color {
        if transaction.isInternalTransfer || transaction.isIgnored {
            return AppColors.secondaryText
        }
        return transaction.normalizedDirection == .credit ? AppColors.success : AppColors.primaryText
    }

    private var subtitle: String {
        var parts = [Formatters.dateString(for: transaction.bookingDate)]
        if transaction.normalizedDirection == .debit {
            parts.append(ExpenseCategory.displayName(forStoredValue: transaction.category, locale: locale))
        }
        if transaction.normalizedDirection == .credit {
            parts.append(AppLocalizer.string("transaction.nature." + transaction.creditNature.rawValue, locale: locale))
        }
        if let counterparty = transaction.counterpartyName, counterparty != transaction.label {
            parts.append(counterparty)
        }
        if let linkedEntityName {
            parts.append("→ \(linkedEntityName)")
        }
        if let accountName {
            parts.append(accountName)
        }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        let sign = transaction.normalizedDirection == .credit ? "+" : "−"
        return sign + Formatters.currencyString(for: transaction.amount, currencyCode: transaction.currencyCode)
    }
}

struct RefundExpensePickerView: View {
    let transactionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(appState.bankTransactions.filter { $0.isExpense && (query.isEmpty || $0.label.localizedStandardContains(query)) }.sorted { $0.bookingDate > $1.bookingDate }) { expense in
                Button {
                    guard let refund = appState.bankTransactions.first(where: { $0.id == transactionID }) else { return }
                    do { try appState.setBankTransaction(refund, nature: "refund", refundOf: expense.id); dismiss() }
                    catch { errorMessage = error.userMessage }
                } label: {
                    BankTransactionRowView(transaction: expense, accountName: appState.externalAccount(id: expense.accountID)?.name)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(AppLocalizer.string("transaction.refund.link", locale: locale))
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
