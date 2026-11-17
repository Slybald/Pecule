import SwiftUI

struct MonthSelectorView: View {
    let monthLabel: String
    let locale: Locale
    let identifierPrefix: String
    let onPreviousMonth: () -> Void
    let onCurrentMonth: () -> Void
    let onNextMonth: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                Button(action: onPreviousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(AppLocalizer.string("income.action.previousMonth", locale: locale))
                .accessibilityIdentifier("\(identifierPrefix)-previous-month-button")

                Spacer(minLength: 0)

                Text(monthLabel)
                    .font(AppTypography.screenSectionTitle)
                    .foregroundStyle(AppColors.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onNextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(AppLocalizer.string("income.action.nextMonth", locale: locale))
                .accessibilityIdentifier("\(identifierPrefix)-next-month-button")
            }

            Button(AppLocalizer.string("income.action.currentMonth", locale: locale), action: onCurrentMonth)
                .buttonStyle(.bordered)
                .tint(AppColors.accent)
                .accessibilityIdentifier("\(identifierPrefix)-current-month-button")
        }
        .padding(AppSpacing.lg)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix)-month-selector")
    }
}
