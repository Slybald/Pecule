import Foundation

/// Règle unique des achats saisis à la main quand des comptes bancaires sont inclus (audit M006 et m093).
///
/// Un achat compte dans les dépenses du mois, sauf si une opération bancaire le représente déjà :
/// - il est rattaché à un débit qui compte dans les totaux d'un compte inclus (`settledPurchaseIDs`) ;
/// - ou, sans rattachement, un débit plausible existe : compte inclus, comptant dans les totaux, rattaché
///   à aucune saisie, même montant à 0,01 € près, date à ±3 jours. Un débit ne représente qu'un seul
///   achat : deux achats identiques face à un seul débit en laissent un compté.
///
/// Les tolérances sont celles du rapprochement automatique (`BankReconciliationService`) : « plausible »
/// désigne ce que la synchronisation aurait elle-même rattaché. Le résumé du mois (accueil, budget,
/// graphique) et Opérations passent tous deux par ce service, ce qui les garde d'accord.
struct ManualPurchaseCoverageService {
    static let amountTolerance = Decimal(sign: .plus, exponent: -2, significand: 1)
    static let dayTolerance = 3
    /// Un achat peut se disputer un débit avec un autre achat à 3 jours, qui peut avoir un autre débit à
    /// 3 jours de lui : pour juger les achats d'une période, on lit les opérations 9 jours plus loin.
    static let operationMargin = 3 * dayTolerance

    var calendar: Calendar = .current

    /// Ce que la règle décide pour chaque achat fourni.
    struct Coverage: Equatable {
        /// Achats rattachés à une opération qui compte : elle les représente, quelle que soit sa date.
        var settledPurchaseIDs: Set<UUID> = []
        /// Achats sans rattachement qu'un débit plausible représente : achat vers opération.
        var representedPurchases: [UUID: UUID] = [:]

        func counts(_ purchase: Purchase) -> Bool {
            !settledPurchaseIDs.contains(purchase.id) && representedPurchases[purchase.id] == nil
        }
    }

    /// Prédicat partagé avec Achats et Opérations : seul le lien vers un débit qui compte dans les totaux
    /// d'un compte inclus représente l'achat. Une opération ignorée, en attente, en devise étrangère,
    /// absente de la banque, virement interne ou d'un compte exclu ne le masque pas.
    static func settledPurchaseIDs(in transactions: [BankTransaction], includedAccountIDs: Set<UUID>) -> Set<UUID> {
        Set(transactions.compactMap { transaction in
            transaction.isExpense && includedAccountIDs.contains(transaction.accountID) ? transaction.linkedPurchaseID : nil
        })
    }

