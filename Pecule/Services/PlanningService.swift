import CryptoKit
import Foundation
import SwiftData

struct CommitmentDraft: Identifiable {
    var id = UUID()
    var sourceKey = UUID().uuidString
    var title = ""
    var amount: Decimal = 0
    var direction = "debit"
    var dueDate: Date?
    var accountID: UUID?
    var cadence = "monthly"
    var count: Int?
    var status = "confirmed"
    var category = "other"
    var sourceKind = "manual"
    var sourceID: UUID?
    var priceIncrease: Decimal?
    init() {}
    init(_ item: PlannedCommitment) {
        id = item.id; sourceKey = item.sourceKey; title = item.title; amount = item.amount
        direction = item.direction; dueDate = item.dueDate; accountID = item.accountID
        cadence = item.cadence; count = item.count; status = item.status; category = item.category
        sourceKind = item.sourceKind; sourceID = item.sourceID
    }
}

struct PlanningSnapshot {
    var commitments: [PlannedCommitment] = []
    var payments: [CommitmentPayment] = []
    var settings: [PlanningAccountSetting] = []
    var scenarios: [PurchaseScenario] = []
    var provisions: [GoalProvision] = []
    var provisionPayments: [ProvisionPayment] = []
    var allocationPlans: [GoalAllocationPlan] = []
    var allocations: [GoalAllocation] = []
    var refunds: [ExpectedRefund] = []
    var receipts: [RefundReceipt] = []
    var rules: [TransactionRule] = []
    var splits: [TransactionSplit] = []
    var checkpoints: [BankImportCheckpoint] = []
    var paymentTransactions: [BankTransaction] = []

    // The operations already assigned to a commitment, a provision or an expected refund.
    var assignedTransactionIDs: Set<UUID> {
        PeculeDataStore.assignedTransactionIDs(payments: payments, provisionPayments: provisionPayments, refunds: refunds)
    }
}

struct ForecastEvent: Identifiable, Equatable {
    var id: String
    var commitmentID: UUID
    var title: String
    var amount: Decimal // signed: credit positive, debit negative
    var date: Date?
    var accountID: UUID?
    var confirmed: Bool
    var category: String
}

struct ForecastAccount: Equatable {
    var id: UUID
    var name: String
    var balance: Decimal?
    var threshold: Decimal
    var dailyVariable: Decimal?
}

struct ForecastDay: Identifiable {
    var date: Date
    var balances: [UUID: Decimal]
    var total: Decimal?
    var events: [ForecastEvent]
    var estimatedExpenses: [UUID: Decimal] = [:]
    var id: Date { date }
}

struct PlanningAlert: Identifiable {
    var accountID: UUID
    var accountName: String
    var date: Date
    var amount: Decimal
    var id: UUID { accountID }
}

struct PlanningForecast {
    var days: [ForecastDay]
    var alerts: [PlanningAlert]
    var unresolved: [ForecastEvent]
    var estimationAvailable: Bool
    var incomplete: Bool
    var minimum: Decimal? { days.compactMap(\.total).min() }
    var minimumDay: ForecastDay? { days.filter { $0.total != nil }.min { $0.total! < $1.total! } }

    // The list shown to the user is capped; `unresolved` itself stays whole, so `incomplete` never depends on the cap.
    static let displayedUnresolvedLimit = 10
    var displayedUnresolved: [ForecastEvent] { Array(unresolved.prefix(Self.displayedUnresolvedLimit)) }
    var hiddenUnresolvedCount: Int { max(0, unresolved.count - Self.displayedUnresolvedLimit) }
}

