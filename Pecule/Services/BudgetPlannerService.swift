import Foundation

struct BudgetPlannerService {
    private let financialCalculator: FinancialCalculatorService
    private let calendar: Calendar
    private let referenceDateProvider: () -> Date

    init(
        financialCalculator: FinancialCalculatorService = FinancialCalculatorService(),
        calendar: Calendar = .current,
        referenceDateProvider: @escaping () -> Date = Date.init
    ) {
        self.financialCalculator = financialCalculator
        self.calendar = calendar
        self.referenceDateProvider = referenceDateProvider
    }

    func summary(
        forMonthContaining date: Date? = nil,
        subscriptions: [Subscription],
        purchases: [Purchase],
        incomeSources: [IncomeSource] = [],
        monthlyIncomeOverrides: [MonthlyIncomeOverride] = [],
        budgetRules: [BudgetRule] = [],
        budgetOverrides: [BudgetOverride] = [],
        bankTransactions: [BankTransaction] = [],
        includedAccountIDs: Set<UUID> = [],
        prefersBankAmounts: Bool = true
    ) -> MonthlyFinancialSummary {
        // Une seule définition du mois pour tout le calcul (m090) : celle du calendrier injecté. Revenus,
        // plafonds et dépenses se lisaient sinon dans deux mois différents (UTC puis local) aux bornes.
        let month = monthInterval(containing: date ?? referenceDateProvider())
        let monthStart = month.start
        let snapshot = AppDataSnapshot(
            subscriptions: subscriptions,
            purchases: purchases,
            goals: [],
            habits: [],
            incomeSources: incomeSources,
            monthlyIncomeOverrides: monthlyIncomeOverrides,
            budgetRules: budgetRules,
            budgetOverrides: budgetOverrides
        )

        return summaryCore(
            month: month,
            subscriptions: subscriptions,
            purchases: purchases,
            applicableIncomeSources: applicableIncomeSources(in: monthStart, from: incomeSources),
            resolvedIncomeAmount: { source in
                resolvedMonthlyIncomeAmount(
                    for: source,
                    in: monthStart,
                    monthlyIncomeOverrides: monthlyIncomeOverrides
                )
            },
            budgetCategories: snapshot.budgetCategories,
            resolvedBudgetAmount: { category in
                snapshot.budgetAmount(for: category, in: monthStart, calendar: calendar)
            },
            bankTransactions: bankTransactions,
            includedAccountIDs: includedAccountIDs,
            prefersBankAmounts: prefersBankAmounts
        )
    }

    func summary(
        forMonthContaining date: Date? = nil,
        from snapshot: AppDataSnapshot,
        prefersBankAmounts: Bool = true
    ) -> MonthlyFinancialSummary {
        let month = monthInterval(containing: date ?? referenceDateProvider())
        let monthStart = month.start

        return summaryCore(
            month: month,
            subscriptions: snapshot.subscriptions,
            purchases: snapshot.purchases,
            applicableIncomeSources: applicableIncomeSources(in: monthStart, from: snapshot.incomeSources),
            resolvedIncomeAmount: { source in
                resolvedMonthlyIncomeAmount(
                    for: source,
                    in: monthStart,
                    monthlyIncomeOverrides: snapshot.monthlyIncomeOverrides
                )
            },
            budgetCategories: snapshot.budgetCategories,
            resolvedBudgetAmount: { category in
                snapshot.budgetAmount(for: category, in: monthStart, calendar: calendar)
            },
            bankTransactions: snapshot.bankTransactions,
            includedAccountIDs: Set(snapshot.externalAccounts.filter { $0.isIncludedInTotals && !$0.isManual }.map(\.id)),
            prefersBankAmounts: prefersBankAmounts
        )
    }

    @MainActor
    func summary(
        forMonthContaining date: Date? = nil,
        from appState: AppState
    ) -> MonthlyFinancialSummary {
        let month = monthInterval(containing: date ?? referenceDateProvider())
        let monthStart = month.start

        return summaryCore(
            month: month,
            subscriptions: appState.subscriptions,
            purchases: appState.purchases,
            applicableIncomeSources: appState.activeIncomeSources(in: monthStart, calendar: calendar),
            resolvedIncomeAmount: { source in
                appState.resolvedMonthlyIncomeAmount(
                    for: source,
                    in: monthStart,
                    calendar: calendar
                )
            },
            budgetCategories: appState.budgetCategories,
            resolvedBudgetAmount: { category in
                appState.budgetAmount(for: category, in: monthStart, calendar: calendar)
            },
            bankTransactions: appState.bankTransactions,
            includedAccountIDs: Set(appState.linkedExternalAccounts.filter(\.isIncludedInTotals).map(\.id)),
            prefersBankAmounts: appState.prefersBankAmounts
        )
    }

