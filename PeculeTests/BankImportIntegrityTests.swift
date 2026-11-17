import Foundation
import SwiftData
import XCTest
@testable import Pecule

// Sous-lot 2a de l'audit du 5 octobre : M001 (opérations identiques sans référence), M020 (ligne
// illisible dans une page), m040 (clé de continuation périmée).
@MainActor
final class BankImportIntegrityTests: XCTestCase {
    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Harness {
        let gateway: ScriptedGateway
        let clock: ClockBox
        let service: BankSyncService
        let store: PeculeDataStore
        let account: ExternalAccount
    }

    private let start = TestFixtures.referenceDate

    private func makeHarness() throws -> Harness {
        let gateway = ScriptedGateway()
        let clock = ClockBox(start)
        let store = try TestFixtures.makeDataStore()
        let service = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { clock.now })
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        return Harness(gateway: gateway, clock: clock, service: service, store: store, account: account)
    }

    private func sync(_ harness: Harness) async {
        await harness.service.refresh([harness.account], attended: true)
    }

    private func storedRows(_ store: PeculeDataStore) throws -> [BankTransaction] {
        try store.container.mainContext.fetch(FetchDescriptor<BankTransaction>(sortBy: [SortDescriptor(\.externalID)]))
    }

    private func storedIDs(_ store: PeculeDataStore) throws -> Set<String> {
        Set(try storedRows(store).map(\.externalID))
    }

    private func operation(
        _ reference: String? = nil,
        transactionId: String? = nil,
        amount: String = "2.50",
        day: Int = -1,
        label: String = "CAFE",
        status: String = "BOOK"
    ) -> BankTransactionDTO {
        BankTransactionDTO(
            entryReference: reference,
            transactionId: transactionId,
            amount: TestFixtures.decimal(amount),
            currency: "EUR",
            creditDebitIndicator: .debit,
            status: status,
            bookingDate: TestFixtures.day(offset: day),
            creditorName: label,
            remittanceInformation: ["CB \(label)"]
        )
    }

    private func fingerprintID(_ dto: BankTransactionDTO, stable: String = "hash-1") -> String {
        BankTransaction.externalID(accountStableIdentifier: stable, dto: dto, bookingDate: dto.bookingDate ?? start)
    }

    private func page(_ dtos: [BankTransactionDTO], key: String? = nil, skipped: Int = 0) -> BankTransactionsPage {
        BankTransactionsPage(transactions: dtos, continuationKey: key, skippedCount: skipped)
    }

    // MARK: - M001 : identifiant de repli et rang d'occurrence

    func testTwoIdenticalOperationsWithoutReferenceStayTwoRows() async throws {
        let h = try makeHarness()
        let coffee = operation()
        h.gateway.transactionPages = [nil: page([coffee, coffee])]

        await sync(h)

        XCTAssertNil(h.account.lastSyncError)
        let base = fingerprintID(coffee)
        XCTAssertEqual(try storedIDs(h.store), [base, base + "#2"])
        XCTAssertTrue(try storedRows(h.store).allSatisfy { $0.amount == TestFixtures.decimal("2.50") })
    }

    func testRepeatingTheSameImportInsertsNothing() async throws {
        let h = try makeHarness()
        let coffee = operation()
        h.gateway.transactionPages = [nil: page([coffee, coffee])]
        await sync(h)
        let firstPass = Set(try storedRows(h.store).map(\.id))

        await sync(h)
        await sync(h)

        let rows = try storedRows(h.store)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)), firstPass, "no row is replaced, none is added")
    }

    func testImportingTheSameNumberedBatchTwiceInsertsZeroRows() throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let coffee = operation()
        // The batch exactly as the synchronization builds it: fallback identifiers are numbered per window.
        func batch() throws -> [BankTransaction] {
            var occurrences = BankTransactionOccurrenceCounter()
            return try [coffee, coffee].map { dto in
                let row = try XCTUnwrap(BankTransaction(dto: dto, accountID: account.id, accountStableIdentifier: account.stableIdentifier))
                row.externalID = occurrences.identifier(forFingerprint: row.externalID)
                return row
            }
        }
        XCTAssertEqual(try store.importBankTransactionsReturningInsertedIDs(try batch()).count, 2)
        XCTAssertEqual(try store.importBankTransactionsReturningInsertedIDs(try batch()), [])
        XCTAssertEqual(try store.importBankTransactions(try batch()), 0)
        XCTAssertEqual(try storedRows(store).count, 2)
    }

    func testOperationsWithAReferenceKeepTheirIdentifierAndAreNeverNumbered() async throws {
        let h = try makeHarness()
        let byReference = operation("ref-1")
        let byTransactionID = operation(nil, transactionId: "tx-9")
        let twin = operation()
        h.gateway.transactionPages = [nil: page([byReference, byTransactionID, twin, twin])]

        await sync(h)

        let base = fingerprintID(twin)
        XCTAssertEqual(try storedIDs(h.store), ["hash-1#ref-1", "hash-1#tx-9", base, base + "#2"])
    }

    func testRowsStoredBeforeTheFixKeepTheirIdentityAndTheLostTwinIsRecovered() async throws {
        let h = try makeHarness()
        let coffee = operation()
        // What the previous version stored for two identical operations: one row, the other one lost.
        let legacy = try XCTUnwrap(BankTransaction(dto: coffee, accountID: h.account.id, accountStableIdentifier: h.account.stableIdentifier))
        legacy.automaticCategory = legacy.category
        try h.store.importBankTransactions([legacy])
        try h.store.updateBankTransactionNote(id: legacy.id, note: "Tournée du bureau")
        let legacyID = legacy.id
        let legacyExternalID = legacy.externalID

        h.gateway.transactionPages = [nil: page([coffee, coffee])]
        await sync(h)

        let rows = try storedRows(h.store)
        XCTAssertEqual(rows.count, 2, "the operation lost until now is imported")
        let kept = try XCTUnwrap(rows.first { $0.externalID == legacyExternalID })
        XCTAssertEqual(kept.id, legacyID, "the stored row is the first occurrence, not a replacement")
        XCTAssertEqual(kept.userNote, "Tournée du bureau")
        let recovered = try XCTUnwrap(rows.first { $0.externalID == legacyExternalID + "#2" })
        XCTAssertNil(recovered.userNote)
    }

    func testIdenticalOperationsOnDifferentPagesAreNumberedAcrossTheWindow() async throws {
        let h = try makeHarness()
        let coffee = operation()
        h.gateway.transactionPages = [
            nil: page([coffee], key: "p2"),
            "p2": page([coffee, coffee]),
        ]

        await sync(h)

        let base = fingerprintID(coffee)
        XCTAssertEqual(try storedIDs(h.store), [base, base + "#2", base + "#3"])
        XCTAssertNil(h.account.lastSyncError)
    }

    func testNumberingResumesWhereAnInterruptedWindowStopped() async throws {
        let h = try makeHarness()
        let coffee = operation()
        h.gateway.transactionPages = [nil: page([coffee], key: "p2"), "p2": page([coffee])]
        h.gateway.transactionErrors["p2"] = BankGatewayError.transport("offline")
        await sync(h)
        let base = fingerprintID(coffee)
        XCTAssertNotNil(h.account.lastSyncError)
        XCTAssertEqual(try storedIDs(h.store), [base])

        h.gateway.transactionErrors = [:]
        await sync(h)

        XCTAssertNil(h.account.lastSyncError)
        XCTAssertEqual(try storedIDs(h.store), [base, base + "#2"], "the second page continues the numbering of the first")
    }

    func testNumberedRowIsKeptWhileItsTwinIsInTheWindowAndPrunedWhenTheBankDropsIt() async throws {
        let h = try makeHarness()
        let coffee = operation()
        let base = fingerprintID(coffee)
        h.gateway.transactionPages = [nil: page([coffee, coffee])]
        await sync(h)
        await sync(h)
        XCTAssertEqual(try storedIDs(h.store), [base, base + "#2"], "a #2 row present in the window is not purged")

        h.gateway.transactionPages = [nil: page([coffee])]
        await sync(h)

        XCTAssertEqual(try storedIDs(h.store), [base], "the bank now returns one operation: the surplus row goes")
    }

    func testOccurrenceCounterNumbersRepeatsAndRestoresFromFetchedIdentifiers() {
        let base = "hash-1#sha256:" + String(repeating: "ab", count: 32)
        let other = "hash-1#sha256:" + String(repeating: "cd", count: 32)
        var counter = BankTransactionOccurrenceCounter()
        XCTAssertEqual(counter.identifier(forFingerprint: base), base, "the first occurrence keeps the historical identifier")
        XCTAssertEqual(counter.identifier(forFingerprint: base), base + "#2")
        XCTAssertEqual(counter.identifier(forFingerprint: base), base + "#3")
        XCTAssertEqual(counter.identifier(forFingerprint: other), other)

        var resumed = BankTransactionOccurrenceCounter(resumingFrom: [base, base + "#2", "hash-1#ref-1", "hash-1#sha256:short", other])
        XCTAssertEqual(resumed.identifier(forFingerprint: base), base + "#3")
        XCTAssertEqual(resumed.identifier(forFingerprint: other), other + "#2")
        let fresh = "hash-1#sha256:" + String(repeating: "ef", count: 32)
        XCTAssertEqual(resumed.identifier(forFingerprint: fresh), fresh)
    }

    func testOccurrenceIdentifiersAreSplitOnlyWhenTheyHaveTheFingerprintShape() throws {
        let base = "hash-1#sha256:" + String(repeating: "0f", count: 32)
        XCTAssertEqual(BankTransactionOccurrenceCounter.split(base)?.fingerprint, base)
        XCTAssertEqual(BankTransactionOccurrenceCounter.split(base)?.rank, 1)
        XCTAssertEqual(BankTransactionOccurrenceCounter.split(base + "#4")?.fingerprint, base)
        XCTAssertEqual(BankTransactionOccurrenceCounter.split(base + "#4")?.rank, 4)
        XCTAssertNil(BankTransactionOccurrenceCounter.split(base + "#1"), "rank 1 never carries a suffix")
        XCTAssertNil(BankTransactionOccurrenceCounter.split(base + "#x"))
        XCTAssertNil(BankTransactionOccurrenceCounter.split("hash-1#ref-1"))
        XCTAssertNil(BankTransactionOccurrenceCounter.split("hash-1#sha256:" + String(repeating: "zz", count: 32)))
        XCTAssertNil(BankTransactionOccurrenceCounter.split("hash-1#sha256:abc"))
    }

    // Valeurs calculées avec l'algorithme du commit 4ebaa72, avant l'existence du rang d'occurrence :
    // si l'une d'elles change, les opérations déjà en base seraient dupliquées puis purgées.
    func testFallbackIdentifiersOfExistingRowsAreByteForByteUnchanged() throws {
        let cases: [(BankTransactionDTO, String)] = [
            (
                BankTransactionDTO(entryReference: nil, amount: TestFixtures.decimal("12.34"), currency: "EUR", creditDebitIndicator: .debit, status: "PDNG", bookingDate: TestFixtures.date(2026, 9, 10), creditorName: "Shop", remittanceInformation: ["CB SHOP"]),
                "hash-1#sha256:e3c3eebc8e2456493ee6659f2e877dd302f5cfd04ff0db9302223b0bd4636944"
            ),
            (
                BankTransactionDTO(entryReference: nil, amount: TestFixtures.decimal("1204.49"), currency: "EUR", creditDebitIndicator: .credit, bookingDate: TestFixtures.date(2026, 9, 12), debtorName: "ACME SAS", remittanceInformation: ["VIR SALAIRE"]),
                "hash-1#sha256:184d4192c8c4d441c11986d072bcb01776847c80798093991902f4394e2f23d5"
            ),
            (
                BankTransactionDTO(entryReference: nil, amount: TestFixtures.decimal("2.50"), currency: "EUR", creditDebitIndicator: .debit, bookingDate: TestFixtures.date(2026, 9, 14), creditorName: "CAFE"),
                "hash-1#sha256:2a944e716c5f3f5a13f923686d4874817bd51c8a42ea892ba3143fde5fd9749d"
            ),
        ]
        for (dto, expected) in cases {
            let row = try XCTUnwrap(BankTransaction(dto: dto, accountID: UUID(), accountStableIdentifier: "hash-1"))
            XCTAssertEqual(row.externalID, expected)
            var occurrences = BankTransactionOccurrenceCounter()
            XCTAssertEqual(occurrences.identifier(forFingerprint: row.externalID), expected, "first occurrence: identifier untouched")
        }
        let referenced = BankTransactionDTO(entryReference: "ref-7", amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: TestFixtures.date(2026, 9, 10))
        XCTAssertEqual(BankTransaction(dto: referenced, accountID: UUID(), accountStableIdentifier: "hash-1")?.externalID, "hash-1#ref-7")
    }

    func testFallbackDetectionAgreesWithTheIdentifierDerivation() {
        let shapes: [(entry: String?, transaction: String?)] = [(nil, nil), ("", nil), (nil, ""), ("", "tx"), ("ref", nil), (nil, "tx"), ("ref", "tx")]
        for shape in shapes {
            let dto = BankTransactionDTO(entryReference: shape.entry, transactionId: shape.transaction, amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: start)
            let identifier = BankTransaction.externalID(accountStableIdentifier: "hash-1", dto: dto, bookingDate: start)
            XCTAssertEqual(BankTransaction.usesFallbackIdentifier(dto), identifier.contains("#sha256:"), "\(shape)")
        }
    }

    // MARK: - M020 : une ligne illisible ne bloque ni la page ni le compte

    func testUnreadableRowIsSkippedCountedAndTheOthersAreImported() async throws {
        let h = try makeHarness()
        let json = """
        {"transactions":[
          {"entry_reference":"a","transaction_amount":{"currency":"EUR","amount":"5.00"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-13","creditor":{"name":"SHOP"}},
          {"entry_reference":"bad","transaction_amount":{"currency":"EUR","amount":"7.00"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"","creditor":{"name":"SHOP"}},
          {"entry_reference":"c","transaction_amount":{"currency":"EUR","amount":"9.00"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-09-12","creditor":{"name":"SHOP"}}
        ],"continuation_key":null}
        """
        let decoded = try BankGatewayJSON.makeDecoder().decode(BankTransactionsPage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transactions.compactMap(\.entryReference), ["a", "c"])
        XCTAssertEqual(decoded.skippedCount, 1)
        h.gateway.transactionPages = [nil: decoded]

        await sync(h)

        XCTAssertEqual(try storedIDs(h.store), ["hash-1#a", "hash-1#c"])
        XCTAssertNil(h.account.lastSyncError, "an unreadable row never marks the account in error")
        XCTAssertEqual(h.account.normalizedStatus, .active)
        XCTAssertNil(h.service.errorMessage)
        XCTAssertEqual(h.service.lastSyncSkippedRowCount, 1)
        XCTAssertEqual(h.account.balance, 10, "the balance is updated even though a row was skipped")
        XCTAssertNotNil(h.account.lastSyncedAt)
    }

    func testRowWithoutAnyDateIsCountedAsSkippedToo() async throws {
        let h = try makeHarness()
        let undated = BankTransactionDTO(entryReference: "undated", amount: 1, currency: "EUR", creditDebitIndicator: .debit, bookingDate: nil)
        h.gateway.transactionPages = [nil: page([operation("dated"), undated])]

        await sync(h)

        XCTAssertEqual(try storedIDs(h.store), ["hash-1#dated"])
        XCTAssertEqual(h.service.lastSyncSkippedRowCount, 1)
        XCTAssertNil(h.account.lastSyncError)
    }

    func testSkippedRowsAreSummedAcrossAccountsAndResetOnTheNextSynchronization() async throws {
        let h = try makeHarness()
        let other = try XCTUnwrap(try h.store.saveExternalAccounts([TestFixtures.linkedAccount(stableIdentifier: "other")]).first)
        h.gateway.transactionPagesByAccount = [
            "uid-hash-1": [nil: page([operation("a")], skipped: 2)],
            "uid-other": [nil: page([operation("b")], skipped: 3)],
        ]
        await h.service.refresh([h.account, other], attended: true)
        XCTAssertEqual(h.service.lastSyncSkippedRowCount, 5)
        XCTAssertEqual(try storedIDs(h.store), ["hash-1#a", "other#b"])

        h.gateway.transactionPagesByAccount = [
            "uid-hash-1": [nil: page([operation("a")])],
            "uid-other": [nil: page([operation("b")])],
        ]
        await h.service.refresh([h.account, other], attended: true)
        XCTAssertEqual(h.service.lastSyncSkippedRowCount, 0)
    }

    func testAWindowWithSkippedRowsNeverPrunesBecauseTheUnreadableRowMayBeALocalOne() async throws {
        let h = try makeHarness()
        h.gateway.transactionPages = [nil: page([operation("recent", day: -1), operation("older", day: -3)])]
        await sync(h)
        XCTAssertEqual(try storedIDs(h.store), ["hash-1#recent", "hash-1#older"])

        h.gateway.transactionPages = [nil: page([operation("recent", day: -1)], skipped: 1)]
        await sync(h)
        XCTAssertEqual(try storedIDs(h.store), ["hash-1#recent", "hash-1#older"], "the missing row might be the one that could not be read")

        h.gateway.transactionPages = [nil: page([operation("recent", day: -1)], skipped: 0)]
        await sync(h)
        XCTAssertEqual(try storedIDs(h.store), ["hash-1#recent"], "a fully readable window prunes as before")
    }

    // MARK: - m040 : clé de continuation périmée

    private func interruptAfterFirstPage(_ h: Harness) async throws -> Date? {
        let first = operation("a", day: -2)
        let second = operation("b", day: -1)
        h.gateway.transactionPages = [nil: page([first], key: "k1"), "k1": page([second])]
        h.gateway.transactionErrors["k1"] = BankGatewayError.transport("offline")
        await sync(h)
        let checkpoint = try h.store.importCheckpoint(accountID: h.account.id)
        XCTAssertEqual(checkpoint.continuationKey, "k1")
        XCTAssertEqual(checkpoint.fetchedExternalIDs, ["hash-1#a"])
        XCTAssertNotNil(h.account.lastSyncError)
        return checkpoint.windowStart
    }

    func testARejectedContinuationKeyRestartsTheWindowFromItsStart() async throws {
        let rejections: [BankGatewayError] = [
            .http(status: 400, code: "bad_request"),
            .upstream(status: 422, code: "WRONG_CONTINUATION_KEY"),
            .upstream(status: 404, code: "404"),
        ]
        for rejection in rejections {
            let h = try makeHarness()
            let windowStart = try await interruptAfterFirstPage(h)
            h.gateway.transactionQueries = []
            // The bank no longer knows "k1"; read from the start, the whole window fits in one page.
            h.gateway.transactionErrors["k1"] = rejection
            h.gateway.transactionPages = [nil: page([operation("a", day: -2), operation("b", day: -1)])]

            await sync(h)

            XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), ["k1", nil], "\(rejection)")
            XCTAssertEqual(h.gateway.transactionQueries.map(\.dateFrom), [windowStart, windowStart], "the same window restarts, not a new one")
            XCTAssertEqual(h.gateway.transactionQueries.map(\.strategy), ["longest", "longest"])
            XCTAssertEqual(try storedIDs(h.store), ["hash-1#a", "hash-1#b"])
            XCTAssertNil(h.account.lastSyncError)
            XCTAssertEqual(h.account.normalizedStatus, .active)
            let checkpoint = try h.store.importCheckpoint(accountID: h.account.id)
            XCTAssertTrue(checkpoint.initialImportCompleted)
            XCTAssertNil(checkpoint.continuationKey)
            XCTAssertNil(checkpoint.windowStart)
            XCTAssertEqual(checkpoint.fetchedExternalIDs, [])
        }
    }

    func testTheWindowRestartsOnlyOncePerSynchronization() async throws {
        let h = try makeHarness()
        _ = try await interruptAfterFirstPage(h)
        h.gateway.transactionQueries = []
        // A bank that rejects every key: the fresh read hands out "k2", which is rejected too.
        h.gateway.transactionErrors = ["k1": BankGatewayError.http(status: 400, code: "bad_request"), "k2": BankGatewayError.http(status: 400, code: "bad_request")]
        h.gateway.transactionPages = [nil: page([operation("a", day: -2)], key: "k2")]

        await sync(h)

        XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), ["k1", nil, "k2"], "one restart, then the error is reported")
        XCTAssertEqual(h.account.normalizedStatus, .error)
        XCTAssertNotNil(h.account.lastSyncError)
        XCTAssertNotNil(h.service.errorMessage)
    }

    func testClientErrorsThatAreNotAboutTheKeyNeverRestartTheWindow() async throws {
        let errors: [BankGatewayError] = [
            .upstream(status: 403, code: "403"),
            .upstream(status: 429, code: "429"),
            .upstream(status: 401, code: "401"),
            .rateLimited(retryAfterSeconds: 60),
            .sessionExpired,
            .unauthorized,
            .linkNotFound,
            .http(status: 500, code: nil),
            .upstream(status: 502, code: "unknown"),
            .transport("offline"),
            .decoding("odd"),
        ]
        for error in errors {
            let h = try makeHarness()
            _ = try await interruptAfterFirstPage(h)
            h.gateway.transactionQueries = []
            h.gateway.transactionErrors["k1"] = error

            await sync(h)

            XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), ["k1"], "\(error) must not replay the window")
            let checkpoint = try h.store.importCheckpoint(accountID: h.account.id)
            XCTAssertEqual(checkpoint.continuationKey, "k1", "the saved key survives errors that are not about it")
            XCTAssertEqual(checkpoint.fetchedExternalIDs, ["hash-1#a"])
        }
    }

    func testAResumePointOlderThanADayIsDroppedBeforeAskingTheBank() async throws {
        let cases: [(hours: Double, resumes: Bool)] = [(23, true), (25, false)]
        for scenario in cases {
            let h = try makeHarness()
            let windowStart = try await interruptAfterFirstPage(h)
            h.gateway.transactionErrors = [:]
            h.gateway.transactionQueries = []
            h.clock.now = start.addingTimeInterval(scenario.hours * 3600)

            await sync(h)

            if scenario.resumes {
                XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), ["k1"], "\(scenario.hours) h: the saved key is still used")
            } else {
                XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), [nil, "k1"], "\(scenario.hours) h: the window is re-read from its start")
            }
            XCTAssertEqual(h.gateway.transactionQueries.first?.dateFrom, windowStart)
            XCTAssertEqual(try storedIDs(h.store), ["hash-1#a", "hash-1#b"])
            XCTAssertNil(h.account.lastSyncError)
        }
    }

    // A process killed mid-import records no failure: only the attempt date is left to bound the age,
    // and it must be read before the new attempt overwrites it.
    func testAKilledProcessLeavesNoFailureDateButTheAttemptDateStillBoundsTheAge() async throws {
        let cases: [(attemptedHoursAgo: Double?, resumes: Bool)] = [(1, true), (25, false), (nil, true)]
        for scenario in cases {
            let h = try makeHarness()
            let checkpoint = try h.store.importCheckpoint(accountID: h.account.id)
            checkpoint.windowStart = TestFixtures.day(offset: -30)
            checkpoint.continuationKey = "k1"
            checkpoint.fetchedExternalIDs = ["hash-1#a"]
            checkpoint.lastAttemptAt = scenario.attemptedHoursAgo.map { start.addingTimeInterval(-$0 * 3600) }
            checkpoint.lastFailedAt = nil
            try h.store.saveImportCheckpoint()
            h.gateway.transactionPages = [nil: page([operation("a", day: -2)], key: "k1"), "k1": page([operation("b", day: -1)])]

            await sync(h)

            let label = "attempt \(scenario.attemptedHoursAgo.map { "\($0) h ago" } ?? "unknown")"
            let expectedKeys: [String?] = scenario.resumes ? ["k1"] : [nil, "k1"]
            XCTAssertEqual(h.gateway.transactionQueries.map(\.continuationKey), expectedKeys, label)
            XCTAssertEqual(h.gateway.transactionQueries.first?.dateFrom, TestFixtures.day(offset: -30), label)
            XCTAssertNil(h.account.lastSyncError, label)
        }
    }

    // Le profil change pendant que la banque répond « clé inconnue » : rien n'est réécrit, rien n'est relancé.
    func testAProfileInvalidatedWhileTheKeyIsBeingRejectedLeavesTheResumePointUntouched() async throws {
        let store = try TestFixtures.makeDataStore()
        let account = try XCTUnwrap(try store.saveExternalAccounts([TestFixtures.linkedAccount()]).first)
        let checkpoint = try store.importCheckpoint(accountID: account.id)
        checkpoint.windowStart = TestFixtures.day(offset: -30)
        checkpoint.continuationKey = "k1"
        checkpoint.fetchedExternalIDs = ["hash-1#a"]
        try store.saveImportCheckpoint()
        let gateway = SuspendedRejectionGateway()
        let service = BankSyncService(gateway: gateway, dataStore: store, referenceDateProvider: { TestFixtures.referenceDate })

        let work = Task { await service.refresh([account], attended: true) }
        await gateway.waitForRequest()
        service.invalidate()
        await gateway.release()
        await work.value

        let requests = await gateway.transactionRequests
        XCTAssertEqual(requests, 1, "an invalidated profile does not replay the window")
        XCTAssertEqual(checkpoint.continuationKey, "k1")
        XCTAssertEqual(checkpoint.fetchedExternalIDs, ["hash-1#a"])
        XCTAssertNil(account.lastSyncError)
        XCTAssertTrue(try storedRows(store).isEmpty)
    }

    // MARK: - Audit du 9 novembre 2026, constats 3, 4 et 11

    private func daysAgo(_ date: Date?, at now: Date) throws -> Double {
        now.timeIntervalSince(try XCTUnwrap(date)) / 86_400
    }

    // Constat 3 : une opération vieille de plus de 90 jours ne doit pas faire partir la fenêtre d'une date que la banque
    // refuse (WRONG_TRANSACTIONS_PERIOD), et un échec d'import ne doit pas figer le solde.
    func testDormantAccountNeverAsksForMoreThanTheBankServes() async throws {
        let h = try makeHarness()
        h.gateway.transactionPages = [nil: page([operation("old", day: -100)])]
        await sync(h)

        h.clock.now = start.addingTimeInterval(86_400)
        await sync(h)
        let incremental = try XCTUnwrap(h.gateway.transactionQueries.last)
        XCTAssertLessThanOrEqual(try daysAgo(incremental.dateFrom, at: h.clock.now), 89)

        // Un point de reprise déjà écrit par une version fautive est ramené lui aussi.
        let checkpoint = try h.store.importCheckpoint(accountID: h.account.id)
        checkpoint.windowStart = TestFixtures.day(offset: -120)
        checkpoint.continuationKey = "stale"
        try h.store.saveImportCheckpoint()
        await sync(h)
        let resumed = try XCTUnwrap(h.gateway.transactionQueries.last)
        XCTAssertLessThanOrEqual(try daysAgo(resumed.dateFrom, at: h.clock.now), 89)
        XCTAssertNil(resumed.continuationKey, "une clé liée à l'ancienne fenêtre ne s'applique plus à la nouvelle")
    }

    func testBalanceIsKeptWhenTheTransactionImportFails() async throws {
        let h = try makeHarness()
        await sync(h)
        let firstSync = h.account.lastSyncedAt
        XCTAssertEqual(h.account.balance, 10)

        h.gateway.transactionErrors[nil] = BankGatewayError.http(status: 400, code: "bad_request")
        h.gateway.balancesResult = .success([BankBalance(name: nil, balanceType: "XPCD", amount: 999, currency: "EUR")])
        h.clock.now = start.addingTimeInterval(86_400)
        await sync(h)

        XCTAssertEqual(h.account.balance, 999, "le solde lu juste avant est enregistré malgré l'échec")
        XCTAssertEqual(h.account.lastSyncedAt, firstSync, "mais la synchronisation reste en échec")
        XCTAssertNotNil(h.account.lastSyncError)
        XCTAssertEqual(h.account.normalizedStatus, .error)
    }

    // Constat 4 : une réponse vide ne prouve la disparition de rien de comptabilisé ; seul l'en-cours (pending) s'efface.
    func testAnEmptyAnswerDeletesPendingEntriesOnlyNeverBookedOnes() async throws {
        let h = try makeHarness()
        h.gateway.transactionPages = [nil: page([
            operation("booked-a", day: -10), operation("booked-b", day: -12), operation("held", day: -11, status: "PDNG"),
        ])]
        await sync(h)
        XCTAssertEqual(try storedRows(h.store).count, 3)

        h.gateway.transactionPages = [nil: page([])]
        await sync(h)

        XCTAssertEqual(try storedRows(h.store).map(\.externalID).sorted(), ["hash-1#booked-a", "hash-1#booked-b"])
        XCTAssertTrue(try storedRows(h.store).allSatisfy { !$0.isAbsentFromBank })
        XCTAssertNil(h.account.lastSyncError)
    }

    // Constat 11 : un compte en erreur n'est pas redemandé à chaque appel ; après un 429, on attend ce que la banque a dit.
    func testAccountInErrorWaitsForTheRateLimitDelayBeforeBeingRetried() async throws {
        let h = try makeHarness()
        h.gateway.balancesResult = .failure(BankGatewayError.rateLimited(retryAfterSeconds: 6 * 3600))
        func stale() async { await h.service.refreshIfStale([h.account], maxAge: 8 * 3600, attended: false) }

        await stale()
        await stale()
        XCTAssertEqual(h.gateway.balanceRequests.count, 1, "deuxième appel immédiat : aucune requête")
        h.clock.now = start.addingTimeInterval(5 * 3600)
        await stale()
        XCTAssertEqual(h.gateway.balanceRequests.count, 1, "le délai de 6 h n'est pas écoulé")
        h.clock.now = start.addingTimeInterval(6 * 3600 + 1)
        await stale()
        XCTAssertEqual(h.gateway.balanceRequests.count, 2)
    }

    // Relecture de la PR 3 : le délai de la banque est borné, par le bas (délai minimal) et par le haut (24 h).
    func testRateLimitDelayIsClampedBetweenTheMinimumAndOneDay() async throws {
        let minimum = BankSyncService.minimumRetryDelayAfterFailure
        let cases: [(seconds: Int, waits: TimeInterval)] = [(0, minimum), (-5, minimum), (Int.max, 24 * 3600)]
        for (seconds, waits) in cases {
            let h = try makeHarness()
            h.gateway.balancesResult = .failure(BankGatewayError.rateLimited(retryAfterSeconds: seconds))
            func stale() async { await h.service.refreshIfStale([h.account], maxAge: 8 * 3600, attended: false) }

            await stale()
            await stale()
            XCTAssertEqual(h.gateway.balanceRequests.count, 1, "\(seconds) : pas de nouvelle requête tout de suite")
            h.clock.now = start.addingTimeInterval(waits - 1)
            await stale()
            XCTAssertEqual(h.gateway.balanceRequests.count, 1, "\(seconds) : pas avant \(waits) s")
            h.clock.now = start.addingTimeInterval(waits + 1)
            await stale()
            XCTAssertEqual(h.gateway.balanceRequests.count, 2, "\(seconds) : de nouveau permis après \(waits) s")
        }
    }

    func testAnEmptyBalanceListDoesNotEraseTheLastKnownBalanceWhenTheImportFails() async throws {
        let h = try makeHarness()
        await sync(h)
        XCTAssertEqual(h.account.balance, 10)

        h.gateway.transactionErrors[nil] = BankGatewayError.http(status: 400, code: "bad_request")
        h.gateway.balancesResult = .success([])
        h.clock.now = start.addingTimeInterval(86_400)
        await sync(h)

        XCTAssertEqual(h.account.balance, 10)
        XCTAssertNotNil(h.account.lastSyncError)
    }

    func testAccountInErrorIsNotRetriedBeforeTheMinimumDelay() async throws {
        let h = try makeHarness()
        h.gateway.balancesResult = .failure(BankGatewayError.transport("offline"))
        func stale() async { await h.service.refreshIfStale([h.account], maxAge: 8 * 3600) }

        await stale()
        h.clock.now = start.addingTimeInterval(BankSyncService.minimumRetryDelayAfterFailure - 1)
        await stale()
        XCTAssertEqual(h.gateway.balanceRequests.count, 1)
        h.clock.now = start.addingTimeInterval(BankSyncService.minimumRetryDelayAfterFailure + 1)
        await stale()
        XCTAssertEqual(h.gateway.balanceRequests.count, 2)
    }
}

// Answers its first transactions request only once released, and then rejects the key; later requests
// return an empty page at once, so a missing guard shows up as a failed assertion rather than a hang.
private actor SuspendedRejectionGateway: BankGatewayClient {
    nonisolated var requiresConfiguration: Bool { false }
    private(set) var transactionRequests = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func startLink(institution: BankInstitution) async throws -> BankLinkStart { throw BankGatewayError.notConfigured }
    func link(id: String) async throws -> BankLink { throw BankGatewayError.notConfigured }
    func deleteLink(id: String) async throws {}
    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        [BankBalance(name: nil, balanceType: "CLBD", amount: 10, currency: "EUR")]
    }
    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        transactionRequests += 1
        guard transactionRequests == 1 else { return BankTransactionsPage(transactions: [], continuationKey: nil) }
        await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
        throw BankGatewayError.http(status: 400, code: "bad_request")
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
