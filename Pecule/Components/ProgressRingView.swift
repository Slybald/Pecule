import SwiftUI

// 10 pt ring on a neutral track; tint follows the budget thresholds unless the caller fixes it. Never nested.
struct ProgressRingView<Label: View>: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    var tint: Color? = nil
    @ViewBuilder var label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColors.neutralPill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint ?? BudgetBarView.tint(for: progress), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : AppMotion.chart, value: progress)
            label()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Formatters.percentString(for: min(max(progress, 0), 1)))
    }
}

extension ProgressRingView where Label == EmptyView {
    init(progress: Double, lineWidth: CGFloat = 10, tint: Color? = nil) {
        self.init(progress: progress, lineWidth: lineWidth, tint: tint) { EmptyView() }
    }
}