    /// Une ligne de dépense du plan du mois : ce que le montant d'une catégorie additionne. La liste ouverte
    /// depuis une ligne de budget (m094) est celle-ci, pas une recherche parallèle dans les opérations :
    /// abonnements actifs, achats du mois et opérations non rattachées y figurent, et leur somme est le
    /// montant affiché.
    struct SpendingLine: Identifiable, Equatable {
        enum Origin: Equatable {
            case subscription(UUID, BillingCycle)
            case purchase(UUID)
            case bankOperation(UUID)
        }

        let origin: Origin
        let title: String
        // Un abonnement est lissé sur le mois : il n'a pas de jour.
        let date: Date?
        // Nom canonique de stockage, celui des résumés par catégorie.
        let category: String
        let amount: Decimal
        let isFixed: Bool

        var id: String {
            switch origin {
            case .subscription(let id, _): "subscription-" + id.uuidString
            case .purchase(let id): "purchase-" + id.uuidString
            case .bankOperation(let id): "bank-" + id.uuidString
            }
        }
    }

    /// Les lignes du mois, du plus gros montant au plus petit, calculées avec les mêmes entrées que
    /// `summary(forMonthContaining:from:)`.
    @MainActor
    func spendingLines(
        forMonthContaining date: Date? = nil,
        from appState: AppState
    ) -> [SpendingLine] {
        let month = monthInterval(containing: date ?? referenceDateProvider())
        let (_, evidence) = bankEvidence(
            for: month,
            bankTransactions: appState.bankTransactions,
            includedAccountIDs: Set(appState.linkedExternalAccounts.filter(\.isIncludedInTotals).map(\.id)),
            prefersBankAmounts: appState.prefersBankAmounts
        )
        return spendingLines(subscriptions: appState.subscriptions, purchases: appState.purchases, in: month, evidence: evidence)
            .sorted(by: spendingLineOrder)
    }
}

private extension BudgetPlannerService {
    struct CategoryBucket {
        let displayCategory: String
        var fixedCharges: Decimal
        var variableExpenses: Decimal
    }

    struct OrphanDebit {
        let id: UUID
        let title: String
        let date: Date
        let category: String
        // Négatif pour un remboursement reçu.
        let amount: Decimal
    }

    // Booked, EUR, non-transfer, non-ignored transactions of included accounts inside the month.
    struct BankEvidence {
        let bySubscription: [UUID: Decimal]
        let byPurchase: [UUID: Decimal]
        let byIncomeSource: [UUID: Decimal]
        let orphanDebits: [OrphanDebit]
        let unmatchedIncome: Decimal

        static let empty = BankEvidence(bySubscription: [:], byPurchase: [:], byIncomeSource: [:], orphanDebits: [], unmatchedIncome: .zero)
    }

    func bankEvidence(from transactions: [BankTransaction], includedAccountIDs: Set<UUID>, in month: DateInterval) -> BankEvidence {
        var bySubscription: [UUID: Decimal] = [:]
        var byPurchase: [UUID: Decimal] = [:]
        var byIncomeSource: [UUID: Decimal] = [:]
        var orphanDebits: [OrphanDebit] = []
        var unmatchedIncome: Decimal = .zero

        for transaction in transactions where transaction.bookingDate >= month.start && transaction.bookingDate < month.end && includedAccountIDs.contains(transaction.accountID) && transaction.countsInTotals {
            if transaction.isRefund {
                orphanDebits.append(OrphanDebit(id: transaction.id, title: transaction.label, date: transaction.bookingDate, category: transaction.category, amount: -transaction.amount))
                continue
            }
            switch transaction.link {
            case .subscription(let id):
                bySubscription[id, default: .zero] += transaction.amount
            case .purchase(let id):
                byPurchase[id, default: .zero] += transaction.amount
            case .income(let id):
                byIncomeSource[id, default: .zero] += transaction.amount
            case nil:
                if transaction.normalizedDirection == .debit {
                    orphanDebits.append(OrphanDebit(id: transaction.id, title: transaction.label, date: transaction.bookingDate, category: transaction.category, amount: transaction.amount))
                } else {
                    unmatchedIncome += transaction.amount
                }
            }
        }

        return BankEvidence(bySubscription: bySubscription, byPurchase: byPurchase, byIncomeSource: byIncomeSource, orphanDebits: orphanDebits, unmatchedIncome: unmatchedIncome)
    }

