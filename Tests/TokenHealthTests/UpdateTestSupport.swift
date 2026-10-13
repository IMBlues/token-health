import Foundation
@testable import TokenHealth

/// 检查更新的测试替身。和 `CursorTestSupport` 那些一样，抽出来给多个测试文件共用。
struct StubUpdateChecker: UpdateChecking {
    let release: AppRelease?
    var error: (any Error & Sendable)?

    func latestRelease() async throws -> AppRelease {
        if let error { throw error }
        guard let release else { throw UpdateError.malformedRelease("no stub release") }
        return release
    }
}

struct StubUpdateDownloader: UpdateDownloading {
    let result: URL?
    var error: (any Error & Sendable)?

    func download(_ release: AppRelease, into directory: URL) async throws -> URL {
        if let error { throw error }
        guard let result else { throw UpdateError.malformedRelease("no stub download") }
        return result
    }
}

enum UpdateTestData {
    static func release(_ tag: String) -> AppRelease {
        AppRelease(
            tagName: tag,
            version: AppVersion(tag),
            dmg: DMGAsset(
                name: "TokenHealth-\(tag).dmg",
                url: URL(string: "https://example.com/download/TokenHealth-\(tag).dmg")!
            ),
            pageURL: URL(string: "https://example.com/release")!
        )
    }

    @MainActor
    static func store(
        currentVersion: String = "1.0.8",
        latest: AppRelease? = nil,
        checkError: (any Error & Sendable)? = nil,
        downloadsDirectory: URL = URL(fileURLWithPath: "/tmp/token-health-tests"),
        downloaded: URL? = nil,
        downloadError: (any Error & Sendable)? = nil,
        openFile: @escaping (URL) -> Void = { _ in }
    ) -> UpdateStore {
        UpdateStore(
            currentVersion: currentVersion,
            checker: StubUpdateChecker(release: latest, error: checkError),
            downloader: StubUpdateDownloader(result: downloaded, error: downloadError),
            downloadsDirectory: downloadsDirectory,
            openFile: openFile
        )
    }
}
