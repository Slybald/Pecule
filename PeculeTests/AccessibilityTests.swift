import Accessibility
import SwiftUI
import UIKit
import XCTest
@testable import Pecule

// Contraste WCAG 2.1 AA (4,5:1 pour le texte) des couleurs d'information, et résumé VoiceOver des graphiques.
final class AccessibilityTests: XCTestCase {
    private func components(_ color: Color, _ style: UIUserInterfaceStyle) -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        let (r, g, b) = components(color, style)
        func linear(_ c: CGFloat) -> Double { c <= 0.03928 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ foreground: Color, on background: Color, _ style: UIUserInterfaceStyle) -> Double {
        let (a, b) = (luminance(foreground, style), luminance(background, style))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testInfoTextReadsOnItsTintAndOnTheCanvasInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertGreaterThanOrEqual(contrast(AppColors.info, on: AppColors.infoTint, style), 4.5, "info sur infoTint, \(style.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(AppColors.info, on: AppColors.surface, style), 4.5, "info sur surface, \(style.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(AppColors.info, on: AppColors.canvasGrouped, style), 4.5, "info sur fond groupé, \(style.rawValue)")
        }
    }

    func testTheChartDescriptorCarriesTheSummaryAndEveryPoint() {
        let start = TestFixtures.referenceDate
        let descriptor = AmountOverTimeChartDescriptor(
            title: "Dépenses", summary: "12,00 € dépensés", seriesName: "Dépenses", xTitle: "Date", yTitle: "Montant",
            points: [
                .init(date: start, amount: 0),
                .init(date: start.addingTimeInterval(86_400), amount: 5),
                .init(date: start.addingTimeInterval(2 * 86_400), amount: 12),
            ]
        ).makeChartDescriptor()

        XCTAssertEqual(descriptor.title, "Dépenses")
        XCTAssertEqual(descriptor.summary, "12,00 € dépensés")
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 3)
        XCTAssertEqual((descriptor.yAxis as? AXNumericDataAxisDescriptor)?.range, 0 ... 12)
    }

    func testAnEmptyChartStillBuildsADescriptor() {
        let descriptor = AmountOverTimeChartDescriptor(
            title: "t", summary: "s", seriesName: "n", xTitle: "x", yTitle: "y", points: []
        ).makeChartDescriptor()
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 0)
    }
}
