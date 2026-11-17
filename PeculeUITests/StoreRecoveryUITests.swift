import XCTest

// Câblage de l'écran de reprise : il remplace l'application quand la base ne s'ouvre pas, ses identifiants
// sont adressables, et « Réessayer » rouvre la base. Le contenu exact des messages et la copie des fichiers
// sont vérifiés en test unitaire (StoreBackupTests) ; ici, le premier essai d'ouverture échoue par simulation.
@MainActor
final class StoreRecoveryUITests: PeculeUITestCase {
    func testFailedStoreOpeningShowsTheRecoveryScreenAndRetryOpensTheApp() {
        let app = XCUIApplication()
        app.launchEnvironment["PECULE_UI_TESTS_USE_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["PECULE_AUTOMATION_DATA_MODE"] = AutomationDataMode.empty.rawValue
        app.launchEnvironment["PECULE_AUTOMATION_DISABLE_ANIMATIONS"] = "1"
        app.launchEnvironment["PECULE_AUTOMATION_SIMULATE_STORE_FAILURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()
        addTeardownBlock {
            if app.state != .notRunning { app.terminate() }
        }

        let retry = waitForScreen(in: app, identifier: "store-recovery-retry")
        XCTAssertEqual(retry.label, "Réessayer")
        XCTAssertTrue(identifiedElement(in: app, identifier: "store-recovery-title").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "store-recovery-message").label.contains("copie de sécurité"))
        XCTAssertTrue(identifiedElement(in: app, identifier: "store-recovery-error-id").label.contains("open-NSCocoaErrorDomain-259"))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "l'application ne s'affiche pas tant que la base n'est pas ouverte")
        capture(name: "store-recovery")

        retry.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "après « Réessayer », la base s'ouvre et l'application apparaît")
        XCTAssertFalse(identifiedElement(in: app, identifier: "store-recovery-retry").exists)
    }
}
