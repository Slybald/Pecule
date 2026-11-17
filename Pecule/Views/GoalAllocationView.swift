import SwiftUI

struct GoalAllocationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var editing = false
    @State private var addingGoal = false
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }

    var body: some View {
        let draft = appState.allocationDraft()
        let targets = appState.allocationTargets()
        List {
            Section {
                Text(text("allocation.intro"))
                if appState.planning.allocationPlans.isEmpty {
                    Text(text("allocation.noPlan")).foregroundStyle(.secondary)
                } else {
                    LabeledContent(text("allocation.capacity"), value: Formatters.currencyString(for: draft.capacity))
                        .accessibilityIdentifier("allocation-saved-capacity")
                    LabeledContent(text("allocation.allocated"), value: Formatters.currencyString(for: draft.allocated))
                    LabeledContent(text("allocation.unallocated"), value: Formatters.currencyString(for: draft.unallocated))
                }
                if targets.isEmpty {
                    Text(text("allocation.empty"))
                    Button(text("Add Goal")) { addingGoal = true }.accessibilityIdentifier("allocation-add-goal")
                } else {
                    Button(text("allocation.edit")) { editing = true }.accessibilityIdentifier("allocation-edit")
                }
            }
            if !targets.isEmpty {
                Section(text(appState.planning.allocationPlans.isEmpty ? "allocation.goalsToAllocate" : "allocation.savedPlan")) {
                    ForEach(draft.entries) { entry in
                        if let goal = targets.first(where: { $0.id == entry.goalID }) {
                            LabeledContent(goal.title, value: Formatters.currencyString(for: entry.amount))
                                .accessibilityIdentifier("allocation-saved-\(goal.id)")
                        }
                    }
                }
                if (try? GoalAllocationService.normalized(draft, targets: targets)) == nil {
                    Text(text("allocation.reviewChanged")).foregroundStyle(AppColors.warning)
                }
            }
        }
        .navigationTitle(text("allocation.title"))
        .sheet(isPresented: $editing) {
            NavigationStack { GoalAllocationEditor(initial: appState.allocationDraft(), targets: appState.allocationTargets()) }
        }
        .sheet(isPresented: $addingGoal) { NavigationStack { GoalFormView(goal: nil) } }
    }
}

private struct EditableAllocation: Identifiable {
    var id: UUID
    var amount: String
    // Le montant dont le champ a été prérempli : tant que le texte n'est pas modifié, il passe tel quel.
    let original: Decimal

    init(id: UUID, original: Decimal) {
        self.id = id
        self.original = original
        amount = Formatters.decimalString(for: original)
    }
}

private struct GoalAllocationEditor: View {
    let initial: AllocationDraft
    let targets: [AllocationTarget]
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var capacity: String
    @State private var entries: [EditableAllocation]
    @State private var errorMessage: String?
    @State private var preview: AllocationDraft?
    @State private var showingPreview = false

    init(initial: AllocationDraft, targets: [AllocationTarget]) {
        self.initial = initial; self.targets = targets
        _capacity = State(initialValue: Formatters.decimalString(for: initial.capacity))
        _entries = State(initialValue: initial.entries.map { .init(id: $0.goalID, original: $0.amount) })
    }
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    private func draft() throws -> AllocationDraft {
        guard let value = Formatters.decimalValue(from: capacity, prefilledWith: initial.capacity) else { throw AllocationError.invalidAmount }
        let rows = try entries.map { row in
            guard let amount = Formatters.decimalValue(from: row.amount, prefilledWith: row.original) else { throw AllocationError.invalidAmount }
            return AllocationEntry(goalID: row.id, amount: amount)
        }
        return AllocationDraft(capacity: value, entries: rows)
    }

