import Foundation

// "Do I finish the month in the green?" answered from what is known today, without any network call.
struct CashflowForecast: Equatable {
    enum Confidence: Equatable {
        case low
        case medium
        case high
    }

    struct UpcomingCharge: Equatable, Identifiable {
        let id: UUID
        let name: String
        let amount: Decimal
        let date: Date
    }

    let month: DateInterval
    let openingBalance: Decimal?
    let remainingIncome: Decimal
    let upcomingCharges: [UpcomingCharge]
    let dailyVariableRate: Decimal
    let remainingDays: Int
    let completeMonthsUsed: Int

    var remainingFixedCharges: Decimal {
        upcomingCharges.map(\.amount).reduce(.zero, +).currencyRounded
    }

    var projectedVariable: Decimal {
        (dailyVariableRate * Decimal(remainingDays)).currencyRounded
    }

    // Why the month-end balance may be missing, so that every screen words it the same way.
    enum ClosingBalanceAvailability: Equatable {
        case available
        // No balance to start from.
        case unknownBalance
        // No complete month to set the pace of the variable spending: a balance computed anyway would silently assume none.
        case insufficientHistory
    }

    var closingBalanceAvailability: ClosingBalanceAvailability {
        guard openingBalance != nil else { return .unknownBalance }
        return completeMonthsUsed > 0 ? .available : .insufficientHistory
    }

    // Opening balance plus what is still to come, minus what is still to go out.
    var expectedClosingBalance: Decimal? {
        closingBalance(variableSpending: projectedVariable)
    }

    // Variable spending at half the usual pace.
    var bestClosingBalance: Decimal? {
        closingBalance(variableSpending: (projectedVariable / 2).currencyRounded)
    }

    // Variable spending at one and a half times the usual pace.
    var worstClosingBalance: Decimal? {
        closingBalance(variableSpending: (projectedVariable * Decimal(1.5)).currencyRounded)
    }

    // Nil whenever the variable spending cannot be paced: none of the three figures is then shown as a forecast.
    private func closingBalance(variableSpending: Decimal) -> Decimal? {
        guard closingBalanceAvailability == .available, let openingBalance else { return nil }
        return (openingBalance + remainingIncome - remainingFixedCharges - variableSpending).currencyRounded
    }

    var hasDistinctClosingRange: Bool {
        guard let worst = worstClosingBalance, let best = bestClosingBalance else { return false }
        return worst != best
    }

    var confidence: Confidence {
        guard openingBalance != nil else {
            return .low
        }
        switch completeMonthsUsed {
        case 3...: return .high
        case 1 ... 2: return .medium
        default: return .low
        }
    }
}

struct CashflowForecastInputs {
    struct PlannedIncome: Equatable {
        let sourceID: UUID
        let amount: Decimal
    }

    let openingBalance: Decimal?
    let plannedIncome: [PlannedIncome]
    // Income sources that already received a bank credit this month.
    let settledIncomeSourceIDs: Set<UUID>
    let upcomingCharges: [CashflowForecast.UpcomingCharge]
    let observedMonths: [ObservedMonth]
}

struct CashflowForecastService {
    static let baselineMonths = 3

    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func forecast(on date: Date, inputs: CashflowForecastInputs) -> CashflowForecast? {
        guard let month = calendar.dateInterval(of: .month, for: date) else {
            return nil
        }
        let dayStart = calendar.startOfDay(for: date)
        let remainingDays = max(calendar.dateComponents([.day], from: dayStart, to: month.end).day ?? 1, 1)
        let remainingIncome = inputs.plannedIncome
            .filter { !inputs.settledIncomeSourceIDs.contains($0.sourceID) }
            .map(\.amount)
            .reduce(.zero, +)
            .currencyRounded
        let charges = inputs.upcomingCharges
            .filter { $0.date >= dayStart && $0.date < month.end }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
        let baseline = inputs.observedMonths.filter(\.isComplete).suffix(Self.baselineMonths)

        return CashflowForecast(
            month: month,
            openingBalance: inputs.openingBalance,
            remainingIncome: remainingIncome,
            upcomingCharges: charges,
            dailyVariableRate: dailyVariableRate(from: Array(baseline)),
            remainingDays: remainingDays,
            completeMonthsUsed: baseline.count
        )
    }

    // Median of the last complete months' daily averages: robust to one exceptional month, unlike a mean.
    func dailyVariableRate(from months: [ObservedMonth]) -> Decimal {
        let rates: [Decimal] = months.compactMap { month in
            let days = calendar.dateComponents([.day], from: month.month.start, to: month.month.end).day ?? 30
            guard days > 0 else {
                return nil
            }
            return month.variableExpenses / Decimal(days)
        }
        return MonthlyObservationService(calendar: calendar).median(rates)
    }
}

extension AppState {
    // `baselineMonths` replaces the certified history (tests, previews); in the app it is always nil.
    func cashflowForecast(on date: Date = Date(), calendar: Calendar = .current, baselineMonths: [ObservedMonth]? = nil) -> CashflowForecast? {
        guard let month = calendar.dateInterval(of: .month, for: date) else {
            return nil
        }
        let includedAccounts = externalAccounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }
        let included = Set(includedAccounts.map(\.id))
        // The observed months pace the variable spending only where the habitual reading of the cash-flow calendar
        // would be available: same source, `habitualDailyVariable`. Until the coverage is certified, none is.
        let hasCertifiedHistory = !includedAccounts.isEmpty && includedAccounts.allSatisfy { habitualDailyVariable(for: $0) != nil }
        let plannedIncome = planningEvents(on: date, until: month.end, calendar: calendar).compactMap { event -> CashflowForecastInputs.PlannedIncome? in
            guard event.confirmed, event.amount > 0, let due = event.date,
                  due >= calendar.startOfDay(for: date), event.accountID.map(included.contains) ?? true else { return nil }
            return .init(sourceID: event.commitmentID, amount: event.amount)
        }

        return CashflowForecastService(calendar: calendar).forecast(
            on: date,
            inputs: CashflowForecastInputs(
                openingBalance: totalExternalBalance(),
                plannedIncome: plannedIncome,
                settledIncomeSourceIDs: [],
                upcomingCharges: confirmedUpcomingCharges(on: date, calendar: calendar),
                observedMonths: baselineMonths ?? (hasCertifiedHistory ? observedMonths : [])
            )
        )
    }
}
