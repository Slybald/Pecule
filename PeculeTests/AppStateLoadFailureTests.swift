import Foundation
import XCTest
@testable import Pecule

// Un échec de chargement ne vide jamais l'écran en silence : les données restent, l'échec est publié
// (l'écran de reprise s'affiche), et « Réessayer » relit le disque.
@MainActor
final class AppStateLoadFailureTests: XCTestCase {
    func testAFailedReloadKeepsTheDataAndReportsTheFailureUntilARetrySucceeds() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        try state.addSubscription(
            name: "Fitness", amount: Decimal(string: "19.90") ?? 0, billingCycle: .monthly,
            category: "Health", nextBillingDate: TestFixtures.referenceDate, isActive: true
        )
        XCTAssertEqual(state.subscriptions.count, 1)
        XCTAssertNil(state.loadFailure)

        state.injectedLoadFailure = CocoaError(.fileReadCorruptFile)
        state.reload()

        XCTAssertEqual(state.subscriptions.count, 1, "an unreadable store must not look like an empty one")
        XCTAssertEqual(state.loadFailure?.identifier, "load-NSCocoaErrorDomain-259")

        state.injectedLoadFailure = nil
        state.reload()

        XCTAssertNil(state.loadFailure)
        XCTAssertEqual(state.subscriptions.count, 1)
    }
}
