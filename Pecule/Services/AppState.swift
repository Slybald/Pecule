import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var subscriptions: [Subscription]
    @Published var purchases: [Purchase]
    @Published var goals: [Goal]
    @Published var habits: [Habit]
    @Published var incomeSources: [IncomeSource]
    @Published var monthlyIncomeOverrides: [MonthlyIncomeOverride]
    @Published var budgetRules: [BudgetRule]
    @Published var planning = PlanningSnapshot()
    @Published var monthlySpendingLimits: [MonthlySpendingLimit] = []
    @Published var budgetOverrides: [BudgetOverride]
    @Published var externalAccounts: [ExternalAccount]
    @Published var bankTransactions: [BankTransaction]
    @Published private(set) var bankImportProgress: [UUID: BankImportProgress] = [:]
    @Published private(set) var dataRevision: UInt64 = 0
    // Set when the last reload() could not read the store; cleared by the next one that succeeds.
    @Published private(set) var loadFailure: DataLoadFailure?
    // Tests only: makes the next reload() fail the way an unreadable store would.
    #if DEBUG
    var injectedLoadFailure: Error?
    #endif
    let dataStore: PeculeDataStore
    private let shouldSeedOnReload: Bool
    var bankCacheStart = Date.distantPast
    // Un historique couvre plusieurs années : sans borne, parcourir les mois retenait en mémoire
    // toutes les opérations de tous les mois visités jusqu'au prochain rechargement.
    static let historicalMonthCacheLimit = 18
    var historicalMonthCache: [Date: [BankTransaction]] = [:]
    private var historicalMonthOrder: [Date] = []
    func cachedHistoricalMonth(_ start: Date) -> [BankTransaction]? {
        guard let rows = historicalMonthCache[start] else { return nil }
        if let index = historicalMonthOrder.firstIndex(of: start) {
            historicalMonthOrder.remove(at: index)
            historicalMonthOrder.append(start)
        }
        return rows
    }

    func cacheHistoricalMonth(_ start: Date, _ rows: [BankTransaction]) {
        if historicalMonthCache[start] == nil, historicalMonthOrder.count >= Self.historicalMonthCacheLimit,
           let oldest = historicalMonthOrder.first {
            historicalMonthOrder.removeFirst()
            historicalMonthCache[oldest] = nil
        }
        historicalMonthCache[start] = rows
        historicalMonthOrder.removeAll { $0 == start }
        historicalMonthOrder.append(start)
    }

    private let financialCalculator: FinancialCalculatorService
    private let subscriptionAnalyzer: SubscriptionAnalyzerService
    private let insightsService: InsightsService
    private let observationService: MonthlyObservationService
    private var externalChangeTask: Task<Void, Never>?
    // Twelve months of bank evidence, oldest first; rebuilt on every reload (sync or annotation).
    @Published private(set) var observedMonths: [ObservedMonth] = []
    @Published private(set) var recurringCharges: [RecurringCharge] = []
    private let recommendationService: RecommendationService
    let aiAdvisor: AIAdvisorService
    let bankGateway: any BankGatewayClient
    let bankSync: BankSyncService
    @Published private(set) var isBankGatewayConfigured: Bool
    @Published var prefersBankAmounts: Bool {
        didSet { preferenceStore?.set(prefersBankAmounts, forKey: preferenceKey) }
    }
    private let preferenceStore: UserDefaults?
    private let preferenceKey: String
    private(set) var isProfileActive = true
    var managesIdentity = false
    var identityGatewayURL: URL?
    var requestSignOut: (() async -> Void)?
    let notificationScope = UUID().uuidString
    static let prefersBankAmountsKey = "LifeOS.prefersBankAmounts"
    private let bankGatewayConfigurationStore: BankGatewayConfigurationStore

    init(
        dataStore: PeculeDataStore,
        shouldSeedOnReload: Bool = false,
        preferenceKey: String = AppState.prefersBankAmountsKey,
        financialCalculator: FinancialCalculatorService = FinancialCalculatorService(),
        subscriptionAnalyzer: SubscriptionAnalyzerService = SubscriptionAnalyzerService(),
        insightsService: InsightsService = InsightsService(),
        observationService: MonthlyObservationService = MonthlyObservationService(),
        recommendationService: RecommendationService = RecommendationService(),
        aiAdvisor: AIAdvisorService = AIAdvisorService(),
        bankGateway: any BankGatewayClient = StubBankGatewayClient(),
        bankGatewayConfigurationStore: BankGatewayConfigurationStore = BankGatewayConfigurationStore(secretStore: InMemorySecretStore())
    ) {
        self.subscriptions = []
        self.purchases = []
        self.goals = []
        self.habits = []
        self.incomeSources = []
        self.monthlyIncomeOverrides = []
        self.budgetRules = []
        self.budgetOverrides = []
        self.externalAccounts = []
        self.bankTransactions = []
        self.dataStore = dataStore
        self.shouldSeedOnReload = shouldSeedOnReload
        self.preferenceKey = preferenceKey
        // Temporary databases (tests/previews) must not read or overwrite persistent
        // financial preferences, nor leak a manual-mode choice into the next launch.
        let preferenceStore: UserDefaults? = dataStore.container.configurations.allSatisfy(\.isStoredInMemoryOnly) ? nil : .standard
        self.preferenceStore = preferenceStore
        self.financialCalculator = financialCalculator
        self.subscriptionAnalyzer = subscriptionAnalyzer
        self.insightsService = insightsService
        self.observationService = observationService
        self.recommendationService = recommendationService
        self.aiAdvisor = aiAdvisor
        self.bankGateway = bankGateway
        self.bankSync = BankSyncService(gateway: bankGateway, dataStore: dataStore)
        self.bankGatewayConfigurationStore = bankGatewayConfigurationStore
        self.isBankGatewayConfigured = Self.isConfigured(bankGateway, store: bankGatewayConfigurationStore)
        self.prefersBankAmounts = preferenceStore?.object(forKey: preferenceKey) as? Bool ?? true
        bankSync.onDataChanged = { [weak self] in self?.reload() }
        // App Intents write through the same store; reload so the UI shows what Siri just added.
        externalChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .peculeDataDidChangeExternally) {
                await MainActor.run {
                    self?.reload()
                }
            }
        }
        reload()
    }

    var currentBankGatewayConfiguration: BankGatewayConfiguration? {
        try? bankGatewayConfigurationStore.load()
    }

    // A blank token keeps the stored one, so the form never has to echo the secret back to the screen.
    func saveBankGatewayConfiguration(baseURL: URL, bearerToken: String?) throws {
        let trimmed = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let token = trimmed.isEmpty ? currentBankGatewayConfiguration?.bearerToken : trimmed else {
            throw BankGatewayConfigurationError.missingToken
        }
        try bankGatewayConfigurationStore.save(BankGatewayConfiguration(baseURL: baseURL, bearerToken: token))
        isBankGatewayConfigured = Self.isConfigured(bankGateway, store: bankGatewayConfigurationStore)
    }

    // For the connection test in the form: the stored bearer, never displayed.
    func storedBankGatewayToken() -> String? {
        (try? bankGatewayConfigurationStore.load())?.bearerToken
    }

    // Public page served by the gateway itself, so the policy always matches the deployed code.
    var bankGatewayPrivacyURL: URL? {
        (identityGatewayURL ?? (try? bankGatewayConfigurationStore.load())?.baseURL)?.appending(path: "privacy")
    }

    func clearBankGatewayConfiguration() throws {
        try bankGatewayConfigurationStore.clear()
        isBankGatewayConfigured = Self.isConfigured(bankGateway, store: bankGatewayConfigurationStore)
    }

    private static func isConfigured(_ gateway: any BankGatewayClient, store: BankGatewayConfigurationStore) -> Bool {
        !gateway.requiresConfiguration || (try? store.load()) != nil
    }

    static var preview: AppState {
        do {
            let container = try PeculeDataStore.makeInMemoryContainer()
            let dataStore = PeculeDataStore(container: container)
            return AppState(dataStore: dataStore, shouldSeedOnReload: true)
        } catch {
            fatalError("Unable to create preview store: \(error)")
        }
    }

    func invalidateProfile() {
        isProfileActive = false
        dataRevision &+= 1
        externalChangeTask?.cancel()
        externalChangeTask = nil
        bankSync.invalidate()
        aiAdvisor.state = .idle
        subscriptions = []; purchases = []; goals = []; habits = []
        incomeSources = []; monthlyIncomeOverrides = []; budgetRules = []; budgetOverrides = []
        monthlySpendingLimits = []; goalContributions = []; availableCategories = ExpenseCategory.allCases
        historicalMonthCache = [:]
        historicalMonthOrder = []
        planning = PlanningSnapshot()
        externalAccounts = []; bankTransactions = []; observedMonths = []; recurringCharges = []; bankImportProgress = [:]
    }

    @Published var goalContributions: [GoalContribution] = []
    @Published var availableCategories: [ExpenseCategory] = ExpenseCategory.allCases

    func reload() {
        guard isProfileActive else { return }
        defer { dataRevision &+= 1 }
        do {
            #if DEBUG
            if let injectedLoadFailure { throw injectedLoadFailure }
            #endif
            if shouldSeedOnReload {
                try dataStore.seedIfNeeded()
            } else {
                try dataStore.removeUnmodifiedDemoData()
            }
            bankCacheStart = Calendar.current.date(byAdding: .month, value: -13, to: Calendar.current.peculeMonthStart(for: Date())) ?? .distantPast
            historicalMonthCache = [:]
            historicalMonthOrder = []
            // Best effort, once per store: a failed repair must never keep the app from loading.
            try? dataStore.repairOrphanedReferencesOnce()
            try dataStore.reconcileProvisionPayments()
            let snapshot = try dataStore.loadSnapshot(bankSince: bankCacheStart)
            availableCategories = try dataStore.categoryCatalog(preserving: snapshot)
            goalContributions = try dataStore.goalContributions()
            monthlySpendingLimits = try dataStore.monthlySpendingLimits()
            planning = try dataStore.planningSnapshot()
            subscriptions = snapshot.subscriptions
            purchases = snapshot.purchases
            goals = snapshot.goals
            habits = snapshot.habits
            incomeSources = snapshot.incomeSources
            monthlyIncomeOverrides = snapshot.monthlyIncomeOverrides
            budgetRules = snapshot.budgetRules
            budgetOverrides = snapshot.budgetOverrides
            externalAccounts = snapshot.externalAccounts
            bankTransactions = snapshot.bankTransactions
            bankImportProgress = try dataStore.bankImportProgress()
            let includedAccountIDs = Set(snapshot.externalAccounts.filter { $0.isIncludedInTotals && !$0.isManual }.map(\.id))
            observedMonths = observationService.observe(transactions: snapshot.bankTransactions, includedAccountIDs: includedAccountIDs)
            recurringCharges = RecurringChargeDetector(calendar: observationService.calendar).detect(in: snapshot.bankTransactions, includedAccountIDs: includedAccountIDs)
            loadFailure = nil
        } catch {
            // Never empty the collections: an empty screen reads as "everything is lost". The data on disk is
            // untouched; the root view shows the recovery screen and "Retry" calls reload() again.
            let failure = DataLoadFailure(error)
            AppLog.data.error("Reload failed (\(failure.identifier, privacy: .public)): \(String(describing: error), privacy: .private)")
            loadFailure = failure
        }
    }

    func addSubscription(
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: String,
        nextBillingDate: Date,
        isActive: Bool
    ) throws {
        try dataStore.addSubscription(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            billingCycle: billingCycle,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            nextBillingDate: nextBillingDate,
            isActive: isActive
        )

        reload()
    }

    func updateSubscription(
        _ subscription: Subscription,
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: String,
        nextBillingDate: Date,
        isActive: Bool
    ) throws {
        try dataStore.updateSubscription(
            subscription,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            billingCycle: billingCycle,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            nextBillingDate: nextBillingDate,
            isActive: isActive
        )

        reload()
    }

    func deleteSubscription(_ subscription: Subscription) throws {
        try dataStore.deleteSubscription(subscription)
        reload()
    }

    func addPurchase(
        title: String,
        amount: Decimal,
        date: Date,
        category: String,
        merchant: String,
        notes: String?
    ) throws {
        try dataStore.addPurchase(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            date: date,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes
        )

        reload()
    }

    func updatePurchase(
        _ purchase: Purchase,
        title: String,
        amount: Decimal,
        date: Date,
        category: String,
        merchant: String,
        notes: String?
    ) throws {
        try dataStore.updatePurchase(
            purchase,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            date: date,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes
        )

        reload()
    }

    func deletePurchase(_ purchase: Purchase) throws {
        try dataStore.deletePurchase(purchase)
        reload()
    }

    func addGoal(
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String
    ) throws {
        try dataStore.addGoal(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            targetAmount: targetAmount.currencyRounded,
            currentAmount: currentAmount.currencyRounded,
            targetDate: targetDate,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        reload()
    }

    func updateGoal(
        _ goal: Goal,
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String
    ) throws {
        try dataStore.updateGoal(
            goal,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            targetAmount: targetAmount.currencyRounded,
            currentAmount: currentAmount.currencyRounded,
            targetDate: targetDate,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        reload()
    }

    func deleteGoal(_ goal: Goal) throws {
        try dataStore.deleteGoal(goal)
        reload()
    }

    func addHabit(
        title: String,
        frequency: HabitFrequency,
        targetCount: Int,
        completedCount: Int,
        linkedGoalID: UUID?
    ) throws {
        let safeTargetCount = max(targetCount, 1)

        try dataStore.addHabit(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: frequency,
            targetCount: safeTargetCount,
            completedCount: max(0, min(completedCount, safeTargetCount)),
            linkedGoalID: linkedGoalID
        )

        reload()
    }

    func updateHabit(
        _ habit: Habit,
        title: String,
        frequency: HabitFrequency,
        targetCount: Int,
        completedCount: Int,
        linkedGoalID: UUID?
    ) throws {
        let safeTargetCount = max(targetCount, 1)

        try dataStore.updateHabit(
            habit,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: frequency,
            targetCount: safeTargetCount,
            completedCount: max(0, min(completedCount, safeTargetCount)),
            linkedGoalID: linkedGoalID
        )

        reload()
    }

    func markHabitCompleted(_ habit: Habit) throws {
        try dataStore.markHabitCompleted(habit)
        reload()
    }

    func addIncomeSource(
        name: String,
        amount: Decimal,
        type: IncomeType,
        startDate: Date,
        endDate: Date?,
        isRecurring: Bool,
        isActive: Bool
    ) throws {
        try dataStore.addIncomeSource(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            type: type,
            startDate: startDate,
            endDate: sanitizedIncomeEndDate(endDate, startDate: startDate, isRecurring: isRecurring),
            isRecurring: isRecurring,
            isActive: isActive
        )

        reload()
    }

    func updateIncomeSource(
        _ incomeSource: IncomeSource,
        name: String,
        amount: Decimal,
        type: IncomeType,
        startDate: Date,
        endDate: Date?,
        isRecurring: Bool,
        isActive: Bool
    ) throws {
        try dataStore.updateIncomeSource(
            incomeSource,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount.currencyRounded,
            type: type,
            startDate: startDate,
            endDate: sanitizedIncomeEndDate(endDate, startDate: startDate, isRecurring: isRecurring),
            isRecurring: isRecurring,
            isActive: isActive
        )

        reload()
    }

    func deleteIncomeSource(_ incomeSource: IncomeSource) throws {
        try dataStore.deleteIncomeSource(incomeSource)
        reload()
    }

    func addMonthlyIncomeOverride(
        incomeSourceID: UUID,
        month: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) throws {
        try dataStore.addMonthlyIncomeOverride(
            incomeSourceID: incomeSourceID,
            month: month,
            amount: amount.currencyRounded,
            replacesSourceAmount: replacesSourceAmount
        )

        reload()
    }

    func updateMonthlyIncomeOverride(
        _ monthlyIncomeOverride: MonthlyIncomeOverride,
        incomeSourceID: UUID,
        month: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) throws {
        try dataStore.updateMonthlyIncomeOverride(
            monthlyIncomeOverride,
            incomeSourceID: incomeSourceID,
            month: month,
            amount: amount.currencyRounded,
            replacesSourceAmount: replacesSourceAmount
        )

        reload()
    }

    func deleteMonthlyIncomeOverride(_ monthlyIncomeOverride: MonthlyIncomeOverride) throws {
        try dataStore.deleteMonthlyIncomeOverride(monthlyIncomeOverride)
        reload()
    }

    func setBudgetRule(
        category: String,
        monthlyAmount: Decimal
    ) throws {
        try dataStore.setBudgetRule(
            category: ExpenseCategory.canonicalStorageValue(for: category),
            monthlyAmount: max(monthlyAmount.currencyRounded, .zero)
        )

        reload()
    }

    func deleteBudgetRule(_ budgetRule: BudgetRule) throws {
        try dataStore.deleteBudgetRule(budgetRule)
        reload()
    }

    func setBudgetOverride(
        category: String,
        month: Date,
        monthlyAmount: Decimal
    ) throws {
        try dataStore.setBudgetOverride(
            category: ExpenseCategory.canonicalStorageValue(for: category),
            month: month,
            monthlyAmount: max(monthlyAmount.currencyRounded, .zero)
        )

        reload()
    }

    func deleteBudgetOverride(_ budgetOverride: BudgetOverride) throws {
        try dataStore.deleteBudgetOverride(budgetOverride)
        reload()
    }

    var activeSubscriptions: [Subscription] {
        subscriptions.filter(\.isActive)
    }

    var activeIncomeSources: [IncomeSource] {
        sortedIncomeSources(
            incomeSources.filter(\.isActive)
        )
    }

    var recurringIncomeSources: [IncomeSource] {
        sortedIncomeSources(
            activeIncomeSources.filter(\.isRecurring)
        )
    }

    var incomeOverrides: [MonthlyIncomeOverride] {
        monthlyIncomeOverrides.sorted { left, right in
            if left.monthStartDate != right.monthStartDate {
                return left.monthStartDate < right.monthStartDate
            }

            let leftIncomeSourceName = incomeSourceName(for: left.incomeSourceID)
            let rightIncomeSourceName = incomeSourceName(for: right.incomeSourceID)

            if leftIncomeSourceName != rightIncomeSourceName {
                return leftIncomeSourceName.localizedCaseInsensitiveCompare(rightIncomeSourceName) == .orderedAscending
            }

            return left.id.uuidString < right.id.uuidString
        }
    }

    var budgetCategories: [String] {
        currentSnapshot.budgetCategories
    }

    var activeSubscriptionsCount: Int {
        activeSubscriptions.count
    }

    var displaySubscriptions: [Subscription] {
        subscriptions.sorted { left, right in
            if left.isActive != right.isActive {
                return left.isActive && !right.isActive
            }

            if left.nextBillingDate != right.nextBillingDate {
                return left.nextBillingDate < right.nextBillingDate
            }

            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    var upcomingSubscriptions: [Subscription] {
        upcomingSubscriptions(on: Date())
    }

    func upcomingSubscriptions(on date: Date, calendar: Calendar = .current) -> [Subscription] {
        activeSubscriptions.filter { $0.nextBillingDate >= calendar.startOfDay(for: date) }
            .sorted { $0.nextBillingDate < $1.nextBillingDate }
    }

    var monthlySubscriptionCost: Decimal {
        activeSubscriptions.reduce(.zero) { partialResult, subscription in
            partialResult + financialCalculator.costPerMonth(subscription)
        }
        .currencyRounded
    }

    var annualSubscriptionCost: Decimal {
        subscriptionAnalyzer.annualTotal(for: subscriptions)
    }

    var expensiveSubscriptions: [Subscription] {
        subscriptionAnalyzer.expensiveSubscriptions(in: subscriptions)
    }

    var duplicateSubscriptionGroups: [[Subscription]] {
        subscriptionAnalyzer.duplicateGroups(in: subscriptions)
    }

    var recentPurchases: [Purchase] {
        purchases.sorted { left, right in
            if left.date != right.date {
                return left.date > right.date
            }

            if left.amount != right.amount {
                return left.amount > right.amount
            }

            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    var highestAmountPurchases: [Purchase] {
        purchases.sorted { left, right in
            if left.amount != right.amount {
                return left.amount > right.amount
            }

            if left.date != right.date {
                return left.date > right.date
            }

            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    var purchaseCount: Int {
        purchases.count
    }

    var totalPurchaseAmount: Decimal {
        purchases.reduce(.zero) { partialResult, purchase in
            partialResult + purchase.amount
        }
        .currencyRounded
    }

    var activeGoals: [Goal] {
        goals
            .filter { !$0.isArchived }
            .sorted { left, right in
                if left.targetDate != right.targetDate {
                    return left.targetDate < right.targetDate
                }

                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    var archivedGoals: [Goal] {
        goals
            .filter(\.isArchived)
            .sorted { left, right in
                if left.targetDate != right.targetDate {
                    return left.targetDate > right.targetDate
                }

                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    var overallGoalProgress: Double {
        let targetTotal = activeGoals.reduce(.zero) { partialResult, goal in
            partialResult + goal.targetAmount
        }

        let targetValue = NSDecimalNumber(decimal: targetTotal).doubleValue

        guard targetValue > 0 else {
            return 0
        }

        let currentTotal = activeGoals.reduce(.zero) { partialResult, goal in
            partialResult + goal.currentAmount
        }

        let currentValue = NSDecimalNumber(decimal: currentTotal).doubleValue

        return min(max(currentValue / targetValue, 0), 1)
    }

    var dashboardInsights: [InsightItem] {
        insightsService.generateInsights(from: self)
    }

    var dashboardRecommendations: [RecommendationItem] {
        recommendationService.generateRecommendations(from: self)
    }

    var activeHabits: [Habit] {
        habits
            .filter(\.isActive)
            .sorted { left, right in
                left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    var inactiveHabits: [Habit] {
        habits
            .filter { !$0.isActive }
            .sorted { left, right in
                left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    func goalTitle(for linkedGoalID: UUID?) -> String? {
        guard let linkedGoalID else {
            return nil
        }

        return goals.first(where: { $0.id == linkedGoalID })?.title
    }

    func activeIncomeSources(
        in month: Date,
        calendar: Calendar = .current
    ) -> [IncomeSource] {
        sortedIncomeSources(
            activeIncomeSources.filter { $0.applies(toMonthContaining: month, calendar: calendar) }
        )
    }

    func monthlyIncomeOverride(
        for source: IncomeSource,
        in month: Date,
        calendar: Calendar = .current
    ) -> MonthlyIncomeOverride? {
        monthlyIncomeOverrides.first { monthlyIncomeOverride in
            monthlyIncomeOverride.incomeSourceID == source.id &&
            monthlyIncomeOverride.applies(toMonthContaining: month, calendar: calendar)
        }
    }

    func resolvedMonthlyIncomeAmount(
        for source: IncomeSource,
        in month: Date,
        calendar: Calendar = .current
    ) -> Decimal? {
        guard source.applies(toMonthContaining: month, calendar: calendar) else {
            return nil
        }

        guard let monthlyIncomeOverride = monthlyIncomeOverride(
            for: source,
            in: month,
            calendar: calendar
        ) else {
            return source.amount.currencyRounded
        }

        return monthlyIncomeOverride.resolvedAmount(for: source.amount)
    }

    func monthlyIncomeOverrides(
        for month: Date,
        calendar: Calendar = .current
    ) -> [MonthlyIncomeOverride] {
        // Le mois est celui du calendrier injecté : `month` est lu tel quel, sans repasser par l'ancrage UTC
        // de `peculeMonthStart`, qui prend l'avant-veille ou le lendemain près des bornes de mois.
        incomeOverrides.filter { monthlyIncomeOverride in
            monthlyIncomeOverride.applies(toMonthContaining: month, calendar: calendar)
        }
    }

    func monthlyFinancialSummary(
        for month: Date,
        calendar: Calendar = .current
    ) -> MonthlyFinancialSummary {
        let includedIDs = includedLinkedAccountIDs
        if prefersBankAmounts, !includedIDs.isEmpty, let interval = calendar.dateInterval(of: .month, for: month) {
            var summary = BudgetOverviewService().recordedSummary(
                month: interval,
                transactions: bankTransactions(in: month, calendar: calendar),
                includedAccountIDs: includedIDs,
                plannedAmount: { budgetLimit(for: $0.storageValue, in: month, calendar: calendar) },
                catalog: availableCategories,
                // Un achat saisi compte, sauf si une opération bancaire le représente déjà.
                manualPurchases: countedManualPurchases(in: interval, includedAccountIDs: includedIDs, calendar: calendar)
            )
            summary.reservedForGoals = GoalFundingService().reserved(for: month, contributions: budgetGoalContributions(), calendar: calendar)
            return summary
        }
        var summary = BudgetPlannerService(
            financialCalculator: financialCalculator,
            calendar: calendar,
            referenceDateProvider: { month }
        )
        .summary(forMonthContaining: month, from: self)
        summary.reservedForGoals = GoalFundingService().reserved(for: month, contributions: budgetGoalContributions(), calendar: calendar)
        return summary
    }

    // Ce que le montant dépensé du plan du mois additionne, ligne par ligne (abonnements actifs, achats du
    // mois). C'est la liste ouverte depuis une ligne de budget en mode manuel : produite par le même service
    // que le montant, sa somme est ce montant (m094). Sans catégorie, toutes les lignes du mois.
    func plannedSpendingLines(
        in month: Date,
        category: ExpenseCategory? = nil,
        calendar: Calendar = .current
    ) -> [BudgetPlannerService.SpendingLine] {
        let lines = BudgetPlannerService(
            financialCalculator: financialCalculator,
            calendar: calendar,
            referenceDateProvider: { month }
        )
        .spendingLines(forMonthContaining: month, from: self)
        guard let category else { return lines }
        return lines.filter { ExpenseCategory.canonicalCategory(for: $0.category) == category }
    }

    func budgetRule(for category: String) -> BudgetRule? {
        currentSnapshot.budgetRule(for: category)
    }

    func budgetOverride(
        for category: String,
        in month: Date,
        calendar: Calendar = .current
    ) -> BudgetOverride? {
        currentSnapshot.budgetOverride(for: category, in: month, calendar: calendar)
    }

    func budgetLimit(for category: String, in month: Date, calendar: Calendar = .current) -> Decimal? {
        if let override = budgetOverride(for: category, in: month, calendar: calendar) { return override.monthlyAmount.currencyRounded }
        return budgetRule(for: category)?.monthlyAmount.currencyRounded
    }

    func budgetAmount(
        for category: String,
        in month: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        currentSnapshot.budgetAmount(for: category, in: month, calendar: calendar)
    }

    func monthlyBudget(
        for month: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        currentSnapshot.monthlyBudget(for: month, calendar: calendar)
    }
}

extension AppState {
    // Internal so pure services (budgets, forecasts) can consume the full state, bank data included.
    var currentSnapshot: AppDataSnapshot {
        AppDataSnapshot(
            subscriptions: subscriptions,
            purchases: purchases,
            goals: goals,
            habits: habits,
            incomeSources: incomeSources,
            monthlyIncomeOverrides: monthlyIncomeOverrides,
            budgetRules: budgetRules,
            budgetOverrides: budgetOverrides,
            externalAccounts: externalAccounts,
            bankTransactions: bankTransactions
        )
    }
}

private extension AppState {
    func sanitizedIncomeEndDate(
        _ endDate: Date?,
        startDate: Date,
        isRecurring: Bool
    ) -> Date? {
        guard isRecurring, let endDate else {
            return nil
        }

        return endDate < startDate ? startDate : endDate
    }

    func sortedIncomeSources(_ incomeSources: [IncomeSource]) -> [IncomeSource] {
        incomeSources.sorted { left, right in
            if left.type.sortOrder != right.type.sortOrder {
                return left.type.sortOrder < right.type.sortOrder
            }

            if left.startDate != right.startDate {
                return left.startDate < right.startDate
            }

            let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)

            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            return left.id.uuidString < right.id.uuidString
        }
    }

    func incomeSourceName(for incomeSourceID: UUID) -> String {
        incomeSources.first(where: { $0.id == incomeSourceID })?.name ?? incomeSourceID.uuidString
    }
}
