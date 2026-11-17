import SwiftUI

struct CommitmentsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var newDraft: CommitmentDraft?

    var body: some View {
        let drafts = appState.commitmentDrafts().filter { $0.direction == "debit" }
        List {
            if drafts.isEmpty {
                Text(AppLocalizer.string("commitments.empty", locale: locale))
                    .foregroundStyle(.secondary)
            }
            ForEach(["confirmed", "suggested", "stopped", "rejected"], id: \.self) { status in
                let rows = drafts.filter { $0.status == status }
                if !rows.isEmpty {
                    Section(AppLocalizer.string("commitments.status." + status, locale: locale)) {
                        ForEach(rows) { draft in
                            NavigationLink { CommitmentDetailView(commitmentID: draft.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(draft.title).font(.headline)
                                    Text(Formatters.currencyString(for: draft.amount) + " · " + AppLocalizer.string("commitments.cadence." + draft.cadence, locale: locale))
                                    if let count = draft.count {
                                        Text(AppLocalizer.pluralFormat("commitments.scheduleCount %lld", locale: locale, Int64(count)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if draft.dueDate == nil {
                                        Text(AppLocalizer.string("commitments.noDate", locale: locale)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("commitment-row-\(draft.id)")
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLocalizer.string("commitments.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newDraft = CommitmentDraft() } label: {
                    Label(AppLocalizer.string("commitments.add", locale: locale), systemImage: "plus")
                }.accessibilityIdentifier("commitments-add")
            }
        }
        .sheet(item: $newDraft) { draft in NavigationStack { CommitmentFormView(draft: draft) } }
    }
}

struct CommitmentDetailView: View {
    let commitmentID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var editing: CommitmentDraft?
    @State private var matching: ForecastEvent?
    @State private var errorMessage: String?

    private var draft: CommitmentDraft? { appState.commitmentDrafts().first { $0.id == commitmentID } }
    private var events: [ForecastEvent] {
        let now = Date()
        return appState.planningEvents(on: now, until: Calendar.current.date(byAdding: .year, value: 1, to: now)!)
            .filter { $0.commitmentID == commitmentID }
    }

    var body: some View {
        List {
            if let draft {
                Section {
                    Text(draft.title).font(.title2.bold()).accessibilityIdentifier("commitment-title")
                    LabeledContent(AppLocalizer.string("commitments.amount", locale: locale), value: Formatters.currencyString(for: draft.amount))
                    Text(AppLocalizer.string("commitments.status." + draft.status, locale: locale))
                        .accessibilityIdentifier("commitment-status")
                    Text(draft.accountID.flatMap { appState.externalAccount(id: $0)?.name } ?? AppLocalizer.string("commitments.noAccount", locale: locale))
                    if let annual = draft.annualCost {
                        LabeledContent(AppLocalizer.string("commitments.annual", locale: locale), value: Formatters.currencyString(for: annual))
                    }
                    if let increase = draft.priceIncrease {
                        Text(AppLocalizer.format("commitments.increase %@ %@", locale: locale,
                                                 Formatters.currencyString(for: increase),
                                                 Formatters.currencyString(for: increase * (draft.cadence == "monthly" ? 12 : 1))))
                            .foregroundStyle(AppColors.warning)
                    }
                    Button(AppLocalizer.string("Edit", locale: locale)) { editing = draft }
                        .accessibilityIdentifier("commitment-edit")
                    if draft.status == "suggested" {
                        // Confirmation always opens the editable amount, date, account and finite schedule.
                        Button(AppLocalizer.string("commitments.confirm", locale: locale)) { editing = draft }
                            .accessibilityIdentifier("commitment-confirm")
                        Button(AppLocalizer.string("commitments.reject", locale: locale)) { decide(draft, status: "rejected") }
                            .accessibilityIdentifier("commitment-reject")
                    } else if draft.status == "confirmed" {
                        Button(AppLocalizer.string("commitments.stop", locale: locale), role: .destructive) { decide(draft, status: "stopped") }
                            .accessibilityIdentifier("commitment-stop")
                    }
                }
                Section(AppLocalizer.string("commitments.schedule", locale: locale)) {
                    if events.isEmpty { Text(AppLocalizer.string("commitments.noUpcoming", locale: locale)).foregroundStyle(.secondary) }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.date.map { Formatters.dateString(for: $0) } ?? AppLocalizer.string("commitments.noDate", locale: locale))
                            Text(Formatters.currencyString(for: abs(event.amount))).font(.headline)
                            if event.confirmed, event.date != nil {
                                Button(AppLocalizer.string("commitments.match", locale: locale)) { matching = event }
                                    .accessibilityIdentifier("commitment-match-\(event.id)")
                            }
                        }.padding(.vertical, 4)
                    }
                }
                let payments = appState.planning.payments.filter { $0.commitmentID == commitmentID }
                if !payments.isEmpty {
                    Section(AppLocalizer.string("commitments.payments", locale: locale)) {
                        ForEach(payments, id: \.transactionID) { payment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(appState.planning.paymentTransactions.first { $0.id == payment.transactionID }?.label ?? AppLocalizer.string("commitments.paymentUnavailable", locale: locale))
                                Text(Formatters.currencyString(for: payment.amount))
                                Button(AppLocalizer.string("commitments.unmatch", locale: locale), role: .destructive) {
                                    perform { try $0.removeCommitmentPayment(transactionID: payment.transactionID) }
                                }
                            }
                        }
                    }
                }
            } else { Text(AppLocalizer.string("accounts.transaction.unavailable", locale: locale)) }
        }
        .navigationTitle(AppLocalizer.string("commitments.detail", locale: locale))
        .sheet(item: $editing) { draft in NavigationStack { CommitmentFormView(draft: draft) } }
        .sheet(item: $matching) { event in NavigationStack { CommitmentPaymentView(event: event) } }
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
    private func decide(_ draft: CommitmentDraft, status: String) {
        var updated = draft; updated.status = status
        perform { try $0.saveCommitment(updated) }
    }
    private func perform(_ action: (PeculeDataStore) throws -> Void) {
        do { try appState.planningWrite(action) } catch { errorMessage = error.userMessage }
    }
}

struct CommitmentFormView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State var draft: CommitmentDraft
    @State private var amount = ""
    @State private var count = ""
    @State private var hasDate = false
    @State private var dueDate = Date()
    @State private var finite = false
    @State private var errorMessage: String?

    private var scheduleLocked: Bool { appState.planning.payments.contains { $0.commitmentID == draft.id } }
    private var valid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (Self.enteredAmount(from: amount, in: draft).map { !$0.isNaN && $0.currencyRounded > 0 } ?? false) &&
        (!finite || Int(count).map { (1...1200).contains($0) } == true)
    }

    // Le montant du champ. Tant que le texte est celui du préremplissage, le montant du brouillon passe
    // tel quel : confirmer sans rien toucher ne doit modifier ni l'engagement ni l'abonnement source dont
    // il recopie le montant (M022).
    static func enteredAmount(from text: String, in draft: CommitmentDraft) -> Decimal? {
        Formatters.decimalValue(from: text, prefilledWith: draft.amount > 0 ? draft.amount : nil)
    }

    // Le brouillon que « Enregistrer » écrit : confirmé, avec le montant, la date et le nombre d'échéances du
    // formulaire. Extrait de la vue pour que la confirmation sans modification se teste sans interface.
    static func confirmedDraft(from draft: CommitmentDraft, amountText: String, dueDate: Date?, count: Int?) -> CommitmentDraft? {
        guard let value = enteredAmount(from: amountText, in: draft) else { return nil }
        var confirmed = draft
        confirmed.amount = value
        confirmed.status = "confirmed"
        confirmed.dueDate = dueDate
        confirmed.count = draft.cadence == "once" ? nil : count
        return confirmed
    }

    var body: some View {
        Form {
            Section {
                TextField(AppLocalizer.string("commitments.name", locale: locale), text: $draft.title)
                    .accessibilityIdentifier("commitment-name")
                TextField(AppLocalizer.string("commitments.amount", locale: locale), text: $amount)
                    .keyboardType(.decimalPad).accessibilityIdentifier("commitment-amount")
                CategorySelectionView(selection: $draft.category, identifier: "commitment-category")
            }
            Section {
                Picker(AppLocalizer.string("commitments.account", locale: locale), selection: $draft.accountID) {
                    Text(AppLocalizer.string("commitments.noAccount", locale: locale)).tag(nil as UUID?)
                    ForEach(appState.externalAccounts.filter { $0.currencyCode == "EUR" }) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                Picker(AppLocalizer.string("commitments.frequency", locale: locale), selection: $draft.cadence) {
                    ForEach(draft.sourceKind == "subscription" ? ["monthly", "yearly"] : ["once", "monthly", "yearly"], id: \.self) { cadence in
                        Text(AppLocalizer.string("commitments.cadence." + cadence, locale: locale)).tag(cadence)
                    }
                }.accessibilityIdentifier("commitment-cadence")
                Toggle(AppLocalizer.string("commitments.dateKnown", locale: locale), isOn: $hasDate)
                    .accessibilityIdentifier("commitment-date-known")
                if hasDate {
                    DatePicker(AppLocalizer.string("commitments.nextDate", locale: locale), selection: $dueDate, displayedComponents: .date)
                }
                if draft.cadence != "once" && draft.sourceKind != "subscription" {
                    Toggle(AppLocalizer.string("commitments.finite", locale: locale), isOn: $finite)
                        .accessibilityIdentifier("commitment-finite")
                    if finite {
                        TextField(AppLocalizer.string("commitments.count", locale: locale), text: $count)
                            .keyboardType(.numberPad).accessibilityIdentifier("commitment-count")
                        Text(AppLocalizer.string("commitments.countHelp", locale: locale)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(AppLocalizer.string(scheduleLocked ? "commitments.linkedSchedule" : "commitments.dateHelp", locale: locale))
            }.disabled(scheduleLocked)
            if draft.sourceKind == "installment" {
                Text(AppLocalizer.string("commitments.installmentHelp", locale: locale)).font(.footnote)
            }
        }
        .navigationTitle(AppLocalizer.string("commitments.detail", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalizer.string("Cancel", locale: locale)) { dismiss() }.accessibilityIdentifier("commitment-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) { save() }.disabled(!valid)
                    .accessibilityIdentifier("commitment-save")
            }
        }
        .onAppear {
            amount = draft.amount > 0 ? Formatters.decimalString(for: draft.amount) : ""
            hasDate = draft.dueDate != nil; dueDate = draft.dueDate ?? Date()
            finite = draft.count != nil; count = draft.count.map(String.init) ?? "3"
        }
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
    private func save() {
        guard valid, let confirmed = Self.confirmedDraft(from: draft, amountText: amount, dueDate: hasDate ? dueDate : nil, count: finite ? Int(count) : nil) else { return }
        draft = confirmed
        do { try appState.planningWrite { try $0.saveCommitment(draft) }; dismiss() }
        catch { errorMessage = error.userMessage }
    }
}

private struct CommitmentPaymentView: View {
    let event: ForecastEvent
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    private var candidates: [BankTransaction] {
        let assigned = appState.planning.assignedTransactionIDs
        return appState.bankTransactions.filter { tx in
            tx.isExpense && tx.currencyCode == "EUR" && Calendar.current.startOfDay(for: tx.bookingDate) <= Calendar.current.startOfDay(for: Date()) &&
            tx.amount <= abs(event.amount) && PeculeDataStore.isTransactionFree(tx, assignedTransactionIDs: assigned) &&
            (event.accountID == nil || event.accountID == tx.accountID) &&
            event.date.map { abs(Calendar.current.dateComponents([.day], from: $0, to: tx.bookingDate).day ?? 99) <= 7 } == true
        }
    }
    var body: some View {
        List {
            Text(AppLocalizer.string("commitments.matchHelp", locale: locale)).font(.footnote).foregroundStyle(.secondary)
            if candidates.isEmpty { Text(AppLocalizer.string("commitments.noCandidates", locale: locale)) }
            ForEach(candidates) { tx in
                Button {
                    do {
                        try appState.planningWrite { store in
                            if !appState.planning.commitments.contains(where: { $0.id == event.commitmentID }),
                               let draft = appState.commitmentDrafts().first(where: { $0.id == event.commitmentID }) { try store.saveCommitment(draft) }
                            try store.reconcilePayment(event: event, transactionID: tx.id)
                        }
                        dismiss()
                    } catch { errorMessage = error.userMessage }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tx.label)
                        Text(Formatters.currencyString(for: tx.amount) + " · " + Formatters.dateString(for: tx.bookingDate))
                    }
                }.accessibilityIdentifier("commitment-payment-\(tx.id)")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(AppColors.error) }
        }
        .navigationTitle(AppLocalizer.string("commitments.match", locale: locale))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLocalizer.string("Cancel", locale: locale)) { dismiss() } } }
    }
}
