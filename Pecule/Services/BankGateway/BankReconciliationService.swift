import Foundation

// Links imported bank transactions to the manual entries they settle, only when the evidence is unambiguous.
struct BankReconciliationService: Sendable {
    struct Transaction: Equatable, Sendable {
        let externalID: String
        let amount: Decimal
        let direction: BankTransactionDirection
        let bookingDate: Date
        let label: String
        let counterparty: String?
        let isEligible: Bool
        // The account the operation belongs to: recurring charges are detected account by account.
        var accountID: UUID? = nil
    }

    struct SubscriptionCandidate: Equatable, Sendable {
        let id: UUID
        let name: String
        let amount: Decimal
        let billingCycle: BillingCycle
        let nextBillingDate: Date
        let isActive: Bool
    }

    struct PurchaseCandidate: Equatable, Sendable {
        let id: UUID
        let title: String
        let merchant: String
        let amount: Decimal
        let date: Date
    }

    struct IncomeCandidate: Equatable, Sendable {
        let id: UUID
        let name: String
        let amount: Decimal
        let isActive: Bool
    }

    enum Link: Hashable, Sendable {
        case subscription(UUID)
        case purchase(UUID)
        case income(UUID)

        init(_ link: BankTransactionLink) {
            switch link {
            case .subscription(let id): self = .subscription(id)
            case .purchase(let id): self = .purchase(id)
            case .income(let id): self = .income(id)
            }
        }
    }

    struct Match: Hashable, Sendable {
        let externalID: String
        let link: Link
    }

    // An operation already settled against a manual entry, whatever its age: what makes a billing cycle
    // "taken", and the proof that a creditor has already debited a subscription on its rhythm.
    struct LinkedOperation: Equatable, Sendable {
        let link: Link
        let bookingDate: Date
        let label: String
    }

    var amountTolerance: Decimal = Decimal(string: "0.01")!
    var purchaseDayTolerance: Int = 3
    var subscriptionDayTolerance: Int = 5
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    // Two operations closer than half a billing cycle belong to the same cycle.
    private static let monthlyHalfCycleDays = 15
    private static let yearlyHalfCycleDays = 182

    private struct Pair {
        let transaction: Transaction
        let link: Link
        let score: Int
        // Days between the operation and the entry's own date (nearest billing date, purchase date); 0 when the entry has none.
        let gap: Int
    }

    // Which entries are spoken for. A purchase settles once; a subscription or a salary settles once per cycle.
    private struct Ledger {
        var closed: Set<Link> = []
        var settledDates: [Link: [Date]] = [:]

        mutating func record(_ link: Link, on date: Date) {
            if case .purchase = link { closed.insert(link) } else { settledDates[link, default: []].append(date) }
        }
    }

    func matches(
        transactions: [Transaction],
        subscriptions: [SubscriptionCandidate],
        purchases: [PurchaseCandidate],
        incomeSources: [IncomeCandidate],
        alreadyLinked: Set<Link> = [],
        linkedOperations: [LinkedOperation] = [],
        recurringChargeIDs: Set<String> = []
    ) -> [Match] {
        var ledger = Ledger(closed: alreadyLinked)
        for operation in linkedOperations { ledger.record(operation.link, on: operation.bookingDate) }
        var linkedBySubscription: [UUID: [LinkedOperation]] = [:]
        for operation in linkedOperations {
            if case .subscription(let id) = operation.link { linkedBySubscription[id, default: []].append(operation) }
        }
        let cycles = Dictionary(subscriptions.map { ($0.id, $0.billingCycle) }, uniquingKeysWith: { first, _ in first })

        // Every (operation, entry) pair that has evidence, judged on its own.
        var pairs: [Pair] = []
        for transaction in transactions where transaction.isEligible {
            switch transaction.direction {
            case .debit:
                pairs += subscriptionPairs(for: transaction, in: subscriptions, linkedOperations: linkedBySubscription, recurringChargeIDs: recurringChargeIDs)
                pairs += purchasePairs(for: transaction, in: purchases)
            case .credit:
                pairs += incomePairs(for: transaction, in: incomeSources)
            }
        }
        // The strongest evidence is assigned first, then the closest date; identifiers only make the order
        // total, so the outcome never depends on the order the operations arrive in.
        pairs.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            if $0.transaction.externalID != $1.transaction.externalID { return $0.transaction.externalID < $1.transaction.externalID }
            return $0.link.sortKey < $1.link.sortKey
        }
        let pairsByTransaction = Dictionary(grouping: pairs, by: { $0.transaction.externalID })

