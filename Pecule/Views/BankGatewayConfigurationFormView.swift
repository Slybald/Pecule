import SwiftUI

struct BankGatewayConfigurationFormView: View {
    private enum Field: Hashable {
        case url
        case token
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focusedField: Field?
    @State private var touchedFields: Set<Field> = []
    @State private var urlText = ""
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var errorMessage: String?
    @State private var probeState: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle
        case running
        case success(environment: String, aspspCount: Int)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    AppLocalizer.string("gatewayForm.url.placeholder", locale: locale),
                    text: $urlText
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .url)
                .accessibilityIdentifier("gateway-form-url-field")

                if let message = validationMessage(for: .url) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("gateway-form-url-error")
                }
            } header: {
                Text(AppLocalizer.string("gatewayForm.url.label", locale: locale))
            }

            Section {
                SecureField(
                    hasStoredToken
                        ? AppLocalizer.string("gatewayForm.token.unchanged", locale: locale)
                        : AppLocalizer.string("gatewayForm.token.label", locale: locale),
                    text: $token
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .token)
                .accessibilityIdentifier("gateway-form-token-field")

                if let message = validationMessage(for: .token) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("gateway-form-token-error")
                }
            } header: {
                Text(AppLocalizer.string("gatewayForm.token.label", locale: locale))
            }

            Section {
                Button {
                    Task { await probe() }
                } label: {
                    if probeState == .running {
                        HStack(spacing: AppSpacing.sm) {
                            ProgressView()
                            Text(AppLocalizer.string("gatewayForm.test.running", locale: locale))
                        }
                    } else {
                        Text(AppLocalizer.string("gatewayForm.test.button", locale: locale))
                    }
                }
                .disabled(!isFormValid || probeState == .running)
                .accessibilityIdentifier("gateway-form-test-button")

                switch probeState {
                case .success(let environment, let aspspCount):
                    Label(
                        AppLocalizer.format("gatewayForm.test.success %@ %lld", locale: locale, environment, aspspCount),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(AppColors.success)
                    .accessibilityIdentifier("gateway-form-test-result")
                case .failure(let message):
                    Label(AppLocalizer.format("gatewayForm.test.failure %@", locale: locale, message), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("gateway-form-test-result")
                case .idle, .running:
                    EmptyView()
                }
            } footer: {
                Text(AppLocalizer.string("gatewayForm.test.footer", locale: locale))
            }
        }
        .navigationTitle(AppLocalizer.string("gatewayForm.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("gateway-form-cancel-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    save()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("gateway-form-save-button")
            }
        }
        .onChange(of: focusedField) { previous, _ in
            if let previous {
                touchedFields.insert(previous)
            }
        }
        .onAppear {
            // The token is never echoed back: leaving the field blank keeps the stored secret.
            if let configuration = appState.currentBankGatewayConfiguration {
                urlText = configuration.baseURL.absoluteString
                hasStoredToken = true
            }
        }
        .alert(
            AppLocalizer.string("gatewayForm.error.title", locale: locale),
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

    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private var urlError: String? {
        parsedURL == nil ? AppLocalizer.string("gatewayForm.url.error", locale: locale) : nil
    }

    private var tokenError: String? {
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasStoredToken
            ? AppLocalizer.string("gatewayForm.token.error", locale: locale)
            : nil
    }

    private var isFormValid: Bool {
        urlError == nil && tokenError == nil
    }

    private func validationMessage(for field: Field) -> String? {
        guard touchedFields.contains(field) else {
            return nil
        }
        switch field {
        case .url: return urlError
        case .token: return tokenError
        }
    }

    // The token typed in the form wins; a blank field falls back to the stored one, like save() does.
    private func candidateConfiguration() -> BankGatewayConfiguration? {
        guard let parsedURL else {
            return nil
        }
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = typed.isEmpty ? (appState.storedBankGatewayToken() ?? "") : typed
        guard !bearer.isEmpty else {
            return nil
        }
        return BankGatewayConfiguration(baseURL: parsedURL, bearerToken: bearer)
    }

    private func probe() async {
        guard let configuration = candidateConfiguration() else {
            return
        }
        probeState = .running
        do {
            let result = try await LiveBankGatewayClient(configurationProvider: { nil }).probe(configuration)
            probeState = .success(environment: result.environment, aspspCount: result.aspspCount)
            AppHaptics.play(.success)
        } catch {
            probeState = .failure(error.userMessage)
            AppHaptics.play(.error)
        }
    }

    private func save() {
        guard let parsedURL else {
            return
        }
        do {
            try appState.saveBankGatewayConfiguration(baseURL: parsedURL, bearerToken: token)
            AppHaptics.play(.success)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
