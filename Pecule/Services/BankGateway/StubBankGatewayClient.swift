import Foundation
import Synchronization

// Deterministic stand-in used by unit tests, previews and UI automation; mirrors the Mock ASPSP sandbox data.
final class StubBankGatewayClient: BankGatewayClient {
    static let linkID = "stub-link-0001"
    static let accountUID = "63a6f008-0852-4daa-98ce-b19430e1c1c4"
    static let accountIdentificationHash = "stub-identification-hash"

    private let state = Mutex<State>(State())
    private let stressesFinancialHealth: Bool

    init(stressesFinancialHealth: Bool = false) {
        self.stressesFinancialHealth = stressesFinancialHealth
    }

    private struct State {
        var startedLinks: [String] = []
        var deletedLinks: [String] = []
        var failure: BankGatewayError?
    }

    var startedLinks: [String] { state.withLock { $0.startedLinks } }
    var deletedLinks: [String] { state.withLock { $0.deletedLinks } }

    func failNextCalls(with error: BankGatewayError?) {
        state.withLock { $0.failure = error }
    }

    var requiresConfiguration: Bool { false }

    // A lifeos:// callback lets the link flow complete without a web authentication session.
    func startLink(institution: BankInstitution) async throws -> BankLinkStart {
        try throwIfFailing()
        state.withLock { $0.startedLinks.append(institution.rawValue) }
        return BankLinkStart(
            linkId: Self.linkID,
            authUrl: URL(string: "lifeos://link/done?linkId=\(Self.linkID)")!,
            validUntil: Self.consentValidUntil
        )
    }

    func link(id: String) async throws -> BankLink {
        try throwIfFailing()
        guard id == Self.linkID else {
            throw BankGatewayError.linkNotFound
        }
        return BankLink(
            id: id,
            status: .authorized,
            aspsp: BankAspsp(name: BankInstitution.mock.aspspName, country: BankInstitution.mock.aspspCountry),
            validUntil: Self.consentValidUntil,
            errorCode: nil,
            accounts: [
                BankLinkAccount(
                    uid: Self.accountUID,
                    identificationHash: Self.accountIdentificationHash,
                    iban: nil,
                    name: "Titulaire démo",
                    currency: "EUR",
                    product: nil,
                    cashAccountType: "CACC",
                    usage: "PRIV"
                ),
            ]
        )
    }

    func deleteLink(id: String) async throws {
        try throwIfFailing()
        state.withLock { $0.deletedLinks.append(id) }
    }

    func balances(accountUID: String, attended: Bool) async throws -> [BankBalance] {
        try throwIfFailing()
        guard accountUID == Self.accountUID else {
            throw BankGatewayError.http(status: 404, code: "account_not_found")
        }
        return [BankBalance(name: "Closing accounting balance", balanceType: "CLBD", amount: Decimal(string: "53.51")!, currency: "EUR")]
    }

    func transactions(accountUID: String, query: BankTransactionsQuery, attended: Bool) async throws -> BankTransactionsPage {
        try throwIfFailing()
        guard accountUID == Self.accountUID else {
            throw BankGatewayError.http(status: 404, code: "account_not_found")
        }
        return BankTransactionsPage(transactions: stressesFinancialHealth ? Self.financialStressTransactions : Self.sampleTransactions(), continuationKey: nil)
    }

    // Automation-only evidence that exercises every financial-health advice branch.
    // All rows belong to this month, including when tests run on the first day.
    static var financialStressTransactions: [BankTransactionDTO] {
        let date = Calendar.current.peculeMonthStart(for: Date())
        return [
            BankTransactionDTO(entryReference: "stress-salary", amount: 1200, currency: "EUR", creditDebitIndicator: .credit, bookingDate: date, debtorName: "Employeur test", remittanceInformation: ["SALAIRE TEST"]),
            BankTransactionDTO(entryReference: "stress-rent", amount: 1100, currency: "EUR", creditDebitIndicator: .debit, bookingDate: date, creditorName: "Bailleur test", remittanceInformation: ["LOYER TEST"]),
            BankTransactionDTO(entryReference: "stress-shopping", amount: 350, currency: "EUR", creditDebitIndicator: .debit, bookingDate: date, creditorName: "Commerce test", remittanceInformation: ["ACHAT TEST"]),
        ]
    }

