import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale
    @State private var presentedSheet: GoalSheet?
    @State private var errorMessage: String?
    @State private var goalPendingDeletion: Goal?

    var body: some View {
        Group {
            if appState.goals.isEmpty {
                EmptyStateView(
                    title: AppLocalizer.string("No goals created", locale: locale),
                    message: AppLocalizer.string("Create a financial or personal goal to start tracking your progress.", locale: locale),
                    systemImage: "target",
                    buttonTitle: AppLocalizer.string("Add Goal", locale: locale),
                    action: {
                        presentedSheet = .add
                    },
                    tint: AppColors.goalTint,
                    identifier: "goals-empty-state"
                )
            } else {
                List {
                    Section {
                        NavigationLink { GoalAllocationView() } label: {
                            Label(AppLocalizer.string("allocation.title", locale: locale), systemImage: "arrow.triangle.branch")
                        }.accessibilityIdentifier("goals-allocation")
                    }
                    if !appState.activeGoals.isEmpty {
                        Section(AppLocalizer.string("Active Goals", locale: locale)) {
                            ForEach(appState.activeGoals) { goal in
                                Button {
                                    presentedSheet = .edit(goal)
                                } label: {
                                    ActiveGoalRowView(goal: goal, isFeatured: goal.id == appState.activeGoals.first?.id)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("goal-row-\(goal.id.uuidString)")
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        goalPendingDeletion = goal
                                    } label: {
                                        Label(AppLocalizer.string("Delete", locale: locale), systemImage: "trash")
                                    }
                                    .tint(AppColors.error)
                                    .accessibilityIdentifier("goals-delete-button")
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }

                    if !appState.archivedGoals.isEmpty {
                        Section(AppLocalizer.string("Archived", locale: locale)) {
                            ForEach(appState.archivedGoals) { goal in
                                ArchivedGoalRowView(goal: goal, locale: locale)
                                    .accessibilityIdentifier("archived-goal-row-\(goal.id.uuidString)")
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
                    }
                    Section {
                        Button { navigation.open(.budgets) } label: {
                            Label(AppLocalizer.string("overview.goal.budget", locale: locale), systemImage: "chart.bar")
                        }
                        .accessibilityIdentifier("goals-budget-button")
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text(AppLocalizer.string("overview.goal.separateBalance", locale: locale))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColors.overviewBackground.ignoresSafeArea())
                .accessibilityIdentifier("goals-list")
            }
        }
        .navigationTitle(AppLocalizer.string("Goals", locale: locale))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PurchaseSimulationsView() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel(AppLocalizer.string("simulation.title", locale: locale)).accessibilityIdentifier("goals-simulations")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { ProvisionsView() } label: { Image(systemName: "calendar.badge.clock") }
                    .accessibilityLabel(AppLocalizer.string("provision.title", locale: locale)).accessibilityIdentifier("goals-provisions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalizer.string("Add Goal", locale: locale))
                .accessibilityIdentifier("goals-add-button")
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, _ in
            consumePendingRoute()
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .add:
                    GoalFormView(goal: nil)
                case let .edit(goal):
                    if goal.normalizedIntention == .plannedExpense { ProvisionDetailView(goalID: goal.id) }
                    else { GoalFormView(goal: goal) }
                }
            }
            .environmentObject(appState)
        }
        .deleteConfirmation($goalPendingDeletion, name: \.title) { deleteGoal($0) }
        .alert(
            AppLocalizer.string("Unable to Change Goal", locale: locale),
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

    private func deleteGoal(_ goal: Goal) {
        do {
            try appState.deleteGoal(goal)
        } catch {
            errorMessage = error.userMessage
        }
    }
    private func consumePendingRoute() {
        guard let route = navigation.consume(where: { if case .goal = $0 { return true } else { return false } }),
              case .goal(let id) = route,
              let id,
              let item = appState.goals.first(where: { $0.id == id }) else {
            return
        }
        presentedSheet = .edit(item)
    }

}

#Preview {
    NavigationStack {
        GoalsView()
            .environmentObject(AppNavigation())
            .environmentObject(AppState.preview)
    }
}

#Preview("Empty") {
    let previewState = AppState.preview
    previewState.goals = []

    return NavigationStack {
        GoalsView()
            .environmentObject(AppNavigation())
            .environmentObject(previewState)
    }
}

private enum GoalSheet: Identifiable {
    case add
    case edit(Goal)

    var id: String {
        switch self {
        case .add:
            return "add"
        case let .edit(goal):
            return goal.id.uuidString
        }
    }
}

private struct ActiveGoalRowView: View {
    @Environment(\.locale) private var locale
    let goal: Goal
    let isFeatured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(goal.title)
                    .font(isFeatured ? .title2.weight(.semibold) : AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Spacer()

                Text(Formatters.percentString(for: goal.progress))
                    .font(AppTypography.rowSubtitle.weight(.medium))
                    .foregroundStyle(AppColors.secondaryText)
            }

            if isFeatured {
                OverviewAmountView(value: Formatters.currencyString(for: goal.currentAmount))
                Text(AppLocalizer.format("overview.goal.target %@", locale: locale, Formatters.currencyString(for: goal.targetAmount)))
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
            }

            ProgressView(value: goal.progress)
                .tint(AppColors.goalTint)

            HStack {
                Text(ExpenseCategory.displayName(forStoredValue: goal.category, locale: locale))
                Spacer()
                if let date = goal.deadline() { Text(Formatters.dateString(for: date)) }
                else { Text(AppLocalizer.string("goal.noDeadline", locale: locale)) }
            }
            .font(AppTypography.rowSubtitle)
            .foregroundStyle(AppColors.secondaryText)

            if !isFeatured {
                Text("\(Formatters.currencyString(for: goal.currentAmount)) / \(Formatters.currencyString(for: goal.targetAmount))")
                .font(AppTypography.rowMeta)
                .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Formatters.percentString(for: goal.progress))
    }
}

private struct ArchivedGoalRowView: View {
    let goal: Goal
    let locale: Locale

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(goal.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Text(ExpenseCategory.displayName(forStoredValue: goal.category, locale: locale))
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppColors.secondaryText)
            }

            Spacer()

            Text(goal.progress >= 1 ? AppLocalizer.string("Completed", locale: locale) : AppLocalizer.string("Archived", locale: locale))
                .font(AppTypography.badge)
                .foregroundStyle(goal.progress >= 1 ? AppColors.success : AppColors.secondaryText)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}
