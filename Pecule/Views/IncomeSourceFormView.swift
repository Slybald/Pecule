import SwiftUI

struct IncomeSourceFormView: View {
    private enum Field: Hashable {
        case name
        case amount
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let incomeSource: IncomeSource?

    @State private var name: String
    @State private var type: IncomeType
    @State private var amountText: String
    @State private var isRecurring: Bool
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var isActive: Bool
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @FocusState private var focusedField: Field?

    init(incomeSource: IncomeSource?) {
        self.incomeSource = incomeSource
        _name = State(initialValue: incomeSource?.name ?? "")
        _type = State(initialValue: incomeSource?.type ?? .salary)
        _amountText = State(initialValue: Formatters.decimalString(for: incomeSource?.amount))
        _isRecurring = State(initialValue: incomeSource?.isRecurring ?? true)
        _startDate = State(initialValue: incomeSource?.startDate ?? Date())
        _hasEndDate = State(initialValue: incomeSource?.isRecurring == true && incomeSource?.endDate != nil)
        _endDate = State(initialValue: incomeSource?.endDate ?? incomeSource?.startDate ?? Date())
        _isActive = State(initialValue: incomeSource?.isActive ?? true)
    }

    private var isEditing: Bool {
        incomeSource != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAmountText: String {
        amountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAmount: Decimal? {
        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: incomeSource?.amount), decimal > .zero else {
            return nil
        }

        return decimal.currencyRounded
    }

    private var resolvedEndDate: Date? {
        guard isRecurring, hasEndDate else {
            return nil
        }

        return endDate
    }

    private var nameError: String? {
        trimmedName.isEmpty ? AppLocalizer.string("income.validation.nameRequired", locale: locale) : nil
    }

    private var amountError: String? {
        guard !trimmedAmountText.isEmpty else {
            return AppLocalizer.string("income.validation.amountRequired", locale: locale)
        }

        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: incomeSource?.amount) else {
            return AppLocalizer.string("income.validation.validAmount", locale: locale)
        }

        guard decimal > .zero else {
            return AppLocalizer.string("income.validation.amountPositive", locale: locale)
        }

        return nil
    }

    private var endDateError: String? {
        guard isRecurring, hasEndDate, endDate < startDate else {
            return nil
        }

        return AppLocalizer.string("income.validation.endDateAfterStart", locale: locale)
    }

    private var isFormValid: Bool {
        nameError == nil &&
            amountError == nil &&
            endDateError == nil
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                TextField(AppLocalizer.string("income.form.field.name", locale: locale), text: $name)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("income-source-form-name-field")

                if let message = validationMessage(for: .name) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("income-source-form-name-error")
                }

                Picker(AppLocalizer.string("income.form.field.type", locale: locale), selection: $type) {
                    ForEach(IncomeType.allCases, id: \.self) { type in
                        Text(type.displayName(locale: locale)).tag(type)
                    }
                }
                .accessibilityIdentifier("income-source-form-type-picker")

                TextField(AppLocalizer.string("income.form.field.amount", locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .amount)
                    .accessibilityIdentifier("income-source-form-amount-field")

                if let message = validationMessage(for: .amount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("income-source-form-amount-error")
                }

                Toggle(AppLocalizer.string("income.form.field.recurring", locale: locale), isOn: $isRecurring)
                    .accessibilityIdentifier("income-source-form-recurring-toggle")
            }

            Section(AppLocalizer.string("income.section.schedule", locale: locale)) {
                DatePicker(
                    AppLocalizer.string("income.form.field.startDate", locale: locale),
                    selection: $startDate,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("income-source-form-start-date-picker")

                if isRecurring {
                    Toggle(AppLocalizer.string("income.form.field.hasEndDate", locale: locale), isOn: $hasEndDate)
                        .accessibilityIdentifier("income-source-form-has-end-date-toggle")

                    if hasEndDate {
                        DatePicker(
                            AppLocalizer.string("income.form.field.endDate", locale: locale),
                            selection: $endDate,
                            displayedComponents: .date
                        )
                        .accessibilityIdentifier("income-source-form-end-date-picker")

                        if let endDateError {
                            FormValidationMessageView(message: endDateError)
                                .accessibilityIdentifier("income-source-form-end-date-error")
                        }
                    }
                }
            }

            if let incomeSource, incomeSource.isActive {
                Section {
                    NavigationLink { IncomeForecastFormView(incomeID: incomeSource.id) } label: {
                        Text(AppLocalizer.string("treasury.incomeSchedule", locale: locale))
                    }.accessibilityIdentifier("income-forecast-schedule")
                }
            }
            Section(AppLocalizer.string("income.section.status", locale: locale)) {
                Toggle(AppLocalizer.string("income.form.field.active", locale: locale), isOn: $isActive)
                    .accessibilityIdentifier("income-source-form-active-toggle")
            }
        }
        .navigationTitle(
            isEditing
            ? AppLocalizer.string("income.form.source.editTitle", locale: locale)
            : AppLocalizer.string("income.form.source.newTitle", locale: locale)
        )
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .onChange(of: isRecurring) { _, isRecurring in
            if !isRecurring {
                hasEndDate = false
            }
        }
        .onChange(of: hasEndDate) { _, hasEndDate in
            if hasEndDate && endDate < startDate {
                endDate = startDate
            }
        }
        .alert(
            AppLocalizer.string("income.form.source.errorTitle", locale: locale),
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
                .accessibilityIdentifier("income-source-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    saveIncomeSource()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("income-source-form-save-button")
            }
        }
    }

    private func saveIncomeSource() {
        guard let amount = parsedAmount else {
            return
        }

        do {
            if let incomeSource {
                try appState.updateIncomeSource(
                    incomeSource,
                    name: name,
                    amount: amount,
                    type: type,
                    startDate: startDate,
                    endDate: resolvedEndDate,
                    isRecurring: isRecurring,
                    isActive: isActive
                )
            } else {
                try appState.addIncomeSource(
                    name: name,
                    amount: amount,
                    type: type,
                    startDate: startDate,
                    endDate: resolvedEndDate,
                    isRecurring: isRecurring,
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

#Preview("New Income Source") {
    NavigationStack {
        IncomeSourceFormView(incomeSource: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Income Source") {
    let previewState = AppState.preview

    return NavigationStack {
        IncomeSourceFormView(incomeSource: previewState.incomeSources.first)
            .environmentObject(previewState)
    }
}
