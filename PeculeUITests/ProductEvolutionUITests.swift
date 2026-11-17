import XCTest

@MainActor
final class ProductEvolutionUITests: PeculeUITestCase {
    private func scrollUntilExists(in app: XCUIApplication, identifier: String) -> Bool {
        for _ in 0..<6 {
            let element = identifiedElement(in: app, identifier: identifier)
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return identifiedElement(in: app, identifier: identifier).isHittable
    }

    func testNativeOverviewLinksAndScreenshots() {
        let app = launchSeededApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5)); mock.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))

        openRootTab(in: app, identifier: "root-tab-goals")
        capture(name: "native-overview-goals")
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "goals-budget-button"))
        identifiedElement(in: app, identifier: "goals-budget-button").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "budgets-summary").waitForExistence(timeout: 5))
        capture(name: "native-overview-budget")
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "budget-all-operations"))
        identifiedElement(in: app, identifier: "budget-all-operations").tap()
        waitForScreen(in: app, identifier: "operations-screen")
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        capture(name: "native-overview-operations")

        openRootTab(in: app, identifier: "root-tab-accounts")
        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash").waitForExistence(timeout: 5))
        capture(name: "native-overview-accounts")
    }

    func testMonthlyBudgetIsSharedBetweenHomeAndBudgetAndCanBeRemoved() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-budget-edit").tap()
        let amount = identifiedElement(in: app, identifier: "monthly-budget-amount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("1500")
        identifiedElement(in: app, identifier: "monthly-budget-save").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-budget-margin").waitForExistence(timeout: 5))
        capture(name: "native-home-manual-budget")
        identifiedElement(in: app, identifier: "dashboard-budget-margin").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "monthly-budget-explained-margin").waitForExistence(timeout: 5))
        openRootTab(in: app, identifier: "root-tab-spending")
        identifiedElement(in: app, identifier: "budget-monthly-limit").tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue((amount.value as? String ?? "").contains("1500"))
        amount.clearAndTypeText("0")
        identifiedElement(in: app, identifier: "monthly-budget-save").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "budget-monthly-margin").waitForExistence(timeout: 5))
        openRootTab(in: app, identifier: "root-tab-today")
        let explained = identifiedElement(in: app, identifier: "monthly-budget-explained-margin")
        XCTAssertTrue(explained.waitForExistence(timeout: 5))
        XCTAssertTrue(explained.label.contains("0,00"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        identifiedElement(in: app, identifier: "dashboard-budget-edit").tap()
        identifiedElement(in: app, identifier: "monthly-budget-remove").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-budget-edit").waitForExistence(timeout: 5))
        XCTAssertFalse(identifiedElement(in: app, identifier: "dashboard-budget-margin").exists)
    }

    func testBankHomeHasTrajectoryAndBudgetExplanation() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        identifiedElement(in: app, identifier: "bank-institution-row-mock").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        identifiedElement(in: app, identifier: "dashboard-budget-edit").tap()
        let amount = identifiedElement(in: app, identifier: "monthly-budget-amount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("1500")
        identifiedElement(in: app, identifier: "monthly-budget-save").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-budget-margin").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-spending-trajectory").exists)
        capture(name: "native-home-bank-budget")
        identifiedElement(in: app, identifier: "dashboard-budget-margin").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "monthly-budget-explained-margin").waitForExistence(timeout: 5))
        capture(name: "native-home-margin-explanation")
    }

    func testZeroCategoryLimitRemainsVisibleWithoutSpending() {
        let app = launchEmptyApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-spending")
        identifiedElement(in: app, identifier: "budgets-edit-menu").tap()
        app.buttons["Courses"].tap()
        let amount = identifiedElement(in: app, identifier: "budget-form-amount-field")
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("0")
        app.buttons["budget-form-save-button"].tap()
        let row = identifiedElement(in: app, identifier: "budget-row-groceries")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        waitForScreen(in: app, identifier: "operations-screen")
        XCTAssertTrue(identifiedElement(in: app, identifier: "operations-empty").exists)
    }

    func testFiveDestinationsAndSecondaryHabits() {
        let app = launchSeededApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-operations")
        waitForScreen(in: app, identifier: "operations-screen")
        openRootTab(in: app, identifier: "root-tab-spending")
        waitForScreen(in: app, identifier: "budgets-screen")
        openRootTab(in: app, identifier: "root-tab-goals")
        waitForScreen(in: app, identifier: "goals-list")
        openRootTab(in: app, identifier: "root-tab-accounts")
        waitForScreen(in: app, identifier: "accounts-screen")
        XCTAssertFalse(identifiedElement(in: app, identifier: "accounts-direction-picker").exists)
        openRootTab(in: app, identifier: "root-tab-today")
        identifiedElement(in: app, identifier: "dashboard-more-menu").tap()
        identifiedElement(in: app, identifier: "dashboard-habits-menu").tap()
        XCTAssertTrue(app.buttons["habits-add-button"].waitForExistence(timeout: 5))
        capture(name: "product-secondary-habits")
    }

    func testAccountHistoryAndGlobalOperationsHaveSeparateDestinations() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5)); mock.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        openRootTab(in: app, identifier: "root-tab-accounts")
        let account = identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash")
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertFalse(identifiedElement(in: app, identifier: "accounts-direction-picker").exists)
        capture(name: "product-accounts")
        account.tap()
        waitForScreen(in: app, identifier: "account-history-screen")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z").waitForExistence(timeout: 5))
        capture(name: "product-account-history")
        openRootTab(in: app, identifier: "root-tab-operations")
        waitForScreen(in: app, identifier: "operations-screen")
        XCTAssertTrue(app.searchFields.firstMatch.exists)
    }

    func testGoalReservationAppearsInAllowanceExplanation() {
        let app = launchSeededApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-goals")
        let goal = identifiedElement(in: app, identifier: "goal-row-\(SeedIdentifiers.summerVacationGoal)")
        XCTAssertTrue(goal.waitForExistence(timeout: 5)); goal.tap()
        XCTAssertTrue(app.textFields["goal-form-title-field"].waitForExistence(timeout: 5))
        let amount = identifiedElement(in: app, identifier: "goal-reservation-amount")
        for _ in 0..<7 where !amount.isHittable { app.swipeUp() }
        XCTAssertTrue(amount.isHittable); amount.tap(); amount.typeText("25")
        let reserve = identifiedElement(in: app, identifier: "goal-reserve")
        for _ in 0..<3 where !reserve.isHittable { app.swipeUp() }
        reserve.tap()
        capture(name: "product-goal-reserved")
        app.buttons["goal-form-save-button"].tap()
        openRootTab(in: app, identifier: "root-tab-spending")
        identifiedElement(in: app, identifier: "budget-allowance-explanation").tap()
        waitForScreen(in: app, identifier: "allowance-explanation-screen")
        let reservedValue = app.staticTexts["allowance-goal-reservations-value"]
        XCTAssertTrue(reservedValue.waitForExistence(timeout: 5))
        assertReserved(reservedValue, equals: "25,00€")
        capture(name: "product-allowance")

        openRootTab(in: app, identifier: "root-tab-goals")
        goal.tap()
        XCTAssertTrue(app.textFields["goal-form-title-field"].waitForExistence(timeout: 5))
        for _ in 0..<7 where !amount.isHittable { app.swipeUp() }
        XCTAssertTrue(amount.isHittable)
        amount.tap(); amount.typeText("10")
        let release = identifiedElement(in: app, identifier: "goal-release")
        for _ in 0..<3 where !release.isHittable { app.swipeUp() }
        XCTAssertTrue(release.isEnabled)
        release.tap()
        app.buttons["goal-form-save-button"].tap()
        openRootTab(in: app, identifier: "root-tab-spending")
        XCTAssertTrue(reservedValue.waitForExistence(timeout: 5))
        assertReserved(reservedValue, equals: "15,00€")
    }

    // LabeledContent merges the row title with its value into a single accessibility label
    // ("Réservé aux objectifs ce mois, 25,00 €"), so the amount is checked as the part after the separator.
    // Comparing the suffix with its comma keeps the assertion exact: 125,00 € would not match 25,00 €.
    private func assertReserved(
        _ element: XCUIElement,
        equals amount: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let label = element.label.filter { !$0.isWhitespace }
        XCTAssertTrue(
            label.hasSuffix("," + amount),
            "unexpected reserved amount label: \(element.label)",
            file: file,
            line: line
        )
    }
}
