import SwiftUI

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    let buttonTitle: String?
    let buttonIdentifier: String?
    let identifier: String?
    let action: (() -> Void)?
    let tint: Color

    init(
        title: String,
        message: String,
        systemImage: String,
        buttonTitle: String? = nil,
        buttonIdentifier: String? = nil,
        action: (() -> Void)? = nil,
        tint: Color = AppColors.accent,
        identifier: String? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.buttonTitle = buttonTitle
        self.buttonIdentifier = buttonIdentifier
        self.identifier = identifier
        self.action = action
        self.tint = tint
    }

    var body: some View {
        VStack {
            Spacer(minLength: AppSpacing.xxl)

            VStack(spacing: AppSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                        .frame(width: 76, height: 76)

                    Image(systemName: systemImage)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(tint)
                }

                VStack(spacing: AppSpacing.sm) {
                    Text(title)
                        .font(AppTypography.screenSectionTitle)
                        .foregroundStyle(AppColors.primaryText)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Posé ici et non sur la vue entière : un identifiant appliqué au conteneur
                // écrase celui du bouton d'action, qui devient inadressable.
                .accessibilityIdentifier(identifier ?? "")

                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .accessibilityIdentifier(buttonIdentifier ?? "empty-state-action")
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
            }
            .frame(maxWidth: 420)
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.lg)
        // Fond commun aux écrans refaits : une carte blanche flottante détonnait avec eux.
        .background(AppColors.overviewBackground.ignoresSafeArea())
    }
}

#Preview("With Action") {
    EmptyStateView(
        title: "No subscriptions yet",
        message: "Track your recurring expenses to understand your monthly commitments.",
        systemImage: "repeat.circle.fill",
        buttonTitle: "Add Subscription",
        action: {},
        tint: AppColors.subscriptionTint
    )
}

#Preview("Without Action") {
    EmptyStateView(
        title: "Your dashboard is empty",
        message: "Add subscriptions, purchases, or goals to see useful insights.",
        systemImage: "square.grid.2x2.fill"
    )
}
