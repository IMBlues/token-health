import AppKit

/// 把一张图强制绘制到已知的 RGBA 位图上，数出至少部分不透明的像素个数。
///
/// 用来区分「画了东西」和「交了一张空白图」。尺寸断言做不到这件事 ——
/// 而空白图恰恰是 SF Symbol 名字写错、或 logo 资源没打进包时的表现。
///
/// 之所以不直接读 `image.representations`：`ProviderIcon` 返回的是延迟绘制的
/// `NSImage(drawingHandler:)`，在真正绘制之前它没有任何位图表示。
@MainActor
func opaquePixelCount(_ image: NSImage) -> Int {
    guard let rep = rasterized(image), let data = rep.bitmapData else {
        return 0
    }
    let alphaIndex = rep.samplesPerPixel - 1
    let stride = rep.samplesPerPixel
    var count = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * stride + alphaIndex] > 0 {
            count += 1
        }
    }
    return count
}

/// 数出比较亮的不透明像素。`opaquePixelCount` 分不出同一张 logo 上的是白漆还是黑漆
/// —— 两种颜色都会落满同一个形状 —— 而「菜单栏换色后 logo 还换不换得回来」
/// 恰恰只能这么看。
@MainActor
func brightPixelCount(_ image: NSImage) -> Int {
    guard let rep = rasterized(image), let data = rep.bitmapData else {
        return 0
    }
    let alphaIndex = rep.samplesPerPixel - 1
    let stride = rep.samplesPerPixel
    var count = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let base = y * rep.bytesPerRow + x * stride
            guard data[base + alphaIndex] > 0 else {
                continue
            }
            let luminance = (Double(data[base]) + Double(data[base + 1]) + Double(data[base + 2])) / 3
            if luminance > 127 {
                count += 1
            }
        }
    }
    return count
}

@MainActor
private func rasterized(_ image: NSImage) -> NSBitmapImageRep? {
    let width = Int(image.size.width * 2)
    let height = Int(image.size.height * 2)
    guard width > 0, height > 0,
          let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: width,
              pixelsHigh: height,
              bitsPerSample: 8,
              samplesPerPixel: 4,
              hasAlpha: true,
              isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0,
              bitsPerPixel: 0
          ),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return rep
}
