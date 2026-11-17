import Foundation
import SwiftData

// The original requested window survives process death and per-page failures.
// Its completion proves an import finished, not that the bank supplied all history.
@Model
final class BankImportCheckpoint {
    @Attribute(.unique) var accountID: UUID
    var windowStart: Date?
    var continuationKey: String?
    var fetchedExternalIDs: [String] = []
    var initialImportCompleted: Bool = false
    var lastCompletedAt: Date?
    var lastAttemptAt: Date?
    var lastFailedAt: Date?
    var requestedHistoryStart: Date?

    init(accountID: UUID) { self.accountID = accountID }
}
