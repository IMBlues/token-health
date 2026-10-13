import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

/// Updates 那一块的渲染冒烟：五种状态下都能光栅化出图像。
///
/// 设置窗口在这台机器上没法用辅助功能脚本可靠地驱动（SwiftUI 的侧栏选中 + 合成点击都
/// 不稳），所以「这一块画得出来吗」交给这里断言 —— 至少能挡住空视图与崩溃。
@MainActor
struct UpdateSettingsSectionRenderTests {
    private func render(_ store: UpdateStore) throws -> CGImage {
        let renderer = ImageRenderer(
            content: Form {
                UpdateSettingsSection(store: store)
            }
            .formStyle(.grouped)
            .frame(width: 520)
        )
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    @Test
    func rendersBeforeTheFirstCheck() throws {
        let store = UpdateTestData.store()
        #expect(store.state == .idle)

        let image = try render(store)
        #expect(image.height > 0, "还没查过时也要有当前版本和按钮")
    }

    @Test
    func rendersUpToDate() async throws {
        let store = UpdateTestData.store(latest: UpdateTestData.release("1.0.8"))
        await store.check()

        let image = try render(store)
        #expect(image.height > 0)
    }

    @Test
    func rendersAnAvailableUpdate() async throws {
        let store = UpdateTestData.store(latest: UpdateTestData.release("1.0.9"))
        await store.check()
        #expect(store.state == .updateAvailable(UpdateTestData.release("1.0.9")))

        let image = try render(store)
        #expect(image.height > 0, "多出下载按钮和 release 链接")
    }

    @Test
    func rendersADownloadedDiskImage() async throws {
        let directory = URL(fileURLWithPath: "/tmp/token-health-tests-render")
        let dmg = directory.appendingPathComponent("TokenHealth-1.0.9.dmg")
        let store = UpdateTestData.store(
            latest: UpdateTestData.release("1.0.9"),
            downloadsDirectory: directory,
            downloaded: dmg
        )
        await store.check()
        await store.downloadAndOpen()

        let image = try render(store)
        #expect(image.height > 0, "要显示落地路径和「拖进 Applications」那句话")
    }

    @Test
    func rendersAFailure() async throws {
        let store = UpdateTestData.store(checkError: URLError(.timedOut))
        await store.check()

        let image = try render(store)
        #expect(image.height > 0, "失败也要有一行字")
    }

}
