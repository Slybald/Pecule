import XCTest

// La barre d'onglets d'iOS 26 n'expose aucun identifiant d'accessibilité sur ses boutons : toute
// la suite les atteint donc par position. Ce contrat tient tant que l'ordre ne bouge pas, et rien
// ne le vérifiait — une intervertion de deux onglets aurait fait passer des dizaines de tests en
// exerçant le mauvais écran, sans le moindre échec.
@MainActor
final class RootTabOrderUITests: PeculeUITestCase {
    func testEachPositionCarriesItsExpectedTabAndOpensItsOwnScreen() {
        let app = launchSeededApp(disableAnimations: true)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertEqual(
            tabBar.buttons.count,
            Self.rootTabs.count,
            "le nombre d'onglets a changé : les positions codées dans les tests ne valent plus"
        )

        for (index, tab) in Self.rootTabs.enumerated() {
            let button = tabBar.buttons.element(boundBy: index)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "aucun onglet en position \(index)")
            XCTAssertEqual(button.label, tab.label, "la position \(index) n'est plus « \(tab.label) »")

            button.tap()
            XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: 5), "\(tab.label) ne devient pas actif")
            XCTAssertTrue(
                identifiedElement(in: app, identifier: tab.screen).waitForExistence(timeout: 10),
                "la position \(index) devrait ouvrir « \(tab.screen) »"
            )
        }
    }
}
