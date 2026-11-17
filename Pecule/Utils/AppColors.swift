import SwiftUI
import UIKit

// "Ardoise" identity: slate neutrals carry structure, one cobalt carries interaction,
// green is reserved for money in and red for trouble. Every token has a light and a dark value;
// the app follows the system appearance, so chrome (titles, tab bar) always reads on the canvas.
enum AppColors {
    // Tonal elevation ladder: canvas < grouped < surface < elevated (dark), the reverse tones in light.
    static let canvas = Color(light: "#F2F4F7", dark: "#0B0F17")
    static let overviewBackground = Color(light: "#FAF9F6", dark: "#0B0F17")
    static let canvasGrouped = Color(light: "#E8ECF1", dark: "#111722")
    static let surface = Color(light: "#FFFFFF", dark: "#161D2A")
    static let surfaceElevated = Color(light: "#FFFFFF", dark: "#1E2736")
    static let separator = Color(light: "#D9DFE7", dark: "#2A3446")

    static let textPrimary = Color(light: "#0F172A", dark: "#F1F4F9")
    static let textSecondary = Color(light: "#4A586B", dark: "#A9B3C2")
    // Darkened from the proposal so it clears 4.5:1 on the grouped tab-bar background.
    static let textTertiary = Color(light: "#56657A", dark: "#8391A4")

    static let accent = Color(light: "#1D4ED8", dark: "#5B93FF")
    static let onAccent = Color(light: "#FFFFFF", dark: "#0B0F17")
    static let accentTint = Color(light: "#E4ECFC", dark: "#1A2B4D")
    static let selection = Color(light: "#E4ECFC", dark: "#1A2B4D")
    static let focusRing = accent

    // Money direction and states.
    static let positive = Color(light: "#0F7B4F", dark: "#38C97F")
    static let positiveTint = Color(light: "#E3F5EC", dark: "#12301F")
    static let negative = Color(light: "#C4223A", dark: "#FF6E7A")
    static let negativeTint = Color(light: "#FBE7EA", dark: "#3A1A1F")
    // Darkened so warning text on its tint reaches 4.5:1.
    static let warning = Color(light: "#9E5400", dark: "#F2B33D")
    static let warningTint = Color(light: "#FCEFDC", dark: "#3A2C10")
    // Darkened from #0E6FBF (4.42:1 on infoTint) so info text clears 4.5:1 on infoTint (4.63) and the grouped canvas (4.58).
    static let info = Color(light: "#0D6CB9", dark: "#79AEFF")
    static let infoTint = Color(light: "#E3EEFA", dark: "#14283F")

    static let neutralPill = Color(light: "#E4E9F0", dark: "#242E3F")
    static let neutralPillText = Color(light: "#3D4A5C", dark: "#BCC5D3")
    static let chartGrid = Color(light: "#E3E8EF", dark: "#222B3A")
    static let chartAxisText = textTertiary

    // Domain tints: one stable colour per part of the app, never a neon.
    static let subscriptionTint = category(.subscriptions)
    static let purchaseTint = category(.shopping)
    static let goalTint = accent
    static let habitTint = info

    // Category palette: no pure green, no pure red, neighbouring hues separated by lightness.
    static func category(_ category: ExpenseCategory) -> Color {
        switch category {
        case .subscriptions: Color(light: "#4F5BD5", dark: "#8A93F5")
        case .insurance: Color(light: "#5E7689", dark: "#9CB1C4")
        // Leaf yellow-green instead of teal, so groceries never read as "money in".
        case .groceries: Color(light: "#4E7F22", dark: "#9CC85A")
        case .fuel: Color(light: "#9C6A08", dark: "#E3B341")
        case .transport: Color(light: "#0A7599", dark: "#43BDE0")
        case .housing: Color(light: "#8A5A33", dark: "#C69268")
        case .health: Color(light: "#B83A88", dark: "#EA7EC0")
        case .leisure: Color(light: "#7B47C9", dark: "#B58BF2")
        case .shopping: Color(light: "#C4521A", dark: "#F5975A")
        case .education: Color(light: "#23457A", dark: "#7896C8")
        default: Color(light: "#667085", dark: "#9AA3B2")
        }
    }

    // Colour is never the only channel: every category also has a symbol.
    static func categorySymbol(_ category: ExpenseCategory) -> String {
        switch category {
        case .subscriptions: "creditcard"
        case .insurance: "shield"
        case .groceries: "cart"
        case .fuel: "fuelpump"
        case .transport: "tram"
        case .housing: "house"
        case .health: "cross.case"
        case .leisure: "gamecontroller"
        case .shopping: "bag"
        case .education: "book"
        default: "ellipsis.circle"
        }
    }

    // Legacy names kept during the migration; they now point at the semantic tokens.
    static let background = canvas
    static let groupedBackground = canvasGrouped
    static let cardBackground = surface
    static let cardBackgroundOpaque = surface
    static let primaryText = textPrimary
    static let secondaryText = textSecondary
    static let success = positive
    static let error = negative
    static let neutral = neutralPillText
}

extension Color {
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
