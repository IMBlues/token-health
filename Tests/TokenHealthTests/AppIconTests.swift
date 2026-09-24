import AppKit
import Testing
@testable import TokenHealth

@MainActor
struct AppIconTests {
    @Test
    func menuIconIsAnAdaptiveTemplate() throws {
        let image = try #require(AppIcon.menuBarImage())
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(opaquePixelCount(image) > 8)
    }

    @Test
    func applicationIconsExistForBothAppearances() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let lightImage = try #require(AppIcon.applicationImage(for: light))
        let darkImage = try #require(AppIcon.applicationImage(for: dark))
        #expect(!lightImage.isTemplate)
        #expect(!darkImage.isTemplate)
        #expect(lightImage.size == darkImage.size)
        #expect(lightImage.tiffRepresentation != darkImage.tiffRepresentation)
    }
}
