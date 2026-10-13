import Foundation
import Testing
@testable import TokenHealth

/// 版本号比较。
///
/// 按字符串比会得出 `1.0.10 < 1.0.9` —— 那正好是「有新版本却提示已是最新」的方向，
/// 所以这一层必须按分量比。
struct AppVersionTests {
    @Test
    func comparesEachComponentAsANumber() {
        #expect(AppVersion("1.0.9") < AppVersion("1.0.10"))
        #expect(AppVersion("1.2.0") < AppVersion("1.10.0"))
        #expect(!(AppVersion("1.0.10") < AppVersion("1.0.9")))
    }

    @Test
    func equalVersionsAreNotLessThanEachOther() {
        #expect(!(AppVersion("1.0.8") < AppVersion("1.0.8")))
        #expect(AppVersion("1.0.8") == AppVersion("1.0.8"))
    }

    /// 短的一方缺的分量按 0 算：`1.1` 和 `1.1.0` 是同一版。
    @Test
    func missingComponentsCountAsZero() {
        #expect(!(AppVersion("1.1") < AppVersion("1.1.0")))
        #expect(!(AppVersion("1.1.0") < AppVersion("1.1")))
        #expect(AppVersion("1.1") < AppVersion("1.1.1"))
    }

    /// tag 上带 `v` 前缀、或者带 `-beta` 这类后缀都不该让解析结果变成「老版本」。
    @Test
    func toleratesTagDecoration() {
        #expect(AppVersion("v1.0.9").components == [1, 0, 9])
        #expect(AppVersion("1.0.9-beta.2").components == [1, 0, 9])
        #expect(AppVersion("v1.0.9") < AppVersion("v1.0.10"))
    }

    /// 解析不出数字的 tag（`nightly` 之类）没有分量，按全 0 处理，因此永远不比当前版本新。
    @Test
    func anUnparseableTagNeverLooksNewer() {
        #expect(AppVersion("nightly").components.isEmpty)
        #expect(!(AppVersion("1.0.8") < AppVersion("nightly")))
    }
}

/// GitHub release 的解析。
struct GitHubReleaseCheckerTests {
    @Test
    func picksTheDmgAsset() throws {
        let release = try GitHubReleaseChecker.release(from: Self.payload)

        #expect(release.version == AppVersion("1.0.9"))
        #expect(release.dmg.name == "TokenHealth-1.0.9.dmg")
        #expect(release.dmg.url.absoluteString == "https://example.com/download/TokenHealth-1.0.9.dmg")
    }

    /// 一个 release 里没有 dmg 就没得更新，得报错而不是返回一个没有下载地址的「新版本」。
    @Test
    func refusesAReleaseWithoutADmg() throws {
        let json = """
        {"tag_name":"1.0.9","html_url":"https://example.com/release","assets":[
          {"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt","size":12}
        ]}
        """.data(using: .utf8)!

        #expect(throws: UpdateError.self) {
            try GitHubReleaseChecker.release(from: json)
        }
    }

    @Test
    func surfacesAHTTPFailure() async {
        let checker = GitHubReleaseChecker(fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })

        await #expect(throws: URLError.self) {
            try await checker.latestRelease()
        }
    }

    @Test
    func rejectsANonSuccessStatus() async {
        let checker = GitHubReleaseChecker(fetch: { _ in
            (Self.payload, HTTPURLResponse(url: GitHubReleaseChecker.endpoint, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })

        await #expect(throws: UpdateError.self) {
            try await checker.latestRelease()
        }
    }

    static let payload = """
    {
      "tag_name": "1.0.9",
      "html_url": "https://example.com/release",
      "assets": [
        {"name": "TokenHealth-1.0.9.dmg", "browser_download_url": "https://example.com/download/TokenHealth-1.0.9.dmg", "size": 2443825},
        {"name": "TokenHealth-1.0.9.dmg.sha256", "browser_download_url": "https://example.com/download/TokenHealth-1.0.9.dmg.sha256", "size": 64}
      ]
    }
    """.data(using: .utf8)!
}

