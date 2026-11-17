import SwiftUI

// Motion tokens. Everything animated goes through here so Reduce Motion degrades it in one place.
enum AppMotion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let numeric = Animation.easeInOut(duration: 0.4)
    static let listInsert = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let chart = Animation.easeOut(duration: 0.6)
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? reduced : animation
    }
}

private struct AppAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(AppMotion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct NumericTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.contentTransition(.opacity)
        } else {
            content.contentTransition(.numericText())
        }
    }
}

extension View {
    func appAnimation<Value: Equatable>(_ animation: Animation = AppMotion.standard, value: Value) -> some View {
        modifier(AppAnimationModifier(animation: animation, value: value))
    }

    // Money values roll in place instead of snapping.
    func appNumericTransition() -> some View {
        modifier(NumericTransitionModifier())
    }
}
