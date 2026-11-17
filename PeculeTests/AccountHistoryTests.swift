import CryptoKit
import SwiftData
import XCTest
@testable import Pecule

@MainActor
final class AccountHistoryTests: XCTestCase {
    func testKeysetPaginationWithEqualDatesAndNewerInsertion() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount()
        let other = TestFixtures.linkedAccount(stableIdentifier: "other")
        let rows = (0..<257).map { TestFixtures.transaction(account: account, reference: String(format: "%05d", $0), amount: 1, direction: .debit, dayOffset: -($0 / 50)) }
        try store.importBankTransactions(rows + [TestFixtures.transaction(account: other, reference: "excluded", amount: 2, direction: .debit, dayOffset: 0)])
        let first = try store.accountHistory(accountID: account.id, limit: 30)
        XCTAssertEqual(first.transactions.count, 30)
        try store.importBankTransactions([TestFixtures.transaction(account: account, reference: "new", amount: 1, direction: .debit, dayOffset: 1)])
        var ids = first.transactions.map(\.id), cursor = first.next
        while let next = cursor {
            let page = try store.accountHistory(accountID: account.id, after: next, limit: 30)
            XCTAssertTrue(page.transactions.allSatisfy { $0.accountID == account.id })
            ids += page.transactions.map(\.id); cursor = page.next
        }
        XCTAssertEqual(ids.count, 257)
        XCTAssertEqual(Set(ids), Set(rows.map(\.id)))
    }

    func testSyntheticTenAndFiftyThousandOperations() throws {
        for count in [10_000, 50_000] {
            let store = try TestFixtures.makeDataStore()
            let account = TestFixtures.linkedAccount()
            let start = Date()
            for i in 0..<count {
                store.container.mainContext.insert(TestFixtures.transaction(account: account, reference: String(format: "%06d", i), amount: 1, direction: .debit, dayOffset: -(i / 100)))
            }
            try store.container.mainContext.save()
            let queryStart = Date()
            let page = try store.accountHistory(accountID: account.id)
            XCTAssertEqual(page.transactions.count, 100)
            let second = try store.accountHistory(accountID: account.id, after: page.next)
            XCTAssertEqual(second.transactions.count, 100)
            XCTAssertTrue(Set(page.transactions.map(\.id)).isDisjoint(with: second.transactions.map(\.id)))
            let twoPagesSeconds = Date().timeIntervalSince(queryStart)
            // Mesuré 0,012 s à 10 000 et 0,023 s à 50 000 avec la pagination par curseur. Le seuil est
            // volontairement large : il ne mesure pas la machine, il tombe si quelqu'un remplace le
            // curseur par un tri complet en mémoire, ce qui coûte des secondes à cette échelle.
            XCTAssertLessThan(twoPagesSeconds, 1.0, "deux pages de 100 lignes doivent rester instantanées à \(count) opérations")
            let searchStart = Date()
            let records = OperationSearchService().records(transactions: try store.transactions(in: nil), purchases: [], accounts: [account])
            var filter = OperationFilter(); filter.accountID = account.id; filter.minimumAmount = 1
            let matches = OperationSearchService().search(records, filter: filter)
            XCTAssertEqual(matches.records.count, count)
            print("GLOBAL_SEARCH count=\(count) projectionAndFilterSeconds=\(Date().timeIntervalSince(searchStart))")
            print("SYNTHETIC count=\(count) insertionSeconds=\(queryStart.timeIntervalSince(start)) twoPagesSeconds=\(twoPagesSeconds) returned=200")
        }
    }
}

extension AccountHistoryTests {
    func testAccountNavigationDoesNotPreloadOldHistoryButOldMonthAndDetailRemainAvailable() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let account = TestFixtures.linkedAccount()
        try state.dataStore.saveExternalAccounts([account])
        let old = TestFixtures.transaction(account: account, reference: "old", amount: 40, direction: .debit, dayOffset: -900)
        try state.dataStore.importBankTransactions([old])
        state.reload()
        XCTAssertFalse(state.bankTransactions.contains { $0.id == old.id })
        XCTAssertEqual(try state.dataStore.accountHistory(accountID: account.id).transactions.first?.id, old.id)
        XCTAssertEqual(state.bankTransaction(id: old.id)?.amount, 40)
        XCTAssertEqual(state.bankTransactions(in: old.bookingDate).first?.id, old.id)
        XCTAssertEqual(state.monthlyFinancialSummary(for: old.bookingDate).totalExpenses, 40)
    }
}

