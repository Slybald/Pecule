import SwiftUI

struct PurchaseFormView: View {
    private enum Field: Hashable {
        case title
        case amount
        case merchant
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let purchase: Purchase?

    @State private var title: String
    @State private var amountText: String
    @State private var date: Date
    @State private var category: String
    @State private var merchant: String
    @State private var notes: String
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @FocusState private var focusedField: Field?

    init(purchase: Purchase?) {
        self.purchase = purchase
        _title = State(initialValue: purchase?.title ?? "")
        _amountText = State(initialValue: Formatters.decimalString(for: purchase?.amount))
        _date = State(initialValue: purchase?.date ?? Date())
        _category = State(initialValue: ExpenseCategory.formStorageValue(for: purchase?.category))
        _merchant = State(initialValue: purchase?.merchant ?? "")
        _notes = State(initialValue: purchase?.notes ?? "")
    }

    private var isEditing: Bool {
        purchase != nil
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCategory: String {
        category.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMerchant: String {
        merchant.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: purchase?.amount), decimal > .zero else {
            return nil
        }

        return decimal.currencyRounded
    }

    private var titleError: String? {
        trimmedTitle.isEmpty ? AppLocalizer.string("Title is required.", locale: locale) : nil
    }

    private var amountError: String? {
        guard !trimmedAmountText.isEmpty else {
            return AppLocalizer.string("Amount is required.", locale: locale)
        }

        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: purchase?.amount) else {
            return AppLocalizer.string("Enter a valid amount.", locale: locale)
        }

        guard decimal > .zero else {
            return AppLocalizer.string("Enter an amount greater than 0.", locale: locale)
        }

        return nil
    }

    private var usesLegacyCategoryValue: Bool {
        ExpenseCategory(matching: category) == nil && !trimmedCategory.isEmpty
    }

    private var merchantError: String? {
        trimmedMerchant.isEmpty ? AppLocalizer.string("Merchant is required.", locale: locale) : nil
    }

    private var isFormValid: Bool {
        titleError == nil &&
        amountError == nil &&
        merchantError == nil
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                TextField(AppLocalizer.string("Title", locale: locale), text: $title)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("purchase-form-title-field")

                if let message = validationMessage(for: .title) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("purchase-form-title-error")
                }

                TextField(AppLocalizer.string("Amount", locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .amount)
                    .accessibilityIdentifier("purchase-form-amount-field")

                if let message = validationMessage(for: .amount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("purchase-form-amount-error")
                }

                DatePicker(AppLocalizer.string("Date", locale: locale), selection: $date, displayedComponents: .date)
            }

            Section(AppLocalizer.string("Category", locale: locale)) {
                CategorySelectionView(selection: $category, identifier: "purchase-form-category-field")

                if usesLegacyCategoryValue {
                    Text(AppLocalizer.format("Current saved category: %@", locale: locale, trimmedCategory))
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("purchase-form-category-legacy-note")
                }

                TextField(AppLocalizer.string("Merchant", locale: locale), text: $merchant)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .merchant)
                    .accessibilityIdentifier("purchase-form-merchant-field")

                if let message = validationMessage(for: .merchant) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("purchase-form-merchant-error")
                }
            }

            Section(AppLocalizer.string("Notes", locale: locale)) {
                TextField(AppLocalizer.string("Notes", locale: locale), text: $notes, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .accessibilityIdentifier("purchase-form-notes-field")
            }
        }
        .navigationTitle(isEditing ? AppLocalizer.string("Edit Purchase", locale: locale) : AppLocalizer.string("New Purchase", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .alert(
            AppLocalizer.string("Unable to Save Purchase", locale: locale),
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
                .accessibilityIdentifier("purchase-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    savePurchase()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("purchase-form-save-button")
            }
        }
    }

    private func savePurchase() {
        guard let amount = parsedAmount else {
            return
        }

        do {
            if let purchase {
                try appState.updatePurchase(
                    purchase,
                    title: title,
                    amount: amount,
                    date: date,
                    category: categoryForSaving,
                    merchant: merchant,
                    notes: notes
                )
            } else {
                try appState.addPurchase(
                    title: title,
                    amount: amount,
                    date: date,
                    category: categoryForSaving,
                    merchant: merchant,
                    notes: notes
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
        case .title:
            return titleError
        case .amount:
            return amountError
        case .merchant:
            return merchantError
        }
    }
}

#Preview("New Purchase") {
    NavigationStack {
        PurchaseFormView(purchase: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Purchase") {
    let previewState = AppState.preview

    return NavigationStack {
        PurchaseFormView(purchase: previewState.purchases.first)
            .environmentObject(previewState)
    }
}
