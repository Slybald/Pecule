import Foundation
import XCTest
@testable import Pecule

// Les pluriels viennent des variations du catalogue, pas de « (s) » : un seul sens par nombre, dans les deux langues.
final class PluralLocalizationTests: XCTestCase {
    private let fr = Locale(identifier: "fr_FR")
    private let en = Locale(identifier: "en_US")

    func testLinkedAccountsSubtitleAgreesWithTheCount() {
        let key = "dashboard.metrics.totalBalance.subtitle %lld"
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: fr, 1), "1 compte lié")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: fr, 3), "3 comptes liés")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: en, 1), "1 linked account")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: en, 3), "3 linked accounts")
    }

    func testScheduleAndInstallmentCountsAgreeWithTheCount() {
        XCTAssertEqual(AppLocalizer.pluralFormat("commitments.scheduleCount %lld", locale: fr, 1), "1 échéance dans ce plan")
        XCTAssertEqual(AppLocalizer.pluralFormat("commitments.scheduleCount %lld", locale: fr, 12), "12 échéances dans ce plan")
        XCTAssertEqual(AppLocalizer.pluralFormat("commitments.scheduleCount %lld", locale: en, 1), "1 payment in this plan")
        XCTAssertEqual(AppLocalizer.pluralFormat("installment.count %lld", locale: fr, 2), "2 versements au total")
        XCTAssertEqual(AppLocalizer.pluralFormat("installment.count %lld", locale: en, 2), "2 installments in total")
    }

    func testFreshnessSummaryPluralisesTheFirstCountOnly() {
        let key = "bank.freshness.attention %lld %lld"
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: fr, Int64(1), Int64(1)), "1 compte sur 1 à actualiser ou vérifier")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: fr, Int64(2), Int64(3)), "2 comptes sur 3 à actualiser ou vérifier")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: en, Int64(1), Int64(4)), "1 account of 4 to refresh or check")
        XCTAssertEqual(AppLocalizer.pluralFormat(key, locale: en, Int64(2), Int64(4)), "2 accounts of 4 to refresh or check")
    }
}
