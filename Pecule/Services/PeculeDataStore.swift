import Foundation
import SwiftData

@MainActor
final class PeculeDataStore {
    let container: ModelContainer
    private let context: ModelContext
    private let seedDataService: SeedDataService
    // Une seule passe de nettoyage par lancement suffit : les lignes de démonstration ne sont
    // réintroduites que par l'amorçage, qui relève de l'autre branche du rechargement. Sans ce
    // garde-fou, chaque annotation d'opération relisait un instantané complet pour rien.
    private var hasSweptDemoData = false
    // Même logique pour la réparation des références orphelines : une passe par ouverture du store. Tout
    // ce qui la rendrait nécessaire en cours de session est désormais nettoyé à la suppression.
    private var hasRepairedReferences = false

    init(
        container: ModelContainer,
        seedDataService: SeedDataService = SeedDataService()
    ) {
        self.container = container
        self.context = container.mainContext
        self.seedDataService = seedDataService
    }

    // Toute ouverture d'une base sur disque passe par `PersistentStoreOpener` : copie avant migration,
    // repère de version, et `StoreOpenError` récupérable plutôt qu'une erreur brute du framework.
    static func makeSharedContainer(opener: PersistentStoreOpener = PersistentStoreOpener()) throws -> ModelContainer {
        let configuration: ModelConfiguration
        do { configuration = try makePersistentConfiguration() }
        catch { throw StoreOpenError(stage: .open, underlying: error, backup: nil) }
        return try opener.open(configuration)
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = PeculeSchema.current
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        // Même point d'entrée que les bases sur disque : « ni copie ni repère en mémoire » y est une règle.
        return try PersistentStoreOpener().open(configuration)
    }

    func seedIfNeeded() throws {
        let hasSubscriptions = try context.fetchCount(FetchDescriptor<Subscription>()) > 0
        let hasPurchases = try context.fetchCount(FetchDescriptor<Purchase>()) > 0
        let hasGoals = try context.fetchCount(FetchDescriptor<Goal>()) > 0
        let hasHabits = try context.fetchCount(FetchDescriptor<Habit>()) > 0

        guard !hasSubscriptions, !hasPurchases, !hasGoals, !hasHabits else {
            return
        }

        let seedData = seedDataService.makeSeedData()

        seedData.subscriptions.forEach(context.insert)
        seedData.purchases.forEach(context.insert)
        seedData.goals.forEach(context.insert)
        seedData.habits.forEach(context.insert)
        seedData.incomeSources.forEach(context.insert)
        seedData.monthlyIncomeOverrides.forEach(context.insert)

        try context.save()
    }

    // Fixed fixture IDs plus unchanged fields identify old demo records, never merchant names alone.
    // No schema change is needed; this is idempotent and also works on an existing installation.
    func removeUnmodifiedDemoData() throws {
        guard !hasSweptDemoData else { return }
        defer { hasSweptDemoData = true }
        let snapshot = try loadSnapshot(bankSince: .distantFuture)
        let demo = seedDataService.makeSeedData()
        let subscriptions = snapshot.subscriptions.filter { item in
            demo.subscriptions.contains {
                $0.id == item.id && $0.name == item.name && $0.amount == item.amount &&
                $0.billingCycle == item.billingCycle && $0.category == item.category &&
                $0.nextBillingDate == item.nextBillingDate && $0.isActive == item.isActive
            }
        }
        let purchases = snapshot.purchases.filter { item in
            demo.purchases.contains {
                $0.id == item.id && $0.title == item.title && $0.amount == item.amount &&
                $0.date == item.date && $0.category == item.category &&
                $0.merchant == item.merchant && $0.notes == item.notes
            }
        }
        let goals = snapshot.goals.filter { item in
            demo.goals.contains {
                $0.id == item.id && $0.title == item.title && $0.targetAmount == item.targetAmount &&
                $0.currentAmount == item.currentAmount && $0.targetDate == item.targetDate &&
                $0.category == item.category && $0.isArchived == item.isArchived
            }
        }
        let habits = snapshot.habits.filter { item in
            demo.habits.contains {
                $0.id == item.id && $0.title == item.title && $0.frequency == item.frequency &&
                $0.targetCount == item.targetCount && $0.completedCount == item.completedCount &&
                $0.linkedGoalID == item.linkedGoalID && $0.isActive == item.isActive
            }
        }
        let incomes = snapshot.incomeSources.filter { item in
            demo.incomeSources.contains {
                $0.id == item.id && $0.name == item.name && $0.amount == item.amount &&
                $0.type == item.type && $0.startDate == item.startDate && $0.endDate == item.endDate &&
                $0.isRecurring == item.isRecurring && $0.isActive == item.isActive
            } && !snapshot.monthlyIncomeOverrides.contains { override in
                override.incomeSourceID == item.id && !demo.monthlyIncomeOverrides.contains {
                    $0.id == override.id && $0.amount == override.amount &&
                    $0.monthStartDate == override.monthStartDate && $0.replacesSourceAmount == override.replacesSourceAmount
                }
            }
        }
        let subscriptionIDs = Set(subscriptions.map(\.id))
        let purchaseIDs = Set(purchases.map(\.id))
        let incomeIDs = Set(incomes.map(\.id))
        let goalIDs = Set(goals.map(\.id))
        let needsCleanup = !subscriptionIDs.isEmpty || !purchaseIDs.isEmpty || !incomeIDs.isEmpty
        // The snapshot above already holds exactly the linked rows this loop can change.
        for transaction in needsCleanup ? snapshot.bankTransactions : [] {
            if let id = transaction.linkedSubscriptionID, subscriptionIDs.contains(id) { transaction.linkedSubscriptionID = nil }
            if let id = transaction.linkedPurchaseID, purchaseIDs.contains(id) { transaction.linkedPurchaseID = nil }
            if let id = transaction.linkedIncomeSourceID, incomeIDs.contains(id) { transaction.linkedIncomeSourceID = nil }
        }
        for habit in snapshot.habits where !habits.contains(where: { $0.id == habit.id }) {
            if let id = habit.linkedGoalID, goalIDs.contains(id) { habit.linkedGoalID = nil }
        }
        snapshot.monthlyIncomeOverrides.filter { incomeIDs.contains($0.incomeSourceID) }.forEach(context.delete)
        subscriptions.forEach(context.delete)
        purchases.forEach(context.delete)
        goals.forEach(context.delete)
        habits.forEach(context.delete)
        incomes.forEach(context.delete)
        if context.hasChanges { try context.save() }
    }

