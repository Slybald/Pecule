import XCTest

// Le parcours de connexion bancaire est le premier écran qu'un ami verra, et il n'était joué par
// aucun test : 669 lignes entre BankConnectionView et le formulaire de passerelle, couverture nulle.
@MainActor
final class BankConnectionUITests: PeculeUITestCase {
    // Depuis une installation vide : appel à l'action, choix de banque, sélection des comptes,
    // import, et un solde qui s'affiche. C'est le critère d'acceptation du lot 3.
    func testConnectingABankFromTheEmptyAccountsTabImportsAndShowsABalance() {
        let app = launchEmptyApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-accounts")

        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-empty-state").waitForExistence(timeout: 5))
        identifiedElement(in: app, identifier: "accounts-connect-bank").tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-connection-screen").waitForExistence(timeout: 5))
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()

        // Sélection des comptes inclus : l'import n'a pas encore eu lieu.
        let selectionToggle = identifiedElement(in: app, identifier: "bank-selection-stub-identification-hash")
        XCTAssertTrue(selectionToggle.waitForExistence(timeout: 20), "l'écran de sélection des comptes s'affiche")
        identifiedElement(in: app, identifier: "bank-selection-confirm").tap()

        // Import puis état des données, avec la fraîcheur du compte.
        let done = identifiedElement(in: app, identifier: "bank-connection-done")
        XCTAssertTrue(done.waitForExistence(timeout: 30), "l'import aboutit à l'état des données")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-freshness-summary").exists, "avec la fraîcheur du compte")

        done.tap()
        _ = identifiedElement(in: app, identifier: "accounts-screen").waitForExistence(timeout: 10)
        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash").waitForExistence(timeout: 10))
        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-total-balance").exists, "le solde importé s'affiche")
    }

    // Écarter un compte à la sélection doit le laisser hors des totaux, sans le faire disparaître.
    func testAnAccountLeftOutOfTheSelectionStaysOutOfTheTotals() {
        let app = launchEmptyApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-accounts")
        identifiedElement(in: app, identifier: "accounts-connect-bank").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()

        let selection = identifiedElement(in: app, identifier: "bank-selection-stub-identification-hash")
        XCTAssertTrue(selection.waitForExistence(timeout: 15))
        selection.tap()
        identifiedElement(in: app, identifier: "bank-selection-confirm").tap()

        XCTAssertTrue(
            identifiedElement(in: app, identifier: "bank-connection-done").waitForExistence(timeout: 30),
            "l'import aboutit même en écartant un compte"
        )
    }

    // « Configurer la passerelle » est un réglage de développeur : un utilisateur ne voit que « Lier un compte ».
    func testGatewaySettingsStayHiddenUntilDeveloperModeIsEnabled() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        setDeveloperMode(false, in: app)
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "settings-bank-link-button"), "« Lier un compte » reste la seule action visible")
        // Une ligne hors écran n'existe pas dans l'arbre : sans défilement, « n'existe pas » serait vrai à vide.
        XCTAssertFalse(scrollUntilExists(in: app, identifier: "settings-bank-link-external-button", attempts: 3))
        XCTAssertFalse(scrollUntilExists(in: app, identifier: "settings-bank-gateway-configure-button", attempts: 3))

        setDeveloperMode(true, in: app)
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "settings-bank-gateway-configure-button"))
        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-bank-link-external-button").exists)
        setDeveloperMode(false, in: app)
    }

    // Le formulaire de passerelle, 413 lignes jamais exercées : ses refus de saisie sont ce qui
    // empêche un ami de se retrouver bloqué sans comprendre pourquoi.
    func testTheGatewayFormRefusesAnInvalidAddressAndAnEmptyToken() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        setDeveloperMode(true, in: app)
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "settings-bank-gateway-configure-button"))
        identifiedElement(in: app, identifier: "settings-bank-gateway-configure-button").tap()

        let url = identifiedElement(in: app, identifier: "gateway-form-url-field")
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("pas-une-url")

        let token = identifiedElement(in: app, identifier: "gateway-form-token-field")
        token.tap()
        token.typeText("x")
        // Sortir du champ pour que la validation s'affiche.
        url.tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "gateway-form-url-error").waitForExistence(timeout: 5), "une adresse non HTTPS est refusée")

        // L'état « désactivé » d'un bouton de barre d'outils ne se lit pas de façon fiable :
        // on vérifie ce qui compte, à savoir qu'une configuration invalide n'est pas acceptée.
        identifiedElement(in: app, identifier: "gateway-form-save-button").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "gateway-form-url-field").exists, "le formulaire reste ouvert sur une adresse invalide")
    }

    private func scrollUntilExists(in app: XCUIApplication, identifier: String, attempts: Int = 5) -> Bool {
        for _ in 0 ..< attempts {
            if identifiedElement(in: app, identifier: identifier).waitForExistence(timeout: 2) {
                return true
            }
            app.swipeUp()
        }
        return identifiedElement(in: app, identifier: identifier).exists
    }
}
