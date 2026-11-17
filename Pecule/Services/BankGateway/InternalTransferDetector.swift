import Foundation

// Pairs a debit on one linked account with a credit of the same amount on another within a few days.
struct InternalTransferDetector: Sendable {
    struct Candidate: Equatable, Sendable {
        let externalID: String
        let accountID: UUID
        let amount: Decimal
        let direction: BankTransactionDirection
        let bookingDate: Date
    }

    var maxDayDistance: Int = 3

    func pairedTransferIDs(in candidates: [Candidate]) -> Set<String> {
        let debits = candidates.filter { $0.direction == .debit }.sorted { $0.bookingDate < $1.bookingDate }
        var credits = candidates.filter { $0.direction == .credit }
        var matched = Set<String>()
        let window = TimeInterval(maxDayDistance) * 86_400

        for debit in debits {
            let bestIndex = credits.indices
                .filter { index in
                    let credit = credits[index]
                    return credit.accountID != debit.accountID &&
                        credit.amount == debit.amount &&
                        abs(credit.bookingDate.timeIntervalSince(debit.bookingDate)) <= window
                }
                .min { abs(credits[$0].bookingDate.timeIntervalSince(debit.bookingDate)) < abs(credits[$1].bookingDate.timeIntervalSince(debit.bookingDate)) }
            guard let bestIndex else {
                continue
            }
            matched.insert(debit.externalID)
            matched.insert(credits[bestIndex].externalID)
            credits.remove(at: bestIndex)
        }

        return matched
    }
}
