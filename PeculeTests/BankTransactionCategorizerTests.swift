import XCTest
@testable import Pecule

final class BankTransactionCategorizerTests: XCTestCase {
    private let categorizer = BankTransactionCategorizer()

    private func category(_ label: String, counterparty: String? = nil, mcc: String? = nil, code: String? = nil) -> ExpenseCategory {
        categorizer.category(label: label, counterparty: counterparty, merchantCategoryCode: mcc, bankTransactionCode: code)
    }

    func testMerchantCategoryCodeWinsOverKeywords() {
        XCTAssertEqual(category("SOMETHING", mcc: "5411"), .groceries)
        XCTAssertEqual(category("CARREFOUR", mcc: "5541"), .fuel)
        XCTAssertEqual(category("UNKNOWN", mcc: "0000"), .other)
    }

    func testRealBoursoramaAndRevolutLabels() {
        XCTAssertEqual(category("TOTAL\\VILLEBOURG D\\ FR", counterparty: "TOTAL\\VILLEBOURG D\\"), .fuel)
        XCTAssertEqual(category("AMAZON PAYMENTS\\PARIS\\ FR"), .shopping)
        XCTAssertEqual(category("DISTRI CAFE DUPONT\\VILLEBOURG\\ FR"), .leisure)
        XCTAssertEqual(category("VIR Corner - Uber Eats"), .leisure)
        XCTAssertEqual(category("CB CARREFOUR"), .groceries)
        XCTAssertEqual(category("SAS  EXEMPLE\\VILLEBOURG\\ FR"), .other)
        XCTAssertEqual(category("VIR INST DUPONT"), .other)
        XCTAssertEqual(category("SALAIRE"), .other)
    }

    func testKeywordRulesAndPrecedence() {
        XCTAssertEqual(category("PRLV TOTALENERGIES ELECTRICITE"), .housing)
        XCTAssertEqual(category("TOTAL ANGOULEME"), .fuel)
        XCTAssertEqual(category("UBER EATS PARIS"), .leisure)
        XCTAssertEqual(category("UBER *TRIP"), .transport)
        XCTAssertEqual(category("Netflix.com"), .subscriptions)
        XCTAssertEqual(category("CURSOR AI"), .subscriptions)
        XCTAssertEqual(category("PHARMACIE DU CENTRE"), .health)
        XCTAssertEqual(category("MAIF ASSURANCE AUTO"), .insurance)
        XCTAssertEqual(category("SNCF VOYAGEURS"), .transport)
        XCTAssertEqual(category("E.LECLERC POITIERS"), .groceries)
        XCTAssertEqual(category("Décathlon Niort"), .shopping)
        XCTAssertEqual(category("UNIVERSITE DE POITIERS"), .education)
        XCTAssertEqual(category("BP PARIS"), .fuel)
        XCTAssertEqual(category("BPCE VIREMENT"), .other, "BP must match a whole word")
    }

    func testNormalizationStripsDiacriticsAndSeparators() {
        XCTAssertEqual(BankTransactionCategorizer.normalize("Décathlon\\Niort\\  FR"), "DECATHLON NIORT FR")
        XCTAssertEqual(BankTransactionCategorizer.normalize("  e.leclerc  "), "E LECLERC")
    }
}
