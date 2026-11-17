import SwiftUI

struct SubscriptionFormView: View {
    private enum Field: Hashable {
        case name
        case amount
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let subscription: Subscription?

    @State private var name: String
    @State private var amountText: String
    @State private var billingCycle: BillingCycle
    @State private var category: String
    @State private var nextBillingDate: Date
    @State private var isActive: Bool
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @FocusState private var focusedField: Field?

    init(subscription: Subscription?) {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
        _amountText = State(initialValue: Formatters.decimalString(for: subscription?.amount))
        _billingCycle = State(initialValue: subscription?.billingCycle ?? .monthly)
        _category = State(initialValue: ExpenseCategory.formStorageValue(for: subscription?.category))
        _nextBillingDate = State(initialValue: subscription?.nextBillingDate ?? Date())
        _isActive = State(initialValue: subscription?.isActive ?? true)
    }

    private var isEditing: Bool {
        subscription != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCategory: String {
        category.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAmountText: String {
        amountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedCategory: Binding<ExpenseCategory> {
        Binding(
            get: { ExpenseCategory(matching: category) ?? .other },
            set: { selectedCategory in
                category = selectedCategory.storageValue
            }
        )
    }

    private var categoryForSaving: String {
        ExpenseCategory.formStorageValue(for: category)
    }

    private var parsedAmount: Decimal? {
        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: subscription?.amount), decimal > .zero else {
            return nil
        }

        return decimal.currencyRounded
    }

    private var nameError: String? {
        trimmedName.isEmpty ? AppLocalizer.string("Name is required.", locale: locale) : nil
    }

    private var usesLegacyCategoryValue: Bool {
        ExpenseCategory(matching: category) == nil && !trimmedCategory.isEmpty
    }

    private var amountError: String? {
        guard !trimmedAmountText.isEmpty else {
            return AppLocalizer.string("Amount is required.", locale: locale)
        }

        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: subscription?.amount) else {
            return AppLocalizer.string("Enter a valid amount.", locale: locale)
        }

        guard decimal > .zero else {
            return AppLocalizer.string("Enter an amount greater than 0.", locale: locale)
        }

        return nil
    }

    private var isFormValid: Bool {
        nameError == nil &&
        amountError == nil
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                TextField(AppLocalizer.string("Name", locale: locale), text: $name)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("subscription-form-name-field")

                if let message = validationMessage(for: .name) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("subscription-form-name-error")
                }

                CategorySelectionView(selection: $category, identifier: "subscription-form-category-field")

                if usesLegacyCategoryValue {
                    Text(AppLocalizer.format("Current saved category: %@", locale: locale, trimmedCategory))
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("subscription-form-category-legacy-note")
                }
            }

            Section(AppLocalizer.string("Billing", locale: locale)) {
                TextField(AppLocalizer.string("Amount", locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .amount)
                    .accessibilityIdentifier("subscription-form-amount-field")

                if let message = validationMessage(for: .amount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("subscription-form-amount-error")
                }

                Picker(AppLocalizer.string("Billing Cycle", locale: locale), selection: $billingCycle) {
                    ForEach(BillingCycle.allCases, id: \.self) { cycle in
                        Text(cycle.displayName).tag(cycle)
                    }
                }

                DatePicker(
                    AppLocalizer.string("Next Billing Date", locale: locale),
                    selection: $nextBillingDate,
                    displayedComponents: .date
                )

                Toggle(AppLocalizer.string("Active", locale: locale), isOn: $isActive)
            }
        }
        .navigationTitle(isEditing ? AppLocalizer.string("Edit Subscription", locale: locale) : AppLocalizer.string("New Subscription", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .alert(
            AppLocalizer.string("Unable to Save Subscription", locale: locale),
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) {
                    dismiss()
                }
                .accessibilityIdentifier("subscription-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    saveSubscription()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("subscription-form-save-button")
            }
        }
    }

    private func saveSubscription() {
        guard let amount = parsedAmount else {
            return
        }

        do {
            if let subscription {
                try appState.updateSubscription(
                    subscription,
                    name: name,
                    amount: amount,
                    billingCycle: billingCycle,
                    category: categoryForSaving,
                    nextBillingDate: nextBillingDate,
                    isActive: isActive
                )
            } else {
                try appState.addSubscription(
                    name: name,
                    amount: amount,
                    billingCycle: billingCycle,
                    category: categoryForSaving,
                    nextBillingDate: nextBillingDate,
                    isActive: isActive
                )
            }

            AppHaptics.play(.success)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func validationMessage(for field: Field) -> String? {
        guard touchedFields.contains(field) else {
            return nil
        }

        switch field {
        case .name:
            return nameError
        case .amount:
            return amountError
        }
    }
}

#Preview("New Subscription") {
    NavigationStack {
        SubscriptionFormView(subscription: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Subscription") {
    let previewState = AppState.preview

    return NavigationStack {
        SubscriptionFormView(subscription: previewState.subscriptions.first)
            .environmentObject(previewState)
    }
}
