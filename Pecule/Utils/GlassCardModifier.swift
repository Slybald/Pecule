import SwiftUI

// Tonal surfaces, no glass, no shadow. Level 2 (card) is a flat tone; level 3 (elevated) adds a hairline.
enum AppSurfaceLevel {
    case card
    case elevated
}

struct AppSurfaceModifier: ViewModifier {
    let level: AppSurfaceLevel
    let padding: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(level == .card ? AppColors.surface : AppColors.surfaceElevated, in: shape)
            .overlay {
                if level == .elevated {
                    shape.strokeBorder(AppColors.separator, lineWidth: 1)
                }
            }
    }
}

extension View {
    func appSurface(_ level: AppSurfaceLevel = .card, padding: CGFloat = AppSpacing.lg, cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppSurfaceModifier(level: level, padding: padding, cornerRadius: cornerRadius))
    }

    // Legacy name kept during the migration: a "glass card" is now a flat card.
    func glassCard(padding: CGFloat = AppSpacing.lg) -> some View {
        modifier(AppSurfaceModifier(level: .card, padding: padding, cornerRadius: AppRadius.card))
    }
}
