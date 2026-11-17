import XCTest
@testable import Pecule

final class BankReconciliationServiceTests: XCTestCase {
    private let service = BankReconciliationService()
    private let netflix = UUID()
    private let spotify = UUID()
    private let coffeeMaker = UUID()
    private let salary = UUID()

    private func transaction(_ id: String, _ amount: String, _ direction: BankTransactionDirection, day: Int, label: String, counterparty: String? = nil, eligible: Bool = true) -> BankReconciliationService.Transaction {
        BankReconciliationService.Transaction(
            externalID: id,
            amount: TestFixtures.decimal(amount),
            direction: direction,
            bookingDate: TestFixtures.day(offset: day),
            label: label,
            counterparty: counterparty,
            isEligible: eligible
        )
    }

    private var subscriptions: [BankReconciliationService.SubscriptionCandidate] {
        [
            .init(id: netflix, name: "Netflix", amount: TestFixtures.decimal("15.99"), billingCycle: .monthly, nextBillingDate: TestFixtures.day(offset: 2), isActive: true),
            .init(id: spotify, name: "Spotify Premium", amount: TestFixtures.decimal("10.99"), billingCycle: .monthly, nextBillingDate: TestFixtures.day(offset: 20), isActive: true),
        ]
    }

    func testLinksSubscriptionByAmountAndNameOrBillingDate() {
        let matches = service.matches(
            transactions: [
                transaction("t-netflix", "15.99", .debit, day: 0, label: "PRLV SEPA NETFLIX INTERNATIONAL"),
                transaction("t-spotify", "10.99", .debit, day: -12, label: "CB SPOTIFY AB", counterparty: "Spotify"),
                transaction("t-other", "15.99", .debit, day: -20, label: "CB SOMETHING ELSE"),
            ],
            subscriptions: subscriptions,
            purchases: [],
            incomeSources: []
        )

        XCTAssertEqual(matches, [
            .init(externalID: "t-spotify", link: .subscription(spotify)),
            .init(externalID: "t-netflix", link: .subscription(netflix)),
        ], "sorted by booking date; the unnamed 15.99 far from the billing date stays unlinked")
    }

    func testEachManualEntryIsLinkedAtMostOnceAndTiesStayUnlinked() {
        let twin = UUID()
        let twins: [BankReconciliationService.SubscriptionCandidate] = [
            .init(id: netflix, name: "Netflix", amount: 15.99, billingCycle: .monthly, nextBillingDate: TestFixtures.day(offset: 0), isActive: true),
            .init(id: twin, name: "Netflix Famille", amount: 15.99, billingCycle: .monthly, nextBillingDate: TestFixtures.day(offset: 0), isActive: true),
        ]
        let ambiguous = service.matches(
            transactions: [transaction("t1", "15.99", .debit, day: 0, label: "NETFLIX")],
            subscriptions: twins,
            purchases: [],
            incomeSources: []
        )
        XCTAssertTrue(ambiguous.isEmpty, "two equally good candidates: never guess")

        let repeated = service.matches(
            transactions: [
                transaction("t1", "15.99", .debit, day: 0, label: "NETFLIX"),
                transaction("t2", "15.99", .debit, day: 1, label: "NETFLIX"),
            ],
            subscriptions: [twins[0]],
            purchases: [],
            incomeSources: []
        )
        XCTAssertEqual(repeated.map(\.externalID), ["t1"])

        let taken = service.matches(
            transactions: [transaction("t1", "15.99", .debit, day: 0, label: "NETFLIX")],
            subscriptions: [twins[0]],
            purchases: [],
            incomeSources: [],
            alreadyLinked: [.subscription(netflix)]
        )
        XCTAssertTrue(taken.isEmpty)
    }

