import SwiftUI

struct GoalFormView: View {
    private enum Field: Hashable {
        case title
        case category
        case targetAmount
        case currentAmount
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let goal: Goal?

    @State private var title: String
    @State private var targetAmountText: String
    @State private var currentAmountText: String
    @State private var targetDate: Date
    @State private var intention: GoalIntention
    @State private var durationMonths: Int
    @State private var showsHelp: Bool
    @State private var category: String
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @State private var simulatedContribution: Double = 0
    @FocusState private var focusedField: Field?

    init(goal: Goal?) {
        self.goal = goal
        _intention = State(initialValue: goal?.normalizedIntention ?? .purchase)
        _durationMonths = State(initialValue: goal?.durationMonths ?? 12)
        _showsHelp = State(initialValue: goal?.showsFundingHelp ?? false)
        _title = State(initialValue: goal?.title ?? "")
        _targetAmountText = State(initialValue: Formatters.decimalString(for: goal?.targetAmount))
        _currentAmountText = State(initialValue: Formatters.decimalString(for: goal?.currentAmount ?? .zero))
        _targetDate = State(initialValue: goal?.targetDate ?? Date())
        _category = State(initialValue: goal?.category ?? ExpenseCategory.other.storageValue)
    }

    private var isEditing: Bool {
        goal != nil
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCategory: String {
        category.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTargetAmountText: String {
        targetAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCurrentAmountText: String {
        currentAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Un champ resté tel qu'il a été prérempli garde la valeur de l'objectif, centimes compris : le relire
    // ne doit jamais l'altérer, sans quoi renommer un objectif réservé à 83,34 € l'enregistrait à 83 €,
    // sous la réservation (M025).
    private var enteredTargetAmount: Decimal? {
        Formatters.decimalValue(from: targetAmountText, prefilledWith: goal?.targetAmount)
    }

    private var enteredCurrentAmount: Decimal? {
        Formatters.decimalValue(from: currentAmountText, prefilledWith: goal?.currentAmount ?? .zero)
    }

    // Les montants que « Enregistrer » écrit, ou nil si l'un des deux champs est invalide. Extrait de la
    // vue pour que le parcours « renommer un objectif réservé » se teste sans interface.
    static func amountsToSave(targetText: String, currentText: String, goal: Goal?) -> (target: Decimal, current: Decimal)? {
        guard let target = Formatters.decimalValue(from: targetText, prefilledWith: goal?.targetAmount), target > .zero,
              let current = Formatters.decimalValue(from: currentText, prefilledWith: goal?.currentAmount ?? .zero), current >= .zero else {
            return nil
        }

        return (target.currencyRounded, current.currencyRounded)
    }

    private var titleError: String? {
        trimmedTitle.isEmpty ? AppLocalizer.string("Title is required.", locale: locale) : nil
    }

    private var categoryError: String? {
        trimmedCategory.isEmpty ? AppLocalizer.string("Category is required.", locale: locale) : nil
    }

    private var targetAmountError: String? {
        guard !trimmedTargetAmountText.isEmpty else {
            return AppLocalizer.string("Target amount is required.", locale: locale)
        }

        guard let decimal = enteredTargetAmount else {
            return AppLocalizer.string("Enter a valid target amount.", locale: locale)
        }

        guard decimal > .zero else {
            return AppLocalizer.string("Enter a target amount greater than 0.", locale: locale)
        }

        return nil
    }

    private var currentAmountError: String? {
        guard !trimmedCurrentAmountText.isEmpty else {
            return AppLocalizer.string("Current amount is required.", locale: locale)
        }

        guard let decimal = enteredCurrentAmount else {
            return AppLocalizer.string("Enter a valid current amount.", locale: locale)
        }

        guard decimal >= .zero else {
            return AppLocalizer.string("Enter an amount of 0 or more.", locale: locale)
        }

        return nil
    }

    private var isFormValid: Bool {
        titleError == nil &&
        categoryError == nil &&
        targetAmountError == nil &&
        currentAmountError == nil
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                TextField(AppLocalizer.string("Title", locale: locale), text: $title)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("goal-form-title-field")

                if let message = validationMessage(for: .title) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("goal-form-title-error")
                }

                CategorySelectionView(selection: $category, identifier: "goal-form-category-field")

                if let message = validationMessage(for: .category) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("goal-form-category-error")
                }

                Picker(AppLocalizer.string("goal.intention", locale: locale), selection: $intention) {
                    ForEach(GoalIntention.allCases.filter { $0 != .plannedExpense }) { item in
                        Text(AppLocalizer.string("goal.intention." + item.rawValue, locale: locale)).tag(item)
                    }
                }.accessibilityIdentifier("goal-intention-picker")
                if intention == .deadline || intention == .plannedExpense {
                    DatePicker(AppLocalizer.string("Target Date", locale: locale), selection: $targetDate, displayedComponents: .date)
                        .accessibilityIdentifier("goal-date-picker")
                }
                if intention == .duration {
                    Stepper(AppLocalizer.format("goal.duration %lld", locale: locale, Int64(durationMonths)), value: $durationMonths, in: 1...120)
                        .accessibilityIdentifier("goal-duration-stepper")
                }
                Toggle(AppLocalizer.string("goal.funding.help", locale: locale), isOn: $showsHelp)
                    .accessibilityIdentifier("goal-help-toggle")
                Text(AppLocalizer.string("goal.funding.helpExplanation", locale: locale)).font(.footnote)
            }

            Section(AppLocalizer.string("Progress", locale: locale)) {
                TextField(AppLocalizer.string("Target Amount", locale: locale), text: $targetAmountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .targetAmount)
                    .accessibilityIdentifier("goal-form-target-amount-field")

                if let message = validationMessage(for: .targetAmount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("goal-form-target-amount-error")
                }

                TextField(AppLocalizer.string("Current Amount", locale: locale), text: $currentAmountText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .currentAmount)
                    .accessibilityIdentifier("goal-form-current-amount-field")

                if let message = validationMessage(for: .currentAmount) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("goal-form-current-amount-error")
                }
            }

            if let goal {
                GoalReservationSection(goalID: goal.id)
            }
            if let simulation = currentSimulation {
                Section {
                    Slider(value: $simulatedContribution, in: 0 ... simulatorUpperBound, step: 10) {
                        Text(AppLocalizer.string("goal.simulator.contribution", locale: locale))
                    }
                    .accessibilityIdentifier("goal-form-simulator-slider")

                    Text(AppLocalizer.format("goal.simulator.contribution %@", locale: locale, Formatters.currencyString(for: simulation.monthlyContribution)))
                        .font(AppTypography.rowTitle)

                    if let months = simulation.monthsToReach, let completion = simulation.completionDate {
                        Text(months == 0
                            ? AppLocalizer.string("goal.simulator.reached", locale: locale)
                            : AppLocalizer.format("goal.simulator.result %lld %@", locale: locale, months, Formatters.dateString(for: completion)))
                            .font(AppTypography.secondaryBody)
                            .accessibilityIdentifier("goal-form-simulator-result")
                        if let slip = simulation.slipMonths, slip > 0 {
                            Text(AppLocalizer.format("goal.simulator.slip %lld", locale: locale, slip))
                                .font(AppTypography.rowMeta)
                                .foregroundStyle(AppColors.warning)
                        }
                    } else {
                        Text(AppLocalizer.string("goal.simulator.never", locale: locale))
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.secondaryText)
                    }

                    if let needed = simulation.monthlyNeededForTargetDate, needed > .zero {
                        Text(AppLocalizer.format("goal.simulator.needed %@", locale: locale, Formatters.currencyString(for: needed)))
                            .font(AppTypography.rowMeta)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                } header: {
                    Text(AppLocalizer.string("goal.simulator.section", locale: locale))
                } footer: {
                    Text(AppLocalizer.string("goal.simulator.footer", locale: locale))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("goal-form-simulator")
            }
        }
        .onChange(of: goal?.currentAmount) { _, value in currentAmountText = Formatters.decimalString(for: value) }
        .onAppear {
            if simulatedContribution == 0, let inputs = currentSimulationInputs,
               let needed = GoalSimulator().monthlyNeeded(target: inputs.target, current: inputs.current, targetDate: targetDate, now: Date()) {
                simulatedContribution = NSDecimalNumber(decimal: needed).doubleValue
            }
        }
        .navigationTitle(isEditing ? AppLocalizer.string("Edit Goal", locale: locale) : AppLocalizer.string("New Goal", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .alert(
            AppLocalizer.string("Unable to Save Goal", locale: locale),
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
                .accessibilityIdentifier("goal-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    saveGoal()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("goal-form-save-button")
            }
        }
    }

    private var currentSimulationInputs: (target: Decimal, current: Decimal)? {
        guard let target = enteredTargetAmount, target > .zero else {
            return nil
        }
        let current = enteredCurrentAmount ?? .zero
        guard current < target else {
            return nil
        }
        return (target, current)
    }

    private var simulatorUpperBound: Double {
        guard let inputs = currentSimulationInputs else {
            return 100
        }
        let remaining = NSDecimalNumber(decimal: inputs.target - inputs.current).doubleValue
        return max((remaining / 2).rounded(.up), 50)
    }

    private var effectiveTargetDate: Date? {
        switch intention {
        case .deadline, .plannedExpense: targetDate
        case .duration: Calendar.current.date(byAdding: .month, value: durationMonths, to: goal?.startedAt ?? Date())
        case .purchase, .reserve: nil
        }
    }

    private var currentSimulation: GoalSimulation? {
        guard let inputs = currentSimulationInputs else {
            return nil
        }
        return GoalSimulator().simulate(
            target: inputs.target,
            current: inputs.current,
            targetDate: effectiveTargetDate,
            monthlyContribution: Decimal(simulatedContribution).currencyRounded,
            now: Date()
        )
    }

    private func saveGoal() {
        guard let amounts = Self.amountsToSave(targetText: targetAmountText, currentText: currentAmountText, goal: goal) else {
            return
        }

        do {
            guard appState.isProfileActive else { throw BankTransactionEditError.unavailable }
            try appState.dataStore.saveGoalPlan(id: goal?.id, title: title, target: amounts.target, current: amounts.current,
                category: category, intention: intention, targetDate: targetDate, durationMonths: durationMonths, showsHelp: showsHelp)
            appState.reload()

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
        case .category:
            return categoryError
        case .targetAmount:
            return targetAmountError
        case .currentAmount:
            return currentAmountError
        }
    }
}

#Preview("New Goal") {
    NavigationStack {
        GoalFormView(goal: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Goal") {
    let previewState = AppState.preview

    return NavigationStack {
        GoalFormView(goal: previewState.activeGoals.first)
            .environmentObject(previewState)
    }
}