@MainActor
struct UpdateStoreTests {
    private func makeStore(
        latest: AppRelease?,
        currentVersion: String = "1.0.8",
        error: (any Error & Sendable)? = nil,
        downloaded: URL? = nil,
        downloadsDirectory: URL = URL(fileURLWithPath: "/tmp/token-health-tests"),
        opened: @escaping (URL) -> Void = { _ in }
    ) -> UpdateStore {
        UpdateStore(
            currentVersion: currentVersion,
            checker: StubUpdateChecker(release: latest, error: error),
            downloader: StubUpdateDownloader(result: downloaded ?? downloadsDirectory.appendingPathComponent("TokenHealth-1.0.9.dmg")),
            downloadsDirectory: downloadsDirectory,
            openFile: opened
        )
    }

    /// 解析不出分量的 tag 不该被当成「有新版本」，否则界面会一直挂着一个点不动的更新。
    @Test
    func anUnparseableTagIsNotOfferedAsAnUpdate() async {
        let store = makeStore(latest: Self.release("nightly"))

        await store.check()

        #expect(store.state == .upToDate(latest: "nightly"))
    }

    @Test
    func reportsUpToDateWhenTheReleaseMatchesTheRunningVersion() async {
        let store = makeStore(latest: Self.release("1.0.8"))

        await store.check()

        #expect(store.state == .upToDate(latest: "1.0.8"))
    }

    @Test
    func reportsAnAvailableUpdateWhenTheReleaseIsNewer() async {
        let store = makeStore(latest: Self.release("1.0.9"))

        await store.check()

        #expect(store.state == .updateAvailable(Self.release("1.0.9")))
    }

    /// 装的是更新的版本（比如自己 build 的 dev 版）时不该提示「有更新」。
    @Test
    func reportsUpToDateWhenTheRunningVersionIsNewer() async {
        let store = makeStore(latest: Self.release("1.0.7"), currentVersion: "1.0.8")

        await store.check()

        #expect(store.state == .upToDate(latest: "1.0.7"))
    }

    @Test
    func surfacesAFailureInsteadOfPretendingNothingHappened() async {
        let store = makeStore(latest: nil, error: URLError(.timedOut))

        await store.check()

        guard case .failed = store.state else {
            Issue.record("期望 .failed，实际是 \(store.state)")
            return
        }
    }

    @Test
    func downloadingOpensTheDmgAndRemembersWhereItLanded() async {
        let directory = URL(fileURLWithPath: "/tmp/token-health-tests-download")
        let dmg = directory.appendingPathComponent("TokenHealth-1.0.9.dmg")
        var opened: [URL] = []
        let store = makeStore(latest: Self.release("1.0.9"), downloaded: dmg, downloadsDirectory: directory, opened: { opened.append($0) })

        await store.check()
        await store.downloadAndOpen()

        #expect(opened == [dmg])
        #expect(store.state == .downloaded(dmg))
    }

    /// 下载失败就得说失败，而不是留一句「已下载」。
    @Test
    func aFailedDownloadIsReported() async {
        let store = UpdateStore(
            currentVersion: "1.0.8",
            checker: StubUpdateChecker(release: Self.release("1.0.9"), error: nil),
            downloader: StubUpdateDownloader(result: nil, error: URLError(.networkConnectionLost)),
            downloadsDirectory: URL(fileURLWithPath: "/tmp/token-health-tests"),
            openFile: { _ in Issue.record("下载失败时不该打开任何东西") }
        )

        await store.check()
        await store.downloadAndOpen()

        guard case .failed = store.state else {
            Issue.record("期望 .failed，实际是 \(store.state)")
            return
        }
    }

    /// 没查过（或已是最新）时点「下载」不该做任何事。
    @Test
    func downloadDoesNothingWithoutAnAvailableUpdate() async {
        var opened: [URL] = []
        let store = makeStore(latest: Self.release("1.0.8"), opened: { opened.append($0) })

        await store.check()
        await store.downloadAndOpen()

        #expect(opened.isEmpty)
        #expect(store.state == .upToDate(latest: "1.0.8"))
    }

    static func release(_ tag: String) -> AppRelease {
        UpdateTestData.release(tag)
    }
}
