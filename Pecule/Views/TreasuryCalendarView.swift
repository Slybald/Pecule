import Charts
import SwiftUI

struct TreasuryCalendarView: View {
    var initialAccountID: UUID?
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var accountID: UUID?
    @State private var habitual = false
    @State private var untilSalary = false

    init(initialAccountID: UUID? = nil) {
        self.initialAccountID = initialAccountID
        _accountID = State(initialValue: initialAccountID)
    }
    private var accounts: [ExternalAccount] {
        appState.externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }
    }
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    private func currency(_ amount: Decimal?) -> String {
        amount.map { Formatters.currencyString(for: $0) } ?? text("bankAccount.balance.unknown")
    }
    // The sentence VoiceOver reads for the chart: the lowest forecast balance and the day it happens.
    private func forecastChartSummary(_ forecast: PlanningForecast) -> String {
        let minimum = AppLocalizer.format("treasury.chart.labelled %@ %@", locale: locale, text("treasury.minimum"), currency(forecast.minimum))
        guard let day = forecast.minimumDay else { return minimum }
        return AppLocalizer.format("treasury.chart.separated %@ %@", locale: locale, minimum, Formatters.dateString(for: day.date))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            let salary = appState.nextPlannedSalary(on: now)
            let end = untilSalary ? salary.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) } : nil
            let forecast = appState.planningForecast(on: now, until: end, accountID: accountID, habitual: habitual)
            List {
                Section {
                    Picker(text("treasury.account"), selection: $accountID) {
                        Text(text("treasury.allAccounts")).tag(nil as UUID?)
                        ForEach(accounts) { account in Text(account.name).tag(Optional(account.id)) }
                    }.accessibilityIdentifier("treasury-account")
                    Picker(text("treasury.reading"), selection: $habitual) {
                        Text(text("treasury.confirmed")).tag(false)
                        Text(text("treasury.habitual")).tag(true)
                    }.accessibilityIdentifier("treasury-reading")
                    Picker(text("treasury.horizon"), selection: $untilSalary) {
                        Text(text("treasury.thirtyDays")).tag(false)
                        if salary != nil { Text(text("treasury.untilSalary")).tag(true) }
                    }.accessibilityIdentifier("treasury-horizon")
                    Text(text(habitual ? "treasury.habitualExplanation" : "treasury.confirmedExplanation"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if accounts.isEmpty {
                    Text(text("treasury.noAccounts")).accessibilityIdentifier("treasury-empty")
                } else if habitual && !forecast.estimationAvailable {
                    Text(text("treasury.estimationUnavailable"))
                        .accessibilityIdentifier("treasury-estimation-unavailable")
                } else {
                    Section {
                        LabeledContent(text("treasury.minimum"), value: currency(forecast.minimum))
                            .accessibilityIdentifier("treasury-minimum")
                        if let day = forecast.minimumDay { Text(Formatters.dateString(for: day.date)).foregroundStyle(.secondary) }
                        if forecast.minimum != nil {
                            Chart(forecast.days) { day in
                                if let amount = day.total {
                                    LineMark(x: .value("Date", day.date), y: .value("EUR", NSDecimalNumber(decimal: amount).doubleValue))
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                        .foregroundStyle(AppColors.accent)
                                        .accessibilityLabel(Formatters.dateString(for: day.date))
                                        .accessibilityValue(currency(amount))
                                }
                            }.frame(height: 160)
                                .accessibilityChartDescriptor(AmountOverTimeChartDescriptor(
                                    title: text("treasury.title"),
                                    summary: forecastChartSummary(forecast),
                                    seriesName: text("treasury.title"),
                                    xTitle: text("chart.axis.date"),
                                    yTitle: text("chart.axis.amount"),
                                    points: forecast.days.compactMap { day in
                                        day.total.map { .init(date: day.date, amount: NSDecimalNumber(decimal: $0).doubleValue) }
                                    }
                                ))
                                .accessibilityIdentifier("treasury-chart")
                        }
                        if forecast.incomplete {
                            Text(text("treasury.incomplete")).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("treasury-incomplete")
                        }
                    }
                    if !forecast.alerts.isEmpty {
                        Section(text("treasury.alerts")) {
                            ForEach(forecast.alerts) { alert in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(alert.accountName).font(.headline)
                                    Text(AppLocalizer.format("treasury.belowThreshold %@ %@", locale: locale,
                                                             Formatters.dateString(for: alert.date), currency(alert.amount)))
                                        .foregroundStyle(AppColors.error)
                                }.accessibilityIdentifier("treasury-alert-\(alert.id)")
                            }
                        }
                    }

                }
                if !forecast.unresolved.isEmpty {
                    Section {
                        ForEach(forecast.displayedUnresolved) { event in
                            if let source = appState.incomeSources.first(where: { $0.id == event.commitmentID }) {
                                NavigationLink { IncomeForecastFormView(incomeID: source.id) } label: { eventRow(event) }
                            } else {
                                NavigationLink { CommitmentDetailView(commitmentID: event.commitmentID) } label: { eventRow(event) }
                            }
                        }
                        if forecast.hiddenUnresolvedCount > 0 {
                            Text(AppLocalizer.format("treasury.unresolvedMore %lld", locale: locale, forecast.hiddenUnresolvedCount))
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("treasury-unresolved-more")
                        }
                    } header: { Text(text("treasury.unresolved")) }
                    footer: { Text(text("treasury.unresolvedHelp")) }
                }
                Section(text("treasury.prepare")) {
                    NavigationLink { CommitmentsView() } label: { Text(text("commitments.title")) }
                    ForEach(appState.incomeSources.filter(\.isActive)) { source in
                        NavigationLink { IncomeForecastFormView(incomeID: source.id) } label: {
                            Label(source.name, systemImage: "calendar.badge.plus")
                        }.accessibilityIdentifier("treasury-income-\(source.id)")
                    }
                    NavigationLink { IncomeView() } label: { Text(text("income.title")) }
                    ForEach(accounts.filter { accountID == nil || $0.id == accountID }) { account in
                        NavigationLink { TreasuryThresholdView(accountID: account.id) } label: {
                            Text(AppLocalizer.format("treasury.thresholdFor %@", locale: locale, account.name))
                        }.accessibilityIdentifier("treasury-threshold-\(account.id)")
                    }
                }
                if !habitual || forecast.estimationAvailable {
                    Section(text("treasury.days")) {
                        ForEach(forecast.days) { day in
                            NavigationLink {
                                TreasuryDayView(day: day, accounts: accounts.filter { accountID == nil || $0.id == accountID })
                            } label: {
                                LabeledContent(Formatters.dateString(for: day.date), value: currency(day.total))
                            }.accessibilityIdentifier("treasury-day-\(Int(day.date.timeIntervalSince1970))")
                        }
                    }
                }
            }
        }
        .navigationTitle(text("treasury.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appState.dataRevision) { _, _ in
            if let accountID, !accounts.contains(where: { $0.id == accountID }) { self.accountID = nil }
            if appState.nextPlannedSalary() == nil { untilSalary = false }
        }
    }
    private func eventRow(_ event: ForecastEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title).font(.headline)
            Text(currency(event.amount))
            Text(event.date.map { Formatters.dateString(for: $0) } ?? text("commitments.noDate"))
            if event.accountID == nil { Text(text("commitments.noAccount")) }
            if !event.confirmed { Text(text("commitments.status.suggested")) }
        }.font(.subheadline)
    }
}

