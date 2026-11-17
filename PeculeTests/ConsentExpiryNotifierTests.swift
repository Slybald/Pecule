import XCTest
import UserNotifications
@testable import Pecule

@MainActor
final class ConsentExpiryNotifierTests: XCTestCase {
    func testBuildsOneQuietReminderPerLinkedAccountSevenDaysBeforeExpiry() throws {
        let calendar = TestFixtures.utcCalendar()
        let now = TestFixtures.referenceDate // 2026-09-14
        let soon = TestFixtures.linkedAccount(stableIdentifier: "soon", name: "Compte courant")
        soon.consentValidUntil = TestFixtures.date(2026, 10, 1)
        let past = TestFixtures.linkedAccount(stableIdentifier: "past", name: "Ancien")
        past.consentValidUntil = TestFixtures.date(2026, 9, 18, hour: 0)
        let manual = ExternalAccount(manualName: "Livret", balance: 10)

        let requests = ConsentExpiryNotifier(calendar: calendar).requests(for: [soon, past, manual], now: now, locale: Locale(identifier: "fr_FR"))

        XCTAssertEqual(requests.map(\.identifier), ["consent-expiry-soon"], "a reminder already in the past and a manual account produce nothing")
        let request = try XCTUnwrap(requests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.year, 2026)
        XCTAssertEqual(trigger.dateComponents.month, 9)
        XCTAssertEqual(trigger.dateComponents.day, 24)
        XCTAssertEqual(trigger.dateComponents.hour, 9)
        XCTAssertTrue(request.content.body.contains("Compte courant"))
        XCTAssertNil(request.content.sound, "quiet delivery")
    }
}
