import Foundation

/// Antigravity 本机的语言服务器。
///
/// 界面上那份额度是它给的，而它的上游调用我们复现不出来：同一个 host、同一个 `project`、
/// 同一个 User-Agent，Google 的 `retrieveUserQuotaSummary` 只回两个组，而它回三个 ——
/// 多出来的 `Gemini 4 Argon` 那一池在 `fetchAvailableModels`、`retrieveUserQuota` 和
/// `retrieveUserQuotaSummary` 的任何一个响应里都搜不到。所以这一池只能从它这儿拿。
///
/// 拿不到也不影响别的：调用方拿不到就退回直连，少一根条子而已。
enum AntigravityLocalQuota {
    /// 语言服务器自己的 HTTP 服务路径。它同时给界面提供同一份数据。
    static let path = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    struct Session: Equatable, Sendable {
        /// 请求要带 `X-Codeium-Csrf-Token`，否则一律 401，值就在进程命令行里。
        var csrfToken: String
        /// 它同时开着 HTTPS 和另一个明文口，而命令行里只写了 `--https_server_port 0`（动态分配），
        /// 所以哪个是 HTTPS 得挨个试。
        var ports: [Int]
    }

    /// 从命令行里取 CSRF token。`--csrf_token` 后面没跟值（或者跟的是下一个选项）就当没有。
    static func csrfToken(fromArguments arguments: String) -> String? {
        let fields = arguments.split(separator: " ").map(String.init)
        guard let flag = fields.firstIndex(of: "--csrf_token") else {
            return nil
        }
        let value = fields.index(after: flag)
        guard value < fields.endIndex else {
            return nil
        }
        let token = fields[value]
        return token.hasPrefix("--") ? nil : token
    }

    /// 从 `lsof` 的输出里取所有回环监听端口，按出现顺序。
    static func listeningPorts(fromLsof output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") where line.contains("LISTEN") {
            guard let marker = line.range(of: "127.0.0.1:") else {
                continue
            }
            let digits = line[marker.upperBound...].prefix { $0.isNumber }
            guard let port = Int(digits), !ports.contains(port) else {
                continue
            }
            ports.append(port)
        }
        return ports
    }

    /// 本机服务把它包在 `response` 里，而解析器认的是里面那一层。
    ///
    /// 认不出来就返回 nil 而不是原样透传：调用方会挨个试端口，撞上别的服务时它回的可能也是
    /// 一个 200 和一个合法的 JSON —— 收下来的话，「这不是额度」就变成了「这个账号没有额度」。
    static func unwrapped(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (root["response"] as? [String: Any]) ?? root
        guard payload["groups"] is [Any] else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - 找到它

    /// lsof 的选择条件是**或**关系，`-a` 才把它变成**与**。少了它，`-p <pid>` 和 `-iTCP`
    /// 会各算各的，输出里就是这台机器上所有监听端口。
    static let lsofArguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN"]

    /// 跑着的语言服务器会话；没跑、或者参数形状变了，就是 nil。
    static func liveSession() -> Session? {
        guard let running = runningProcess(),
              let token = csrfToken(fromArguments: running.arguments) else {
            return nil
        }
        let listing = run("/usr/sbin/lsof", ["-p", "\(running.pid)"] + lsofArguments) ?? ""
        let ports = listeningPorts(fromLsof: listing)
        guard !ports.isEmpty else {
            return nil
        }
        return Session(csrfToken: token, ports: ports)
    }

    private static func runningProcess() -> (pid: Int, arguments: String)? {
        guard let output = run("/bin/ps", ["-eo", "pid,args"]) else {
            return nil
        }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("language_server"), line.contains("--csrf_token"),
                  let separator = line.firstIndex(of: " "),
                  let pid = Int(line[line.startIndex..<separator]) else {
                continue
            }
            return (pid, String(line[separator...]))
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 语言服务器用的自签证书系统默认会拒。这个委托只对回环地址放行，而且只挂在下面这个
    /// session 上 —— App 里别的请求走的还是普通的 `URLSession`，不因此放宽任何东西。
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration, delegate: LocalhostTrust(), delegateQueue: nil)
    }()
}

private final class LocalhostTrust: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        guard host == "127.0.0.1" || host == "localhost",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
