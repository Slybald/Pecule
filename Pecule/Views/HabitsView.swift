import SwiftUI

struct HabitsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var presentedSheet: HabitSheet?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if appState.habits.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("No habits yet", locale: locale),
                    message: AppLocalizer.string("Build routines that support your goals.", locale: locale),
                    systemImage: "checkmark.circle.fill",
                    buttonTitle: AppLocalizer.string("Add Habit", locale: locale),
                    action: {
                        presentedSheet = .add
                    },
                    tint: AppColors.habitTint,
                    identifier: "habits-empty-state"
                )
            } else {
                List {
                    if !appState.activeHabits.isEmpty {
                        Section(AppLocalizer.string("Active Habits", locale: locale)) {
                            ForEach(appState.activeHabits) { habit in
                                ActiveHabitRowView(
                                    habit: habit,
                                    linkedGoalTitle: appState.goalTitle(for: habit.linkedGoalID),
                                    onEdit: {
                                        presentedSheet = .edit(habit)
                                    },
                                    onComplete: {
                                        completeHabit(habit)
                                    }
                                )
                                .accessibilityIdentifier("habit-row-\(habit.id.uuidString)")
                                .glassCard(padding: AppSpacing.md)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }

                    if !appState.inactiveHabits.isEmpty {
                        Section(AppLocalizer.string("Inactive", locale: locale)) {
                            ForEach(appState.inactiveHabits) { habit in
                                InactiveHabitRowView(
                                    habit: habit,
                                    linkedGoalTitle: appState.goalTitle(for: habit.linkedGoalID)
                                )
                                .accessibilityIdentifier("inactive-habit-row-\(habit.id.uuidString)")
                                .glassCard(padding: AppSpacing.md)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColors.background.ignoresSafeArea())
                .accessibilityIdentifier("habits-list")
            }
        }
        .navigationTitle(AppLocalizer.string("Habits", locale: locale))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalizer.string("Add Habit", locale: locale))
                .accessibilityIdentifier("habits-add-button")
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            consumePendingRoute()
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .add:
                    HabitFormView(habit: nil)
                case let .edit(habit):
                    HabitFormView(habit: habit)
                }
            }
            .environmentObject(appState)
        }
        .alert(
            AppLocalizer.string("Unable to Change Habit", locale: locale),
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
    }

    private func completeHabit(_ habit: Habit) {
        do {
            try appState.markHabitCompleted(habit)
            AppHaptics.play(.impact)
        } catch {
            errorMessage = error.userMessage
        }
    }
    private func consumePendingRoute() {
        guard let route = navigation.consume(where: { if case .habit = $0 { return true } else { return false } }),
              case .habit(let id) = route,
              let id,
              let item = appState.habits.first(where: { $0.id == id }) else {
            return
        }
        presentedSheet = .edit(item)
    }

}

#Preview {
    NavigationStack {
        HabitsView()
            .environmentObject(AppNavigation())
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty") {
    let previewState = AppState.preview
    previewState.habits = []

    return NavigationStack {
        HabitsView()
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}

private enum HabitSheet: Identifiable {
    case add
    case edit(Habit)

    var id: String {
        switch self {
        case .add:
            return "add"
        case let .edit(habit):
            return habit.id.uuidString
        }
    }
}

private struct ActiveHabitRowView: View {
    let habit: Habit
    let linkedGoalTitle: String?
    let onEdit: () -> Void
    let onComplete: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            Button(action: onEdit) {
                HabitSummaryView(
                    habit: habit,
                    linkedGoalTitle: linkedGoalTitle,
                    accentColor: AppColors.habitTint
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("habit-edit-button-\(habit.id.uuidString)")
            .accessibilityValue("\(habit.completedCount)/\(habit.targetCount)")

            Button(AppLocalizer.string("Complete", locale: locale)) {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.habitTint)
            .disabled(habit.completedCount >= habit.targetCount)
            .accessibilityIdentifier("habit-complete-button-\(habit.id.uuidString)")
            .accessibilityLabel(
                AppLocalizer.format("Complete %@", locale: locale, habit.title)
            )
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}

private struct InactiveHabitRowView: View {
    let habit: Habit
    let linkedGoalTitle: String?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HabitSummaryView(
                habit: habit,
                linkedGoalTitle: linkedGoalTitle,
                accentColor: AppColors.secondaryText
            )

            Text(AppLocalizer.string("Inactive", locale: locale))
                .font(AppTypography.badge)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}

private struct HabitSummaryView: View {
    let habit: Habit
    let linkedGoalTitle: String?
    let accentColor: Color
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(habit.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Spacer()

                Text(habit.frequency.displayName)
                    .font(AppTypography.badge)
                    .foregroundStyle(AppColors.secondaryText)
            }

            ProgressView(value: habit.progress)
                .tint(accentColor)

            HStack {
                Text(AppLocalizer.format("%@ of %@", locale: locale, "\(habit.completedCount)", "\(habit.targetCount)"))

                if let linkedGoalTitle {
                    Spacer()
                    Text(linkedGoalTitle)
                }
            }
            .font(AppTypography.rowSubtitle)
            .foregroundStyle(AppColors.secondaryText)
        }
    }
}
