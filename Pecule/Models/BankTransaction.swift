import CryptoKit
import Foundation
import SwiftData

enum BankTransactionDirection: String, Codable, CaseIterable {
    case debit
    case credit
}

enum BankTransactionStatus: String, Codable, CaseIterable {
    case booked
    case pending
}

enum BankTransactionEditError: LocalizedError {
    case unavailable
    var errorDescription: String? { AppLocalizer.string("accounts.transaction.unavailable") }
}

@Model
final class BankTransaction: Identifiable {
    var id: UUID
    @Attribute(.unique) var externalID: String
    var accountID: UUID
    // Always positive; the sign lives in `direction`, like every other amount in the app.
    var amount: Decimal
    var direction: String
    var currencyCode: String
    var bookingDate: Date
    var valueDate: Date?
    var label: String
    var counterpartyName: String?
    var status: String
    var merchantCategoryCode: String?
    var bankTransactionCode: String?
    var category: String
    var isInternalTransfer: Bool
    var isIgnored: Bool
    var linkedPurchaseID: UUID?
    var linkedSubscriptionID: UUID?
    var linkedIncomeSourceID: UUID?
    // Additive V3 annotations. Automatic preserves the original bank evidence.
    var natureOverride: String = "automatic"
    var refundOfTransactionID: UUID?
    var userNote: String?
    var automaticCategory: String?
    var categoryOverride: String?
    var ruleCategory: String?
    var ruleApplicationID: UUID?
    var isAbsentFromBank: Bool = false
    var internalTransferOverride: Bool?
    var transferEvidence: String?
    var installmentDecision: String?
    var installmentNumber: Int?
    var installmentCount: Int?


    init(
        id: UUID = UUID(),
        externalID: String,
        accountID: UUID,
        amount: Decimal,
        direction: BankTransactionDirection,
        currencyCode: String,
        bookingDate: Date,
        valueDate: Date? = nil,
        label: String,
        counterpartyName: String? = nil,
        status: BankTransactionStatus = .booked,
        merchantCategoryCode: String? = nil,
        bankTransactionCode: String? = nil,
        category: String = ExpenseCategory.other.storageValue,
        isInternalTransfer: Bool = false,
        isIgnored: Bool = false,
        linkedPurchaseID: UUID? = nil,
        linkedSubscriptionID: UUID? = nil,
        linkedIncomeSourceID: UUID? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.accountID = accountID
        self.amount = amount
        self.direction = direction.rawValue
        self.currencyCode = currencyCode
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.label = label
        self.counterpartyName = counterpartyName
        self.status = status.rawValue
        self.merchantCategoryCode = merchantCategoryCode
        self.bankTransactionCode = bankTransactionCode
        self.category = category
        self.isInternalTransfer = isInternalTransfer
        self.isIgnored = isIgnored
        self.linkedPurchaseID = linkedPurchaseID
        self.linkedSubscriptionID = linkedSubscriptionID
        self.linkedIncomeSourceID = linkedIncomeSourceID
    }
}

enum BankTransactionLink: Equatable, Hashable {
    case subscription(UUID)
    case purchase(UUID)
    case income(UUID)

    init(_ link: BankReconciliationService.Link) {
        switch link {
        case .subscription(let id): self = .subscription(id)
        case .purchase(let id): self = .purchase(id)
        case .income(let id): self = .income(id)
        }
    }
}

extension BankTransaction {
    var link: BankTransactionLink? {
        if let linkedSubscriptionID { return .subscription(linkedSubscriptionID) }
        if let linkedPurchaseID { return .purchase(linkedPurchaseID) }
        if let linkedIncomeSourceID { return .income(linkedIncomeSourceID) }
        return nil
    }

    var isLinked: Bool {
        link != nil
    }

    func apply(_ link: BankTransactionLink?) {
        linkedSubscriptionID = nil
        linkedPurchaseID = nil
        linkedIncomeSourceID = nil
        switch link {
        case .subscription(let id): linkedSubscriptionID = id
        case .purchase(let id): linkedPurchaseID = id
        case .income(let id): linkedIncomeSourceID = id
        case nil: break
        }
    }

    var normalizedDirection: BankTransactionDirection {
        BankTransactionDirection(rawValue: direction) ?? .debit
    }

    var normalizedStatus: BankTransactionStatus {
        BankTransactionStatus(rawValue: status) ?? .booked
    }

    // Pending entries are often re-booked under a new reference: only booked ones count.
    var isExpense: Bool {
        normalizedDirection == .debit && countsInTotals
    }

    var isIncome: Bool {
        normalizedDirection == .credit && countsInTotals && !isRefund
    }