    // Called when the store is loaded: repairs what earlier versions left behind (see `repairOrphanedReferences`).
    func repairOrphanedReferencesOnce() throws {
        guard !hasRepairedReferences else { return }
        defer { hasRepairedReferences = true }
        _ = try repairOrphanedReferences()
    }

    func loadSnapshot(bankSince: Date = .distantPast) throws -> AppDataSnapshot {
        try Self.loadSnapshot(in: context, bankSince: bankSince)
    }

    // Lisible depuis n'importe quel contexte : l'export lit la table entière sur un contexte d'arrière-plan.
    nonisolated static func loadSnapshot(in context: ModelContext, bankSince: Date = .distantPast) throws -> AppDataSnapshot {
        return AppDataSnapshot(
            subscriptions: try context.fetch(
                FetchDescriptor<Subscription>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ),
            purchases: try context.fetch(
                FetchDescriptor<Purchase>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ),
            goals: try context.fetch(
                FetchDescriptor<Goal>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ),
            habits: try context.fetch(
                FetchDescriptor<Habit>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ),
            incomeSources: try context.fetch(
                FetchDescriptor<IncomeSource>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ),
            monthlyIncomeOverrides: try context.fetch(
                FetchDescriptor<MonthlyIncomeOverride>(
                    sortBy: [
                        SortDescriptor(\.monthStartDate),
                        SortDescriptor(\.id)
                    ]
                )
            ),
            budgetRules: try context.fetch(
                FetchDescriptor<BudgetRule>(
                    sortBy: [
                        SortDescriptor(\.category),
                        SortDescriptor(\.id)
                    ]
                )
            ),
            budgetOverrides: try context.fetch(
                FetchDescriptor<BudgetOverride>(
                    sortBy: [
                        SortDescriptor(\.year),
                        SortDescriptor(\.month),
                        SortDescriptor(\.category),
                        SortDescriptor(\.id)
                    ]
                )
            ),
            externalAccounts: try context.fetch(
                FetchDescriptor<ExternalAccount>(
                    sortBy: [
                        SortDescriptor(\.name),
                        SortDescriptor(\.id)
                    ]
                )
            ),
            bankTransactions: try context.fetch(
                FetchDescriptor<BankTransaction>(
                    predicate: #Predicate { $0.bookingDate >= bankSince || $0.linkedPurchaseID != nil || $0.linkedSubscriptionID != nil || $0.linkedIncomeSourceID != nil },
                    sortBy: [
                        SortDescriptor(\.bookingDate, order: .reverse),
                        SortDescriptor(\.id)
                    ]
                )
            )
        )
    }

    @discardableResult
    func saveExternalAccounts(_ accounts: [ExternalAccount]) throws -> [ExternalAccount] {
        let existingAccounts = try context.fetch(FetchDescriptor<ExternalAccount>())
        var savedAccounts: [ExternalAccount] = []

        for account in accounts {
            if let existing = existingAccounts.first(where: { $0.stableIdentifier == account.stableIdentifier })
                ?? existingAccounts.first(where: { Self.isLegacyIdentifier($0.stableIdentifier, matching: account) }) {
                if existing.stableIdentifier != account.stableIdentifier {
                    try rekeyExternalAccount(existing, to: account.stableIdentifier)
                }
                existing.requiresInclusionReview = account.requiresInclusionReview
                existing.currentUID = account.currentUID
                existing.linkID = account.linkID
                existing.institution = account.institution
                existing.name = account.name
                existing.maskedIBAN = account.maskedIBAN
                existing.currencyCode = account.currencyCode
                existing.consentValidUntil = account.consentValidUntil
                existing.status = account.status
                existing.lastSyncError = nil
                savedAccounts.append(existing)
            } else {
                context.insert(account)
                savedAccounts.append(account)
            }
        }

        try context.save()
        return savedAccounts
    }

    // Accounts first linked before the gateway computed a hash were keyed on their full IBAN.
    private static func isLegacyIdentifier(_ identifier: String, matching account: ExternalAccount) -> Bool {
        guard !identifier.hasPrefix("manual:"), let maskedIBAN = account.maskedIBAN else {
            return false
        }
        return ExternalAccount.maskedIBAN(from: identifier) == maskedIBAN && identifier.count > 15 && identifier.uppercased() == identifier
    }

