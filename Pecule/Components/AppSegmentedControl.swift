import SwiftUI

// Segmented control on the tokens: selection fill, accent text, one identifier per segment for tests and VoiceOver.
struct AppSegmentedControl<Segment: Hashable & Identifiable>: View {
    let segments: [Segment]
    @Binding var selection: Segment
    let title: (Segment) -> String
    let identifier: (Segment) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AppSpacing.xxs) {
            ForEach(segments) { segment in
                let isSelected = segment == selection
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.quick) {
                        selection = segment
                    }
                    AppHaptics.play(.selection)
                } label: {
                    Text(title(segment))
                        .font(AppTypography.rowSubtitle.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AppColors.accent : AppColors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, AppSpacing.sm)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: AppRadius.control - 2, style: .continuous)
                                    .fill(AppColors.selection)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier(segment))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(AppSpacing.xxs)
        .background(AppColors.canvasGrouped, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }
}