    func testLinksPurchasesByAmountAndDateAndIncomeByAmount() {
        let purchases: [BankReconciliationService.PurchaseCandidate] = [
            .init(id: coffeeMaker, title: "Machine à café", merchant: "Darty", amount: TestFixtures.decimal("79.90"), date: TestFixtures.day(offset: -2)),
        ]
        let incomes: [BankReconciliationService.IncomeCandidate] = [
            .init(id: salary, name: "Salaire ACME", amount: 1500, isActive: true),
        ]
        let matches = service.matches(
            transactions: [
                transaction("t-darty", "79.90", .debit, day: 0, label: "CB DARTY POITIERS"),
                transaction("t-late", "79.90", .debit, day: 6, label: "CB DARTY POITIERS"),
                transaction("t-salary", "1505.00", .credit, day: -1, label: "VIR SEPA ACME SAS SALAIRE"),
                transaction("t-ignored", "1500.00", .credit, day: -1, label: "VIR", eligible: false),
                transaction("t-big", "1700.00", .credit, day: -1, label: "VIR ACME"),
            ],
            subscriptions: [],
            purchases: purchases,
            incomeSources: incomes
        )

        XCTAssertEqual(Set(matches), [
            .init(externalID: "t-darty", link: .purchase(coffeeMaker)),
            .init(externalID: "t-salary", link: .income(salary)),
        ])
    }

    // The billing date follows the bank: it moves to the first cycle after the operation that settled it.
    func testNextBillingDateMovesToTheFirstCycleAfterTheOperationAndNeverBackwards() {
        let anchor = TestFixtures.date(2026, 10, 20)
        func next(_ operation: Date, anchor: Date = TestFixtures.date(2026, 10, 20), cycle: BillingCycle = .monthly) -> Date {
            service.nextBillingDate(settledOn: operation, anchor: anchor, cycle: cycle)
        }
        XCTAssertEqual(next(TestFixtures.date(2026, 10, 20)), TestFixtures.date(2026, 11, 20), "on time")
        XCTAssertEqual(next(TestFixtures.date(2026, 10, 22)), TestFixtures.date(2026, 11, 20), "two days late")
        XCTAssertEqual(next(TestFixtures.date(2026, 10, 16)), TestFixtures.date(2026, 11, 20), "four days early still settles this cycle")
        XCTAssertEqual(next(TestFixtures.date(2026, 10, 8)), anchor, "twelve days early is not this cycle's payment: the date stays")
        XCTAssertEqual(next(TestFixtures.date(2026, 9, 20)), anchor, "last cycle's payment never moves the date backwards")
        XCTAssertEqual(next(TestFixtures.date(2026, 1, 20)), anchor, "a far older operation never regresses the date either")
        // M087: a date left behind catches up, however late.
        XCTAssertEqual(next(TestFixtures.date(2026, 10, 5), anchor: TestFixtures.date(2026, 7, 5)), TestFixtures.date(2026, 11, 5), "three months late")
        XCTAssertEqual(next(TestFixtures.date(2027, 3, 3), anchor: TestFixtures.date(2026, 7, 5)), TestFixtures.date(2027, 4, 5), "nine months late")
        // Cycles are counted from the anchor: the 31st does not drift to the 28th.
        XCTAssertEqual(next(TestFixtures.date(2027, 3, 30), anchor: TestFixtures.date(2027, 1, 31)), TestFixtures.date(2027, 4, 30))
        XCTAssertEqual(next(TestFixtures.date(2027, 1, 30), anchor: TestFixtures.date(2027, 1, 31)), TestFixtures.date(2027, 2, 28))
        XCTAssertEqual(next(TestFixtures.date(2027, 3, 12), anchor: TestFixtures.date(2026, 3, 10), cycle: .yearly), TestFixtures.date(2028, 3, 10))
        XCTAssertEqual(next(TestFixtures.date(2026, 3, 12), anchor: TestFixtures.date(2026, 3, 10), cycle: .yearly), TestFixtures.date(2027, 3, 10))
    }

    // M017, m086, m087, m088: how an operation is matched to the manual entry it settles.
    private let basicFit = UUID()
    private let account = UUID()

    private func debit(_ id: String, _ amount: String, on date: Date, label: String, accountID: UUID? = nil) -> BankReconciliationService.Transaction {
        BankReconciliationService.Transaction(
            externalID: id, amount: TestFixtures.decimal(amount), direction: .debit, bookingDate: date,
            label: label, counterparty: nil, isEligible: true, accountID: accountID
        )
    }

