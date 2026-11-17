import SwiftUI

struct PurchasesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var selectedSort: PurchaseSortOption = .recent
    @State private var isPresentingAddPurchase = false
    @State private var errorMessage: String?
    @State private var purchasePendingDeletion: Purchase?
    @State private var month = Calendar.current.peculeMonthStart(for: Date())
    @State private var routedPurchase: Purchase?

    var body: some View {
        Group {
            if appState.purchases.isEmpty && appState.linkedExternalAccounts.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("No purchases recorded", locale: locale),
                    message: AppLocalizer.string("Add purchases to measure their real cost over time.", locale: locale),
                    systemImage: "cart.fill",
                    buttonTitle: AppLocalizer.string("Add Purchase", locale: locale),
                    action: {
                        isPresentingAddPurchase = true
                    },
                    tint: AppColors.purchaseTint,
                    identifier: "purchases-empty-state"
                )
            } else {
                List {
                    Section {
                        Picker(AppLocalizer.string("Sort", locale: locale), selection: $selectedSort) {
                            ForEach(PurchaseSortOption.allCases) { option in
                                Text(option.title(locale: locale)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("purchases-sort-picker")
                    }

                    if !appState.linkedExternalAccounts.isEmpty {
                        Section {
                            SpendingMonthPicker(month: $month)
                            if bankPurchases.isEmpty {
                                Text(AppLocalizer.string("purchases.bank.empty", locale: locale))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            ForEach(bankPurchases) { transaction in
                                NavigationLink {
                                    BankTransactionDetailView(transaction: transaction)
                                } label: {
                                    BankTransactionRowView(
                                        transaction: transaction,
                                        accountName: appState.externalAccount(id: transaction.accountID)?.name,
                                        linkedEntityName: appState.linkedEntityName(for: transaction)
                                    )
                                }
                            }
                        } header: {
                            Text(AppLocalizer.string("purchases.bank.section", locale: locale))
                        }
                    }

                    if !sortedPurchases.isEmpty {
                    Section(AppLocalizer.string("purchases.manual.section", locale: locale)) {
                        ForEach(sortedPurchases) { purchase in
                            NavigationLink {
                                PurchaseDetailView(purchase: purchase)
                            } label: {
                                PurchaseRowView(purchase: purchase)
                            }
                            .accessibilityIdentifier("purchase-row-\(purchase.id.uuidString)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    purchasePendingDeletion = purchase
                                } label: {
                                    Label(AppLocalizer.string("Delete", locale: locale), systemImage: "trash")
                                }
                                .tint(AppColors.error)
                                .accessibilityIdentifier("purchases-delete-button")
                            }
                        }
                    }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("purchases-list")
            }
        }
        .navigationTitle(AppLocalizer.string("Purchases", locale: locale))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingAddPurchase = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalizer.string("Add Purchase", locale: locale))
                .accessibilityIdentifier("purchases-add-button")
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            if let route = navigation.consume(where: { if case .purchase = $0 { return true } else { return false } }),
               case .purchase(let id) = route, let id {
                routedPurchase = appState.purchases.first { $0.id == id }
            }
        }
        .navigationDestination(item: $routedPurchase) { purchase in
            PurchaseDetailView(purchase: purchase)
        }
        .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
        .sheet(isPresented: $isPresentingAddPurchase) {
            NavigationStack {
                PurchaseFormView(purchase: nil)
            }
            .environmentObject(appState)
        }
        .deleteConfirmation($purchasePendingDeletion, name: \.title) { deletePurchase($0) }
        .alert(
            AppLocalizer.string("Unable to Change Purchase", locale: locale),
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

    private var sortedPurchases: [Purchase] {
        // Même prédicat qu'Opérations : seul le lien vers une opération qui compte dans les totaux d'un compte inclus masque l'achat.
        let linkedIDs = ManualPurchaseCoverageService.settledPurchaseIDs(
            in: appState.bankTransactions,
            includedAccountIDs: Set(appState.externalAccounts.filter(\.isIncludedInTotals).map(\.id))
        )
        let purchases: [Purchase]
        switch selectedSort {
        case .recent:
            purchases = appState.recentPurchases
        case .amount:
            purchases = appState.highestAmountPurchases
        }
        return purchases.filter { !linkedIDs.contains($0.id) }
    }

    private var bankPurchases: [BankTransaction] {
        let transactions = appState.spendingTransactions(in: month)
        return selectedSort == .recent ? transactions : transactions.sorted {
            $0.amount != $1.amount ? $0.amount > $1.amount : $0.externalID < $1.externalID
        }
    }

    private func deletePurchase(_ purchase: Purchase) {
        do {
            try appState.deletePurchase(purchase)
        } catch {
            errorMessage = error.userMessage
        }
    }
}

struct SpendingMonthPicker: View {
    @Binding var month: Date
    @Environment(\.locale) private var locale

    var body: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(AppLocalizer.string("spending.month.previous", locale: locale))
                .accessibilityIdentifier("spending-month-previous")
            Spacer()
            Text(Formatters.monthYearString(for: month))
                .font(AppTypography.rowTitle)
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(month >= Calendar.current.peculeMonthStart(for: Date()))
                .accessibilityLabel(AppLocalizer.string("spending.month.next", locale: locale))
                .accessibilityIdentifier("spending-month-next")
        }
        .buttonStyle(.borderless)
    }

    private func move(_ offset: Int) {
        month = Calendar.current.date(byAdding: .month, value: offset, to: month) ?? month
    }
}

#Preview {
    NavigationStack {
        PurchasesView()
            .environmentObject(AppNavigation())
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty") {
    let previewState = AppState.preview
    previewState.purchases = []

    return NavigationStack {
        PurchasesView()
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}

    private enum PurchaseSortOption: String, CaseIterable, Identifiable {
    case recent
    case amount

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .recent:
            return AppLocalizer.string("Recent", locale: locale)
        case .amount:
            return AppLocalizer.string("Amount", locale: locale)
        }
    }
}

private struct PurchaseRowView: View {
    let purchase: Purchase
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(purchase.title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AppColors.primaryText)

                    Text(purchase.merchant)
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Spacer()

                Text(Formatters.currencyString(for: purchase.amount))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
            }

            HStack {
                Text(purchase.categoryDisplayName(locale: locale))
                Spacer()
                Text(Formatters.dateString(for: purchase.date))
            }
            .font(AppTypography.rowSubtitle)
            .foregroundStyle(AppColors.secondaryText)

            if let notes = purchase.notes, !notes.isEmpty {
                Text(notes)
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }
}
