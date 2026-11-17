import Foundation
import SwiftData

enum BankInstitution: String, Codable, CaseIterable, Identifiable {
    case mock
    case boursorama
    case revolut
    case manual

    var id: String { rawValue }

    static var linkableCases: [BankInstitution] {
        allCases.filter { $0 != .manual }
    }

    var aspspName: String {
        switch self {
        case .mock: "Mock ASPSP"
        case .boursorama: "Boursorama Banque"
        case .revolut: "Revolut"
        case .manual: ""
        }
    }

    var aspspCountry: String { "FR" }

    func displayName(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        AppLocalizer.string("bankInstitution.\(rawValue)", locale: locale)
    }
}

enum ExternalAccountStatus: String, Codable, CaseIterable {
    case active
    case needsReconnect
    case error
}

@Model
final class ExternalAccount: Identifiable {
    var id: UUID
    // identification_hash from Enable Banking: stable across re-authorizations, unlike the per-session uid.
    @Attribute(.unique) var stableIdentifier: String
    var currentUID: String
    var linkID: String
    var institution: String
    var name: String
    var maskedIBAN: String?
    var currencyCode: String
    var balance: Decimal?
    var balanceType: String?
    var balanceDate: Date?
    var consentValidUntil: Date?
    var status: String
    var lastSyncedAt: Date?
    var lastSyncError: String?
    var requiresInclusionReview: Bool = false
    var isIncludedInTotals: Bool

    init(
        id: UUID = UUID(),
        stableIdentifier: String,
        currentUID: String,
        linkID: String,
        institution: BankInstitution,
        name: String,
        maskedIBAN: String? = nil,
        currencyCode: String,
        balance: Decimal? = nil,
        balanceType: String? = nil,
        balanceDate: Date? = nil,
        consentValidUntil: Date? = nil,
        status: ExternalAccountStatus = .active,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        isIncludedInTotals: Bool = true
    ) {
        self.id = id
        self.stableIdentifier = stableIdentifier
        self.currentUID = currentUID
        self.linkID = linkID
        self.institution = institution.rawValue
        self.name = name
        self.maskedIBAN = maskedIBAN
        self.currencyCode = currencyCode
        self.balance = balance
        self.balanceType = balanceType
        self.balanceDate = balanceDate
        self.consentValidUntil = consentValidUntil
        self.status = status.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.isIncludedInTotals = isIncludedInTotals
    }
}

extension ExternalAccount {
    static let manualBalanceType = "MANUAL"

    convenience init(manualName name: String, balance: Decimal, currencyCode: String = "EUR") {
        let id = UUID()
        self.init(
            id: id,
            stableIdentifier: "manual:\(id.uuidString)",
            currentUID: "",
            linkID: "",
            institution: .manual,
            name: name,
            currencyCode: currencyCode,
            balance: balance.currencyRounded,
            balanceType: Self.manualBalanceType
        )
    }

    var normalizedInstitution: BankInstitution? {
        BankInstitution(rawValue: institution)
    }

    var isManual: Bool {
        normalizedInstitution == .manual
    }

    var normalizedStatus: ExternalAccountStatus {
        ExternalAccountStatus(rawValue: status) ?? .error
    }

    // Both are bank accounts of the same consent: a link carries every account the customer authorized at once,
    // so the link has to outlive whichever of them is removed first.
    func sharesLink(with other: ExternalAccount) -> Bool {
        id != other.id && !isManual && !other.isManual && linkID == other.linkID
    }

    static func maskedIBAN(from iban: String?) -> String? {
        guard let iban, iban.count > 8 else {
            return iban
        }
        let compact = iban.replacingOccurrences(of: " ", with: "")
        return "\(compact.prefix(4))…\(compact.suffix(4))"
    }
}


extension ExternalAccount {
    func shortDisplayName(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        if isManual { return name }
        let bank = normalizedInstitution?.displayName(locale: locale) ?? institution
        guard let maskedIBAN, !maskedIBAN.isEmpty else { return bank }
        return bank + " · " + String(maskedIBAN.suffix(4))
    }
}
