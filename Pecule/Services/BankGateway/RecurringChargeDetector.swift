import Foundation

// A debit that keeps coming back at the same cadence with a stable amount: a subscription, tracked or not.
struct RecurringCharge: Equatable, Identifiable {
    enum Cadence: Equatable {
        case monthly
        case yearly
    }

    let key: String
    let accountID: UUID
    let label: String
    let cadence: Cadence
    let occurrences: Int
    let latestAmount: Decimal
    let previousAmount: Decimal
    let lastDate: Date
    let category: ExpenseCategory
    let isLinkedToSubscription: Bool

    var id: String { "\(accountID.uuidString):\(key)" }

    func isCurrent(on date: Date, calendar: Calendar = .current) -> Bool {
        let age = calendar.dateComponents([.day], from: lastDate, to: date).day ?? Int.max
        return calendar.startOfDay(for: lastDate) <= calendar.startOfDay(for: date) && age <= (cadence == .monthly ? 45 : 400)
    }

    func estimatedNextDate(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: cadence == .monthly ? .month : .year, value: 1, to: lastDate) ?? lastDate
    }

    // At least 2 % and 0.50 above the previous typical amount.
    var priceIncrease: Decimal? {
        let threshold = max((previousAmount * Decimal(0.02)).currencyRounded, TestableConstants.minimumIncrease)
        let delta = (latestAmount - previousAmount).currencyRounded
        return delta >= threshold ? delta : nil
    }

    enum TestableConstants {
        static let minimumIncrease: Decimal = 0.5
    }
}

struct RecurringChargeDetector {
    static let noiseWords: Set<String> = [
        "prlv", "sepa", "cb", "carte", "paiement", "facture", "echeance", "ref", "vir", "virement", "dd", "achat",
        "com", "fr", "www", "international", "bv", "sas", "sarl", "ltd", "inc", "europe", "france", "paris", "irl", "ie", "lu", "nl",
    ]
    static let monthlyInterval = 28 ... 33
    static let yearlyInterval = 360 ... 370
    static let minimumMonthlyOccurrences = 3
    // One year of history cannot hold three yearly debits; two matching ones a year apart are convincing enough.
    static let minimumYearlyOccurrences = 2
    static let amountTolerance = 0.20

    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func detect(in transactions: [BankTransaction], includedAccountIDs: Set<UUID>, asOf date: Date = Date()) -> [RecurringCharge] {
        var groups: [String: [BankTransaction]] = [:]
        // Ordre délibéré : les comparaisons immédiates écartent l'essentiel des lignes avant
        // `excludesInfiniteRecurrence`, seul test coûteux de la liste puisqu'il analyse le libellé.
        for transaction in transactions
        where transaction.normalizedDirection == .debit
            && transaction.linkedPurchaseID == nil
            && includedAccountIDs.contains(transaction.accountID)
            && transaction.countsInTotals
            && calendar.startOfDay(for: transaction.bookingDate) <= calendar.startOfDay(for: date)
            && !transaction.excludesInfiniteRecurrence {
            let key = Self.merchantKey(for: transaction.label)
            guard !key.isEmpty else {
                continue
            }
            groups["\(transaction.accountID.uuidString):\(key)", default: []].append(transaction)
        }

        return groups.values.compactMap { rows in charge(rows: rows) }
            .sorted { $0.lastDate != $1.lastDate ? $0.lastDate > $1.lastDate : $0.key < $1.key }
    }

    // Charges no subscription accounts for: nothing linked and no active subscription sharing a word with the merchant.
    func untracked(_ charges: [RecurringCharge], subscriptions: [Subscription]) -> [RecurringCharge] {
        let subscriptionKeys = subscriptions.filter(\.isActive).map { Self.merchantKey(for: $0.name) }
        return charges.filter { charge in
            guard !charge.isLinkedToSubscription else {
                return false
            }
            let words = Set(charge.key.split(separator: " ").map(String.init))
            return !subscriptionKeys.contains { key in
                !Set(key.split(separator: " ").map(String.init)).isDisjoint(with: words)
            }
        }
    }

    static func merchantKey(for label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let words = folded
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !noiseWords.contains($0) }
        return words.prefix(2).joined(separator: " ")
    }

    private func charge(rows: [BankTransaction]) -> RecurringCharge? {
        let sorted = rows.sorted { $0.bookingDate < $1.bookingDate }
        guard sorted.count >= Self.minimumYearlyOccurrences else {
            return nil
        }
        let intervals = zip(sorted.dropFirst(), sorted).map { later, earlier in
            calendar.dateComponents([.day], from: earlier.bookingDate, to: later.bookingDate).day ?? 0
        }
        let medianInterval = median(intervals.map(Double.init))
        let cadence: RecurringCharge.Cadence
        if Self.monthlyInterval.contains(Int(medianInterval)),
           intervals.allSatisfy({ (25...38).contains($0) }), sorted.count >= Self.minimumMonthlyOccurrences {
            cadence = .monthly
        } else if Self.yearlyInterval.contains(Int(medianInterval)), intervals.allSatisfy({ (350...380).contains($0) }) {
            cadence = .yearly
        } else {
            return nil
        }

        let amounts = sorted.map { NSDecimalNumber(decimal: $0.amount).doubleValue }
        let typical = median(amounts)
        guard typical > 0, amounts.allSatisfy({ abs($0 - typical) <= typical * Self.amountTolerance }) else {
            return nil
        }
        let latest = sorted[sorted.count - 1]
        let previousAmounts = sorted.dropLast().map(\.amount)

        return RecurringCharge(
            key: Self.merchantKey(for: latest.label),
            accountID: latest.accountID,
            label: latest.label,
            cadence: cadence,
            occurrences: sorted.count,
            latestAmount: latest.amount,
            previousAmount: MonthlyObservationService(calendar: calendar).median(previousAmounts),
            lastDate: latest.bookingDate,
            category: ExpenseCategory.canonicalCategory(for: latest.category),
            isLinkedToSubscription: sorted.contains { $0.linkedSubscriptionID != nil }
        )
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