// M021 : le curseur ne compare plus d'identifiants, il nomme un jour et les lignes déjà rendues ce jour-là.
extension AccountHistoryTests {
    private func digestReference(_ index: Int) -> String {
        "sha256:" + SHA256.hash(data: Data("operation-\(index)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func walk(_ store: PeculeDataStore, accountID: UUID, pageSize: Int, between: (AccountHistoryPage) throws -> Void = { _ in }) throws -> [BankTransaction] {
        var rows: [BankTransaction] = []
        var cursor: AccountHistoryCursor?
        var pages = 0
        repeat {
            let page = try store.accountHistory(accountID: accountID, after: cursor, limit: pageSize)
            rows += page.transactions
            cursor = page.next
            pages += 1
            try between(page)
        } while cursor != nil && pages < 2_000
        return rows
    }

    func testPaginationReturnsEveryRowOnceWhenIdentifiersSortDifferentlyThanTheyCompare() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount(stableIdentifier: "acc")
        // Several of these order differently under the store's locale-aware sort and a binary comparison.
        let tricky = ["9", "10", "A", "a", "_x", "é", "B", "b", "2", "_", "é2", "Z"]
        let sameDay = (tricky + (0..<12).map(digestReference)).map {
            TestFixtures.transaction(account: account, reference: $0, amount: 1, direction: .debit, dayOffset: 0)
        }
        let older = (0..<5).map { TestFixtures.transaction(account: account, reference: "older-\($0)", amount: 1, direction: .debit, dayOffset: -1 - $0 / 2) }
        let newer = [TestFixtures.transaction(account: account, reference: "newer", amount: 1, direction: .debit, dayOffset: 1)]
        let all = sameDay + older + newer
        try store.importBankTransactions(all)
        let expected = Set(all.map(\.externalID))

        let whole = try store.accountHistory(accountID: account.id, limit: 500)
        XCTAssertNil(whole.next)
        XCTAssertEqual(whole.transactions.count, expected.count)
        XCTAssertEqual(whole.transactions.map(\.bookingDate), whole.transactions.map(\.bookingDate).sorted(by: >), "most recent day first")

        for pageSize in [1, 2, 3, 5, 7, 24, 100] {
            let ids = try walk(store, accountID: account.id, pageSize: pageSize).map(\.externalID)
            XCTAssertEqual(ids.count, expected.count, "page size \(pageSize): no row skipped, none repeated")
            XCTAssertEqual(Set(ids), expected, "page size \(pageSize)")
            XCTAssertEqual(ids, whole.transactions.map(\.externalID), "page size \(pageSize): the order does not depend on the paging")
            XCTAssertEqual(try walk(store, accountID: account.id, pageSize: pageSize).map(\.externalID), ids, "page size \(pageSize): and it is stable")
        }
    }

    func testTwoHundredFiftyOperationsOfTheSameDayPageWithoutLossOrRepeat() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount(stableIdentifier: "acc")
        let rows = (0..<250).map { TestFixtures.transaction(account: account, reference: digestReference($0), amount: 1, direction: .debit, dayOffset: 0) }
        try store.importBankTransactions(rows)

        let ids = try walk(store, accountID: account.id, pageSize: 100).map(\.externalID)

        XCTAssertEqual(ids.count, 250)
        XCTAssertEqual(Set(ids), Set(rows.map(\.externalID)))
    }

    func testRowsAddedOnTheCursorDayWhilePagingAreNeitherSkippedNorRepeated() throws {
        let store = try TestFixtures.makeDataStore()
        let account = TestFixtures.linkedAccount(stableIdentifier: "acc")
        let initial = (0..<10).map { TestFixtures.transaction(account: account, reference: "d0-\($0)", amount: 1, direction: .debit, dayOffset: 0) }
            + (0..<4).map { TestFixtures.transaction(account: account, reference: "d1-\($0)", amount: 1, direction: .debit, dayOffset: -1) }
        try store.importBankTransactions(initial)
        let arrivals = [
            TestFixtures.transaction(account: account, reference: "A-late", amount: 1, direction: .debit, dayOffset: 0),
            TestFixtures.transaction(account: account, reference: "0-late", amount: 1, direction: .debit, dayOffset: 0),
        ]
        let newerDay = TestFixtures.transaction(account: account, reference: "tomorrow", amount: 1, direction: .debit, dayOffset: 1)
        var inserted = false

        let ids = try walk(store, accountID: account.id, pageSize: 3) { _ in
            guard !inserted else { return }
            inserted = true
            try store.importBankTransactions(arrivals + [newerDay])
        }.map(\.externalID)

        XCTAssertEqual(ids.count, Set(ids).count, "no row is returned twice")
        XCTAssertEqual(Set(ids), Set((initial + arrivals).map(\.externalID)), "rows added on the cursor day are reached, rows of a newer day are not")
    }
}
