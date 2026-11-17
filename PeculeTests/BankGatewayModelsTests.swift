import XCTest
@testable import Pecule

final class BankGatewayModelsTests: XCTestCase {
    // Captured from the sandbox gateway on 2026-09-14 (Mock ASPSP).
    private let balancesJSON = """
    {"balances":[{"name":"Closing accounting balance","balance_amount":{"currency":"EUR","amount":"53.51"},"balance_type":"CLBD","last_change_date_time":null,"reference_date":null,"last_committed_transaction":null}]}
    """

    private let transactionsJSON = """
    {"transactions":[{"entry_reference":"dkx1z","merchant_category_code":null,"transaction_amount":{"currency":"EUR","amount":"8.19"},"creditor":{"name":"Onni Mäkinen","postal_address":null,"organisation_id":null,"private_id":null,"contact_details":null},"creditor_account":null,"creditor_agent":null,"debtor":null,"debtor_account":null,"debtor_agent":null,"bank_transaction_code":null,"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-13","value_date":"2026-09-12","transaction_date":null,"balance_after_transaction":null,"reference_number":null,"reference_number_schema":null,"remittance_information":["Onni Mäkinen-DBIT-8.19-dkx1z"],"debtor_account_additional_identification":null,"creditor_account_additional_identification":null,"exchange_rate":null,"note":null,"transaction_id":null},{"entry_reference":"eo28j","merchant_category_code":null,"transaction_amount":{"currency":"EUR","amount":"4.49"},"creditor":{"name":"Onni Hämäläinen","postal_address":null,"organisation_id":null,"private_id":null,"contact_details":null},"creditor_account":null,"creditor_agent":null,"debtor":null,"debtor_account":null,"debtor_agent":null,"bank_transaction_code":null,"credit_debit_indicator":"CRDT","status":"BOOK","booking_date":"2026-09-13","value_date":"2026-09-10","transaction_date":null,"balance_after_transaction":null,"reference_number":null,"reference_number_schema":null,"remittance_information":["Onni Hämäläinen-CRDT-4.49-eo28j"],"debtor_account_additional_identification":null,"creditor_account_additional_identification":null,"exchange_rate":null,"note":null,"transaction_id":null}],"continuation_key":null}
    """

    private let linkJSON = """
    {"id":"a697a401-590f-4fd8-aa96-e46fd01b74a7","status":"authorized","aspsp":{"name":"Mock ASPSP","country":"FR"},"psuType":"personal","createdAt":"2026-09-14T07:39:07.434Z","validUntil":"2027-03-13T07:39:07.434000Z","errorCode":null,"accounts":[{"uid":"63a6f008-0852-4daa-98ce-b19430e1c1c4","identificationHash":"WwpbCiJhc3BzcF9uYW1lIgpdLApbCiJhc3BzcF9jb3VudHJ5IgpdLApbCiJhY2NvdW50IiwKInJlc291cmNlX2lkIgpdCl0=.c6uX+nDhZkqd+4dyaqyZOmFAjSejMLaJO5S2EVFyDSQ=","iban":null,"name":"Titulaire démo","currency":"EUR","product":null,"cashAccountType":"CARD","usage":"PRIV"}]}
    """

    private func utcNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testDecodesBalancesFromGatewayPayload() throws {
        struct Envelope: Decodable { let balances: [BankBalance] }
        let envelope = try BankGatewayJSON.makeDecoder().decode(Envelope.self, from: Data(balancesJSON.utf8))

        XCTAssertEqual(envelope.balances.count, 1)
        let balance = try XCTUnwrap(envelope.balances.first)
        XCTAssertEqual(balance.balanceType, "CLBD")
        XCTAssertEqual(balance.amount, Decimal(string: "53.51"))
        XCTAssertEqual(balance.currency, "EUR")
        XCTAssertNil(balance.referenceDate)
    }

    func testDecodesTransactionsWithPositiveAmountsAndIndicators() throws {
        let page = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(transactionsJSON.utf8))