        func isOpen(_ pair: Pair) -> Bool {
            entryIsOpen(pair.link, on: pair.transaction.bookingDate, in: ledger, cycles: cycles)
        }

        var decided = Set<String>()
        var assigned: [(match: Match, date: Date)] = []
        for pair in pairs {
            let id = pair.transaction.externalID
            guard !decided.contains(id), isOpen(pair) else { continue }
            decided.insert(id)
            // Never guess: another entry still open fits this operation just as well.
            let rivals = (pairsByTransaction[id] ?? []).filter { $0.link != pair.link && $0.score == pair.score && isOpen($0) }
            guard rivals.isEmpty else { continue }
            ledger.record(pair.link, on: pair.transaction.bookingDate)
            assigned.append((Match(externalID: id, link: pair.link), pair.transaction.bookingDate))
        }

        return assigned.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.match.externalID < $1.match.externalID
        }.map(\.match)
    }

    // Where a subscription's billing date moves once an operation settles one of its cycles: the first cycle date
    // strictly after the operation, counted from the anchor in both directions like the planning engine (the anchor
    // plus whole cycles, so a 31st never drifts), so a date that stayed behind is caught up however late it is.
    // A payment made up to `subscriptionDayTolerance` days early still settles the cycle it anticipates, and a date
    // is never moved backwards.
    func nextBillingDate(settledOn transactionDate: Date, anchor: Date, cycle: BillingCycle, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar
        let component: Calendar.Component = cycle == .monthly ? .month : .year
        guard let threshold = calendar.date(byAdding: .day, value: subscriptionDayTolerance, to: transactionDate), threshold >= anchor else {
            return anchor
        }
        var index = max(0, (calendar.dateComponents([component], from: anchor, to: threshold).value(for: component) ?? 0) - 1)
        var steps = 0
        while let cycleDate = calendar.date(byAdding: component, value: index, to: anchor), steps < 1_200 {
            if cycleDate > threshold { return cycleDate }
            index += 1
            steps += 1
        }
        return anchor
    }

    private func entryIsOpen(_ link: Link, on date: Date, in ledger: Ledger, cycles: [UUID: BillingCycle]) -> Bool {
        guard !ledger.closed.contains(link) else { return false }
        let halfCycle: Int
        switch link {
        case .purchase:
            return true
        case .subscription(let id):
            halfCycle = cycles[id] == .yearly ? Self.yearlyHalfCycleDays : Self.monthlyHalfCycleDays
        case .income:
            halfCycle = Self.monthlyHalfCycleDays
        }
        return !(ledger.settledDates[link] ?? []).contains { daysBetween($0, date) < halfCycle }
    }

    private func subscriptionPairs(
        for transaction: Transaction,
        in subscriptions: [SubscriptionCandidate],
        linkedOperations: [UUID: [LinkedOperation]],
        recurringChargeIDs: Set<String>
    ) -> [Pair] {
        subscriptions.compactMap { subscription in
            guard subscription.isActive, amountsMatch(transaction.amount, subscription.amount) else {
                return nil
            }
            let nameMatch = labelMatches(transaction, name: subscription.name)
            let gap = cycleDistance(from: transaction.bookingDate, anchor: subscription.nextBillingDate, cycle: subscription.billingCycle)
            let dateMatch = gap <= subscriptionDayTolerance
            // The right amount near a due date proves nothing (a baker's 15,99 next to a 15,99 subscription):
            // the label names the subscription, or this creditor is known to debit it on that rhythm.
            guard nameMatch || (dateMatch && hasRecurringEvidence(for: transaction, subscription: subscription, linkedOperations: linkedOperations[subscription.id] ?? [], recurringChargeIDs: recurringChargeIDs)) else {
                return nil
            }
            return Pair(transaction: transaction, link: .subscription(subscription.id), score: 2 + (nameMatch ? 2 : 0) + (dateMatch ? 1 : 0), gap: gap)
        }
    }

    private func purchasePairs(for transaction: Transaction, in purchases: [PurchaseCandidate]) -> [Pair] {
        purchases.compactMap { purchase in
            let gap = daysBetween(transaction.bookingDate, purchase.date)
            guard amountsMatch(transaction.amount, purchase.amount), gap <= purchaseDayTolerance else {
                return nil
            }
            let nameMatch = labelMatches(transaction, name: purchase.merchant) || labelMatches(transaction, name: purchase.title)
            return Pair(transaction: transaction, link: .purchase(purchase.id), score: 2 + (nameMatch ? 2 : 0), gap: gap)
        }
    }

    private func incomePairs(for transaction: Transaction, in incomeSources: [IncomeCandidate]) -> [Pair] {
        incomeSources.compactMap { source in
            guard source.isActive, amountsMatch(transaction.amount, source.amount, tolerance: max(amountTolerance, source.amount * Decimal(string: "0.01")!)) else {
                return nil
            }
            // An equal amount never proves a salary (or any particular income source).
            guard labelMatches(transaction, name: source.name) else { return nil }
            return Pair(transaction: transaction, link: .income(source.id), score: 4, gap: 0)
        }
    }

    // A recurring debit: the creditor's charge is detected as recurring on this account, or the same creditor
    // already settled the previous cycle of this very subscription.
    private func hasRecurringEvidence(
        for transaction: Transaction,
        subscription: SubscriptionCandidate,
        linkedOperations: [LinkedOperation],
        recurringChargeIDs: Set<String>
    ) -> Bool {
        let creditor = RecurringChargeDetector.merchantKey(for: transaction.label)
        guard !creditor.isEmpty else { return false }
        if let accountID = transaction.accountID, recurringChargeIDs.contains("\(accountID.uuidString):\(creditor)") {
            return true
        }
        let component: Calendar.Component = subscription.billingCycle == .monthly ? .month : .year
        guard let previousCycle = calendar.date(byAdding: component, value: -1, to: transaction.bookingDate) else { return false }
        return linkedOperations.contains {
            RecurringChargeDetector.merchantKey(for: $0.label) == creditor && daysBetween($0.bookingDate, previousCycle) <= subscriptionDayTolerance
        }
    }

    private func amountsMatch(_ left: Decimal, _ right: Decimal, tolerance: Decimal? = nil) -> Bool {
        abs(left - right) <= (tolerance ?? amountTolerance)
    }

    private func labelMatches(_ transaction: Transaction, name: String) -> Bool {
        let haystack = " " + BankTransactionCategorizer.normalize([transaction.label, transaction.counterparty ?? ""].joined(separator: " ")) + " "
        let tokens = BankTransactionCategorizer.normalize(name).split(separator: " ").map(String.init).filter { $0.count >= 4 }
        return tokens.contains { haystack.contains(" \($0)") }
    }

    // Days from `date` to the closest billing date, counted from the anchor in both directions: a date left
    // behind, or ahead, is reached by whole cycles exactly as the planning engine counts them.
    private func cycleDistance(from date: Date, anchor: Date, cycle: BillingCycle) -> Int {
        let component: Calendar.Component = cycle == .monthly ? .month : .year
        let whole = calendar.dateComponents([component], from: anchor, to: date).value(for: component) ?? 0
        var distance = daysBetween(date, anchor)
        for index in (whole - 1) ... (whole + 1) {
            guard let cycleDate = calendar.date(byAdding: component, value: index, to: anchor) else {
                continue
            }
            distance = min(distance, daysBetween(date, cycleDate))
        }
        return distance
    }

    private func daysBetween(_ left: Date, _ right: Date) -> Int {
        Int((abs(left.timeIntervalSince(right)) / 86_400).rounded())
    }
}

private extension BankReconciliationService.Link {
    // A total order on entries, for the final tie-break between otherwise equal pairs.
    var sortKey: String {
        switch self {
        case .subscription(let id): "s" + id.uuidString
        case .purchase(let id): "p" + id.uuidString
        case .income(let id): "i" + id.uuidString
        }
    }
}
