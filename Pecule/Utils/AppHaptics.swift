import SwiftUI
import UIKit

// Haptic tokens. Automation runs switch them off in one place; every call site names the gesture, not the generator.
@MainActor
enum AppHaptics {
    enum Kind {
        case success
        case warning
        case error
        case selection
        case impact
    }

    static var isEnabled = true

    static func play(_ kind: Kind) {
        guard isEnabled else {
            return
        }
        switch kind {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .impact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    static func feedback(for kind: Kind) -> SensoryFeedback {
        switch kind {
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .selection: .selection
        case .impact: .impact(weight: .light)
        }
    }
}

private struct AppHapticModifier<Trigger: Equatable>: ViewModifier {
    let kind: AppHaptics.Kind
    let trigger: Trigger

    func body(content: Content) -> some View {
        let isEnabled = AppHaptics.isEnabled
        content.sensoryFeedback(trigger: trigger) { _, _ in
            isEnabled ? AppHaptics.feedback(for: kind) : nil
        }
    }
}

extension View {
    // Declarative variant for values that change while the view stays on screen (a sync date, a counter).
    func appHaptic<Trigger: Equatable>(_ kind: AppHaptics.Kind, trigger: Trigger) -> some View {
        modifier(AppHapticModifier(kind: kind, trigger: trigger))
    }
}
