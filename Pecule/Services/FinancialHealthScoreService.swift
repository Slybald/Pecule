import Foundation

// One explainable A–E grade built from four ratios, each naming the amount to move to reach its target.
struct FinancialHealthComponent: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case savings
        case fixedCharges
        case margin
        case cushion

        var weight: Double {
            switch self {
            case .savings: 0.30
            case .fixedCharges: 0.25
            case .margin: 0.20
            case .cushion: 0.25
            }
        }
    }

    let kind: Kind
    // 0...100, nil when the inputs cannot measure it (no income, no account).
    let score: Int?
    // The underlying ratio: a rate for savings/fixed/margin, a number of months for the cushion.
    let measured: Double?
    // Money to move (save, cut, keep, set aside) to hit the target; nil when already there or unknown.
    let leverAmount: Decimal?

    var id: Kind { kind }
    var weight: Double { kind.weight }
    var isMeasured: Bool { score != nil }
}

struct FinancialHealthScore: Equatable {
    enum Grade: String, Equatable {
        case a = "A"
        case b = "B"
        case c = "C"
        case d = "D"
        case e = "E"

        init(total: Int) {
            switch total {
            case 80...: self = .a
            case 65 ..< 80: self = .b
            case 50 ..< 65: self = .c
            case 35 ..< 50: self = .d
            default: self = .e
            }
        }
    }

    let components: [FinancialHealthComponent]

    // Weighted mean of the measured components; weights are renormalised so an unmeasured ratio is not a penalty.
    var total: Int? {
        let measured = components.filter(\.isMeasured)
        let weightSum = measured.map(\.weight).reduce(0, +)
        guard weightSum > 0 else {
            return nil
        }
        let weighted = measured.reduce(0.0) { $0 + Double($1.score ?? 0) * $1.weight }
        return Int((weighted / weightSum).rounded())
    }

    var grade: Grade? {
        total.map(Grade.init(total:))
    }

    var weakestComponent: FinancialHealthComponent? {
        components.filter(\.isMeasured).min { ($0.score ?? 0, $0.kind.rawValue) < ($1.score ?? 0, $1.kind.rawValue) }
    }
}

struct FinancialHealthInputs: Equatable {
    let monthlyIncome: Decimal
    let fixedCharges: Decimal
    let remainingToLive: Decimal
    let savingsRate: Double?
    let totalBalance: Decimal?
    let averageMonthlyExpenses: Decimal
}

struct FinancialHealthScoreService {
    static let savingsTarget = 0.20
    static let fixedChargesTarget = 0.35
    static let fixedChargesFloor = 0.70
    static let marginTarget = 0.15
    static let cushionTargetMonths = 3.0

    func score(_ inputs: FinancialHealthInputs) -> FinancialHealthScore {
        FinancialHealthScore(components: [
            savings(inputs),
            fixedCharges(inputs),
            margin(inputs),
            cushion(inputs),
        ])
    }

    private func savings(_ inputs: FinancialHealthInputs) -> FinancialHealthComponent {
        guard inputs.monthlyIncome > .zero, let rate = inputs.savingsRate else {
            return FinancialHealthComponent(kind: .savings, score: nil, measured: nil, leverAmount: nil)
        }
        let score = linear(rate, zeroAt: 0, fullAt: Self.savingsTarget)
        let lever = rate < Self.savingsTarget ? (inputs.monthlyIncome * Decimal(Self.savingsTarget - rate)).currencyRounded : nil
        return FinancialHealthComponent(kind: .savings, score: score, measured: rate, leverAmount: lever)
    }

    private func fixedCharges(_ inputs: FinancialHealthInputs) -> FinancialHealthComponent {
        guard inputs.monthlyIncome > .zero else {
            return FinancialHealthComponent(kind: .fixedCharges, score: nil, measured: nil, leverAmount: nil)
        }
        let ratio = double(inputs.fixedCharges) / double(inputs.monthlyIncome)
        let score = linear(ratio, zeroAt: Self.fixedChargesFloor, fullAt: Self.fixedChargesTarget)
        let lever = ratio > Self.fixedChargesTarget ? (inputs.monthlyIncome * Decimal(ratio - Self.fixedChargesTarget)).currencyRounded : nil
        return FinancialHealthComponent(kind: .fixedCharges, score: score, measured: ratio, leverAmount: lever)
    }

    private func margin(_ inputs: FinancialHealthInputs) -> FinancialHealthComponent {
        guard inputs.monthlyIncome > .zero else {
            return FinancialHealthComponent(kind: .margin, score: nil, measured: nil, leverAmount: nil)
        }
        let ratio = double(inputs.remainingToLive) / double(inputs.monthlyIncome)
        let score = linear(ratio, zeroAt: 0, fullAt: Self.marginTarget)
        let lever = ratio < Self.marginTarget ? (inputs.monthlyIncome * Decimal(Self.marginTarget - ratio)).currencyRounded : nil
        return FinancialHealthComponent(kind: .margin, score: score, measured: ratio, leverAmount: lever)
    }

    private func cushion(_ inputs: FinancialHealthInputs) -> FinancialHealthComponent {
        guard let balance = inputs.totalBalance, inputs.averageMonthlyExpenses > .zero else {
            return FinancialHealthComponent(kind: .cushion, score: nil, measured: nil, leverAmount: nil)
        }
        let months = double(balance) / double(inputs.averageMonthlyExpenses)
        let score = linear(months, zeroAt: 0, fullAt: Self.cushionTargetMonths)
        let lever = months < Self.cushionTargetMonths ? (inputs.averageMonthlyExpenses * Decimal(Self.cushionTargetMonths - months)).currencyRounded : nil
        return FinancialHealthComponent(kind: .cushion, score: score, measured: months, leverAmount: lever)
    }

    // Straight line between the two anchors, clamped to 0...100; anchors may be in either order.
    private func linear(_ value: Double, zeroAt: Double, fullAt: Double) -> Int {
        let fraction = (value - zeroAt) / (fullAt - zeroAt)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

extension AppState {
    func financialHealthScore(on date: Date = Date(), calendar: Calendar = .current) -> FinancialHealthScore {
        let summary = monthlyFinancialSummary(for: date, calendar: calendar)
        let metrics = DecisionMetricsService().metrics(from: summary, on: date, calendar: calendar)
        let completeMonths = observedMonths.filter(\.isComplete).suffix(3)
        let observedRates = completeMonths.compactMap(\.savingsRate).sorted()
        let savingsRate = observedRates.isEmpty
            ? metrics.savingsRate
            : observedRates[observedRates.count / 2]
        let averageExpenses = completeMonths.isEmpty
            ? summary.totalExpenses
            : (completeMonths.map(\.totalExpenses).reduce(.zero, +) / Decimal(completeMonths.count)).currencyRounded

        return FinancialHealthScoreService().score(FinancialHealthInputs(
            monthlyIncome: summary.totalEstimatedIncome,
            fixedCharges: summary.fixedCharges,
            remainingToLive: summary.remainingToLive,
            savingsRate: savingsRate,
            totalBalance: totalExternalBalance(),
            averageMonthlyExpenses: averageExpenses
        ))
    }
}
