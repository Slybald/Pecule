import XCTest
@testable import Pecule

@MainActor
final class BankRetentionTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let now = TestFixtures.referenceDate // 2026-09-14

    func testPolicyDatesAndDeadConsentRule() {
        let policy = BankRetentionPolicy.default

        XCTAssertEqual(policy.cutoffDate(now: now, calendar: calendar), TestFixtures.date(2024, 9, 14, hour: 0))

        let fresh = TestFixtures.linkedAccount(stableIdentifier: "fresh")
        fresh.consentValidUntil = TestFixtures.date(2026, 1, 1)
        fresh.status = ExternalAccountStatus.needsReconnect.rawValue
        XCTAssertTrue(policy.isDeadConsent(fresh, now: now, calendar: calendar), "expired 8 months ago and never reconnected")

        let recent = TestFixtures.linkedAccount(stableIdentifier: "recent")
        recent.consentValidUntil = TestFixtures.date(2026, 8, 1)
        recent.status = ExternalAccountStatus.needsReconnect.rawValue
        XCTAssertFalse(policy.isDeadConsent(recent, now: now, calendar: calendar), "still inside the grace period")

        let active = TestFixtures.linkedAccount(stableIdentifier: "active")
        active.consentValidUntil = TestFixtures.date(2026, 1, 1)
        XCTAssertFalse(policy.isDeadConsent(active, now: now, calendar: calendar), "an active account is never purged")

        let manual = ExternalAccount(manualName: "Livret", balance: 100)
        manual.consentValidUntil = TestFixtures.date(2020, 1, 1)
        XCTAssertFalse(policy.isDeadConsent(manual, now: now, calendar: calendar))
    }

    func testRetentionPurgesOnlyUnannotatedAutomaticRowsAndPreservesExpiredAccounts() throws {
        let store = try TestFixtures.makeDataStore()
        let accounts = try store.saveExternalAccounts([
            TestFixtures.linkedAccount(stableIdentifier: "live", name: "Compte courant"),
            TestFixtures.linkedAccount(stableIdentifier: "dead", name: "Vieux compte"),
        ])
        let live = try XCTUnwrap(accounts.first { $0.stableIdentifier == "live" })
        let dead = try XCTUnwrap(accounts.first { $0.stableIdentifier == "dead" })
        dead.consentValidUntil = TestFixtures.date(2025, 12, 1)
        try store.updateExternalAccountStatus(dead, status: .needsReconnect, error: "session_expired")

        let old = TestFixtures.transaction(account: live, reference: "old", amount: 10, direction: .debit, dayOffset: -800)
        old.automaticCategory = old.category
        let oldLinked = TestFixtures.transaction(account: live, reference: "old-linked", amount: 12, direction: .debit, dayOffset: -800)
        oldLinked.apply(.subscription(UUID()))
        let recent = TestFixtures.transaction(account: live, reference: "recent", amount: 30, direction: .debit, dayOffset: -30)
        let deadRow = TestFixtures.transaction(account: dead, reference: "dead-row", amount: 5, direction: .debit, dayOffset: -10)
        try store.importBankTransactions([old, oldLinked, recent, deadRow])

        let report = try store.applyBankRetention(now: now, calendar: calendar)

        XCTAssertEqual(report.purgedTransactions, 1, "only the old unlinked row goes")
        XCTAssertTrue(report.removedAccounts.isEmpty)
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(Set(snapshot.externalAccounts.map(\.stableIdentifier)), ["live", "dead"])
        XCTAssertEqual(Set(snapshot.bankTransactions.map(\.label)), ["old-linked", "recent", "dead-row"])

        let second = try store.applyBankRetention(now: now, calendar: calendar)
        XCTAssertTrue(second.isEmpty, "idempotent")
    }
}
