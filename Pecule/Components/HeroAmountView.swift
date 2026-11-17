import SwiftUI

// The one serif number of the app: reste à vivre, total balance. Cents shrink under 1 000 €; a hairline
// underline (not a fill) marks a negative state, and the caption is expected to change with it.
struct HeroAmountView: View {
    let amount: Decimal
    let caption: String
    var currencyCode: String = "EUR"
    var isAlert: Bool = false
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = AppTypography.heroBaseSize
    @Environment(\.locale) private var locale

    private var isNegative: Bool { isAlert || amount < .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            amountLine
                .overlay(alignment: .bottom) {
                    if isNegative {
                        Rectangle()
                            .fill(AppColors.negative)
                            .frame(height: 1)
                            .offset(y: 2)
                    }
                }
            Text(caption)
                .font(AppTypography.cardCaption)
                .foregroundStyle(isNegative ? AppColors.negative : AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(spokenAmount)
    }

    private var amountLine: some View {
        let parts = Formatters.amountParts(for: amount, currencyCode: currencyCode)
        let showCents = abs(amount) < 1000
        let heroSize = min(size, 56)
        let color = isNegative ? AppColors.negative : AppColors.textPrimary
        return HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text((amount < .zero ? "−" : "") + parts.integer)
                .font(AppTypography.heroAmount(size: heroSize))
                .foregroundStyle(color)
                .appNumericTransition()
            if showCents, let fraction = parts.fraction {
                Text(fraction)
                    .font(AppTypography.heroAmount(size: heroSize * 0.6))
                    .foregroundStyle(isNegative ? AppColors.negative : AppColors.textTertiary)
                    .appNumericTransition()
            }
            Text(parts.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.leading, AppSpacing.xxs)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var spokenAmount: String {
        let magnitude = Formatters.currencyString(for: abs(amount), currencyCode: currencyCode)
        return amount < .zero ? AppLocalizer.format("amount.voice.negative %@", locale: locale, magnitude) : magnitude
    }
}

#Preview {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
        HeroAmountView(amount: 812.4, caption: "Reste à vivre jusqu'au 30 sept.")
        HeroAmountView(amount: 1834, caption: "Solde des comptes")
        HeroAmountView(amount: -120.5, caption: "Dépassement prévu le 22 sept.")
    }
    .padding(AppSpacing.lg)
    .appSurface()
    .padding(AppSpacing.lg)
    .background(AppColors.canvas)
}
