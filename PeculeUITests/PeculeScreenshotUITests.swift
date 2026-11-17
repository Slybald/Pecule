import XCTest

@MainActor
final class PeculeScreenshotUITests: PeculeUITestCase {
    func testCaptureDashboardSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        waitForScreen(in: app, identifier: "dashboard-screen")
        capture(name: "dashboard_seeded")
    }

    func testCaptureSubscriptionsSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        openSpendingSegment(in: app, "subscriptions")
        waitForScreen(in: app, identifier: "subscriptions-list")
        capture(name: "subscriptions_seeded")
    }

    func testCapturePurchasesSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        openSpendingSegment(in: app, "purchases")
        waitForScreen(in: app, identifier: "purchases-list")
        capture(name: "purchases_seeded")
    }

    func testCaptureGoalsSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-goals")
        waitForScreen(in: app, identifier: "goals-list")
        capture(name: "goals_seeded")
    }

    func testCaptureHabitsSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-habits")
        waitForScreen(in: app, identifier: "habits-list")
        capture(name: "habits_seeded")
    }

    func testCaptureDashboardEmpty() {
        let app = launchEmptyApp(disableAnimations: true)
        waitForScreen(in: app, identifier: "dashboard-empty-state")
        capture(name: "dashboard_empty")
    }

    func testCaptureIncomeListSeeded() {
        let app = launchSeededApp(disableAnimations: true)
        openIncomeScreen(in: app)
        waitForScreen(in: app, identifier: "income-screen")
        capture(name: "income_list_seeded")
    }

    func testCaptureIncomeEmpty() {
        let app = launchEmptyApp(disableAnimations: true)
        openIncomeScreen(in: app)
        waitForScreen(in: app, identifier: "income-empty-state")
        capture(name: "income_empty")
    }

    func testCaptureSubscriptionForm() {
        let app = launchSeededApp(disableAnimations: true)
        openSpendingSegment(in: app, "subscriptions")

        let addButton = app.buttons["subscriptions-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.buttons["subscription-form-save-button"].waitForExistence(timeout: 5))
        capture(name: "subscription_form")
    }

    func testCaptureIncomeSourceForm() {
        let app = launchSeededApp(disableAnimations: true)
        openIncomeScreen(in: app)

        let addButton = app.buttons["income-add-source-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.buttons["income-source-form-save-button"].waitForExistence(timeout: 5))
        capture(name: "income_source_form")
    }

    func testCaptureIncomeOverrideForm() {
        let app = launchSeededApp(disableAnimations: true)
        openIncomeScreen(in: app)

        let addButton = app.buttons["income-add-override-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.buttons["income-override-form-save-button"].waitForExistence(timeout: 5))
        capture(name: "income_override_form")
    }
}
