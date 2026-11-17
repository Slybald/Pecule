import SwiftUI

extension View {
    func appCardSurface(cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppSurfaceModifier(level: .card, padding: 0, cornerRadius: cornerRadius))
    }

    // Hairline drawn at one physical pixel so it never vanishes in dark mode.
    func appHairline(edge: Edge = .bottom, leadingInset: CGFloat = AppSpacing.lg) -> some View {
        modifier(HairlineModifier(edge: edge, leadingInset: leadingInset))
    }
}

private struct HairlineModifier: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let edge: Edge
    let leadingInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 1 / max(displayScale, 1))
                .padding(.leading, leadingInset)
        }
    }
}
