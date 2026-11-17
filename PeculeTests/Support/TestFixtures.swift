import Foundation
import XCTest
@testable import Pecule

// Shared helpers for new test files; older suites keep their private copies untouched.
enum TestFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_789_371_262) // 2026-09-14T07:34:22Z

    static func decimal(_ value: String, file: StaticString = #filePath, line: UInt = #line) -> Decimal {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            XCTFail("Unable to parse decimal literal: \(value)", file: file, line: line)
            return .zero
        }
        return decimal
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? referenceDate
    }

    static func day(offset: Int, from reference: Date = referenceDate) -> Date {
        BankGatewayDateParser.parseDay(BankGatewayJSON.dayString(from: reference.addingTimeInterval(TimeInterval(offset) * 86_400))) ?? reference
    }

    @MainActor
    static func makeDataStore() throws -> PeculeDataStore {
        PeculeDataStore(container: try PeculeDataStore.makeInMemoryContainer())
    }

    @MainActor
    static func makeAppState(seeded: Bool = true, gateway: any BankGatewayClient = StubBankGatewayClient()) throws -> AppState {
        AppState(dataStore: try makeDataStore(), shouldSeedOnReload: seeded, bankGateway: gateway)
    }

    @MainActor
    static func linkedAccount(
        stableIdentifier: String = "hash-1",
        name: String = "Compte courant",
        institution: BankInstitution = .mock,
        balance: Decimal? = nil,
        maskedIBAN: String? = nil
    ) -> ExternalAccount {
        ExternalAccount(
            stableIdentifier: stableIdentifier,
            currentUID: "uid-\(stableIdentifier)",
            linkID: "link-\(stableIdentifier)",
            institution: institution,
            name: name,
            maskedIBAN: maskedIBAN,
            currencyCode: "EUR",
            balance: balance,
            balanceType: balance == nil ? nil : "XPCD"
        )
    }

    @MainActor
    static func transaction(
        account: ExternalAccount,
        reference: String,
        amount: Decimal,
        direction: BankTransactionDirection,
        dayOffset: Int,
        label: String? = nil,
        category: ExpenseCategory = .other,
        bankTransactionCode: String? = nil,
        automaticCategory: String? = nil
    ) -> BankTransaction {
        let transaction = BankTransaction(
            externalID: "\(account.stableIdentifier)#\(reference)",
            accountID: account.id,
            amount: amount,
            direction: direction,
            currencyCode: account.currencyCode,
            bookingDate: day(offset: dayOffset),
            label: label ?? reference,
            bankTransactionCode: bankTransactionCode,
            category: category.storageValue
        )
        transaction.automaticCategory = automaticCategory
        return transaction
    }
}
