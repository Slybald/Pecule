import SwiftUI

// Affiché à la place de l'app quand la base sur disque ne s'ouvre pas : un message qui dit ce qui est
// arrivé aux données, l'identifiant de l'erreur à citer, et « Réessayer ». Aucun identifiant
// d'accessibilité sur un conteneur, il écraserait celui du bouton : seulement sur les éléments feuilles.
struct StoreRecoveryView: View {
    let messageKey: String
    let identifier: String
    let retry: () -> Void
    @Environment(\.locale) private var locale

    init(failure: StoreOpenError, retry: @escaping () -> Void) {
        self.init(messageKey: failure.messageKey, identifier: failure.identifier, retry: retry)
    }

    init(messageKey: String, identifier: String, retry: @escaping () -> Void) {
        self.messageKey = messageKey
        self.identifier = identifier
        self.retry = retry
    }

    var body: some View {
        // Le défilement garde le bouton atteignable aux plus grandes tailles de texte ; la hauteur
        // minimale recentre le contenu quand il tient sur l'écran.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(AppColors.warning)
                        .accessibilityHidden(true)
                    Text(AppLocalizer.string("storage.recovery.title", locale: locale))
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColors.primaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("store-recovery-title")
                    Text(AppLocalizer.string(messageKey, locale: locale))
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("store-recovery-message")
                    Text(AppLocalizer.format("storage.recovery.errorID %@", locale: locale, identifier))
                        .font(AppTypography.meta.monospaced())
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("store-recovery-error-id")
                    Button(AppLocalizer.string("storage.recovery.retry", locale: locale), action: retry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("store-recovery-retry")
                }
                .frame(maxWidth: 420)
                .padding(AppSpacing.xl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(AppColors.overviewBackground.ignoresSafeArea())
    }
}
