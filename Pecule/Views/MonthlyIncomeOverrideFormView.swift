import SwiftUI

struct MonthlyIncomeOverrideFormView: View {
    private enum Field: Hashable {
        case amount
    }

    private enum OverrideMode: String, CaseIterable, Hashable {
        case replace
        case adjustment

        var replacesSourceAmount: Bool {
            self == .replace
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let monthlyIncomeOverride: MonthlyIncomeOverride?

    @State private var incomeSourceID: UUID?
    @State private var month: Date
    @State private var mode: OverrideMode
    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @State private var hasTouchedSource = false
    @FocusState private var focusedField: Field?

    init(monthlyIncomeOverride: MonthlyIncomeOverride?, defaultMonth: Date = Date()) {
        let normalizedMonth = Calendar.current.peculeMonthStart(for: monthlyIncomeOverride?.monthStartDate ?? defaultMonth)
        self.monthlyIncomeOverride = monthlyIncomeOverride
        _incomeSourceID = State(initialValue: monthlyIncomeOverride?.incomeSourceID)
        _month = State(initialValue: normalizedMonth)
        _mode = State(initialValue: monthlyIncomeOverride?.replacesSourceAmount == true ? .replace : .adjustment)
        _amountText = State(initialValue: Formatters.decimalString(for: monthlyIncomeOverride?.amount))
    }

    private var isEditing: Bool {
        monthlyIncomeOverride != nil
    }

    private var trimmedAmountText: String {
        amountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var availableIncomeSources: [IncomeSource] {
        appState.incomeSources.sorted { left, right in
            if left.isActive != right.isActive {
                return left.isActive && !right.isActive
            }

            if left.type.sortOrder != right.type.sortOrder {
                return left.type.sortOrder < right.type.sortOrder
            }

            let leftName = left.name.localizedCaseInsensitiveCompare(right.name)

            if leftName != .orderedSame {
                return leftName == .orderedAscending
            }

            return left.id.uuidString < right.id.uuidString
        }
    }

    private var parsedAmount: Decimal? {
        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: monthlyIncomeOverride?.amount) else {
            return nil
        }

        switch mode {
        case .replace:
            guard decimal >= .zero else {
                return nil
            }
        case .adjustment:
            guard decimal != .zero else {
                return nil
            }
        }

        return decimal.currencyRounded
    }

    private var sourceError: String? {
        incomeSourceID == nil ? AppLocalizer.string("income.validation.sourceRequired", locale: locale) : nil
    }

    private var amountError: String? {
        guard !trimmedAmountText.isEmpty else {
            return AppLocalizer.string("income.validation.amountRequired", locale: locale)
        }

        guard let decimal = Formatters.decimalValue(from: amountText, prefilledWith: monthlyIncomeOverride?.amount) else {
            return AppLocalizer.string("income.validation.validAmount", locale: locale)
        }

        switch mode {
        case .replace:
            guard decimal >= .zero else {
                return AppLocalizer.string("income.validation.overrideAmountNonNegative", locale: locale)
            }
        case .adjustment:
            guard decimal != .zero else {
                return AppLocalizer.string("income.validation.overrideAdjustmentNonZero", locale: locale)
            }
        }

        return nil
    }

    private var isFormValid: Bool {
        sourceError == nil && amountError == nil
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                Picker(
                    AppLocalizer.string("income.form.field.source", locale: locale),
                    selection: $incomeSourceID
                ) {
                    Text(AppLocalizer.string("income.form.field.selectSource", locale: locale))
                        .tag(Optional<UUID>.none)

                    ForEach(availableIncomeSources) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
                .accessibilityIdentifier("income-override-form-source-picker")
                .onChange(of: incomeSourceID) { _, _ in
                    hasTouchedSource = true
                }

                if hasTouchedSource, let sourceError {
                    FormValidationMessageView(message: sourceError)
                        .accessibilityIdentifier("income-override-form-source-error")
                }

                DatePicker(
                    AppLocalizer.string("income.form.field.month", locale: locale),
                    selection: $month,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("income-override-form-month-picker")

                Picker(AppLocalizer.string("income.form.field.adjustmentMode", locale: locale), selection: $mode) {
                    Text(AppLocalizer.string("income.override.mode.replace", locale: locale)).tag(OverrideMode.replace)
                    Text(AppLocalizer.string("income.override.mode.adjustment", locale: locale)).tag(OverrideMode.adjustment)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("income-override-form-mode-picker")

                TextField(AppLocalizer.string("income.form.field.amount", locale: locale), text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .amount)
                    .accessibilityIdentifier("income-override-form-amount-field")

                if let message = validationMessage(for: .amount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("income-override-form-amount-error")
                }
            }
        }
        .navigationTitle(
            isEditing
            ? AppLocalizer.string("income.form.override.editTitle", locale: locale)
            : AppLocalizer.string("income.form.override.newTitle", locale: locale)
        )
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .alert(
            AppLocalizer.string("income.form.override.errorTitle", locale: locale),
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
                .accessibilityIdentifier("income-override-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    saveOverride()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("income-override-form-save-button")
            }
        }
    }

    private func saveOverride() {
        guard let incomeSourceID, let amount = parsedAmount else {
            return
        }

        do {
            if let monthlyIncomeOverride {
                try appState.updateMonthlyIncomeOverride(
                    monthlyIncomeOverride,
                    incomeSourceID: incomeSourceID,
                    month: month,
                    amount: amount,
                    replacesSourceAmount: mode.replacesSourceAmount
                )
            } else {
                try appState.addMonthlyIncomeOverride(
                    incomeSourceID: incomeSourceID,
                    month: month,
                    amount: amount,
                    replacesSourceAmount: mode.replacesSourceAmount
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
        case .amount:
            return amountError
        }
    }
}

#Preview("New Monthly Adjustment") {
    NavigationStack {
        MonthlyIncomeOverrideFormView(monthlyIncomeOverride: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Monthly Adjustment") {
    let previewState = AppState.preview

    return NavigationStack {
        MonthlyIncomeOverrideFormView(monthlyIncomeOverride: previewState.monthlyIncomeOverrides.first)
            .environmentObject(previewState)
    }
}
