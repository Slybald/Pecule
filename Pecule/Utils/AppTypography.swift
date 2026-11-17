import SwiftUI

// SF Pro, default design, Dynamic Type everywhere. Emphasis comes from weight and size, never from colour alone.
enum AppTypography {
    static let screenTitle = Font.largeTitle.weight(.bold)
    static let sectionTitle = Font.headline
    static let sectionAction = Font.subheadline.weight(.medium)
    static let cardCaption = Font.footnote.weight(.medium)
    static let cardValue = Font.title2.weight(.semibold).monospacedDigit()
    static let cardTitle = Font.headline
    static let rowTitle = Font.body
    static let rowSubtitle = Font.subheadline
    static let rowAmount = Font.body.weight(.medium).monospacedDigit()
    static let rowAmountEmphasis = Font.body.weight(.semibold).monospacedDigit()
    static let meta = Font.caption
    static let badge = Font.caption.weight(.semibold)
    static let body = Font.body
    static let secondaryBody = Font.subheadline
    static let gradeLetter = Font.system(size: 56, weight: .heavy).monospacedDigit()

    // Hero amounts scale with the large title; the serif is the one distinctive typographic move of the identity.
    static func heroAmount(size: CGFloat) -> Font {
        Font.system(size: size, weight: .bold, design: .serif).monospacedDigit()
    }

    static let heroBaseSize: CGFloat = 44

    // Legacy names kept during the migration.
    static let screenSectionTitle = sectionTitle
    static let rowMeta = meta
}
