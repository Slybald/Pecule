import Foundation
import FoundationModels

@Generable(description: "A short, actionable financial insight based on the user's data")
struct AIInsight: Identifiable, Hashable {
    let id = UUID()

    @Guide(description: "A catchy, short title (max 4 words)")
    var title: String

    @Guide(description: "A friendly, personalized 2-sentence advice based on their goals and spending")
    var advice: String

    @Guide(description: "A single emoji that represents the advice")
    var emoji: String
}

enum AIAdvisorUnavailableReason: Equatable {
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case generic
    case unknown
    case failure(String)

    var localizedDescription: String {
        switch self {
        case .deviceNotEligible:
            return AppLocalizer.string("aiAdvisor.unavailable.deviceNotEligible")
        case .notEnabled:
            return AppLocalizer.string("aiAdvisor.unavailable.notEnabled")
        case .modelNotReady:
            return AppLocalizer.string("aiAdvisor.unavailable.modelNotReady")
        case .generic:
            return AppLocalizer.string("aiAdvisor.unavailable.generic")
        case .unknown:
            return AppLocalizer.string("aiAdvisor.unavailable.unknown")
        case let .failure(message):
            return AppLocalizer.format("aiAdvisor.unavailable.failure %@", message)
        }
    }
}

enum AIAdvisorState: Equatable {
    case idle
    case loading
    case available(AIInsight)
    case unavailable(AIAdvisorUnavailableReason)
}

@MainActor
final class AIAdvisorService: ObservableObject {
    @Published var state: AIAdvisorState = .idle
    private var languageDidChangeTask: Task<Void, Never>?

    init() {
        languageDidChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: LocalizationManager.didChangeLanguageNotification
            ) {
                await MainActor.run {
                    self?.state = .idle
                }
            }
        }
    }

    deinit {
        languageDidChangeTask?.cancel()
    }

    func generateAdvice(from appState: AppState) async {
        state = .loading

        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break // Model is ready, proceed
        case .unavailable(.deviceNotEligible):
            state = .unavailable(.deviceNotEligible)
            return
        case .unavailable(.appleIntelligenceNotEnabled):
            state = .unavailable(.notEnabled)
            return
        case .unavailable(.modelNotReady):
            state = .unavailable(.modelNotReady)
            return
        case .unavailable(_):
            state = .unavailable(.generic)
            return
        @unknown default:
            state = .unavailable(.unknown)
            return
        }

        let languageCode = LocalizationManager.currentAppLocale.language.languageCode?.identifier ?? "fr"
        let responseLanguage = languageCode == "en" ? "English" : "French"

        let builder = AIAdvisorPromptBuilder()
        let session = LanguageModelSession(instructions: builder.instructions(responseLanguage: responseLanguage))
        // Aggregates only: the model never sees a label, a merchant or an account name.
        let prompt = builder.prompt(for: appState.aiAdvisorContext())

        do {
            let response = try await session.respond(to: prompt, generating: AIInsight.self)
            state = .available(response.content)
        } catch {
            state = .unavailable(.failure(error.userMessage))
        }
    }
}
