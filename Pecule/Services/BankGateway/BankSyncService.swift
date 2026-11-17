import Foundation
import os

enum BankLinkCallback: Equatable {
    case done(linkID: String)
    case error(code: String)

    init?(url: URL) {
        guard
            url.scheme == "lifeos",
            url.host == "link",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value }
        switch components.path {
        case "/done":
            guard let linkID = value("linkId"), !linkID.isEmpty else {
                return nil
            }
            self = .done(linkID: linkID)
        case "/error":
            self = .error(code: value("code") ?? "unknown")
        default:
            return nil
        }
    }
}

enum BankLinkError: Error, Equatable {
    case cancelled
    case invalidCallback
    case refused(code: String)
    case notAuthorized(BankLinkStatus)
    case incompleteImport
}

@MainActor
final class BankSyncService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case linking
        case syncing
    }

    struct PendingLink: Equatable {
        let institution: BankInstitution
        let linkID: String
        let expiresAt: Date
        var requiresAccountSelection = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var pendingLink: PendingLink?
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { errorOffersReconnect = false } }
    }
    // The alert adds a "Reconnect" button when the error can only be cured by a new bank authorization.
    @Published private(set) var errorOffersReconnect = false
    // Bank rows the last synchronization could not read or date. They are dropped, never fatal: the
    // account stays healthy and the rest of the window is imported. 0 when everything was understood.
    @Published private(set) var lastSyncSkippedRowCount = 0
    var onDataChanged: (() -> Void)?

    private var isInvalidated = false

    private func report(_ error: Error) {
        AppLog.bank.error("Bank operation failed: \(String(reflecting: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
        let presented = UserFacingError(error)
        errorMessage = presented.message
        errorOffersReconnect = presented.action == .reconnectBank
    }

    func invalidate() {
        isInvalidated = true
        activeAccountID = nil
        pendingLink = nil
        onDataChanged = nil
    }

    private func requireCurrentProfile() throws {
        try Task.checkCancellation()
        if isInvalidated { throw CancellationError() }
    }

    private let gateway: any BankGatewayClient
    private let dataStore: PeculeDataStore
    private let referenceDateProvider: () -> Date
    private let categorizer = BankTransactionCategorizer()
    private let transferDetector = InternalTransferDetector()
    private let reconciliationService = BankReconciliationService()

    static let transferDetectionWindowDays = 60

    init(
        gateway: any BankGatewayClient,
        dataStore: PeculeDataStore,
        referenceDateProvider: @escaping () -> Date = Date.init
    ) {
        self.gateway = gateway
        self.dataStore = dataStore
        self.referenceDateProvider = referenceDateProvider
        do {
            if let saved = try dataStore.pendingBankAuthorization() {
                if saved.expiresAt > referenceDateProvider(), let institution = BankInstitution(rawValue: saved.institution) {
                    pendingLink = PendingLink(institution: institution, linkID: saved.linkID, expiresAt: saved.expiresAt, requiresAccountSelection: saved.requiresAccountSelection)
                } else {
                    try dataStore.clearPendingBankAuthorization()
                    report(BankLinkError.notAuthorized(.expired))
                }
            }
        } catch { report(error) }
    }

    var isBusy: Bool {
        phase != .idle
    }

    @discardableResult
    func linkAccount(
        institution: BankInstitution,
        syncImmediately: Bool = true,
        authenticate: (URL) async throws -> URL
    ) async -> [ExternalAccount] {
        guard !isInvalidated, phase == .idle else {
            return []
        }
        phase = .linking
        defer { phase = .idle }

        do {
            let start = try await gateway.startLink(institution: institution)
            try requireCurrentProfile()
            try rememberPendingLink(start, institution: institution, requiresAccountSelection: !syncImmediately)
            // The stub gateway hands back a completed callback directly; real links go through the web session.
            let callbackURL = start.authUrl.scheme == "lifeos" ? start.authUrl : try await authenticate(start.authUrl)
            try requireCurrentProfile()
            guard let callback = BankLinkCallback(url: callbackURL),
                  callbackLinkID(callbackURL) == start.linkId else {
                throw BankLinkError.invalidCallback
            }
            let linkID: String
            switch callback {
            case .done(let id):
                linkID = id
            case .error(let code):
                try clearPendingLink()
                throw BankLinkError.refused(code: code)
            }

            let link = try await gateway.link(id: linkID)
            try requireCurrentProfile()
            guard link.id == start.linkId else { throw BankLinkError.invalidCallback }
            guard link.status == .authorized else {
                if link.status != .pending { try clearPendingLink() }
                throw BankLinkError.notAuthorized(link.status)
            }

            let savedAccounts = try importAccounts(from: link, institution: institution, requiresSelection: !syncImmediately)
            try clearPendingLink()
            errorMessage = nil
            if syncImmediately { await syncAll(savedAccounts, attended: true) }
            return savedAccounts
        } catch BankLinkError.cancelled {
            cancelPendingLink()
            return []
        } catch is CancellationError {
            return []
        } catch {
            report(error)
            return []
        }
    }

    // External mode: the authorization happens in Safari and comes back through the lifeos:// scheme.
    func startExternalLink(institution: BankInstitution) async -> URL? {
        guard !isInvalidated, phase == .idle else {
            return nil
        }
        phase = .linking
        defer { phase = .idle }

        do {
            let start = try await gateway.startLink(institution: institution)
            try requireCurrentProfile()
            try rememberPendingLink(start, institution: institution)
            return start.authUrl
        } catch {
            report(error)
            return nil
        }
    }

    private func rememberPendingLink(_ start: BankLinkStart, institution: BankInstitution, requiresAccountSelection: Bool = false) throws {
        // Match the gateway callback lifetime; consent validity is a separate, longer period.
        let expiresAt = min(start.validUntil, referenceDateProvider().addingTimeInterval(15 * 60))
        try dataStore.savePendingBankAuthorization(linkID: start.linkId, institution: institution, expiresAt: expiresAt, requiresAccountSelection: requiresAccountSelection)
        pendingLink = PendingLink(institution: institution, linkID: start.linkId, expiresAt: expiresAt, requiresAccountSelection: requiresAccountSelection)
        errorMessage = nil
    }

    private func clearPendingLink() throws {
        try dataStore.clearPendingBankAuthorization()
        pendingLink = nil
    }

    func cancelPendingLink() {
        guard !isInvalidated else { return }
        do { try clearPendingLink() }
        catch { report(error) }
    }

    private func callbackLinkID(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "linkId" }?.value
    }

    func handleIncomingURL(_ url: URL) async {
        guard BankLinkCallback(url: url) != nil else {
            return
        }
        await completePendingLink(callbackURL: url)
    }

    @discardableResult
    func completePendingLink(callbackURL: URL? = nil) async -> [ExternalAccount] {
        guard !isInvalidated, let pending = pendingLink, phase == .idle else {
            return []
        }
        guard pending.expiresAt > referenceDateProvider() else {
            cancelPendingLink()
            report(BankLinkError.notAuthorized(.expired))
            return []
        }
        if let callbackURL {
            guard callbackLinkID(callbackURL) == pending.linkID else { return [] }
            switch BankLinkCallback(url: callbackURL) {
            case .done(let linkID) where linkID == pending.linkID:
                break
            case .error(let code):
                cancelPendingLink()
                report(BankLinkError.refused(code: code))
                return []
            default:
                return []
            }
        }

        phase = .linking
        defer { phase = .idle }

        do {
            let link = try await gateway.link(id: pending.linkID)
            try requireCurrentProfile()
            guard link.id == pending.linkID else { throw BankLinkError.invalidCallback }
            switch link.status {
            case .authorized:
                let savedAccounts = try importAccounts(from: link, institution: pending.institution, requiresSelection: pending.requiresAccountSelection)
                try clearPendingLink()
                errorMessage = nil
                if !pending.requiresAccountSelection { await syncAll(savedAccounts, attended: true) }
                return savedAccounts
            case .pending:
                errorMessage = AppLocalizer.string("bank.error.linkStillPending")
                return []
            default:
                try clearPendingLink()
                throw BankLinkError.notAuthorized(link.status)
            }
        } catch {
            report(error)
            return []
        }
    }

    private func importAccounts(from link: BankLink, institution: BankInstitution, requiresSelection: Bool = false) throws -> [ExternalAccount] {
        let accounts = link.accounts.map { account in
            ExternalAccount(
                stableIdentifier: account.stableIdentifier,
                currentUID: account.uid,
                linkID: link.id,
                institution: institution,
                name: account.name ?? institution.displayName(),
                maskedIBAN: ExternalAccount.maskedIBAN(from: account.iban),
                currencyCode: Self.normalizedCurrency(account.currency) ?? "EUR",
                consentValidUntil: link.validUntil,
                // Card "accounts" mirror payments already debited from the current account: keep them out of totals.
                isIncludedInTotals: account.cashAccountType != "CARD"
            )
        }
        for account in accounts { account.requiresInclusionReview = requiresSelection }
        let savedAccounts = try dataStore.saveExternalAccounts(accounts)
        onDataChanged?()
        return savedAccounts
    }

    func refresh(_ accounts: [ExternalAccount], attended: Bool) async {
        guard !isInvalidated, phase == .idle else {
            return
        }
        phase = .syncing
        defer { phase = .idle }
        await syncAll(accounts, attended: attended)
    }

    // Foreground by default; background tasks must explicitly use unattended requests.
    func refreshIfStale(_ accounts: [ExternalAccount], maxAge: TimeInterval, attended: Bool = true) async {
        let linked = accounts.filter { !$0.isManual }
        guard !linked.isEmpty else {
            return
        }
        let now = referenceDateProvider()
        let progress = (try? dataStore.bankImportProgress()) ?? [:]
        let stale = linked.filter { account in
            if account.lastSyncError != nil {
                // A failed account waits: for what the bank asked (rate limit), else for a minimum delay.
                let notBefore = retryNotBefore[account.id] ?? progress[account.id]?.lastFailedAt.map { $0.addingTimeInterval(Self.minimumRetryDelayAfterFailure) }
                return notBefore.map { now >= $0 } ?? true
            }
            guard let lastSync = account.lastSyncedAt else { return true }
            return now.timeIntervalSince(lastSync) >= maxAge
        }
        guard !stale.isEmpty else { return }
        await refresh(stale, attended: attended)
    }

    @discardableResult
    func unlink(_ account: ExternalAccount) async -> Bool {
        guard !isInvalidated, phase == .idle else {
            return false
        }
        phase = .syncing
        defer { phase = .idle }

        do {
            // A link is one bank consent carrying every account the customer authorized: revoking it for one account
            // would silently cut the others off. It is revoked only with the last bank account that still uses it;
            // an account with siblings is only removed here, with its own data.
            if !account.isManual, try dataStore.linkSiblings(of: account).isEmpty {
                do {
                    try await gateway.deleteLink(id: account.linkID)
                } catch BankGatewayError.linkNotFound {
                    // Already gone server-side; the local copy still has to go.
                }
            }
            try requireCurrentProfile()
            try dataStore.deleteExternalAccount(account)
            onDataChanged?()
            return true
        } catch {
            report(error)
            return false
        }
    }

    static let initialHistoryDays = 365
    static let incrementalOverlapDays = 7
    static let maxTransactionPages = 50
    // The bank serves at most 90 days for a dated window; one day of margin keeps the request inside it.
    static let maxWindowAgeDays = 89
    // A failed account is not asked again before this, even by an app opened over and over.
    static let minimumRetryDelayAfterFailure: TimeInterval = 15 * 60
    // A bank-requested wait is honoured up to this: an absurd value must not lock an account out in the background.
    static let maximumRetryDelayAfterFailure: TimeInterval = 24 * 3600
    // A continuation key is a bank-side cursor: a saved one older than this is dropped, not replayed.
    static let resumePointMaxAge: TimeInterval = 24 * 3600

    // Bank-requested wait after a rate limit (`retryAfterSeconds`); lost on relaunch, where only the minimum delay applies.
    private var retryNotBefore: [UUID: Date] = [:]

    private func syncAll(_ accounts: [ExternalAccount], attended: Bool) async {
        var failures: [UserFacingError] = []
        var skippedRows = 0
        let ownMaskedIBANs = Set((try? dataStore.loadSnapshot(bankSince: .distantFuture).externalAccounts.compactMap(\.maskedIBAN)) ?? [])

        for account in accounts where !account.isManual && !account.requiresInclusionReview {
            activeAccountID = account.id
            defer { activeAccountID = nil }
            do {
                try requireCurrentProfile()
                // Read before the attempt below overwrites it: when the saved resume point was last touched.
                let previousCheckpoint = try dataStore.importCheckpoint(accountID: account.id)
                let resumePointTouchedAt = [previousCheckpoint.lastAttemptAt, previousCheckpoint.lastFailedAt].compactMap { $0 }.max()
                try dataStore.recordBankSyncAttempt(accountID: account.id, at: referenceDateProvider())
                let balances = try await gateway.balances(accountUID: account.currentUID, attended: attended)
                try requireCurrentProfile()
                let preferred = Self.preferredBalance(in: balances)
                let imported: ImportResult
                do {
                    imported = try await importTransactions(for: account, attended: attended, ownMaskedIBANs: ownMaskedIBANs, resumePointTouchedAt: resumePointTouchedAt)
                } catch {
                    // The balance was read; a failing import must not freeze it (the sync itself stays failed).
                    // An empty list of balances says nothing: the last known balance stays.
                    if !isInvalidated, !Task.isCancelled, let preferred {
                        try? dataStore.updateExternalAccountBalance(
                            account, balance: preferred.amount, balanceType: preferred.balanceType,
                            balanceDate: preferred.referenceDate ?? preferred.lastChangeDateTime,
                            currencyCode: Self.normalizedCurrency(preferred.currency), syncedAt: nil
                        )
                    }
                    throw error
                }
                skippedRows += imported.skippedRowCount
                try requireCurrentProfile()
                try dataStore.updateExternalAccountBalance(
                    account,
                    balance: preferred?.amount,
                    balanceType: preferred?.balanceType,
                    balanceDate: preferred?.referenceDate ?? preferred?.lastChangeDateTime,
                    currencyCode: Self.normalizedCurrency(preferred?.currency),
                    syncedAt: referenceDateProvider()
                )
                retryNotBefore[account.id] = nil
            } catch is CancellationError {
                return
            } catch BankGatewayError.sessionExpired {
                guard !isInvalidated, !Task.isCancelled else { return }
                AppLog.bank.error("Sync failed, consent expired (account \(account.id.uuidString, privacy: .private))")
                try? dataStore.recordBankSyncAttempt(accountID: account.id, at: referenceDateProvider(), failed: true)
                try? dataStore.updateExternalAccountStatus(account, status: .needsReconnect, error: "session_expired")
                failures.append(UserFacingError(BankGatewayError.sessionExpired))
            } catch {
                guard !isInvalidated, !Task.isCancelled else { return }
                AppLog.bank.error("Sync failed (account \(account.id.uuidString, privacy: .private)): \(String(reflecting: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
                try? dataStore.recordBankSyncAttempt(accountID: account.id, at: referenceDateProvider(), failed: true)
                if case BankGatewayError.rateLimited(let seconds) = error {
                    let wait = min(max(TimeInterval(seconds), Self.minimumRetryDelayAfterFailure), Self.maximumRetryDelayAfterFailure)
                    retryNotBefore[account.id] = referenceDateProvider().addingTimeInterval(wait)
                }
                let failure = UserFacingError(error)
                try? dataStore.updateExternalAccountStatus(account, status: failure.action == .reconnectBank ? .needsReconnect : .error, error: failure.key ?? "error.generic")
                failures.append(failure)
            }
        }

        guard !isInvalidated, !Task.isCancelled else { return }
        detectInternalTransfers()
        reconcileWithManualEntries()
        _ = try? dataStore.applyBankRetention(now: referenceDateProvider())
        if failures.isEmpty, accounts.contains(where: { !$0.isManual && !$0.requiresInclusionReview }) { lastSyncDate = referenceDateProvider() }
        // A failure that needs a reconnection is the one reported: it is the only one the person can act on.
        let reported = failures.first { $0.action == .reconnectBank } ?? failures.first
        errorMessage = reported?.message
        errorOffersReconnect = reported?.action == .reconnectBank
        if lastSyncSkippedRowCount != skippedRows { lastSyncSkippedRowCount = skippedRows }
        onDataChanged?()
    }

    // Links settled subscriptions, purchases and salaries so budgets can use real amounts without double counting.
    // Every recent operation is weighed against every manual entry at once (`BankReconciliationService.matches`);
    // what is already linked, however long ago, tells which billing cycles are taken.
    private func reconcileWithManualEntries() {
        let now = referenceDateProvider()
        let calendar = Calendar.current
        let since = now.addingTimeInterval(-TimeInterval(Self.transferDetectionWindowDays) * 86_400)
        guard let snapshot = try? dataStore.loadSnapshot(bankSince: .distantFuture) else {
            return
        }
        // A debit near a due date only counts as the subscription's when it is a known recurring one: that proof
        // needs the history the recurring-charge detector reads (13 months, like the screens that show it).
        let hasSubscriptions = snapshot.subscriptions.contains(where: \.isActive)
        let historyStart = hasSubscriptions
            ? min(since, calendar.date(byAdding: .month, value: -13, to: calendar.peculeMonthStart(for: now)) ?? since)
            : since
        guard let history = try? dataStore.recentBankTransactions(since: historyStart) else {
            return
        }
        let recent = history.filter { $0.bookingDate >= since }
        let includedAccountIDs = Set(snapshot.externalAccounts.filter(\.isIncludedInTotals).map(\.id))
        let subscriptions = snapshot.subscriptions.map {
            BankReconciliationService.SubscriptionCandidate(id: $0.id, name: $0.name, amount: $0.amount, billingCycle: $0.billingCycle, nextBillingDate: $0.nextBillingDate, isActive: $0.isActive)
        }
        let purchases = snapshot.purchases.filter { $0.date >= since.addingTimeInterval(-7 * 86_400) }.map {
            BankReconciliationService.PurchaseCandidate(id: $0.id, title: $0.title, merchant: $0.merchant, amount: $0.amount, date: $0.date)
        }
        let incomeSources = snapshot.incomeSources.map {
            BankReconciliationService.IncomeCandidate(id: $0.id, name: $0.name, amount: $0.amount, isActive: $0.isActive)
        }
        // The snapshot read with `.distantFuture` holds exactly the linked operations, whatever their age.
        let linkedOperations = snapshot.bankTransactions.compactMap { transaction in
            transaction.link.map { BankReconciliationService.LinkedOperation(link: .init($0), bookingDate: transaction.bookingDate, label: transaction.label) }
        }
        let recurringChargeIDs = hasSubscriptions
            ? Set(RecurringChargeDetector(calendar: calendar).detect(in: history, includedAccountIDs: includedAccountIDs, asOf: now).map(\.id))
            : []
        let candidates = recent.map { transaction in
            BankReconciliationService.Transaction(
                externalID: transaction.externalID,
                amount: transaction.amount,
                direction: transaction.normalizedDirection,
                bookingDate: transaction.bookingDate,
                label: transaction.label,
                counterparty: transaction.counterpartyName,
                isEligible: transaction.isEligibleForReconciliation
                    && !(transaction.normalizedDirection == .credit && transaction.natureOverride == "personalTransfer")
                    && !transaction.isLinked
                    && !transaction.isInternalTransfer
                    && includedAccountIDs.contains(transaction.accountID),
                accountID: transaction.accountID
            )
        }
        let matches = reconciliationService.matches(
            transactions: candidates,
            subscriptions: subscriptions,
            purchases: purchases,
            incomeSources: incomeSources,
            linkedOperations: linkedOperations,
            recurringChargeIDs: recurringChargeIDs
        )

        _ = try? dataStore.applyReconciliation(matches, advancingBillingDates: true, referenceDate: now, calendar: calendar)
    }

    private func detectInternalTransfers() {
        let since = referenceDateProvider().addingTimeInterval(-TimeInterval(Self.transferDetectionWindowDays) * 86_400)
        // The two legs of a transfer can be days apart, so a pair straddles the edge of the window.
        // Read a margin of maxDayDistance older days to keep the earlier leg pairable, without
        // ever putting those older rows up for revocation.
        let pairingSince = since.addingTimeInterval(-TimeInterval(transferDetector.maxDayDistance) * 86_400)
        guard let recent = try? dataStore.recentBankTransactions(since: pairingSince) else {
            return
        }
        let candidates = recent.filter {
            $0.isEligibleForReconciliation && $0.internalTransferOverride == nil
                && $0.natureOverride == "automatic" && $0.creditNature != .salary
        }.map {
            InternalTransferDetector.Candidate(
                externalID: $0.externalID,
                accountID: $0.accountID,
                amount: $0.amount,
                direction: $0.normalizedDirection,
                bookingDate: $0.bookingDate
            )
        }
        // Both sets: what was genuinely examined this pass and what is still paired, so a dissolved
        // pair is undone. Rows read only as pairing context stay out of consideredIDs: a leg whose
        // counterpart has aged out of the window keeps its mark instead of being silently revoked.
        _ = try? dataStore.reconcileInternalTransfers(
            consideredIDs: Set(candidates.filter { $0.bookingDate >= since }.map(\.externalID)),
            pairedIDs: transferDetector.pairedTransferIDs(in: candidates)
        )
    }

    struct ImportResult: Equatable {
        var insertedCount = 0
        // Rows the bank sent that could not be read or dated: dropped and counted, never fatal.
        var skippedRowCount = 0
    }

    // A continuation key the bank no longer recognizes comes back as a 4xx (a 400 or 404 through the
    // gateway, or an upstream 4xx). Authorization, consent, timeout and rate-limit answers are about
    // something else: replaying the window for them would only burn the bank's daily quota.
    static func isRejectedContinuationKey(_ error: Error) -> Bool {
        let status: Int
        switch error as? BankGatewayError {
        case .http(let httpStatus, _)?: status = httpStatus
        case .upstream(let upstreamStatus, _)?: status = upstreamStatus
        default: return false
        }
        return (400..<500).contains(status) && ![401, 403, 408, 429].contains(status)
    }

    // First import pulls a year with the "longest" strategy; later runs re-read a 7-day overlap so
    // late-booked entries are caught, and the unique externalID keeps the overlap idempotent.
    @discardableResult
    private func importTransactions(
        for account: ExternalAccount,
        attended: Bool,
        ownMaskedIBANs: Set<String> = [],
        resumePointTouchedAt: Date? = nil
    ) async throws -> ImportResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var query = BankTransactionsQuery()
        let checkpoint = try dataStore.importCheckpoint(accountID: account.id)
        // A key saved long ago is dropped before the bank can reject it; the window restarts from its start.
        if checkpoint.continuationKey != nil, let touchedAt = resumePointTouchedAt,
           referenceDateProvider().timeIntervalSince(touchedAt) > Self.resumePointMaxAge {
            checkpoint.continuationKey = nil
            checkpoint.fetchedExternalIDs = []
        }
        // The bank refuses a window that starts further back than it serves (WRONG_TRANSACTIONS_PERIOD), and a dormant
        // account's last operation can be older than that: the window never starts before this floor.
        let oldestServedDate = calendar.date(byAdding: .day, value: -Self.maxWindowAgeDays, to: referenceDateProvider())
        if let windowStart = checkpoint.windowStart {
            query.dateFrom = windowStart
            query.continuationKey = checkpoint.continuationKey
            // A resume point written by an older version can hold a window that is now too old; its key goes with it.
            // (The first import is excluded: it asks for a year with the "longest" strategy, which the bank answers on its own terms.)
            if checkpoint.initialImportCompleted, let oldestServedDate, windowStart < oldestServedDate {
                query.dateFrom = oldestServedDate
                query.continuationKey = nil
                checkpoint.continuationKey = nil
                checkpoint.fetchedExternalIDs = []
            }
        } else if checkpoint.initialImportCompleted, let latestBookingDate = try dataStore.latestBankTransactionDate(accountID: account.id) {
            query.dateFrom = calendar.date(byAdding: .day, value: -Self.incrementalOverlapDays, to: latestBookingDate)
            if let oldestServedDate, let from = query.dateFrom, from < oldestServedDate { query.dateFrom = oldestServedDate }
        } else {
            query.dateFrom = calendar.date(byAdding: .day, value: -Self.initialHistoryDays, to: referenceDateProvider())
            query.strategy = "longest"
        }

        if !checkpoint.initialImportCompleted { query.strategy = "longest" }
        checkpoint.windowStart = query.dateFrom
        try dataStore.saveImportCheckpoint()
        let windowStart = query.dateFrom
        var result = ImportResult()
        var pageCount = 0
        var fetchedExternalIDs = query.continuationKey == nil ? Set<String>() : Set(checkpoint.fetchedExternalIDs)
        // Identical operations without a bank reference are numbered across the whole window, pages included.
        var occurrences = BankTransactionOccurrenceCounter(resumingFrom: fetchedExternalIDs)
        var insertedExternalIDs = Set<String>()
        var hasRestartedWindow = false
        repeat {
            try requireCurrentProfile()
            let page: BankTransactionsPage
            do {
                page = try await gateway.transactions(accountUID: account.currentUID, query: query, attended: attended)
            } catch let error where query.continuationKey != nil && !hasRestartedWindow && Self.isRejectedContinuationKey(error) {
                // The saved key is stale: forget it and the identifiers seen under it, then re-read the
                // window from its start. Once per synchronization, so a bank that rejects everything
                // cannot keep this loop alive.
                try requireCurrentProfile()
                hasRestartedWindow = true
                query.continuationKey = nil
                checkpoint.continuationKey = nil
                checkpoint.fetchedExternalIDs = []
                try dataStore.saveImportCheckpoint()
                fetchedExternalIDs = []
                occurrences = BankTransactionOccurrenceCounter()
                result.skippedRowCount = 0
                pageCount = 0
                page = try await gateway.transactions(accountUID: account.currentUID, query: query, attended: attended)
            }
            try requireCurrentProfile()
            var skippedInPage = page.skippedCount
            let transactions = page.transactions.compactMap { dto -> BankTransaction? in
                guard let transaction = BankTransaction(dto: dto, accountID: account.id, accountStableIdentifier: account.stableIdentifier) else {
                    skippedInPage += 1
                    return nil
                }
                if BankTransaction.usesFallbackIdentifier(dto) {
                    transaction.externalID = occurrences.identifier(forFingerprint: transaction.externalID)
                }
                transaction.category = categorizer.category(
                    label: transaction.label,
                    counterparty: transaction.counterpartyName,
                    merchantCategoryCode: dto.merchantCategoryCode,
                    bankTransactionCode: dto.bankTransactionCode
                ).storageValue
                transaction.automaticCategory = transaction.category
                if let counterpartyIBAN = ExternalAccount.maskedIBAN(from: dto.counterpartyAccountIBAN),
                   counterpartyIBAN != account.maskedIBAN,
                   ownMaskedIBANs.contains(counterpartyIBAN) {
                    transaction.isInternalTransfer = true
                    transaction.transferEvidence = ClassificationEvidence.knownAccount.rawValue
                }
                return transaction
            }
            result.skippedRowCount += skippedInPage
            fetchedExternalIDs.formUnion(transactions.map(\.externalID))
            let insertedIDs = try dataStore.importBankTransactionsReturningInsertedIDs(transactions)
            result.insertedCount += insertedIDs.count
            insertedExternalIDs.formUnion(insertedIDs)
            query.continuationKey = page.continuationKey
            checkpoint.continuationKey = page.continuationKey
            checkpoint.fetchedExternalIDs = Array(fetchedExternalIDs)
            try dataStore.saveImportCheckpoint()
            pageCount += 1
        } while query.continuationKey != nil && pageCount < Self.maxTransactionPages

        guard query.continuationKey == nil else { throw BankLinkError.incompleteImport }

        // Only a complete window can prove a local transaction vanished upstream, and only when every
        // row of it was understood: an unreadable row could be the very one a local copy stands for.
        if query.continuationKey == nil, let windowStart, result.skippedRowCount == 0 {
            try dataStore.pruneBankTransactions(
                accountID: account.id,
                bookedOnOrAfter: windowStart,
                keeping: fetchedExternalIDs,
                insertedExternalIDs: insertedExternalIDs,
                // An empty answer proves nothing about booked operations (some banks answer it for a window they no longer serve).
                pendingOnly: fetchedExternalIDs.isEmpty
            )
        }

        checkpoint.initialImportCompleted = true
        checkpoint.lastCompletedAt = referenceDateProvider()
        checkpoint.requestedHistoryStart = checkpoint.requestedHistoryStart ?? windowStart
        checkpoint.windowStart = nil
        checkpoint.continuationKey = nil
        checkpoint.fetchedExternalIDs = []
        try dataStore.saveImportCheckpoint()
        return result
    }

    // "Real-time" balances (expected / interim available) match what banking apps display; booked ones are fallbacks.
    static func preferredBalance(in balances: [BankBalance]) -> BankBalance? {
        let priority = ["XPCD", "ITAV", "CLAV", "CLBD", "OPBD", "ITBD"]
        for type in priority {
            if let match = balances.first(where: { $0.balanceType == type }) {
                return match
            }
        }
        return balances.first
    }

    // Some banks report "XXX" (ISO 4217 "no currency") on the account while the balances carry the real code.
    static func normalizedCurrency(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 3, code != "XXX" else {
            return nil
        }
        return code
    }

    static func message(for error: Error, locale: Locale = LocalizationManager.currentAppLocale) -> String {
        UserFacingError(error, locale: locale).message
    }
}
