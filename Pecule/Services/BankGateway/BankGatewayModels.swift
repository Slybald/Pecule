import Foundation

struct BankGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String
}

enum BankGatewayConfigurationError: Error, Equatable {
    case missingToken
}

enum BankGatewayError: Error, Equatable {
    case notConfigured
    case unauthorized
    case sessionExpired
    case rateLimited(retryAfterSeconds: Int)
    case linkNotFound
    case upstream(status: Int, code: String)
    case http(status: Int, code: String?)
    case transport(String)
    case decoding(String)
}

enum BankLinkStatus: String, Codable, Sendable {
    case pending
    case authorized
    case expired
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = BankLinkStatus(rawValue: rawValue) ?? .unknown
    }
}

struct BankAspsp: Codable, Equatable, Sendable {
    let name: String
    let country: String
}

struct BankLinkStart: Codable, Equatable, Sendable {
    let linkId: String
    let authUrl: URL
    let validUntil: Date
}

struct BankLinkAccount: Codable, Equatable, Sendable {
    let uid: String
    let identificationHash: String?
    let iban: String?
    let name: String?
    let currency: String?
    let product: String?
    let cashAccountType: String?
    let usage: String?

    var stableIdentifier: String {
        identificationHash ?? iban ?? uid
    }
}

struct BankLink: Codable, Equatable, Sendable {
    let id: String
    let status: BankLinkStatus
    let aspsp: BankAspsp
    let validUntil: Date?
    let errorCode: String?
    let accounts: [BankLinkAccount]
}

struct BankBalance: Decodable, Equatable, Sendable {
    let name: String?
    let balanceType: String
    let amount: Decimal
    let currency: String
    let referenceDate: Date?
    let lastChangeDateTime: Date?

    private enum CodingKeys: String, CodingKey {
        case name
        case balanceType = "balance_type"
        case balanceAmount = "balance_amount"
        case referenceDate = "reference_date"
        case lastChangeDateTime = "last_change_date_time"
    }

    init(name: String?, balanceType: String, amount: Decimal, currency: String, referenceDate: Date? = nil, lastChangeDateTime: Date? = nil) {
        self.name = name
        self.balanceType = balanceType
        self.amount = amount
        self.currency = currency
        self.referenceDate = referenceDate
        self.lastChangeDateTime = lastChangeDateTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let money = try container.decode(BankMoney.self, forKey: .balanceAmount)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        balanceType = try container.decode(String.self, forKey: .balanceType)
        amount = money.amount
        currency = money.currency
        referenceDate = try container.decodeIfPresent(Date.self, forKey: .referenceDate)
        lastChangeDateTime = try container.decodeIfPresent(Date.self, forKey: .lastChangeDateTime)
    }
}

enum BankCreditDebitIndicator: String, Codable, Sendable {
    case credit = "CRDT"
    case debit = "DBIT"
}

struct BankTransactionDTO: Decodable, Equatable, Sendable {
    let entryReference: String?
    let transactionId: String?
    let amount: Decimal
    let currency: String
    let creditDebitIndicator: BankCreditDebitIndicator
    let status: String?
    let bookingDate: Date?
    let valueDate: Date?
    let transactionDate: Date?
    let creditorName: String?
    let debtorName: String?
    let creditorAccountIBAN: String?
    let debtorAccountIBAN: String?
    let remittanceInformation: [String]
    let merchantCategoryCode: String?
    let bankTransactionCode: String?

    private enum CodingKeys: String, CodingKey {
        case entryReference = "entry_reference"
        case transactionId = "transaction_id"
        case transactionAmount = "transaction_amount"
        case creditDebitIndicator = "credit_debit_indicator"
        case status
        case bookingDate = "booking_date"
        case valueDate = "value_date"
        case transactionDate = "transaction_date"
        case creditor
        case debtor
        case creditorAccount = "creditor_account"
        case debtorAccount = "debtor_account"
        case remittanceInformation = "remittance_information"
        case merchantCategoryCode = "merchant_category_code"
        case bankTransactionCode = "bank_transaction_code"
    }

    init(
        entryReference: String?,
        transactionId: String? = nil,
        amount: Decimal,
        currency: String,
        creditDebitIndicator: BankCreditDebitIndicator,
        status: String? = "BOOK",
        bookingDate: Date?,
        valueDate: Date? = nil,
        transactionDate: Date? = nil,
        creditorName: String? = nil,
        debtorName: String? = nil,
        creditorAccountIBAN: String? = nil,
        debtorAccountIBAN: String? = nil,
        remittanceInformation: [String] = [],
        merchantCategoryCode: String? = nil,
        bankTransactionCode: String? = nil
    ) {
        self.entryReference = entryReference
        self.transactionId = transactionId
        self.amount = amount
        self.currency = currency
        self.creditDebitIndicator = creditDebitIndicator
        self.status = status
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.transactionDate = transactionDate
        self.creditorName = creditorName
        self.debtorName = debtorName
        self.creditorAccountIBAN = creditorAccountIBAN
        self.debtorAccountIBAN = debtorAccountIBAN
        self.remittanceInformation = remittanceInformation
        self.merchantCategoryCode = merchantCategoryCode
        self.bankTransactionCode = bankTransactionCode
    }

