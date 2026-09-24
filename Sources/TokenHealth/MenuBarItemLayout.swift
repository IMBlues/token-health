import CoreGraphics

/// 菜单栏项的纯几何计算：图标与每根条画在哪里。
/// 刻意不碰 AppKit，这样布局可以在没有窗口服务器的测试进程里验证。
struct MenuBarItemLayout: Equatable {
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1.5
    static let maxBarHeight: CGFloat = 13
    static let iconSize: CGFloat = 12
    static let iconGap: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    /// 2% 的额度在 13pt 高里只有 0.26pt，不兜底等于看不见。
    static let minimumVisibleHeight: CGFloat = 1.5
    /// 状态项两侧留一点，避免图像贴着相邻项。
    static let statusItemPadding: CGFloat = 6

    var size: CGSize
    var iconRect: CGRect?
    /// 每根条的空槽，满高。
    var tracks: [CGRect]
    /// 每根条的填充，从空槽底部起算。
    var fills: [CGRect]
    /// 金额型内容的可用区域；有它时 `tracks` 与 `fills` 必为空。
    var amountRect: CGRect?

    static func make(metrics: [MenuBarMetric], hasIcon: Bool, amountWidth: CGFloat) -> MenuBarItemLayout {
        let iconWidth = hasIcon ? iconSize + iconGap : 0
        let height = maxBarHeight + 2 * verticalPadding
        let iconRect = hasIcon
            ? CGRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            : nil

        if amountText(in: metrics) != nil {
            let width = max(amountWidth, 0)
            return MenuBarItemLayout(
                size: CGSize(width: iconWidth + width, height: height),
                iconRect: iconRect,
                tracks: [],
                fills: [],
                amountRect: CGRect(x: iconWidth, y: verticalPadding, width: width, height: maxBarHeight)
            )
        }

        var ratios = metrics.compactMap { metric -> Double? in
            guard case let .ratio(value) = metric.shape else {
                return nil
            }
            return min(max(value, 0), 1)
        }
        if ratios.isEmpty {
            ratios = [0]
        }

        var tracks: [CGRect] = []
        var fills: [CGRect] = []
        var x = iconWidth
        for ratio in ratios {
            tracks.append(CGRect(x: x, y: verticalPadding, width: barWidth, height: maxBarHeight))
            let fillHeight = ratio > 0 ? max(minimumVisibleHeight, maxBarHeight * CGFloat(ratio)) : 0
            fills.append(CGRect(x: x, y: verticalPadding, width: barWidth, height: fillHeight))
            x += barWidth + barGap
        }

        let barsWidth = CGFloat(ratios.count) * barWidth + CGFloat(ratios.count - 1) * barGap
        return MenuBarItemLayout(
            size: CGSize(width: iconWidth + barsWidth, height: height),
            iconRect: iconRect,
            tracks: tracks,
            fills: fills,
            amountRect: nil
        )
    }

    /// 金额型内容只可能来自 DeepSeek，且一次只有一个。
    static func amountText(in metrics: [MenuBarMetric]) -> String? {
        metrics.compactMap { metric -> String? in
            guard case let .amount(text) = metric.shape else {
                return nil
            }
            return text
        }.first
    }
}
