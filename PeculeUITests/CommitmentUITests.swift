import XCTest

@MainActor
final class CommitmentUITests: PeculeUITestCase {
    private func enableSwitch(_ identifier: String, in app: XCUIApplication) {
        let row = reach(identifier, in: app)
        // SwiftUI exposes the whole row and the actual thumb as nested switches.
        // Tapping the row's center hits its label, not the control on iOS 26.
        let control = row.switches.firstMatch
        XCTAssertTrue(control.exists)
        control.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
    }
    private func reach(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = identifiedElement(in: app, identifier: identifier)
        for _ in 0..<6 {
            if element.exists && element.isHittable { return element }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); return element
    }
    func testCreateEditStopAndCancelCommitmentFromBudget() {
        let app = launchEmptyApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-commitments", in: app).tap()
        identifiedElement(in: app, identifier: "commitments-add").tap()
        let name = identifiedElement(in: app, identifier: "commitment-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Assurance annuelle")
        let amount = identifiedElement(in: app, identifier: "commitment-amount")
        amount.tap(); amount.typeText("120")
        identifiedElement(in: app, identifier: "commitment-save").tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Assurance annuelle")).firstMatch.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "commitment-title").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Date à compléter"].exists)
        capture(name: "engagement-unknown-date")
        identifiedElement(in: app, identifier: "commitment-edit").tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("150")
        identifiedElement(in: app, identifier: "commitment-save").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "150,00")).firstMatch.waitForExistence(timeout: 5))
        identifiedElement(in: app, identifier: "commitment-stop").tap()
        XCTAssertEqual(identifiedElement(in: app, identifier: "commitment-status").label, "Arrêtés")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        identifiedElement(in: app, identifier: "commitments-add").tap()
        identifiedElement(in: app, identifier: "commitment-name").tap()
        identifiedElement(in: app, identifier: "commitment-name").typeText("Annulé")
        identifiedElement(in: app, identifier: "commitment-cancel").tap()
        XCTAssertFalse(app.staticTexts["Annulé"].exists)
    }
    func testMatchingAndRemovingABankPaymentUpdatesTheRemainingAmount() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-commitments", in: app).tap()
        identifiedElement(in: app, identifier: "commitments-add").tap()
        let name = identifiedElement(in: app, identifier: "commitment-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Mensualité test")
        let amount = identifiedElement(in: app, identifier: "commitment-amount")
        amount.tap(); amount.typeText("90")
        enableSwitch("commitment-date-known", in: app)
        identifiedElement(in: app, identifier: "commitment-save").tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mensualité test")).firstMatch.tap()
        let match = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "commitment-match-")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5)); match.tap()
        let payment = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "commitment-payment-", "Onni Mäkinen")).firstMatch
        XCTAssertTrue(payment.waitForExistence(timeout: 5)); payment.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "81,81")).firstMatch.waitForExistence(timeout: 5))
        capture(name: "engagement-partial-payment")
        let unmatch = app.buttons["Annuler l’association"].firstMatch
        for _ in 0..<8 { if unmatch.exists && unmatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(unmatch.exists); unmatch.tap()
        for _ in 0..<8 { if identifiedElement(in: app, identifier: "commitment-title").isHittable { break }; app.swipeDown() }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "81,81")).firstMatch.exists)
    }
    func testDatedFiniteCommitmentAppearsOnHomeAndStopsThere() {
        let app = launchEmptyApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-commitments", in: app).tap()
        identifiedElement(in: app, identifier: "commitments-add").tap()
        let name = identifiedElement(in: app, identifier: "commitment-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Ordinateur")
        let amount = identifiedElement(in: app, identifier: "commitment-amount")
        amount.tap(); amount.typeText("90")
        enableSwitch("commitment-date-known", in: app)
        enableSwitch("commitment-finite", in: app)
        let count = reach("commitment-count", in: app)
        count.tap(); count.clearAndTypeText("3")
        identifiedElement(in: app, identifier: "commitment-save").tap()
        openRootTab(in: app, identifier: "root-tab-today")
        let charge = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard-charge-")).firstMatch
        for _ in 0..<5 { if charge.exists && charge.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(charge.exists); charge.tap()
        XCTAssertEqual(identifiedElement(in: app, identifier: "commitment-title").label, "Ordinateur")
        capture(name: "engagement-finite-schedule")
        identifiedElement(in: app, identifier: "commitment-stop").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard-charge-")).firstMatch.exists)
    }
}
