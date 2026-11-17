import XCTest
@testable import Pecule

final class CashflowForecastServiceTests: XCTestCase {
    private let calendar = TestFixtures.utcCalendar()
    private let today = TestFixtures.referenceDate // 2026-09-14
    private let salaryID = UUID()
    private let aidID = UUID()

    private func observed(_ year: Int, _ month: Int, variable: Decimal, complete: Bool = true) throws -> ObservedMonth {
        ObservedMonth(
            month: try XCTUnwrap(calendar.dateInterval(of: .month, for: TestFixtures.date(year, month, 1))),
            income: 1500,
            fixedCharges: 600,
            variableExpenses: variable,
            byCategory: [:],
            dailyVariableMedian: 0,
            transactionCount: 5,
            isComplete: complete
        )
    }

    private func charge(_ name: String, _ amount: String, _ year: Int, _ month: Int, _ day: Int) -> CashflowForecast.UpcomingCharge {
        CashflowForecast.UpcomingCharge(id: UUID(), name: name, amount: TestFixtures.decimal(amount), date: TestFixtures.date(year, month, day))
    }

    private func inputs(openingBalance: Decimal? = 1000, observed: [ObservedMonth]) -> CashflowForecastInputs {
        CashflowForecastInputs(
            openingBalance: openingBalance,
            plannedIncome: [.init(sourceID: salaryID, amount: 1500), .init(sourceID: aidID, amount: 100)],
            settledIncomeSourceIDs: [salaryID],
            upcomingCharges: [
                charge("Netflix", "15.99", 2026, 9, 20),
                charge("Salle de sport", "30", 2026, 9, 10),
                charge("Assurance", "120", 2026, 10, 2),
            ],
            observedMonths: observed
        )
    }

    func testForecastCombinesBalanceRemainingIncomeChargesAndMedianPace() throws {
        let observed = [
            try observed(2026, 6, variable: 300),   // 10 / day
            try observed(2026, 7, variable: 310),   // 10 / day
            try observed(2026, 8, variable: 620),   // 20 / day, the exceptional month the median ignores
            try observed(2026, 9, variable: 40, complete: false),
        ]

        let forecast = try XCTUnwrap(CashflowForecastService(calendar: calendar).forecast(on: today, inputs: inputs(observed: observed)))

        XCTAssertEqual(forecast.remainingDays, 17)
        XCTAssertEqual(forecast.remainingIncome, 100, "the settled salary is out, the aid is still expected")
        XCTAssertEqual(forecast.upcomingCharges.map(\.name), ["Netflix"], "past and next-month charges are out")
        XCTAssertEqual(forecast.remainingFixedCharges, TestFixtures.decimal("15.99"))
        XCTAssertEqual(forecast.dailyVariableRate, 10)
        XCTAssertEqual(forecast.projectedVariable, 170)
        XCTAssertEqual(forecast.expectedClosingBalance, TestFixtures.decimal("914.01"))
        XCTAssertEqual(forecast.bestClosingBalance, TestFixtures.decimal("999.01"))
        XCTAssertEqual(forecast.worstClosingBalance, TestFixtures.decimal("829.01"))
        XCTAssertEqual(forecast.completeMonthsUsed, 3)
        XCTAssertEqual(forecast.confidence, .high)
        XCTAssertTrue(forecast.hasDistinctClosingRange)
    }

    func testConfidenceDropsWithoutHistoryOrBalance() throws {
        let service = CashflowForecastService(calendar: calendar)

        let oneMonth = try XCTUnwrap(service.forecast(on: today, inputs: inputs(observed: [try observed(2026, 8, variable: 310)])))
        XCTAssertEqual(oneMonth.confidence, .medium)
        XCTAssertEqual(oneMonth.dailyVariableRate, 10)
        XCTAssertEqual(oneMonth.closingBalanceAvailability, .available)

        let noHistory = try XCTUnwrap(service.forecast(on: today, inputs: inputs(observed: [])))
        XCTAssertEqual(noHistory.confidence, .low)
        XCTAssertEqual(noHistory.projectedVariable, 0)
        // M004 : sans mois complet, 1 084,01 € « prévus » ignoraient toute dépense variable. Aucune prévision n'est rendue.
        XCTAssertNil(noHistory.expectedClosingBalance)
        XCTAssertFalse(noHistory.hasDistinctClosingRange)

        let noBalance = try XCTUnwrap(service.forecast(on: today, inputs: inputs(openingBalance: nil, observed: [try observed(2026, 8, variable: 310)])))
        XCTAssertEqual(noBalance.confidence, .low)
        XCTAssertNil(noBalance.expectedClosingBalance)
        XCTAssertNil(noBalance.worstClosingBalance)
        XCTAssertFalse(noBalance.hasDistinctClosingRange)
        XCTAssertEqual(noBalance.closingBalanceAvailability, .unknownBalance)
    }