    private func rekeyExternalAccount(_ account: ExternalAccount, to stableIdentifier: String) throws {
        let accountID = account.id
        let oldPrefix = account.stableIdentifier + "#"
        let transactions = try context.fetch(
            FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.accountID == accountID })
        )
        for transaction in transactions where transaction.externalID.hasPrefix(oldPrefix) {
            transaction.externalID = stableIdentifier + "#" + transaction.externalID.dropFirst(oldPrefix.count)
        }
        account.stableIdentifier = stableIdentifier
    }

    func updateExternalAccountBalance(
        _ account: ExternalAccount,
        balance: Decimal?,
        balanceType: String?,
        balanceDate: Date?,
        currencyCode: String? = nil,
        syncedAt: Date?
    ) throws {
        account.balance = balance?.currencyRounded
        account.balanceType = balanceType
        account.balanceDate = balanceDate
        if let currencyCode {
            account.currencyCode = currencyCode
        }
        // Without a date this only records the balance: the synchronization it belongs to did not succeed.
        if let syncedAt {
            account.lastSyncedAt = syncedAt
            account.lastSyncError = nil
            account.status = ExternalAccountStatus.active.rawValue
        }
        try context.save()
    }

    @discardableResult
    func addManualAccount(name: String, balance: Decimal) throws -> ExternalAccount {
        let account = ExternalAccount(manualName: name.trimmingCharacters(in: .whitespacesAndNewlines), balance: balance)
        context.insert(account)
        try context.save()
        return account
    }

    func updateManualAccount(_ account: ExternalAccount, name: String, balance: Decimal) throws {
        account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.balance = balance.currencyRounded
        account.balanceDate = nil
        try context.save()
    }

    func confirmAccountSelection(_ selections: [UUID: Bool]) throws {
        let accounts = try context.fetch(FetchDescriptor<ExternalAccount>())
        let selected = accounts.filter { selections[$0.id] != nil }
        guard selected.count == selections.count, selected.allSatisfy({ $0.requiresInclusionReview }) else { throw BankTransactionEditError.unavailable }
        for account in selected {
            account.isIncludedInTotals = selections[account.id] ?? false
            account.requiresInclusionReview = false
        }
        try context.save()
    }

    func updateExternalAccountInclusion(_ account: ExternalAccount, isIncludedInTotals: Bool) throws {
        account.isIncludedInTotals = isIncludedInTotals
        try context.save()
    }

    func updateExternalAccountStatus(
        _ account: ExternalAccount,
        status: ExternalAccountStatus,
        error: String?
    ) throws {
        account.status = status.rawValue
        account.lastSyncError = error
        try context.save()
    }

    @discardableResult
    func importBankTransactions(_ transactions: [BankTransaction]) throws -> Int {
        try importBankTransactionsReturningInsertedIDs(transactions).count
    }

    // The synchronization needs to know which rows this import created: a pending entry the bank
    // re-books under another reference can only be paired with a row that appeared in the same window.
    func importBankTransactionsReturningInsertedIDs(_ transactions: [BankTransaction]) throws -> [String] {
        guard !transactions.isEmpty else {
            return []
        }

        let accountIDs = Array(Set(transactions.map(\.accountID)))
        let existingTransactions = try context.fetch(
            FetchDescriptor<BankTransaction>(
                predicate: #Predicate { accountIDs.contains($0.accountID) }
            )
        )
        var knownTransactions = Dictionary(existingTransactions.map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })
        var insertedIDs: [String] = []
        var hasChanges = false

        for transaction in transactions {
            if let existing = knownTransactions[transaction.externalID] {
                if existing.isAbsentFromBank {
                    existing.isAbsentFromBank = false
                    hasChanges = true
                }
                // Legacy categories may already be user corrections; preserve their unknown provenance.
                if let automatic = transaction.automaticCategory,
                   existing.automaticCategory != nil || existing.categoryOverride != nil {
                    let category = existing.categoryOverride ?? automatic
                    if existing.automaticCategory != automatic || existing.category != category {
                        existing.automaticCategory = automatic
                        existing.category = category
                        try updateRefundCategories(for: existing)
                        hasChanges = true
                    }
                }
                if existing.internalTransferOverride == nil && existing.natureOverride == "automatic" && transaction.isInternalTransfer {
                    existing.isInternalTransfer = true
                    existing.transferEvidence = transaction.transferEvidence
                    hasChanges = true
                }
                // Banks revise amounts and settle pending entries under the same reference.
                if existing.amount != transaction.amount || existing.status != transaction.status ||
                    existing.valueDate != transaction.valueDate || existing.bookingDate != transaction.bookingDate ||
                    existing.label != transaction.label || existing.counterpartyName != transaction.counterpartyName ||
                    existing.direction != transaction.direction || existing.currencyCode != transaction.currencyCode ||
                    existing.merchantCategoryCode != transaction.merchantCategoryCode || existing.bankTransactionCode != transaction.bankTransactionCode {
                    existing.amount = transaction.amount
                    existing.status = transaction.status
                    existing.valueDate = transaction.valueDate
                    existing.bookingDate = transaction.bookingDate
                    existing.label = transaction.label
                    existing.counterpartyName = transaction.counterpartyName
                    existing.direction = transaction.direction
                    existing.currencyCode = transaction.currencyCode
                    existing.merchantCategoryCode = transaction.merchantCategoryCode
                    existing.bankTransactionCode = transaction.bankTransactionCode
                    hasChanges = true
                }
            } else {
                context.insert(transaction)
                knownTransactions[transaction.externalID] = transaction
                insertedIDs.append(transaction.externalID)
                hasChanges = true
            }
        }

        if hasChanges {
            try context.save()
        }

        return insertedIDs
    }

    func recentBankTransactions(since date: Date) throws -> [BankTransaction] {
        try context.fetch(
            FetchDescriptor<BankTransaction>(
                predicate: #Predicate { $0.bookingDate >= date },
                sortBy: [SortDescriptor(\.bookingDate)]
            )
        )
    }

    // Reconciles the whole detection window instead of only adding marks: an automatic pairing is a
    // verdict on current evidence, so when the counterpart disappears the verdict goes with it.
    // User decisions (internalTransferOverride, natureOverride) are never touched.
    @discardableResult
    func reconcileInternalTransfers(consideredIDs: Set<String>, pairedIDs: Set<String>) throws -> Int {
        guard !consideredIDs.isEmpty else {
            return 0
        }
        let ids = Array(consideredIDs)
        let transactions = try context.fetch(
            FetchDescriptor<BankTransaction>(
                predicate: #Predicate { ids.contains($0.externalID) }
            )
        )
        var changed = 0
        for transaction in transactions where transaction.internalTransferOverride == nil && transaction.natureOverride == "automatic" {
            if pairedIDs.contains(transaction.externalID) {
                guard !transaction.isInternalTransfer else { continue }
                transaction.isInternalTransfer = true
                transaction.transferEvidence = ClassificationEvidence.pairedAccounts.rawValue
                changed += 1
            } else if transaction.isInternalTransfer && transaction.transferEvidence == ClassificationEvidence.pairedAccounts.rawValue {
                transaction.isInternalTransfer = false
                transaction.transferEvidence = nil
                changed += 1
            }
        }
        if changed > 0 {
            try context.save()
        }
        return changed
    }

    func updateBankTransaction(_ transaction: BankTransaction, category: ExpenseCategory) throws {
        let current = try editableBankTransaction(id: transaction.id)
        current.categoryOverride = category.storageValue
        current.category = category.storageValue
        try updateRefundCategories(for: current)
        try context.save()
    }

    func resetBankTransactionCategory(id: UUID) throws {
        let current = try editableBankTransaction(id: id)
        let automatic = BankTransactionCategorizer().category(label: current.label, counterparty: current.counterpartyName,
            merchantCategoryCode: current.merchantCategoryCode, bankTransactionCode: current.bankTransactionCode).storageValue
        current.automaticCategory = automatic
        current.categoryOverride = nil
        current.category = automatic
        try updateRefundCategories(for: current)
        try context.save()
    }

    func updateBankTransactionNote(id: UUID, note: String) throws {
        let current = try editableBankTransaction(id: id)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        current.userNote = trimmed.isEmpty ? nil : trimmed
        try context.save()
    }

    func editableBankTransaction(id: UUID) throws -> BankTransaction {
        var descriptor = FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let current = try context.fetch(descriptor).first else { throw BankTransactionEditError.unavailable }
        return current
    }

    private func updateRefundCategories(for expense: BankTransaction) throws {
        let id = expense.id
        for refund in try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.refundOfTransactionID == id })) {
            refund.category = expense.category
            refund.categoryOverride = expense.category
        }
    }

    private func referencedRefundExpenseIDs() throws -> Set<UUID> {
        let refundIDs = Set(try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.refundOfTransactionID != nil })).compactMap(\.refundOfTransactionID))
        let paymentIDs = Set(try planningFetch(CommitmentPayment.self).map(\.transactionID))
        let sourceIDs = Set(try planningFetch(PlannedCommitment.self).filter { $0.sourceKind == "installment" }.compactMap(\.sourceID))
        let provisionIDs = Set(try planningFetch(ProvisionPayment.self).map(\.transactionID))
        return refundIDs.union(paymentIDs).union(sourceIDs).union(provisionIDs)
    }

    func updateBankTransaction(_ transaction: BankTransaction, isInternalTransfer: Bool) throws {
        let current = try editableBankTransaction(id: transaction.id)
        current.isInternalTransfer = isInternalTransfer
        current.internalTransferOverride = isInternalTransfer
        if isInternalTransfer {
            if current.normalizedDirection == .credit { current.natureOverride = "internalTransfer" }
        } else if current.natureOverride == "internalTransfer" {
            current.natureOverride = current.normalizedDirection == .credit ? "needsReview" : "automatic"
        }
        try context.save()
    }

    func updateBankTransaction(_ transaction: BankTransaction, isIgnored: Bool) throws {
        let current = try editableBankTransaction(id: transaction.id)
        current.isIgnored = isIgnored
        try context.save()
    }

    func updateBankTransaction(_ transaction: BankTransaction, link: BankTransactionLink?) throws {
        let current = try editableBankTransaction(id: transaction.id)
        current.apply(link)
        try context.save()
    }

    // `matches` come in date order. A subscription's billing date follows what the bank settled: it moves to the
    // first cycle after the linked operation, whether the date was on time or had been left behind.
    @discardableResult
    func applyReconciliation(_ matches: [BankReconciliationService.Match], advancingBillingDates: Bool, referenceDate: Date, calendar: Calendar = .current) throws -> Int {
        guard !matches.isEmpty else {
            return 0
        }
        let ids = matches.map(\.externalID)
        let transactions = try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { ids.contains($0.externalID) }))
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let reconciliation = BankReconciliationService()
        var applied = 0

        for match in matches {
            guard let transaction = transactions.first(where: { $0.externalID == match.externalID }) else {
                continue
            }
            transaction.apply(BankTransactionLink(match.link))
            applied += 1
            if advancingBillingDates, case .subscription(let id) = match.link,
               let subscription = subscriptions.first(where: { $0.id == id }) {
                let next = reconciliation.nextBillingDate(settledOn: transaction.bookingDate, anchor: subscription.nextBillingDate, cycle: subscription.billingCycle, calendar: calendar)
                if next > subscription.nextBillingDate {
                    try advanceBillingDate(of: subscription, to: next)
                }
            }
        }

        if applied > 0 {
            try context.save()
        }
        return applied
    }

    // The one way a subscription's billing date moves on its own: the planned commitment drawn from the
    // subscription moves with it, so the subscriptions and commitments screens never show two dates.
    // The caller saves.
    func advanceBillingDate(of subscription: Subscription, to date: Date) throws {
        subscription.nextBillingDate = date
        for record in try planningFetch(PlannedCommitment.self) where record.sourceKind == "subscription" && record.sourceID == subscription.id {
            record.dueDate = date
        }
    }

    // Removes local transactions the bank no longer returns for a window it fully re-sent.
    // `insertedExternalIDs` are the rows this window created: an annotated pending entry the bank
    // re-booked under a new reference hands its annotations to its one look-alike among them, then goes
    // with the other vanished rows instead of lingering as an annotated ghost that no total counts.
    @discardableResult
    func pruneBankTransactions(
        accountID: UUID,
        bookedOnOrAfter windowStart: Date,
        keeping externalIDs: Set<String>,
        insertedExternalIDs: Set<String> = [],
        pendingOnly: Bool = false
    ) throws -> Int {
        let candidates = try context.fetch(
            FetchDescriptor<BankTransaction>(
                predicate: #Predicate { $0.accountID == accountID && $0.bookingDate >= windowStart }
            )
        )
        let missing = candidates.filter { !externalIDs.contains($0.externalID) && (!pendingOnly || $0.normalizedStatus == .pending) }
        let referencedIDs = try referencedRefundExpenseIDs()
        let rebooked = adoptAnnotationsOfRebookedPendingEntries(
            missing: missing,
            insertedThisWindow: candidates.filter { insertedExternalIDs.contains($0.externalID) && externalIDs.contains($0.externalID) },
            referencedIDs: referencedIDs
        )
        let preserved = missing.filter { !rebooked.contains($0.id) && ($0.hasUserAnnotations || referencedIDs.contains($0.id)) }
        // Keep annotations inspectable while excluding a movement withdrawn by the bank from totals.
        preserved.forEach { $0.isAbsentFromBank = true }
        let removed = missing.filter { rebooked.contains($0.id) || (!$0.hasUserAnnotations && !referencedIDs.contains($0.id)) }
        try deleteBankTransactions(removed)
        if !missing.isEmpty {
            try context.save()
        }
        return removed.count
    }

    private static let rebookingToleranceDays = 3

    // Pending entries are often re-booked under a new reference (BankTransaction.isExpense). Pairs each
    // annotated pending entry the bank dropped with the one new row of the window that looks like its
    // booked successor (same account, amount, direction and currency, dated within a few days, no
    // annotation yet) and moves the annotations there. Returns the entries whose annotations moved.
    // Any doubt pairs nothing: a note moved onto the wrong operation is worse than one left on a ghost.
    private func adoptAnnotationsOfRebookedPendingEntries(
        missing: [BankTransaction],
        insertedThisWindow: [BankTransaction],
        referencedIDs: Set<UUID>
    ) -> Set<UUID> {
        let successors = insertedThisWindow.filter { !$0.hasUserAnnotations }
        guard !successors.isEmpty else { return [] }
        // Bank days are pinned at noon UTC (BankGatewayDateParser), so their distance is read in UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        func dayDistance(_ first: Date, _ second: Date) -> Int {
            abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: second)).day ?? .max)
        }
        // Planned commitments and refunds point at the entry itself: it stays where it is.
        let orphans = missing.filter { $0.normalizedStatus == .pending && $0.hasUserAnnotations && !referencedIDs.contains($0.id) }
        let pairs = orphans.compactMap { orphan -> (orphan: BankTransaction, successor: BankTransaction)? in
            let lookAlikes = successors.filter {
                $0.accountID == orphan.accountID && $0.amount == orphan.amount && $0.direction == orphan.direction
                    && $0.currencyCode == orphan.currencyCode
                    && dayDistance($0.bookingDate, orphan.bookingDate) <= Self.rebookingToleranceDays
            }
            return lookAlikes.count == 1 ? (orphan, lookAlikes[0]) : nil
        }
        // A successor wanted by two pending entries is ambiguous for both.
        let demand = Dictionary(grouping: pairs, by: { $0.successor.id })
        var moved = Set<UUID>()
        for pair in pairs where demand[pair.successor.id]?.count == 1 {
            pair.successor.adoptAnnotations(from: pair.orphan)
            moved.insert(pair.orphan.id)
        }
        return moved
    }

    func importCheckpoint(accountID: UUID) throws -> BankImportCheckpoint {
        if let checkpoint = try context.fetch(FetchDescriptor<BankImportCheckpoint>(predicate: #Predicate { $0.accountID == accountID })).first {
            return checkpoint
        }
        let checkpoint = BankImportCheckpoint(accountID: accountID)
        context.insert(checkpoint)
        try context.save()
        return checkpoint
    }

    func saveImportCheckpoint() throws { try context.save() }

    func bankImportProgress() throws -> [UUID: BankImportProgress] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BankImportCheckpoint>()).map {
            ($0.accountID, BankImportProgress(initialImportCompleted: $0.initialImportCompleted,
                pendingWindowStart: $0.windowStart, requestedHistoryStart: $0.requestedHistoryStart,
                lastAttemptAt: $0.lastAttemptAt, lastFailedAt: $0.lastFailedAt))
        })
    }

    func recordBankSyncAttempt(accountID: UUID, at date: Date, failed: Bool = false) throws {
        let checkpoint = try importCheckpoint(accountID: accountID)
        if failed { checkpoint.lastFailedAt = date } else { checkpoint.lastAttemptAt = date }
        try context.save()
    }

    func pendingBankAuthorization() throws -> BankPendingAuthorization? {
        try context.fetch(FetchDescriptor<BankPendingAuthorization>()).first
    }

    func savePendingBankAuthorization(linkID: String, institution: BankInstitution, expiresAt: Date, requiresAccountSelection: Bool = false) throws {
        if let pending = try pendingBankAuthorization() {
            pending.linkID = linkID
            pending.institution = institution.rawValue
            pending.expiresAt = expiresAt
            pending.requiresAccountSelection = requiresAccountSelection
        } else {
            let pending = BankPendingAuthorization(linkID: linkID, institution: institution, expiresAt: expiresAt)
            pending.requiresAccountSelection = requiresAccountSelection
            context.insert(pending)
        }
        try context.save()
    }

    func clearPendingBankAuthorization() throws {
        for pending in try context.fetch(FetchDescriptor<BankPendingAuthorization>()) { context.delete(pending) }
        try context.save()
    }

    func updateBankTransaction(_ transaction: BankTransaction, nature: String, refundOf: UUID? = nil) throws {
        let current = try editableBankTransaction(id: transaction.id)
        guard (["automatic", "income", "salary", "personalTransfer", "otherIncome", "refund", "needsReview", "internalTransfer"].contains(nature) && current.normalizedDirection == .credit) || nature == "internalTransfer" else { throw BankTransactionEditError.unavailable }
        if let refundOf {
            let expense = try editableBankTransaction(id: refundOf)
            guard nature == "refund", expense.isExpense else { throw BankTransactionEditError.unavailable }
            current.category = expense.category
            current.categoryOverride = expense.category
        }
        current.natureOverride = nature
        current.internalTransferOverride = nature == "automatic" ? nil : nature == "internalTransfer"
        current.isInternalTransfer = nature == "internalTransfer" || (nature == "automatic" && current.transferEvidence != nil)
        current.refundOfTransactionID = nature == "refund" ? refundOf : nil
        current.linkedIncomeSourceID = nil
        try context.save()
    }

    func latestBankTransactionDate(accountID: UUID) throws -> Date? {
        var descriptor = FetchDescriptor<BankTransaction>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.bookingDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.bookingDate
    }

    // Retain annotations and historical categories whose provenance predates V3.
    // Expired consent stops bank access; it is not a request to delete an account or its history.
    func applyBankRetention(_ policy: BankRetentionPolicy = .default, now: Date = Date(), calendar: Calendar = .current) throws -> BankRetentionReport {
        let cutoff = policy.cutoffDate(now: now, calendar: calendar)
        let referencedIDs = try referencedRefundExpenseIDs()
        let expired = try context.fetch(
            FetchDescriptor<BankTransaction>(
                predicate: #Predicate { $0.bookingDate < cutoff }
            )
        )
        .filter { !$0.hasUserAnnotations && $0.automaticCategory != nil && !referencedIDs.contains($0.id) }
        try deleteBankTransactions(expired)
        if !expired.isEmpty {
            try context.save()
        }
        return BankRetentionReport(purgedTransactions: expired.count, removedAccounts: [])
    }

    // Removes the account, its operations and everything planned on them or on the account: no row is left
    // pointing at what is gone (a payment of a deleted operation would block editing its commitment or goal).
    func deleteExternalAccount(_ account: ExternalAccount) throws {
        let accountID = account.id
        do {
            let transactions = try context.fetch(
                FetchDescriptor<BankTransaction>(
                    predicate: #Predicate { $0.accountID == accountID }
                )
            )
            let deletedIDs = Set(transactions.map(\.id))
            for refund in try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.refundOfTransactionID != nil })) {
                if let original = refund.refundOfTransactionID, deletedIDs.contains(original) { refund.refundOfTransactionID = nil }
            }
            try deleteBankTransactions(transactions)
            try detachPlanningRows(fromAccount: accountID)
            try context.fetch(FetchDescriptor<BankImportCheckpoint>(predicate: #Predicate { $0.accountID == accountID })).forEach(context.delete)
            context.delete(account)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func bankTransactionCount(accountID: UUID) throws -> Int {
        try context.fetchCount(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.accountID == accountID }))
    }

    // The other bank accounts covered by the same consent: a link carries every account the customer
    // authorized at once, and the consent may only be revoked with the last of them.
    func linkSiblings(of account: ExternalAccount) throws -> [ExternalAccount] {
        let linkID = account.linkID
        return try context.fetch(FetchDescriptor<ExternalAccount>(predicate: #Predicate { $0.linkID == linkID }))
            .filter { account.sharesLink(with: $0) }
    }

    func addSubscription(
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: String,
        nextBillingDate: Date,
        isActive: Bool
    ) throws {
        let subscription = Subscription(
            name: name,
            amount: amount.currencyRounded,
            billingCycle: billingCycle,
            category: category,
            nextBillingDate: nextBillingDate,
            isActive: isActive
        )

        context.insert(subscription)
        try context.save()
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
        subscription.name = name
        subscription.amount = amount.currencyRounded
        subscription.billingCycle = billingCycle
        subscription.category = category
        subscription.nextBillingDate = nextBillingDate
        subscription.isActive = isActive
        if let record = try planningFetch(PlannedCommitment.self).first(where: { $0.sourceKind == "subscription" && $0.sourceID == subscription.id }) {
            var draft = CommitmentDraft(record)
            draft.title = name; draft.amount = amount; draft.category = category
            draft.dueDate = nextBillingDate; draft.cadence = billingCycle == .yearly ? "yearly" : "monthly"
            draft.status = isActive ? "confirmed" : "stopped"
            do { try saveCommitment(draft) } catch { context.rollback(); throw error }
        }
        try context.save()
    }

    func deleteSubscription(_ subscription: Subscription) throws {
        for record in try planningFetch(PlannedCommitment.self) where record.sourceKind == "subscription" && record.sourceID == subscription.id {
            record.status = "stopped"
        }
        // Operations stay in the books, but no longer claim a subscription that is gone.
        let subscriptionID = subscription.id
        try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.linkedSubscriptionID == subscriptionID }))
            .forEach { $0.linkedSubscriptionID = nil }
        context.delete(subscription)
        try context.save()
    }

    func addPurchase(
        title: String,
        amount: Decimal,
        date: Date,
        category: String,
        merchant: String,
        notes: String?
    ) throws {
        let purchase = Purchase(
            title: title,
            amount: amount.currencyRounded,
            date: date,
            category: category,
            merchant: merchant,
            notes: normalizedNotes(notes)
        )

        context.insert(purchase)
        try context.save()
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
        purchase.title = title
        purchase.amount = amount.currencyRounded
        purchase.date = date
        purchase.category = category
        purchase.merchant = merchant
        purchase.notes = normalizedNotes(notes)

        try context.save()
    }

    func deletePurchase(_ purchase: Purchase) throws {
        let purchaseID = purchase.id
        try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.linkedPurchaseID == purchaseID }))
            .forEach { $0.linkedPurchaseID = nil }
        context.delete(purchase)
        try context.save()
    }

    func addGoal(
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String
    ) throws {
        let goal = Goal(
            title: title,
            targetAmount: targetAmount.currencyRounded,
            currentAmount: currentAmount.currencyRounded,
            targetDate: targetDate,
            category: category,
            isArchived: false
        )

        context.insert(goal)
        try context.save()
    }

    func updateGoal(
        _ goal: Goal,
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String
    ) throws {
        goal.title = title
        goal.targetAmount = targetAmount.currencyRounded
        goal.currentAmount = currentAmount.currencyRounded
        goal.targetDate = targetDate
        goal.category = category

        try context.save()
    }

    func deleteGoal(_ goal: Goal) throws {
        let contributions = try goalContributions().filter { $0.goalID == goal.id }
        guard GoalFundingService().totalReserved(goalID: goal.id, contributions: contributions) == 0 else { throw BankTransactionEditError.unavailable }
        guard try !planningFetch(ProvisionPayment.self).contains(where: { $0.goalID == goal.id }) else { throw BankTransactionEditError.unavailable }
        try planningFetch(GoalProvision.self).filter { $0.goalID == goal.id }.forEach(context.delete)
        try planningFetch(GoalAllocation.self).filter { $0.goalID == goal.id }.forEach(context.delete)
        // A habit keeps its link to a goal only while the goal exists: the picker has no label for a ghost.
        let goalID = goal.id
        try context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.linkedGoalID == goalID }))
            .forEach { $0.linkedGoalID = nil }
        contributions.forEach(context.delete)
        context.delete(goal)
        try context.save()
    }

    func addHabit(
        title: String,
        frequency: HabitFrequency,
        targetCount: Int,
        completedCount: Int,
        linkedGoalID: UUID?
    ) throws {
        let habit = Habit(
            title: title,
            frequency: frequency,
            targetCount: max(targetCount, 1),
            completedCount: max(0, min(completedCount, targetCount)),
            linkedGoalID: linkedGoalID,
            isActive: true
        )

        context.insert(habit)
        try context.save()
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

        habit.title = title
        habit.frequency = frequency
        habit.targetCount = safeTargetCount
        habit.completedCount = max(0, min(completedCount, safeTargetCount))
        habit.linkedGoalID = linkedGoalID

        try context.save()
    }

    func markHabitCompleted(_ habit: Habit) throws {
        guard habit.completedCount < habit.targetCount else {
            return
        }

        habit.completedCount += 1
        try context.save()
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
        let incomeSource = IncomeSource(
            name: name,
            amount: amount.currencyRounded,
            type: type,
            startDate: startDate,
            endDate: normalizedIncomeEndDate(endDate, startDate: startDate, isRecurring: isRecurring),
            isRecurring: isRecurring,
            isActive: isActive
        )

        context.insert(incomeSource)
        try context.save()
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
        incomeSource.name = name
        incomeSource.amount = amount.currencyRounded
        incomeSource.type = type
        incomeSource.startDate = startDate
        incomeSource.endDate = normalizedIncomeEndDate(
            endDate,
            startDate: startDate,
            isRecurring: isRecurring
        )
        incomeSource.isRecurring = isRecurring
        incomeSource.isActive = isActive

        try context.save()
    }

    func deleteIncomeSource(_ incomeSource: IncomeSource) throws {
        let linkedOverrides = try context.fetch(FetchDescriptor<MonthlyIncomeOverride>())
            .filter { $0.incomeSourceID == incomeSource.id }

        linkedOverrides.forEach(context.delete)
        // The credits it settled go back to unmatched income instead of pointing at a deleted source.
        let incomeSourceID = incomeSource.id
        try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.linkedIncomeSourceID == incomeSourceID }))
            .forEach { $0.linkedIncomeSourceID = nil }
        context.delete(incomeSource)

        try context.save()
    }

    func addMonthlyIncomeOverride(
        incomeSourceID: UUID,
        month: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) throws {
        let monthStartDate = normalizedMonthStart(month)

        if let existingOverride = try existingMonthlyIncomeOverride(
            incomeSourceID: incomeSourceID,
            monthStartDate: monthStartDate
        ) {
            existingOverride.amount = amount.currencyRounded
            existingOverride.replacesSourceAmount = replacesSourceAmount
        } else {
            let override = MonthlyIncomeOverride(
                incomeSourceID: incomeSourceID,
                monthStartDate: monthStartDate,
                amount: amount.currencyRounded,
                replacesSourceAmount: replacesSourceAmount
            )

            context.insert(override)
        }

        try context.save()
    }

    func updateMonthlyIncomeOverride(
        _ monthlyIncomeOverride: MonthlyIncomeOverride,
        incomeSourceID: UUID,
        month: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) throws {
        let monthStartDate = normalizedMonthStart(month)

        if let conflictingOverride = try existingMonthlyIncomeOverride(
            incomeSourceID: incomeSourceID,
            monthStartDate: monthStartDate,
            excludingOverrideID: monthlyIncomeOverride.id
        ) {
            context.delete(conflictingOverride)
        }

        monthlyIncomeOverride.incomeSourceID = incomeSourceID
        monthlyIncomeOverride.monthStartDate = monthStartDate
        monthlyIncomeOverride.amount = amount.currencyRounded
        monthlyIncomeOverride.replacesSourceAmount = replacesSourceAmount

        try context.save()
    }

    func deleteMonthlyIncomeOverride(_ monthlyIncomeOverride: MonthlyIncomeOverride) throws {
        context.delete(monthlyIncomeOverride)
        try context.save()
    }

    func setBudgetRule(
        category: String,
        monthlyAmount: Decimal
    ) throws {
        let normalizedCategory = normalizedBudgetCategory(category)

        let safeMonthlyAmount = max(monthlyAmount.currencyRounded, .zero)
        let categoryKey = BudgetRule.categoryKey(for: normalizedCategory)

        if let existingBudgetRule = try existingBudgetRule(for: normalizedCategory) {
            existingBudgetRule.category = normalizedCategory
            existingBudgetRule.monthlyAmount = safeMonthlyAmount
        } else {
            context.insert(
                BudgetRule(
                    category: normalizedCategory,
                    monthlyAmount: safeMonthlyAmount
                )
            )
        }

        let linkedOverrides = try context.fetch(FetchDescriptor<BudgetOverride>())
            .filter { BudgetRule.categoryKey(for: $0.category) == categoryKey }

        linkedOverrides.forEach { budgetOverride in
            budgetOverride.category = normalizedCategory
        }

        try context.save()
    }

    func deleteBudgetRule(_ budgetRule: BudgetRule) throws {
        let categoryKey = BudgetRule.categoryKey(for: budgetRule.category)
        let linkedOverrides = try context.fetch(FetchDescriptor<BudgetOverride>())
            .filter { BudgetRule.categoryKey(for: $0.category) == categoryKey }

        linkedOverrides.forEach(context.delete)
        context.delete(budgetRule)

        try context.save()
    }

    func setBudgetOverride(
        category: String,
        month: Date,
        monthlyAmount: Decimal
    ) throws {
        let normalizedCategory = normalizedBudgetCategory(category)

        let safeMonthlyAmount = max(monthlyAmount.currencyRounded, .zero)
        let monthComponents = budgetMonthComponents(from: month)

        if let existingBudgetRule = try existingBudgetRule(for: normalizedCategory) {
            existingBudgetRule.category = normalizedCategory
        } else {
            context.insert(
                BudgetRule(
                    category: normalizedCategory,
                    monthlyAmount: .zero
                )
            )
        }

        if let existingBudgetOverride = try existingBudgetOverride(
            for: normalizedCategory,
            year: monthComponents.year,
            month: monthComponents.month
        ) {
            existingBudgetOverride.category = normalizedCategory
            existingBudgetOverride.year = monthComponents.year
            existingBudgetOverride.month = monthComponents.month
            existingBudgetOverride.monthlyAmount = safeMonthlyAmount
        } else {
            context.insert(
                BudgetOverride(
                    category: normalizedCategory,
                    year: monthComponents.year,
                    month: monthComponents.month,
                    monthlyAmount: safeMonthlyAmount
                )
            )
        }

        try context.save()
    }

    func deleteBudgetOverride(_ budgetOverride: BudgetOverride) throws {
        context.delete(budgetOverride)
        try context.save()
    }
}

