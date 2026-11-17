import AuthenticationServices
import SwiftUI

struct BankAccountsSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var bankSync: BankSyncService
    @Environment(\.locale) private var locale
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var presentedSheet: BankAccountsSheet?
    @State private var isDisconnectConfirmationPresented = false
    @State private var pendingUnlink: PendingUnlink?
    @AppStorage(DeveloperMode.key) private var developerMode = false

    var body: some View {
        Section {
            if appState.isBankGatewayConfigured {
                accountRows
                actionRows
            } else if appState.requestSignOut != nil {
                accountRows
                Button(AppLocalizer.string("settings.bankAccounts.addManual", locale: locale)) { presentedSheet = .manualAccount(nil) }
            } else {
                if developerMode {
                    Text(AppLocalizer.string("settings.bankAccounts.configure.message", locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(.secondary)
                    configureButton
                } else {
                    Text(AppLocalizer.string("settings.bankAccounts.unavailable", locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-bank-unavailable")
                }
            }
        } header: {
            // Presentation modifiers live on a concrete view: Section itself is not in the accessibility tree.
            Text(AppLocalizer.string("settings.bankAccounts.section", locale: locale))
                .accessibilityIdentifier("settings-bank-accounts-section")
                .sheet(item: $presentedSheet) { sheet in
                    NavigationStack {
                        switch sheet {
                        case .configure:
                            BankGatewayConfigurationFormView()
                        case .manualAccount(let account):
                            ManualAccountFormView(account: account)
                        case .chooseInstitution(let external):
                            BankInstitutionPickerView { institution in
                                Task {
                                    if external {
                                        await linkExternally(institution)
                                    } else {
                                        await link(institution)
                                    }
                                }
                            }
                        }
                    }
                    .environmentObject(appState)
                }
                .appHaptic(.success, trigger: bankSync.lastSyncDate)
                .appHaptic(.error, trigger: bankSync.errorMessage)
                .bankSyncErrorAlert(bankSync) { presentedSheet = .chooseInstitution(external: false) }
                // Hosted by its own view: the alert above reports errors, and two alerts on one view do not stack.
                .background { unlinkConfirmation }
        } footer: {
            if let lastSyncDate = bankSync.lastSyncDate {
                Text(AppLocalizer.format("settings.bankAccounts.lastSync %@", locale: locale, Formatters.dateTimeString(for: lastSyncDate)))
            }
        }
    }

    @ViewBuilder
    private var accountRows: some View {
        if appState.externalAccounts.isEmpty {
            Text(AppLocalizer.string("settings.bankAccounts.empty", locale: locale))
                .font(AppTypography.secondaryBody)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-bank-accounts-empty")
        } else {
            ForEach(appState.externalAccounts) { account in
                ExternalAccountRowView(account: account)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingUnlink = PendingUnlink(
                                account: account,
                                operationCount: (try? appState.dataStore.bankTransactionCount(accountID: account.id)) ?? 0,
                                revokesConsent: !account.isManual && !appState.externalAccounts.contains { account.sharesLink(with: $0) }
                            )
                        } label: {
                            Label(AppLocalizer.string("settings.bankAccounts.unlink", locale: locale), systemImage: "trash")
                        }
                        .accessibilityIdentifier("bank-account-unlink-\(account.stableIdentifier)")
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if account.isManual {
                            Button {
                                presentedSheet = .manualAccount(account)
                            } label: {
                                Label(AppLocalizer.string("settings.bankAccounts.editManual", locale: locale), systemImage: "pencil")
                            }
                            .tint(AppColors.accent)
                            .accessibilityIdentifier("bank-account-edit-\(account.stableIdentifier)")
                        }
                        Button {
                            do {
                                try appState.setExternalAccount(account, includedInTotals: !account.isIncludedInTotals)
                            } catch {
                                bankSync.errorMessage = error.userMessage
                            }
                        } label: {
                            Label(
                                AppLocalizer.string(account.isIncludedInTotals ? "settings.bankAccounts.excludeFromTotals" : "settings.bankAccounts.includeInTotals", locale: locale),
                                systemImage: account.isIncludedInTotals ? "eye.slash" : "eye"
                            )
                        }
                        .tint(AppColors.neutral)
                        .accessibilityIdentifier("bank-account-toggle-totals-\(account.stableIdentifier)")
                    }
            }
        }
    }

    @ViewBuilder
    private var actionRows: some View {
        if let pending = bankSync.pendingLink {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(AppLocalizer.format("settings.bankAccounts.pending %@", locale: locale, pending.institution.displayName(locale: locale)))
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(AppLocalizer.string("settings.bankAccounts.pending.check", locale: locale)) {
                        Task { _ = await bankSync.completePendingLink() }
                    }
                    .disabled(bankSync.isBusy)
                    .accessibilityIdentifier("settings-bank-pending-check-button")
                    Spacer()
                    Button(AppLocalizer.string("Cancel", locale: locale), role: .destructive) {
                        bankSync.cancelPendingLink()
                    }
                    .accessibilityIdentifier("settings-bank-pending-cancel-button")
                }
                .buttonStyle(.borderless)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-bank-pending-row")
        }

        Button {
            presentedSheet = .chooseInstitution(external: false)
        } label: {
            Label(AppLocalizer.string("settings.bankAccounts.link", locale: locale), systemImage: "plus.circle")
        }
        .disabled(bankSync.isBusy)
        .accessibilityIdentifier("settings-bank-link-button")

        // Developer mode only: the same link, opened in Safari instead of the in-app sheet.
        if developerMode {
            Button {
                presentedSheet = .chooseInstitution(external: true)
            } label: {
                Label(AppLocalizer.string("settings.bankAccounts.linkExternal", locale: locale), systemImage: "safari")
            }
            .disabled(bankSync.isBusy)
            .accessibilityIdentifier("settings-bank-link-external-button")
        }

        Button {
            presentedSheet = .manualAccount(nil)
        } label: {
            Label(AppLocalizer.string("settings.bankAccounts.addManual", locale: locale), systemImage: "square.and.pencil")
        }
        .accessibilityIdentifier("settings-bank-add-manual-button")

        if !appState.linkedExternalAccounts.isEmpty {
            Toggle(isOn: $appState.prefersBankAmounts) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(AppLocalizer.string("settings.bankAccounts.preferBankAmounts", locale: locale))
                    Text(AppLocalizer.string("settings.bankAccounts.preferBankAmounts.footer", locale: locale))
                        .font(AppTypography.rowMeta)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-bank-prefer-amounts-toggle")
        }

        if !appState.linkedExternalAccounts.isEmpty {
            Button {
                Task { await bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
            } label: {
                HStack {
                    Label(AppLocalizer.string("settings.bankAccounts.refresh", locale: locale), systemImage: "arrow.clockwise")
                    if bankSync.isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(bankSync.isBusy)
            .accessibilityIdentifier("settings-bank-refresh-button")
        }

        if appState.requestSignOut == nil, developerMode { configureButton }

        if let privacyURL = appState.bankGatewayPrivacyURL {
            Link(destination: privacyURL) {
                Label(AppLocalizer.string("settings.bankAccounts.privacy", locale: locale), systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settings-bank-privacy-link")
        }
    }

    @ViewBuilder
    private var configureButton: some View {
        Button {
            presentedSheet = .configure
        } label: {
            Label(AppLocalizer.string("settings.bankAccounts.configure", locale: locale), systemImage: "key")
        }
        .accessibilityIdentifier("settings-bank-gateway-configure-button")

        if appState.isBankGatewayConfigured && appState.bankGateway.requiresConfiguration {
            Button(role: .destructive) {
                isDisconnectConfirmationPresented = true
            } label: {
                Label(AppLocalizer.string("settings.bankAccounts.disconnect", locale: locale), systemImage: "key.slash")
            }
            .accessibilityIdentifier("settings-bank-gateway-disconnect-button")
            .confirmationDialog(
                AppLocalizer.string("settings.bankAccounts.disconnect.confirm", locale: locale),
                isPresented: $isDisconnectConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(AppLocalizer.string("settings.bankAccounts.disconnect", locale: locale), role: .destructive) {
                    do {
                        try appState.clearBankGatewayConfiguration()
                    } catch {
                        bankSync.errorMessage = error.userMessage
                    }
                }
                .accessibilityIdentifier("settings-bank-gateway-disconnect-confirm-button")
                Button(AppLocalizer.string("Cancel", locale: locale), role: .cancel) {}
            }
        }
    }

    // An alert rather than a confirmation dialog: on iPhone a dialog attached to a section header opens as a popover
    // anchored to that header, with no cancel button. The alert always shows both choices, and a message this long.
    private var unlinkConfirmation: some View {
        Color.clear
            .alert(
                pendingUnlink.map { AppLocalizer.format("settings.bankAccounts.unlink.confirm.title %@", locale: locale, $0.account.name) } ?? "",
                isPresented: Binding(
                    get: { pendingUnlink != nil },
                    set: { if !$0 { pendingUnlink = nil } }
                ),
                presenting: pendingUnlink
            ) { pending in
                Button(AppLocalizer.string("settings.bankAccounts.unlink", locale: locale), role: .destructive) {
                    let account = pending.account
                    Task { await bankSync.unlink(account) }
                }
                .accessibilityIdentifier("bank-account-unlink-confirm-button")
                Button(AppLocalizer.string("Cancel", locale: locale), role: .cancel) {}
                    .accessibilityIdentifier("bank-account-unlink-cancel-button")
            } message: { pending in
                Text(unlinkMessage(for: pending))
            }
    }

    // What unlinking costs, said before it happens: the operations go with their notes and corrections, and the
    // bank consent is revoked only when no other account of the same link still depends on it.
    private func unlinkMessage(for pending: PendingUnlink) -> String {
        var parts: [String] = []
        if pending.operationCount == 1 {
            parts.append(AppLocalizer.string("settings.bankAccounts.unlink.confirm.operations.one", locale: locale))
        } else if pending.operationCount > 1 {
            parts.append(AppLocalizer.format("settings.bankAccounts.unlink.confirm.operations %lld", locale: locale, Int64(pending.operationCount)))
        } else {
            parts.append(AppLocalizer.string(pending.account.isManual ? "settings.bankAccounts.unlink.confirm.manual" : "settings.bankAccounts.unlink.confirm.operations.none", locale: locale))
        }
        if pending.revokesConsent {
            parts.append(AppLocalizer.string("settings.bankAccounts.unlink.confirm.consent", locale: locale))
        }
        return parts.joined(separator: " ")
    }

    private func linkExternally(_ institution: BankInstitution) async {
        if let url = await bankSync.startExternalLink(institution: institution) {
            openURL(url)
        }
    }

    private func link(_ institution: BankInstitution) async {
        await bankSync.linkAccount(institution: institution) { url in
            do {
                return try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: "lifeos",
                    preferredBrowserSession: .shared
                )
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                throw BankLinkError.cancelled
            }
        }
    }
}

private struct PendingUnlink: Identifiable {
    let account: ExternalAccount
    let operationCount: Int
    // Last bank account of its link: the consent goes with it.
    let revokesConsent: Bool

    var id: UUID { account.id }
}

private enum BankAccountsSheet: Identifiable {
    case configure
    case chooseInstitution(external: Bool)
    case manualAccount(ExternalAccount?)

    var id: String {
        switch self {
        case .configure: "configure"
        case .chooseInstitution(let external): external ? "chooseInstitution-external" : "chooseInstitution"
        case .manualAccount(let account): "manualAccount-\(account?.id.uuidString ?? "new")"
        }
    }
}

struct ExternalAccountRowView: View {
    let account: ExternalAccount
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.name)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(balanceText)
                    .font(AppTypography.rowTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                    .privacySensitive()
                    .accessibilityLabel(AppLocalizer.format("bankAccount.voice.balance %@", locale: locale, balanceText))
                    .accessibilityIdentifier("bank-account-balance-\(account.stableIdentifier)")
            }
            HStack(spacing: AppSpacing.sm) {
                Text(subtitle)
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(.secondary)
                Spacer()
                if !account.isIncludedInTotals {
                    StatusPillView(text: AppLocalizer.string("bankAccount.excludedFromTotals", locale: locale), tint: AppColors.neutral)
                        .accessibilityIdentifier("bank-account-excluded-\(account.stableIdentifier)")
                }
                StatusPillView(text: statusText, tint: statusTint)
                    .accessibilityIdentifier("bank-account-status-\(account.stableIdentifier)")
            }
            if let consentValidUntil = account.consentValidUntil {
                Text(AppLocalizer.format("settings.bankAccounts.consentUntil %@", locale: locale, Formatters.dateString(for: consentValidUntil)))
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bank-account-row-\(account.stableIdentifier)")
    }

    private var balanceText: String {
        guard let balance = account.balance else {
            return AppLocalizer.string("bankAccount.balance.unknown", locale: locale)
        }
        return Formatters.currencyString(for: balance, currencyCode: account.currencyCode)
    }

    private var subtitle: String {
        let institution = account.normalizedInstitution?.displayName(locale: locale) ?? account.institution
        guard let maskedIBAN = account.maskedIBAN else {
            return institution
        }
        return "\(institution) · \(maskedIBAN)"
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

struct BankInstitutionPickerView: View {
    var dismissOnSelection = true
    let onSelect: (BankInstitution) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        List(BankInstitution.linkableCases) { institution in
            Button {
                if dismissOnSelection { dismiss() }
                onSelect(institution)
            } label: {
                HStack {
                    Text(institution.displayName(locale: locale))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("bank-institution-row-\(institution.rawValue)")
        }
        .safeAreaInset(edge: .bottom) {
            // The policy sits right where the consent decision is made.
            if let privacyURL = appState.bankGatewayPrivacyURL {
                VStack(spacing: AppSpacing.xs) {
                    Text(AppLocalizer.string("bank.privacy.footer", locale: locale))
                        .font(AppTypography.rowMeta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Link(AppLocalizer.string("settings.bankAccounts.privacy", locale: locale), destination: privacyURL)
                        .font(AppTypography.rowSubtitle.weight(.semibold))
                        .accessibilityIdentifier("bank-institution-privacy-link")
                }
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .navigationTitle(AppLocalizer.string("settings.bankAccounts.link", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("bank-institution-cancel-button")
            }
        }
        .accessibilityIdentifier("bank-institution-picker")
    }
}