struct PlanningEngine {
    var calendar: Calendar
    // Overdue occurrences older than this are no longer listed. Left to pile up, a recurring commitment that was never
    // matched adds one line a month for ever and keeps every projection "incomplete".
    static let overdueWindowDays = 45
    // An unassigned booked debit of the same amount, dated at most this many days before a due date, is that due date's payment.
    static let settlementWindowDays = 5
    static let settlementTolerance = Decimal(sign: .plus, exponent: -2, significand: 1) // 0.01
    func occurrenceKey(_ id: UUID, date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(id.uuidString):\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    func events(for draft: CommitmentDraft, from start: Date, until end: Date, paid: [String: Decimal]) -> [ForecastEvent] {
        guard ["confirmed", "suggested"].contains(draft.status), !draft.amount.isNaN, draft.amount > 0 else { return [] }
        let sign: Decimal = draft.direction == "credit" ? 1 : -1
        guard let anchor = draft.dueDate else {
            return [.init(id: draft.id.uuidString, commitmentID: draft.id, title: draft.title,
                          amount: sign * draft.amount, date: nil, accountID: draft.accountID,
                          confirmed: draft.status == "confirmed", category: draft.category)]
        }
        var result: [ForecastEvent] = []
        // A recurring schedule lists only the recent past; a single occurrence stays until it is settled or edited.
        let oldest = draft.cadence == "once" ? nil
            : calendar.date(byAdding: .day, value: -Self.overdueWindowDays, to: calendar.startOfDay(for: start))
        // Anchor-based addition avoids Jan 31 -> Feb 28 -> Mar 28 drift.
        let maxCount = min(draft.count ?? 1200, 1200)
        for index in 0..<max(maxCount, 0) {
            let due: Date
            if draft.cadence == "once" {
                if index > 0 { break }; due = anchor
            } else {
                guard let next = calendar.date(byAdding: draft.cadence == "yearly" ? .year : .month, value: index, to: anchor) else { break }
                due = next
            }
            let day = calendar.startOfDay(for: due)
            if day >= end { break }
            // Skipped, not renumbered: `index` still counts from the anchor, so a finite schedule keeps its length.
            if let oldest, day < oldest { continue }
            let key = occurrenceKey(draft.id, date: due)
            let remaining = max(0, draft.amount - (paid[key] ?? 0)).currencyRounded
            if remaining == 0 { continue }
            // Keep overdue occurrences inspectable at their real dates; projections exclude past days.
            result.append(.init(id: key, commitmentID: draft.id, title: draft.title, amount: sign * remaining,
                                date: day, accountID: draft.accountID, confirmed: draft.status == "confirmed", category: draft.category))
        }
        return result
    }
    func forecast(accounts: [ForecastAccount], events: [ForecastEvent], from start: Date, until end: Date,
                  habitual: Bool, incomplete: Bool = false) -> PlanningForecast {
        let start = calendar.startOfDay(for: start)
        let ids = Set(accounts.map(\.id))
        let available = !accounts.isEmpty && accounts.allSatisfy { $0.dailyVariable != nil }
        let completeBalances = !accounts.isEmpty && accounts.allSatisfy { $0.balance != nil }
        var balances = Dictionary(uniqueKeysWithValues: accounts.compactMap { a in a.balance.map { (a.id, $0) } })
        let unresolved = events.filter { $0.date == nil || $0.date! < start || $0.accountID == nil || !ids.contains($0.accountID!) }
        // An unavailable habitual reading must never look like zero variable spending.
        if habitual && !available {
            return .init(days: [], alerts: [], unresolved: unresolved, estimationAvailable: false, incomplete: true)
        }
        let usable = events.filter { event in
            event.date.map { $0 >= start && $0 < end } == true && (event.confirmed || habitual) && (event.accountID.map(ids.contains) ?? true)
        }
        let grouped = Dictionary(grouping: usable) { calendar.startOfDay(for: $0.date!) }
        var days: [ForecastDay] = [], alerts: [PlanningAlert] = [], alerted: Set<UUID> = [], day = start
        var unassignedTotal: Decimal = 0
        while day < end, days.count < 366 {
            let entries = grouped[day, default: []]
            for event in entries {
                if let id = event.accountID, ids.contains(id) {
                    if balances[id] != nil { balances[id]! += event.amount }
                } else if event.accountID == nil { unassignedTotal += event.amount }
            }
            var estimated: [UUID: Decimal] = [:]
            for account in accounts {
                if habitual, let rate = account.dailyVariable, balances[account.id] != nil {
                    let amount = max(0, rate).currencyRounded
                    balances[account.id]! -= amount
                    estimated[account.id] = amount
                }
                if let value = balances[account.id], value < account.threshold, !alerted.contains(account.id) {
                    alerts.append(.init(accountID: account.id, accountName: account.name, date: day, amount: value.currencyRounded))
                    alerted.insert(account.id)
                }
            }
            let total = completeBalances ? (balances.values.reduce(0, +) + unassignedTotal).currencyRounded : nil
            days.append(.init(date: day, balances: balances.mapValues(\.currencyRounded), total: total, events: entries, estimatedExpenses: estimated))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }; day = next
        }
        return .init(days: days, alerts: alerts, unresolved: unresolved, estimationAvailable: available,
                     incomplete: incomplete || !completeBalances || !unresolved.isEmpty || (habitual && !available))
    }
    func provisionContribution(target: Decimal, reserved: Decimal, due: Date, now: Date) -> Decimal {
        // Calendar months between the month of `now` and the month of `due`, read in the calendar's own time zone.
        // Never measure them between two instants: noons pinned in UTC are one hour apart on the wall clock across
        // a daylight-saving change, which drops a whole month (Paris, October to February: 3 instead of 4).
        let from = calendar.dateComponents([.year, .month], from: now), to = calendar.dateComponents([.year, .month], from: due)
        let months = max(1, ((to.year ?? 0) - (from.year ?? 0)) * 12 + (to.month ?? 0) - (from.month ?? 0))
        var amount = max(0, target - reserved) / Decimal(months), rounded = Decimal()
        NSDecimalRound(&rounded, &amount, 2, .up)
        return rounded
    }
    // "Remaining known charges" must not count twice what the bank already took. A confirmed debit dated today or later
    // is dropped when exactly one booked, unassigned operation of the same amount (to the cent) explains it: same account
    // (or the commitment's account is unknown), dated from `settlementWindowDays` before the due date up to today, and
    // that operation fits no other due date. Two candidates, either way round, change nothing: ambiguous proximity is
    // never auto-matched. Computation only: no payment is recorded, the occurrence stays assignable by hand.
    func removingSettledCharges(from events: [ForecastEvent], transactions: [BankTransaction], includedAccountIDs: Set<UUID>,
                                assignedTransactionIDs: Set<UUID>, now: Date) -> [ForecastEvent] {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let earliest = calendar.date(byAdding: .day, value: -Self.settlementWindowDays, to: today) else { return events }
        // Raw instants first: this scans every cached operation, so keep the per-row cost to a comparison.
        let debits = transactions.filter { transaction in
            transaction.bookingDate >= earliest && transaction.bookingDate < tomorrow && transaction.isExpense &&
            includedAccountIDs.contains(transaction.accountID) &&
            PeculeDataStore.isTransactionFree(transaction, assignedTransactionIDs: assignedTransactionIDs)
        }
        guard !debits.isEmpty else { return events }
        var candidates: [Int: [UUID]] = [:], claims: [UUID: Int] = [:]
        for (index, event) in events.enumerated() {
            guard event.confirmed, event.amount < 0, let due = event.date, due >= today,
                  let from = calendar.date(byAdding: .day, value: -Self.settlementWindowDays, to: due) else { continue }
            let matches = debits.filter { debit in
                debit.bookingDate >= from && (event.accountID == nil || event.accountID == debit.accountID) &&
                abs(abs(event.amount) - debit.amount) <= Self.settlementTolerance
            }.map(\.id)
            guard !matches.isEmpty else { continue }
            candidates[index] = matches
            for id in matches { claims[id, default: 0] += 1 }
        }
        return events.enumerated().compactMap { index, event in
            if let matches = candidates[index], matches.count == 1, claims[matches[0]] == 1 { return nil }
            return event
        }
    }
}