    private func subscription(_ id: UUID, _ name: String, _ amount: String, due: Date, cycle: BillingCycle = .monthly) -> BankReconciliationService.SubscriptionCandidate {
        .init(id: id, name: name, amount: TestFixtures.decimal(amount), billingCycle: cycle, nextBillingDate: due, isActive: true)
    }

    private func recurringID(_ label: String) -> String {
        "\(account.uuidString):\(RecurringChargeDetector.merchantKey(for: label))"
    }

    // M017: the same amount near a due date is not evidence of anything by itself.
    func testADebitOfTheSameAmountNearTheDueDateIsNotLinkedWithoutALabelOrAProofOfRecurrence() {
        let subscriptions = [
            subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20)),
            subscription(basicFit, "Basic Fit", "50.00", due: TestFixtures.date(2026, 10, 20)),
        ]
        let matches = service.matches(
            transactions: [
                debit("bakery", "15.99", on: TestFixtures.date(2026, 10, 16), label: "CB BOULANGERIE PAUL", accountID: account),
                debit("atm", "50.00", on: TestFixtures.date(2026, 10, 18), label: "RETRAIT DAB PARIS", accountID: account),
                debit("lookalike", "49.99", on: TestFixtures.date(2026, 10, 20), label: "CB QQCHOSE", accountID: account),
            ],
            subscriptions: subscriptions, purchases: [], incomeSources: []
        )
        XCTAssertTrue(matches.isEmpty, "a baker's 15,99 and an ATM 50,00 are not the subscriptions")
    }

    func testANamedDebitIsLinkedWithoutAnyOtherProof() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20))]
        let matches = service.matches(
            transactions: [debit("named", "15.99", on: TestFixtures.date(2026, 10, 16), label: "PRLV SEPA NETFLIX INTERNATIONAL", accountID: account)],
            subscriptions: subscriptions, purchases: [], incomeSources: []
        )
        XCTAssertEqual(matches, [.init(externalID: "named", link: .subscription(netflix))])
    }

    func testADebitNearTheDueDateIsLinkedWhenItsCreditorIsDetectedAsRecurringOnThatAccount() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20))]
        let label = "PRLV SEPA STREAMCO 4412"
        let operation = debit("recurring", "15.99", on: TestFixtures.date(2026, 10, 19), label: label, accountID: account)
        let proven = service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], recurringChargeIDs: [recurringID(label)])
        XCTAssertEqual(proven, [.init(externalID: "recurring", link: .subscription(netflix))])

        let otherAccount = service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], recurringChargeIDs: ["\(UUID().uuidString):\(RecurringChargeDetector.merchantKey(for: label))"])
        XCTAssertTrue(otherAccount.isEmpty, "recurrence is detected account by account")
        let farFromTheDueDate = debit("far", "15.99", on: TestFixtures.date(2026, 10, 3), label: label, accountID: account)
        XCTAssertTrue(service.matches(transactions: [farFromTheDueDate], subscriptions: subscriptions, purchases: [], incomeSources: [], recurringChargeIDs: [recurringID(label)]).isEmpty,
                      "recurrence only proves the date match, never replaces it")
    }

    func testADebitNearTheDueDateIsLinkedWhenTheSameCreditorSettledThePreviousCycle() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20))]
        let label = "PRLV SEPA STREAMCO 4412"
        let previous = BankReconciliationService.LinkedOperation(link: .subscription(netflix), bookingDate: TestFixtures.date(2026, 9, 19), label: "PRLV SEPA STREAMCO 4398")
        let operation = debit("next", "15.99", on: TestFixtures.date(2026, 10, 19), label: label, accountID: account)
        XCTAssertEqual(service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [previous]),
                       [.init(externalID: "next", link: .subscription(netflix))])

        let anotherCreditor = BankReconciliationService.LinkedOperation(link: .subscription(netflix), bookingDate: TestFixtures.date(2026, 9, 19), label: "CB BOULANGERIE PAUL")
        XCTAssertTrue(service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [anotherCreditor]).isEmpty)
        let otherSubscription = BankReconciliationService.LinkedOperation(link: .subscription(basicFit), bookingDate: TestFixtures.date(2026, 9, 19), label: label)
        XCTAssertTrue(service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [otherSubscription]).isEmpty)
        let notThePreviousCycle = BankReconciliationService.LinkedOperation(link: .subscription(netflix), bookingDate: TestFixtures.date(2026, 7, 19), label: label)
        XCTAssertTrue(service.matches(transactions: [operation], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [notThePreviousCycle]).isEmpty)
    }

    // m086: the best evidence takes the entry, whatever the order in which operations happened or arrived.
    func testTheNamedDebitTakesTheSubscriptionEvenWhenAnEarlierLookalikeIsAlsoACandidate() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20))]
        let label = "CB BOULANGERIE PAUL"
        let lookalike = debit("a-lookalike", "15.99", on: TestFixtures.date(2026, 10, 16), label: label, accountID: account)
        let real = debit("b-real", "15.99", on: TestFixtures.date(2026, 10, 20), label: "PRLV NETFLIX", accountID: account)
        for order in [[lookalike, real], [real, lookalike]] {
            let matches = service.matches(transactions: order, subscriptions: subscriptions, purchases: [], incomeSources: [], recurringChargeIDs: [recurringID(label)])
            XCTAssertEqual(matches, [.init(externalID: "b-real", link: .subscription(netflix))], "the later, named debit wins the cycle")
        }
    }

    func testEqualOperationsAreAssignedTheSameWhateverTheirOrder() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 10, 20))]
        let day = TestFixtures.date(2026, 10, 20)
        let twins = [
            debit("t-b", "15.99", on: day, label: "PRLV NETFLIX"),
            debit("t-a", "15.99", on: day, label: "PRLV NETFLIX"),
        ]
        let forward = service.matches(transactions: twins, subscriptions: subscriptions, purchases: [], incomeSources: [])
        let backward = service.matches(transactions: twins.reversed(), subscriptions: subscriptions, purchases: [], incomeSources: [])
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, [.init(externalID: "t-a", link: .subscription(netflix))], "one of two identical debits settles the cycle, deterministically")

        // Two entries, two named operations on the same day: every arrival order gives the same assignment.
        let spotify = UUID()
        let both = [
            subscription(netflix, "Netflix", "15.99", due: day),
            subscription(spotify, "Spotify Premium", "15.99", due: day),
        ]
        let operations = [
            debit("o-netflix", "15.99", on: day, label: "PRLV NETFLIX"),
            debit("o-spotify", "15.99", on: day, label: "CB SPOTIFY AB"),
        ]
        let reference = Set(service.matches(transactions: operations, subscriptions: both, purchases: [], incomeSources: []))
        XCTAssertEqual(reference, [.init(externalID: "o-netflix", link: .subscription(netflix)), .init(externalID: "o-spotify", link: .subscription(spotify))])
        XCTAssertEqual(Set(service.matches(transactions: operations.reversed(), subscriptions: both.reversed(), purchases: [], incomeSources: [])), reference)
    }

    // m087: the nearest billing date is searched in both directions from the anchor.
    func testADateLeftThreeMonthsBehindOrAheadStillMatchesItsCycle() {
        let label = "PRLV SEPA STREAMCO 4412"
        let operation = debit("late", "42.00", on: TestFixtures.date(2026, 10, 5), label: label, accountID: account)
        let proof: Set<String> = [recurringID(label)]
        let late = [subscription(netflix, "Netflix", "42.00", due: TestFixtures.date(2026, 7, 5))]
        XCTAssertEqual(service.matches(transactions: [operation], subscriptions: late, purchases: [], incomeSources: [], recurringChargeIDs: proof),
                       [.init(externalID: "late", link: .subscription(netflix))], "anchor three months behind")
        let ahead = [subscription(netflix, "Netflix", "42.00", due: TestFixtures.date(2026, 12, 5))]
        XCTAssertEqual(service.matches(transactions: [operation], subscriptions: ahead, purchases: [], incomeSources: [], recurringChargeIDs: proof),
                       [.init(externalID: "late", link: .subscription(netflix))], "anchor two months ahead")
        XCTAssertTrue(service.matches(transactions: [operation], subscriptions: late, purchases: [], incomeSources: []).isEmpty, "still no link without proof")
        let yearly = [subscription(netflix, "Netflix", "42.00", due: TestFixtures.date(2024, 10, 3), cycle: .yearly)]
        XCTAssertEqual(service.matches(transactions: [operation], subscriptions: yearly, purchases: [], incomeSources: [], recurringChargeIDs: proof),
                       [.init(externalID: "late", link: .subscription(netflix))], "a yearly date left two years behind")
    }

    // m088: a cycle is taken by an operation less than half a cycle away, whatever the month it falls in.
    func testACycleSettledBeforeTheMonthBoundaryIsTakenAfterIt() {
        let subscriptions = [subscription(netflix, "Netflix", "15.99", due: TestFixtures.date(2026, 11, 1))]
        let settled = BankReconciliationService.LinkedOperation(link: .subscription(netflix), bookingDate: TestFixtures.date(2026, 10, 30), label: "PRLV NETFLIX")
        let afterTheBoundary = debit("nov-2", "15.99", on: TestFixtures.date(2026, 11, 2), label: "PRLV NETFLIX")
        XCTAssertTrue(service.matches(transactions: [afterTheBoundary], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [settled]).isEmpty,
                      "30/10 already settles this cycle")
        // The next cycle's debit is free again.
        let nextCycle = debit("dec-1", "15.99", on: TestFixtures.date(2026, 12, 1), label: "PRLV NETFLIX")
        XCTAssertEqual(service.matches(transactions: [nextCycle], subscriptions: subscriptions, purchases: [], incomeSources: [], linkedOperations: [settled]),
                       [.init(externalID: "dec-1", link: .subscription(netflix))])
        // Two operations of the same run on both sides of the boundary settle the cycle once.
        let onTheOtherSide = debit("oct-30", "15.99", on: TestFixtures.date(2026, 10, 30), label: "PRLV NETFLIX")
        let run = service.matches(transactions: [afterTheBoundary, onTheOtherSide], subscriptions: subscriptions, purchases: [], incomeSources: [])
        XCTAssertEqual(run.count, 1)
        // A linked purchase is spoken for whatever its age; so is a salary within the same cycle.
        let purchase = UUID(), salary = UUID()
        let purchases: [BankReconciliationService.PurchaseCandidate] = [.init(id: purchase, title: "Machine à café", merchant: "Darty", amount: TestFixtures.decimal("79.90"), date: TestFixtures.date(2026, 10, 1))]
        let oldLink = BankReconciliationService.LinkedOperation(link: .purchase(purchase), bookingDate: TestFixtures.date(2025, 1, 1), label: "CB DARTY")
        XCTAssertTrue(service.matches(transactions: [debit("darty", "79.90", on: TestFixtures.date(2026, 10, 1), label: "CB DARTY")], subscriptions: [], purchases: purchases, incomeSources: [], linkedOperations: [oldLink]).isEmpty)
        let incomes: [BankReconciliationService.IncomeCandidate] = [.init(id: salary, name: "Salaire ACME", amount: 1500, isActive: true)]
        let credit = BankReconciliationService.Transaction(externalID: "pay-nov", amount: 1500, direction: .credit, bookingDate: TestFixtures.date(2026, 11, 1), label: "VIR SALAIRE ACME", counterparty: nil, isEligible: true)
        let paid = BankReconciliationService.LinkedOperation(link: .income(salary), bookingDate: TestFixtures.date(2026, 10, 31), label: "VIR SALAIRE ACME")
        XCTAssertTrue(service.matches(transactions: [credit], subscriptions: [], purchases: [], incomeSources: incomes, linkedOperations: [paid]).isEmpty)
    }
}
