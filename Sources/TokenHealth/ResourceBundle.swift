import Foundation

/// App 资源包的唯一查找入口。
///
/// 不能用 SwiftPM 生成的 `Bundle.module`：`swift build` 生成的那份访问器只在
/// `.app` 根目录和构建机上的 `.build` 绝对路径里找资源包。前者散在 Contents 之外，
/// 会让代码签名变成 unsealed（`codesign --verify` 直接报错）；后者在别人的机器上
/// 根本不存在。两个都落空时 `Bundle.module` 走的是 `fatalError`，于是别人装上就闪退。
///
/// 改成沿 `Bundle.main` 找到 `Contents/Resources` 里的资源包。找不到返回 nil，
/// 由调用方各自退回 SF Symbol，不拿闪退换一张图标。
enum ResourceBundle {
    static let module: Bundle? = {
        let name = "TokenHealth_TokenHealth"
        let directories = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for directory in directories {
            let path = directory.appendingPathComponent("\(name).bundle").path
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }
        #if DEBUG
        // 测试进程里 Bundle.main 是 .xctest，资源包在旁边的构建目录里，只能交给生成访问器。
        return Bundle.module
        #else
        return nil
        #endif
    }()
}
