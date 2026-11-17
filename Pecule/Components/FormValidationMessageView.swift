import SwiftUI

struct FormValidationMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(AppColors.error)
                .accessibilityHidden(true)

            Text(message)
                .font(AppTypography.rowMeta)
                .foregroundStyle(AppColors.error)

            Spacer(minLength: 0)
        }
        .padding(.top, AppSpacing.xxs)
    }
}

#Preview {
    Form {
        Section("Validation") {
            FormValidationMessageView(message: "Enter an amount greater than 0.")
        }
    }
}
