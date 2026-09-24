import CoreGraphics

/// 趋势图的纯几何：把一串点归一化成柱高。
/// 与 `MenuBarItemLayout` 同一路数 —— 不碰 AppKit，便于在无窗口进程里验证。
enum DetailSeriesChart {
    /// 归一化基准：所有点的最大值。空序列或全 0 返回 0。
    static func maximum(of points: [DetailSeriesPoint]) -> Double {
        points.map(\.value).filter { $0.isFinite && $0 > 0 }.max() ?? 0
    }

    /// 与 `points` 一一对应的柱高。
    /// 值为 0 的柱高为 0；非 0 但极小的值托到 `minimumVisibleHeight`，避免看不见。
    static func heights(
        points: [DetailSeriesPoint],
        maxHeight: CGFloat,
        minimumVisibleHeight: CGFloat
    ) -> [CGFloat] {
        let peak = maximum(of: points)
        guard peak > 0, maxHeight > 0 else {
            return points.map { _ in 0 }
        }
        return points.map { point in
            guard point.value.isFinite, point.value > 0 else {
                return 0
            }
            let scaled = maxHeight * CGFloat(point.value / peak)
            return min(maxHeight, max(minimumVisibleHeight, scaled))
        }
    }
}
