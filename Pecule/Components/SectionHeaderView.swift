import SwiftUI

// Section title with an optional trailing action, the only way sections are titled outside system lists.
struct SectionHeaderView: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AppSpacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AppTypography.sectionAction)
                    .foregroundStyle(AppColors.accent)
            }
        }
        .padding(.top, AppSpacing.sm)
    }
}
