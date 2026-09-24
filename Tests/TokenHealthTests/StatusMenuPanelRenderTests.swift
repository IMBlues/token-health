import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

private struct PanelStubFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable {
        throw PanelStubError()
    }
}

private struct PanelStubError: Error {}

/// 下拉面板的渲染冒烟测试。用 `ImageRenderer` 在无窗口进程里光栅化整个面板，
/// 能拦住「视图在渲染时崩掉」和「面板高度没有跟着账号数增长」这类问题。
/// 像素级外观不在这里断言 —— 那要靠人工看。
@MainActor
struct StatusMenuPanelRenderTests {
    @Test
    func thePanelGrowsWithEachAccount() throws {
        let empty = try renderPanel(accounts: 0)
        let populated = try renderPanel(accounts: 3)

        #expect(populated.height > empty.height)
    }

    @Test
    func aPinnedAccountRendersTheSameAsAnUnpinnedOne() throws {
        let unpinned = try renderPanel(accounts: 3, pinnedIndices: [])
        let pinned = try renderPanel(accounts: 3, pinnedIndices: [0])

        // 钉住只换一个图标，版式不该因此变化。
        #expect(pinned.height == unpinned.height)
    }

    /// 视图里写错一个 SF Symbol 名字不会报错，只会安静地画不出来。
    @Test
    func thePanelSymbolsAreReal() {
        for name in ["pin", "pin.fill", "chevron.right", "chevron.down", "arrow.clockwise.circle", "gearshape"] {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not a valid SF Symbol"
            )
        }
    }

    private func renderPanel(accounts: Int, pinnedIndices: [Int] = []) throws -> (width: Int, height: Int) {
        let defaults = UserDefaults(suiteName: "panel-render-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        let state = AppState(
            configStore: store,
            usageReporter: UsageReporter(),
            rateStore: ExchangeRateStore(configStore: store, fetcher: PanelStubFetcher())
        )

        let kinds: [ProviderKind] = [.kimiCode, .zhipuCode, .deepSeek]
        for index in 0..<accounts {
            let kind = kinds[index % kinds.count]
            let id = state.addConfig(providerKind: kind)
            state.snapshots[id] = ProviderUsageSnapshot(
                id: id,
                serviceName: kind.title,
                providerTitle: kind.title,
                planName: "Plan",
                usages: [
                    TokenUsage(window: .fiveHours, used: 31, limit: 100),
                    TokenUsage(window: .week, used: 82, limit: 100)
                ],
                state: .ready,
                statusMessage: "ok",
                updatedAt: Date()
            )
        }
        for index in pinnedIndices where index < accounts {
            state.setPinned(state.configs[index].id, true)
        }

        let renderer = ImageRenderer(
            content: StatusMenuView()
                .environmentObject(state)
                .frame(width: 360)
        )
        renderer.scale = 2

        let image = try #require(renderer.cgImage)
        return (image.width, image.height)
    }
}
