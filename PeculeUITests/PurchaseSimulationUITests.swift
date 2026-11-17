import XCTest

@MainActor
final class PurchaseSimulationUITests: PeculeUITestCase {
    private func reach(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        reach(identifiedElement(in: app, identifier: identifier), in: app)
    }
    private func reach(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<14 { if element.exists && element.isHittable { return element }; app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription); return element
    }
    private func create(in app: XCUIApplication) {
        openRootTab(in: app, identifier: "root-tab-goals")
        reach("goals-simulations", in: app).tap()
        reach("simulation-add", in: app).tap()
        let name = identifiedElement(in: app, identifier: "simulation-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Ordinateur test")
        let amount = reach("simulation-amount", in: app)
        amount.tap(); amount.typeText("100")
        identifiedElement(in: app, identifier: "simulation-save").tap()
    }
    private func row(in app: XCUIApplication) -> XCUIElement {
        reach(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "simulation-row-")).firstMatch, in: app)
    }
    func testCreateEditCancelReopenFromBudgetAndDeleteScenario() {
        let app = launchEmptyApp(disableAnimations: true)
        create(in: app)
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5)); row(in: app).tap()
        let amount = identifiedElement(in: app, identifier: "simulation-amount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("120")
        identifiedElement(in: app, identifier: "simulation-save").tap()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5)); row(in: app).tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("999")
        identifiedElement(in: app, identifier: "simulation-cancel").tap()
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-simulations", in: app).tap()
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5)); row(in: app).tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value as? String, "120")
        XCTAssertTrue(reach("simulation-budget-after", in: app).label.contains("Non disponible"))
        capture(name: "simulation-no-budget")
        reach("simulation-delete", in: app).tap()
        let confirm = app.sheets.buttons["Supprimer le scénario"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "simulation-empty").waitForExistence(timeout: 5))
    }
    // Also run in dark appearance with the largest accessibility text size.
    func testBankComparisonAndProjectImpactRemainReachable() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        create(in: app)
        XCTAssertTrue(row(in: app).waitForExistence(timeout: 5)); row(in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "simulation-amount").waitForExistence(timeout: 5))
        XCTAssertTrue(reach("simulation-minimum-before", in: app).label.contains("53,51"))
        XCTAssertTrue(reach("simulation-minimum-after", in: app).label.contains("46,49"))
        capture(name: "simulation-bank-comparison")
        reach("simulation-projects-after", in: app)
        capture(name: "simulation-projects-impact")
        identifiedElement(in: app, identifier: "simulation-cancel").tap()
        openRootTab(in: app, identifier: "root-tab-accounts")
        let account = reach("accounts-card-stub-identification-hash", in: app)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "53,51")).firstMatch.exists,
                      account.debugDescription)
    }
}
