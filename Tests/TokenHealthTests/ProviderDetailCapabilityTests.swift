import Foundation
import Testing
@testable import TokenHealth

struct ProviderDetailCapabilityTests {
    private func config(_ kind: ProviderKind, auth: AuthMode) -> ServiceConfig {
        ServiceConfig(displayName: kind.title, providerKind: kind, authMode: auth)
    }

    @Test
    func onlyBrowserLoginDeepSeekProducesDetail() {
        #expect(ProviderFactory.producesUsageDetail(for: config(.deepSeek, auth: .browserLogin)))
        #expect(
            !ProviderFactory.producesUsageDetail(for: config(.deepSeek, auth: .api)),
            "这个判断只看得到 config；API 模式下不提供浮层"
        )
    }

    @Test
    func browserLoginOpenCodeGoProducesDetail() {
        #expect(ProviderFactory.producesUsageDetail(for: config(.openCodeGo, auth: .browserLogin)))
        #expect(
            !ProviderFactory.producesUsageDetail(for: config(.openCodeGo, auth: .api)),
            "API key 模式只有百分比与重置时间，撑不起卡片"
        )
    }

    @Test
    func codexProducesDetailInEitherMode() {
        // Codex 没有登录 / API 之分：`usesLocalLogin` 把它的 authMode 固定成 `.api`，
        // 所以这个分支不能看 authMode（与 DeepSeek / Go 那条规则不同）。
        #expect(ProviderFactory.producesUsageDetail(for: config(.codex, auth: .api)))
        #expect(ProviderFactory.producesUsageDetail(for: config(.codex, auth: .browserLogin)))
    }

    @Test
    func everyOtherProviderIsUnsupported() {
        for kind in ProviderKind.allCases where kind != .deepSeek && kind != .openCodeGo && kind != .codex {
            for auth in AuthMode.allCases {
                #expect(
                    !ProviderFactory.producesUsageDetail(for: config(kind, auth: auth)),
                    "\(kind) / \(auth) 不该被当成支持详情"
                )
            }
        }
    }
}
