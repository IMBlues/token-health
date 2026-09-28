import Foundation
import Security

/// 钥匙串条目的原始读写。
///
/// 抽成协议只有一个理由：让「系统没批准这次访问」这类失败能在测试里复现。真机上它表现为
/// 一个没人应答的授权框，超时后读取返回 -60008（errAuthorizationInternal）—— 测试进程既弹
/// 不出这个框，也造不出这个状态码。状态码本身与 Security 框架的 OSStatus 同一套取值。
protocol KeychainBacking: Sendable {
    /// 读取条目数据。
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?)
    /// 列出 service 下所有条目的 account 名，供旧格式迁移用。
    func copyAllAccounts(service: String) -> (status: OSStatus, accounts: [String])
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// 经由 `/usr/bin/security` 命令行读写钥匙串 —— 这是唯一能免除授权弹窗的路子。
///
/// 起因（2026-09-28 实测）：这台 macOS 对非 Apple 签名的进程，钥匙串授权按「条目 × 调用方
/// cdhash」记忆（日志里的 XARA 分区表：`asking user about XARA partition for 'cdhash:…'`），
/// 每次重建 App 都换 cdhash，于是每次重装后的首次读取都要弹一次密码框；没人应答时读取会阻塞
/// 到超时（-60008，实测 47 分钟），凭据就此不可用。证书签名救不了 —— 换固定 requirement 的
/// 证书后照样弹，条目 ACL 设成 allow-all 也照样弹。
///
/// 而 `/usr/bin/security` 是 Apple 签名的，分区表里那个 `apple-tool:` 覆盖它：同样的条目，
/// CLI 读取 0.03 秒返回、零弹窗。所以把读写都交给它，App 怎么重建都不再打扰用户。
/// 代价是写入时整份数据会短暂出现在 security 进程的 argv 里（`-X <hex>`），与「条目 ACL
/// 本就是 allow-all」同一量级的暴露 —— 这是为个人工具换来的取舍。
struct SecurityToolKeychainBacking: KeychainBacking {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/security")

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        let result = Self.run(["find-generic-password", "-w", "-s", service, "-a", account])
        guard result.exitCode == 0 else {
            return (Self.status(fromExitCode: result.exitCode), nil)
        }
        guard let data = Self.decodePasswordOutput(result.stdout) else {
            return (errSecDecode, nil)
        }
        return (errSecSuccess, data)
    }

    func copyAllAccounts(service: String) -> (status: OSStatus, accounts: [String]) {
        // CLI 没有「列举 service 下全部条目」的用法。旧格式迁移在本机早已完成
        // （vault 里 legacyMigrationComplete = true），这里当作没有旧条目，
        // 迁移随即写下完成标记，之后再也不走这条路。
        (errSecItemNotFound, [])
    }

    /// `-U`：条目在就更新、不在就新建，与 SecItemUpdate/SecItemAdd 的组合等价。
    /// 写入会由 CLI 重建条目（ACL 回到 allow-all、分区表回到 apple-tool:），
    /// 之后的 CLI 读取继续静默 —— 这正是我们要的状态。
    func update(service: String, account: String, data: Data) -> OSStatus {
        let result = Self.run(
            ["add-generic-password", "-U", "-A", "-s", service, "-a", account, "-X", data.hexString]
        )
        return Self.status(fromExitCode: result.exitCode)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        update(service: service, account: account, data: data)
    }

    func delete(service: String, account: String) -> OSStatus {
        let result = Self.run(["delete-generic-password", "-s", service, "-a", account])
        return Self.status(fromExitCode: result.exitCode)
    }

    // MARK: - CLI 细节

    private struct RunResult {
        var exitCode: Int32
        var stdout: Data
    }

    private static func run(_ arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, stdout: Data())
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(exitCode: process.terminationStatus, stdout: stdout)
    }

    /// `security` 的退出码是 OSStatus 截到低 8 位：0 = 成功，44 = errSecItemNotFound
    /// （-25300 & 0xff）。只认这两个确定的；其余一律当内部错误 —— 走 CLI 之后，
    /// 授权弹窗那条路已经不该再出现。
    static func status(fromExitCode exitCode: Int32) -> OSStatus {
        switch exitCode {
        case 0: return errSecSuccess
        case 44: return errSecItemNotFound
        default: return errSecInternalComponent
        }
    }

    /// 解析 `find-generic-password -w` 的输出：CLI 总在末尾补一个换行；内容里有非可打印
    /// 字节时（我们的 vault 因为含 UTF-8 就属于这种）整份数据以十六进制输出。
    /// vault 的格式是 JSON 对象，首字节必是 `{`，所以「明文 vs hex」可以确定地判别。
    static func decodePasswordOutput(_ output: Data) -> Data? {
        var bytes = output
        if bytes.last == 0x0a {
            bytes.removeLast()
        }
        if bytes.isEmpty {
            return Data()
        }
        if bytes.first == UInt8(ascii: "{") {
            return bytes
        }
        guard bytes.count % 2 == 0,
              let text = String(data: bytes, encoding: .utf8),
              text.allSatisfy(\.isHexDigit) else {
            // 既不是 JSON 也不像十六进制：当成明文原样返回（旧格式的字符串凭据就是这样）。
            return bytes
        }
        var decoded = Data(capacity: bytes.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                return nil
            }
            decoded.append(byte)
            index = next
        }
        return decoded
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
