import XCTest
@testable import Pecule

// M006 : un achat saisi à la main compte, sauf si une opération bancaire le représente déjà.
// m093 : seul le lien vers une opération qui compte dans les totaux masque l'achat.
@MainActor
final class ManualPurchaseCoverageTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let account = UUID()
    private lazy var service = ManualPurchaseCoverageService(calendar: calendar)
    private var september: DateInterval { calendar.dateInterval(of: .month, for: TestFixtures.date(2026, 9, 14))! }

    private func debit(_ amount: String, day: Int, month: Int = 9, account: UUID? = nil, label: String = "CB", configure: (BankTransaction) -> Void = { _ in }) -> BankTransaction {
        let transaction = BankTransaction(
            externalID: UUID().uuidString, accountID: account ?? self.account, amount: TestFixtures.decimal(amount),
            direction: .debit, currencyCode: "EUR", bookingDate: TestFixtures.date(2026, month, day), label: label
        )
        configure(transaction)
        return transaction
    }

    private func purchase(_ title: String = "Achat", _ amount: String, day: Int, month: Int = 9, hour: Int = 12) -> Purchase {
        Purchase(title: title, amount: TestFixtures.decimal(amount), date: TestFixtures.date(2026, month, day, hour: hour),
                 category: ExpenseCategory.groceries.storageValue, merchant: "Magasin", notes: nil)
    }

    private func coverage(_ purchases: [Purchase], _ transactions: [BankTransaction], included: Set<UUID>? = nil) -> ManualPurchaseCoverageService.Coverage {
        service.coverage(purchases: purchases, transactions: transactions, includedAccountIDs: included ?? [account])
    }

    // MARK: M006

    func testACashPurchaseWithNoPlausibleDebitCounts() {
        let cash = purchase("Marché", "12.00", day: 12)
        let unrelated = debit("47.30", day: 12)
        let counted = service.countedPurchases(in: september, purchases: [cash], transactions: [unrelated], includedAccountIDs: [account])
        XCTAssertEqual(counted.map(\.id), [cash.id])
    }

    func testAPurchaseDoubledByAPlausibleDebitIsRepresentedByIt() {
        let manual = purchase("Courses", "42.10", day: 11)
        let bank = debit("42.10", day: 10)
        let result = coverage([manual], [bank])
        XCTAssertEqual(result.representedPurchases, [manual.id: bank.id])
        XCTAssertFalse(result.counts(manual))
        XCTAssertTrue(service.countedPurchases(in: september, purchases: [manual], transactions: [bank], includedAccountIDs: [account]).isEmpty)
    }

    func testToleranceIsOneCentAndThreeCalendarDays() {
        XCTAssertEqual(ManualPurchaseCoverageService.dayTolerance, 3)
        XCTAssertEqual(ManualPurchaseCoverageService.amountTolerance, TestFixtures.decimal("0.01"))
        let manual = purchase("Courses", "42.10", day: 10)
        // Même montant à 0,01 € près, de part et d'autre.
        for amount in ["42.09", "42.10", "42.11"] {
            XCTAssertFalse(coverage([manual], [debit(amount, day: 10)]).counts(manual), amount)
        }
        for amount in ["42.08", "42.12", "42.20"] {
            XCTAssertTrue(coverage([manual], [debit(amount, day: 10)]).counts(manual), amount)
        }
        // Trois jours d'écart, avant ou après : plausible. Quatre : non.
        for day in [7, 13] {
            XCTAssertFalse(coverage([manual], [debit("42.10", day: day)]).counts(manual), "jour \(day)")
        }
        for day in [6, 14] {
            XCTAssertTrue(coverage([manual], [debit("42.10", day: day)]).counts(manual), "jour \(day)")
        }
    }

    // Le jour est celui du calendrier injecté. Un achat du 1er octobre à 00 h 10 à Paris est encore le 30 septembre
    // en UTC : face à un débit du 4 octobre (midi UTC), il est à trois jours civils à Paris, à quatre en UTC.
    // Compter les jours en durée écoulée (3 jours 14 heures) le jugerait à quatre jours dans les deux cas.
    func testDaysAreCalendarDaysOfTheInjectedCalendar() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let lateNight = Purchase(
            title: "Dîner", amount: 30, date: try XCTUnwrap(paris.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0, minute: 10))),
            category: ExpenseCategory.leisure.storageValue, merchant: "Bistro", notes: nil
        )
        let bank = debit("30.00", day: 4, month: 10)
        let inParis = ManualPurchaseCoverageService(calendar: paris).coverage(purchases: [lateNight], transactions: [bank], includedAccountIDs: [account])
        XCTAssertEqual(inParis.representedPurchases, [lateNight.id: bank.id])
        let inUTC = ManualPurchaseCoverageService(calendar: calendar).coverage(purchases: [lateNight], transactions: [bank], includedAccountIDs: [account])
        XCTAssertTrue(inUTC.representedPurchases.isEmpty)
    }

    func testOnlyADebitThatCountsOnAnIncludedAccountAndBelongsToNoEntryCanRepresentAPurchase() {
        let manual = purchase("Courses", "42.10", day: 10)
        let otherAccount = UUID()
        let cases: [(String, BankTransaction)] = [
            ("compte exclu", debit("42.10", day: 10, account: otherAccount)),
            ("ignorée", debit("42.10", day: 10) { $0.isIgnored = true }),
            ("en attente", debit("42.10", day: 10) { $0.status = BankTransactionStatus.pending.rawValue }),
            ("devise étrangère", debit("42.10", day: 10) { $0.currencyCode = "USD" }),
            ("virement interne", debit("42.10", day: 10) { $0.isInternalTransfer = true }),
            ("absente de la banque", debit("42.10", day: 10) { $0.isAbsentFromBank = true }),
            ("rattachée à un autre achat", debit("42.10", day: 10) { $0.linkedPurchaseID = UUID() }),
            ("rattachée à un abonnement", debit("42.10", day: 10) { $0.linkedSubscriptionID = UUID() }),
            ("crédit", { let credit = debit("42.10", day: 10); credit.direction = BankTransactionDirection.credit.rawValue; return credit }()),
        ]
        for (reason, transaction) in cases {
            XCTAssertTrue(coverage([manual], [transaction]).counts(manual), "un débit \(reason) ne représente pas l'achat")
        }
        XCTAssertFalse(coverage([manual], [debit("42.10", day: 10)]).counts(manual), "le même débit, sans défaut, le représente")
        XCTAssertTrue(coverage([manual], [debit("42.10", day: 10)], included: []).counts(manual), "sans compte inclus, rien ne représente l'achat")
    }

    func testOneDebitRepresentsOnlyOnePurchase() {
        let first = purchase("Café", "3.50", day: 10, hour: 8)
        let second = purchase("Café", "3.50", day: 10, hour: 15)
        let bank = debit("3.50", day: 10)
        let one = coverage([first, second], [bank])
        XCTAssertEqual(one.representedPurchases, [first.id: bank.id], "l'achat le plus ancien garde le débit")
        XCTAssertTrue(one.counts(second), "le second café, sans débit, reste à compter")

        let both = coverage([first, second], [bank, debit("3.50", day: 11)])
        XCTAssertTrue(both.counts(first) == false && both.counts(second) == false, "deux débits, deux achats représentés")
    }

    // A (jour 3) préfère D1 (jour 4), mais B (jour 6) n'a que D1 : A doit céder D1 et prendre D0 (jour 0).
    func testAnEarlierPurchaseYieldsItsDebitWhenAnotherDebitFitsItToo() {
        let a = purchase("A", "10.00", day: 3), b = purchase("B", "10.00", day: 6)
        let d0 = debit("10.00", day: 1), d1 = debit("10.00", day: 4)
        let result = coverage([a, b], [d0, d1])
        XCTAssertEqual(result.representedPurchases.count, 2, "les deux achats trouvent un débit")
        XCTAssertEqual(result.representedPurchases[b.id], d1.id)
        XCTAssertEqual(result.representedPurchases[a.id], d0.id)
    }

    func testTheResultDoesNotDependOnTheOrderOfTheInputs() {
        let purchases = (1...6).map { purchase("Achat \($0)", $0 % 2 == 0 ? "10.00" : "10.01", day: 8 + $0 / 2) }
        let debits = (1...4).map { debit("10.00", day: 7 + $0) }
        let reference = coverage(purchases, debits)
        for _ in 0..<5 {
            XCTAssertEqual(coverage(purchases.shuffled(), debits.shuffled()), reference)
        }
    }

    func testTolerancesAreThoseOfTheAutomaticReconciliation() {
        XCTAssertEqual(ManualPurchaseCoverageService.dayTolerance, BankReconciliationService().purchaseDayTolerance)
        XCTAssertEqual(ManualPurchaseCoverageService.amountTolerance, BankReconciliationService().amountTolerance)
    }

    func testOperationsAreReadNineDaysBeyondThePeriod() {
        let window = service.operationWindow(for: september)
        XCTAssertEqual(window.start, TestFixtures.date(2026, 8, 23, hour: 0))
        XCTAssertEqual(window.end, TestFixtures.date(2026, 10, 10, hour: 0))
    }

    // Un achat de fin de mois se rapproche d'un débit du mois suivant : le débit qui le représente n'est pas dans
    // le mois, mais l'achat n'est pas compté deux fois pour autant.
    func testAPurchaseAtTheEndOfAMonthIsRepresentedByTheDebitOfTheNext() {
        let manual = purchase("Courses", "42.10", day: 30)
        let bank = debit("42.10", day: 2, month: 10)
        XCTAssertTrue(service.countedPurchases(in: september, purchases: [manual], transactions: [bank], includedAccountIDs: [account]).isEmpty)
    }

    // MARK: m093

    func testOnlyALinkToAnOperationThatCountsInTheTotalsHidesAPurchase() {
        let counting = purchase("Compté", "10.00", day: 10)
        let others = (1...8).map { purchase("Autre \($0)", "10.00", day: 10) }
        let otherAccount = UUID()
        func linked(_ purchase: Purchase, _ configure: (BankTransaction) -> Void = { _ in }) -> BankTransaction {
            debit("10.00", day: 20) { $0.linkedPurchaseID = purchase.id; configure($0) }
        }
        let transactions = [
            linked(counting),
            linked(others[0]) { $0.isIgnored = true },
            linked(others[1]) { $0.status = BankTransactionStatus.pending.rawValue },
            linked(others[2]) { $0.currencyCode = "USD" },
            linked(others[3]) { $0.isInternalTransfer = true },
            linked(others[4]) { $0.accountID = otherAccount },
            linked(others[5]) { $0.isAbsentFromBank = true },
            linked(others[6]) { $0.direction = BankTransactionDirection.credit.rawValue },
        ]
        let settled = ManualPurchaseCoverageService.settledPurchaseIDs(in: transactions, includedAccountIDs: [account])
        XCTAssertEqual(settled, [counting.id])
    }

    func testALinkedPurchaseStaysListedAndCountedWhenItsOperationDoesNotCount() {
        let linkedAccount = TestFixtures.linkedAccount()
        let excludedAccount = TestFixtures.linkedAccount(stableIdentifier: "excluded")
        excludedAccount.isIncludedInTotals = false
        let makePurchase = { Purchase(title: "Achat", amount: 80, date: TestFixtures.referenceDate, category: .shopping, merchant: "Shop", notes: nil) }
        let scenarios: [(String, ExternalAccount, (BankTransaction) -> Void)] = [
            ("ignorée", linkedAccount, { $0.isIgnored = true }),
            ("en attente", linkedAccount, { $0.status = "pending" }),
            ("en dollars", linkedAccount, { $0.currencyCode = "USD" }),
            ("virement interne", linkedAccount, { $0.isInternalTransfer = true }),
            ("compte exclu", excludedAccount, { _ in }),
        ]
        let search = OperationSearchService()
        for (reason, owner, configure) in scenarios {
            let manual = makePurchase()
            let operation = TestFixtures.transaction(account: owner, reference: "linked", amount: 80, direction: .debit, dayOffset: 0, category: .shopping)
            operation.linkedPurchaseID = manual.id
            configure(operation)
            let records = search.records(transactions: [operation], purchases: [manual], accounts: [linkedAccount, excludedAccount])
            XCTAssertTrue(records.contains { $0.id == .purchase(manual.id) }, "achat lié à une opération \(reason) : il reste listé")
            XCTAssertEqual(search.search(records, filter: OperationFilter()).netExpenses, 80, "achat lié à une opération \(reason) : il compte")
        }
    }

    func testALinkedPurchaseStaysHiddenWhenItsOperationCounts() {
        let linkedAccount = TestFixtures.linkedAccount()
        let manual = Purchase(title: "Achat", amount: 80, date: TestFixtures.referenceDate, category: .shopping, merchant: "Shop", notes: nil)
        let operation = TestFixtures.transaction(account: linkedAccount, reference: "linked", amount: 80, direction: .debit, dayOffset: 0, category: .shopping)
        operation.linkedPurchaseID = manual.id
        let search = OperationSearchService()
        let records = search.records(transactions: [operation], purchases: [manual], accounts: [linkedAccount])
        XCTAssertEqual(records.map(\.id), [.bank(operation.id)])
        XCTAssertEqual(search.search(records, filter: OperationFilter()).netExpenses, 80, "une seule fois")
    }

    func testTheStoreReadsTheSameLinkPredicateAsThePurchasesAndOperationsScreens() throws {
        let state = try TestFixtures.makeAppState(seeded: false)
        let accounts = try state.dataStore.saveExternalAccounts([
            TestFixtures.linkedAccount(stableIdentifier: "kept"), TestFixtures.linkedAccount(stableIdentifier: "dropped"),
        ])
        let kept = try XCTUnwrap(accounts.first { $0.stableIdentifier == "kept" })
        let dropped = try XCTUnwrap(accounts.first { $0.stableIdentifier == "dropped" })
        let (visible, ignored, elsewhere) = (UUID(), UUID(), UUID())
        let counting = TestFixtures.transaction(account: kept, reference: "counting", amount: 10, direction: .debit, dayOffset: 0)
        counting.linkedPurchaseID = visible
        let ignoredOperation = TestFixtures.transaction(account: kept, reference: "ignored", amount: 10, direction: .debit, dayOffset: 0)
        ignoredOperation.linkedPurchaseID = ignored; ignoredOperation.isIgnored = true
        let onOtherAccount = TestFixtures.transaction(account: dropped, reference: "other", amount: 10, direction: .debit, dayOffset: 0)
        onOtherAccount.linkedPurchaseID = elsewhere
        try state.dataStore.importBankTransactions([counting, ignoredOperation, onOtherAccount])
        XCTAssertEqual(try state.dataStore.linkedPurchaseIDs(includedAccountIDs: [kept.id]), [visible])
        XCTAssertEqual(try state.dataStore.linkedPurchaseIDs(includedAccountIDs: [kept.id, dropped.id]), [visible, elsewhere])
    }
}
