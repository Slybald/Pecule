import Foundation
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class PersistentMigrationTests: XCTestCase {
    func testV2PersistentStorePreservesBalancesTransactionsAndLinksAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store")
        let accountID = UUID(), subscriptionID = UUID(), transactionID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PeculeSchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let account = PeculeSchemaV2.ExternalAccount(id: accountID, stableIdentifier: "fixture-account", currentUID: "uid", linkID: "link", institution: .mock, name: "Fixture", currencyCode: "EUR", balance: 1234)
            let subscription = PeculeSchemaV1.Subscription(id: subscriptionID, name: "Fixture", amount: 20, billingCycle: .monthly, category: "Subscriptions", nextBillingDate: TestFixtures.referenceDate, isActive: true)
            let transaction = PeculeSchemaV2.BankTransaction(id: transactionID, externalID: "fixture#1", accountID: accountID, amount: 20, direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.referenceDate, label: "Fixture", category: "Insurance", linkedSubscriptionID: subscriptionID)
            container.mainContext.insert(account)
            container.mainContext.insert(subscription)
            container.mainContext.insert(transaction)
            try container.mainContext.save()
        }
        for pass in 0..<2 {
            try autoreleasepool {
                let schema = PeculeSchema.current
                let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
                let account = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ExternalAccount>()).first)
                let transaction = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<BankTransaction>()).first)
                XCTAssertEqual(account.id, accountID)
                XCTAssertEqual(account.balance, 1234)
                XCTAssertEqual(transaction.id, transactionID)
                XCTAssertEqual(transaction.linkedSubscriptionID, subscriptionID)
                XCTAssertEqual(transaction.category, "Insurance")
                XCTAssertEqual(transaction.natureOverride, "automatic")
                if pass == 0 {
                    XCTAssertNil(transaction.userNote)
                    XCTAssertNil(transaction.automaticCategory)
                    XCTAssertNil(transaction.categoryOverride)
                    XCTAssertFalse(transaction.isAbsentFromBank)
                    transaction.userNote = "Note after migration"
                    transaction.categoryOverride = transaction.category
                    try container.mainContext.save()
                } else {
                    XCTAssertEqual(transaction.userNote, "Note after migration")
                    XCTAssertEqual(transaction.categoryOverride, "Insurance")
                }
                XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Subscription>()).count, 1)
                XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<BankImportCheckpoint>()).isEmpty)
            }
        }
    }

    func testV1PersistentStoreMigratesDirectlyToCurrentWithoutLosingManualHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store")
        let id = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PeculeSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            container.mainContext.insert(PeculeSchemaV1.Purchase(id: id, title: "Personal", amount: 74.86, date: TestFixtures.referenceDate, category: "Insurance", merchant: "Fixture", notes: "Keep this annotation"))
            try container.mainContext.save()
        }
        let schema = PeculeSchema.current
        let container = try ModelContainer(for: schema, migrationPlan: PeculeMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url)])
        let purchase = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Purchase>()).first)
        XCTAssertEqual(purchase.id, id)
        XCTAssertEqual(purchase.amount, 74.86)
        XCTAssertEqual(purchase.notes, "Keep this annotation")
    }
}
