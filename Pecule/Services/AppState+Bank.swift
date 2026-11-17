import Foundation

extension AppState {
    func totalExternalBalance(currencyCode: String = "EUR") -> Decimal? {
        let balances = externalAccounts
            .filter { $0.isIncludedInTotals && $0.currencyCode == currencyCode }
            .compactMap(\.balance)
        guard !balances.isEmpty else {
            return nil
        }
        return balances.reduce(.zero, +).currencyRounded
    }

    // Without an explicit account, only accounts included in totals contribute (card mirrors stay out).
    func bankTransactions(
        in monthDate: Date,
        direction: BankTransactionDirection? = nil,
        accountID: UUID? = nil,
        calendar: Calendar = .current
    ) -> [BankTransaction] {
        guard isProfileActive, let month = calendar.dateInterval(of: .month, for: monthDate) else {
            return []
        }
        let includedAccountIDs = Set(externalAccounts.filter(\.isIncludedInTotals).map(\.id))
        let candidates: [BankTransaction]
        if month.start < bankCacheStart {
            if let cached = cachedHistoricalMonth(month.start) { candidates = cached }
            else {
                do {
                    candidates = try dataStore.transactions(in: month)
                    cacheHistoricalMonth(month.start, candidates)
                } catch {
                    // A failed read is not "no transactions": nothing is cached, the next call reads again.
                    AppLog.data.error("Historical month read failed: \(String(describing: error), privacy: .private)")
                    candidates = []
                }
            }
        } else { candidates = bankTransactions }
        return candidates.filter { transaction in
            transaction.bookingDate >= month.start && transaction.bookingDate < month.end &&
                calendar.startOfDay(for: transaction.bookingDate) <= calendar.startOfDay(for: Date()) &&
                (accountID == nil ? includedAccountIDs.contains(transaction.accountID) : transaction.accountID == accountID) &&
                (direction == nil || transaction.normalizedDirection == direction)
        }
    }

    func setExternalAccount(_ account: ExternalAccount, includedInTotals: Bool) throws {
        try dataStore.updateExternalAccountInclusion(account, isIncludedInTotals: includedInTotals)
        reload()
    }

    func bankMonthlyTotal(
        in monthDate: Date,
        direction: BankTransactionDirection,
        calendar: Calendar = .current
    ) -> Decimal {
        bankTransactions(in: monthDate, calendar: calendar)
            .filter { direction == .debit ? ($0.isExpense || $0.isRefund) : $0.isIncome }
            .reduce(Decimal.zero) { $0 + (direction == .debit ? $1.netExpenseAmount : $1.amount) }
            .currencyRounded
    }

    struct BankCategorySpending: Identifiable, Equatable {
        let category: ExpenseCategory
        let amount: Decimal

        var id: String { category.rawValue }
    }

    func bankSpendingByCategory(in monthDate: Date, calendar: Calendar = .current) -> [BankCategorySpending] {
        let totals = bankTransactions(in: monthDate, calendar: calendar)
            .filter { $0.isExpense || $0.isRefund }
            .reduce(into: [ExpenseCategory: Decimal]()) { partial, transaction in
                partial[ExpenseCategory.canonicalCategory(for: transaction.category), default: .zero] += transaction.netExpenseAmount
            }
        return totals
            .map { BankCategorySpending(category: $0.key, amount: $0.value.currencyRounded) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category.rawValue < $1.category.rawValue }
    }

