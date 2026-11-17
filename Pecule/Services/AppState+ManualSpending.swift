import Foundation

// Dépenses du mois en mode bancaire : les opérations des comptes inclus, plus les achats saisis à la main
// qu'aucune opération ne représente. La règle vit dans `ManualPurchaseCoverageService` ; ces points d'entrée
// donnent au résumé du mois, au graphique et à Opérations les mêmes entrées, donc le même total.
extension AppState {
    var includedLinkedAccountIDs: Set<UUID> {
        Set(linkedExternalAccounts.filter(\.isIncludedInTotals).map(\.id))
    }

    // Opérations brutes (ni filtre de compte, ni de statut) de la période : la mémoire quand elle la couvre,
    // la base sinon.
    func rawBankTransactions(in interval: DateInterval) -> [BankTransaction] {
        guard isProfileActive else { return [] }
        if interval.start >= bankCacheStart {
            return bankTransactions.filter { $0.bookingDate >= interval.start && $0.bookingDate < interval.end }
        }
        return (try? dataStore.transactions(in: interval)) ?? []
    }

    // Achats saisis qui comptent dans les dépenses du mois, tel que les juge le mode bancaire.
    func countedManualPurchases(in month: DateInterval, includedAccountIDs: Set<UUID>? = nil, calendar: Calendar = .current) -> [Purchase] {
        let included = includedAccountIDs ?? includedLinkedAccountIDs
        guard !included.isEmpty else { return [] }
        let service = ManualPurchaseCoverageService(calendar: calendar)
        return service.countedPurchases(
            in: month,
            purchases: purchases,
            transactions: rawBankTransactions(in: service.operationWindow(for: month)),
            includedAccountIDs: included,
            // La mémoire garde tous les rattachements, quel que soit leur âge : l'ensemble est complet.
            settledPurchaseIDs: ManualPurchaseCoverageService.settledPurchaseIDs(in: bankTransactions, includedAccountIDs: included)
        )
    }

    // La courbe de l'accueil : mêmes opérations et mêmes achats que le total du mois.
    func monthlySpendingTrajectory(on date: Date, calendar: Calendar = .current) -> [MonthlyBudgetService.Point] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        return MonthlyBudgetService.trajectory(
            transactions: bankTransactions(in: date, calendar: calendar),
            manualPurchases: countedManualPurchases(in: month, calendar: calendar),
            on: date,
            calendar: calendar
        )
    }

    // Les enregistrements d'Opérations pour une période (toute la table sans période). Les opérations sont
    // lues avec la marge du rapprochement, pour que les achats du bord de période soient jugés comme dans le
    // résumé du mois ; la recherche écarte ensuite ce qui sort de la période.
    func operationRecords(in window: DateInterval?, calendar: Calendar = .current) throws -> [OperationRecord] {
        let service = ManualPurchaseCoverageService(calendar: calendar)
        let transactions = try dataStore.transactions(in: window.map(service.operationWindow(for:)))
        let included = Set(externalAccounts.filter(\.isIncludedInTotals).map(\.id))
        return OperationSearchService().records(
            transactions: transactions,
            purchases: purchases,
            accounts: externalAccounts,
            linkedPurchaseIDs: window == nil ? nil : try dataStore.linkedPurchaseIDs(includedAccountIDs: included),
            calendar: calendar
        )
    }

    // Vrai quand des comptes sont inclus mais qu'aucune opération n'est importée sur la période : un total à
    // zéro n'y est alors pas une absence de dépense. Faux sans compte inclus (rien à signaler).
    func hasNoImportedOperations(in interval: DateInterval) -> Bool {
        let included = includedLinkedAccountIDs
        guard !included.isEmpty else { return false }
        return BudgetOverviewService.importedOperationCount(in: rawBankTransactions(in: interval), month: interval, includedAccountIDs: included) == 0
    }
}
