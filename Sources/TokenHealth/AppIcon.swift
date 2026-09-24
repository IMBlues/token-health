import AppKit

/// 品牌图形的唯一入口：菜单栏那枚小葫芦，以及 App 图标的亮/暗两版。
///
/// 菜单栏用的是 template 图：它只带 alpha，由系统按菜单栏明暗自动着色，
/// 所以一个资源同时服务亮色和暗色菜单栏；App 图标则分亮/暗两版资源，按外观取。
enum AppIcon {
    static func menuBarImage() -> NSImage? {
        guard let url = ResourceBundle.module?.url(forResource: "TokenHealthMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    static func applicationImage(for appearance: NSAppearance) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "TokenHealthIconDark" : "TokenHealthIconLight"
        guard let url = ResourceBundle.module?.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = false
        return image
    }
}
