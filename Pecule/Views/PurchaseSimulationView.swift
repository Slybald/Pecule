import SwiftUI

struct PurchaseSimulationsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var editing: PurchaseSimulationDraft?
    var body: some View {
        List {
            Section {
                Text(AppLocalizer.string("simulation.intro", locale: locale)).foregroundStyle(.secondary)
                Button { editing = PurchaseSimulationDraft() } label: {
                    Label(AppLocalizer.string("simulation.add", locale: locale), systemImage: "plus")
                }.accessibilityIdentifier("simulation-add")
            }
            Section(AppLocalizer.string("simulation.saved", locale: locale)) {
                if appState.planning.scenarios.isEmpty {
                    Text(AppLocalizer.string("simulation.empty", locale: locale)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("simulation-empty")
                }
                ForEach(appState.planning.scenarios.sorted { $0.date < $1.date }) { scenario in
                    Button { editing = PurchaseSimulationDraft(scenario) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scenario.title).font(.headline)
                            Text(Formatters.currencyString(for: scenario.amount) + " · " + Formatters.dateString(for: scenario.date))
                            if Calendar.current.startOfDay(for: scenario.date) < Calendar.current.startOfDay(for: Date()) {
                                Text(AppLocalizer.string("simulation.dateNeedsUpdate", locale: locale)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("simulation-row-\(scenario.id)")
                }
            }
        }
        .navigationTitle(AppLocalizer.string("simulation.title", locale: locale))
        .sheet(item: $editing) { draft in NavigationStack { PurchaseSimulationView(draft: draft) } }
    }
}

struct PurchaseSimulationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State var draft: PurchaseSimulationDraft
    @State private var amountText = ""
    @State private var loaded = false
    @State private var habitual = false
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false

    private var accounts: [ExternalAccount] { appState.externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" } }
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    private var edited: PurchaseSimulationDraft {
        var value = draft; value.amount = Formatters.decimalValue(from: amountText, prefilledWith: draft.amount > 0 ? draft.amount : nil) ?? 0; return value
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            let comparison = Result { try appState.simulatePurchase(edited, on: now, habitual: habitual) }
            Form {
                Section {
                    TextField(text("simulation.name"), text: $draft.title).accessibilityIdentifier("simulation-name")
                    TextField(text("commitments.amount"), text: $amountText).keyboardType(.decimalPad)
                        .accessibilityIdentifier("simulation-amount")
                    DatePicker(text("simulation.date"), selection: $draft.date,
                               in: Calendar.current.startOfDay(for: now)...PurchaseSimulationService.latestDate(now: now, calendar: .current), displayedComponents: .date)
                        .accessibilityIdentifier("simulation-date")
                    if Calendar.current.startOfDay(for: draft.date) < Calendar.current.startOfDay(for: now) {
                        Button(text("simulation.useToday")) { draft.date = now }.accessibilityIdentifier("simulation-use-today")
                    }
                    Picker(text("commitments.account"), selection: $draft.accountID) {
                        Text(text("commitments.noAccount")).tag(nil as UUID?)
                        ForEach(accounts) { account in Text(account.name).tag(Optional(account.id)) }
                        if let id = draft.accountID, !accounts.contains(where: { $0.id == id }) {
                            Text(text("simulation.unavailableAccount")).tag(Optional(id))
                        }
                    }.accessibilityIdentifier("simulation-account")
                    Picker(text("treasury.reading"), selection: $habitual) {
                        Text(text("treasury.confirmed")).tag(false)
                        Text(text("treasury.habitual")).tag(true)
                    }.accessibilityIdentifier("simulation-reading")
                } footer: { Text(text("simulation.intro")) }
                switch comparison {
                case .success(let result):
                    PurchaseSimulationComparisonView(result: result, accountID: draft.accountID, habitual: habitual) { date in draft.date = date }
                case .failure(let error):
                    Text(amountText.isEmpty ? text("simulation.enterAmount") : error.userMessageQuiet)
                        .foregroundStyle(.secondary).accessibilityIdentifier("simulation-validation")
                }
                if draft.isExisting {
                    Section {
                        Button(text("simulation.delete"), role: .destructive) { confirmsDeletion = true }
                            .accessibilityIdentifier("simulation-delete")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("Cancel")) { dismiss() }.accessibilityIdentifier("simulation-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("Save")) {
                        do { try appState.planningWrite { try $0.savePurchaseScenario(edited, now: now) }; dismiss() }
                        catch { errorMessage = error.userMessage }
                    }.disabled(!canSave(comparison)).accessibilityIdentifier("simulation-save")
                }
            }
        }
        .navigationTitle(text("simulation.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }; loaded = true
            amountText = draft.amount > 0 ? Formatters.decimalString(for: draft.amount) : ""
        }
        .alert(text("common.error.save"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(text("OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(text("simulation.deleteExplanation"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(text("simulation.delete"), role: .destructive) {
                do { try appState.planningWrite { try $0.deletePurchaseScenario(id: draft.id) }; dismiss() }
                catch { errorMessage = error.userMessage }
            }
            Button(text("Cancel"), role: .cancel) {}
        }
    }
    private func canSave(_ result: Result<PurchaseSimulationResult, Error>) -> Bool {
        if case .success = result { return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

private struct PurchaseSimulationComparisonView: View {
    let result: PurchaseSimulationResult
    let accountID: UUID?
    let habitual: Bool
    let useDate: (Date) -> Void
    @Environment(\.locale) private var locale
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    private func currency(_ amount: Decimal?) -> String { amount.map { Formatters.currencyString(for: $0) } ?? text("simulation.unknown") }

    var body: some View {
        Section {
            comparison("simulation.budgetMargin", before: result.month.budgetBefore, after: result.month.budgetAfter, id: "simulation-budget")
            if result.month.budgetBefore == nil { Text(text("simulation.noBudget")).font(.footnote).foregroundStyle(.secondary) }
            Text(text("simulation.knownBudget")).font(.footnote).foregroundStyle(.secondary)
        } header: { Text(Formatters.monthYearString(for: result.month.month)) }
        Section {
            if habitual && !result.reference.estimationAvailable {
                Text(text("treasury.estimationUnavailable")).accessibilityIdentifier("simulation-estimate-unavailable")
            } else {
                comparison("simulation.minimum", before: result.reference.minimum, after: result.scenario.minimum, id: "simulation-minimum")
                if let day = result.scenario.minimumDay {
                    Text(AppLocalizer.format("simulation.minimumDate %@", locale: locale, Formatters.dateString(for: day.date))).foregroundStyle(.secondary)
                }
                if accountID != nil {
                    comparison("simulation.accountMinimum", before: result.accountBefore, after: result.accountAfter, id: "simulation-account-minimum")
                } else { Text(text("simulation.unassigned")).font(.footnote).foregroundStyle(.secondary) }
                if result.reference.incomplete || result.scenario.incomplete {
                    Text(text("treasury.incomplete")).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(result.scenario.alerts) { alert in
                    Text(AppLocalizer.format("simulation.alert %@ %@ %@", locale: locale, alert.accountName,
                                             currency(alert.amount), Formatters.dateString(for: alert.date)))
                        .foregroundStyle(AppColors.error)
                }
            }
            Text(AppLocalizer.format("simulation.horizon %@", locale: locale,
                                     Formatters.dateString(for: Calendar.current.date(byAdding: .day, value: -1, to: result.end)!)))
                .font(.footnote).foregroundStyle(.secondary)
            Text(text("simulation.projectionHelp")).font(.footnote).foregroundStyle(.secondary)
        } header: { Text(text("simulation.cashflow")) }
        Section {
            comparison("simulation.forProjects", before: result.month.projectsBefore, after: result.month.projectsAfter, id: "simulation-projects")
            LabeledContent(text("simulation.reserved"), value: currency(result.month.reservedInMonth))
            Text(text(result.month.usesBankAmounts ? "simulation.projectsBankHelp" : "simulation.projectsManualHelp"))
                .font(.footnote).foregroundStyle(.secondary)
            Text(text("simulation.projectsUnchanged")).font(.footnote).foregroundStyle(.secondary)
        } header: { Text(text("Goals")) }
        Section {
            if let date = result.afterSalaryDate, let forecast = result.afterSalaryForecast, let month = result.afterSalaryMonth {
                Text(Formatters.dateString(for: date)).font(.headline)
                LabeledContent(text("simulation.minimum"), value: currency(forecast.minimum))
                LabeledContent(text("simulation.budgetMargin"), value: currency(month.budgetAfter))
                Text(Formatters.monthYearString(for: month.month)).foregroundStyle(.secondary)
                LabeledContent(text("simulation.forProjects"), value: currency(month.projectsAfter))
                Button(text("simulation.useAfterSalary")) { useDate(date) }.accessibilityIdentifier("simulation-after-salary")
            } else { Text(text("simulation.noSalary")).foregroundStyle(.secondary) }
        } header: { Text(text("simulation.afterSalary")) }
    }
    private func comparison(_ key: String, before: Decimal?, after: Decimal?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(key)).font(.headline)
            LabeledContent(text("simulation.before")) { Text(currency(before)).accessibilityIdentifier(id + "-before") }
            LabeledContent(text("simulation.after")) { Text(currency(after)).accessibilityIdentifier(id + "-after") }
        }.padding(.vertical, 4)
    }
}
