import SwiftUI

enum PrivacyShieldPolicy {
    // The app switcher snapshot is taken while the scene is inactive; automation runs keep the UI inspectable.
    static func shouldShow(scenePhase: ScenePhase, automation: AppAutomationConfiguration) -> Bool {
        scenePhase != .active && automation.showsPrivacyShield
    }
}

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
                Text("Pécule")
                    .font(AppTypography.cardValue)
                    .foregroundStyle(AppColors.primaryText)
            }
        }
        .accessibilityIdentifier("privacy-shield")
    }
}
