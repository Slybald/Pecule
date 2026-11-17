import SwiftUI

struct ManualAccountFormView: View {
    private enum Field: Hashable {
        case name
        case balance
    }

    let account: ExternalAccount?

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focusedField: Field?
    @State private var touchedFields: Set<Field> = []
    @State private var name = ""
    @State private var balanceText = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField(AppLocalizer.string("manualAccountForm.name.placeholder", locale: locale), text: $name)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("manual-account-form-name-field")

                if let message = validationMessage(for: .name) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("manual-account-form-name-error")
                }
            } header: {
                Text(AppLocalizer.string("manualAccountForm.name.label", locale: locale))
            }

            Section {
                TextField(Formatters.amountPlaceholder(locale: locale), text: $balanceText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .balance)
                    .accessibilityLabel(AppLocalizer.string("manualAccountForm.balance.label", locale: locale))
                    .accessibilityIdentifier("manual-account-form-balance-field")

                if let message = validationMessage(for: .balance) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("manual-account-form-balance-error")
                }
            } header: {
                Text(AppLocalizer.string("manualAccountForm.balance.label", locale: locale))
            }
        }
        .navigationTitle(AppLocalizer.string("manualAccountForm.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("manual-account-form-cancel-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    save()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("manual-account-form-save-button")
            }
        }
        .onChange(of: focusedField) { previous, _ in
            if let previous {
                touchedFields.insert(previous)
            }
        }
        .onAppear {
            if let account {
                name = account.name
                balanceText = Formatters.decimalString(for: account.balance)
            }
        }
        .alert(
            AppLocalizer.string("common.error.save", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedBalance: Decimal? {
        Formatters.decimalValue(from: balanceText, prefilledWith: account?.balance)
    }

    private var nameError: String? {
        trimmedName.isEmpty ? AppLocalizer.string("manualAccountForm.name.error", locale: locale) : nil
    }

    private var balanceError: String? {
        parsedBalance == nil ? AppLocalizer.string("manualAccountForm.balance.error", locale: locale) : nil
    }

    private var isFormValid: Bool {
        nameError == nil && balanceError == nil
    }

    private func validationMessage(for field: Field) -> String? {
        guard touchedFields.contains(field) else {
            return nil
        }
        switch field {
        case .name: return nameError
        case .balance: return balanceError
        }
    }

    private func save() {
        guard let parsedBalance else {
            return
        }
        do {
            if let account {
                try appState.updateManualAccount(account, name: trimmedName, balance: parsedBalance)
            } else {
                try appState.addManualAccount(name: trimmedName, balance: parsedBalance)
            }
            AppHaptics.play(.success)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
