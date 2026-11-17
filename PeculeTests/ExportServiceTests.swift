import PDFKit
import SwiftData
import Synchronization
import XCTest
@testable import Pecule

@MainActor
final class ExportServiceTests: XCTestCase {
    private func makeState() throws -> AppState {
        let appState = try TestFixtures.makeAppState(seeded: false)
        try appState.addPurchase(title: "Courses; \"bio\"", amount: TestFixtures.decimal("12.5"), date: TestFixtures.date(2026, 9, 3), category: ExpenseCategory.groceries.storageValue, merchant: "Biocoop", notes: nil)
        try appState.addIncomeSource(name: "Salaire", amount: 1500, type: .salary, startDate: TestFixtures.date(2026, 1, 1), endDate: nil, isRecurring: true, isActive: true)
        let account = try XCTUnwrap(try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(name: "Compte courant", balance: TestFixtures.decimal("1234.56"))]).first)
        try appState.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "cb-1", amount: TestFixtures.decimal("1000"), direction: .credit, dayOffset: -1, label: "SALAIRE"),
        ])
        // Deux intentions différentes : l'une porte une échéance, l'autre n'en a pas.
        try appState.dataStore.saveGoalPlan(id: nil, title: "Voyage", target: 2000, current: 300, category: ExpenseCategory.leisure.storageValue,
                                            intention: .deadline, targetDate: TestFixtures.date(2026, 12, 24), durationMonths: 12, showsHelp: false, now: TestFixtures.referenceDate)
        try appState.dataStore.saveGoalPlan(id: nil, title: "Casque", target: 300, current: 0, category: ExpenseCategory.shopping.storageValue,
                                            intention: .purchase, targetDate: TestFixtures.referenceDate, durationMonths: 12, showsHelp: false, now: TestFixtures.referenceDate)
        appState.reload()
        return appState
    }

    func testCSVUsesBOMSemicolonsDecimalCommaAndEscapesFields() throws {
        // Keep the state alive: the snapshot's model instances die with their container.
        let appState = try makeState()
        let csv = ExportService(calendar: TestFixtures.utcCalendar()).csv(from: appState.currentSnapshot)

        XCTAssertTrue(csv.hasPrefix(ExportService.byteOrderMark), "Excel needs the BOM to read UTF-8 accents")
        let lines = csv.dropFirst().split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.first, ExportService.csvHeader.joined(separator: ";"))
        XCTAssertEqual(lines.count, 7, "en-tête + achat + revenu + deux objectifs + compte + ligne bancaire")
        let purchase = try XCTUnwrap(lines.first { $0.hasPrefix("achat;") })
        XCTAssertEqual(purchase, "achat;2026-09-03;\"Courses; \"\"bio\"\"\";12,50;debit;EUR;Groceries;;;Biocoop")
        let income = try XCTUnwrap(lines.first { $0.hasPrefix("revenu;") })
        XCTAssertTrue(income.contains(";Salaire;1500,00;credit;EUR;salary;"))
        let account = try XCTUnwrap(lines.first { $0.hasPrefix("compte;") })
        XCTAssertTrue(account.contains(";Compte courant;1234,56;;EUR;"))
        let bank = try XCTUnwrap(lines.first { $0.hasPrefix("banque;") })
        XCTAssertTrue(bank.contains(";SALAIRE;1000,00;credit;EUR;Other;Compte courant;comptabilise;"))
    }

    // L'export lisait la colonne brute `targetDate`, qui ne veut rien dire pour une intention sans
    // échéance : un objectif d'achat ressortait avec la date de sa création comme date cible.
    func testGoalsAreExportedThroughTheirIntentionNotTheirRawColumn() throws {
        let appState = try makeState()

        let csv = ExportService(calendar: TestFixtures.utcCalendar()).csv(from: appState.currentSnapshot)
        let lines = csv.dropFirst().split(separator: "\r\n").map(String.init).filter { $0.hasPrefix("objectif;") }

        XCTAssertEqual(lines.count, 2)
        let voyage = try XCTUnwrap(lines.first { $0.contains(";Voyage;") })
        XCTAssertTrue(voyage.hasPrefix("objectif;2026-12-24;"), "une échéance réelle est exportée : \(voyage)")
        let casque = try XCTUnwrap(lines.first { $0.contains(";Casque;") })
        XCTAssertTrue(casque.hasPrefix("objectif;;"), "sans échéance, la colonne reste vide : \(casque)")
        XCTAssertTrue(casque.contains("purchase"), "l'intention accompagne la ligne : \(casque)")
        XCTAssertEqual(lines.firstIndex(of: voyage)! < lines.firstIndex(of: casque)!, true, "les objectifs datés passent avant")
    }

    func testEscapeOnlyQuotesWhenNeeded() {
        let service = ExportService()

        XCTAssertEqual(service.escape("Netflix"), "Netflix")
        XCTAssertEqual(service.escape("a;b"), "\"a;b\"")
        XCTAssertEqual(service.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(service.escape("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(service.amount(TestFixtures.decimal("1234.5")), "1234,50")
    }

    func testEscapeNeutralisesSpreadsheetFormulasButKeepsAmounts() {
        let service = ExportService()

        XCTAssertEqual(service.escape("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(service.escape("@SUM(A1)"), "\"'@SUM(A1)\"")
        XCTAssertEqual(service.escape("-cmd"), "\"'-cmd\"")
        XCTAssertEqual(service.escape("\tTab"), "\"'\tTab\"")
        XCTAssertEqual(service.escape("-42,00"), "-42,00")
        XCTAssertEqual(service.escape("+4,49"), "+4,49")
        XCTAssertEqual(service.escape("1 234,56"), "1 234,56")
    }

    func testMonthlyReportRendersAPDF() async throws {
        let appState = try makeState()

        let file = try XCTUnwrap(appState.pdfExport(for: TestFixtures.referenceDate))

        XCTAssertEqual(file.fileName, ExportService.pdfFileName)
        XCTAssertTrue(String(decoding: file.data.prefix(5), as: UTF8.self).hasPrefix("%PDF"), "a real PDF header")
        XCTAssertGreaterThan(file.data.count, 1_000)
        let csvFile = try await appState.csvExportInBackground()
        XCTAssertEqual(csvFile.fileName, ExportService.csvFileName)
    }

    // M004 : le PDF ne porte aucun « solde prévu » ni fourchette tant que la prévision est absente.
    func testMonthlyReportCarriesNoMonthEndBalanceWhileTheForecastIsWithheld() throws {
        let appState = try makeState()

        XCTAssertNil(appState.monthlyReport(for: TestFixtures.referenceDate).forecast?.expectedClosingBalance)
        let file = try XCTUnwrap(appState.pdfExport(for: TestFixtures.referenceDate))
        let text = try XCTUnwrap(PDFDocument(data: file.data)?.string)

        XCTAssertTrue(text.localizedCaseInsensitiveContains("Reste à vivre"), "le texte du PDF est lisible et le reste du rapport est là : \(text.prefix(200))")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Solde prévu"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Fourchette"))
    }

    // Constat 8 : l'export lisait l'instantané de l'app (13 derniers mois + opérations rapprochées), alors que la
    // rétention est de 24 mois : une opération non rapprochée de 20 mois en était absente.
    func testCSVExportCarriesBankTransactionsOlderThanTheAppSnapshotWindow() async throws {
        let appState = try TestFixtures.makeAppState(seeded: false)
        let account = try XCTUnwrap(try appState.dataStore.saveExternalAccounts([TestFixtures.linkedAccount(name: "Compte courant")]).first)
        try appState.dataStore.importBankTransactions([
            TestFixtures.transaction(account: account, reference: "ancienne", amount: TestFixtures.decimal("42"), direction: .debit, dayOffset: -600, label: "VIEILLE OPERATION"),
            TestFixtures.transaction(account: account, reference: "recente", amount: TestFixtures.decimal("10"), direction: .debit, dayOffset: -3, label: "RECENTE"),
        ].map { transaction in
            // Les dates des fixtures partent de la date de référence ; on ancre sur aujourd'hui, comme la fenêtre de l'app.
            transaction.bookingDate = TestFixtures.day(offset: transaction.label == "RECENTE" ? -3 : -600, from: Date())
            return transaction
        })
        appState.reload()
        XCTAssertFalse(appState.bankTransactions.contains { $0.label == "VIEILLE OPERATION" }, "précondition : hors de la fenêtre de l'app")

        let csv = String(decoding: try await appState.csvExportInBackground().data, as: UTF8.self)

        XCTAssertTrue(csv.contains(";VIEILLE OPERATION;42,00;debit;"))
        XCTAssertTrue(csv.contains(";RECENTE;10,00;debit;"))
    }

    // Le format ne bouge pas pour ce qui y figurait déjà : mêmes octets que l'export de l'instantané.
    func testCSVExportKeepsTheExactFormatForTransactionsAlreadyExported() async throws {
        let appState = try makeState()

        let exported = try await appState.csvExportInBackground()
        XCTAssertEqual(exported.data, ExportService().csvData(from: appState.currentSnapshot))
    }

    // La lecture de toute la table ne s'exécute pas sur le fil principal : affirmé au moment de la lecture,
    // donc indépendant de la charge de la machine. (Mesure à 50 000 opérations : voir la description de la PR.)
    func testCSVExportReadsTheTableOffTheMainThread() async throws {
        let appState = try TestFixtures.makeAppState(seeded: false)
        let readOnMainThread = Mutex<Bool?>(nil)

        _ = try await appState.csvExportInBackground { container in
            readOnMainThread.withLock { $0 = Thread.isMainThread }
            return try PeculeDataStore.loadSnapshot(in: ModelContext(container))
        }

        XCTAssertEqual(readOnMainThread.withLock { $0 }, false)
    }

    // Logique de l'écran, sans interface : un seul export à la fois, et l'échec est rendu à l'utilisateur.
    func testExportCoordinatorRunsOneExportAtATimeAndReportsFailure() async throws {
        let coordinator = ExportCoordinator()
        let calls = Mutex(0)
        let file = ExportedFile(data: Data(), fileName: "x.csv", contentType: .commaSeparatedText)

        async let first: Void = coordinator.run {
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(200))
            return file
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(coordinator.isExporting)
        await coordinator.run { calls.withLock { $0 += 1 }; return file }
        await first

        XCTAssertEqual(calls.withLock { $0 }, 1, "le second appui pendant l'export est ignoré")
        XCTAssertFalse(coordinator.isExporting)
        XCTAssertEqual(coordinator.file?.fileName, "x.csv")
        XCTAssertFalse(coordinator.failed)

        await coordinator.run { throw SecretStoreError.invalidData }
        XCTAssertTrue(coordinator.failed)
        XCTAssertFalse(coordinator.isExporting)
    }
}
