import AppKit

/// 把一份布局画成菜单栏项用的位图。
///
/// 整个类型限定在主线程：所有绘制都发生在主线程，而 `NSFont` 不是 `Sendable`，
/// 静态常量在 Swift 6 严格并发下必须挂在 actor 上。
@MainActor
enum MenuBarItemRenderer {
    static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// 金额型内容的文本宽度。布局层拿不到字体度量，所以由这里量好传进去。
    static func amountWidth(for metrics: [MenuBarMetric]) -> CGFloat {
        guard let text = MenuBarItemLayout.amountText(in: metrics) else {
            return 0
        }
        return (text as NSString).size(withAttributes: [.font: amountFont]).width
    }

    static func image(
        layout: MenuBarItemLayout,
        kind: ProviderKind,
        metrics: [MenuBarMetric],
        iconColor: NSColor,
        scale: CGFloat
    ) -> NSImage {
        let pointSize = layout.size
        let pixelWidth = Int(max(1, (pointSize.width * scale).rounded()))
        let pixelHeight = Int(max(1, (pointSize.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: pointSize)
        }

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        draw(layout: layout, kind: kind, metrics: metrics, iconColor: iconColor)
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = false
        return image
    }

    private static func draw(
        layout: MenuBarItemLayout,
        kind: ProviderKind,
        metrics: [MenuBarMetric],
        iconColor: NSColor
    ) {
        if let iconRect = layout.iconRect {
            ProviderIcon.image(for: kind, size: iconRect.width, tint: iconColor)
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let trackColor = iconColor.withAlphaComponent(0.18)
        for track in layout.tracks {
            trackColor.setFill()
            barPath(in: track).fill()
        }

        let severities = metrics.compactMap(\.severity)
        for (index, fill) in layout.fills.enumerated() where fill.height > 0 {
            fillColor(for: index < severities.count ? severities[index] : nil).setFill()
            barPath(in: fill).fill()
        }

        if let amountRect = layout.amountRect,
           let text = MenuBarItemLayout.amountText(in: metrics) {
            let string = NSAttributedString(
                string: text,
                attributes: [.font: amountFont, .foregroundColor: iconColor]
            )
            string.draw(
                at: NSPoint(
                    x: amountRect.minX,
                    y: amountRect.midY - string.size().height / 2
                )
            )
        }
    }

    private static func barPath(in rect: CGRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: rect,
            xRadius: MenuBarItemLayout.barWidth / 2,
            yRadius: MenuBarItemLayout.barWidth / 2
        )
    }

    /// 阈值与菜单卡片保持一致：≥90% 红、≥70% 橙、其余绿。
    private static func fillColor(for severity: Double?) -> NSColor {
        guard let severity else {
            return .systemGreen
        }
        if severity >= 0.9 {
            return .systemRed
        }
        if severity >= 0.7 {
            return .systemOrange
        }
        return .systemGreen
    }
}
