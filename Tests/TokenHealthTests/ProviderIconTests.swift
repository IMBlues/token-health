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
}
