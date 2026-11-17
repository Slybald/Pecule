import Foundation

// Unannotated automatic statements may age out; account consent expiry never authorizes deletion.
struct BankRetentionPolicy: Equatable {
    static let `default` = BankRetentionPolicy(retentionMonths: 24, deadConsentGraceDays: 180)

    let retentionMonths: Int
    let deadConsentGraceDays: Int

    func cutoffDate(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: -retentionMonths, to: calendar.startOfDay(for: now)) ?? now
    }

    // Classifies stale consent for diagnostics only; callers must not infer permission to delete data.
    func isDeadConsent(_ account: ExternalAccount, now: Date, calendar: Calendar = .current) -> Bool {
        guard !account.isManual, account.normalizedStatus != .active, let consentValidUntil = account.consentValidUntil,
              let deadline = calendar.date(byAdding: .day, value: deadConsentGraceDays, to: consentValidUntil) else {
            return false
        }
        return now >= deadline
    }
}

struct BankRetentionReport: Equatable {
    let purgedTransactions: Int
    let removedAccounts: [String]

    var isEmpty: Bool {
        purgedTransactions == 0 && removedAccounts.isEmpty
    }
}
