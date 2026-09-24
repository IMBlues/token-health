import Foundation

// SwiftPM 里「有 @main」和「有 main.swift」只能二选一。入口放在这里，是为了让 QA 模式
// 能在 SwiftUI / AppKit 起来之前就接管进程 —— 见 ProviderLifecycleQA。
if ProviderLifecycleQA.isEnabled {
    ProviderLifecycleQA.run()
}

TokenHealthApp.main()
