import SwiftUI

struct HabitFormView: View {
    private enum Field: Hashable {
        case title
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var appState: AppState

    private let habit: Habit?

    @State private var title: String
    @State private var frequency: HabitFrequency
    @State private var targetCount: Int
    @State private var completedCount: Int
    @State private var linkedGoalID: UUID?
    @State private var errorMessage: String?
    @State private var touchedFields: Set<Field> = []
    @FocusState private var focusedField: Field?

    init(habit: Habit?) {
        self.habit = habit
        _title = State(initialValue: habit?.title ?? "")
        _frequency = State(initialValue: habit?.frequency ?? .daily)
        _targetCount = State(initialValue: max(habit?.targetCount ?? 1, 1))
        _completedCount = State(initialValue: max(habit?.completedCount ?? 0, 0))
        _linkedGoalID = State(initialValue: habit?.linkedGoalID)
    }

    private var isEditing: Bool {
        habit != nil
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var titleError: String? {
        trimmedTitle.isEmpty ? AppLocalizer.string("Title is required.", locale: locale) : nil
    }

    private var countsAreValid: Bool {
        targetCount > 0 && completedCount >= 0 && completedCount <= targetCount
    }

    private var isFormValid: Bool {
        titleError == nil && countsAreValid
    }

    private var availableGoals: [Goal] {
        appState.activeGoals + appState.archivedGoals
    }

    var body: some View {
        Form {
            Section(AppLocalizer.string("Details", locale: locale)) {
                TextField(AppLocalizer.string("Title", locale: locale), text: $title)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("habit-form-title-field")

                if let message = validationMessage(for: .title) {
                    FormValidationMessageView(message: message)
                        .accessibilityIdentifier("habit-form-title-error")
                }

                Picker(AppLocalizer.string("Frequency", locale: locale), selection: $frequency) {
                    ForEach(HabitFrequency.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }

            Section(AppLocalizer.string("Progress", locale: locale)) {
                Stepper(AppLocalizer.format("Target Count: %lld", locale: locale, Int64(targetCount)), value: $targetCount, in: 1...30)

                Stepper(
                    AppLocalizer.format("Completed Count: %lld", locale: locale, Int64(completedCount)),
                    value: $completedCount,
                    in: 0...targetCount
                )
            }

            Section(AppLocalizer.string("Linked Goal", locale: locale)) {
                Picker(AppLocalizer.string("Goal", locale: locale), selection: $linkedGoalID) {
                    Text(AppLocalizer.string("No Goal", locale: locale)).tag(nil as UUID?)

                    ForEach(availableGoals) { goal in
                        Text(goal.isArchived ? AppLocalizer.format("%@ (Archived)", locale: locale, goal.title) : goal.title)
                            .tag(Optional(goal.id))
                    }
                }
            }
        }
        .navigationTitle(isEditing ? AppLocalizer.string("Edit Habit", locale: locale) : AppLocalizer.string("New Habit", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: targetCount) { _, newValue in
            if completedCount > newValue {
                completedCount = newValue
            }

            markTitleAsTouchedIfNeeded()
        }
        .onChange(of: completedCount) { _, _ in
            markTitleAsTouchedIfNeeded()
        }
        .onChange(of: frequency) { _, _ in
            markTitleAsTouchedIfNeeded()
        }
        .onChange(of: linkedGoalID) { _, _ in
            markTitleAsTouchedIfNeeded()
        }
        .onChange(of: focusedField) { previousField, currentField in
            if let previousField, previousField != currentField {
                touchedFields.insert(previousField)
            }
        }
        .alert(
            AppLocalizer.string("Unable to Save Habit", locale: locale),
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
                .accessibilityIdentifier("habit-form-cancel-button")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    saveHabit()
                }
                .disabled(!isFormValid)
                .accessibilityIdentifier("habit-form-save-button")
            }
        }
    }

    private func saveHabit() {
        do {
            if let habit {
                try appState.updateHabit(
                    habit,
                    title: title,
                    frequency: frequency,
                    targetCount: targetCount,
                    completedCount: completedCount,
                    linkedGoalID: linkedGoalID
                )
            } else {
                try appState.addHabit(
                    title: title,
                    frequency: frequency,
                    targetCount: targetCount,
                    completedCount: completedCount,
                    linkedGoalID: linkedGoalID
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
        }
    }

    private func markTitleAsTouchedIfNeeded() {
        guard titleError != nil else {
            return
        }

        touchedFields.insert(.title)
    }
}

#Preview("New Habit") {
    NavigationStack {
        HabitFormView(habit: nil)
            .environmentObject(AppState.preview)
    }
}

#Preview("Edit Habit") {
    let previewState = AppState.preview

    return NavigationStack {
        HabitFormView(habit: previewState.activeHabits.first)
            .environmentObject(previewState)
    }
}

#Preview("Archived Goal Link") {
    let previewState = AppState.preview
    let habit = previewState.activeHabits.first
    habit?.linkedGoalID = previewState.archivedGoals.first?.id

    return NavigationStack {
        HabitFormView(habit: habit)
            .environmentObject(previewState)
    }
}
