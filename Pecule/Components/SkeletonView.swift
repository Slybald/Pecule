import SwiftUI

// Placeholder bars shown while a value is being fetched. The shimmer stops under Reduce Motion.
struct SkeletonView: View {
    var lines: Int = 2
    var lineHeight: CGFloat = 12
    var lastLineWidth: CGFloat? = 160
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        bars
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, AppColors.primaryText.opacity(0.14), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width)
                        .offset(x: shimmerPhase * proxy.size.width)
                        .onAppear {
                            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                                shimmerPhase = 1
                            }
                        }
                    }
                    .mask(bars)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppLocalizer.string("common.loading", locale: locale))
            .accessibilityIdentifier("skeleton-placeholder")
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(0..<max(lines, 1), id: \.self) { index in
                RoundedRectangle(cornerRadius: lineHeight / 2, style: .continuous)
                    .fill(AppColors.separator)
                    .frame(maxWidth: index == lines - 1 ? lastLineWidth : .infinity, alignment: .leading)
                    .frame(height: lineHeight)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: AppSpacing.lg) {
        SkeletonView(lines: 3)
        SkeletonView(lines: 1, lineHeight: 28, lastLineWidth: 120)
    }
    .padding(AppSpacing.lg)
    .glassCard()
    .padding(AppSpacing.lg)
    .background(AppColors.groupedBackground)
}