    var body: some View {
        Form {
            Section {
                TextField(text("allocation.capacity"), text: $capacity).keyboardType(.decimalPad)
                    .accessibilityIdentifier("allocation-capacity")
                Text(text("allocation.capacityHelp")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(text("allocation.distribute")) {
                    do {
                        guard let value = Formatters.decimalValue(from: capacity, prefilledWith: initial.capacity) else { throw AllocationError.invalidAmount }
                        let input = AllocationDraft(capacity: value, entries: entries.map { .init(goalID: $0.id, amount: 0) })
                        let result = try GoalAllocationService.distribute(input, targets: targets)
                        entries = result.entries.map { .init(id: $0.goalID, original: $0.amount) }
                        errorMessage = nil
                    } catch { errorMessage = error.userMessage }
                }.accessibilityIdentifier("allocation-distribute")
                Text(text("allocation.priorityHelp")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(entries.indices, id: \.self) { index in
                if let goal = targets.first(where: { $0.id == entries[index].id }) {
                    Section {
                        Text(goal.title).font(.headline)
                        LabeledContent(text("allocation.remaining"), value: Formatters.currencyString(for: goal.remaining))
                        TextField(text("allocation.monthly"), text: $entries[index].amount).keyboardType(.decimalPad)
                            .accessibilityLabel(AppLocalizer.format("allocation.amountFor %@", locale: locale, goal.title))
                            .accessibilityIdentifier("allocation-amount-\(goal.id)")
                        HStack {
                            Text(AppLocalizer.format("allocation.priority %lld", locale: locale, Int64(index + 1)))
                            Spacer()
                            Button { entries.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up").frame(minWidth: 44, minHeight: 44) }
                                .disabled(index == 0).accessibilityLabel(text("allocation.moveUp"))
                                .accessibilityIdentifier("allocation-up-\(goal.id)")
                            Button { entries.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down").frame(minWidth: 44, minHeight: 44) }
                                .disabled(index == entries.count - 1).accessibilityLabel(text("allocation.moveDown"))
                                .accessibilityIdentifier("allocation-down-\(goal.id)")
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section {
                if let value = try? draft(), !value.capacity.isNaN, value.entries.allSatisfy({ !$0.amount.isNaN }) {
                    LabeledContent(text("allocation.unallocated"), value: Formatters.currencyString(for: value.unallocated))
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error).accessibilityIdentifier("allocation-error") }
                Button(text("allocation.preview")) {
                    do {
                        preview = try GoalAllocationService.normalized(draft(), targets: targets)
                        errorMessage = nil; showingPreview = true
                    } catch { errorMessage = error.userMessage }
                }.accessibilityIdentifier("allocation-preview")
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(text("allocation.edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("Cancel")) { dismiss() }.accessibilityIdentifier("allocation-cancel")
            }
        }
        .navigationDestination(isPresented: $showingPreview) {
            if let preview { GoalAllocationPreview(before: initial, proposed: preview, targets: targets) { dismiss() } }
        }
    }
}

private struct GoalAllocationPreview: View {
    let before: AllocationDraft
    let proposed: AllocationDraft
    let targets: [AllocationTarget]
    let onSaved: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var errorMessage: String?
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    private func date(_ simulation: GoalSimulation) -> String {
        simulation.completionDate.map { Formatters.dateString(for: $0) } ?? text("allocation.noDate")
    }
    var body: some View {
        let results = (try? GoalAllocationService.compare(before: before, after: proposed, targets: targets, now: Date(), calendar: .current)) ?? []
        List {
            Section {
                LabeledContent(text("allocation.capacity"), value: Formatters.currencyString(for: proposed.capacity))
                LabeledContent(text("allocation.allocated"), value: Formatters.currencyString(for: proposed.allocated))
                LabeledContent(text("allocation.unallocated"), value: Formatters.currencyString(for: proposed.unallocated))
                Text(text("allocation.assumptions")).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("allocation-preview-help")
            }
            ForEach(results) { result in
                Section(result.target.title) {
                    LabeledContent(text("allocation.beforeAmount"), value: Formatters.currencyString(for: result.before.monthlyContribution))
                    LabeledContent(text("allocation.afterAmount"), value: Formatters.currencyString(for: result.after.monthlyContribution))
                    LabeledContent(text("allocation.beforeDate"), value: date(result.before))
                    LabeledContent(text("allocation.afterDate"), value: date(result.after))
                        .accessibilityIdentifier("allocation-date-\(result.id)")
                    if let deadline = result.target.deadline {
                        LabeledContent(text("Target Date"), value: Formatters.dateString(for: deadline))
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error).accessibilityIdentifier("allocation-save-error") }
        }
        .navigationTitle(text("allocation.preview"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(text("allocation.confirm")) {
                    do {
                        try appState.planningWrite { try $0.saveAllocationPlan(proposed) }
                        onSaved()
                    } catch { errorMessage = error.userMessage }
                }.accessibilityIdentifier("allocation-confirm")
            }
        }
    }
}