extension PeculeDataStore {
    func planningFetch<T: PersistentModel>(_ type: T.Type) throws -> [T] { try container.mainContext.fetch(FetchDescriptor<T>()) }
    func planningSnapshot() throws -> PlanningSnapshot {
        let payments = try planningFetch(CommitmentPayment.self)
        let paymentIDs = payments.map(\.transactionID) + (try planningFetch(ProvisionPayment.self)).map(\.transactionID)
        let transactions = try container.mainContext.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { paymentIDs.contains($0.id) }))
        return try .init(commitments: planningFetch(PlannedCommitment.self), payments: payments,
                  settings: planningFetch(PlanningAccountSetting.self), scenarios: planningFetch(PurchaseScenario.self),
                  provisions: planningFetch(GoalProvision.self), provisionPayments: planningFetch(ProvisionPayment.self),
                  allocationPlans: planningFetch(GoalAllocationPlan.self), allocations: planningFetch(GoalAllocation.self),
                  refunds: planningFetch(ExpectedRefund.self), receipts: planningFetch(RefundReceipt.self),
                  rules: planningFetch(TransactionRule.self), splits: planningFetch(TransactionSplit.self), checkpoints: planningFetch(BankImportCheckpoint.self), paymentTransactions: transactions)
    }
    func saveCommitment(_ draft: CommitmentDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.amount.isNaN, draft.amount.currencyRounded > 0, ["debit", "credit"].contains(draft.direction),
              ["once", "monthly", "yearly"].contains(draft.cadence),
              ["confirmed", "suggested", "rejected", "stopped"].contains(draft.status),
              draft.count.map({ (1...1200).contains($0) }) ?? true else { throw BankTransactionEditError.unavailable }
        if let accountID = draft.accountID {
            guard try planningFetch(ExternalAccount.self).contains(where: { $0.id == accountID && $0.currencyCode == "EUR" }) else { throw BankTransactionEditError.unavailable }
        }
        let rows = try planningFetch(PlannedCommitment.self)
        if let previous = rows.first(where: { $0.id == draft.id || $0.sourceKey == draft.sourceKey }),
           try planningFetch(CommitmentPayment.self).contains(where: { $0.commitmentID == previous.id }),
           previous.dueDate != draft.dueDate || previous.cadence != draft.cadence || previous.accountID != draft.accountID || previous.direction != draft.direction || previous.count != draft.count {
            throw CommitmentEditError.linkedSchedule
        }
        let row = rows.first { $0.id == draft.id || $0.sourceKey == draft.sourceKey } ?? PlannedCommitment(id: draft.id, sourceKey: draft.sourceKey, title: draft.title, amount: draft.amount)
        if !rows.contains(where: { $0.id == row.id }) { container.mainContext.insert(row) }
        row.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines); row.amount = draft.amount.currencyRounded; row.direction = draft.direction
        row.dueDate = draft.dueDate; row.accountID = draft.accountID; row.cadence = draft.cadence
        row.count = draft.count; row.status = draft.status; row.category = ExpenseCategory.formStorageValue(for: draft.category)
        row.sourceKind = draft.sourceKind; row.sourceID = draft.sourceID
        if draft.sourceKind == "subscription", let sub = try planningFetch(Subscription.self).first(where: { $0.id == draft.sourceID }) {
            sub.name = draft.title; sub.amount = row.amount; sub.isActive = draft.status == "confirmed"
            if let date = draft.dueDate { sub.nextBillingDate = date }
            sub.billingCycle = draft.cadence == "yearly" ? .yearly : .monthly
        }
    }
    // The one rule for "this operation can still be assigned": no link to a subscription, a purchase or an income
    // source, no commitment payment, no provision payment, no expected refund (one the user gave up does not count).
    // An operation assigned twice would be counted twice, so every way of assigning one asks here first,
    // and so do the selection lists that offer operations.
    nonisolated static func isTransactionFree(_ transaction: BankTransaction, assignedTransactionIDs: Set<UUID>) -> Bool {
        transaction.link == nil && !assignedTransactionIDs.contains(transaction.id)
    }
    nonisolated static func assignedTransactionIDs(payments: [CommitmentPayment], provisionPayments: [ProvisionPayment], refunds: [ExpectedRefund]) -> Set<UUID> {
        Set(payments.map(\.transactionID))
            .union(provisionPayments.map(\.transactionID))
            .union(refunds.filter { !$0.isAbandoned }.map(\.transactionID))
    }
    func isTransactionFree(id: UUID) throws -> Bool {
        let transaction = try editableBankTransaction(id: id)
        let assigned = Self.assignedTransactionIDs(
            payments: try planningFetch(CommitmentPayment.self),
            provisionPayments: try planningFetch(ProvisionPayment.self),
            refunds: try planningFetch(ExpectedRefund.self)
        )
        return Self.isTransactionFree(transaction, assignedTransactionIDs: assigned)
    }
    func reconcilePayment(event: ForecastEvent, transactionID: UUID, now: Date = Date(), calendar: Calendar = .current) throws {
        let transaction = try editableBankTransaction(id: transactionID)
        let payments = try planningFetch(CommitmentPayment.self)
        guard let record = try planningFetch(PlannedCommitment.self).first(where: { $0.id == event.commitmentID }),
              record.status == "confirmed", try isTransactionFree(id: transactionID),
              let due = event.date, let end = calendar.date(byAdding: .day, value: 1, to: due) else { throw BankTransactionEditError.unavailable }
        let draft = CommitmentDraft(record)
        var paid: [String: Decimal] = [:]
        for payment in payments where payment.commitmentID == record.id {
            if let tx = try? editableBankTransaction(id: payment.transactionID), Self.validPayment(tx, for: draft, now: now, calendar: calendar) {
                paid[payment.occurrenceKey, default: 0] += min(payment.amount, tx.amount)
            }
        }
        guard let current = PlanningEngine(calendar: calendar).events(for: draft, from: calendar.startOfDay(for: due), until: end, paid: paid).first(where: { $0.id == event.id }),
              current == event, Self.validPayment(transaction, for: draft, now: now, calendar: calendar), transaction.amount <= abs(current.amount) else {
            throw BankTransactionEditError.unavailable
        }
        container.mainContext.insert(CommitmentPayment(transactionID: transactionID, commitmentID: event.commitmentID,
                                                       occurrenceKey: event.id, amount: transaction.amount))
    }
    static func validPayment(_ transaction: BankTransaction, for draft: CommitmentDraft, now: Date, calendar: Calendar) -> Bool {
        transaction.countsInTotals && transaction.currencyCode == "EUR" && calendar.startOfDay(for: transaction.bookingDate) <= calendar.startOfDay(for: now) &&
        (draft.direction == "debit" ? transaction.isExpense : transaction.isIncome) &&
        (draft.accountID == nil || draft.accountID == transaction.accountID)
    }
    func removeCommitmentPayment(transactionID: UUID) throws {
        guard let payment = try planningFetch(CommitmentPayment.self).first(where: { $0.transactionID == transactionID }) else { return }
        container.mainContext.delete(payment)
    }
    func saveThreshold(accountID: UUID, amount: Decimal) throws {
        guard !amount.isNaN, try planningFetch(ExternalAccount.self).contains(where: { $0.id == accountID }) else { throw BankTransactionEditError.unavailable }
        if let row = try planningFetch(PlanningAccountSetting.self).first(where: { $0.accountID == accountID }) { row.threshold = amount.currencyRounded }
        else { container.mainContext.insert(PlanningAccountSetting(accountID: accountID, threshold: amount)) }
    }
}

