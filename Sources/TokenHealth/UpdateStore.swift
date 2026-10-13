import AppKit
import Foundation

/// 形如 `1.0.8` 的版本号。
///
/// 只取开头的数字分量，`v1.0.9`、`1.0.9-beta.2` 都当 `[1, 0, 9]`。按字符串比是不行的：
/// `"1.0.10" < "1.0.9"` 在字符串序里成立，那正好是「有新版本却提示已是最新」的方向。
struct AppVersion: Comparable, Equatable, Sendable {
    let raw: String
    let components: [Int]

    init(_ raw: String) {
        self.raw = raw
        components = Self.components(in: raw)
    }

    /// 取开头那段「数字.数字.数字」。碰到第一个非数字与非点的字符就停（`-beta` 之类）。
    private static func components(in raw: String) -> [Int] {
        var parsed: [Int] = []
        var current = ""
        var hasDigit = false
        for character in raw {
            if character.isNumber {
                current.append(character)
                hasDigit = true
            } else if character == "." || character == "-" || character == "_" {
                if hasDigit {
                    parsed.append(Int(current) ?? 0)
                    current = ""
                    hasDigit = false
                    // `-` 之后是预发布标记，不是版本分量。
                    if character != "." { break }
                }
            } else if hasDigit {
                break
            }
        }
        if hasDigit {
            parsed.append(Int(current) ?? 0)
        }
        return parsed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

/// 一次 GitHub 发布里我们关心的东西。
struct AppRelease: Equatable, Sendable {
    let tagName: String
    let version: AppVersion
    let dmg: DMGAsset
    let pageURL: URL
}

struct DMGAsset: Equatable, Sendable {
    let name: String
    let url: URL
}

enum UpdateError: LocalizedError, Equatable {
    case malformedRelease(String)
    case noDMGAsset
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .malformedRelease(detail):
            "GitHub release 解析失败：\(detail)"
        case .noDMGAsset:
            "这个 release 里没有 .dmg"
        case let .badStatus(code):
            "GitHub 返回 HTTP \(code)"
        }
    }
}

protocol UpdateChecking: Sendable {
    func latestRelease() async throws -> AppRelease
}

/// 从 GitHub 的 latest release 拿最新 dmg。
///
/// 抽 `fetch` 出来是为了让解析与状态码分支能在测试里不碰网络。
struct GitHubReleaseChecker: UpdateChecking {
    static let endpoint = URL(string: "https://api.github.com/repos/IMBlues/token-health/releases/latest")!

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var fetch: Fetch = { request in
        try await URLSession.shared.data(for: request)
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenHealth", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }
        return try Self.release(from: data)
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    static func release(from data: Data) throws -> AppRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.malformedRelease(error.localizedDescription)
        }
        guard let asset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.noDMGAsset
        }
        return AppRelease(
            tagName: payload.tagName,
            version: AppVersion(payload.tagName),
            dmg: DMGAsset(name: asset.name, url: asset.browserDownloadURL),
            pageURL: payload.htmlURL
        )
    }
}

protocol UpdateDownloading: Sendable {
    func download(_ release: AppRelease, into directory: URL) async throws -> URL
}

/// 把 dmg 落到目标目录。同名文件直接覆盖 —— 用户点的就是「把最新的拿下来」。
struct UpdateDownloader: UpdateDownloading {
    typealias Fetch = @Sendable (URL) async throws -> (URL, URLResponse)

    var fetch: Fetch = { url in
        try await URLSession.shared.download(from: url)
    }

    func download(_ release: AppRelease, into directory: URL) async throws -> URL {
        let (temporary, response) = try await fetch(release.dmg.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }

        let destination = directory.appendingPathComponent(release.dmg.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// 检查更新、下载 dmg、交给系统打开。AppState 拥有它，设置页观察它。
@MainActor
final class UpdateStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case updateAvailable(AppRelease)
        case downloading(AppRelease)
        case downloaded(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let currentVersion: AppVersion

    private let checker: any UpdateChecking
    private let downloader: any UpdateDownloading
    private let downloadsDirectory: URL
    private let openFile: (URL) -> Void

    init(
        currentVersion: String = UpdateStore.bundleVersion,
        checker: any UpdateChecking = GitHubReleaseChecker(),
        downloader: any UpdateDownloading = UpdateDownloader(),
        downloadsDirectory: URL = UpdateStore.userDownloadsDirectory,
        openFile: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.currentVersion = AppVersion(currentVersion)
        self.checker = checker
        self.downloader = downloader
        self.downloadsDirectory = downloadsDirectory
        self.openFile = openFile
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var userDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// 这一版是不是新的。解析不出分量的 tag 一律不算更新 —— 宁可漏报，不可误报。
    func isNewerThanCurrent(_ release: AppRelease) -> Bool {
        !release.version.components.isEmpty && currentVersion < release.version
    }

    func check() async {
        state = .checking
        do {
            let release = try await checker.latestRelease()
            state = isNewerThanCurrent(release)
                ? .updateAvailable(release)
                : .upToDate(latest: release.tagName)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 下载并打开 dmg 让用户自己拖进 /Applications —— App 不碰自己的安装目录。
    func downloadAndOpen() async {
        guard case let .updateAvailable(release) = state else {
            return
        }
        state = .downloading(release)
        do {
            let file = try await downloader.download(release, into: downloadsDirectory)
            openFile(file)
            state = .downloaded(file)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
