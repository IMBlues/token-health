import AppKit
import SwiftUI

/// 把 SwiftUI 自动塞在工具栏最前面的弹性空位摘掉。
///
/// 实测（`ZZToolbarProbe`）拿到的 NSToolbar 是：
/// `[FlexibleSpace][toggleSidebar][splitViewSeparator][+][−]` —— 那个开头的弹性空位会把
/// 侧边栏开关和增删按钮一起推到窗口中间，看起来就不像「挨着侧边栏开关」。
/// SwiftUI 没有 API 关掉它，只能在窗口出现后从 NSToolbar 上摘。
enum SettingsToolbarTuner {
    static func tune(_ window: NSWindow?) {
        guard let toolbar = window?.toolbar else {
            return
        }
        var removed = 0
        while let first = toolbar.items.first, first.itemIdentifier == .flexibleSpace {
            toolbar.removeItem(at: 0)
            removed += 1
        }
        if removed > 0 {
            print("[TUNE] removed \(removed) leading flexible space item(s)")
        }
    }
}

/// 拿到承载本视图的 `NSWindow` —— SwiftUI 的 View 里没有这个入口。
struct WindowTuner: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
