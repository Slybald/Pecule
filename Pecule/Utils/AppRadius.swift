import CoreGraphics

// Continuous corners everywhere. Large radii read as toys; money gets 16 at most on cards.
enum AppRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let sheet: CGFloat = 20
    static let bar: CGFloat = 4
    static let progress: CGFloat = 3
    static let pill: CGFloat = 999

    // Legacy names kept during the migration.
    static let sm: CGFloat = control
    static let md: CGFloat = card
    static let lg: CGFloat = sheet
}
