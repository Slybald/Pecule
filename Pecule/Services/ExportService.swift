import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Portable copies of the data: a spreadsheet-friendly CSV and an A4 monthly report.
struct ExportService {
    static let separator = ";"
    static let byteOrderMark = "\u{FEFF}"
    static let csvFileName = "pecule-export.csv"
    static let pdfFileName = "pecule-rapport.pdf"

    private let calendar: Calendar
    private let dateFormatter: DateFormatter
    private let numberFormatter: NumberFormatter

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = dateFormatter
        // Decimal comma, no grouping: what French Excel and Numbers expect with a semicolon separator.
        let numberFormatter = NumberFormatter()
        numberFormatter.locale = Locale(identifier: "fr_FR")
        numberFormatter.numberStyle = .decimal
        numberFormatter.usesGroupingSeparator = false
        numberFormatter.minimumFractionDigits = 2
        numberFormatter.maximumFractionDigits = 2
        self.numberFormatter = numberFormatter
    }

    static let csvHeader = ["type", "date", "libelle", "montant", "sens", "devise", "categorie", "compte", "statut", "details"]

    func csv(from snapshot: AppDataSnapshot) -> String {
        var rows: [[String]] = [Self.csvHeader]
        let accountNames = Dictionary(uniqueKeysWithValues: snapshot.externalAccounts.map { ($0.id, $0.name) })

        for purchase in snapshot.purchases.sorted(by: { $0.date < $1.date }) {
            rows.append(["achat", date(purchase.date), purchase.title, amount(purchase.amount), "debit", "EUR", ExpenseCategory.canonicalStorageValue(for: purchase.category), "", "", [purchase.merchant, purchase.notes ?? ""].filter { !$0.isEmpty }.joined(separator: " / ")])
        }
        for subscription in snapshot.subscriptions.sorted(by: { $0.nextBillingDate < $1.nextBillingDate }) {
            rows.append(["abonnement", date(subscription.nextBillingDate), subscription.name, amount(subscription.amount), "debit", "EUR", ExpenseCategory.canonicalStorageValue(for: subscription.category), "", subscription.isActive ? "actif" : "inactif", subscription.billingCycle.rawValue])
        }
        for source in snapshot.incomeSources.sorted(by: { $0.startDate < $1.startDate }) {
            rows.append(["revenu", date(source.startDate), source.name, amount(source.amount), "credit", "EUR", source.type.rawValue, "", source.isActive ? "actif" : "inactif", source.isRecurring ? "recurrent" : "ponctuel"])
        }
        // Undated intentions export an empty date rather than the creation instant kept in targetDate.
        let datedGoals = snapshot.goals.map { (goal: $0, due: $0.deadline(calendar: calendar)) }
        for entry in datedGoals.sorted(by: { left, right in
            switch (left.due, right.due) {
            case let (leftDue?, rightDue?): return leftDue < rightDue
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.goal.title < right.goal.title
            }
        }) {
            let goal = entry.goal
            let details = ["cible " + amount(goal.targetAmount), goal.normalizedIntention.rawValue, goal.durationMonths.map { "\($0) mois" } ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            rows.append(["objectif", entry.due.map(date) ?? "", goal.title, amount(goal.currentAmount), "", "EUR", goal.category, "", goal.isArchived ? "archive" : "actif", details])
        }
        for account in snapshot.externalAccounts.sorted(by: { $0.name < $1.name }) {
            rows.append(["compte", account.balanceDate.map(date) ?? "", account.name, account.balance.map(amount) ?? "", "", account.currencyCode, "", account.maskedIBAN ?? "", account.status, account.institution])
        }
        for transaction in snapshot.bankTransactions.sorted(by: { $0.bookingDate < $1.bookingDate }) {
            rows.append([
                "banque",
                date(transaction.bookingDate),
                transaction.label,
                amount(transaction.amount),
                transaction.normalizedDirection == .credit ? "credit" : "debit",
                transaction.currencyCode,
                ExpenseCategory.canonicalStorageValue(for: transaction.category),
                accountNames[transaction.accountID] ?? "",
                transaction.normalizedStatus == .pending ? "en attente" : "comptabilise",
                [transaction.isInternalTransfer ? "virement interne" : "", transaction.isIgnored ? "ignore" : "", transaction.isLinked ? "rapproche" : ""].filter { !$0.isEmpty }.joined(separator: " / "),
            ])
        }

        return Self.byteOrderMark + rows.map { $0.map(escape).joined(separator: Self.separator) }.joined(separator: "\r\n") + "\r\n"
    }

    func csvData(from snapshot: AppDataSnapshot) -> Data {
        Data(csv(from: snapshot).utf8)
    }

    // One A4 page rendered from SwiftUI; nil only if Core Graphics refuses the context.
    @MainActor
    func monthlyReportPDF(_ report: MonthlyReport) -> Data? {
        let pageSize = CGSize(width: 595, height: 842)
        let renderer = ImageRenderer(content: MonthlyReportView(report: report).frame(width: pageSize.width, height: pageSize.height))
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        renderer.render { _, render in
            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    func date(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    func amount(_ value: Decimal) -> String {
        numberFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    // Excel et Numbers exécutent comme une formule une cellule qui commence par = + - @, tabulation ou retour chariot ;
    // un libellé bancaire vient d'un tiers, on le neutralise par une apostrophe (OWASP), sauf pour un nombre.
    static let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    // Quote a field when it holds the separator, a quote or a line break; quotes are doubled.
    func escape(_ field: String) -> String {
        var field = field
        var needsQuotes = field.contains(Self.separator) || field.contains("\"") || field.contains("\n") || field.contains("\r")
        if let first = field.first, Self.formulaTriggers.contains(first), !Self.looksNumeric(field) {
            field = "'" + field
            needsQuotes = true
        }
        guard needsQuotes else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func looksNumeric(_ field: String) -> Bool {
        field.contains(where: \.isNumber) && field.allSatisfy { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" || $0 == "+" || $0 == " " }
    }
}

struct MonthlyReport: Equatable {
    let month: Date
    let summary: MonthlyFinancialSummary
    let budgetRows: [BudgetOverviewRow]
    let forecast: CashflowForecast?
    let health: FinancialHealthScore
    let totalBalance: Decimal?
}

struct ExportedFile: Transferable, Identifiable {
    let data: Data
    let fileName: String
    let contentType: UTType

    var id: String { fileName }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { $0.data }
            .suggestedFileName { $0.fileName }
    }
}

extension AppState {
    // Toute la table des opérations, pas l'instantané de l'app (13 mois) : la portabilité couvre la rétention de 24 mois.
    // Lecture et mise en forme sur un contexte neuf, hors du fil principal (les modèles ne quittent pas la tâche).
    // `snapshotReader` n'existe que pour que les tests voient sur quel fil la lecture s'exécute.
    func csvExportInBackground(
        snapshotReader: @escaping @Sendable (ModelContainer) throws -> AppDataSnapshot = { try PeculeDataStore.loadSnapshot(in: ModelContext($0)) }
    ) async throws -> ExportedFile {
        let container = dataStore.container
        let data = try await Task.detached(priority: .userInitiated) {
            ExportService().csvData(from: try snapshotReader(container))
        }.value
        return ExportedFile(data: data, fileName: ExportService.csvFileName, contentType: .commaSeparatedText)
    }

    func monthlyReport(for month: Date = Date(), calendar: Calendar = .current) -> MonthlyReport {
        MonthlyReport(
            month: month,
            summary: monthlyFinancialSummary(for: month, calendar: calendar),
            budgetRows: budgetOverview(for: month, calendar: calendar).filter { $0.plannedAmount != nil || $0.spentAmount > .zero },
            forecast: cashflowForecast(on: month, calendar: calendar),
            health: financialHealthScore(on: month, calendar: calendar),
            totalBalance: totalExternalBalance()
        )
    }

    func pdfExport(for month: Date = Date()) -> ExportedFile? {
        ExportService().monthlyReportPDF(monthlyReport(for: month)).map {
            ExportedFile(data: $0, fileName: ExportService.pdfFileName, contentType: .pdf)
        }
    }
}

// État de l'export affiché par les réglages : un seul export à la fois, une erreur rendue à l'utilisateur.
@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var isExporting = false
    @Published var file: ExportedFile?
    @Published var failed = false

    func run(_ produce: () async throws -> ExportedFile) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do { file = try await produce() } catch { failed = true }
    }
}
