import SwiftUI

struct ProvisionsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var adding = false
    var body: some View {
        List {
            if appState.provisionSummaries().isEmpty { Text(AppLocalizer.string("provision.empty", locale: locale)) }
            ForEach(appState.provisionSummaries(), id: \.goalID) { summary in
                NavigationLink { ProvisionDetailView(goalID: summary.goalID) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title).font(.headline)
                        Text(Formatters.dateString(for: summary.dueDate))
                        Text(AppLocalizer.format("provision.reserveSummary %@ %@", locale: locale, Formatters.currencyString(for: summary.reserved), Formatters.currencyString(for: summary.target)))
                    }
                }.accessibilityIdentifier("provision-row-\(summary.goalID)")
            }
        }
        .navigationTitle(AppLocalizer.string("provision.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(AppLocalizer.string("provision.add", locale: locale)).accessibilityIdentifier("provision-add")
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { ProvisionFormView() } }
    }
}

struct ProvisionDetailView: View {
    let goalID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var errorMessage: String?
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    var body: some View {
        List {
            if let summary = appState.provisionSummaries().first(where: { $0.goalID == goalID }) {
                Section {
                    Text(summary.title).font(.title2.bold()).accessibilityIdentifier("provision-detail-title")
                    LabeledContent(text("Target Date"), value: Formatters.dateString(for: summary.dueDate))
                    LabeledContent(text("Target Amount"), value: Formatters.currencyString(for: summary.target))
                    LabeledContent(text("provision.paid"), value: Formatters.currencyString(for: summary.paid))
                    LabeledContent(text("provision.monthlyNeeded"), value: Formatters.currencyString(for: summary.monthlyNeeded))
                        .accessibilityIdentifier("provision-monthly-needed")
                    Text(text("provision.suggestionHelp")).font(.footnote).foregroundStyle(.secondary)
                    if summary.monthlyNeeded > 0 {
                        Button(AppLocalizer.format("provision.reserveSuggested %@", locale: locale, Formatters.currencyString(for: summary.monthlyNeeded))) {
                            guard appState.isProfileActive else { return }
                            do { try appState.dataStore.reserveForGoal(id: goalID, amount: summary.monthlyNeeded, date: Date()); appState.reload() }
                            catch { errorMessage = error.userMessage }
                        }.accessibilityIdentifier("provision-reserve-suggested")
                    }
                    if summary.renewal != "completed" {
                        Button(text("Edit")) { editing = true }.accessibilityIdentifier("provision-edit")
                    }
                    NavigationLink { ProvisionPaymentView(goalID: goalID) } label: {
                        Text(text("provision.matchPayment"))
                    }.accessibilityIdentifier("provision-match-payment")
                }
                GoalReservationSection(goalID: goalID)
                let payments = appState.planning.provisionPayments.filter { $0.goalID == goalID }
                if !payments.isEmpty {
                    Section(text("provision.payments")) {
                        ForEach(payments, id: \.transactionID) { payment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(appState.planning.paymentTransactions.first { $0.id == payment.transactionID }?.label ?? text("commitments.paymentUnavailable"))
                                Button(text("commitments.unmatch"), role: .destructive) {
                                    perform { try $0.removeProvisionPayment(transactionID: payment.transactionID) }
                                }.accessibilityIdentifier("provision-unmatch-\(payment.transactionID)")
                            }
                        }
                    }
                }
                if summary.renewal == "yearly", summary.paid >= summary.target {
                    Section {
                        Button(text("provision.renew")) {
                            do { try appState.planningWrite { try $0.renewProvision(goalID: goalID) }; dismiss() }
                            catch { errorMessage = error.userMessage }
                        }.accessibilityIdentifier("provision-renew")
                    } footer: { Text(text("provision.renewHelp")) }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error) }
        }
        .navigationTitle(text("provision.detail"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(text("Done")) { dismiss() } } }
        .sheet(isPresented: $editing) { NavigationStack { ProvisionFormView(goalID: goalID) } }
    }
    private func perform(_ action: (PeculeDataStore) throws -> Void) {
        do { try appState.planningWrite(action) } catch { errorMessage = error.userMessage }
    }
}

