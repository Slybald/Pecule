import XCTest

@MainActor
final class ProvisionUITests: PeculeUITestCase {
    private func reach(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = identifiedElement(in: app, identifier: identifier)
        for _ in 0..<8 { if element.exists && element.isHittable { return element }; app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); return element
    }
    private func createProvision(in app: XCUIApplication) {
        openRootTab(in: app, identifier: "root-tab-goals")
        identifiedElement(in: app, identifier: "goals-provisions").tap()
        identifiedElement(in: app, identifier: "provision-add").tap()
        let title = identifiedElement(in: app, identifier: "provision-name")
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Assurance test")
        identifiedElement(in: app, identifier: "provision-amount").tap()
        identifiedElement(in: app, identifier: "provision-amount").typeText("100")
        identifiedElement(in: app, identifier: "provision-save").tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "provision-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "provision-detail-title").waitForExistence(timeout: 5))
    }
    func testCreateReserveEditCancelAndOpenFromBudget() {
        let app = launchEmptyApp(disableAnimations: true)
        createProvision(in: app)
        identifiedElement(in: app, identifier: "provision-reserve-suggested").tap()
        XCTAssertFalse(identifiedElement(in: app, identifier: "provision-reserve-suggested").exists)
        capture(name: "provision-funded")
        identifiedElement(in: app, identifier: "provision-edit").tap()
        let amount = identifiedElement(in: app, identifier: "provision-amount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("120")
        identifiedElement(in: app, identifier: "provision-save").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "provision-reserve-suggested").waitForExistence(timeout: 5))
        identifiedElement(in: app, identifier: "provision-edit").tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("999")
        identifiedElement(in: app, identifier: "provision-cancel").tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "999,00")).firstMatch.exists)
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-provisions", in: app).tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "provision-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertEqual(identifiedElement(in: app, identifier: "provision-detail-title").label, "Assurance test")
    }
    func testMatchAndUndoPaymentFromAProvision() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        createProvision(in: app)
        identifiedElement(in: app, identifier: "provision-reserve-suggested").tap()
        reach("provision-match-payment", in: app).tap()
        let payment = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "provision-payment-")).firstMatch
        XCTAssertTrue(payment.waitForExistence(timeout: 5)); payment.tap()
        identifiedElement(in: app, identifier: "provision-payment-confirm").tap()
        let undo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "provision-unmatch-")).firstMatch
        for _ in 0..<8 { if undo.exists && undo.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(undo.exists); capture(name: "provision-payment-linked"); undo.tap()
        XCTAssertFalse(undo.exists)
    }

    // Run with the simulator's dark appearance and accessibility text size as well.
    func testProvisionControlsRemainReachableWithLargeText() {
        let app = launchEmptyApp(disableAnimations: true)
        createProvision(in: app)
        capture(name: "provision-accessibility-summary")
        reach("provision-reserve-suggested", in: app).tap()
        XCTAssertFalse(identifiedElement(in: app, identifier: "provision-reserve-suggested").exists)
        reach("goal-reservation-amount", in: app)
        capture(name: "provision-accessibility-reserve")
    }
}
