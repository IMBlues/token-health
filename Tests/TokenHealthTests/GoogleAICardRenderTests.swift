import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

private struct CardRenderStubFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable {
        throw CardRenderStubError()
    }
}

private struct CardRenderStubError: Error {}

/// Google AI 的卡片布局冒烟测试。渲染器在无窗口进程里光栅化整个面板，能拦住「视图渲染时崩掉」
/// 和「四个窗口又挤回一行」这类问题。像素级外观不在这里断言 —— 那要靠人工看。
@MainActor
struct GoogleAICardRenderTests {
    @Test
    func theGoogleAICardWrapsItsFourWindowsOntoTwoRows() throws {
        let googleAI = try renderPanel(kind: .googleAI, usages: [
            TokenUsage(window: .fiveHours, label: "Gemini 5h", used: 0, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "Gemini Week", used: 60, limit: 100, unit: "%"),
            TokenUsage(window: .fiveHours, label: "Claude & GPT 5h", used: 12, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "Claude & GPT Week", used: 4, limit: 100, unit: "%")
        ])
        let kimi = try renderPanel(kind: .kimiCode, usages: [
            TokenUsage(window: .fiveHours, used: 31, limit: 100),
            TokenUsage(window: .week, used: 82, limit: 100)
        ])

        // 四条并排时每列只有 ~75pt，「Claude & GPT 5h」会被截成「Claude…」—— 四列看起来一模一样。
        // 换行成两行两列是这个 Provider 的卡片比别的高的原因，也正是这条断言在守的东西。
        #expect(googleAI.height > kimi.height)
        #expect(googleAI.width == kimi.width)
    }

    private func renderPanel(kind: ProviderKind, usages: [TokenUsage]) throws -> (width: Int, height: Int) {
        let defaults = UserDefaults(suiteName: "card-render-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        let state = AppState(
            configStore: store,
            usageReporter: UsageReporter(),
            rateStore: ExchangeRateStore(configStore: store, fetcher: CardRenderStubFetcher())
        )

        let id = state.addConfig(providerKind: kind)
        state.snapshots[id] = ProviderUsageSnapshot(
            id: id,
            serviceName: kind.title,
            providerTitle: kind.title,
            planName: "Plan",
            usages: usages,
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )

        let renderer = ImageRenderer(
            content: StatusMenuView(openSettings: {})
                .environmentObject(state)
                .frame(width: 360)
        )
        renderer.scale = 2

        let image = try #require(renderer.cgImage)
        return (image.width, image.height)
    }
}
