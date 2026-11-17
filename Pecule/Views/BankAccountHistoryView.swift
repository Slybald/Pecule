import SwiftUI

struct BankAccountHistoryView: View {
    let accountID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    @State private var rows: [BankTransaction] = []
    @State private var cursor: AccountHistoryCursor?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let account = appState.externalAccount(id: accountID) {
                Section {
                    Text(account.name)
                    if let iban = account.maskedIBAN { Text(iban) }
                    LabeledContent(AppLocalizer.string("accounts.totalBalance", locale: locale), value: account.balance.map { Formatters.currencyString(for: $0, currencyCode: account.currencyCode) } ?? AppLocalizer.string("bankAccount.balance.unknown", locale: locale))
                    NavigationLink { BankDataStatusView(bankSync: appState.bankSync, accountID: accountID) } label: {
                        Text(AppLocalizer.string("bank.freshness.title", locale: locale))
                    }
                }
                if account.currencyCode == "EUR", account.isIncludedInTotals {
                    NavigationLink { TreasuryCalendarView(initialAccountID: accountID) } label: {
                        Label(AppLocalizer.string("treasury.title", locale: locale), systemImage: "calendar")
                    }.accessibilityIdentifier("account-calendar")
                }
                Section(AppLocalizer.string("operations.title", locale: locale)) {
                    ForEach(rows) { transaction in
                        NavigationLink { BankTransactionDetailView(transaction: transaction) } label: {
                            BankTransactionRowView(transaction: transaction, accountName: nil)
                        }
                    }
                    if cursor != nil {
                        Button(AppLocalizer.string("operations.loadMore", locale: locale)) { load(reset: false) }
                            .accessibilityIdentifier("account-history-load-more")
                    }
                    if rows.isEmpty && errorMessage == nil {
                        Text(AppLocalizer.string("accounts.transactions.empty", locale: locale))
                    }
                    if let errorMessage {
                        Text(errorMessage)
                        Button(AppLocalizer.string("Retry", locale: locale)) { load(reset: rows.isEmpty) }
                    }
                }
            }
        }
        .onChange(of: appState.dataRevision, initial: true) { _, _ in load(reset: true) }
        .navigationTitle(appState.externalAccount(id: accountID)?.shortDisplayName(locale: locale) ?? "")
        .accessibilityIdentifier("account-history-screen")
    }
    private func load(reset: Bool) {
        guard appState.isProfileActive, appState.externalAccount(id: accountID) != nil else {
            rows = []
            cursor = nil
            errorMessage = nil
            return
        }
        do {
            let page = try appState.dataStore.accountHistory(accountID: accountID, after: reset ? nil : cursor)
            rows = reset ? page.transactions : rows + page.transactions
            cursor = page.next
            errorMessage = nil
        } catch { errorMessage = error.userMessage }
    }
}
