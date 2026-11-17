import Foundation

// Values detached from SwiftData for UI and future shared financial contexts.
struct BankImportProgress: Equatable {
    let initialImportCompleted: Bool
    let pendingWindowStart: Date?
    let requestedHistoryStart: Date?
    let lastAttemptAt: Date?
    let lastFailedAt: Date?
}

struct BankAccountFreshness: Identifiable {
    enum State: String { case manual, awaitingSelection, syncing, notSynced, partial, failed, needsReconnect, current, stale, unverified }
    let id: UUID
    let state: State
    let lastSuccessfulAt: Date?
    let lastAttemptAt: Date?
    let lastFailedAt: Date?
    let requestedHistoryStart: Date?
    let firstReceivedAt: Date?
    let lastReceivedAt: Date?
    let initialImportCompleted: Bool
    // Why the last attempt failed, in words: nil when it did not.
    var lastError: String?
    var needsAttention: Bool { state != .current && state != .manual }
}

struct BankFreshnessService {
    static let staleAfter: TimeInterval = 3600

    func status(account: ExternalAccount, progress: BankImportProgress?, transactions: [BankTransaction], now: Date, isSyncing: Bool = false) -> BankAccountFreshness {
        let state: BankAccountFreshness.State
        if account.isManual { state = .manual }
        else if account.requiresInclusionReview { state = .awaitingSelection }
        else if isSyncing { state = .syncing }
        else if account.normalizedStatus == .needsReconnect || account.consentValidUntil.map({ $0 <= now }) == true { state = .needsReconnect }
        else if progress?.pendingWindowStart != nil { state = .partial }
        else if account.lastSyncError != nil { state = .failed }
        else if let last = account.lastSyncedAt {
            if now.timeIntervalSince(last) >= Self.staleAfter { state = .stale }
            else { state = progress?.initialImportCompleted == true ? .current : .unverified }
        } else { state = .notSynced }
        let dates = transactions.filter { $0.accountID == account.id && !$0.isAbsentFromBank }.map(\.bookingDate)
        return BankAccountFreshness(id: account.id, state: state, lastSuccessfulAt: account.lastSyncedAt,
            lastAttemptAt: progress?.lastAttemptAt, lastFailedAt: progress?.lastFailedAt,
            requestedHistoryStart: progress?.requestedHistoryStart ?? progress?.pendingWindowStart, firstReceivedAt: dates.min(), lastReceivedAt: dates.max(),
            initialImportCompleted: progress?.initialImportCompleted ?? false,
            lastError: account.lastSyncError.map(Self.localizedStoredError))
    }

    // `lastSyncError` holds a catalogue key (or the legacy "session_expired"). Anything else is text written before the
    // keys existed ("Erreur : 404 ACCOUNT_DOES_NOT_EXIST", a sentence frozen in another language): never shown as is.
    static func localizedStoredError(_ stored: String) -> String {
        if stored == "session_expired" { return AppLocalizer.string("error.bank.linkExpired") }
        let known = ["error.", "bank.error.", "auth.error."].contains { stored.hasPrefix($0) } && AppLocalizer.string(stored) != stored
        return AppLocalizer.string(known ? stored : "error.bank.unexpected")
    }
}