    func setBankTransaction(_ transaction: BankTransaction, nature: String, refundOf: UUID? = nil) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransaction(transaction, nature: nature, refundOf: refundOf)
        reload()
    }

    func setBankTransaction(_ transaction: BankTransaction, category: ExpenseCategory) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransaction(transaction, category: category)
        reload()
    }

    func setBankTransaction(_ transaction: BankTransaction, isInternalTransfer: Bool) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransaction(transaction, isInternalTransfer: isInternalTransfer)
        reload()
    }

    func setBankTransaction(_ transaction: BankTransaction, isIgnored: Bool) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransaction(transaction, isIgnored: isIgnored)
        reload()
    }

    func setBankTransaction(_ transaction: BankTransaction, link: BankTransactionLink?) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransaction(transaction, link: link)
        reload()
    }

    func setBankTransactionNote(id: UUID, note: String) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.updateBankTransactionNote(id: id, note: note)
        reload()
    }

    func resetBankTransactionCategory(id: UUID) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.resetBankTransactionCategory(id: id)
        reload()
    }

    func linkedEntityName(for transaction: BankTransaction) -> String? {
        switch transaction.link {
        case .subscription(let id): return subscriptions.first { $0.id == id }?.name
        case .purchase(let id): return purchases.first { $0.id == id }?.title
        case .income(let id): return incomeSources.first { $0.id == id }?.name
        case nil: return nil
        }
    }

    func externalAccount(id: UUID) -> ExternalAccount? {
        externalAccounts.first { $0.id == id }
    }

    var linkedExternalAccounts: [ExternalAccount] {
        externalAccounts.filter { !$0.isManual }
    }

    func addManualAccount(name: String, balance: Decimal) throws {
        try dataStore.addManualAccount(name: name, balance: balance)
        reload()
    }

    func updateManualAccount(_ account: ExternalAccount, name: String, balance: Decimal) throws {
        try dataStore.updateManualAccount(account, name: name, balance: balance)
        reload()
    }
}

extension AppState {
    func observedMonth(containing date: Date, calendar: Calendar = .current) -> ObservedMonth? {
        observedMonths.first { $0.month.contains(date) }
    }

    var categoryTrends: [CategoryTrend] {
        MonthlyObservationService(calendar: .current).categoryTrends(in: observedMonths)
    }
}

extension AppState {
    var currentRecurringCharges: [RecurringCharge] {
        recurringCharges.filter { $0.isCurrent(on: Date()) }
    }

    var historicalRecurringCharges: [RecurringCharge] {
        recurringCharges.filter { !$0.isCurrent(on: Date()) }
    }

    var estimatedAnnualRecurringCost: Decimal {
        currentRecurringCharges.reduce(Decimal.zero) { total, charge in
            total + charge.latestAmount * (charge.cadence == .monthly ? 12 : 1)
        }.currencyRounded
    }

    func spendingTransactions(in month: Date, calendar: Calendar = .current) -> [BankTransaction] {
        bankTransactions(in: month, direction: .debit, calendar: calendar)
            .filter(\.isExpense)
            .sorted { $0.bookingDate != $1.bookingDate ? $0.bookingDate > $1.bookingDate : $0.externalID < $1.externalID }
    }

    func transactions(for charge: RecurringCharge) -> [BankTransaction] {
        bankTransactions.filter {
            $0.accountID == charge.accountID && $0.isExpense &&
            RecurringChargeDetector.merchantKey(for: $0.label) == charge.key
        }.sorted { $0.bookingDate > $1.bookingDate }
    }

    var untrackedRecurringCharges: [RecurringCharge] {
        RecurringChargeDetector().untracked(currentRecurringCharges, subscriptions: subscriptions)
    }

    var recurringChargesWithPriceIncrease: [RecurringCharge] {
        currentRecurringCharges.filter { $0.priceIncrease != nil }
    }
}

extension AppState {
    func bankFreshness(now: Date, syncingAccountID: UUID? = nil) -> [BankAccountFreshness] {
        let service = BankFreshnessService()
        // Le regroupement complet ne sert que de repli quand les bornes d'historique sont
        // indisponibles. Le construire d'office reparcourait toutes les opérations à chaque
        // rendu, dans une vue qui se rafraîchit toute seule chaque minute.
        var grouped: [UUID: [BankTransaction]]?
        return externalAccounts.map { account in
            let history: [BankTransaction]
            if let bounds = try? dataStore.historyBounds(accountID: account.id) {
                history = bounds
            } else {
                if grouped == nil {
                    grouped = Dictionary(grouping: bankTransactions, by: \.accountID)
                }
                history = grouped?[account.id] ?? []
            }
            return service.status(
                account: account,
                progress: bankImportProgress[account.id],
                transactions: history,
                now: now,
                isSyncing: syncingAccountID == account.id
            )
        }
    }
}

extension AppState {
    func confirmAccountSelection(_ selections: [UUID: Bool]) throws {
        guard isProfileActive else { throw BankTransactionEditError.unavailable }
        try dataStore.confirmAccountSelection(selections)
        reload()
    }
}
