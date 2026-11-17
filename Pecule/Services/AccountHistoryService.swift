import Foundation
import SwiftData

// The cursor never compares identifiers with `>` or `<`. The store sorts strings with a locale-aware
// collation that no predicate reproduces, so a cursor built on `externalID > reference` skipped or
// repeated rows whenever several operations of one day had identifiers that order differently there.
// It names a day and the rows of that day already returned: identity cannot disagree with itself.
struct AccountHistoryCursor: Equatable {
    let date: Date
    let returnedExternalIDs: Set<String>
}

struct AccountHistoryPage {
    let transactions: [BankTransaction]
    let next: AccountHistoryCursor?
}

extension PeculeDataStore {
    // MainActor only. Keyset pagination remains stable when newer rows arrive.
    // Never fetch the global snapshot to display an account's next page.
    func accountHistory(accountID: UUID, after cursor: AccountHistoryCursor? = nil, limit: Int = 100) throws -> AccountHistoryPage {
        let pageSize = min(max(limit, 1), 500)
        var descriptor: FetchDescriptor<BankTransaction>
        if let cursor {
            let date = cursor.date
            descriptor = FetchDescriptor(predicate: #Predicate<BankTransaction> {
                $0.accountID == accountID && $0.bookingDate <= date
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate<BankTransaction> { $0.accountID == accountID })
        }
        // The secondary key only orders rows within a day. Correctness does not depend on it.
        descriptor.sortBy = [SortDescriptor(\.bookingDate, order: .reverse), SortDescriptor(\.externalID)]
        // The rows already returned for the cursor day sort first: reading that many more leaves a full page.
        descriptor.fetchLimit = pageSize + 1 + (cursor?.returnedExternalIDs.count ?? 0)
        var fetched = try container.mainContext.fetch(descriptor)
        if let cursor {
            fetched.removeAll { $0.bookingDate == cursor.date && cursor.returnedExternalIDs.contains($0.externalID) }
        }
        let rows = Array(fetched.prefix(pageSize))
        guard fetched.count > pageSize, let last = rows.last else {
            return AccountHistoryPage(transactions: rows, next: nil)
        }
        var returned = Set(rows.filter { $0.bookingDate == last.bookingDate }.map(\.externalID))
        if let cursor, cursor.date == last.bookingDate {
            returned.formUnion(cursor.returnedExternalIDs)
        }
        return AccountHistoryPage(transactions: rows, next: AccountHistoryCursor(date: last.bookingDate, returnedExternalIDs: returned))
    }
}

extension PeculeDataStore {
    func transactions(in interval: DateInterval?) throws -> [BankTransaction] {
        if let interval {
            let start = interval.start, end = interval.end
            return try container.mainContext.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.bookingDate >= start && $0.bookingDate < end }))
        }
        return try container.mainContext.fetch(FetchDescriptor<BankTransaction>())
    }

    // Un achat rattaché à une opération bancaire ne doit pas apparaître deux fois. Le lien peut
    // pointer hors de la fenêtre affichée : on lit donc les seules lignes rattachées, qui sont peu
    // nombreuses, plutôt que de relire toute la table pour reconstituer cet ensemble. Seul le lien vers
    // une opération qui compte dans les totaux d'un compte inclus représente l'achat (m093) : le prédicat
    // est celui d'Achats et d'Opérations, `ManualPurchaseCoverageService.settledPurchaseIDs`.
    func linkedPurchaseIDs(includedAccountIDs: Set<UUID>) throws -> Set<UUID> {
        let descriptor = FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.linkedPurchaseID != nil })
        return ManualPurchaseCoverageService.settledPurchaseIDs(in: try container.mainContext.fetch(descriptor), includedAccountIDs: includedAccountIDs)
    }

    func historyBounds(accountID: UUID) throws -> [BankTransaction] {
        var first = FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.accountID == accountID && !$0.isAbsentFromBank }, sortBy: [SortDescriptor(\.bookingDate)])
        first.fetchLimit = 1
        var last = first
        last.sortBy = [SortDescriptor(\.bookingDate, order: .reverse)]
        return try container.mainContext.fetch(first) + container.mainContext.fetch(last)
    }
}

extension AppState {
    func bankTransaction(id: UUID) -> BankTransaction? {
        guard isProfileActive else { return nil }
        return try? dataStore.editableBankTransaction(id: id)
    }
}
