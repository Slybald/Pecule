import SwiftUI

struct BankTransactionLinkPickerView: View {
    private let transactionID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var errorMessage: String?

    init(transaction: BankTransaction) {
        transactionID = transaction.id
    }

    private var transaction: BankTransaction? {
        appState.bankTransactions.first { $0.id == transactionID }
    }

    private var recentPurchases: [Purchase] {
        guard let transaction else { return [] }
        let horizon = transaction.bookingDate.addingTimeInterval(-45 * 86_400)
        return appState.purchases.filter { $0.date >= horizon }.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if let transaction {
                if transaction.isLinked {
                    Section {
                        Button(role: .destructive) {
                            apply(nil)
                        } label: {
                            Label(AppLocalizer.string("accounts.action.unlink", locale: locale), systemImage: "link.badge.minus")
                        }
                        .accessibilityIdentifier("bank-link-remove-button")
                    }
                }

                if transaction.normalizedDirection == .debit {
                    Section {
                        ForEach(appState.subscriptions.filter(\.isActive)) { subscription in
                            row(title: subscription.name, amount: subscription.amount, selected: transaction.link == .subscription(subscription.id)) {
                                apply(.subscription(subscription.id))
                            }
                            .accessibilityIdentifier("bank-link-subscription-\(subscription.id.uuidString)")
                        }
                    } header: {
                        Text(AppLocalizer.string("linkPicker.subscriptions", locale: locale))
                    }

                    Section {
                        ForEach(recentPurchases) { purchase in
                            row(title: purchase.title, amount: purchase.amount, selected: transaction.link == .purchase(purchase.id)) {
                                apply(.purchase(purchase.id))
                            }
                            .accessibilityIdentifier("bank-link-purchase-\(purchase.id.uuidString)")
                        }
                    } header: {
                        Text(AppLocalizer.string("linkPicker.purchases", locale: locale))
                    }
                } else {
                    Section {
                        ForEach(appState.incomeSources.filter(\.isActive)) { source in
                            row(title: source.name, amount: source.amount, selected: transaction.link == .income(source.id)) {
                                apply(.income(source.id))
                            }
                            .accessibilityIdentifier("bank-link-income-\(source.id.uuidString)")
                        }
                    } header: {
                        Text(AppLocalizer.string("linkPicker.income", locale: locale))
                    }
                }
            } else {
                ContentUnavailableView(AppLocalizer.string("accounts.transaction.unavailable", locale: locale), systemImage: "doc.questionmark")
                    .accessibilityIdentifier("bank-transaction-unavailable")
            }
        }
        .navigationTitle(AppLocalizer.string("linkPicker.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("bank-link-cancel-button")
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
        .accessibilityIdentifier("bank-link-picker")
    }

    private func row(title: String, amount: Decimal, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Formatters.currencyString(for: amount))
                    .foregroundStyle(.secondary)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppColors.accent)
                }
            }
        }
    }

    private func apply(_ link: BankTransactionLink?) {
        guard let transaction else {
            dismiss()
            return
        }
        do {
            try appState.setBankTransaction(transaction, link: link)
            AppHaptics.play(.success)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