extension AppState {
    func planningWrite(_ action: (PeculeDataStore) throws -> Void) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        do { try action(dataStore); try dataStore.container.mainContext.save(); reload() }
        catch { dataStore.container.mainContext.rollback(); reload(); throw error }
    }
    func commitmentDrafts(on now: Date = Date(), calendar: Calendar = .current) -> [CommitmentDraft] {
        func matchesSubscription(title: String, accountID: UUID?) -> Bool {
            let key = RecurringChargeDetector.merchantKey(for: title)
            let detectedAccounts = Set(recurringCharges.filter { $0.key == key }.map(\.accountID))
                .union(planning.commitments.filter { $0.sourceKind == "detected" && RecurringChargeDetector.merchantKey(for: $0.title) == key }.compactMap(\.accountID))
            return subscriptions.contains { sub in
                guard RecurringChargeDetector.merchantKey(for: sub.name) == key else { return false }
                let linkedAccounts = Set(bankTransactions.filter { $0.linkedSubscriptionID == sub.id }.map(\.accountID))
                return accountID.map(linkedAccounts.contains) == true || (linkedAccounts.isEmpty && detectedAccounts.count == 1)
            }
        }
        // An explicit manual subscription supersedes its unambiguous detected counterpart.
        var drafts = planning.commitments.map(CommitmentDraft.init).filter {
            $0.sourceKind != "income" && ($0.sourceKind != "detected" || !matchesSubscription(title: $0.title, accountID: $0.accountID))
        }
        var keys = Set(drafts.map(\.sourceKey))
        func add(_ draft: CommitmentDraft) { if keys.insert(draft.sourceKey).inserted { drafts.append(draft) } }
        for sub in subscriptions {
            var d = CommitmentDraft(); d.id = sub.id; d.sourceKey = "subscription:\(sub.id)"; d.title = sub.name
            d.amount = sub.amount; d.dueDate = sub.nextBillingDate; d.cadence = sub.billingCycle == .yearly ? "yearly" : "monthly"
            d.status = sub.isActive ? "confirmed" : "stopped"
            d.category = sub.category; d.sourceKind = "subscription"; d.sourceID = sub.id
            let accounts = Set(bankTransactions.filter { $0.linkedSubscriptionID == sub.id }.map(\.accountID))
            if accounts.count == 1 { d.accountID = accounts.first }
            d.priceIncrease = recurringCharges.first { charge in
                RecurringChargeDetector.merchantKey(for: sub.name) == charge.key &&
                (d.accountID == nil || d.accountID == charge.accountID)
            }?.priceIncrease
            add(d)
        }
        for income in incomeSources where income.isActive {
            var d = CommitmentDraft(); d.id = income.id; d.sourceKey = "income:\(income.id)"; d.title = income.name
            d.amount = income.amount
            d.direction = "credit"; d.cadence = income.isRecurring ? "monthly" : "once"; d.sourceKind = "income"; d.sourceID = income.id
            if let saved = planning.commitments.first(where: { $0.sourceKey == d.sourceKey }) {
                d.dueDate = saved.dueDate; d.accountID = saved.accountID
            }
            add(d)
        }
        for charge in recurringCharges where charge.isCurrent(on: now, calendar: calendar) && !charge.isLinkedToSubscription {
            // A manual subscription may already describe this merchant; never add its hypothesis twice.
            guard !matchesSubscription(title: charge.label, accountID: charge.accountID) else { continue }
            var d = CommitmentDraft(); d.id = CommitmentDraft.stableID(for: "detected:\(charge.id)")
            d.sourceKey = "detected:\(charge.id)"; d.title = charge.label; d.amount = charge.latestAmount
            d.dueDate = charge.estimatedNextDate(calendar: calendar); d.accountID = charge.accountID
            d.cadence = charge.cadence == .yearly ? "yearly" : "monthly"; d.status = "suggested"
            d.category = charge.category.storageValue; d.sourceKind = "detected"; d.priceIncrease = charge.priceIncrease
            add(d)
        }
        // Keep user decisions; only refresh the evidence shown alongside them.
        for index in drafts.indices where drafts[index].sourceKind == "detected" {
            drafts[index].priceIncrease = recurringCharges.first { "detected:\($0.id)" == drafts[index].sourceKey }?.priceIncrease
        }
        return drafts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func planningEvents(on now: Date = Date(), until end: Date, calendar: Calendar = .current) -> [ForecastEvent] {
        let engine = PlanningEngine(calendar: calendar)
        let transactions = Dictionary((bankTransactions + planning.paymentTransactions).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var paid: [String: Decimal] = [:]
        for payment in planning.payments {
            if let tx = transactions[payment.transactionID], let record = planning.commitments.first(where: { $0.id == payment.commitmentID }),
               PeculeDataStore.validPayment(tx, for: CommitmentDraft(record), now: now, calendar: calendar) {
                paid[payment.occurrenceKey, default: 0] += min(payment.amount, tx.amount)
            }
        }
        var result: [ForecastEvent] = []
        let today = calendar.startOfDay(for: now)
        for draft in commitmentDrafts(on: now, calendar: calendar) {
            var draftPayments = paid
            // Explicit existing links can settle one occurrence only; ambiguous proximity is never auto-matched.
            func occurrences(paid: [String: Decimal]) -> [ForecastEvent] {
                let entries = engine.events(for: draft, from: today, until: end, paid: [:])
                return entries.compactMap { entry in
                    var event = entry
                    if draft.sourceKind == "income", let source = incomeSources.first(where: { $0.id == draft.sourceID }) {
                        guard let amount = resolvedMonthlyIncomeAmount(for: source, in: entry.date ?? now, calendar: calendar) else { return nil }
                        event.amount = amount
                    }
                    let alreadyPaid = paid[event.id] ?? 0
                    // A past occurrence with a payment is closed against it. The planned amount is not kept per
                    // occurrence, so a later price change would otherwise reopen the difference on every past
                    // payment. Cost: such an occurrence no longer takes a second, complementary payment.
                    if alreadyPaid > 0, let date = event.date, date < today { return nil }
                    let amount = max(0, abs(event.amount) - alreadyPaid).currencyRounded
                    guard amount > 0 else { return nil }
                    event.amount = event.amount < 0 ? -amount : amount
                    return event
                }
            }
            let allEvents = occurrences(paid: [:])
            if let sourceID = draft.sourceID {
                for tx in bankTransactions where tx.countsInTotals && calendar.startOfDay(for: tx.bookingDate) <= calendar.startOfDay(for: now) &&
                    ((draft.sourceKind == "subscription" && tx.linkedSubscriptionID == sourceID && tx.isExpense) ||
                     (draft.sourceKind == "income" && tx.linkedIncomeSourceID == sourceID && tx.isIncome)) &&
                    !planning.payments.contains(where: { $0.transactionID == tx.id }) && tx.currencyCode == "EUR" {
                    let matches = allEvents.filter { event in
                        event.date.map { abs(calendar.dateComponents([.day], from: $0, to: tx.bookingDate).day ?? 99) <= 7 } == true &&
                        (event.accountID == nil || event.accountID == tx.accountID)
                    }
                    if matches.count == 1 { draftPayments[matches[0].id, default: 0] += tx.amount }
                }
            }
            result += occurrences(paid: draftPayments)
        }
        return result.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
    // The known charges still to come, for every figure: `planningEvents` minus what the bank already took.
    // Only when the amounts come from the bank: a manual plan does not contain the debit, so the charge must stay.
    // The raw `planningEvents` stays for listing and matching occurrences by hand.
    func remainingPlanningEvents(on now: Date = Date(), until end: Date, calendar: Calendar = .current) -> [ForecastEvent] {
        let events = planningEvents(on: now, until: end, calendar: calendar)
        guard prefersBankAmounts else { return events }
        return PlanningEngine(calendar: calendar).removingSettledCharges(
            from: events, transactions: bankTransactions,
            includedAccountIDs: Set(linkedExternalAccounts.filter(\.isIncludedInTotals).map(\.id)),
            assignedTransactionIDs: planning.assignedTransactionIDs, now: now)
    }
    func nextPlannedSalary(on now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let ids = Set(incomeSources.filter { $0.type == .salary && $0.isActive }.map(\.id))
        let end = calendar.date(byAdding: .day, value: 366, to: now) ?? now
        let salaryIDs = Set(commitmentDrafts(on: now, calendar: calendar).filter { $0.sourceID.map(ids.contains) == true && $0.sourceKind == "income" }.map(\.id))
        let included = Set(externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }.map(\.id))
        return planningEvents(on: now, until: end, calendar: calendar).filter {
            salaryIDs.contains($0.commitmentID) && $0.confirmed && ($0.accountID.map(included.contains) ?? true)
        }.compactMap(\.date).filter { $0 >= calendar.startOfDay(for: now) }.min()
    }
    func planningForecast(on now: Date = Date(), until end: Date? = nil, accountID: UUID? = nil,
                          habitual: Bool = false, extra: [ForecastEvent] = [], calendar: Calendar = .current) -> PlanningForecast {
        let end = end ?? calendar.date(byAdding: .day, value: 30, to: calendar.startOfDay(for: now))!
        let selected = externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" && (accountID == nil || $0.id == accountID) }
        let events = remainingPlanningEvents(on: now, until: end, calendar: calendar) + extra
        let includedIDs = Set(selected.map(\.id))
        let accounts: [ForecastAccount] = selected.map { account in
            .init(id: account.id, name: account.name, balance: account.balance,
                  threshold: planning.settings.first { $0.accountID == account.id }?.threshold ?? 0,
                  dailyVariable: habitualDailyVariable(for: account))
        }
        let scopedEvents = events.filter { event in
            guard let id = event.accountID else { return true }
            return includedIDs.contains(id) || !externalAccounts.contains(where: { $0.id == id })
        }
        let stale = selected.contains { account in
            account.lastSyncError != nil || account.normalizedStatus != .active ||
            (account.balanceDate.map { now.timeIntervalSince($0) >= 86400 } ?? true) ||
            (!account.isManual && (account.lastSyncedAt.map { now.timeIntervalSince($0) >= BankFreshnessService.staleAfter } ?? true))
        }
        // Keep unassigned items visible on a single-account page without charging that account.
        let forecastEvents = accountID == nil ? scopedEvents : scopedEvents.filter { $0.accountID != nil }
        var result = PlanningEngine(calendar: calendar).forecast(accounts: accounts, events: forecastEvents, from: now, until: end, habitual: habitual, incomplete: stale)
        if accountID != nil {
            result.unresolved += scopedEvents.filter { $0.accountID == nil }
            result.incomplete = result.incomplete || !result.unresolved.isEmpty
        }
        return result

    }
    // The one place that decides whether an account's variable spending may be estimated, so the habitual reading of
    // the cash-flow calendar and the month-end forecast (`cashflowForecast`) always stand or fall together.
    // The gateway supplies requested windows and import completion, not certified history coverage. Neither the first
    // transaction nor a completed import proves an empty month complete. Nothing certifies a coverage today, so the
    // estimate stays unavailable (nil) for every account. The day a source of coverage exists, it belongs here.
    func habitualDailyVariable(for account: ExternalAccount) -> Decimal? { nil }
}

// Durable source identities survive a new bank import and changes to the latest evidence row.
extension CommitmentDraft {
    static func stableID(for key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    var annualCost: Decimal? {
        guard count == nil, cadence != "once" else { return nil }
        return (amount * (cadence == "monthly" ? 12 : 1)).currencyRounded
    }
}

enum CommitmentEditError: LocalizedError {
    case linkedSchedule
    var errorDescription: String? { AppLocalizer.string("commitments.linkedSchedule") }
}

extension AppState {
    func installmentDraft(for transactionID: UUID) -> CommitmentDraft? {
        guard let tx = bankTransaction(id: transactionID), tx.isExpense,
              let evidence = tx.installmentEvidence, evidence.number < evidence.count else { return nil }
        let key = "installment:\(tx.id)"
        if let existing = planning.commitments.first(where: { $0.sourceKey == key }) { return CommitmentDraft(existing) }
        var draft = CommitmentDraft()
        draft.id = CommitmentDraft.stableID(for: key); draft.sourceKey = key
        draft.title = tx.label; draft.amount = tx.amount; draft.accountID = tx.accountID
        draft.count = evidence.count - evidence.number; draft.status = "suggested"
        draft.category = tx.category; draft.sourceKind = "installment"; draft.sourceID = tx.id
        // The next date is deliberately not inferred from an n/N marker.
        return draft
    }
    func confirmedUpcomingCharges(on now: Date, calendar: Calendar) -> [CashflowForecast.UpcomingCharge] {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }
        let included = Set(externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }.map(\.id))
        return remainingPlanningEvents(on: now, until: month.end, calendar: calendar).compactMap { event in
            guard event.confirmed, event.amount < 0, let date = event.date, date >= calendar.startOfDay(for: now),
                  event.accountID.map(included.contains) ?? true else { return nil }
            return .init(id: event.commitmentID, name: event.title, amount: -event.amount, date: date)
        }
    }
}
