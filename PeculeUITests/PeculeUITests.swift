import XCTest

@MainActor
final class PeculeSmokeUITests: PeculeUITestCase {

    func testOperationsSearchFindsBankMovementAndFiltersCanBeCleared() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        openRootTab(in: app, identifier: "root-tab-accounts")
        identifiedElement(in: app, identifier: "accounts-operations-button").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "operations-screen").waitForExistence(timeout: 5))
        capture(name: "operations-before-search")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("carrefour")
        let count = identifiedElement(in: app, identifier: "operations-count")
        XCTAssertTrue(count.label.contains("1 opération"), count.label)
        capture(name: "operations-search-carrefour")
        identifiedElement(in: app, identifier: "operations-clear-filters").tap()
        XCTAssertTrue(count.label.contains("4 opérations"), count.label)
        identifiedElement(in: app, identifier: "operations-filters-button").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "operations-filters-apply").waitForExistence(timeout: 5))
        identifiedElement(in: app, identifier: "operations-filters-apply").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "operations-screen").waitForExistence(timeout: 5))
        search.tap()
        search.typeText("carrefour")
        let movement = app.staticTexts["CB CARREFOUR"].firstMatch
        for _ in 0..<4 where !movement.isHittable { app.swipeUp() }
        XCTAssertTrue(movement.isHittable)
        movement.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-detail").waitForExistence(timeout: 5))
        let note = identifiedElement(in: app, identifier: "transaction-note-field")
        for _ in 0..<6 where !note.isHittable { app.swipeUp() }
        XCTAssertTrue(note.isHittable)
        note.tap()
        note.typeText("Courses pour le week-end")
        let save = identifiedElement(in: app, identifier: "transaction-note-save")
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertFalse(save.isEnabled)
        capture(name: "operation-saved-note")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 where !movement.isHittable { app.swipeUp() }
        movement.tap()
        for _ in 0..<6 where !note.isHittable { app.swipeUp() }
        XCTAssertEqual(note.value as? String, "Courses pour le week-end")
    }

    func testLanguageSwitchRebuildsNavigationAndKeepsHealthUsable() {
        let app = launchSeededApp(disableAnimations: true)
        for (choice, expectedWeight) in [("Anglais", "30%"), ("French", "30 %")] {
            identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
            let picker = identifiedElement(in: app, identifier: "settings-language-picker")
            for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
            XCTAssertTrue(picker.isHittable)
            picker.tap()
            app.buttons[choice].tap()
            openDashboardAnalyses(in: app)
            let health = identifiedElement(in: app, identifier: "dashboard-metric-health")
            XCTAssertTrue(health.waitForExistence(timeout: 5))
            health.tap()
            let savings = identifiedElement(in: app, identifier: "health-component-savings")
            XCTAssertTrue(savings.waitForExistence(timeout: 5))
            XCTAssertTrue(savings.label.contains(expectedWeight), savings.label)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testUnlinkingBankWhilePurchaseDetailIsOpenDoesNotKeepDeletedTransaction() {
        verifyUnlinkingBankWhileDetailIsOpen(showLinkPicker: false)
    }

    func testUnlinkingBankWhileLinkPickerIsOpenDoesNotKeepDeletedTransaction() {
        verifyUnlinkingBankWhileDetailIsOpen(showLinkPicker: true)
    }

    private func verifyUnlinkingBankWhileDetailIsOpen(showLinkPicker: Bool) {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()
        let account = identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash")
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        openSpendingSegment(in: app, "purchases")
        let transaction = identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z")
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        transaction.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-detail").waitForExistence(timeout: 5))
        if showLinkPicker {
            // The detail form grew (instalments, notes, provenance): the link row is lazily built below the fold.
            XCTAssertTrue(scrollUntilExists(in: app, identifier: "bank-transaction-link-button"))
            identifiedElement(in: app, identifier: "bank-transaction-link-button").tap()
            XCTAssertTrue(identifiedElement(in: app, identifier: "bank-link-picker").waitForExistence(timeout: 5))
        }
        openRootTab(in: app, identifier: "root-tab-today")
        account.swipeLeft()
        identifiedElement(in: app, identifier: "bank-account-unlink-stub-identification-hash").tap()
        confirmUnlink(in: app)
        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-bank-accounts-empty").waitForExistence(timeout: 5))
        openRootTab(in: app, identifier: "root-tab-spending")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(transaction.exists, "A deleted bank transaction must not remain editable")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-unavailable").exists || identifiedElement(in: app, identifier: "purchases-empty-state").exists)
    }

    // Délier un compte supprime ses opérations, leurs notes et leurs corrections : le glissement ne suffit plus,
    // la boîte de dialogue doit être confirmée.
    private func confirmUnlink(in app: XCUIApplication) {
        let confirm = identifiedElement(in: app, identifier: "bank-account-unlink-confirm-button")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "la confirmation de la suppression n'apparaît pas")
        confirm.tap()
    }

    func testCancellingTheUnlinkConfirmationKeepsTheAccount() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()
        let account = identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash")
        XCTAssertTrue(account.waitForExistence(timeout: 10))

        account.swipeLeft()
        identifiedElement(in: app, identifier: "bank-account-unlink-stub-identification-hash").tap()
        let cancel = identifiedElement(in: app, identifier: "bank-account-unlink-cancel-button")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "la confirmation de la suppression n'apparaît pas")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-unlink-confirm-button").exists)
        // La phrase dit ce qui sera perdu : le compte, ses 4 opérations de démonstration et, parce que c'est le
        // dernier compte de son lien, la révocation du consentement.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Titulaire démo")).firstMatch.exists, alert.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4 opérations")).firstMatch.exists, alert.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "consentement bancaire sera révoqué")).firstMatch.exists, alert.debugDescription)
        cancel.tap()

        XCTAssertTrue(cancel.wait(for: \.exists, toEqual: false, timeout: 5), "la confirmation doit se refermer")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 5))
        XCTAssertFalse(identifiedElement(in: app, identifier: "settings-bank-accounts-empty").exists, "annuler ne supprime rien")
    }

    func testRemainingDashboardMetricsOpenTheirDestinations() {
        for (metric, screen) in [("income", "income-screen"), ("remaining-to-live", "budgets-screen"), ("daily-allowance", "cashflow-screen")] {
            let app = launchSeededApp(disableAnimations: true)
            openDashboardAnalyses(in: app)
            identifiedElement(in: app, identifier: "dashboard-metric-\(metric)").tap()
            XCTAssertTrue(identifiedElement(in: app, identifier: screen).waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testDashboardGoalSnapshotOpensExistingGoalForEditing() {
        let app = launchSeededApp(disableAnimations: true)
        expandDashboardDetails(in: app)
        let goal = identifiedElement(in: app, identifier: "dashboard-goal-\(SeedIdentifiers.summerVacationGoal)")
        for _ in 0..<8 where !goal.isHittable { app.swipeUp() }
        XCTAssertTrue(goal.isHittable)
        goal.tap()
        XCTAssertTrue(app.textFields["goal-form-title-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["goal-form-title-field"].value as? String, "Summer Vacation")
        app.buttons["goal-form-cancel-button"].tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "goals-list").waitForExistence(timeout: 5))
    }

    func testDashboardRecommendationOpensExistingSubscriptionForEditing() {
        let app = launchSeededApp(disableAnimations: true)
        expandDashboardDetails(in: app)
        let recommendation = identifiedElement(in: app, identifier: "dashboard-recommendation-0")
        for _ in 0..<8 where !recommendation.isHittable { app.swipeUp() }
        XCTAssertTrue(recommendation.isHittable)
        recommendation.tap()
        XCTAssertTrue(app.textFields["subscription-form-name-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["subscription-form-name-field"].value as? String, "Netflix")
        app.buttons["subscription-form-cancel-button"].tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "subscriptions-list").waitForExistence(timeout: 5))
    }

    func testFinancialHealthAdviceAfterBankLinkAndHighExpensesSurvivesNavigationAndResume() {
        let app = launchBankStressApp()
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))

        openSpendingSegment(in: app, "purchases")
        identifiedElement(in: app, identifier: "purchases-add-button").tap()
        app.textFields["purchase-form-title-field"].clearAndTypeText("Dépense test stabilité")
        app.textFields["purchase-form-amount-field"].clearAndTypeText("1000")
        app.textFields["purchase-form-merchant-field"].clearAndTypeText("Commerce test")
        let purchaseSave = app.buttons["purchase-form-save-button"]
        XCTAssertTrue(purchaseSave.isEnabled)
        purchaseSave.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "purchases-add-button").waitForExistence(timeout: 5))

        openSpendingSegment(in: app, "subscriptions")
        identifiedElement(in: app, identifier: "subscriptions-add-button").tap()
        app.textFields["subscription-form-name-field"].clearAndTypeText("Charge test stabilité")
        app.textFields["subscription-form-amount-field"].clearAndTypeText("700")
        let subscriptionSave = app.buttons["subscription-form-save-button"]
        XCTAssertTrue(subscriptionSave.isEnabled)
        subscriptionSave.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "subscriptions-add-button").waitForExistence(timeout: 5))

        openRootTab(in: app, identifier: "root-tab-today")
        app.navigationBars.buttons.element(boundBy: 0).tap() // Settings → dashboard.
        openDashboardAnalyses(in: app)
        for iteration in 0..<3 {
            identifiedElement(in: app, identifier: "dashboard-metric-health").tap()
            XCTAssertTrue(identifiedElement(in: app, identifier: "health-screen").waitForExistence(timeout: 5))
            for (kind, expected) in [("savings", "20 %"), ("fixedCharges", "35 %"), ("margin", "15 %"), ("cushion", "3 mois")] {
                let component = identifiedElement(in: app, identifier: "health-component-\(kind)")
                XCTAssertTrue(component.exists)
                XCTAssertTrue(component.label.contains(expected), "Missing advice for \(kind): \(component.label)")
                XCTAssertFalse(component.label.contains("health.advice."))
            }
            if iteration == 0 { capture(name: "financial-health-all-advice-branches") }
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(identifiedElement(in: app, identifier: "health-screen").waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        capture(name: "dashboard-after-health-stability-check")
    }

    func testDashboardMetricsOpenTheirDestinations() {
        let app = launchSeededApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-metric-monthly-spending").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "budgets-screen").waitForExistence(timeout: 5))
        openSpendingSegment(in: app, "subscriptions")
        XCTAssertTrue(identifiedElement(in: app, identifier: "subscriptions-list").waitForExistence(timeout: 5))
        openSpendingSegment(in: app, "purchases")
        XCTAssertTrue(identifiedElement(in: app, identifier: "purchases-list").waitForExistence(timeout: 5))
    }

    func testEmptyInstallShowsBankPurchasesAfterLinkAndOpensTheirDetail() {
        let app = launchEmptyApp(disableAnimations: true)
        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mock = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))
        openSpendingSegment(in: app, "purchases")
        let transaction = identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z")
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Running Shoes"].exists)
        transaction.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-detail").waitForExistence(timeout: 5))
        capture(name: "bank-purchase-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        identifiedElement(in: app, identifier: "spending-month-previous").tap()
        XCTAssertFalse(identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z").exists)
        identifiedElement(in: app, identifier: "spending-month-next").tap()
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        capture(name: "bank-purchases-current-month")
        openRootTab(in: app, identifier: "root-tab-today")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openIncomeScreen(in: app)
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#eo28j").waitForExistence(timeout: 5))
    }

    func testDashboardDisplaysRealDataMetricCards() {
        let app = launchSeededApp()

        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-budget-edit").exists)
        XCTAssertFalse(identifiedElement(in: app, identifier: "dashboard-metric-health").exists)
        openDashboardAnalyses(in: app)

        XCTAssertFalse(identifiedElement(in: app, identifier: "dashboard-metric-total-subscriptions").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-monthly-spending").exists)
        XCTAssertFalse(identifiedElement(in: app, identifier: "dashboard-metric-purchases-logged").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-income").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-remaining-to-live").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-daily-allowance").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-cashflow").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-metric-health").exists)

        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-ai-advisor-card").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-insights-section").exists)
        expandDashboardDetails(in: app)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-recommendations-section").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-billing-schedule-section").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "dashboard-goals-snapshot-section").exists)
    }

    func testCashflowScreenOpensFromDashboard() {
        let app = launchSeededApp()

        openDashboardAnalyses(in: app)
        identifiedElement(in: app, identifier: "dashboard-metric-cashflow").tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "cashflow-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "cashflow-expected").exists)
    }

    func testFinancialHealthScreenOpensFromDashboard() {
        let app = launchSeededApp()

        openDashboardAnalyses(in: app)
        identifiedElement(in: app, identifier: "dashboard-metric-health").tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "health-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "health-grade").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "health-component-savings").exists)
    }

    func testInsightCardOpensItsScreen() {
        let app = launchSeededApp()

        openDashboardAnalyses(in: app)
        // The seeded data leads with the savings-rate insight, which routes to the cash-flow screen.
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "dashboard-insight-0"))
        identifiedElement(in: app, identifier: "dashboard-insight-0").tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "cashflow-screen").waitForExistence(timeout: 5))
    }

    func testSettingsExportsACSVFile() {
        let app = launchSeededApp()

        identifiedElement(in: app, identifier: "dashboard-settings-button").tap()
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "settings-export-csv-button"))
        identifiedElement(in: app, identifier: "settings-export-csv-button").tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "export-share-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "export-file-name").exists)
    }

    func testSettingsIsReachableFromDashboard() {
        let app = launchSeededApp()

        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-screen").waitForExistence(timeout: 5))
    }

    func testSettingsLinksStubBankAccountAndShowsBalance() {
        let app = launchSeededApp()
        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-bank-accounts-section").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-bank-accounts-empty").exists)

        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mockInstitution = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mockInstitution.waitForExistence(timeout: 5))
        mockInstitution.tap()

        let stableIdentifier = "stub-identification-hash"
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-\(stableIdentifier)").waitForExistence(timeout: 10))
        let balance = identifiedElement(in: app, identifier: "bank-account-balance-\(stableIdentifier)")
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertTrue(balance.label.contains("53"), "unexpected balance label: \(balance.label)")
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-status-\(stableIdentifier)").exists)
        XCTAssertFalse(identifiedElement(in: app, identifier: "settings-bank-accounts-empty").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "settings-bank-refresh-button").exists)
    }

    func testBudgetsScreenSetsAMonthlyBudgetFromSettings() {
        let app = launchSeededApp()
        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        identifiedElement(in: app, identifier: "settings-budgets-button").tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "budgets-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "budgets-summary").exists)

        // A category with neither spending nor a limit no longer occupies a row.
        // Create its limit first, then verify the route from the visible category.
        identifiedElement(in: app, identifier: "budgets-edit-menu").tap()
        app.buttons["Courses"].tap()

        let amountField = identifiedElement(in: app, identifier: "budget-form-amount-field")
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("250")
        let saveButton = identifiedElement(in: app, identifier: "budget-form-save-button")
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        let amountLabel = identifiedElement(in: app, identifier: "budget-amount-groceries")
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "budget-amount-groceries"))
        XCTAssertTrue(amountLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(amountLabel.label.contains("250"), "unexpected amount label: \(amountLabel.label)")
        let groceriesRow = identifiedElement(in: app, identifier: "budget-row-groceries")
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "budget-row-groceries"))
        groceriesRow.tap()
        // En mode manuel, la ligne ouvre les lignes du plan du mois (m094), dont la somme est le montant affiché ;
        // Opérations n'est la destination qu'en mode bancaire (voir ProductEvolutionUITests).
        XCTAssertTrue(identifiedElement(in: app, identifier: "budget-lines-total").waitForExistence(timeout: 5))
    }

    func testSettingsAddsManualAccountIncludedInTotal() {
        let app = launchSeededApp()
        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        identifiedElement(in: app, identifier: "settings-bank-add-manual-button").tap()
        let nameField = identifiedElement(in: app, identifier: "manual-account-form-name-field")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Livret Jeune")
        let balanceField = identifiedElement(in: app, identifier: "manual-account-form-balance-field")
        balanceField.tap()
        balanceField.typeText("383")
        let saveButton = identifiedElement(in: app, identifier: "manual-account-form-save-button")
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "bank-account-row-manual:"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "383")).firstMatch.exists)
    }

    func testAccountsScreenOpensOnlyTheSelectedAccountHistory() {
        let app = launchSeededApp()
        let settingsButton = app.buttons["dashboard-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        identifiedElement(in: app, identifier: "settings-bank-link-button").tap()
        let mockInstitution = identifiedElement(in: app, identifier: "bank-institution-row-mock")
        XCTAssertTrue(mockInstitution.waitForExistence(timeout: 5))
        mockInstitution.tap()
        XCTAssertTrue(identifiedElement(in: app, identifier: "bank-account-row-stub-identification-hash").waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let accountsButton = app.buttons["dashboard-accounts-button"]
        XCTAssertTrue(accountsButton.waitForExistence(timeout: 5))
        accountsButton.tap()

        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-screen").waitForExistence(timeout: 5))
        let totalBalance = identifiedElement(in: app, identifier: "accounts-total-balance")
        XCTAssertTrue(totalBalance.waitForExistence(timeout: 5))
        XCTAssertTrue(totalBalance.label.contains("53"), "unexpected total: \(totalBalance.label)")
        XCTAssertTrue(identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash").exists)
        XCTAssertFalse(identifiedElement(in: app, identifier: "accounts-direction-picker").exists)
        XCTAssertFalse(identifiedElement(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z").exists)
        identifiedElement(in: app, identifier: "accounts-card-stub-identification-hash").tap()
        waitForScreen(in: app, identifier: "account-history-screen")
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "bank-transaction-row-stub-identification-hash#dkx1z"))
        XCTAssertTrue(scrollUntilExists(in: app, identifier: "bank-transaction-row-stub-identification-hash#eo28j"))
    }

    // Lazy lists only materialise visible cells; scroll a few times before giving up.
    private func scrollUntilExists(in app: XCUIApplication, identifier: String, attempts: Int = 4) -> Bool {
        for _ in 0 ..< attempts {
            if identifiedElement(in: app, identifier: identifier).waitForExistence(timeout: 2) {
                return true
            }
            app.swipeUp()
        }
        return identifiedElement(in: app, identifier: identifier).exists
    }

    func testIncomeIsReachableFromDashboard() {
        let app = launchSeededApp()

        openIncomeScreen(in: app)

        XCTAssertTrue(identifiedElement(in: app, identifier: "income-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-summary-card").exists)
        XCTAssertTrue(identifiedElement(in: app, identifier: "income-summary-source").exists, "the card says whether the amounts come from the bank or the plan")
        XCTAssertTrue(
            identifiedElement(
                in: app,
                identifier: "income-source-row-\(SeedIdentifiers.salaryIncomeSource)"
            ).exists
        )

        // The seeded override belongs to March 2026 while the screen opens on the current month.
        let overrideRow = identifiedElement(in: app, identifier: "income-override-row-\(SeedIdentifiers.monthlySalaryOverride)")
        var remainingSteps = 36
        while !overrideRow.exists && remainingSteps > 0 {
            identifiedElement(in: app, identifier: "income-previous-month-button").tap()
            remainingSteps -= 1
        }
        XCTAssertTrue(overrideRow.exists)
    }

    func testTabNavigationAcrossRootScreens() {
        let app = launchSeededApp()

        XCTAssertTrue(app.buttons["dashboard-settings-button"].waitForExistence(timeout: 5))

        openSpendingSegment(in: app, "subscriptions")
        XCTAssertTrue(app.buttons["subscriptions-add-button"].waitForExistence(timeout: 5))

        openSpendingSegment(in: app, "purchases")
        XCTAssertTrue(app.buttons["purchases-add-button"].waitForExistence(timeout: 5))

        openRootTab(in: app, identifier: "root-tab-goals")
        XCTAssertTrue(app.buttons["goals-add-button"].waitForExistence(timeout: 5))

        openRootTab(in: app, identifier: "root-tab-habits")
        XCTAssertTrue(app.buttons["habits-add-button"].waitForExistence(timeout: 5))
    }

    func testSubscriptionsCrudSurfaceIsReachable() {
        let app = launchSeededApp()

        openSpendingSegment(in: app, "subscriptions")

        let addButton = app.buttons["subscriptions-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        let netflixRow = identifiedElement(
            in: app,
            identifier: "subscription-row-\(SeedIdentifiers.netflixSubscription)"
        )
        XCTAssertTrue(netflixRow.waitForExistence(timeout: 5))

        addButton.tap()
        XCTAssertTrue(app.buttons["subscription-form-save-button"].waitForExistence(timeout: 5))
        app.buttons["subscription-form-cancel-button"].tap()

        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        let gymPassRow = identifiedElement(
            in: app,
            identifier: "subscription-row-\(SeedIdentifiers.gymPassSubscription)"
        )
        XCTAssertTrue(gymPassRow.waitForExistence(timeout: 5))
    }

    func testSubscriptionFormValidationShowsInlineErrorsAndEnablesSaveWhenValid() {
        let app = launchSeededApp()

        openSpendingSegment(in: app, "subscriptions")

        let addButton = app.buttons["subscriptions-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["subscription-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["subscription-form-cancel-button"].tap()
    }

    func testPurchasesCrudSurfaceIsReachable() {
        let app = launchSeededApp()

        openSpendingSegment(in: app, "purchases")

        let addButton = app.buttons["purchases-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        let identifiedSegmentedControl = app.segmentedControls["purchases-sort-picker"]
        let segmentedControl = identifiedSegmentedControl.exists
            ? identifiedSegmentedControl
            : app.segmentedControls.firstMatch
        XCTAssertTrue(segmentedControl.waitForExistence(timeout: 5))
        segmentedControl.buttons.element(boundBy: 1).tap()

        addButton.tap()
        XCTAssertTrue(app.buttons["purchase-form-save-button"].waitForExistence(timeout: 5))
        app.buttons["purchase-form-cancel-button"].tap()

        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        let runningShoesRow = identifiedElement(
            in: app,
            identifier: "purchase-row-\(SeedIdentifiers.runningShoesPurchase)"
        )
        XCTAssertTrue(runningShoesRow.waitForExistence(timeout: 5))
        runningShoesRow.tap()

        let editButton = app.buttons["purchase-detail-edit-button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement(in: app, identifier: "purchase-detail-screen").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        segmentedControl.buttons.element(boundBy: 0).tap()

        let groceriesRow = identifiedElement(
            in: app,
            identifier: "purchase-row-\(SeedIdentifiers.groceriesPurchase)"
        )
        XCTAssertTrue(groceriesRow.waitForExistence(timeout: 5))
    }

    // Rouvrir un achat à centimes puis l'enregistrer sans toucher au montant le tronquait en français : le champ était
    // prérempli en « 12.5 », que la locale fr relisait « 12 » (12,50 € devenait 12,00 €, sans aucun message).
    func testReopeningAPurchaseWithCentsAndSavingItUnchangedKeepsItsAmount() {
        let app = launchEmptyApp(disableAnimations: true)
        openSpendingSegment(in: app, "purchases")

        let addButton = app.buttons["purchases-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        app.textFields["purchase-form-title-field"].clearAndTypeText("Courses du marché")
        app.textFields["purchase-form-amount-field"].clearAndTypeText("12,50")
        app.textFields["purchase-form-merchant-field"].clearAndTypeText("Marché")
        let createSaveButton = app.buttons["purchase-form-save-button"]
        XCTAssertTrue(createSaveButton.isEnabled)
        createSaveButton.tap()

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "purchase-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(compactText(of: row).contains("12,50€"), "montant créé absent de la ligne : \(row.label)")
        row.tap()

        let editButton = app.buttons["purchase-detail-edit-button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()
        let amountField = app.textFields["purchase-form-amount-field"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        XCTAssertEqual(amountField.value as? String, "12,5", "le champ rouvert doit porter le montant exact, en notation française")
        let editSaveButton = app.buttons["purchase-form-save-button"]
        XCTAssertTrue(editSaveButton.isEnabled)
        editSaveButton.tap()
        XCTAssertTrue(editSaveButton.waitForNonExistence(timeout: 5), "la feuille d'édition doit se fermer")

        XCTAssertTrue(app.buttons["purchase-detail-edit-button"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowText = compactText(of: row)
        XCTAssertTrue(rowText.contains("12,50€"), "la ligne doit toujours afficher 12,50 € : \(row.label)")
        XCTAssertFalse(rowText.contains("12,00€"), "le montant a été tronqué : \(row.label)")
    }

    // La ligne d'un achat, sans espace : son libellé fusionné et les textes qu'elle contient. Les montants français
    // portent une espace insécable avant « € », d'où le retrait de toutes les espaces avant de comparer.
    private func compactText(of element: XCUIElement) -> String {
        ([element.label] + element.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: "|")
            .filter { !$0.isWhitespace }
    }

    func testPurchaseFormValidationRequiresMerchantBeforeSave() {
        let app = launchSeededApp()

        openSpendingSegment(in: app, "purchases")

        let addButton = app.buttons["purchases-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["purchase-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["purchase-form-cancel-button"].tap()
    }

    func testGoalsCrudSurfaceIsReachable() {
        let app = launchSeededApp()

        openRootTab(in: app, identifier: "root-tab-goals")

        let addButton = app.buttons["goals-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["goal-row-\(SeedIdentifiers.summerVacationGoal)"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            identifiedElement(in: app, identifier: "archived-goal-row-CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
                .waitForExistence(timeout: 5)
        )

        addButton.tap()
        XCTAssertTrue(app.buttons["goal-form-save-button"].waitForExistence(timeout: 5))
        app.buttons["goal-form-cancel-button"].tap()

        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
    }

    // Un glissement ne supprime plus rien tout seul : il demande confirmation, et « Annuler » garde l'objectif.
    func testSwipeDeletingAGoalAsksForConfirmationAndCanBeCancelled() {
        let app = launchSeededApp(disableAnimations: true)
        openRootTab(in: app, identifier: "root-tab-goals")
        let row = app.buttons["goal-row-\(SeedIdentifiers.summerVacationGoal)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.swipeLeft()
        identifiedElement(in: app, identifier: "goals-delete-button").tap()
        let cancel = identifiedElement(in: app, identifier: "delete-cancel-button")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "la confirmation de la suppression n'apparaît pas")
        cancel.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "annuler doit garder l'objectif")

        row.swipeLeft()
        identifiedElement(in: app, identifier: "goals-delete-button").tap()
        let confirm = identifiedElement(in: app, identifier: "delete-confirm-button")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "confirmer doit supprimer l'objectif")
    }

    func testGoalFormValidationAllowsCurrentAmountAboveTargetAmount() {
        let app = launchSeededApp()

        openRootTab(in: app, identifier: "root-tab-goals")

        let addButton = app.buttons["goals-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["goal-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["goal-form-cancel-button"].tap()
    }

    func testHabitsCrudSurfaceIsReachable() {
        let app = launchSeededApp()

        openRootTab(in: app, identifier: "root-tab-habits")

        let addButton = app.buttons["habits-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            identifiedElement(in: app, identifier: "habit-row-\(SeedIdentifiers.noSpendDayHabit)")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            identifiedElement(in: app, identifier: "inactive-habit-row-\(SeedIdentifiers.reviewSubscriptionsHabit)")
                .waitForExistence(timeout: 5)
        )

        addButton.tap()
        XCTAssertTrue(app.buttons["habit-form-save-button"].waitForExistence(timeout: 5))
        app.buttons["habit-form-cancel-button"].tap()

        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            identifiedElement(in: app, identifier: "inactive-habit-row-\(SeedIdentifiers.reviewSubscriptionsHabit)")
                .exists
        )
    }

    func testHabitFormValidationRequiresTitle() {
        let app = launchSeededApp()

        openRootTab(in: app, identifier: "root-tab-habits")

        let addButton = app.buttons["habits-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["habit-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)

        let titleField = app.textFields["habit-form-title-field"]
        titleField.tap()
        titleField.typeText("Read 10 pages")

        XCTAssertTrue(saveButton.isEnabled)
        app.buttons["habit-form-cancel-button"].tap()
    }

    func testEmptyModeDisplaysDashboardEmptyState() {
        let app = launchEmptyApp()

        waitForScreen(in: app, identifier: "dashboard-empty-state")
    }

    func testEmptyModeDisplaysIncomeEmptyState() {
        let app = launchEmptyApp()

        openIncomeScreen(in: app)
        waitForScreen(in: app, identifier: "income-empty-state")
        XCTAssertTrue(app.buttons["income-add-source-button"].exists)
    }

    func testEmptyModeDisplaysSubscriptionsEmptyState() {
        let app = launchEmptyApp()

        openSpendingSegment(in: app, "subscriptions")
        waitForScreen(in: app, identifier: "subscriptions-empty-state")
        XCTAssertTrue(app.buttons["subscriptions-add-button"].exists)
    }

    func testEmptyModeDisplaysPurchasesEmptyState() {
        let app = launchEmptyApp()

        openSpendingSegment(in: app, "purchases")
        waitForScreen(in: app, identifier: "purchases-empty-state")
        XCTAssertTrue(app.buttons["purchases-add-button"].exists)
    }

    func testEmptyModeDisplaysGoalsEmptyState() {
        let app = launchEmptyApp()

        openRootTab(in: app, identifier: "root-tab-goals")
        waitForScreen(in: app, identifier: "goals-empty-state")
        XCTAssertTrue(app.buttons["goals-add-button"].exists)
    }

    func testEmptyModeDisplaysHabitsEmptyState() {
        let app = launchEmptyApp()

        openRootTab(in: app, identifier: "root-tab-habits")
        waitForScreen(in: app, identifier: "habits-empty-state")
        XCTAssertTrue(app.buttons["habits-add-button"].exists)
    }

    func testIncomeSourceFormValidationShowsDisabledSaveWhenInvalid() {
        let app = launchSeededApp()

        openIncomeScreen(in: app)

        let addButton = app.buttons["income-add-source-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["income-source-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["income-source-form-cancel-button"].tap()
    }

    func testMonthlyIncomeOverrideFormValidationShowsDisabledSaveWhenInvalid() {
        let app = launchSeededApp()

        openIncomeScreen(in: app)

        let addButton = app.buttons["income-add-override-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["income-override-form-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["income-override-form-cancel-button"].tap()
    }
}
