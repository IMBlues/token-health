import Foundation
import Testing
@testable import TokenHealth

/// 客户端身份不是装饰：后端按它裁剪返回。
struct GoogleAIClientIdentityTests {
    @Test
    func theUserAgentCarriesTheVersionWhenThereIsOne() {
        #expect(GoogleAIClientIdentity.userAgent(version: "2.23.1") == "antigravity/2.23.1")
    }

    @Test
    func anUnknownVersionFallsBackToTheBareName() {
        // 认不出名字也不能改成别的客户端 —— 后端对不带 "antigravity" 的 UA 直接按「不受支持的
        // 客户端」处理，连账号的 project 都不给。
        #expect(GoogleAIClientIdentity.userAgent(version: nil) == "antigravity")
        #expect(GoogleAIClientIdentity.userAgent(version: "") == "antigravity")
    }

    @Test
    func theVersionComesFromTheAppTheBinaryShipsIn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Antigravity.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources/bin"),
            withIntermediateDirectories: true
        )
        try Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleShortVersionString</key><string>9.9.9</string>
        </dict></plist>
        """#.utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let binary = app.appendingPathComponent("Contents/Resources/bin/language_server")

        #expect(GoogleAIClientIdentity.installedVersion(executableAt: binary) == "9.9.9")
    }

    @Test
    func aBinaryWithoutAnAppAroundItHasNoVersion() {
        let binary = URL(fileURLWithPath: "/tmp/nowhere-\(UUID().uuidString)/language_server")

        #expect(GoogleAIClientIdentity.installedVersion(executableAt: binary) == nil)
    }
}
