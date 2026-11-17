import Foundation
import SwiftData
import XCTest
@testable import Pecule

// La table d'erreurs : aucune erreur technique ne doit arriver telle quelle à l'écran, dans les deux langues.
final class UserFacingErrorTests: XCTestCase {
    private let fr = Locale(identifier: "fr_FR")
    private let en = Locale(identifier: "en_US")

    private struct Opaque: Error {}

    func testALostBankLinkIsExplainedAndOffersAReconnection() {
        let error = BankGatewayError.upstream(status: 404, code: "ACCOUNT_DOES_NOT_EXIST")
        let french = UserFacingError(error, locale: fr)
        let english = UserFacingError(error, locale: en)

        XCTAssertEqual(french.action, .reconnectBank)
        XCTAssertEqual(english.action, .reconnectBank)
        XCTAssertTrue(french.message.hasPrefix("Le lien avec ta banque a expiré"))
        XCTAssertTrue(english.message.hasPrefix("The link with your bank has expired"))
        for message in [french.message, english.message] {
            XCTAssertFalse(message.contains("404"))
            XCTAssertFalse(message.contains("ACCOUNT_DOES_NOT_EXIST"))
        }
    }

    func testAnExpiredConsentAndAnUpstreamSessionErrorBothOfferAReconnection() {
        XCTAssertEqual(UserFacingError(BankGatewayError.sessionExpired, locale: fr).action, .reconnectBank)
        XCTAssertEqual(UserFacingError(BankGatewayError.upstream(status: 401, code: "EXPIRED_SESSION"), locale: fr).action, .reconnectBank)
    }

    func testAFailureStoredBeforeTheKeysExistedIsNeverShownRaw() {
        let legacy = "Erreur : 404 ACCOUNT_DOES_NOT_EXIST"
        XCTAssertEqual(BankFreshnessService.localizedStoredError(legacy), AppLocalizer.string("error.bank.unexpected"))
        XCTAssertEqual(BankFreshnessService.localizedStoredError("session_expired"), AppLocalizer.string("error.bank.linkExpired"))
        XCTAssertEqual(BankFreshnessService.localizedStoredError("error.bank.linkExpired"), AppLocalizer.string("error.bank.linkExpired"))
        XCTAssertEqual(BankFreshnessService.localizedStoredError("error.nonexistent.key"), AppLocalizer.string("error.bank.unexpected"))
    }

    func testAnUpstreamFailureCarriesTheKeyThatIsStoredInsteadOfTheSentence() {
        XCTAssertEqual(UserFacingError(BankGatewayError.upstream(status: 404, code: "X"), locale: fr).key, "error.bank.linkExpired")
        XCTAssertEqual(UserFacingError(BankGatewayError.transport("x"), locale: fr).key, "error.network")
    }

    // Audit du 9 novembre 2026, constat 10 : une session révoquée ou fermée côté banque ne se rétablit que par une reconnexion.
    func testARevokedOrClosedBankSessionOffersAReconnection() {
        for code in ["REVOKED_SESSION", "CLOSED_SESSION"] {
            let presented = UserFacingError(BankGatewayError.upstream(status: 401, code: code), locale: fr)
            XCTAssertEqual(presented.action, .reconnectBank, code)
            XCTAssertEqual(presented.key, "error.bank.linkExpired", code)
        }
        XCTAssertEqual(UserFacingError(BankGatewayError.upstream(status: 401, code: "UNAUTHORIZED_ACCESS"), locale: fr).action, .none)
    }

    func testTransientFailuresOfferNoReconnection() {
        XCTAssertEqual(UserFacingError(BankGatewayError.transport("timeout"), locale: fr).action, .none)
        XCTAssertEqual(UserFacingError(BankGatewayError.upstream(status: 503, code: "ASPSP_ERROR"), locale: fr).action, .none)
        XCTAssertEqual(UserFacingError(BankGatewayError.rateLimited(retryAfterSeconds: 60), locale: fr).action, .none)
    }

    func testNoGatewayErrorLeaksItsCodeOrItsDetail() {
        let errors: [BankGatewayError] = [
            .notConfigured, .unauthorized, .sessionExpired, .rateLimited(retryAfterSeconds: 5), .linkNotFound,
            .upstream(status: 502, code: "SECRET_CODE"), .http(status: 418, code: "teapot"),
            .transport("NSURLErrorDomain -1009"), .decoding("keyNotFound(CodingKeys)")
        ]
        for locale in [fr, en] {
            for error in errors {
                let message = UserFacingError(error, locale: locale).message
                for fragment in ["SECRET_CODE", "teapot", "NSURLError", "keyNotFound", "502", "418", "Pecule."] {
                    XCTAssertFalse(message.contains(fragment), "\(error) → « \(message) » contains \(fragment)")
                }
                XCTAssertFalse(message.hasPrefix("error."), "a missing catalogue key would show its name: \(message)")
            }
        }
    }

    func testSessionNetworkAndDataErrorsGetASentence() {
        XCTAssertEqual(UserFacingError(GatewaySessionCoordinator.SessionError.expired, locale: fr).message, "Ta session a expiré. Reconnecte-toi.")
        XCTAssertEqual(UserFacingError(URLError(.notConnectedToInternet), locale: en).message, "Couldn't reach the service. Check your connection and try again.")
        XCTAssertTrue(UserFacingError(CocoaError(.fileWriteUnknown), locale: fr).message.hasPrefix("Impossible de lire ou d'enregistrer"))
    }

    func testAnUnknownErrorNeverShowsItsTypeName() {
        let message = UserFacingError(Opaque(), locale: fr).message
        XCTAssertEqual(message, "Une erreur inattendue est survenue. Réessaie.")
    }

    func testTheAppsOwnWrittenErrorsKeepTheirSentence() {
        let own = AllocationError.overCapacity
        XCTAssertEqual(UserFacingError(own, locale: fr).message, own.errorDescription)
    }
}
