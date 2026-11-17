import AuthenticationServices
import SwiftUI

// The same entry point works from the empty dashboard, accounts and transaction list.
struct BankConnectionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @ObservedObject var bankSync: BankSyncService
    @AppStorage(DeveloperMode.key) private var developerMode = false
    @State private var isImporting = false
    @State private var showsResult = false

    private var pendingAccounts: [ExternalAccount] { appState.externalAccounts.filter(\.requiresInclusionReview) }

    // Outside developer mode nobody can fill the gateway form: say so and point to the manual accounts.
    private var gatewayUnavailable: some View {
        VStack(spacing: AppSpacing.md) {
            Text(AppLocalizer.string("settings.bankAccounts.unavailable", locale: locale)).font(.headline)
            Text(AppLocalizer.string("bank.connection.unavailable.hint", locale: locale)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bank-connection-unavailable")
    }

    var body: some View {
        Group {
            if isImporting {
                ProgressView(AppLocalizer.string("bank.connection.importing", locale: locale))
            } else if !pendingAccounts.isEmpty {
                BankAccountSelectionView(accounts: pendingAccounts) { choices in
                    Task {
                        isImporting = true
                        defer { isImporting = false }
                        do {
                            try appState.confirmAccountSelection(choices)
                            await bankSync.refresh(appState.externalAccounts.filter { choices[$0.id] != nil }, attended: true)
                            showsResult = true
                        } catch { bankSync.errorMessage = error.userMessage }
                    }
                }
            } else if showsResult {
                BankDataStatusView(bankSync: bankSync)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(AppLocalizer.string("Done", locale: locale)) { dismiss() }
                                .accessibilityIdentifier("bank-connection-done")
                        }
                    }
            } else if !appState.isBankGatewayConfigured {
                if appState.requestSignOut != nil { ManualAccountFormView(account: nil) }
                else if developerMode { BankGatewayConfigurationFormView() }
                else { gatewayUnavailable }
            } else {
                BankInstitutionPickerView(dismissOnSelection: false) { institution in
                    Task {
                        // Discarded on purpose: the returned SwiftData models are not Sendable and
                        // must not become the task's result. The view reads them back from AppState.
                        _ = await bankSync.linkAccount(institution: institution, syncImmediately: false) { url in
                            do {
                                return try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "lifeos", preferredBrowserSession: .shared)
                            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                                throw BankLinkError.cancelled
                            }
                        }
                    }
                }
                .disabled(bankSync.isBusy)
                .safeAreaInset(edge: .top) {
                    if bankSync.isBusy { ProgressView(AppLocalizer.string("bank.connection.authorizing", locale: locale)) }
                    else if bankSync.pendingLink != nil {
                        Button(AppLocalizer.string("settings.bankAccounts.pending.check", locale: locale)) {
                            Task { _ = await bankSync.completePendingLink() }
                        }.padding()
                    }
                }
            }
        }
        .navigationTitle(AppLocalizer.string("bank.connection.title", locale: locale))
        .accessibilityIdentifier("bank-connection-screen")
        .bankSyncErrorAlert(bankSync)
    }
}

private struct BankAccountSelectionView: View {
    let accounts: [ExternalAccount]
    let confirm: ([UUID: Bool]) -> Void
    @Environment(\.locale) private var locale
    @State private var choices: [UUID: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(accounts) { account in
                    Toggle(isOn: Binding(get: { choices[account.id] ?? account.isIncludedInTotals }, set: { choices[account.id] = $0 })) {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            if let iban = account.maskedIBAN { Text(iban).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("bank-selection-\(account.stableIdentifier)")
                }
            } header: { Text(AppLocalizer.string("bank.connection.selection", locale: locale)) }
            footer: { Text(AppLocalizer.string("bank.connection.selectionExplanation", locale: locale)) }
            Button(AppLocalizer.string("bank.connection.confirm", locale: locale)) {
                confirm(Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, choices[$0.id] ?? $0.isIncludedInTotals) }))
            }.accessibilityIdentifier("bank-selection-confirm")
        }
        .accessibilityIdentifier("bank-selection-screen")
    }
}