    var isRefund: Bool {
        guard normalizedDirection == .credit, countsInTotals else { return false }
        if natureOverride != "automatic" { return natureOverride == "refund" }
        let words = (label + " " + (counterpartyName ?? "")).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter }.map(String.init)
        return words.contains("remboursement") || words.contains("refund")
    }

    var netExpenseAmount: Decimal {
        isExpense ? amount : isRefund ? -amount : .zero
    }

    var countsInTotals: Bool {
        !isAbsentFromBank && !isInternalTransfer && !isIgnored && normalizedStatus == .booked && currencyCode == "EUR"
    }

    var hasUserAnnotations: Bool {
        installmentDecision != nil || isLinked || categoryOverride != nil || userNote != nil || natureOverride != "automatic" ||
        refundOfTransactionID != nil || internalTransferOverride != nil || isIgnored
    }

    var classificationSource: String {
        categoryOverride != nil ? "manual" : automaticCategory != nil ? "automatic" : "legacy"
    }

    convenience init?(
        dto: BankTransactionDTO,
        accountID: UUID,
        accountStableIdentifier: String
    ) {
        guard let bookingDate = dto.bookingDate ?? dto.valueDate ?? dto.transactionDate else {
            return nil
        }
        let direction: BankTransactionDirection = dto.creditDebitIndicator == .credit ? .credit : .debit
        let counterparty = direction == .debit ? dto.creditorName : dto.debtorName
        let label = dto.remittanceInformation.first { !$0.isEmpty } ?? counterparty ?? ""
        self.init(
            externalID: Self.externalID(accountStableIdentifier: accountStableIdentifier, dto: dto, bookingDate: bookingDate),
            accountID: accountID,
            // Some banks sign the amount even though credit_debit_indicator already carries the direction.
            amount: abs(dto.amount).currencyRounded,
            direction: direction,
            currencyCode: dto.currency,
            bookingDate: bookingDate,
            valueDate: dto.valueDate,
            label: label,
            counterpartyName: counterparty,
            status: dto.status == "PDNG" ? .pending : .booked,
            merchantCategoryCode: dto.merchantCategoryCode,
            bankTransactionCode: dto.bankTransactionCode
        )
    }

    // Banks do not always provide entry_reference; the fallback digest keeps re-imports idempotent.
    static func externalID(
        accountStableIdentifier: String,
        dto: BankTransactionDTO,
        bookingDate: Date
    ) -> String {
        if let reference = dto.entryReference ?? dto.transactionId, !reference.isEmpty {
            return "\(accountStableIdentifier)#\(reference)"
        }
        let fingerprint = [
            String(Int(bookingDate.timeIntervalSince1970)),
            "\(dto.amount)",
            dto.currency,
            dto.creditDebitIndicator.rawValue,
            dto.remittanceInformation.joined(separator: "|"),
            dto.creditorName ?? "",
            dto.debtorName ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return "\(accountStableIdentifier)#sha256:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    // True when `externalID(...)` falls back to a fingerprint of the operation instead of a bank
    // reference. Same condition as the guard above: the two must always agree.
    static func usesFallbackIdentifier(_ dto: BankTransactionDTO) -> Bool {
        (dto.entryReference ?? dto.transactionId)?.isEmpty ?? true
    }

    // A pending entry the bank re-books under a new reference hands its decisions to the new row.
    // Bank evidence (amount, dates, labels, automatic category) stays the new row's own.
    func adoptAnnotations(from previous: BankTransaction) {
        categoryOverride = previous.categoryOverride
        if let override = previous.categoryOverride { category = override }
        userNote = previous.userNote
        natureOverride = previous.natureOverride
        refundOfTransactionID = previous.refundOfTransactionID
        if let transferOverride = previous.internalTransferOverride {
            internalTransferOverride = transferOverride
            isInternalTransfer = previous.isInternalTransfer
        }
        isIgnored = previous.isIgnored
        linkedPurchaseID = previous.linkedPurchaseID
        linkedSubscriptionID = previous.linkedSubscriptionID
        linkedIncomeSourceID = previous.linkedIncomeSourceID
        installmentDecision = previous.installmentDecision
        installmentNumber = previous.installmentNumber
        installmentCount = previous.installmentCount
        ruleCategory = previous.ruleCategory
        ruleApplicationID = previous.ruleApplicationID
    }
}

// Two identical operations on the same day (two coffees at the same price) share one fingerprint.
// Within one import window the first keeps the identifier it has always had, so rows already stored
// are neither duplicated nor orphaned; the following ones get "#2", "#3"... and stay distinct instead
// of silently merging into the first.
struct BankTransactionOccurrenceCounter {
    private var occurrences: [String: Int] = [:]

    init() {}

    // A window interrupted and resumed mid-way keeps counting where it stopped: the identifiers
    // already fetched say how far each fingerprint got.
    init(resumingFrom fetchedExternalIDs: some Sequence<String>) {
        for identifier in fetchedExternalIDs {
            guard let (fingerprint, rank) = Self.split(identifier) else { continue }
            occurrences[fingerprint] = max(occurrences[fingerprint] ?? 0, rank)
        }
    }

    mutating func identifier(forFingerprint fingerprint: String) -> String {
        let rank = (occurrences[fingerprint] ?? 0) + 1
        occurrences[fingerprint] = rank
        return rank == 1 ? fingerprint : "\(fingerprint)#\(rank)"
    }

    private static let marker = "#sha256:"
    private static let digestLength = 64

    // "acct#sha256:<64 hex>" is rank 1, "acct#sha256:<64 hex>#3" is rank 3 of the same fingerprint.
    // Bank references never match this shape, and are ignored.
    static func split(_ identifier: String) -> (fingerprint: String, rank: Int)? {
        guard let marked = identifier.range(of: marker, options: .backwards) else { return nil }
        let tail = identifier[marked.upperBound...]
        let digest = tail.prefix(digestLength)
        guard digest.count == digestLength, digest.allSatisfy(\.isHexDigit) else { return nil }
        let suffix = tail.dropFirst(digestLength)
        let fingerprint = String(identifier[..<digest.endIndex])
        if suffix.isEmpty { return (fingerprint, 1) }
        guard suffix.hasPrefix("#"), let rank = Int(suffix.dropFirst()), rank >= 2 else { return nil }
        return (fingerprint, rank)
    }
}
