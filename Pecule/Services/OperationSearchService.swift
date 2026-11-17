import Foundation

struct OperationFilter: Equatable {
    enum Source: String, CaseIterable { case bank, manual }
    var source: Source?
    var includedOnly = false
    var text = ""
    var accountID: UUID?
    var dateFrom: Date?
    var dateUntil: Date? // Exclusive; the UI advances the selected final day by one calendar day.
    var category: ExpenseCategory?
    var direction: BankTransactionDirection?
    var status: BankTransactionStatus?
    var minimumAmount: Decimal?
    var maximumAmount: Decimal?
    var needsReview = false
}

struct OperationRecord: Identifiable {
    enum ID: Hashable { case bank(UUID), purchase(UUID) }
    let id: ID
    let date: Date
    let title: String
    let merchant: String
    let accountID: UUID?
    let category: ExpenseCategory
    let amount: Decimal
    let currency: String
    let direction: BankTransactionDirection
    let status: BankTransactionStatus
    let isIncluded: Bool
    let isRefund: Bool
    let needsReview: Bool
    let searchText: String
    var creditNature: CreditNature? = nil
    // Achat saisi à la main qu'une opération bancaire plausible représente déjà : il reste consultable mais
    // ne compte pas, sans quoi la même dépense serait comptée deux fois avant le rapprochement.
    var representedByBankOperation = false
}

struct OperationSearchResult {
    let records: [OperationRecord]
    let grossExpenses: Decimal
    let refunds: Decimal
    let income: Decimal
    var netExpenses: Decimal { (grossExpenses - refunds).currencyRounded }
}

struct OperationSearchService {
    // Immutable projections are rebuilt after a store reload, not on every row render.
    // Quels achats saisis comptent : `ManualPurchaseCoverageService`, la même règle que le résumé du mois.
    func records(
        transactions: [BankTransaction],
        purchases: [Purchase],
        accounts: [ExternalAccount],
        linkedPurchaseIDs: Set<UUID>? = nil,
        calendar: Calendar = .current
    ) -> [OperationRecord] {
        let includedIDs = Set(accounts.filter(\.isIncludedInTotals).map(\.id))
        // Déduit des opérations fournies quand l'appelant les a toutes ; transmis quand il n'en a qu'une
        // fenêtre, sans quoi un achat rattaché hors fenêtre réapparaîtrait en double. Seul un lien vers une
        // opération qui compte dans les totaux masque l'achat : le transmettre filtré de la même façon.
        let coverage = ManualPurchaseCoverageService(calendar: calendar).coverage(
            purchases: purchases,
            transactions: transactions,
            includedAccountIDs: includedIDs,
            settledPurchaseIDs: linkedPurchaseIDs
        )
        let bank = transactions.map { transaction in
            OperationRecord(id: .bank(transaction.id), date: transaction.bookingDate, title: transaction.label,
                merchant: transaction.counterpartyName ?? "", accountID: transaction.accountID,
                category: ExpenseCategory.canonicalCategory(for: transaction.category), amount: transaction.amount,
                currency: transaction.currencyCode, direction: transaction.normalizedDirection,
                status: transaction.normalizedStatus,
                isIncluded: includedIDs.contains(transaction.accountID) && transaction.countsInTotals,
                isRefund: transaction.isRefund, needsReview: transaction.needsClassificationReview,
                searchText: normalize(transaction.label + " " + (transaction.counterpartyName ?? "")),
                creditNature: transaction.normalizedDirection == .credit ? transaction.creditNature : nil)
        }
        let manual = purchases.filter { !coverage.settledPurchaseIDs.contains($0.id) }.map { purchase in
            let represented = coverage.representedPurchases[purchase.id] != nil
            // Même catégorie canonique que le résumé du mois (un nom inconnu reste distinct, il ne devient pas « Autre »).
            return OperationRecord(id: .purchase(purchase.id), date: purchase.date, title: purchase.title,
                merchant: purchase.merchant, accountID: nil, category: ExpenseCategory.canonicalCategory(for: purchase.category),
                amount: purchase.amount, currency: "EUR", direction: .debit, status: .booked,
                isIncluded: !represented, isRefund: false, needsReview: purchase.normalizedCategory == .other,
                searchText: normalize(purchase.title + " " + purchase.merchant),
                representedByBankOperation: represented)
        }
        return (bank + manual).sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return stableID($0.id) < stableID($1.id)
        }
    }

    func search(_ records: [OperationRecord], filter: OperationFilter) -> OperationSearchResult {
        let words = normalize(filter.text).split(whereSeparator: \.isWhitespace)
        let matches = records.filter { record in
            (filter.source == nil || (record.accountID == nil ? .manual : .bank) == filter.source) &&
            (!filter.includedOnly || record.isIncluded) &&
            words.allSatisfy { record.searchText.contains($0) } &&
            (filter.accountID == nil || record.accountID == filter.accountID) &&
            (filter.dateFrom.map { record.date >= $0 } ?? true) &&
            (filter.dateUntil.map { record.date < $0 } ?? true) &&
            (filter.category == nil || record.category == filter.category) &&
            (filter.direction == nil || record.direction == filter.direction) &&
            (filter.status == nil || record.status == filter.status) &&
            (filter.minimumAmount.map { record.amount >= $0 } ?? true) &&
            (filter.maximumAmount.map { record.amount <= $0 } ?? true) &&
            (!filter.needsReview || record.needsReview)
        }
        var gross: Decimal = 0, refunds: Decimal = 0, income: Decimal = 0
        for record in matches where record.isIncluded && record.currency == "EUR" {
            if record.direction == .debit { gross += record.amount }
            else if record.isRefund { refunds += record.amount }
            else { income += record.amount }
        }
        return OperationSearchResult(records: matches, grossExpenses: gross.currencyRounded, refunds: refunds.currencyRounded, income: income.currencyRounded)
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
    private func stableID(_ id: OperationRecord.ID) -> String {
        switch id { case .bank(let id): "bank-" + id.uuidString; case .purchase(let id): "purchase-" + id.uuidString }
    }
}
