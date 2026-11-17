import Accessibility
import SwiftUI

// What VoiceOver gets from a line chart of euro amounts over time: a title, a one-sentence summary, and the
// points to explore (date on x, euros on y), instead of an unnamed picture.
struct AmountOverTimeChartDescriptor: AXChartDescriptorRepresentable {
    struct Point {
        let date: Date
        let amount: Double
    }

    let title: String
    let summary: String
    let seriesName: String
    let xTitle: String
    let yTitle: String
    let points: [Point]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = points.map { $0.date.timeIntervalSince1970 }
        let ys = points.map(\.amount)
        let xAxis = AXNumericDataAxisDescriptor(
            title: xTitle,
            range: (xs.min() ?? 0) ... (xs.max() ?? 0),
            gridlinePositions: []
        ) { Formatters.dateString(for: Date(timeIntervalSince1970: $0)) }
        let yAxis = AXNumericDataAxisDescriptor(
            title: yTitle,
            range: (ys.min() ?? 0) ... (ys.max() ?? 0),
            gridlinePositions: []
        ) { Formatters.currencyString(for: Decimal($0)) }
        let series = AXDataSeriesDescriptor(
            name: seriesName,
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.amount) }
        )
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
