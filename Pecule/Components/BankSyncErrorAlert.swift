import SwiftUI

extension View {
    // One alert for every bank screen. When the error can only be cured by a new authorization, it carries a
    // "Reconnect" button that leads to `onReconnect`; screens that already are the reconnection pass nil.
    func bankSyncErrorAlert(_ bankSync: BankSyncService, onReconnect: (() -> Void)? = nil) -> some View {
        modifier(BankSyncErrorAlert(bankSync: bankSync, onReconnect: onReconnect))
    }
}

private struct BankSyncErrorAlert: ViewModifier {
    @ObservedObject var bankSync: BankSyncService
    let onReconnect: (() -> Void)?
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.alert(
            AppLocalizer.string("settings.bankAccounts.error.title", locale: locale),
            isPresented: Binding(
                get: { bankSync.errorMessage != nil },
                set: { if !$0 { bankSync.errorMessage = nil } }
            )
        ) {
            if bankSync.errorOffersReconnect, let onReconnect {
                Button(AppLocalizer.string("error.action.reconnect", locale: locale)) { onReconnect() }
                    .accessibilityIdentifier("bank-error-reconnect-button")
            }
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(bankSync.errorMessage ?? "")
        }
    }
}