        XCTAssertNil(page.continuationKey)
        XCTAssertEqual(page.transactions.count, 2)
        let debit = page.transactions[0]
        XCTAssertEqual(debit.entryReference, "dkx1z")
        XCTAssertEqual(debit.amount, Decimal(string: "8.19"))
        XCTAssertEqual(debit.creditDebitIndicator, .debit)
        XCTAssertEqual(debit.status, "BOOK")
        XCTAssertEqual(debit.bookingDate, utcNoon(2026, 9, 13))
        XCTAssertEqual(debit.valueDate, utcNoon(2026, 9, 12))
        XCTAssertNil(debit.transactionDate)
        XCTAssertEqual(debit.creditorName, "Onni Mäkinen")
        XCTAssertNil(debit.debtorName)
        XCTAssertEqual(debit.remittanceInformation, ["Onni Mäkinen-DBIT-8.19-dkx1z"])
        XCTAssertEqual(page.transactions[1].creditDebitIndicator, .credit)
    }

    func testDecodesLinkWithFractionalSecondsAndStableIdentifier() throws {
        let link = try BankGatewayJSON.makeDecoder().decode(BankLink.self, from: Data(linkJSON.utf8))

        XCTAssertEqual(link.status, .authorized)
        XCTAssertEqual(link.aspsp, BankAspsp(name: "Mock ASPSP", country: "FR"))
        XCTAssertEqual(link.validUntil, BankGatewayDateParser.parse("2027-03-13T07:39:07.434Z"))
        let account = try XCTUnwrap(link.accounts.first)
        XCTAssertEqual(account.uid, "63a6f008-0852-4daa-98ce-b19430e1c1c4")
        XCTAssertEqual(account.stableIdentifier, account.identificationHash)
        XCTAssertEqual(account.cashAccountType, "CARD")
    }

    func testDecodesBankTransactionCodeAsStringOrObject() throws {
        let json = """
        {"transactions":[
          {"entry_reference":"a","transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-13","bank_transaction_code":{"description":"Card payment","code":"PMNT","sub_code":"CCRD"}},
          {"entry_reference":"b","transaction_amount":{"currency":"EUR","amount":"2.00"},"credit_debit_indicator":"CRDT","status":"BOOK","booking_date":"2026-09-13","bank_transaction_code":"TRANSFER"},
          {"entry_reference":"c","transaction_amount":{"currency":"EUR","amount":"3.00"},"credit_debit_indicator":"CRDT","status":"BOOK","booking_date":"2026-09-13","bank_transaction_code":null},
          {"entry_reference":"d","transaction_amount":{"currency":"EUR","amount":"4.00"},"credit_debit_indicator":"CRDT","status":"BOOK","booking_date":"2026-09-13","bank_transaction_code":{"description":null,"code":null,"sub_code":null}}
        ],"continuation_key":null}
        """
        let page = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(json.utf8))

        XCTAssertEqual(page.transactions.map(\.bankTransactionCode), ["PMNT / CCRD / Card payment", "TRANSFER", nil, nil])
    }

    func testUnknownLinkStatusDoesNotFailDecoding() throws {
        let json = #"{"id":"x","status":"weird","aspsp":{"name":"a","country":"FR"},"validUntil":null,"errorCode":null,"accounts":[]}"#
        let link = try BankGatewayJSON.makeDecoder().decode(BankLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.status, .unknown)
    }

    func testDateParserHandlesIsoAndDayOnlyValues() {
        XCTAssertEqual(BankGatewayDateParser.parse("2026-09-13"), utcNoon(2026, 9, 13))
        XCTAssertEqual(BankGatewayDateParser.parse("2026-09-14T07:34:22Z"), Date(timeIntervalSince1970: 1_789_371_262))
        XCTAssertEqual(BankGatewayDateParser.parse("2026-09-14T07:34:22.428Z"), BankGatewayDateParser.parse("2026-09-14T07:34:22.428000Z"))
        XCTAssertNil(BankGatewayDateParser.parse("not a date"))
        XCTAssertEqual(BankGatewayJSON.dayString(from: utcNoon(2026, 1, 5)), "2026-01-05")
    }

    func testMapsErrorEnvelopesToGatewayErrors() {
        XCTAssertEqual(LiveBankGatewayClient.error(status: 401, body: Data()), .unauthorized)
        XCTAssertEqual(LiveBankGatewayClient.error(status: 409, body: Data(#"{"error":"session_expired"}"#.utf8)), .sessionExpired)
        XCTAssertEqual(LiveBankGatewayClient.error(status: 429, body: Data(#"{"error":"rate_limited","retryAfterSeconds":21600}"#.utf8)), .rateLimited(retryAfterSeconds: 21600))
        XCTAssertEqual(LiveBankGatewayClient.error(status: 404, body: Data(#"{"error":"link_not_found"}"#.utf8)), .linkNotFound)
        XCTAssertEqual(
            LiveBankGatewayClient.error(status: 502, body: Data(#"{"error":"upstream_error","upstreamStatus":403,"upstreamCode":"403"}"#.utf8)),
            .upstream(status: 403, code: "403")
        )
        XCTAssertEqual(LiveBankGatewayClient.error(status: 500, body: Data("<html>".utf8)), .http(status: 500, code: nil))
    }

    func testMapsTransactionDTOToModelWithPositiveAmountAndDirection() throws {
        let page = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(transactionsJSON.utf8))
        let accountID = UUID()

        let debit = try XCTUnwrap(BankTransaction(dto: page.transactions[0], accountID: accountID, accountStableIdentifier: "hash-1"))
        XCTAssertEqual(debit.externalID, "hash-1#dkx1z")
        XCTAssertEqual(debit.accountID, accountID)
        XCTAssertEqual(debit.amount, Decimal(string: "8.19"))
        XCTAssertEqual(debit.normalizedDirection, .debit)
        XCTAssertTrue(debit.isExpense)
        XCTAssertFalse(debit.isIncome)
        XCTAssertEqual(debit.label, "Onni Mäkinen-DBIT-8.19-dkx1z")
        XCTAssertEqual(debit.counterpartyName, "Onni Mäkinen")
        XCTAssertEqual(debit.normalizedStatus, .booked)
        XCTAssertEqual(debit.category, ExpenseCategory.other.storageValue)
        XCTAssertEqual(debit.bookingDate, utcNoon(2026, 9, 13))

        let credit = try XCTUnwrap(BankTransaction(dto: page.transactions[1], accountID: accountID, accountStableIdentifier: "hash-1"))
        XCTAssertEqual(credit.normalizedDirection, .credit)
        XCTAssertTrue(credit.isIncome)
        XCTAssertEqual(credit.counterpartyName, nil, "credits use the debtor as counterparty; the sample has none")
    }

    func testFallbackExternalIDIsDeterministicWhenReferenceMissing() throws {
        let dto = BankTransactionDTO(
            entryReference: nil,
            amount: Decimal(string: "12.34")!,
            currency: "EUR",
            creditDebitIndicator: .debit,
            status: "PDNG",
            bookingDate: utcNoon(2026, 9, 10),
            creditorName: "Shop",
            remittanceInformation: ["CB SHOP"]
        )
        let first = try XCTUnwrap(BankTransaction(dto: dto, accountID: UUID(), accountStableIdentifier: "hash-1"))
        let second = try XCTUnwrap(BankTransaction(dto: dto, accountID: UUID(), accountStableIdentifier: "hash-1"))

        XCTAssertEqual(first.externalID, second.externalID)
        XCTAssertTrue(first.externalID.hasPrefix("hash-1#sha256:"))
        XCTAssertEqual(first.normalizedStatus, .pending)
        XCTAssertNotEqual(first.externalID, BankTransaction(dto: dto, accountID: UUID(), accountStableIdentifier: "hash-2")?.externalID)
    }

    func testSignedAmountsAreStoredAsAbsoluteValues() throws {
        let json = #"{"transactions":[{"entry_reference":"x","transaction_amount":{"currency":"EUR","amount":"-18.15"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-14","creditor":{"name":"TOTAL"}}],"continuation_key":null}"#
        let page = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(json.utf8))
        let transaction = try XCTUnwrap(BankTransaction(dto: page.transactions[0], accountID: UUID(), accountStableIdentifier: "card"))

        XCTAssertEqual(transaction.amount, Decimal(string: "18.15"))
        XCTAssertEqual(transaction.normalizedDirection, .debit)
        XCTAssertTrue(transaction.isExpense)
    }

    func testTransactionWithoutAnyDateIsRejected() {
        let dto = BankTransactionDTO(entryReference: "x", amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: nil)
        XCTAssertNil(BankTransaction(dto: dto, accountID: UUID(), accountStableIdentifier: "hash-1"))
    }

    func testMaskedIBANKeepsOnlyEdges() {
        XCTAssertEqual(ExternalAccount.maskedIBAN(from: "FR76 3000 6000 0112 3456 7890 189"), "FR76…0189")
        XCTAssertEqual(ExternalAccount.maskedIBAN(from: "SHORT"), "SHORT")
        XCTAssertNil(ExternalAccount.maskedIBAN(from: nil))
    }
}

// M020 : une ligne illisible est écartée et comptée, elle ne fait plus échouer la page entière.
extension BankGatewayModelsTests {
    private func decodePage(_ rows: [String], continuationKey: String = "null") throws -> BankTransactionsPage {
        let json = #"{"transactions":[\#(rows.joined(separator: ","))],"continuation_key":\#(continuationKey)}"#
        return try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(json.utf8))
    }

    private func row(_ reference: String, amount: String = "1.00", date: String = "2026-09-13") -> String {
        #"{"entry_reference":"\#(reference)","transaction_amount":{"currency":"EUR","amount":"\#(amount)"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"\#(date)","creditor":{"name":"SHOP"}}"#
    }

    func testOneInvalidRowAmongValidOnesIsSkippedAndCounted() throws {
        let page = try decodePage([row("a"), row("bad", date: ""), row("c")], continuationKey: #""next""#)

        XCTAssertEqual(page.transactions.compactMap(\.entryReference), ["a", "c"], "the valid rows keep their order")
        XCTAssertEqual(page.skippedCount, 1)
        XCTAssertEqual(page.continuationKey, "next", "the cursor to the following page is not lost with the bad row")
    }

    func testEveryKindOfUnreadableRowIsSkippedWithoutFailingThePage() throws {
        let unreadable = [
            #"{"entry_reference":"no-amount","credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-13"}"#,
            #"{"entry_reference":"amount-not-text","transaction_amount":{"currency":"EUR","amount":12.5},"credit_debit_indicator":"DBIT","booking_date":"2026-09-13"}"#,
            #"{"entry_reference":"no-indicator","transaction_amount":{"currency":"EUR","amount":"1.00"},"booking_date":"2026-09-13"}"#,
            #"{"entry_reference":"null-indicator","transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":null,"booking_date":"2026-09-13"}"#,
            #"{"entry_reference":"unknown-indicator","transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":"HOLD","booking_date":"2026-09-13"}"#,
            #"{"entry_reference":"datetime-without-zone","transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":"DBIT","booking_date":"2026-09-13T00:00:00"}"#,
            #"{"entry_reference":"null-remittance-line","transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":"DBIT","booking_date":"2026-09-13","remittance_information":["ok",null]}"#,
            #"{"entry_reference":"garbled-amount","transaction_amount":{"currency":"EUR","amount":"twelve"},"credit_debit_indicator":"DBIT","booking_date":"2026-09-13"}"#,
            "null",
            #""just a string""#,
            "42",
        ]
        let page = try decodePage([row("first")] + unreadable + [row("last")])

        XCTAssertEqual(page.transactions.compactMap(\.entryReference), ["first", "last"])
        XCTAssertEqual(page.skippedCount, unreadable.count)
    }

    func testAFullyValidPageIsUnchangedByTolerantDecoding() throws {
        let page = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(transactionsJSONForTolerance.utf8))

        XCTAssertEqual(page.skippedCount, 0)
        XCTAssertEqual(page.transactions.count, 2)
        XCTAssertEqual(page.transactions.map(\.entryReference), ["dkx1z", "eo28j"])
        XCTAssertEqual(page.transactions[0].amount, Decimal(string: "8.19"))
        XCTAssertEqual(page.transactions[1].creditDebitIndicator, .credit)
        XCTAssertNil(page.continuationKey)
    }

    func testEmptyAndMissingTransactionListsDecodeAsEmptyPages() throws {
        let empty = try decodePage([])
        XCTAssertEqual(empty.transactions, [])
        XCTAssertEqual(empty.skippedCount, 0)
        let missing = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(#"{"continuation_key":"k"}"#.utf8))
        XCTAssertEqual(missing.transactions, [])
        XCTAssertEqual(missing.skippedCount, 0)
        XCTAssertEqual(missing.continuationKey, "k")
    }

    func testAnObjectWhereTheListShouldBeIsStillAStructuralFailure() {
        let json = #"{"transactions":{"entry_reference":"x"},"continuation_key":null}"#
        XCTAssertThrowsError(try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(json.utf8)))
    }

    func testPagesBuiltInCodeHaveNoSkippedRowsByDefault() {
        XCTAssertEqual(BankTransactionsPage(transactions: [], continuationKey: nil).skippedCount, 0)
        XCTAssertEqual(BankTransactionsPage(transactions: [], continuationKey: nil), BankTransactionsPage(transactions: [], continuationKey: nil, skippedCount: 0))
    }

    private var transactionsJSONForTolerance: String {
        #"{"transactions":[{"entry_reference":"dkx1z","transaction_amount":{"currency":"EUR","amount":"8.19"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-13","value_date":"2026-09-12","creditor":{"name":"Onni Mäkinen"},"remittance_information":["Onni Mäkinen-DBIT-8.19-dkx1z"]},{"entry_reference":"eo28j","transaction_amount":{"currency":"EUR","amount":"4.49"},"credit_debit_indicator":"CRDT","status":"BOOK","booking_date":"2026-09-13","value_date":"2026-09-10","creditor":{"name":"Onni Hämäläinen"}}],"continuation_key":null}"#
    }
}
