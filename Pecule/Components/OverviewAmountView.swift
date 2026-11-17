import SwiftUI

/// A single leading amount, shared by the main overview screens.
struct OverviewAmountView: View {
    let value: String
    var tint: Color = AppColors.primaryText
    @ScaledMetric(relativeTo: .largeTitle) private var size = 52.0

    var body: some View {
        Text(value)
            .font(.system(size: size, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .privacySensitive()
    }
}
