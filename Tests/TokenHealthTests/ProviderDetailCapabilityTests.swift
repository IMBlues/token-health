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
    func everyOtherProviderIsUnsupported() {
        for kind in ProviderKind.allCases where kind != .deepSeek {
            for auth in AuthMode.allCases {
                #expect(
                    !ProviderFactory.producesUsageDetail(for: config(kind, auth: auth)),
                    "\(kind) / \(auth) 不该被当成支持详情"
                )
            }
        }
    }
}
