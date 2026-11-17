import Foundation

extension Decimal {
    func rounded(scale: Int = 2, mode: NSDecimalNumber.RoundingMode = .bankers) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }

    var currencyRounded: Decimal {
        rounded(scale: 2)
    }
}
