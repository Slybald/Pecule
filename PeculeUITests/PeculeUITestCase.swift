import XCTest

@MainActor
class PeculeUITestCase: XCTestCase {
    enum AutomationDataMode: String {
        case seeded
        case empty
        case bankStress
    }

    enum SeedIdentifiers {
        static let netflixSubscription = "11111111-1111-1111-1111-111111111111"
        static let gymPassSubscription = "33333333-3333-3333-3333-333333333333"
        static let runningShoesPurchase = "66666666-6666-6666-6666-666666666666"
        static let groceriesPurchase = "88888888-8888-8888-8888-888888888888"
        static let summerVacationGoal = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        static let nextIPhoneGoal = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        static let noSpendDayHabit = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
        static let reviewSubscriptionsHabit = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        static let salaryIncomeSource = "12121212-1212-1212-1212-121212121212"
        static let monthlySalaryOverride = "15151515-1515-1515-1515-151515151515"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func launchSeededApp(disableAnimations: Bool = false) -> XCUIApplication {
        launchApp(dataMode: .seeded, disableAnimations: disableAnimations)
    }

    func launchEmptyApp(disableAnimations: Bool = false) -> XCUIApplication {
        launchApp(dataMode: .empty, disableAnimations: disableAnimations)
    }

    func launchBankStressApp() -> XCUIApplication {
        launchApp(dataMode: .bankStress, disableAnimations: true)
    }

    // Les réglages de passerelle se montrent par cinq appuis rapides sur « Version » (l'état persiste d'un lancement
    // à l'autre sur le simulateur) : l'aide rend l'état voulu, quel que soit celui de départ, et remonte l'écran.
    func setDeveloperMode(_ enabled: Bool, in app: XCUIApplication) {
        let row = identifiedElement(in: app, identifier: "settings-version-row")
        // La liste peut déjà être plus bas que la ligne (elle est alors hors de l'arbre) : chercher dans les deux sens.
        for _ in 0 ..< 6 where !(row.exists && row.isHittable) { app.swipeUp() }
        for _ in 0 ..< 8 where !(row.exists && row.isHittable) { app.swipeDown() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "la ligne Version est introuvable")
        // Le bouton « Quitter » est sous la ligne Version : hors de l'arbre tant que la liste n'est pas au bout.
        let disable = identifiedElement(in: app, identifier: "settings-developer-disable")
        app.swipeUp()
        if enabled, !disable.exists {
            for _ in 0 ..< 5 { row.tap() }
            app.swipeUp()
            XCTAssertTrue(disable.waitForExistence(timeout: 5), "cinq appuis sur Version doivent activer le mode développeur")
        } else if !enabled, disable.exists {
            // Le bouton existe avant d'être touchable (barre d'onglets, clavier) : défiler jusqu'à ce qu'il le soit.
            for _ in 0 ..< 4 where !disable.isHittable { app.swipeUp() }
            disable.tap()
            XCTAssertTrue(waitUntilGone(disable), "le mode développeur doit se quitter")
        }
        for _ in 0 ..< 6 { app.swipeDown() }
    }

    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func identifiedElement(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func waitForScreen(
        in app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = identifiedElement(in: app, identifier: identifier)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected screen element \(identifier) to exist.",
            file: file,
            line: line
        )
        return element
    }

    // iOS 26 n'expose aucun identifiant d'accessibilité sur les boutons de la barre d'onglets,
    // quelle que soit l'API SwiftUI : seule la position est adressable. L'ordre attendu est
    // vérifié une fois pour toutes par `RootTabOrderUITests`, et non à chaque appel, parce qu'un
    // onglet rouvert peut très bien garder un écran empilé au lieu de montrer sa racine.
    static let rootTabs: [(identifier: String, label: String, screen: String)] = [
        ("root-tab-today", "Accueil", "dashboard-screen"),
        ("root-tab-operations", "Opérations", "operations-screen"),
        ("root-tab-spending", "Budget", "budget-manage-menu"),
        ("root-tab-goals", "Objectifs", "goals-add-button"),
        ("root-tab-accounts", "Comptes", "accounts-screen"),
    ]