    // Le même calcul des preuves bancaires pour le résumé et pour la liste de lignes.
    func bankEvidence(
        for month: DateInterval,
        bankTransactions: [BankTransaction],
        includedAccountIDs: Set<UUID>,
        prefersBankAmounts: Bool
    ) -> (usesBankData: Bool, evidence: BankEvidence) {
        let usesBankData = prefersBankAmounts && !includedAccountIDs.isEmpty
        let evidence = usesBankData ? bankEvidence(from: bankTransactions, includedAccountIDs: includedAccountIDs, in: month) : .empty
        return (usesBankData, evidence)
    }

    func summaryCore(
        month: DateInterval,
        subscriptions: [Subscription],
        purchases: [Purchase],
        applicableIncomeSources: [IncomeSource],
        resolvedIncomeAmount: (IncomeSource) -> Decimal?,
        budgetCategories: [String],
        resolvedBudgetAmount: (String) -> Decimal,
        bankTransactions: [BankTransaction] = [],
        includedAccountIDs: Set<UUID> = [],
        prefersBankAmounts: Bool = true
    ) -> MonthlyFinancialSummary {
        let (usesBankData, evidence) = bankEvidence(
            for: month,
            bankTransactions: bankTransactions,
            includedAccountIDs: includedAccountIDs,
            prefersBankAmounts: prefersBankAmounts
        )
        var recurringIncome: Decimal = .zero
        var incomeComplements: Decimal = .zero
        var incomeOverrideDelta: Decimal = .zero

        for source in applicableIncomeSources {
            let baseAmount = source.amount.currencyRounded

            if source.isRecurring {
                recurringIncome += baseAmount
            } else {
                incomeComplements += baseAmount
            }

            // A settled credit is the real amount; otherwise the plan (with its override) stands.
            let resolvedAmount = (evidence.byIncomeSource[source.id] ?? resolvedIncomeAmount(source) ?? baseAmount).currencyRounded
            incomeOverrideDelta += (resolvedAmount - baseAmount).currencyRounded
        }

        let categoryBuckets = categoryBuckets(
            from: spendingLines(subscriptions: subscriptions, purchases: purchases, in: month, evidence: evidence)
        )

        let fixedCharges = categoryBuckets.values
            .reduce(.zero) { partialResult, bucket in
                partialResult + bucket.fixedCharges
            }
            .currencyRounded

        let variableExpenses = categoryBuckets.values
            .reduce(.zero) { partialResult, bucket in
                partialResult + bucket.variableExpenses
            }
            .currencyRounded

        let categorySummaries = categoryBuckets.values
            .map { bucket in
                CategorySpendingSummary(
                    category: bucket.displayCategory,
                    fixedCharges: bucket.fixedCharges.currencyRounded,
                    variableExpenses: bucket.variableExpenses.currencyRounded
                )
            }
            .sorted(by: categorySummaryOrder)

        let budgetStatuses = budgetStatuses(
            from: budgetCategories,
            categoryBuckets: categoryBuckets,
            resolvedBudgetAmount: resolvedBudgetAmount
        )

        return MonthlyFinancialSummary(
            month: month,
            recurringIncome: recurringIncome.currencyRounded,
            incomeComplements: incomeComplements.currencyRounded,
            incomeOverrideDelta: incomeOverrideDelta.currencyRounded,
            fixedCharges: fixedCharges,
            variableExpenses: variableExpenses,
            categorySummaries: categorySummaries,
            budgetStatuses: budgetStatuses,
            dataSource: usesBankData ? .bank : .planned,
            unmatchedIncome: evidence.unmatchedIncome.currencyRounded
        )
    }

    func monthInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    func applicableIncomeSources(
        in month: Date,
        from incomeSources: [IncomeSource]
    ) -> [IncomeSource] {
        incomeSources
            .filter { $0.applies(toMonthContaining: month, calendar: calendar) }
            .sorted(by: incomeSourceOrder)
    }

    func resolvedMonthlyIncomeAmount(
        for source: IncomeSource,
        in month: Date,
        monthlyIncomeOverrides: [MonthlyIncomeOverride]
    ) -> Decimal? {
        guard source.applies(toMonthContaining: month, calendar: calendar) else {
            return nil
        }

        let monthlyIncomeOverride = monthlyIncomeOverrides
            .filter { incomeOverride in
                incomeOverride.incomeSourceID == source.id &&
                incomeOverride.applies(toMonthContaining: month, calendar: calendar)
            }
            .sorted(by: monthlyIncomeOverrideOrder)
            .last

        guard let monthlyIncomeOverride else {
            return source.amount.currencyRounded
        }

        return monthlyIncomeOverride.resolvedAmount(for: source.amount)
    }

