import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class ProfileIsolationTests: XCTestCase {
    func testProfilesAndIssuersUseDifferentStoresAndPreserveTheirOwnData() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let issuer = URL(string: "https://gateway.test")!
        let alice = ProfileStoreLocation(issuer: issuer, userID: "alice/../../legacy")
        let bob = ProfileStoreLocation(issuer: issuer, userID: "bob")
        let otherIssuer = ProfileStoreLocation(issuer: URL(string: "https://other.test")!, userID: "alice/../../legacy")
        XCTAssertNotEqual(alice.key, bob.key)
        XCTAssertNotEqual(alice.key, otherIssuer.key)
        XCTAssertFalse(alice.key.contains("/"))
        XCTAssertNotEqual(alice.preferenceKey, bob.preferenceKey)
        try autoreleasepool {
            let store = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: alice, root: root))
            try store.addPurchase(title: "Private A", amount: 42, date: TestFixtures.referenceDate, category: "Shopping", merchant: "Fixture", notes: "A note")
        }
        let bobStore = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: bob, root: root))
        XCTAssertTrue(try bobStore.loadSnapshot().purchases.isEmpty)
        let aliceStore = PeculeDataStore(container: try PeculeDataStore.makeProfileContainer(location: alice, root: root))
        XCTAssertEqual(try aliceStore.loadSnapshot().purchases.first?.title, "Private A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "LifeOS.store").path))
    }

    func testInvalidatedAppStateCannotReloadAnOldProfile() throws {
        let state = try TestFixtures.makeAppState()
        XCTAssertFalse(state.purchases.isEmpty)
        state.invalidateProfile()
        state.reload()
        XCTAssertFalse(state.isProfileActive)
        XCTAssertTrue(state.purchases.isEmpty)
        XCTAssertTrue(state.externalAccounts.isEmpty)
    }

    func testIntentsCannotFallBackToLegacyStoreInIdentityMode() {
        let saved = AppIntentSupport.dataStore
        let savedPolicy = AppIntentSupport.requiresActiveProfile
        defer { AppIntentSupport.dataStore = saved; AppIntentSupport.requiresActiveProfile = savedPolicy }
        AppIntentSupport.dataStore = nil
        AppIntentSupport.requiresActiveProfile = true
        XCTAssertThrowsError(try AppIntentSupport.store())
    }

    func testInvalidatedProfileCannotReadCachedOrUncachedHistoricalAccountData() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        let cached = TestFixtures.transaction(account: account, reference: "cached", amount: 40, direction: .debit, dayOffset: -900)
        let uncached = TestFixtures.transaction(account: account, reference: "uncached", amount: 50, direction: .debit, dayOffset: -960)
        try state.dataStore.importBankTransactions([cached, uncached])
        state.reload()
        XCTAssertEqual(state.bankTransactions(in: cached.bookingDate, accountID: account.id).count, 1)
        XCTAssertFalse(state.historicalMonthCache.isEmpty)

        state.invalidateProfile()

        XCTAssertTrue(state.historicalMonthCache.isEmpty)
        XCTAssertTrue(state.bankTransactions(in: cached.bookingDate, accountID: account.id).isEmpty)
        XCTAssertTrue(state.bankTransactions(in: uncached.bookingDate, accountID: account.id).isEmpty)
        XCTAssertNil(state.bankTransaction(id: cached.id))
        XCTAssertTrue(state.historicalMonthCache.isEmpty)
    }
}
