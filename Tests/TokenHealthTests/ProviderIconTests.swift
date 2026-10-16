import AppKit
import Foundation
import Testing
@testable import TokenHealth

@MainActor
struct ProviderIconTests {
    @Test
    func brandedProvidersDeclareAnAsset() {
        #expect(ProviderIcon.assetName(for: .kimiCode) == "kimi")
        #expect(ProviderIcon.assetName(for: .deepSeek) == "deepseek")
        #expect(ProviderIcon.assetName(for: .volcengineArk) == "volcengine")
        #expect(ProviderIcon.assetName(for: .genericHTTP) == nil)
        #expect(ProviderIcon.assetName(for: .demo) == nil)
    }

    @Test
    func everyDeclaredLogoIsBundled() throws {
        for kind in ProviderKind.allCases {
            guard let name = ProviderIcon.assetName(for: kind) else {
                continue
            }
            let url = try #require(
                ProviderIcon.bundledLogoURL(for: kind),
                "\(name).pdf is not in the resource bundle; run scripts/fetch-provider-icons.sh"
            )
            #expect(NSImage(contentsOf: url) != nil, "\(name).pdf could not be decoded")
        }
    }

    /// 写错一个 SF Symbol 名字不会报错，只会静默画出一张空白图。
    @Test
    func everyFallbackSymbolNameIsReal() {
        for kind in ProviderKind.allCases {
            let name = ProviderIcon.symbolName(for: kind)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not a valid SF Symbol, so \(kind) would silently draw a blank image"
            )
        }
    }

    /// 不管走 logo 还是走 SF Symbol，每个 Provider 都得真的落墨。
    @Test
    func everyProviderDrawsSomething() {
        for kind in ProviderKind.allCases {
            let image = ProviderIcon.image(for: kind, size: 16, tint: .black)

            #expect(image.size.width == 16)
            #expect(image.size.height == 16)
            #expect(!image.isTemplate, "the composed menu bar image must keep its colors")
            #expect(opaquePixelCount(image) > 8, "\(kind) drew (almost) nothing")
        }
    }

    /// 菜单栏每一轮重绘都会重新取一次 logo。要是每次都 `NSImage(contentsOf:)`，
    /// 就是每秒几十次读盘解 PDF —— 同一个 kind 只该读一次，之后拿同一张。
    @Test
    func aBundledLogoIsLoadedFromDiskOnlyOnce() throws {
        let first = try #require(ProviderIcon.bundledLogo(for: .cursor))
        let second = try #require(ProviderIcon.bundledLogo(for: .cursor))

        #expect(first === second)
    }

    /// 缓存的是原始 logo，不是上完色的成品：成品会把某个时刻的深浅色定死在图里，
    /// 菜单栏换色之后就再也反不回色了。
    @Test
    func theCacheDoesNotFreezeTheTint() {
        let white = ProviderIcon.image(for: .cursor, size: 16, tint: .white)
        let black = ProviderIcon.image(for: .cursor, size: 16, tint: .black)

        #expect(brightPixelCount(white) > 0, "the white logo did not stay white")
        #expect(brightPixelCount(black) == 0, "the black logo came back white")
    }

    /// 设置侧边栏走的是 SwiftUI，那里的图标必须是模板图。
    ///
    /// `image(for:size:tint:)` 把颜色交给延迟绘制去解析，在 AppKit 里没问题（菜单栏项每次重绘
    /// 都自己算好黑或白），但在 SwiftUI 里会被连同当时的外观一起光栅化缓存下来：系统从深色切回
    /// 浅色时它不重画，侧边栏里所有 logo 就停在白色，而同一行的文字已经变回黑色了。
    /// 模板图没有颜色可缓存，SwiftUI 每次都用当前前景色重画，选中行也自然跟着变白。
    @Test
    func theTemplateImageCarriesNoColourOfItsOwn() {
        for kind in ProviderKind.allCases {
            let image = ProviderIcon.templateImage(for: kind, size: 16)

            #expect(image.isTemplate, "\(kind): 没标成 template，SwiftUI 就会照原样画它")
            #expect(
                ink(of: image, under: .aqua) == ink(of: image, under: .darkAqua),
                "\(kind): 图里烤进了跟外观有关的颜色，换外观时就不会跟着变"
            )
            #expect(
                ink(of: image, under: .aqua).contains { $0 > 0 },
                "\(kind): 模板图什么都没画"
            )
        }
    }

    /// 25% 覆盖度以上的像素占比，用来比较两张图在两种外观下画出来是否一致。
    private func ink(of image: NSImage, under appearance: NSAppearance.Name) -> [Int] {
        let side = 16
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()

        return (0..<side).flatMap { x in
            (0..<side).map { y in
                Int(((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
            }
        }
    }
}