    // M004 : AppState passait `observedMonths: []`, donc un rythme variable de zéro, et le « solde prévu fin de mois »
    // (carte de l'accueil, écran Trésorerie, PDF, conseiller IA) ignorait toutes les courses. Sans mois complet,
    // le solde prévu, le meilleur et le pire cas sont absents ; ce qui est connu reste connu.
    func testMonthEndBalanceIsWithheldWithoutACompleteMonthButKnownAmountsRemain() throws {
        let service = CashflowForecastService(calendar: calendar)
        for months in [[], [try observed(2026, 8, variable: 310, complete: false)]] {
            let forecast = try XCTUnwrap(service.forecast(on: today, inputs: inputs(observed: months)))
            XCTAssertEqual(forecast.closingBalanceAvailability, .insufficientHistory)
            XCTAssertNil(forecast.expectedClosingBalance)
            XCTAssertNil(forecast.bestClosingBalance)
            XCTAssertNil(forecast.worstClosingBalance)
            XCTAssertFalse(forecast.hasDistinctClosingRange)
            XCTAssertEqual(forecast.openingBalance, 1000)
            XCTAssertEqual(forecast.remainingIncome, 100)
            XCTAssertEqual(forecast.remainingFixedCharges, TestFixtures.decimal("15.99"), "les prélèvements connus ne dépendent pas de l'historique")
            XCTAssertEqual(forecast.upcomingCharges.map(\.name), ["Netflix"])
        }
    }

    func testObservedVariableSpendingEntersTheMonthEndBalanceOnceCompleteMonthsExist() throws {
        let service = CashflowForecastService(calendar: calendar)
        let months = [try observed(2026, 6, variable: 300), try observed(2026, 7, variable: 310), try observed(2026, 8, variable: 310)]
        let forecast = try XCTUnwrap(service.forecast(on: today, inputs: inputs(observed: months)))
        XCTAssertEqual(forecast.closingBalanceAvailability, .available)
        XCTAssertEqual(forecast.dailyVariableRate, 10)
        XCTAssertEqual(forecast.projectedVariable, 170, "10 € par jour pendant 17 jours")
        // 1 000 + 100 de revenu attendu − 15,99 de prélèvement − 170 de dépenses variables observées.
        XCTAssertEqual(forecast.expectedClosingBalance, TestFixtures.decimal("914.01"))
        XCTAssertEqual(forecast.bestClosingBalance, TestFixtures.decimal("999.01"))
        XCTAssertEqual(forecast.worstClosingBalance, TestFixtures.decimal("829.01"))
    }

    func testTheWithheldForecastSentencesExistInBothLanguages() {
        let french = Locale(identifier: "fr_FR"), english = Locale(identifier: "en_GB")
        for key in ["cashflow.forecastUnavailable", "treasury.unresolvedMore %lld"] {
            XCTAssertNotEqual(AppLocalizer.string(key, locale: french), key)
            XCTAssertNotEqual(AppLocalizer.string(key, locale: english), key)
            XCTAssertNotEqual(AppLocalizer.string(key, locale: french), AppLocalizer.string(key, locale: english))
        }
        XCTAssertTrue(AppLocalizer.format("treasury.unresolvedMore %lld", locale: french, 3).contains("3"))
        XCTAssertTrue(AppLocalizer.format("treasury.unresolvedMore %lld", locale: english, 3).contains("3"))
    }
}
