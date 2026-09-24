import AppKit
import Foundation
import Testing
@testable import TokenHealth

struct ProviderIconTests {
    @Test
    func everyProviderResolvesToOneFormOfIcon() {
        for kind in ProviderKind.allCases {
            let hasAsset = ProviderIcon.assetName(for: kind) != nil
            let hasSymbol = !ProviderIcon.symbolName(for: kind).isEmpty
            #expect(hasAsset || hasSymbol, "\(kind) has neither a logo asset nor a fallback symbol")
        }
    }

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

    @Test
    func loadsTheBundledLogoAtTheRequestedSize() {
        let image = ProviderIcon.image(for: .kimiCode, size: 16, tint: .black)

        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
        #expect(!image.isTemplate, "the composed menu bar image must keep its colors")
    }

    @Test
    func fallsBackToASymbolForProvidersWithoutALogo() {
        let image = ProviderIcon.image(for: .genericHTTP, size: 16, tint: .black)

        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }
}
