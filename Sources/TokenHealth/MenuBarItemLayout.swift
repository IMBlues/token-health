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
    static let percentageWidth: CGFloat = 23
    static let percentageGap: CGFloat = 1
    static let percentageIconSize: CGFloat = 10
    static let percentageIconGap: CGFloat = 1
    static let percentageRowHeight: CGFloat = 7
    static let percentageRowsPerColumn = 3
    static let percentageStatusItemPadding: CGFloat = 2

    var size: CGSize
    var iconRect: CGRect?
    /// 每根条的空槽，满高。
    var tracks: [CGRect]
    /// 每根条的填充，从空槽底部起算。
    var fills: [CGRect]
    /// 金额型内容的可用区域；有它时 `tracks` 与 `fills` 必为空。
    var amountRect: CGRect?
    var percentageRects: [CGRect] = []

    var statusItemLength: CGFloat {
        size.width + (percentageRects.isEmpty ? Self.statusItemPadding : Self.percentageStatusItemPadding)
    }

    static func make(
        metrics: [MenuBarMetric],
        hasIcon: Bool,
        amountWidth: CGFloat,
        displayStyle: MenuBarDisplayStyle = .bars
    ) -> MenuBarItemLayout {
        let amount = amountText(in: metrics)
        let isPercentage = displayStyle == .percentage && amount == nil
        let metricCount = metrics.filter { if case .ratio = $0.shape { true } else { false } }.count
        let percentageRows = min(max(metricCount, 1), percentageRowsPerColumn)
        let logoSize = isPercentage ? percentageIconSize : iconSize
        let iconWidth = hasIcon ? logoSize + (isPercentage ? percentageIconGap : iconGap) : 0
        let height = max(maxBarHeight + 2 * verticalPadding, isPercentage ? CGFloat(percentageRows) * percentageRowHeight : 0)
        let iconRect = hasIcon
            ? CGRect(x: 0, y: (height - logoSize) / 2, width: logoSize, height: logoSize)
            : nil

        if amount != nil {
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

        if displayStyle == .percentage {
            let insetY = (height - CGFloat(percentageRows) * percentageRowHeight) / 2
            let rects = ratios.indices.map { index in
                CGRect(
                    x: iconWidth + CGFloat(index / percentageRowsPerColumn) * (percentageWidth + percentageGap),
                    y: insetY + CGFloat(percentageRows - 1 - index % percentageRowsPerColumn) * percentageRowHeight,
                    width: percentageWidth,
                    height: percentageRowHeight
                )
            }
            return MenuBarItemLayout(
                size: CGSize(width: rects.last!.maxX, height: height),
                iconRect: iconRect,
                tracks: [],
                fills: [],
                amountRect: nil,
                percentageRects: rects
            )
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
