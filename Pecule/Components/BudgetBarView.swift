import SwiftUI

// 6 pt track: accent under 80 %, warning to 100 %, negative beyond with the overflow hatched so it survives greyscale.
struct BudgetBarView: View {
    let ratio: Double
    var height: CGFloat = 6

    static func tint(for ratio: Double) -> Color {
        switch ratio {
        case ..<0.8: AppColors.accent
        case ..<1.0: AppColors.warning
        default: AppColors.negative
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(ratio, 0), 1)
            let shape = RoundedRectangle(cornerRadius: AppRadius.progress, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(AppColors.neutralPill)
                shape.fill(Self.tint(for: ratio))
                    .frame(width: width * clamped)
                if ratio > 1 {
                    let overflow = min(ratio - 1, 1)
                    HatchPattern(color: AppColors.negative)
                        .clipShape(shape)
                        .frame(width: width * overflow)
                        .overlay(shape.stroke(AppColors.negative, lineWidth: 1))
                }
            }
        }
        .frame(height: height)
        .appAnimation(AppMotion.chart, value: ratio)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Formatters.percentString(for: ratio))
    }
}

// Diagonal hatching for overspend segments.
struct HatchPattern: View {
    let color: Color
    var spacing: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .background(color.opacity(0.18))
    }
}
