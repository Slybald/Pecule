import XCTest

@MainActor
final class TreasuryCalendarUITests: PeculeUITestCase {
    private func reach(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = identifiedElement(in: app, identifier: identifier)
        for _ in 0..<10 {
            if element.exists && element.isHittable { return element }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); return element
    }
    private func connectFixture(in app: XCUIApplication) {
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        openRootTab(in: app, identifier: "root-tab-accounts")
        identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash").tap()
        reach("account-calendar", in: app).tap()
    }
    func testEmptyCalendarAndDatedSalaryCanBeSavedAndReopened() {
        let app = launchSeededApp(disableAnimations: true)
        reach("dashboard-calendar", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "treasury-empty").waitForExistence(timeout: 5))
        capture(name: "treasury-empty")
        reach("treasury-income-12121212-1212-1212-1212-121212121212", in: app).tap()
        let toggle = identifiedElement(in: app, identifier: "income-forecast-date-known")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-forecast-date").waitForExistence(timeout: 5))
        identifiedElement(in: app, identifier: "income-forecast-save").tap()
        reach("treasury-income-12121212-1212-1212-1212-121212121212", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-forecast-date").waitForExistence(timeout: 5))
        capture(name: "treasury-income-date")
        // Going back cancels the edit; the previously saved date remains.
        toggle.switches.firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reach("treasury-income-12121212-1212-1212-1212-121212121212", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-forecast-date").waitForExistence(timeout: 5))
    }
    func testAccountCalendarDayAndThresholdUpdateAndUnavailableHabitualReading() {
        let app = launchEmptyApp(disableAnimations: true)
        connectFixture(in: app)
        XCTAssertTrue(identifiedElement(in: app, identifier: "treasury-minimum").waitForExistence(timeout: 5))
        capture(name: "treasury-confirmed")
        let threshold = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "treasury-threshold-")).firstMatch
        for _ in 0..<6 { if threshold.exists && threshold.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(threshold.exists); threshold.tap()
        let amount = identifiedElement(in: app, identifier: "treasury-threshold-amount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.clearAndTypeText("10000")
        identifiedElement(in: app, identifier: "treasury-threshold-save").tap()
        for _ in 0..<6 { if identifiedElement(in: app, identifier: "treasury-reading").exists && identifiedElement(in: app, identifier: "treasury-reading").isHittable { break }; app.swipeDown() }
        let alert = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "treasury-alert-")).firstMatch
        for _ in 0..<5 { if alert.exists && alert.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(alert.exists)
        capture(name: "treasury-account-alert")
        let day = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "treasury-day-")).firstMatch
        for _ in 0..<6 { if day.exists && day.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(day.exists); day.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "treasury-day-detail").waitForExistence(timeout: 5))
        capture(name: "treasury-day-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<10 { if identifiedElement(in: app, identifier: "treasury-reading").exists && identifiedElement(in: app, identifier: "treasury-reading").isHittable { break }; app.swipeDown() }
        identifiedElement(in: app, identifier: "treasury-reading").tap()
        app.buttons["Avec dépenses habituelles"].tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "treasury-estimation-unavailable").waitForExistence(timeout: 5))
        XCTAssertFalse(identifiedElement(in: app, identifier: "treasury-minimum").exists)
        capture(name: "treasury-history-unavailable")
    }
}
