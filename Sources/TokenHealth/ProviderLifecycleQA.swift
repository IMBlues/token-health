import AppKit
import Foundation
import WebKit

/// 加 provider / 删 provider 的真机 QA：`TokenHealth --qa-provider-lifecycle`
///
/// 为什么不能只写成单元测试：这条路走的是 WebKit 的 per-identifier data store，而
/// swift-testing 进程不是真正的 App bundle —— 同样的调用在测试里永远是绿的，在 App 里才崩。
/// 这里真的建 kernel、真的删账号，崩了就是崩了，脚本按退出码判定。
///
/// 用 `scripts/qa-provider-lifecycle.sh` 跑；它会换一个 bundle id 再跑，免得动到真身的数据。
enum ProviderLifecycleQA {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--qa-provider-lifecycle")
    }

    /// 接管进程：不建 SwiftUI、不建菜单栏，跑完检查就退。
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 卡住比崩更难受（脚本会一直等），给它一个上限。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            print("QA FAIL: 超过 90 秒没跑完，多半是挂在某个 WebKit 回调上")
            exit(1)
        }

        Task { @MainActor in
            let failures = await check()
            for failure in failures {
                print("QA FAIL: \(failure)")
            }
            print(failures.isEmpty ? "QA OK" : "QA FAILED (\(failures.count))")
            exit(failures.isEmpty ? 0 : 1)
        }

        app.run()
        exit(0)
    }

    @MainActor
    private static func check() async -> [String] {
        var failures: [String] = []
        let registry = WebSessionRegistry.shared

        // 1) 先删一个这次运行从没建过 kernel 的账号 —— 顺序是故意的。
        //    真实崩法就是这样：App 刚起来，还没建过任何 data store，用户直接点减号。
        //    先做别的 WebKit 调用会把进程带进「已经有 store」的状态，那条路就不崩了。
        let neverBuilt = ServiceConfig(displayName: "QA Never", providerKind: .deepSeek, authMode: .browserLogin)
        await registry.evict(config: neverBuilt)

        // 2) 添加一个网页登录型 provider：建 kernel，也就是建出 WebKit data store，
        //    再写一个 cookie —— 有东西可清，后面的清理断言才有意义。
        let web = ServiceConfig(displayName: "QA Web", providerKind: .deepSeek, authMode: .browserLogin)
        guard registry.controller(for: web) != nil else {
            return failures + ["deepSeek 建不出 kernel"]
        }
        let store = WKWebsiteDataStore(forIdentifier: web.id)
        let cookie = HTTPCookie(properties: [
            .name: "qa", .value: "1", .domain: "example.com", .path: "/",
            .expires: Date().addingTimeInterval(3600),
        ])!
        await store.httpCookieStore.setCookie(cookie)
        let planted = await store.httpCookieStore.allCookies()
        if planted.isEmpty {
            failures.append("cookie 没写进去，后面的清理断言不可信")
        }

        // 3) 删掉它。删账号时 WebView 往往还活着，这一步以前会以 "Data store is in use"
        //    静默失败 —— 不崩，但 profile 一点没清。
        await registry.evict(config: web)
        let remaining = await store.httpCookieStore.allCookies()
        if !remaining.isEmpty {
            failures.append("删掉账号后 cookie 还在（\(remaining.count) 个），profile 没清干净")
        }

        // 4) 删一个没有网页会话的 provider（codex / cursor 那种）。加了就删走的就是这条。
        let apiOnly = ServiceConfig(displayName: "QA API", providerKind: .codex, authMode: .api)
        await registry.evict(config: apiOnly)

        // 5) 连删两次同一个账号，确认墓碑撤掉之后不会出问题。
        await registry.evict(config: neverBuilt)

        return failures
    }
}
