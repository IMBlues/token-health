import AppKit

/// Provider 的图标来源：能拿到官方 logo 就用 logo，否则退回 SF Symbol。
/// 设置侧边栏与菜单栏项共用这一处，避免两边各有一份「谁长什么样」。
enum ProviderIcon {
    /// 内嵌资源名。nil 表示这个 Provider 没有品牌 logo。
    static func assetName(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .cursor: "cursor"
        case .codex: "codex"
        case .kimiCode: "kimi"
        case .zhipuCode: "zhipu"
        case .deepSeek: "deepseek"
        case .miniMax: "minimax"
        case .volcengineArk: "volcengine"
        case .openCodeGo: "opencode"
        case .genericHTTP, .demo: nil
        }
    }

    static func symbolName(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "sparkles"
        case .anthropic: "text.bubble"
        case .cursor: "cursorarrow"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .kimiCode: "moon.stars"
        case .zhipuCode: "brain.head.profile"
        case .deepSeek: "waveform.path.ecg"
        case .miniMax: "m.circle"
        case .volcengineArk: "flame"
        case .openCodeGo: "terminal"
        case .genericHTTP: "network"
        case .demo: "chart.bar"
        }
    }

    /// 指定尺寸与颜色的位图。资源缺失时静默退回 SF Symbol，不让菜单栏项整块消失。
    static func image(for kind: ProviderKind, size: CGFloat, tint: NSColor) -> NSImage {
        let source = bundledLogo(for: kind) ?? symbolImage(for: kind, size: size)
        return tinted(source, color: tint, size: size)
    }

    /// 供测试断言资源确实打进了包 —— 测试进程里的 `Bundle.module` 指向测试自己的
    /// bundle，只有经这里才能真正查到 App 的资源。
    static func bundledLogoURL(for kind: ProviderKind) -> URL? {
        guard let name = assetName(for: kind) else {
            return nil
        }
        return Bundle.module.url(forResource: name, withExtension: "pdf")
    }

    static func bundledLogo(for kind: ProviderKind) -> NSImage? {
        guard let url = bundledLogoURL(for: kind) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func symbolImage(for kind: ProviderKind, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let symbol = NSImage(systemSymbolName: symbolName(for: kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return symbol ?? NSImage(size: NSSize(width: size, height: size))
    }

    /// 绘图推迟到实际绘制时执行，动态颜色（如 `.labelColor`）因此在正确的外观上下文里
    /// 解析，菜单栏项也就拿到了「单色模板」那种随深浅色自适应的效果。
    private static func tinted(_ image: NSImage, color: NSColor, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