    /// Opérations à fournir pour juger les achats de `interval` : la période, élargie de `operationMargin` jours.
    func operationWindow(for interval: DateInterval) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -Self.operationMargin, to: interval.start) ?? interval.start
        let end = calendar.date(byAdding: .day, value: Self.operationMargin, to: interval.end) ?? interval.end
        return DateInterval(start: start, end: max(start, end))
    }

    /// `settledPurchaseIDs` se déduit des opérations fournies ; un appelant qui n'en lit qu'une fenêtre
    /// transmet l'ensemble complet des rattachements, sans quoi un achat rattaché hors fenêtre
    /// réapparaîtrait comme saisie à compter.
    func coverage(
        purchases: [Purchase],
        transactions: [BankTransaction],
        includedAccountIDs: Set<UUID>,
        settledPurchaseIDs: Set<UUID>? = nil
    ) -> Coverage {
        let settled = settledPurchaseIDs ?? Self.settledPurchaseIDs(in: transactions, includedAccountIDs: includedAccountIDs)
        var coverage = Coverage(settledPurchaseIDs: settled)
        guard !includedAccountIDs.isEmpty else { return coverage }

        // Seul un débit rattaché à rien peut en représenter un autre : un rattachement est déjà une affectation.
        let debits = transactions.compactMap { transaction -> Debit? in
            guard transaction.isExpense, transaction.link == nil, includedAccountIDs.contains(transaction.accountID) else { return nil }
            return Debit(id: transaction.id, date: transaction.bookingDate, day: dayNumber(of: transaction.bookingDate), amount: transaction.amount)
        }.sorted(by: Debit.isOrderedBefore)
        guard !debits.isEmpty else { return coverage }

        let candidates = purchases.filter { !settled.contains($0.id) }.sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }
        // Pour chaque achat, les débits plausibles du plus ressemblant au moins ressemblant : le même
        // montant d'abord, puis le jour le plus proche. L'ordre des achats et ces tris sont totaux, donc
        // le résultat ne dépend pas de l'ordre dans lequel les lignes arrivent.
        let adjacency = candidates.map { purchase -> [Int] in
            let day = dayNumber(of: purchase.date)
            var matches: [(index: Int, amountGap: Decimal, dayGap: Int)] = []
            var index = firstIndex(in: debits, onOrAfter: day - Self.dayTolerance)
            while index < debits.count, debits[index].day <= day + Self.dayTolerance {
                let gap = abs(debits[index].amount - purchase.amount)
                if gap <= Self.amountTolerance {
                    matches.append((index, gap, abs(debits[index].day - day)))
                }
                index += 1
            }
            return matches.sorted {
                if $0.amountGap != $1.amountGap { return $0.amountGap < $1.amountGap }
                if $0.dayGap != $1.dayGap { return $0.dayGap < $1.dayGap }
                return $0.index < $1.index
            }.map(\.index)
        }

        // Appariement maximal (chemins augmentants) : un achat déjà apparié le reste, mais peut céder
        // son débit à un autre achat si un autre débit lui convient aussi.
        var owner = [Int?](repeating: nil, count: debits.count)
        func assign(_ purchase: Int, visited: inout Set<Int>) -> Bool {
            for debit in adjacency[purchase] where visited.insert(debit).inserted {
                if let holder = owner[debit], !assign(holder, visited: &visited) { continue }
                owner[debit] = purchase
                return true
            }
            return false
        }
        for purchase in candidates.indices {
            var visited = Set<Int>()
            _ = assign(purchase, visited: &visited)
        }
        for (debit, purchase) in owner.enumerated() {
            if let purchase { coverage.representedPurchases[candidates[purchase].id] = debits[debit].id }
        }
        return coverage
    }

    /// Achats qui comptent dans les dépenses de `month` : ceux du mois qu'aucune opération ne représente.
    /// `transactions` doit couvrir `operationWindow(for: month)`.
    func countedPurchases(
        in month: DateInterval,
        purchases: [Purchase],
        transactions: [BankTransaction],
        includedAccountIDs: Set<UUID>,
        settledPurchaseIDs: Set<UUID>? = nil
    ) -> [Purchase] {
        let coverage = coverage(
            purchases: purchases, transactions: transactions,
            includedAccountIDs: includedAccountIDs, settledPurchaseIDs: settledPurchaseIDs
        )
        return purchases.filter { $0.date >= month.start && $0.date < month.end && coverage.counts($0) }
    }

    private struct Debit {
        let id: UUID
        let date: Date
        let day: Int
        let amount: Decimal

        static func isOrderedBefore(_ left: Debit, _ right: Debit) -> Bool {
            if left.day != right.day { return left.day < right.day }
            if left.date != right.date { return left.date < right.date }
            return left.id.uuidString < right.id.uuidString
        }
    }

    // Jour civil du calendrier injecté : un achat saisi tard le soir et un débit daté à midi UTC se comparent
    // par jour, pas par durée écoulée. Compté en jours du calendrier depuis une origine fixe, ce qui reste juste
    // aux changements d'heure ; `ordinality(of: .day, in: .era)` ne respectait pas le fuseau du calendrier dans
    // le simulateur iOS 26 (testDaysAreCalendarDaysOfTheInjectedCalendar).
    private func dayNumber(of date: Date) -> Int {
        let origin = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.dateComponents([.day], from: origin, to: calendar.startOfDay(for: date)).day
            ?? Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    private func firstIndex(in debits: [Debit], onOrAfter day: Int) -> Int {
        var low = 0, high = debits.count
        while low < high {
            let middle = (low + high) / 2
            if debits[middle].day < day { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