private struct TreasuryDayView: View {
    let day: ForecastDay
    let accounts: [ExternalAccount]
    @Environment(\.locale) private var locale
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    var body: some View {
        List {
            Section(text("treasury.closingBalances")) {
                ForEach(accounts) { account in
                    LabeledContent(account.name, value: day.balances[account.id].map { Formatters.currencyString(for: $0) } ?? text("bankAccount.balance.unknown"))
                }
            }
            Section(text("treasury.movements")) {
                if day.events.isEmpty && day.estimatedExpenses.isEmpty { Text(text("treasury.noEvents")) }
                ForEach(day.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(event.title, value: Formatters.currencyString(for: event.amount))
                        Text(event.accountID.flatMap { id in accounts.first { $0.id == id }?.name } ?? text("commitments.noAccount"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if !event.confirmed { Text(text("commitments.status.suggested")) }
                    }
                }
                ForEach(accounts) { account in
                    if let amount = day.estimatedExpenses[account.id] {
                        LabeledContent(AppLocalizer.format("treasury.chart.separated %@ %@", locale: locale, text("treasury.variable"), account.name), value: Formatters.currencyString(for: -amount))
                    }
                }
            }
        }
        .navigationTitle(Formatters.dateString(for: day.date))
        .accessibilityIdentifier("treasury-day-detail")
    }
}

struct IncomeForecastFormView: View {
    let incomeID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var hasDate = false
    @State private var date = Date()
    @State private var accountID: UUID?
    @State private var errorMessage: String?
    private var draft: CommitmentDraft? { appState.commitmentDrafts().first { $0.sourceKind == "income" && $0.sourceID == incomeID } }
    private func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
    var body: some View {
        Form {
            if let draft {
                Section {
                    Text(draft.title).font(.headline)
                    Toggle(text("commitments.dateKnown"), isOn: $hasDate).accessibilityIdentifier("income-forecast-date-known")
                    if hasDate {
                        DatePicker(text("treasury.receiptDate"), selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("income-forecast-date")
                    }
                    Picker(text("commitments.account"), selection: $accountID) {
                        Text(text("commitments.noAccount")).tag(nil as UUID?)
                        ForEach(appState.externalAccounts.filter { $0.currencyCode == "EUR" }) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }.accessibilityIdentifier("income-forecast-account")
                } footer: { Text(text("treasury.incomeHelp")) }
            }
        }
        .navigationTitle(text("treasury.incomeSchedule"))
        .onAppear { hasDate = draft?.dueDate != nil; date = draft?.dueDate ?? Date(); accountID = draft?.accountID }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(text("Save")) {
                    guard var draft else { return }
                    draft.dueDate = hasDate ? date : nil; draft.accountID = accountID
                    do { try appState.planningWrite { try $0.saveCommitment(draft) }; dismiss() }
                    catch { errorMessage = error.userMessage }
                }.accessibilityIdentifier("income-forecast-save")
            }
        }
        .alert(text("common.error.save"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(text("OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

private struct TreasuryThresholdView: View {
    let accountID: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var errorMessage: String?
    // Le seuil enregistré, dont le champ est prérempli : tant que le texte n'est pas modifié, il passe tel quel.
    private var savedThreshold: Decimal { appState.planning.settings.first { $0.accountID == accountID }?.threshold ?? 0 }
    var body: some View {
        Form {
            Section {
                TextField(AppLocalizer.string("treasury.threshold", locale: locale), text: $amount)
                    .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("treasury-threshold-amount")
            } footer: { Text(AppLocalizer.string("treasury.thresholdHelp", locale: locale)) }
        }
        .navigationTitle(AppLocalizer.string("treasury.threshold", locale: locale))
        .onAppear { amount = Formatters.decimalString(for: savedThreshold) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalizer.string("Save", locale: locale)) {
                    guard let value = Formatters.decimalValue(from: amount, prefilledWith: savedThreshold), !value.isNaN else { return }
                    do { try appState.planningWrite { try $0.saveThreshold(accountID: accountID, amount: value) }; dismiss() }
                    catch { errorMessage = error.userMessage }
                }.disabled(Formatters.decimalValue(from: amount, prefilledWith: savedThreshold) == nil).accessibilityIdentifier("treasury-threshold-save")
            }
        }
        .alert(AppLocalizer.string("common.error.save", locale: locale), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
