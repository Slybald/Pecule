import XCTest

@MainActor
final class GoalAllocationUITests: PeculeUITestCase {
    @discardableResult
    private func reach(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = identifiedElement(in: app, identifier: identifier)
        for _ in 0..<40 {
            if element.exists && element.isHittable { return element }
            let above = element.exists && element.frame.maxY < app.frame.height * 0.35
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.35 : 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.55 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); return element
    }
    private func editor(in app: XCUIApplication) {
        openRootTab(in: app, identifier: "root-tab-goals")
        reach("goals-allocation", in: app).tap()
        reach("allocation-edit", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "allocation-capacity").waitForExistence(timeout: 5))
    }
    func testPreviewConfirmReorderReopenAndCancelFromBothDestinations() {
        let app = launchSeededApp(disableAnimations: true)
        editor(in: app)
        identifiedElement(in: app, identifier: "allocation-capacity").clearAndTypeText("300")
        let first = "allocation-down-99999999-9999-9999-9999-999999999999"
        reach(first, in: app)
        capture(name: "allocation-editor-priority")
        identifiedElement(in: app, identifier: first).tap()
        // Return to the proposal near the top, regardless of the current text size.
        for _ in 0..<12 {
            let button = identifiedElement(in: app, identifier: "allocation-distribute")
            if button.exists && button.isHittable { break }; app.swipeDown()
        }
        reach("allocation-distribute", in: app).tap()
        reach("allocation-preview", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "allocation-confirm").waitForExistence(timeout: 5))
        capture(name: "allocation-preview-summary")
        reach("allocation-date-" + SeedIdentifiers.summerVacationGoal, in: app)
        capture(name: "allocation-preview-dates")
        identifiedElement(in: app, identifier: "allocation-confirm").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "allocation-confirm").wait(for: \.exists, toEqual: false, timeout: 5))
        // The saved summary grows with Dynamic Type; its edit action can be below the fold.
        reach("allocation-edit", in: app).tap()
        let capacity = identifiedElement(in: app, identifier: "allocation-capacity")
        XCTAssertTrue(capacity.waitForExistence(timeout: 5))
        XCTAssertTrue((capacity.value as? String ?? "").contains("300"))
        capacity.clearAndTypeText("999")
        identifiedElement(in: app, identifier: "allocation-cancel").tap()
        openRootTab(in: app, identifier: "root-tab-spending")
        reach("budget-allocation", in: app).tap()
        reach("allocation-edit", in: app).tap()
        XCTAssertTrue(capacity.waitForExistence(timeout: 5))
        XCTAssertTrue((capacity.value as? String ?? "").contains("300"))
    }
    func testOverCapacityIsRejectedBeforeConfirmationAndEmptyGoalsCanBeCreated() {
        let app = launchSeededApp(disableAnimations: true)
        editor(in: app)
        identifiedElement(in: app, identifier: "allocation-capacity").clearAndTypeText("100")
        reach("allocation-amount-" + SeedIdentifiers.summerVacationGoal, in: app).clearAndTypeText("200")
        reach("allocation-preview", in: app).tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "allocation-error").waitForExistence(timeout: 5))
        XCTAssertFalse(identifiedElement(in: app, identifier: "allocation-confirm").exists)
        identifiedElement(in: app, identifier: "allocation-cancel").tap()
        XCTAssertFalse(identifiedElement(in: app, identifier: "allocation-saved-capacity").exists)
        app.terminate()
        let empty = launchEmptyApp(disableAnimations: true)
        openRootTab(in: empty, identifier: "root-tab-spending")
        reach("budget-allocation", in: empty).tap()
        reach("allocation-add-goal", in: empty).tap()
        XCTAssertTrue(identifiedElement(in: empty, identifier: "goal-form-title-field").waitForExistence(timeout: 5))
    }
}