struct ProvisionFormView: View {
    var goalID: UUID?
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var newID = UUID()
    @State private var title = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var renewal = "none"
    @State private var category = ExpenseCategory.other.storageValue
    @State private var errorMessage: String?
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    // Le montant dont le champ est prérempli : tant que le texte n'est pas modifié, il passe tel quel.
    private var savedTarget: Decimal? { appState.goals.first(where: { $0.id == goalID })?.targetAmount }
    var body: some View {
        Form {
            TextField(text("Title"), text: $title).accessibilityIdentifier("provision-name")
            TextField(text("Target Amount"), text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("provision-amount")
            DatePicker(text("Target Date"), selection: $date, displayedComponents: .date)
            Picker(text("provision.renewal"), selection: $renewal) {
                Text(text("provision.once")).tag("none")
                Text(text("provision.yearly")).tag("yearly")
            }
            CategorySelectionView(selection: $category, identifier: "provision-category")
            Text(text("provision.noAutomaticReservation")).font(.footnote).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error) }
        }
        .navigationTitle(text(goalID == nil ? "provision.add" : "provision.detail"))
        .onAppear {
            if let goal = appState.goals.first(where: { $0.id == goalID }) {
                title = goal.title; amount = Formatters.decimalString(for: goal.targetAmount); category = goal.category
                date = goal.targetDate; renewal = appState.planning.provisions.first { $0.goalID == goal.id }?.renewal ?? "none"
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(text("Cancel")) { dismiss() }.accessibilityIdentifier("provision-cancel") }
            ToolbarItem(placement: .confirmationAction) {
                Button(text("Save")) {
                    guard let value = Formatters.decimalValue(from: amount, prefilledWith: savedTarget) else { return }
                    do {
                        try appState.planningWrite { try $0.saveProvision(id: goalID ?? newID, title: title, target: value, dueDate: date, renewal: renewal, category: category) }
                        dismiss()
                    } catch { errorMessage = error.userMessage }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (Formatters.decimalValue(from: amount, prefilledWith: savedTarget) ?? 0) <= 0)
                    .accessibilityIdentifier("provision-save")
            }
        }
    }
}

private struct ProvisionPaymentView: View {
    let goalID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    private var candidates: [BankTransaction] {
        let assigned = appState.planning.assignedTransactionIDs
        return appState.bankTransactions.filter {
            PeculeDataStore.validProvisionPayment($0, now: Date(), calendar: .current)
                && PeculeDataStore.isTransactionFree($0, assignedTransactionIDs: assigned)
        }.sorted { $0.bookingDate > $1.bookingDate }
    }
    var body: some View {
        List {
            Text(AppLocalizer.string("provision.paymentHelp", locale: locale)).font(.footnote)
            if let selectedID, let selected = candidates.first(where: { $0.id == selectedID }) {
                Section {
                    LabeledContent(selected.label, value: Formatters.currencyString(for: selected.amount))
                    Button(AppLocalizer.string("provision.confirmPayment", locale: locale)) {
                        do { try appState.planningWrite { try $0.applyProvisionPayment(goalID: goalID, transactionID: selectedID) }; dismiss() }
                        catch { errorMessage = error.userMessage }
                    }.accessibilityIdentifier("provision-payment-confirm")
                }
            }
            if candidates.isEmpty { Text(AppLocalizer.string("provision.noPayment", locale: locale)) }
            ForEach(candidates) { tx in
                Button { selectedID = tx.id } label: {
                    VStack(alignment: .leading) {
                        LabeledContent(tx.label, value: Formatters.currencyString(for: tx.amount))
                        Text(Formatters.dateString(for: tx.bookingDate)).font(.footnote)
                    }
                }.accessibilityIdentifier("provision-payment-\(tx.id)")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error) }
        }.navigationTitle(AppLocalizer.string("provision.matchPayment", locale: locale))
    }
}
