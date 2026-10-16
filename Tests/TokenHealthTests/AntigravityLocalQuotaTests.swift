import Foundation
import Testing
@testable import TokenHealth

struct AntigravityLocalQuotaTests {
    /// 反重力真实的 language server 命令行（`ps -eo pid,args` 里那一行的后半段）。
    private let arguments = """
    /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
    --override_ide_name antigravity --subclient_type hub --override_ide_version 2.23.1 \
    --override_user_agent_name antigravity --https_server_port 0 \
    --csrf_token 9423ec58-8ef6-4361-b53e-b9408e732b98 --app_data_dir antigravity \
    --api_server_url https://generativelanguage.googleapis.com \
    --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com
    """

    @Test
    func theCsrfTokenComesOutOfTheCommandLine() {
        #expect(
            AntigravityLocalQuota.csrfToken(fromArguments: arguments)
                == "9423ec58-8ef6-4361-b53e-b9408e732b98"
        )
    }

    @Test
    func aCommandLineWithoutATokenHasNoSession() {
        #expect(AntigravityLocalQuota.csrfToken(fromArguments: "--standalone --https_server_port 0") == nil)
    }

    @Test
    func theTokenIsNotTakenFromTheFlagNameItself() {
        // `--csrf_token` 后面必须真的跟一个值；把它自己当成值会让请求带着一串垃圾去 401。
        #expect(AntigravityLocalQuota.csrfToken(fromArguments: "--csrf_token") == nil)
        #expect(AntigravityLocalQuota.csrfToken(fromArguments: "--csrf_token --standalone") == nil)
    }

    /// `lsof -nP -p <pid> -iTCP -sTCP:LISTEN` 的真实输出形状。
    private let lsof = """
    COMMAND     PID       USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    language_ 73068 amazingblues    7u  IPv4 0x458f247208b4d4be      0t0  TCP 127.0.0.1:63521 (LISTEN)
    language_ 73068 amazingblues    8u  IPv4 0xec14160691dacf40      0t0  TCP 127.0.0.1:63522 (LISTEN)
    """

    @Test
    func everyListeningPortIsOffered() {
        // 哪个端口是 HTTPS 没写在输出里 —— 语言服务器同时开着 HTTPS 和另一个明文口，
        // 所以两个都返回，由调用方挨个试。
        #expect(AntigravityLocalQuota.listeningPorts(fromLsof: lsof) == [63521, 63522])
    }

    @Test
    func aProcessListeningOnNothingHasNoPorts() {
        #expect(AntigravityLocalQuota.listeningPorts(fromLsof: "COMMAND PID USER FD TYPE\n") == [])
    }

    @Test
    func theResponseIsUnwrappedBeforeParsing() throws {
        // 本机服务把它包在 `response` 里，而解析器认的是里面那一层。
        let wrapped = Data(#"""
        {"response":{"groups":[{"displayName":"Gemini 4 Argon","buckets":[
          {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.030046133,
           "resetTime":"2026-10-23T06:38:56Z"}]}]}}
        """#.utf8)

        let unwrapped = try #require(AntigravityLocalQuota.unwrapped(wrapped))
        let usages = try GoogleAIQuotaParser.summary(from: unwrapped).usages

        #expect(usages.map(\.label) == ["Gemini 4 Argon Week"])
        #expect(usages.map(\.used) == [97])
    }

    @Test
    func aPayloadThatIsNotWrappedIsPassedThroughAsIs() throws {
        let plain = Data(#"{"groups":[]}"#.utf8)

        #expect(AntigravityLocalQuota.unwrapped(plain) == plain)
    }

    @Test
    func aPayloadWithoutGroupsIsNotASummary() {
        // 挨个试端口时会撞上别的服务：只要它回 200 就收下，会把「返回了但没内容」当成
        // 「这个账号一条额度都没有」。认不出来就当这个端口不是它。
        #expect(AntigravityLocalQuota.unwrapped(Data(#"{"hello":"world"}"#.utf8)) == nil)
        #expect(AntigravityLocalQuota.unwrapped(Data(#"{"response":{"nope":1}}"#.utf8)) == nil)
    }

    @Test
    func thePortLookupAsksForOneProcessOnly() {
        // lsof 的选择条件是**或**关系：少了 `-a` 它会把这台机器上所有进程的监听端口都列出来，
        // 于是「候选端口」变成几十个，挨个去试。
        #expect(AntigravityLocalQuota.lsofArguments.contains("-a"))
    }
}
