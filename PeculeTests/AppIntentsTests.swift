import XCTest
@testable import Pecule

@MainActor
final class AppIntentsTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { AppIntentSupport.dataStore = nil }
        try await super.tearDown()
    }

    func testLogPurchaseIntentWritesThroughTheRegisteredStoreAndNotifies() async throws {
        let store = try TestFixtures.makeDataStore()
        AppIntentSupport.dataStore = store
        let changed = expectation(forNotification: .peculeDataDidChangeExternally, object: nil)
        let intent = LogPurchaseIntent()
        intent.amount = 12.5
        intent.label = "  Café  "
        intent.category = .leisure

        _ = try await intent.perform()

        await fulfillment(of: [changed], timeout: 1)
        let purchases = try store.loadSnapshot().purchases
        XCTAssertEqual(purchases.map(\.title), ["Café"])
        XCTAssertEqual(purchases.first?.amount, TestFixtures.decimal("12.5"))
        XCTAssertEqual(purchases.first?.category, ExpenseCategory.leisure.storageValue)
    }

    func testLogPurchaseIntentRejectsBadInput() async throws {
        AppIntentSupport.dataStore = try TestFixtures.makeDataStore()
        let intent = LogPurchaseIntent()
        intent.amount = 0
        intent.label = "Café"
        do {
            _ = try await intent.perform()
            XCTFail("expected invalidAmount")
        } catch let error as PeculeIntentError {
            XCTAssertEqual(error, .invalidAmount)
        }
        intent.amount = 5
        intent.label = "   "
        do {
            _ = try await intent.perform()
            XCTFail("expected emptyLabel")
        } catch let error as PeculeIntentError {
            XCTAssertEqual(error, .emptyLabel)
        }
    }

    func testTotalBalanceIntentSumsIncludedEuroAccounts() async throws {
        let store = try TestFixtures.makeDataStore()
        AppIntentSupport.dataStore = store
        let accounts = try store.saveExternalAccounts([
            TestFixtures.linkedAccount(stableIdentifier: "a", name: "Courant", balance: 100),
            TestFixtures.linkedAccount(stableIdentifier: "b", name: "Carte", balance: 999),
        ])
        try store.updateExternalAccountInclusion(try XCTUnwrap(accounts.first { $0.stableIdentifier == "b" }), isIncludedInTotals: false)
        try store.addManualAccount(name: "Livret", balance: 50)

        let result = try await TotalBalanceIntent().perform()

        XCTAssertEqual(result.value, 150, "included linked account plus the manual one; the excluded card stays out")
    }

    func testTotalBalanceIntentWithoutAccountsReturnsZero() async throws {
        AppIntentSupport.dataStore = try TestFixtures.makeDataStore()

        let result = try await TotalBalanceIntent().perform()

        XCTAssertEqual(result.value, 0)
    }
}
