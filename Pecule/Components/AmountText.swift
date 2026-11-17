import SwiftUI

// Money direction is decided by the caller, never by a transaction type name.
enum MoneyDirection {
    case income
    case expense
    case neutral
}

// One label for every amount: sign, weight and colour change together, digits stay tabular.
struct AmountText: View {
    enum Style {
        case row
        case card
        case meta
    }

    let amount: Decimal
    var direction: MoneyDirection = .neutral
    var currencyCode: String = "EUR"
    var style: Style = .row
    // Overspent, below zero, failed: the only cases where an amount turns red.
    var isAlert: Bool = false
    @Environment(\.locale) private var locale

    var body: some View {
        Text(displayText)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .appNumericTransition()
            .accessibilityLabel(spokenText)
    }

    private var magnitudeText: String {
        Formatters.currencyString(for: abs(amount), currencyCode: currencyCode)
    }

    private var displayText: String {
        switch direction {
        case .income: "+" + magnitudeText
        case .expense: "−" + magnitudeText
        case .neutral: amount < .zero ? "−" + magnitudeText : magnitudeText
        }
    }

    private var spokenText: String {
        switch direction {
        case .income: AppLocalizer.format("accounts.transaction.voice.credit %@", locale: locale, magnitudeText)
        case .expense: AppLocalizer.format("accounts.transaction.voice.debit %@", locale: locale, magnitudeText)
        case .neutral: amount < .zero ? AppLocalizer.format("amount.voice.negative %@", locale: locale, magnitudeText) : magnitudeText
        }
    }

    private var color: Color {
        if isAlert || (direction == .neutral && amount < .zero) {
            return AppColors.negative
        }
        return direction == .income ? AppColors.positive : AppColors.textPrimary
    }

    private var font: Font {
        switch style {
        case .row: direction == .income ? AppTypography.rowAmountEmphasis : AppTypography.rowAmount
        case .card: AppTypography.cardValue
        case .meta: AppTypography.meta.monospacedDigit()
        }
    }
}

#Preview {
    VStack(alignment: .trailing, spacing: AppSpacing.sm) {
        AmountText(amount: 2450, direction: .income)
        AmountText(amount: TestPreviewValues.expense, direction: .expense)
        AmountText(amount: 1234.5)
        AmountText(amount: -80, isAlert: true)
        AmountText(amount: 812.4, style: .card)
    }
    .padding(AppSpacing.lg)
    .appSurface()
    .padding(AppSpacing.lg)
    .background(AppColors.canvas)
}

private enum TestPreviewValues {
    static let expense: Decimal = 38.9
}