    // Chaque montant du mois, avec sa provenance. Le résumé additionne ces lignes, la liste d'une catégorie
    // les affiche : c'est la même construction.
    func spendingLines(
        subscriptions: [Subscription],
        purchases: [Purchase],
        in month: DateInterval,
        evidence: BankEvidence = .empty
    ) -> [SpendingLine] {
        var lines: [SpendingLine] = []

        for subscription in subscriptions where subscription.isActive {
            // Yearly plans stay amortised even when the bank shows the single annual debit.
            let settled = subscription.billingCycle == .monthly ? evidence.bySubscription[subscription.id] : nil
            lines.append(SpendingLine(
                origin: .subscription(subscription.id, subscription.billingCycle),
                title: subscription.name,
                date: nil,
                category: canonicalCategoryName(for: subscription.category),
                amount: (settled ?? financialCalculator.costPerMonth(subscription)).currencyRounded,
                isFixed: true
            ))
        }

        // Mois à demi-intervalle : un achat daté de minuit pile le 1er n'appartient qu'au nouveau mois.
        for purchase in purchases where purchase.date >= month.start && purchase.date < month.end {
            lines.append(SpendingLine(
                origin: .purchase(purchase.id),
                title: purchase.title,
                date: purchase.date,
                category: canonicalCategoryName(for: purchase.category),
                amount: (evidence.byPurchase[purchase.id] ?? purchase.amount).currencyRounded,
                isFixed: false
            ))
        }

        for orphan in evidence.orphanDebits {
            lines.append(SpendingLine(
                origin: .bankOperation(orphan.id),
                title: orphan.title,
                date: orphan.date,
                category: canonicalCategoryName(for: orphan.category),
                amount: orphan.amount.currencyRounded,
                isFixed: false
            ))
        }

        return lines
    }

    func categoryBuckets(from lines: [SpendingLine]) -> [String: CategoryBucket] {
        var buckets: [String: CategoryBucket] = [:]

        for line in lines {
            let key = categoryKey(for: line.category)
            var bucket = buckets[key] ?? CategoryBucket(displayCategory: line.category, fixedCharges: .zero, variableExpenses: .zero)
            if line.isFixed {
                bucket.fixedCharges += line.amount
            } else {
                bucket.variableExpenses += line.amount
            }
            buckets[key] = bucket
        }

        return buckets
    }

    func budgetStatuses(
        from budgetCategories: [String],
        categoryBuckets: [String: CategoryBucket],
        resolvedBudgetAmount: (String) -> Decimal
    ) -> [BudgetStatus] {
        budgetCategories
            .map { category in
                let key = categoryKey(for: category)
                let bucket = categoryBuckets[key]

                return BudgetStatus(
                    category: canonicalCategoryName(for: category),
                    scope: .totalSpending,
                    plannedAmount: resolvedBudgetAmount(category).currencyRounded,
                    spentAmount: ((bucket?.fixedCharges ?? .zero) + (bucket?.variableExpenses ?? .zero)).currencyRounded
                )
            }
            .filter { $0.plannedAmount > .zero || $0.spentAmount > .zero }
            .sorted(by: budgetStatusOrder)
    }

    func canonicalCategoryName(for rawCategory: String) -> String {
        ExpenseCategory.canonicalStorageValue(for: rawCategory)
    }

    func categoryKey(for category: String) -> String {
        ExpenseCategory.canonicalKey(for: category)
    }

    func incomeSourceOrder(
        _ left: IncomeSource,
        _ right: IncomeSource
    ) -> Bool {
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

    func monthlyIncomeOverrideOrder(
        _ left: MonthlyIncomeOverride,
        _ right: MonthlyIncomeOverride
    ) -> Bool {
        if left.monthStartDate != right.monthStartDate {
            return left.monthStartDate < right.monthStartDate
        }

        return left.id.uuidString < right.id.uuidString
    }

    func spendingLineOrder(
        _ left: SpendingLine,
        _ right: SpendingLine
    ) -> Bool {
        if left.amount != right.amount {
            return left.amount > right.amount
        }

        if left.title != right.title {
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }

        return left.id < right.id
    }

    func categorySummaryOrder(
        _ left: CategorySpendingSummary,
        _ right: CategorySpendingSummary
    ) -> Bool {
        if left.totalSpent != right.totalSpent {
            return left.totalSpent > right.totalSpent
        }

        return left.category.localizedCaseInsensitiveCompare(right.category) == .orderedAscending
    }

    func budgetStatusOrder(
        _ left: BudgetStatus,
        _ right: BudgetStatus
    ) -> Bool {
        left.category.localizedCaseInsensitiveCompare(right.category) == .orderedAscending
    }
}