private extension PeculeDataStore {
    static func makePersistentConfiguration() throws -> ModelConfiguration {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )

        let storeURL = applicationSupportURL.appendingPathComponent("LifeOS.store")

        return ModelConfiguration("LifeOS", schema: PeculeSchema.current, url: storeURL)
    }

    func normalizedNotes(_ notes: String?) -> String? {
        guard let notes else {
            return nil
        }

        let trimmedValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    func normalizedBudgetCategory(_ category: String) -> String {
        ExpenseCategory.canonicalStorageValue(for: category)
    }

    func normalizedIncomeEndDate(
        _ endDate: Date?,
        startDate: Date,
        isRecurring: Bool
    ) -> Date? {
        guard isRecurring, let endDate else {
            return nil
        }

        return endDate < startDate ? startDate : endDate
    }

    func normalizedMonthStart(_ date: Date) -> Date {
        Calendar.current.peculeMonthStart(for: date)
    }

    func budgetMonthComponents(from date: Date) -> (year: Int, month: Int) {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return (components.year ?? 0, components.month ?? 1)
    }

    func existingBudgetRule(for category: String) throws -> BudgetRule? {
        let categoryKey = BudgetRule.categoryKey(for: category)

        return try context.fetch(FetchDescriptor<BudgetRule>()).first { budgetRule in
            BudgetRule.categoryKey(for: budgetRule.category) == categoryKey
        }
    }

    func existingBudgetOverride(
        for category: String,
        year: Int,
        month: Int
    ) throws -> BudgetOverride? {
        let categoryKey = BudgetRule.categoryKey(for: category)

        return try context.fetch(FetchDescriptor<BudgetOverride>()).first { budgetOverride in
            BudgetRule.categoryKey(for: budgetOverride.category) == categoryKey &&
            budgetOverride.matches(year: year, month: month)
        }
    }

    func existingMonthlyIncomeOverride(
        incomeSourceID: UUID,
        monthStartDate: Date,
        excludingOverrideID: UUID? = nil
    ) throws -> MonthlyIncomeOverride? {
        try context.fetch(FetchDescriptor<MonthlyIncomeOverride>()).first { monthlyIncomeOverride in
            monthlyIncomeOverride.incomeSourceID == incomeSourceID &&
            monthlyIncomeOverride.id != excludingOverrideID &&
            Calendar.current.peculeMonthStart(for: monthlyIncomeOverride.monthStartDate) == monthStartDate
        }
    }
}
