import XCTest
@testable import Pecule

@MainActor
final class PeculeTests: XCTestCase {
    private enum DecimalParseError: Error {
        case invalidValue(String)
    }
    nonisolated(unsafe) private var previousLanguageCode: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousLanguageCode = UserDefaults.standard.string(forKey: LocalizationManager.userDefaultsKey)
        UserDefaults.standard.set("en", forKey: LocalizationManager.userDefaultsKey)
    }

    override func tearDownWithError() throws {
        if let previousLanguageCode {
            UserDefaults.standard.set(previousLanguageCode, forKey: LocalizationManager.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.userDefaultsKey)
        }

        try super.tearDownWithError()
    }

    private func decimal(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Decimal {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            XCTFail("Unable to parse decimal literal: \(value)", file: file, line: line)
            throw DecimalParseError.invalidValue(value)
        }

        return decimal
    }

    private func localized(_ key: String) -> String {
        AppLocalizer.string(key, locale: LocalizationManager.currentAppLocale)
    }

    private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(key),
            locale: LocalizationManager.currentAppLocale,
            arguments: arguments
        )
    }

    private func makeDataStore() throws -> PeculeDataStore {
        let container = try PeculeDataStore.makeInMemoryContainer()
        return PeculeDataStore(container: container)
    }

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func fixedReferenceDate() -> Date {
        let calendar = fixedCalendar()

        return calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 14,
                hour: 12
            )
        ) ?? Date()
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        let calendar = fixedCalendar()

        return calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: 12
            )
        ) ?? Date()
    }

    private func removeSeededIncomeData(from state: AppState) throws {
        let existingOverrides = state.monthlyIncomeOverrides
        let existingSources = state.incomeSources

        for monthlyIncomeOverride in existingOverrides {
            try state.deleteMonthlyIncomeOverride(monthlyIncomeOverride)
        }

        for incomeSource in existingSources {
            try state.deleteIncomeSource(incomeSource)
        }
    }

    func testAppLocalizerUsesRequestedLanguageBundle() {
        XCTAssertEqual(
            AppLocalizer.string("tab.dashboard", locale: Locale(identifier: "en_FR")),
            "Dashboard"
        )
        XCTAssertEqual(
            AppLocalizer.string("tab.dashboard", locale: Locale(identifier: "fr_FR")),
            "Tableau de bord"
        )
    }

    func testFinancialHealthAdviceFormatsLiteralPercentInBothLanguages() {
        let french = Locale(identifier: "fr_FR")
        XCTAssertEqual(
            AppLocalizer.format("health.advice.savings %@", locale: french, "150 €"),
            "Mets 150 € de plus de côté chaque mois pour atteindre 20 % d'épargne."
        )
        XCTAssertEqual(AppLocalizer.format("health.weight %lld", locale: french, 30), "30 %")
        XCTAssertEqual(
            AppLocalizer.format("health.advice.savings %@", locale: Locale(identifier: "en_US"), "€150"),
            "Set aside €150 more each month to reach 20% savings."
        )
        XCTAssertEqual(AppLocalizer.format("health.weight %lld", locale: Locale(identifier: "en_US"), Int64(30)), "30%")
        // Exercise the overload using the current app language as well.
        XCTAssertEqual(AppLocalizer.format("health.weight %lld", 25), "25%")
    }

    func testLocalizerRejectsUnsafeFormatsWithoutReadingCVarargs() {
        let locale = Locale(identifier: "fr_FR")
        for template in ["Mets %1$@ pour atteindre 20 % d'épargne.", "%@ %s", "%n", "%", "%0$@", "%2$@", "%999999999999999999999$@", "%f"] {
            XCTAssertNil(AppLocalizer.render(template, locale: locale, arguments: ["150 €"]), template)
        }
        XCTAssertNil(AppLocalizer.render("%@", locale: locale, arguments: [42]))
        XCTAssertNil(AppLocalizer.render("%lld", locale: locale, arguments: ["wrong type"]))
        XCTAssertNil(AppLocalizer.render("%@ %@", locale: locale, arguments: ["missing argument"]))
        XCTAssertNil(AppLocalizer.render("%@", locale: locale, arguments: ["one", "extra"]))
        XCTAssertEqual(AppLocalizer.format("health.advice.savings %@", locale: locale, 42), "health.advice.savings %@")
        XCTAssertEqual(AppLocalizer.render("%2$@ : %1$lld %%", locale: locale, arguments: [Int64(30), "Poids"]), "Poids : 30 %")
        XCTAssertEqual(AppLocalizer.render("%@", locale: locale, arguments: ["20 % d'épargne %n"]), "20 % d'épargne %n")
    }

    func testEveryLocalizedFormatMatchesItsArgumentsAndFoundationOutput() throws {
        let placeholder = try NSRegularExpression(pattern: "%(@|lld)")
        for language in ["en", "fr"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            let strings = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            let locale = Locale(identifier: language)
            var checked = 0
            for (key, template) in strings where key.contains("%") {
                let matches = placeholder.matches(in: key, range: NSRange(key.startIndex..., in: key))
                let arguments: [CVarArg] = matches.enumerated().map { index, match in
                    (key as NSString).substring(with: match.range) == "%@"
                        ? "value \(index)" as CVarArg : Int64(41 + index) as CVarArg
                }
                guard let rendered = AppLocalizer.render(template, locale: locale, arguments: arguments) else {
                    XCTFail("Unsafe or unsupported localized format: \(language), \(key): \(template)")
                    continue
                }
                // Only compare with Foundation after type/count/syntax validation; otherwise
                // the reference call itself would reproduce EXC_BAD_ACCESS.
                XCTAssertEqual(rendered, String(format: template, locale: locale, arguments: arguments), "\(language): \(key)")
                checked += 1
            }
            // Three untranslated extraction-only keys are not emitted into the compiled .strings.
            XCTAssertGreaterThanOrEqual(checked, 76, "All translated catalogue format entries must be exercised")
        }
    }

    func testExpenseCategoryMapsLegacyAndNormalizedValues() {
        XCTAssertEqual(ExpenseCategory(matching: "Streaming"), .subscriptions)
        XCTAssertEqual(ExpenseCategory(matching: "subscriptions"), .subscriptions)
        XCTAssertEqual(ExpenseCategory(matching: "Food"), .groceries)
        XCTAssertEqual(ExpenseCategory(matching: "Essence"), .fuel)
        XCTAssertEqual(ExpenseCategory(matching: "Learning"), .education)
        XCTAssertNil(ExpenseCategory(matching: "Pets"))
    }

    func testExpenseCategoryFormValueStandardizesKnownValuesAndPreservesUnknownValues() {
        XCTAssertEqual(ExpenseCategory.formStorageValue(for: "Streaming"), "Subscriptions")
        XCTAssertEqual(ExpenseCategory.formStorageValue(for: " subscriptions "), "Subscriptions")
        XCTAssertEqual(ExpenseCategory.formStorageValue(for: " Pets "), "Pets")
        XCTAssertEqual(ExpenseCategory.formStorageValue(for: nil), "Other")
    }

    func testExpenseCategoryCanonicalBudgetHelpersPreserveUnknownCategories() {
        XCTAssertEqual(ExpenseCategory.canonicalStorageValue(for: "Food"), "Groceries")
        XCTAssertEqual(ExpenseCategory.canonicalStorageValue(for: "Essence"), "Fuel")
        XCTAssertEqual(ExpenseCategory.canonicalStorageValue(for: "Streaming"), "Subscriptions")
        XCTAssertEqual(ExpenseCategory.canonicalStorageValue(for: "Pets"), "Pets")
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: "Food"), "groceries")
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: "Pets"), ExpenseCategory.custom("Pets").id)
    }

    func testTypedCategoryInitializersStoreReadableValues() throws {
        let purchase = Purchase(
            title: "Fuel stop",
            amount: try decimal("65.20"),
            date: fixedReferenceDate(),
            category: .fuel,
            merchant: "Station One",
            notes: nil
        )
        let subscription = Subscription(
            name: "Netflix",
            amount: try decimal("15.99"),
            billingCycle: .monthly,
            category: .subscriptions,
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        XCTAssertEqual(purchase.category, "Fuel")
        XCTAssertEqual(purchase.normalizedCategoryKey, "fuel")
        XCTAssertEqual(purchase.categoryDisplayName(locale: Locale(identifier: "en_US")), "Fuel")
        XCTAssertEqual(subscription.category, "Subscriptions")
        XCTAssertEqual(subscription.normalizedCategoryKey, "subscriptions")
        XCTAssertEqual(subscription.categoryDisplayName(locale: Locale(identifier: "fr_FR")), "Abonnements")
    }

    func testSeedDataCategoriesExposeNormalizedCategories() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        XCTAssertEqual(
            state.subscriptions.first(where: { $0.name == "Netflix" })?.normalizedCategory,
            .subscriptions
        )
        XCTAssertEqual(
            state.subscriptions.first(where: { $0.name == "Gym Pass" })?.normalizedCategory,
            .health
        )
        XCTAssertEqual(
            state.purchases.first(where: { $0.title == "Coffee Maker" })?.normalizedCategory,
            .housing
        )
        XCTAssertEqual(
            state.purchases.first(where: { $0.title == "Groceries" })?.normalizedCategory,
            .groceries
        )
    }

    func testSubscriptionAnalyzerAnnualTotalMatchesSeedData() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let analyzer = SubscriptionAnalyzerService()

        XCTAssertEqual(analyzer.annualTotal(for: state.subscriptions), try decimal("347.76"))
        XCTAssertEqual(state.annualSubscriptionCost, try decimal("347.76"))
    }

    func testSubscriptionAnalyzerDetectsExpensiveSubscriptionsOnSeedData() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let analyzer = SubscriptionAnalyzerService()

        XCTAssertEqual(analyzer.expensiveSubscriptions(in: state.subscriptions).map(\.name), ["Netflix"])
        XCTAssertEqual(state.expensiveSubscriptions.map(\.name), ["Netflix"])
    }

    func testSubscriptionAnalyzerDuplicateGroupsAreEmptyOnSeedData() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let analyzer = SubscriptionAnalyzerService()

        XCTAssertTrue(analyzer.duplicateGroups(in: state.subscriptions).isEmpty)
        XCTAssertTrue(state.duplicateSubscriptionGroups.isEmpty)
    }

    func testAddingDuplicateSubscriptionUpdatesAnalyzerCollections() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.addSubscription(
            name: " Netflix ",
            amount: try decimal("8.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 2)) ?? Date(),
            isActive: true
        )

        XCTAssertEqual(state.duplicateSubscriptionGroups.count, 1)
        XCTAssertEqual(state.duplicateSubscriptionGroups.first?.map(\.name), ["Netflix", "Netflix"])
    }

    func testAddingExpensiveSubscriptionUpdatesAnalyzerCollections() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.addSubscription(
            name: "YouTube Premium",
            amount: try decimal("16.50"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 19)) ?? Date(),
            isActive: true
        )

        XCTAssertEqual(state.expensiveSubscriptions.map(\.name), ["YouTube Premium", "Netflix"])
        XCTAssertEqual(state.annualSubscriptionCost, try decimal("545.76"))
    }

    func testFinancialCalculatorCostPerDayRoundsExpectedValue() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let coffeeMaker = state.purchases.first(where: { $0.title == "Coffee Maker" }) else {
            XCTFail("Expected Coffee Maker seed purchase.")
            return
        }

        XCTAssertEqual(calculator.costPerDay(coffeeMaker), try decimal("2.66"))
    }

    func testFinancialCalculatorCostPerMonthSupportsMonthlyAndYearlySubscriptions() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) else {
            XCTFail("Expected Netflix seed subscription.")
            return
        }

        guard let gymPass = state.subscriptions.first(where: { $0.name == "Gym Pass" }) else {
            XCTFail("Expected Gym Pass seed subscription.")
            return
        }

        XCTAssertEqual(calculator.costPerMonth(netflix), try decimal("15.99"))
        XCTAssertEqual(calculator.costPerMonth(gymPass), try decimal("10.00"))
    }

    func testFinancialCalculatorLifetimeCostSupportsMonthlyAndYearlySubscriptions() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) else {
            XCTFail("Expected Netflix seed subscription.")
            return
        }

        guard let gymPass = state.subscriptions.first(where: { $0.name == "Gym Pass" }) else {
            XCTFail("Expected Gym Pass seed subscription.")
            return
        }

        XCTAssertEqual(calculator.lifetimeCost(netflix, years: 3), try decimal("575.64"))
        XCTAssertEqual(calculator.lifetimeCost(gymPass, years: 3), try decimal("360.00"))
    }

    func testFinancialCalculatorLifetimeCostReturnsZeroWhenYearsAreNotPositive() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) else {
            XCTFail("Expected Netflix seed subscription.")
            return
        }

        XCTAssertEqual(calculator.lifetimeCost(netflix, years: 0), .zero)
        XCTAssertEqual(calculator.lifetimeCost(netflix, years: -1), .zero)
    }

    func testFinancialCalculatorCostPerYearSupportsMonthlyAndYearlySubscriptions() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) else {
            XCTFail("Expected Netflix seed subscription.")
            return
        }

        guard let gymPass = state.subscriptions.first(where: { $0.name == "Gym Pass" }) else {
            XCTFail("Expected Gym Pass seed subscription.")
            return
        }

        XCTAssertEqual(calculator.costPerYear(netflix), try decimal("191.88"))
        XCTAssertEqual(calculator.costPerYear(gymPass), try decimal("120.00"))
    }

    func testFinancialCalculatorCostOverTimeSupportsExpectedMonthHorizons() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let coffeeMaker = state.purchases.first(where: { $0.title == "Coffee Maker" }) else {
            XCTFail("Expected Coffee Maker seed purchase.")
            return
        }

        XCTAssertEqual(calculator.costOverTime(coffeeMaker, months: 1), try decimal("79.90"))
        XCTAssertEqual(calculator.costOverTime(coffeeMaker, months: 6), try decimal("479.40"))
        XCTAssertEqual(calculator.costOverTime(coffeeMaker, months: 12), try decimal("958.80"))
    }

    func testFinancialCalculatorCostOverTimeReturnsZeroWhenMonthsAreNotPositive() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let calculator = FinancialCalculatorService()

        guard let groceries = state.purchases.first(where: { $0.title == "Groceries" }) else {
            XCTFail("Expected Groceries seed purchase.")
            return
        }

        XCTAssertEqual(calculator.costOverTime(groceries, months: 0), .zero)
        XCTAssertEqual(calculator.costOverTime(groceries, months: -3), .zero)
    }

    func testSeedIfNeededPopulatesEmptyStore() throws {
        let dataStore = try makeDataStore()

        try dataStore.seedIfNeeded()
        let snapshot = try dataStore.loadSnapshot()

        XCTAssertEqual(snapshot.subscriptions.count, 4)
        XCTAssertEqual(snapshot.purchases.count, 4)
        XCTAssertEqual(snapshot.goals.count, 4)
        XCTAssertEqual(snapshot.habits.count, 3)
        XCTAssertEqual(snapshot.incomeSources.count, 3)
        XCTAssertEqual(snapshot.monthlyIncomeOverrides.count, 1)
    }

    func testDashboardMetricsMatchSeedData() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        XCTAssertEqual(state.activeSubscriptionsCount, 3)
        XCTAssertEqual(state.monthlySubscriptionCost, try decimal("28.98"))
        XCTAssertEqual(state.purchaseCount, 4)
        XCTAssertEqual(state.totalPurchaseAmount, try decimal("316.70"))
        XCTAssertEqual(state.overallGoalProgress, 2000.0 / 7700.0, accuracy: 0.0001)
    }

    func testDashboardInsightsMatchSeedDataDeterministically() throws {
        let insightsService = InsightsService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, insightsService: insightsService)

        XCTAssertEqual(state.dashboardInsights.count, 5)
        XCTAssertEqual(
            state.dashboardInsights.map(\.title),
            [
                localized("insights.savingsRate.title"),
                localized("Recent Purchase"),
                localized("Goal Progress"),
                localized("Habit Progress"),
                localized("Subscription Spending")
            ],
            "money insights lead; the active-subscriptions summary drops out of the top five"
        )
        XCTAssertEqual(state.dashboardInsights[0].type, .positive)
        XCTAssertTrue(state.dashboardInsights[1].message.contains("Running Shoes"))
        XCTAssertTrue(state.dashboardInsights[2].message.contains("Summer Vacation"))
        XCTAssertEqual(state.dashboardInsights[3].type, .warning)
        XCTAssertEqual(state.dashboardInsights[3].optionalValue, "2/4")
    }

    func testInsightsServiceLimitsResultsToFiveAndAvoidsDuplicateSubscriptionSpendingMessages() throws {
        let insightsService = InsightsService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, insightsService: insightsService)

        try state.addSubscription(
            name: "YouTube Premium",
            amount: try decimal("12.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        let subscriptionSpendingInsights = state.dashboardInsights.filter { $0.title == localized("Subscription Spending") }

        XCTAssertLessThanOrEqual(state.dashboardInsights.count, 5)
        XCTAssertEqual(subscriptionSpendingInsights.count, 1)
        XCTAssertEqual(subscriptionSpendingInsights.first?.type, .warning)
    }

    func testInsightsServiceUsesProjectedPurchaseCostForRecentPurchaseWarning() throws {
        let insightsService = InsightsService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, insightsService: insightsService)
        let calculator = FinancialCalculatorService()

        guard let runningShoes = state.purchases.first(where: { $0.title == "Running Shoes" }) else {
            XCTFail("Expected Running Shoes seed purchase.")
            return
        }

        let expectedProjectedCost = Formatters.currencyString(for: calculator.costOverTime(runningShoes, months: 12))
        let purchaseInsight = state.dashboardInsights.first(where: { $0.title == localized("Recent Purchase") })

        XCTAssertEqual(purchaseInsight?.optionalValue, expectedProjectedCost)
        XCTAssertTrue(purchaseInsight?.message.contains("Running Shoes") == true)
    }

    func testInsightsServicePrioritizesCloseGoalOverLowGoal() throws {
        let insightsService = InsightsService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, insightsService: insightsService)

        guard let summerVacation = state.goals.first(where: { $0.title == "Summer Vacation" }) else {
            XCTFail("Expected Summer Vacation seed goal.")
            return
        }

        summerVacation.currentAmount = try decimal("1400.00")

        let goalInsights = state.dashboardInsights.filter { $0.title == localized("Goal Progress") }
        let expectedProgressValue = Formatters.percentString(for: summerVacation.progress)

        XCTAssertEqual(goalInsights.count, 1)
        XCTAssertEqual(goalInsights.first?.type, .positive)
        XCTAssertTrue(goalInsights.first?.message.contains("Summer Vacation") == true)
        XCTAssertEqual(goalInsights.first?.optionalValue, expectedProgressValue)
    }

    func testInsightsServiceReturnsNoInsightsForEmptyState() throws {
        let insightsService = InsightsService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, insightsService: insightsService)

        state.subscriptions = []
        state.purchases = []
        state.goals = []
        state.habits = []

        XCTAssertTrue(state.dashboardInsights.isEmpty)
    }

    func testSeedIfNeededDoesNotReseedExistingStore() throws {
        let dataStore = try makeDataStore()

        try dataStore.seedIfNeeded()
        try dataStore.seedIfNeeded()

        let snapshot = try dataStore.loadSnapshot()

        XCTAssertEqual(snapshot.subscriptions.count, 4)
        XCTAssertEqual(snapshot.purchases.count, 4)
        XCTAssertEqual(snapshot.goals.count, 4)
        XCTAssertEqual(snapshot.habits.count, 3)
        XCTAssertEqual(snapshot.incomeSources.count, 3)
        XCTAssertEqual(snapshot.monthlyIncomeOverrides.count, 1)
    }

    func testDerivedCollectionsStayConsistent() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        XCTAssertEqual(state.upcomingSubscriptions(on: TestFixtures.date(2026, 3, 1)).map(\.name), ["iCloud+", "Netflix", "Gym Pass"])
        XCTAssertEqual(state.recentPurchases.map(\.title), ["Groceries", "Desk Lamp", "Running Shoes", "Coffee Maker"])
        XCTAssertEqual(state.highestAmountPurchases.map(\.title), ["Running Shoes", "Coffee Maker", "Groceries", "Desk Lamp"])
        XCTAssertEqual(state.displaySubscriptions.map(\.name), ["iCloud+", "Netflix", "Gym Pass", "Apple Music"])
        XCTAssertEqual(state.activeGoals.map(\.title), ["Summer Vacation", "Next iPhone", "Emergency Fund"])
        XCTAssertEqual(state.archivedGoals.map(\.title), ["Course Budget"])
        XCTAssertEqual(state.activeHabits.map(\.title), ["No-spend day", "Transfer to savings"])
        XCTAssertEqual(state.inactiveHabits.map(\.title), ["Review subscriptions"])
        XCTAssertEqual(state.goalTitle(for: state.activeHabits.last?.linkedGoalID), "Emergency Fund")
        XCTAssertEqual(state.activeHabits.first?.progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func testSeededIncomeHelpersResolveCurrentMonthSummary() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let month = makeDate(year: 2026, month: 3, day: 15)
        let summary = state.monthlyFinancialSummary(for: month)

        XCTAssertEqual(state.monthlyIncomeOverrides(for: month).count, 1)
        XCTAssertEqual(summary.recurringIncome, try decimal("2710.00"))
        XCTAssertEqual(summary.monthlyIncomeAdjustments, try decimal("250.00"))
        XCTAssertEqual(summary.totalEstimatedIncome, try decimal("2960.00"))
    }

    func testAddSubscriptionUpdatesCollectionsAndMetrics() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.addSubscription(
            name: "YouTube Premium",
            amount: try decimal("12.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 19)) ?? Date(),
            isActive: true
        )

        XCTAssertEqual(state.subscriptions.count, 5)
        XCTAssertEqual(state.activeSubscriptionsCount, 4)
        XCTAssertEqual(state.monthlySubscriptionCost, try decimal("41.97"))
        XCTAssertEqual(state.displaySubscriptions.map(\.name), ["iCloud+", "YouTube Premium", "Netflix", "Gym Pass", "Apple Music"])
        XCTAssertEqual(state.upcomingSubscriptions(on: TestFixtures.date(2026, 3, 1)).map(\.name), ["iCloud+", "YouTube Premium", "Netflix", "Gym Pass"])
    }

    func testUpdateSubscriptionPersistsChanges() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let appleMusic = state.subscriptions.first(where: { $0.name == "Apple Music" }) else {
            XCTFail("Expected Apple Music seed subscription.")
            return
        }

        try state.updateSubscription(
            appleMusic,
            name: "Apple Music",
            amount: try decimal("11.49"),
            billingCycle: .monthly,
            category: "Music",
            nextBillingDate: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 17)) ?? Date(),
            isActive: true
        )

        XCTAssertEqual(state.activeSubscriptionsCount, 4)
        XCTAssertEqual(state.monthlySubscriptionCost, try decimal("40.47"))
        XCTAssertEqual(state.displaySubscriptions.map(\.name), ["Apple Music", "iCloud+", "Netflix", "Gym Pass"])
        XCTAssertEqual(state.upcomingSubscriptions(on: TestFixtures.date(2026, 3, 1)).map(\.name), ["Apple Music", "iCloud+", "Netflix", "Gym Pass"])
    }

    func testDeleteSubscriptionRemovesItemAndRefreshesMetrics() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) else {
            XCTFail("Expected Netflix seed subscription.")
            return
        }

        try state.deleteSubscription(netflix)

        XCTAssertEqual(state.subscriptions.count, 3)
        XCTAssertEqual(state.activeSubscriptionsCount, 2)
        XCTAssertEqual(state.monthlySubscriptionCost, try decimal("12.99"))
        XCTAssertEqual(state.displaySubscriptions.map(\.name), ["iCloud+", "Gym Pass", "Apple Music"])
        XCTAssertEqual(state.upcomingSubscriptions(on: TestFixtures.date(2026, 3, 1)).map(\.name), ["iCloud+", "Gym Pass"])
    }

    func testAddPurchaseUpdatesCollectionsAndMetrics() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.addPurchase(
            title: "Headphones",
            amount: try decimal("199.99"),
            date: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 13)) ?? Date(),
            category: "Tech",
            merchant: "Audio Lab",
            notes: "Noise cancelling."
        )

        XCTAssertEqual(state.purchaseCount, 5)
        XCTAssertEqual(state.totalPurchaseAmount, try decimal("516.69"))
        XCTAssertEqual(state.recentPurchases.first?.title, "Headphones")
        XCTAssertEqual(state.highestAmountPurchases.first?.title, "Headphones")
    }

    func testUpdatePurchasePersistsChanges() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let coffeeMaker = state.purchases.first(where: { $0.title == "Coffee Maker" }) else {
            XCTFail("Expected Coffee Maker seed purchase.")
            return
        }

        try state.updatePurchase(
            coffeeMaker,
            title: "Coffee Maker",
            amount: try decimal("149.90"),
            date: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 13)) ?? Date(),
            category: "Home",
            merchant: "Maison Store",
            notes: "Updated purchase."
        )

        XCTAssertEqual(state.purchaseCount, 4)
        XCTAssertEqual(state.totalPurchaseAmount, try decimal("386.70"))
        XCTAssertEqual(state.recentPurchases.first?.title, "Coffee Maker")
        XCTAssertEqual(state.highestAmountPurchases.first?.title, "Coffee Maker")
    }

    func testDeletePurchaseRemovesItemAndRefreshesMetrics() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let groceries = state.purchases.first(where: { $0.title == "Groceries" }) else {
            XCTFail("Expected Groceries seed purchase.")
            return
        }

        try state.deletePurchase(groceries)

        XCTAssertEqual(state.purchaseCount, 3)
        XCTAssertEqual(state.totalPurchaseAmount, try decimal("254.40"))
        XCTAssertEqual(state.recentPurchases.map(\.title), ["Desk Lamp", "Running Shoes", "Coffee Maker"])
        XCTAssertEqual(state.highestAmountPurchases.map(\.title), ["Running Shoes", "Coffee Maker", "Desk Lamp"])
    }

    func testAddGoalUpdatesCollectionsAndProgress() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.addGoal(
            title: "Home Office Setup",
            targetAmount: try decimal("800.00"),
            currentAmount: try decimal("200.00"),
            targetDate: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 15)) ?? Date(),
            category: "Work"
        )

        XCTAssertEqual(state.goals.count, 5)
        XCTAssertEqual(state.activeGoals.map(\.title), ["Home Office Setup", "Summer Vacation", "Next iPhone", "Emergency Fund"])
        XCTAssertEqual(state.archivedGoals.map(\.title), ["Course Budget"])
        XCTAssertEqual(state.goals.first(where: { $0.title == "Home Office Setup" })?.isArchived, false)
        XCTAssertEqual(state.overallGoalProgress, 2200.0 / 8500.0, accuracy: 0.0001)
    }

    func testUpdateGoalPersistsChangesAndKeepsArchiveState() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let summerVacation = state.goals.first(where: { $0.title == "Summer Vacation" }) else {
            XCTFail("Expected Summer Vacation seed goal.")
            return
        }

        try state.updateGoal(
            summerVacation,
            title: "Summer Vacation",
            targetAmount: try decimal("1800.00"),
            currentAmount: try decimal("900.00"),
            targetDate: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15)) ?? Date(),
            category: "Travel"
        )

        XCTAssertEqual(state.goals.count, 4)
        XCTAssertEqual(state.activeGoals.map(\.title), ["Summer Vacation", "Next iPhone", "Emergency Fund"])
        XCTAssertEqual(state.goals.first(where: { $0.title == "Summer Vacation" })?.isArchived, false)
        XCTAssertEqual(state.archivedGoals.map(\.title), ["Course Budget"])
        XCTAssertEqual(state.overallGoalProgress, 2450.0 / 8000.0, accuracy: 0.0001)
    }

    func testDeleteGoalRemovesItemAndRefreshesProgress() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let nextIPhone = state.goals.first(where: { $0.title == "Next iPhone" }) else {
            XCTFail("Expected Next iPhone seed goal.")
            return
        }

        try state.deleteGoal(nextIPhone)

        XCTAssertEqual(state.goals.count, 3)
        XCTAssertEqual(state.activeGoals.map(\.title), ["Summer Vacation", "Emergency Fund"])
        XCTAssertEqual(state.archivedGoals.map(\.title), ["Course Budget"])
        XCTAssertEqual(state.overallGoalProgress, 1700.0 / 6500.0, accuracy: 0.0001)
    }

    func testAddHabitCreatesActiveHabitAndLinksGoal() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        let linkedGoalID = state.activeGoals.first?.id

        try state.addHabit(
            title: "Morning stretch",
            frequency: .daily,
            targetCount: 7,
            completedCount: 2,
            linkedGoalID: linkedGoalID
        )

        XCTAssertEqual(state.habits.count, 4)
        XCTAssertEqual(state.activeHabits.map(\.title), ["Morning stretch", "No-spend day", "Transfer to savings"])
        XCTAssertEqual(state.inactiveHabits.map(\.title), ["Review subscriptions"])
        XCTAssertEqual(state.habits.first(where: { $0.title == "Morning stretch" })?.isActive, true)
        XCTAssertEqual(state.goalTitle(for: linkedGoalID), "Summer Vacation")
    }

    func testUpdateHabitPersistsChangesAndKeepsActiveState() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let noSpendDay = state.habits.first(where: { $0.title == "No-spend day" }) else {
            XCTFail("Expected No-spend day seed habit.")
            return
        }

        try state.updateHabit(
            noSpendDay,
            title: "No-spend streak",
            frequency: .weekly,
            targetCount: 5,
            completedCount: 4,
            linkedGoalID: state.activeGoals.last?.id
        )

        XCTAssertEqual(state.activeHabits.map(\.title), ["No-spend streak", "Transfer to savings"])
        XCTAssertEqual(state.habits.first(where: { $0.title == "No-spend streak" })?.isActive, true)
        XCTAssertEqual(state.habits.first(where: { $0.title == "No-spend streak" })?.progress ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(state.goalTitle(for: state.habits.first(where: { $0.title == "No-spend streak" })?.linkedGoalID), "Emergency Fund")
    }

    func testHabitCanLinkToArchivedGoalAndKeepReadableTitle() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let noSpendDay = state.habits.first(where: { $0.title == "No-spend day" }) else {
            XCTFail("Expected No-spend day seed habit.")
            return
        }

        guard let archivedGoalID = state.archivedGoals.first?.id else {
            XCTFail("Expected archived goal seed data.")
            return
        }

        try state.updateHabit(
            noSpendDay,
            title: "No-spend day",
            frequency: .daily,
            targetCount: 4,
            completedCount: 2,
            linkedGoalID: archivedGoalID
        )

        XCTAssertEqual(state.goalTitle(for: archivedGoalID), "Course Budget")
        XCTAssertEqual(state.habits.first(where: { $0.title == "No-spend day" })?.linkedGoalID, archivedGoalID)
    }

    func testMarkHabitCompletedCapsAtTargetCount() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        guard let noSpendDay = state.habits.first(where: { $0.title == "No-spend day" }) else {
            XCTFail("Expected No-spend day seed habit.")
            return
        }

        try state.markHabitCompleted(noSpendDay)
        XCTAssertEqual(state.activeHabits.first(where: { $0.title == "No-spend day" })?.completedCount, 3)
        XCTAssertEqual(state.activeHabits.first(where: { $0.title == "No-spend day" })?.progress ?? -1, 0.75, accuracy: 0.0001)

        guard let transferToSavings = state.habits.first(where: { $0.title == "Transfer to savings" }) else {
            XCTFail("Expected Transfer to savings seed habit.")
            return
        }

        try state.markHabitCompleted(transferToSavings)
        XCTAssertEqual(state.activeHabits.first(where: { $0.title == "Transfer to savings" })?.completedCount, 1)
        XCTAssertEqual(state.activeHabits.first(where: { $0.title == "Transfer to savings" })?.progress ?? -1, 1.0, accuracy: 0.0001)
    }

    func testAddIncomeSourceUpdatesDerivedCollections() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: " Main salary ",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        try state.addIncomeSource(
            name: " Mobility support ",
            amount: try decimal("120.00"),
            type: .mobility,
            startDate: makeDate(year: 2026, month: 4, day: 10),
            endDate: nil,
            isRecurring: false,
            isActive: true
        )

        try state.addIncomeSource(
            name: "Dormant aid",
            amount: try decimal("80.00"),
            type: .aid,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: false
        )

        XCTAssertEqual(state.incomeSources.count, 3)
        XCTAssertEqual(state.activeIncomeSources.map(\.name), ["Main salary", "Mobility support"])
        XCTAssertEqual(state.recurringIncomeSources.map(\.name), ["Main salary"])
        XCTAssertEqual(
            state.activeIncomeSources(in: makeDate(year: 2026, month: 4, day: 15)).map(\.name),
            ["Main salary", "Mobility support"]
        )
        XCTAssertEqual(
            state.activeIncomeSources(in: makeDate(year: 2026, month: 5, day: 15)).map(\.name),
            ["Main salary"]
        )
    }

    func testUpdateIncomeSourcePersistsChanges() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.updateIncomeSource(
            salary,
            name: "Updated Salary",
            amount: try decimal("2450.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: makeDate(year: 2026, month: 5, day: 31),
            isRecurring: true,
            isActive: true
        )

        guard let updatedSalary = state.incomeSources.first(where: { $0.name == "Updated Salary" }) else {
            XCTFail("Expected updated salary income source.")
            return
        }

        XCTAssertEqual(updatedSalary.amount, try decimal("2450.00"))
        XCTAssertEqual(updatedSalary.endDate, makeDate(year: 2026, month: 5, day: 31))
        XCTAssertEqual(
            state.activeIncomeSources(in: makeDate(year: 2026, month: 6, day: 1)).map(\.name),
            []
        )
    }

    func testMonthlyIncomeOverrideResolvesAdjustmentAndReplacementAmounts() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 4, day: 20),
            amount: try decimal("-200.00"),
            replacesSourceAmount: false
        )

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 5, day: 12),
            amount: try decimal("2500.00"),
            replacesSourceAmount: true
        )

        XCTAssertEqual(state.monthlyIncomeOverrides.count, 2)
        XCTAssertEqual(state.incomeOverrides.map(\.monthStartDate), [
            makeDate(year: 2026, month: 4, day: 1),
            makeDate(year: 2026, month: 5, day: 1)
        ])
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: salary, in: makeDate(year: 2026, month: 3, day: 15)),
            try decimal("2300.00")
        )
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: salary, in: makeDate(year: 2026, month: 4, day: 3)),
            try decimal("2100.00")
        )
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: salary, in: makeDate(year: 2026, month: 5, day: 3)),
            try decimal("2500.00")
        )
    }

    func testUpdateMonthlyIncomeOverridePersistsChanges() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 4, day: 10),
            amount: try decimal("-200.00"),
            replacesSourceAmount: false
        )

        guard let monthlyIncomeOverride = state.monthlyIncomeOverrides.first else {
            XCTFail("Expected monthly income override.")
            return
        }

        try state.updateMonthlyIncomeOverride(
            monthlyIncomeOverride,
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 4, day: 25),
            amount: try decimal("2600.00"),
            replacesSourceAmount: true
        )

        guard let updatedOverride = state.monthlyIncomeOverrides.first else {
            XCTFail("Expected updated monthly income override.")
            return
        }

        XCTAssertEqual(state.monthlyIncomeOverrides.count, 1)
        XCTAssertEqual(updatedOverride.monthStartDate, makeDate(year: 2026, month: 4, day: 1))
        XCTAssertEqual(updatedOverride.amount, try decimal("2600.00"))
        XCTAssertEqual(updatedOverride.replacesSourceAmount, true)
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: salary, in: makeDate(year: 2026, month: 4, day: 4)),
            try decimal("2600.00")
        )
    }

    func testDeleteIncomeSourceRemovesLinkedMonthlyOverrides() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "Salary",
            amount: try decimal("2300.00"),
            type: .salary,
            startDate: makeDate(year: 2026, month: 3, day: 1),
            endDate: nil,
            isRecurring: true,
            isActive: true
        )

        guard let salary = state.incomeSources.first(where: { $0.name == "Salary" }) else {
            XCTFail("Expected salary income source.")
            return
        }

        try state.addMonthlyIncomeOverride(
            incomeSourceID: salary.id,
            month: makeDate(year: 2026, month: 4, day: 10),
            amount: try decimal("-200.00"),
            replacesSourceAmount: false
        )

        try state.deleteIncomeSource(salary)

        XCTAssertTrue(state.incomeSources.isEmpty)
        XCTAssertTrue(state.monthlyIncomeOverrides.isEmpty)
        XCTAssertTrue(state.incomeOverrides.isEmpty)
    }

    func testNonRecurringIncomeSourceAppliesToSingleMonthAndDeletingOverrideRestoresBaseAmount() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)
        try removeSeededIncomeData(from: state)

        try state.addIncomeSource(
            name: "One-off bonus",
            amount: try decimal("500.00"),
            type: .bonus,
            startDate: makeDate(year: 2026, month: 4, day: 5),
            endDate: nil,
            isRecurring: false,
            isActive: true
        )

        guard let bonus = state.incomeSources.first(where: { $0.name == "One-off bonus" }) else {
            XCTFail("Expected bonus income source.")
            return
        }

        XCTAssertNil(
            state.resolvedMonthlyIncomeAmount(for: bonus, in: makeDate(year: 2026, month: 3, day: 20))
        )
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: bonus, in: makeDate(year: 2026, month: 4, day: 20)),
            try decimal("500.00")
        )
        XCTAssertNil(
            state.resolvedMonthlyIncomeAmount(for: bonus, in: makeDate(year: 2026, month: 5, day: 1))
        )

        try state.addMonthlyIncomeOverride(
            incomeSourceID: bonus.id,
            month: makeDate(year: 2026, month: 4, day: 18),
            amount: try decimal("650.00"),
            replacesSourceAmount: true
        )

        guard let monthlyIncomeOverride = state.monthlyIncomeOverrides.first else {
            XCTFail("Expected monthly income override.")
            return
        }

        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: bonus, in: makeDate(year: 2026, month: 4, day: 20)),
            try decimal("650.00")
        )

        try state.deleteMonthlyIncomeOverride(monthlyIncomeOverride)

        XCTAssertTrue(state.monthlyIncomeOverrides.isEmpty)
        XCTAssertEqual(
            state.resolvedMonthlyIncomeAmount(for: bonus, in: makeDate(year: 2026, month: 4, day: 20)),
            try decimal("500.00")
        )
    }

    func testBudgetCategoriesExposeDefaultCatalogWithoutPersistedRules() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        XCTAssertTrue(state.budgetRules.isEmpty)
        XCTAssertTrue(state.budgetOverrides.isEmpty)
        XCTAssertEqual(state.budgetCategories, ExpenseCategory.budgetCategories)
        XCTAssertEqual(
            state.monthlyBudget(for: fixedReferenceDate(), calendar: fixedCalendar()),
            .zero
        )
    }

    func testSetBudgetRuleUpsertsCategoryAndFeedsEffectiveMonthlyBudget() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetRule(
            category: " Food ",
            monthlyAmount: try decimal("350.00")
        )
        try state.setBudgetRule(
            category: "Groceries",
            monthlyAmount: try decimal("425.00")
        )

        XCTAssertEqual(state.budgetRules.count, 1)
        XCTAssertEqual(state.budgetRules.first?.category, "Groceries")
        XCTAssertEqual(state.budgetRules.first?.monthlyAmount, try decimal("425.00"))
        XCTAssertEqual(
            state.budgetAmount(
                for: "Groceries",
                in: fixedReferenceDate(),
                calendar: fixedCalendar()
            ),
            try decimal("425.00")
        )
        XCTAssertEqual(
            state.monthlyBudget(for: fixedReferenceDate(), calendar: fixedCalendar()),
            try decimal("425.00")
        )
    }

    func testBudgetOverrideAppliesOnlyToTargetMonth() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetRule(
            category: "Essence",
            monthlyAmount: try decimal("400.00")
        )
        try state.setBudgetOverride(
            category: "Essence",
            month: makeDate(year: 2026, month: 3, day: 20),
            monthlyAmount: try decimal("500.00")
        )

        XCTAssertEqual(state.budgetOverrides.count, 1)
        XCTAssertEqual(state.budgetRules.first?.category, "Fuel")
        XCTAssertEqual(state.budgetOverrides.first?.category, "Fuel")
        XCTAssertEqual(
            state.budgetOverride(
                for: "Fuel",
                in: makeDate(year: 2026, month: 3, day: 1),
                calendar: fixedCalendar()
            )?.monthlyAmount,
            try decimal("500.00")
        )
        XCTAssertEqual(
            state.budgetAmount(
                for: "Fuel",
                in: makeDate(year: 2026, month: 3, day: 15),
                calendar: fixedCalendar()
            ),
            try decimal("500.00")
        )
        XCTAssertEqual(
            state.budgetAmount(
                for: "Fuel",
                in: makeDate(year: 2026, month: 4, day: 15),
                calendar: fixedCalendar()
            ),
            try decimal("400.00")
        )
    }

    func testUnknownBudgetCategoryIsPreservedSeparatelyFromOther() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetRule(
            category: "Pets",
            monthlyAmount: try decimal("90.00")
        )

        XCTAssertEqual(state.budgetRules.count, 1)
        XCTAssertEqual(state.budgetRules.first?.category, "Pets")
        XCTAssertEqual(
            state.budgetAmount(
                for: "Pets",
                in: fixedReferenceDate(),
                calendar: fixedCalendar()
            ),
            try decimal("90.00")
        )
        XCTAssertEqual(
            state.budgetAmount(
                for: "Other",
                in: fixedReferenceDate(),
                calendar: fixedCalendar()
            ),
            Decimal.zero
        )
    }

    func testSettingBudgetOverrideCreatesZeroBaseRuleWhenMissing() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetOverride(
            category: "Transport",
            month: makeDate(year: 2026, month: 8, day: 8),
            monthlyAmount: try decimal("180.00")
        )

        XCTAssertEqual(state.budgetRules.count, 1)
        XCTAssertEqual(state.budgetRule(for: "Transport")?.monthlyAmount, .zero)
        XCTAssertEqual(
            state.budgetAmount(
                for: "Transport",
                in: makeDate(year: 2026, month: 8, day: 15),
                calendar: fixedCalendar()
            ),
            try decimal("180.00")
        )
        XCTAssertEqual(
            state.budgetAmount(
                for: "Transport",
                in: makeDate(year: 2026, month: 9, day: 15),
                calendar: fixedCalendar()
            ),
            .zero
        )
    }

    func testDeletingBudgetRuleRemovesLinkedOverrides() throws {
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true)

        try state.setBudgetRule(
            category: "Transport",
            monthlyAmount: try decimal("120.00")
        )
        try state.setBudgetOverride(
            category: "Transport",
            month: makeDate(year: 2026, month: 4, day: 12),
            monthlyAmount: try decimal("180.00")
        )

        guard let budgetRule = state.budgetRule(for: "Transport") else {
            XCTFail("Expected transport budget rule.")
            return
        }

        try state.deleteBudgetRule(budgetRule)

        XCTAssertNil(state.budgetRule(for: "Transport"))
        XCTAssertTrue(state.budgetOverrides.isEmpty)
        XCTAssertEqual(
            state.budgetAmount(
                for: "Transport",
                in: makeDate(year: 2026, month: 4, day: 15),
                calendar: fixedCalendar()
            ),
            .zero
        )
    }

    // MARK: - RecommendationService Tests

    func testRecommendationsMatchSeedDataDeterministically() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        let recs = state.dashboardRecommendations

        XCTAssertEqual(recs.count, 3)
        XCTAssertEqual(
            recs.map(\.title),
            [
                localized("Expensive Subscription"),
                localized("Goal Behind Schedule"),
                localized("High-Cost Purchase")
            ]
        )
        XCTAssertEqual(recs[0].priority, .high)
        XCTAssertEqual(recs[1].priority, .medium)
        XCTAssertEqual(recs[2].priority, .low)
        XCTAssertTrue(recs[0].message.contains("Netflix"))
        XCTAssertTrue(recs[1].message.contains("Summer Vacation"))
        XCTAssertTrue(recs[2].message.contains("Running Shoes"))
    }

    func testRecommendationsLimitedToFive() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        // Add a duplicate to trigger duplicate rec
        try state.addSubscription(
            name: "Netflix",
            amount: try decimal("8.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        // Add expensive subscription
        try state.addSubscription(
            name: "YouTube Premium",
            amount: try decimal("16.50"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        // Link a habit with low progress to a goal
        guard let noSpendDay = state.habits.first(where: { $0.title == "No-spend day" }) else {
            XCTFail("Expected No-spend day seed habit.")
            return
        }

        try state.updateHabit(
            noSpendDay,
            title: "No-spend day",
            frequency: .daily,
            targetCount: 4,
            completedCount: 2,
            linkedGoalID: state.activeGoals.first?.id
        )

        XCTAssertLessThanOrEqual(state.dashboardRecommendations.count, 5)
    }

    func testDuplicateSubscriptionSuppressesExpensiveRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        try state.addSubscription(
            name: " Netflix ",
            amount: try decimal("8.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        let recs = state.dashboardRecommendations

        let duplicateRecs = recs.filter { $0.title == localized("Duplicate Subscriptions") }
        let expensiveRecs = recs.filter { $0.title == localized("Expensive Subscription") }

        XCTAssertEqual(duplicateRecs.count, 1)
        XCTAssertTrue(duplicateRecs.first?.message.contains("Netflix") == true)

        // Netflix should not appear as expensive since it's already in the duplicate group
        let expensiveNetflix = expensiveRecs.filter { $0.message.contains("Netflix") }
        XCTAssertTrue(expensiveNetflix.isEmpty)
    }

    func testCloseGoalReplacesWeakGoalRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        guard let summerVacation = state.goals.first(where: { $0.title == "Summer Vacation" }) else {
            XCTFail("Expected Summer Vacation seed goal.")
            return
        }

        summerVacation.currentAmount = try decimal("1400.00")

        let recs = state.dashboardRecommendations

        let closeGoalRecs = recs.filter { $0.title == localized("Goal Nearly Complete") }
        let weakGoalRecs = recs.filter { $0.title == localized("Goal Behind Schedule") }

        XCTAssertEqual(closeGoalRecs.count, 1)
        XCTAssertTrue(closeGoalRecs.first?.message.contains("Summer Vacation") == true)
        XCTAssertTrue(weakGoalRecs.isEmpty)
    }

    func testLinkedHabitRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        guard let noSpendDay = state.habits.first(where: { $0.title == "No-spend day" }) else {
            XCTFail("Expected No-spend day seed habit.")
            return
        }

        let emergencyFundID = state.goals.first(where: { $0.title == "Emergency Fund" })?.id

        try state.updateHabit(
            noSpendDay,
            title: "No-spend day",
            frequency: .daily,
            targetCount: 4,
            completedCount: 2,
            linkedGoalID: emergencyFundID
        )

        let recs = state.dashboardRecommendations
        let habitRecs = recs.filter { $0.title == localized("Habit Needs Attention") }

        XCTAssertEqual(habitRecs.count, 1)
        XCTAssertTrue(habitRecs.first?.message.contains("No-spend day") == true)
        XCTAssertTrue(habitRecs.first?.message.contains("Emergency Fund") == true)
        XCTAssertEqual(habitRecs.first?.estimatedImpact, localizedFormat("%lld remaining", Int64(2)))
    }

    func testExpensiveRecentPurchaseRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)
        let calculator = FinancialCalculatorService()

        guard let runningShoes = state.purchases.first(where: { $0.title == "Running Shoes" }) else {
            XCTFail("Expected Running Shoes seed purchase.")
            return
        }

        let expectedProjectedCost = Formatters.currencyString(for: calculator.costOverTime(runningShoes, months: 12))

        let recs = state.dashboardRecommendations
        let purchaseRecs = recs.filter { $0.title == localized("High-Cost Purchase") }

        XCTAssertEqual(purchaseRecs.count, 1)
        XCTAssertTrue(purchaseRecs.first?.message.contains("Running Shoes") == true)
        XCTAssertEqual(purchaseRecs.first?.estimatedImpact, expectedProjectedCost)
    }

    func testEmptyStateReturnsNoRecommendations() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        state.subscriptions = []
        state.purchases = []
        state.goals = []
        state.habits = []

        XCTAssertTrue(state.dashboardRecommendations.isEmpty)
    }

    func testHealthyStateReturnsPositiveRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        // Set all goals to healthy progress (>= 60%)
        for goal in state.goals {
            goal.currentAmount = goal.targetAmount * Decimal(0.7)
        }

        // Make all habits strong
        for habit in state.habits {
            habit.completedCount = habit.targetCount
        }

        // Remove expensive subscription (make monthly cost low)
        if let netflix = state.subscriptions.first(where: { $0.name == "Netflix" }) {
            try state.deleteSubscription(netflix)
        }

        // Remove expensive purchases by clearing them
        state.purchases = []

        let recs = state.dashboardRecommendations

        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.title, localized("Looking Good"))
        XCTAssertEqual(recs.first?.type, .positive)
        XCTAssertEqual(recs.first?.priority, .low)
    }

    func testWeakGoalWithOverpaidAmountDoesNotProduceNegativeContribution() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        guard let summerVacation = state.goals.first(where: { $0.title == "Summer Vacation" }) else {
            XCTFail("Expected Summer Vacation seed goal.")
            return
        }

        // currentAmount exceeds targetAmount but progress is capped at 1.0
        summerVacation.currentAmount = try decimal("2000.00")

        let recs = state.dashboardRecommendations

        // The overpaid goal should not appear as a weak goal recommendation
        let summerVacationRecs = recs.filter { $0.message.contains("Summer Vacation") && $0.title == localized("Goal Behind Schedule") }
        XCTAssertTrue(summerVacationRecs.isEmpty)

        // If a weak goal rec exists for another goal, its impact should be positive
        if let weakGoalRec = recs.first(where: { $0.title == localized("Goal Behind Schedule") }) {
            XCTAssertNotNil(weakGoalRec.estimatedImpact)
            // Ensure the impact doesn't contain a negative sign
            XCTAssertFalse(weakGoalRec.estimatedImpact?.contains("-") == true)
        }
    }

    func testAllGoalsArchivedProducesNoGoalRecommendation() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        for goal in state.goals {
            goal.isArchived = true
        }

        let recs = state.dashboardRecommendations
        let goalRecs = recs.filter { $0.type == .goal }

        XCTAssertTrue(goalRecs.isEmpty)
    }

    func testDataWithoutStrongSignalsAndWithoutHealthySignalsReturnsEmpty() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        // Remove subscriptions (no expensive, no duplicate, no lean signal)
        state.subscriptions = []

        // Remove purchases (no expensive recent purchase)
        state.purchases = []

        // Set goals to moderate progress (> 0.35 so no weak, < 0.60 so no strong signal, < 0.85 so no close)
        for goal in state.goals.filter({ !$0.isArchived }) {
            goal.currentAmount = goal.targetAmount * Decimal(0.5)
        }

        // Remove linked habits, set all to moderate progress
        for habit in state.habits {
            habit.linkedGoalID = nil
            habit.completedCount = habit.targetCount / 2
        }

        let recs = state.dashboardRecommendations

        XCTAssertTrue(recs.isEmpty)
    }

    func testWeakGoalContributionRoundsToMultipleOfFive() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        // Seed data: Summer Vacation has targetAmount=1500, currentAmount=450, targetDate=2026-07-01
        // referenceDate = 2026-03-14
        // remaining = 1050
        // months from 2026-03-01 to 2026-07-01 = 4
        // rawContribution = 1050 / 4 = 262.5
        // ceil(262.5 / 5) * 5 = 53 * 5 = 265
        let recs = state.dashboardRecommendations
        let weakGoalRec = recs.first(where: { $0.title == localized("Goal Behind Schedule") })

        XCTAssertNotNil(weakGoalRec)
        XCTAssertTrue(weakGoalRec?.message.contains("Summer Vacation") == true)

        let expectedContribution = Formatters.currencyString(for: Decimal(265))
        XCTAssertEqual(weakGoalRec?.estimatedImpact, expectedContribution)
    }

    func testRecommendationsPrioritySortingIsStable() throws {
        let recommendationService = RecommendationService(referenceDateProvider: fixedReferenceDate)
        let state = AppState(dataStore: try makeDataStore(), shouldSeedOnReload: true, recommendationService: recommendationService)

        // Add a duplicate subscription to get both a high-priority duplicate and an expensive rec
        try state.addSubscription(
            name: "Netflix",
            amount: try decimal("8.99"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        // Also add an expensive non-duplicate subscription
        try state.addSubscription(
            name: "YouTube Premium",
            amount: try decimal("16.50"),
            billingCycle: .monthly,
            category: "Streaming",
            nextBillingDate: fixedReferenceDate(),
            isActive: true
        )

        let recs = state.dashboardRecommendations

        // All high priorities should come before medium, medium before low
        var seenPriorities: [RecommendationPriority] = []
        for rec in recs {
            if seenPriorities.last != rec.priority {
                seenPriorities.append(rec.priority)
            }
        }

        // Priorities should be in order: high -> medium -> low (though not all may be present)
        for i in 0..<(seenPriorities.count - 1) {
            XCTAssertTrue(seenPriorities[i] < seenPriorities[i + 1])
        }
    }
}
extension PeculeTests {
    @MainActor
    func testInitialStateIsIdle() {
        let service = AIAdvisorService()
        XCTAssertEqual(service.state, .idle)
    }

    @MainActor
    func testUnavailableStateSetsCorrectly() {
        let service = AIAdvisorService()

        service.state = .unavailable(.deviceNotEligible)

        XCTAssertEqual(service.state, .unavailable(.deviceNotEligible))
        XCTAssertFalse(AIAdvisorUnavailableReason.deviceNotEligible.localizedDescription.isEmpty)
    }
}