    static let consentValidUntil = BankGatewayDateParser.parse("2027-03-13T07:39:07.434000Z")!

    // Dates are relative to `now` so the current-month views always show the sample in UI automation;
    // tests inject a fixed `now` (and calendar) so the sample does not depend on the day of the month.
    static func sampleTransactions(now: Date = Date(), calendar: Calendar = .current) -> [BankTransactionDTO] {
        func date(_ offset: Int) -> Date { day(offset: offset, now: now, calendar: calendar) }
        return [
            BankTransactionDTO(
                entryReference: "dkx1z",
                amount: Decimal(string: "8.19")!,
                currency: "EUR",
                creditDebitIndicator: .debit,
                bookingDate: date(0),
                valueDate: date(-1),
                creditorName: "Onni Mäkinen",
                remittanceInformation: ["Onni Mäkinen-DBIT-8.19-dkx1z"]
            ),
            BankTransactionDTO(
                entryReference: "eo28j",
                amount: Decimal(string: "4.49")!,
                currency: "EUR",
                creditDebitIndicator: .credit,
                bookingDate: date(0),
                valueDate: date(-3),
                debtorName: "Onni Hämäläinen",
                remittanceInformation: ["Onni Hämäläinen-CRDT-4.49-eo28j"]
            ),
            BankTransactionDTO(
                entryReference: "q7m2a",
                amount: Decimal(string: "42.00")!,
                currency: "EUR",
                creditDebitIndicator: .debit,
                bookingDate: date(-2),
                creditorName: "Carrefour",
                remittanceInformation: ["CB CARREFOUR"]
            ),
            BankTransactionDTO(
                entryReference: "s1p9k",
                amount: Decimal(string: "1200.00")!,
                currency: "EUR",
                creditDebitIndicator: .credit,
                bookingDate: date(-12),
                debtorName: "ACME SAS",
                remittanceInformation: ["SALAIRE"]
            ),
        ]
    }

    // Jour d'un échantillon : « aujourd'hui + décalage », borné entre le 1er du mois de `now` et
    // aujourd'hui. Les décalages sont négatifs ou nuls ; un décalage positif serait ramené à aujourd'hui.
    // Pendant les douze premiers jours du mois, « aujourd'hui moins N jours » tombe dans le mois
    // précédent et l'échantillon disparaîtrait des vues mensuelles. On replie alors vers le DÉBUT du
    // mois, jamais vers l'avant : l'ancien repli (aujourd'hui plus N jours) datait le salaire dans le
    // futur, donc en tête du tri et hors des vues mensuelles (l'app masque les opérations futures).
    // Replier vers le 1er garde chaque date dans le mois et jamais après `now`, et conserve l'ordre
    // relatif : plus le décalage est négatif, plus la date est ancienne ou égale. Seule la distinction
    // des jours se perd quand moins de jours se sont écoulés que de décalages distincts.
    // Les calculs partent de midi dans le fuseau du calendrier : dayString formate en UTC, et un
    // instant proche de minuit local glisserait sinon sur la veille, voire sur le mois précédent.
    static func day(offset: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now)) ?? now
        let daysSinceMonthStart = calendar.component(.day, from: noon) - 1
        let bounded = min(max(offset, -daysSinceMonthStart), 0)
        let resolved = calendar.date(byAdding: .day, value: bounded, to: noon) ?? noon
        return BankGatewayDateParser.parseDay(BankGatewayJSON.dayString(from: resolved))!
    }

    private func throwIfFailing() throws {
        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }
    }
}
