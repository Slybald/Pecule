import SwiftUI

struct OperationsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var filter: OperationFilter
    @State private var records: [OperationRecord] = []
    @State private var result = OperationSearchResult(records: [], grossExpenses: 0, refunds: 0, income: 0)
    @State private var visibleCount = 100
    @State private var showsFilters = false
    @State private var loadError: String?
    private let service = OperationSearchService()

    init(month: Date? = nil, category: ExpenseCategory? = nil, source: OperationFilter.Source? = nil, includedOnly: Bool = false) {
        var initial = OperationFilter()
        initial.category = category
        initial.source = source
        initial.includedOnly = includedOnly
        if let month, let interval = Calendar.current.dateInterval(of: .month, for: month) {
            initial.dateFrom = interval.start
            initial.dateUntil = interval.end
        }
        _filter = State(initialValue: initial)
    }

    var body: some View {
        let days = Dictionary(grouping: Array(result.records.prefix(visibleCount))) { Calendar.current.startOfDay(for: $0.date) }
        List {
            if let loadError { Text(loadError).foregroundStyle(.red) }
            Section {
                HStack {
                    Text(result.records.count == 1 ? AppLocalizer.string("operations.count.one", locale: locale) : AppLocalizer.format("operations.count %lld", locale: locale, Int64(result.records.count)))
                        .font(AppTypography.rowTitle).accessibilityIdentifier("operations-count")
                    Spacer()
                    Button { showsFilters = true } label: {
                        Label(AppLocalizer.string("operations.filters", locale: locale), systemImage: "line.3.horizontal.decrease")
                    }.accessibilityIdentifier("operations-filters-button")
                }
                if showsNoImportedOperations {
                    // Un zéro sans aucune opération importée ne dit pas « rien dépensé » : il dit « pas de données ».
                    Text(AppLocalizer.string("overview.noImportedOperations", locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("operations-no-imported")
                } else {
                    Text(AppLocalizer.format("overview.operations.expenses %@", locale: locale, Formatters.currencyString(for: result.netExpenses)))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                }
                DisclosureGroup(AppLocalizer.string("operations.totals.title", locale: locale)) {
                    if result.refunds != .zero {
                        LabeledContent(AppLocalizer.string("operations.grossExpenses", locale: locale), value: Formatters.currencyString(for: result.grossExpenses))
                        LabeledContent(AppLocalizer.string("operations.refunds", locale: locale), value: Formatters.currencyString(for: result.refunds))
                    }
                    if result.income != .zero {
                        LabeledContent(AppLocalizer.string("operations.income", locale: locale), value: Formatters.currencyString(for: result.income))
                    }
                    Text(AppLocalizer.string("operations.totals.explanation", locale: locale))
                        .font(AppTypography.rowMeta).foregroundStyle(.secondary)
                }.font(AppTypography.rowMeta)
                if filter != OperationFilter() {
                    Button(AppLocalizer.string("operations.clearFilters", locale: locale)) { filter = OperationFilter() }
                        .accessibilityIdentifier("operations-clear-filters")
                }
            }
            .listRowBackground(Color.clear)
            if result.records.isEmpty {
                if appState.externalAccounts.isEmpty {
                    NavigationLink { BankConnectionView(bankSync: appState.bankSync) } label: {
                        Label(AppLocalizer.string("bank.connection.title", locale: locale), systemImage: "building.columns")
                    }.accessibilityIdentifier("operations-connect-bank")
                }
                ContentUnavailableView.search(text: filter.text)
                    .accessibilityIdentifier("operations-empty")
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section(Formatters.dateString(for: day)) {
                    ForEach(days[day] ?? []) { record in
                        NavigationLink {
                            OperationDestinationView(id: record.id)
                        } label: {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(record.title).font(AppTypography.rowTitle).lineLimit(2)
                                    Spacer()
                                    Text((record.direction == .debit ? "−" : "+") + Formatters.currencyString(for: record.amount, currencyCode: record.currency))
                                        .font(AppTypography.rowSubtitle).monospacedDigit()
                                }
                                Text((record.creditNature.map { AppLocalizer.string("transaction.nature." + $0.rawValue, locale: locale) } ?? record.category.displayName(locale: locale)) + " · " + accountName(record))
                                    .font(AppTypography.rowMeta).foregroundStyle(.secondary)
                                if record.needsReview {
                                    Text(AppLocalizer.string("transaction.nature.needsReview", locale: locale)).font(AppTypography.rowMeta).foregroundStyle(AppColors.warning)
                                }
                                if record.representedByBankOperation {
                                    Text(AppLocalizer.string("operations.representedByBank", locale: locale)).font(AppTypography.rowMeta).foregroundStyle(.secondary)
                                } else if !record.isIncluded {
                                    Text(AppLocalizer.string("operations.excluded", locale: locale)).font(AppTypography.rowMeta).foregroundStyle(.secondary)
                                }
                                if record.status == .pending {
                                    Text(AppLocalizer.string("operations.status.pending", locale: locale)).font(AppTypography.rowMeta).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            if visibleCount < result.records.count {
                Button(AppLocalizer.string("operations.loadMore", locale: locale)) { visibleCount += 100 }
                    .accessibilityIdentifier("operations-load-more")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.overviewBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("operations.title", locale: locale))
        .accessibilityIdentifier("operations-screen")
        .searchable(text: $filter.text, placement: .navigationBarDrawer(displayMode: .always), prompt: AppLocalizer.string("operations.search", locale: locale))
        .sheet(isPresented: $showsFilters) {
            NavigationStack {
                OperationFiltersView(filter: filter, accounts: appState.externalAccounts) { filter = $0 }
            }
        }
        .onChange(of: appState.dataRevision, initial: true) { _, _ in reloadRecords() }
        .onChange(of: filter) { previous, current in
            // Seul un changement de fenêtre temporelle impose de relire la base : les autres
            // critères se rejouent sur la projection déjà en mémoire.
            if Self.window(for: previous) == Self.window(for: current) {
                applyFilter()
            } else {
                reloadRecords()
            }
        }
        .refreshable { await appState.bankSync.refresh(appState.linkedExternalAccounts, attended: true) }
    }

    // Ouvrir les opérations d'un mois relisait la table entière, puis reconstruisait un
    // enregistrement par ligne, à chaque annotation d'une opération. Quand la recherche est
    // bornée dans le temps, seule cette fenêtre est matérialisée.
    private static func window(for filter: OperationFilter) -> DateInterval? {
        guard let from = filter.dateFrom, let until = filter.dateUntil, from < until else { return nil }
        return DateInterval(start: from, end: until)
    }

    private func reloadRecords() {
        guard appState.isProfileActive else {
            records = []
            loadError = nil
            applyFilter()
            return
        }
        do {
            // Les achats saisis qui comptent sont jugés par la même règle que le résumé du mois.
            records = try appState.operationRecords(in: Self.window(for: filter))
            loadError = nil
            applyFilter()
        } catch { loadError = error.userMessage }
    }

    private func applyFilter() {
        result = service.search(records, filter: filter)
        visibleCount = 100
    }

    // Sur une période sans aucune opération importée des comptes inclus, un total à zéro n'est pas une absence
    // de dépense. Jamais à la place d'un total que des achats saisis rendent non nul.
    private var showsNoImportedOperations: Bool {
        guard let window = Self.window(for: filter), result.netExpenses == .zero else { return false }
        return appState.hasNoImportedOperations(in: window)
    }
    private func accountName(_ record: OperationRecord) -> String {
        record.accountID.flatMap { appState.externalAccount(id: $0)?.shortDisplayName(locale: locale) }
            ?? AppLocalizer.string("operations.manual", locale: locale)
    }
}

private struct OperationDestinationView: View {
    let id: OperationRecord.ID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            switch id {
            case .bank(let id):
                if let transaction = appState.bankTransaction(id: id) {
                    BankTransactionDetailView(transaction: transaction)
                } else { unavailable }
            case .purchase(let id):
                if let purchase = appState.purchases.first(where: { $0.id == id }) {
                    PurchaseDetailView(purchase: purchase)
                } else { unavailable }
            }
        }
    }
    private var unavailable: some View {
        ContentUnavailableView(AppLocalizer.string("accounts.transaction.unavailable", locale: locale), systemImage: "doc.questionmark")
    }
}

private struct OperationFiltersView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State var filter: OperationFilter
    let accounts: [ExternalAccount]
    let apply: (OperationFilter) -> Void
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var usesDates = false
    @State private var firstDay = Date()
    @State private var lastDay = Date()
    @State private var showsAmountError = false

    var body: some View {
        Form {
            Picker(AppLocalizer.string("operations.source", locale: locale), selection: $filter.source) {
                Text(AppLocalizer.string("operations.all", locale: locale)).tag(nil as OperationFilter.Source?)
                ForEach(OperationFilter.Source.allCases, id: \.self) { Text(AppLocalizer.string("operations.source." + $0.rawValue, locale: locale)).tag(Optional($0)) }
            }
            Toggle(AppLocalizer.string("operations.includedOnly", locale: locale), isOn: $filter.includedOnly)
            Picker(AppLocalizer.string("operations.account", locale: locale), selection: $filter.accountID) {
                Text(AppLocalizer.string("operations.all", locale: locale)).tag(nil as UUID?)
                ForEach(accounts) { Text($0.shortDisplayName(locale: locale)).tag(Optional($0.id)) }
            }
            Picker(AppLocalizer.string("Category", locale: locale), selection: $filter.category) {
                Text(AppLocalizer.string("operations.all", locale: locale)).tag(nil as ExpenseCategory?)
                ForEach(appState.availableCategories) { Text($0.displayName(locale: locale)).tag(Optional($0)) }
            }.accessibilityIdentifier("operations-filter-category")
            Picker(AppLocalizer.string("accounts.filter.title", locale: locale), selection: $filter.direction) {
                Text(AppLocalizer.string("operations.all", locale: locale)).tag(nil as BankTransactionDirection?)
                Text(AppLocalizer.string("accounts.filter.expenses", locale: locale)).tag(Optional(BankTransactionDirection.debit))
                Text(AppLocalizer.string("accounts.filter.income", locale: locale)).tag(Optional(BankTransactionDirection.credit))
            }
            Picker(AppLocalizer.string("operations.status", locale: locale), selection: $filter.status) {
                Text(AppLocalizer.string("operations.all", locale: locale)).tag(nil as BankTransactionStatus?)
                ForEach(BankTransactionStatus.allCases, id: \.self) { Text(AppLocalizer.string("operations.status." + $0.rawValue, locale: locale)).tag(Optional($0)) }
            }
            Toggle(AppLocalizer.string("operations.review", locale: locale), isOn: $filter.needsReview)
            Section {
                Toggle(AppLocalizer.string("operations.dates", locale: locale), isOn: $usesDates)
                if usesDates {
                    DatePicker(AppLocalizer.string("operations.from", locale: locale), selection: $firstDay, displayedComponents: .date)
                    DatePicker(AppLocalizer.string("operations.until", locale: locale), selection: $lastDay, in: firstDay..., displayedComponents: .date)
                }
            }
            Section {
                TextField(AppLocalizer.string("operations.minimum", locale: locale), text: $minimum).keyboardType(.decimalPad)
                TextField(AppLocalizer.string("operations.maximum", locale: locale), text: $maximum).keyboardType(.decimalPad)
                if showsAmountError { Text(AppLocalizer.string("operations.amountError", locale: locale)).foregroundStyle(AppColors.error) }
            }
        }
        .navigationTitle(AppLocalizer.string("operations.filters", locale: locale))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(AppLocalizer.string("Cancel", locale: locale)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Done", locale: locale)) { save() }.accessibilityIdentifier("operations-filters-apply")
            }
        }
        .onAppear {
            minimum = Formatters.decimalString(for: filter.minimumAmount)
            maximum = Formatters.decimalString(for: filter.maximumAmount)
            usesDates = filter.dateFrom != nil || filter.dateUntil != nil
            firstDay = filter.dateFrom ?? Date()
            lastDay = filter.dateUntil.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) } ?? Date()
        }
    }
    private func save() {
        let minText = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxText = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        let minValue = Formatters.decimalValue(from: minText, prefilledWith: filter.minimumAmount)
        let maxValue = Formatters.decimalValue(from: maxText, prefilledWith: filter.maximumAmount)
        guard (minText.isEmpty || minValue.map { $0 >= 0 } == true),
              (maxText.isEmpty || maxValue.map { $0 >= 0 } == true),
              minValue == nil || maxValue == nil || minValue! <= maxValue! else { showsAmountError = true; return }
        filter.minimumAmount = minValue
        filter.maximumAmount = maxValue
        filter.dateFrom = usesDates ? Calendar.current.startOfDay(for: firstDay) : nil
        filter.dateUntil = usesDates ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(firstDay, lastDay))) : nil
        apply(filter)
        dismiss()
    }
}
