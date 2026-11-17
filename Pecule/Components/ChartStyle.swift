import Charts
import SwiftUI

// Shared chart rules: horizontal gridlines only, compact currency on the trailing axis, no legend boxes.
enum ChartStyle {
    static let gridLineCount = 4
    static let barCornerRadius: CGFloat = AppRadius.bar
    static let lineWidth: CGFloat = 2
    static let defaultHeight: CGFloat = 180
}

extension View {
    func appChartAxes() -> some View {
        self
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: ChartStyle.gridLineCount)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(AppColors.chartGrid)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Formatters.compactCurrencyString(for: Decimal(amount)))
                                .font(AppTypography.meta)
                                .foregroundStyle(AppColors.chartAxisText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(AppTypography.meta)
                        .foregroundStyle(AppColors.chartAxisText)
                }
            }
            .chartLegend(.hidden)
    }
}

// Keeps the plot frame at its final height so the layout never jumps when data arrives.
struct ChartEmptyStateView: View {
    let message: String
    var hint: String? = nil
    var height: CGFloat = ChartStyle.defaultHeight

    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(message)
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(AppColors.textSecondary)
            if let hint {
                Text(hint)
                    .font(AppTypography.meta)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: height)
        .background {
            VStack {
                ForEach(0 ..< ChartStyle.gridLineCount, id: \.self) { _ in
                    Rectangle().fill(AppColors.chartGrid).frame(height: 0.5)
                    Spacer()
                }
            }
        }
    }
}