    var counterpartyAccountIBAN: String? {
        creditDebitIndicator == .debit ? creditorAccountIBAN : debtorAccountIBAN
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let money = try container.decode(BankMoney.self, forKey: .transactionAmount)
        entryReference = try container.decodeIfPresent(String.self, forKey: .entryReference)
        transactionId = try container.decodeIfPresent(String.self, forKey: .transactionId)
        amount = money.amount
        currency = money.currency
        creditDebitIndicator = try container.decode(BankCreditDebitIndicator.self, forKey: .creditDebitIndicator)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        bookingDate = try container.decodeIfPresent(Date.self, forKey: .bookingDate)
        valueDate = try container.decodeIfPresent(Date.self, forKey: .valueDate)
        transactionDate = try container.decodeIfPresent(Date.self, forKey: .transactionDate)
        creditorName = try container.decodeIfPresent(BankParty.self, forKey: .creditor)?.name
        debtorName = try container.decodeIfPresent(BankParty.self, forKey: .debtor)?.name
        creditorAccountIBAN = try container.decodeIfPresent(BankAccountReference.self, forKey: .creditorAccount)?.iban
        debtorAccountIBAN = try container.decodeIfPresent(BankAccountReference.self, forKey: .debtorAccount)?.iban
        remittanceInformation = try container.decodeIfPresent([String].self, forKey: .remittanceInformation) ?? []
        merchantCategoryCode = try container.decodeIfPresent(String.self, forKey: .merchantCategoryCode)
        bankTransactionCode = try container.decodeIfPresent(BankTransactionCode.self, forKey: .bankTransactionCode)?.summary
    }
}

// Banks send either a plain string or the ISO 20022 object { description, code, sub_code }.
private struct BankTransactionCode: Decodable {
    let summary: String?

    private enum CodingKeys: String, CodingKey {
        case description
        case code
        case subCode = "sub_code"
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            summary = value.isEmpty ? nil : value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let parts = [
            try container.decodeIfPresent(String.self, forKey: .code),
            try container.decodeIfPresent(String.self, forKey: .subCode),
            try container.decodeIfPresent(String.self, forKey: .description),
        ].compactMap { $0 }.filter { !$0.isEmpty }
        summary = parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}

struct BankTransactionsPage: Decodable, Equatable, Sendable {
    let transactions: [BankTransactionDTO]
    let continuationKey: String?
    // Rows the bank sent that could not be read. They are dropped and counted, never fatal: one odd
    // line used to fail the whole page, and the saved resume point then replayed that page forever.
    let skippedCount: Int

    private enum CodingKeys: String, CodingKey {
        case transactions
        case continuationKey = "continuation_key"
    }

    init(transactions: [BankTransactionDTO], continuationKey: String?, skippedCount: Int = 0) {
        self.transactions = transactions
        self.continuationKey = continuationKey
        self.skippedCount = skippedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([LossyRow<BankTransactionDTO>].self, forKey: .transactions) ?? []
        transactions = rows.compactMap(\.value)
        skippedCount = rows.count - transactions.count
        continuationKey = try container.decodeIfPresent(String.self, forKey: .continuationKey)
    }
}

// Decodes one array element without ever throwing, so an unreadable row cannot take its siblings down.
private struct LossyRow<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct BankTransactionsQuery: Equatable, Sendable {
    var dateFrom: Date?
    var dateTo: Date?
    var continuationKey: String?
    var strategy: String?

    init(dateFrom: Date? = nil, dateTo: Date? = nil, continuationKey: String? = nil, strategy: String? = nil) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.continuationKey = continuationKey
        self.strategy = strategy
    }
}

private struct BankMoney: Decodable {
    let amount: Decimal
    let currency: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAmount = try container.decode(String.self, forKey: .amount)
        guard let amount = Decimal(string: rawAmount, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "Invalid amount \(rawAmount)")
        }
        self.amount = amount
        currency = try container.decode(String.self, forKey: .currency)
    }

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
    }
}

private struct BankParty: Decodable {
    let name: String?
}

private struct BankAccountReference: Decodable {
    let iban: String?
}

enum BankGatewayJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            guard let date = BankGatewayDateParser.parse(rawValue) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unrecognized date \(rawValue)")
                )
            }
            return date
        }
        return decoder
    }

    static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum BankGatewayDateParser {
    static func parse(_ rawValue: String) -> Date? {
        let normalized = rawValue.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: normalized) {
            return date
        }
        return parseDay(rawValue)
    }

    // Date-only values are pinned to noon UTC so they land in the same month under both app calendars.
    static func parseDay(_ rawValue: String) -> Date? {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

struct BankGatewayProbe: Equatable, Sendable {
    let environment: String
    let aspspCount: Int
}
