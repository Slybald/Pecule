import SwiftUI

// Tinted capsule: the tint at 14 % behind text in the tint itself; the text is never the only channel of meaning.
struct StatusPillView: View {
    let text: String
    let tint: Color
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: AppSpacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(AppTypography.badge)
            }
            Text(text)
                .font(AppTypography.badge)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

#Preview {
    VStack(spacing: AppSpacing.sm) {
        StatusPillView(text: "À jour", tint: AppColors.positive, systemImage: "checkmark")
        StatusPillView(text: "À reconnecter", tint: AppColors.warning, systemImage: "exclamationmark.triangle")
        StatusPillView(text: "Hors totaux", tint: AppColors.neutralPillText)
        StatusPillView(text: "Erreur", tint: AppColors.negative)
    }
    .padding(AppSpacing.lg)
    .appSurface()
    .padding(AppSpacing.lg)
    .background(AppColors.canvas)
}