    func openRootTab(
        in app: XCUIApplication,
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Les habitudes ne sont pas un onglet : on y accède par le menu de l'accueil.
        if identifier == "root-tab-habits" {
            openRootTab(in: app, identifier: "root-tab-today", file: file, line: line)
            identifiedElement(in: app, identifier: "dashboard-more-menu").tap()
            identifiedElement(in: app, identifier: "dashboard-habits-menu").tap()
            return
        }

        guard let index = Self.rootTabs.firstIndex(where: { $0.identifier == identifier }) else {
            XCTFail("onglet inconnu « \(identifier) »", file: file, line: line)
            return
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "barre d'onglets absente", file: file, line: line)

        let button = tabBar.buttons.element(boundBy: index)
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "aucun onglet en position \(index)",
            file: file,
            line: line
        )
        button.tap()
        XCTAssertTrue(
            button.wait(for: \.isSelected, toEqual: true, timeout: 5),
            "l'onglet \(identifier) n'est pas devenu actif",
            file: file,
            line: line
        )
    }

    func openDashboardAnalyses(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if identifiedElement(in: app, identifier: "dashboard-metric-health").exists { return }
        let menu = identifiedElement(in: app, identifier: "dashboard-more-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "menu de l'accueil absent", file: file, line: line)
        menu.tap()

        // Le menu se déploie avec un court délai. Taper l'entrée aussitôt échoue sur un « aucune
        // correspondance » qui laisse croire à un identifiant disparu, alors que le menu n'est pas
        // encore ouvert. Une seconde tape le rouvre si la première s'est perdue.
        let analyses = identifiedElement(in: app, identifier: "dashboard-analyses-button")
        if !analyses.waitForExistence(timeout: 5) {
            menu.tap()
            XCTAssertTrue(analyses.waitForExistence(timeout: 5), "entrée Analyses absente du menu", file: file, line: line)
        }
        analyses.tap()

        XCTAssertTrue(
            identifiedElement(in: app, identifier: "dashboard-metric-health").waitForExistence(timeout: 10),
            "l'écran des analyses ne s'ouvre pas",
            file: file,
            line: line
        )
    }

    func expandDashboardDetails(in app: XCUIApplication) {
        if !identifiedElement(in: app, identifier: "dashboard-secondary-toggle").exists {
            openDashboardAnalyses(in: app)
        }
        let toggle = identifiedElement(in: app, identifier: "dashboard-secondary-toggle")
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
    }

    // Purchases and subscriptions are reached through the Budget management menu.
    func openSpendingSegment(
        in app: XCUIApplication,
        _ segment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openRootTab(in: app, identifier: "root-tab-spending", file: file, line: line)
        identifiedElement(in: app, identifier: "budget-manage-menu").tap()
        let button = app.descendants(matching: .any).matching(identifier: "spending-segment-\(segment)").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        button.tap()
    }

    func capture(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func openIncomeScreen(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !identifiedElement(in: app, identifier: "dashboard-income-button").isHittable {
            identifiedElement(in: app, identifier: "dashboard-more-menu").tap()
        }
        let incomeButton = identifiedElement(in: app, identifier: "dashboard-income-button")
        XCTAssertTrue(incomeButton.waitForExistence(timeout: 5), file: file, line: line)
        incomeButton.tap()
    }

    private func launchApp(
        dataMode: AutomationDataMode,
        disableAnimations: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PECULE_UI_TESTS_USE_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["PECULE_AUTOMATION_DATA_MODE"] = dataMode.rawValue
        app.launchEnvironment["PECULE_AUTOMATION_DISABLE_ANIMATIONS"] = disableAnimations ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()

        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        return app
    }
}

@MainActor
extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        tap()

        if let currentValue = value as? String, !currentValue.isEmpty {
            let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            typeText(deleteText)
        }

        typeText(text)
    }
}
