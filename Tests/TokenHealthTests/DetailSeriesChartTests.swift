import Foundation
import Testing
@testable import TokenHealth

struct DetailSeriesChartTests {
    private func points(_ values: [Double]) -> [DetailSeriesPoint] {
        values.enumerated().map { index, value in
            DetailSeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400), value: value)
        }
    }

    @Test
    func normalizesAgainstTheLargestPoint() {
        let heights = DetailSeriesChart.heights(points: points([0, 50, 100]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [0, 20, 40])
    }

    @Test
    func reportsZeroMaximumForAnEmptyOrAllZeroSeries() {
        #expect(DetailSeriesChart.maximum(of: []) == 0)
        #expect(DetailSeriesChart.maximum(of: points([0, 0, 0])) == 0)

        let heights = DetailSeriesChart.heights(points: points([0, 0]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [0, 0], "全 0 时不该出现一排最小高度的柱子")
    }

    @Test
    func keepsTinyNonZeroValuesVisible() {
        let heights = DetailSeriesChart.heights(
            points: points([1_000_000, 1]),
            maxHeight: 40,
            minimumVisibleHeight: 1.5
        )
        #expect(heights[0] == 40)
        #expect(heights[1] == 1.5, "非 0 但极小的值托到最小可见高度")
    }

    @Test
    func handlesASinglePoint() {
        let heights = DetailSeriesChart.heights(points: points([7]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [40])
    }

    @Test
    func neverExceedsTheGivenHeight() {
        let heights = DetailSeriesChart.heights(points: points([3, 1, 2]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights.allSatisfy { $0 <= 40 })
    }

    @Test
    func ignoresNonFiniteValues() {
        let heights = DetailSeriesChart.heights(points: points([.nan, 100]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights[0] == 0, "NaN 不该被当成一个巨大的峰值")
        #expect(heights[1] == 40)
    }
}
