# Token Health

> macOS 菜单栏里的 AI Token 余额仪表盘，以及独立的 Windows Electron MVP。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Windows 10/11 x64](https://img.shields.io/badge/Windows-10%2022H2%20%7C%2011%20x64-0078D4)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<p align="center">
  <img src="docs/images/token-health-menu.png" alt="Token Health menu bar screenshot" width="420">
</p>

Token Health 是一个原生 SwiftUI 菜单栏 App，用来把 AI Coding 服务的短周期额度、周额度、重置时间和一些明细用一个小面板看清楚。Provider 卡片默认收起，保留最关键的额度条；点右侧箭头可以展开完整明细。它不做额度绕过，也不代理你的请求，只是读取你授权后的官方网页/API 数据并展示。

## 已支持

| Provider | 状态 | 能看到什么 | 认证方式 |
| --- | --- | --- | --- |
| Codex | 可用 | ChatGPT Codex 账号的短周期、周额度、重置倒计时和独立模型额度桶 | 复用本机 Codex 登录，仅通过官方 App Server 读取额度 |
| Kimi Code | 可用 | 5 小时窗口、周额度、重置倒计时 | Kimi Console Web 登录导入会话，或手动填 Bearer/Cookie |
| Zhipu Coding | 可用 | 5 小时窗口、周额度、MCP 月调用数、近 7 天 token/tool 明细 | BigModel Web 登录导入会话 |
| DeepSeek | 可用 | 余额、今日费用、今日 token / 请求明细 | DeepSeek Platform Web 登录导入会话；API key 模式可读官方余额 |
| MiniMax | 可用 | Token Plan 的 5 小时限额、周限额、视频赠送次数、积分余额、今日/近 7 天 token 明细 | MiniMax Platform Web 登录导入会话 |
| Volcengine Ark | 可用 | Agent Plan 的 5 小时、周、月 AFP 用量和重置时间 | 火山方舟控制台 Web 登录导入会话 |
| Generic HTTP | 可用 | 5 小时窗口、周额度、Token 总额度 | 自定义 JSON endpoint，可选 Bearer token |
| Demo | 可用 | 假数据，用来验证 UI | 无需凭证 |
| OpenAI API / Anthropic / Cursor | 占位 | 仅在你自己提供兼容 Generic HTTP 的 usage endpoint 时可用 | API endpoint + key |

## 暂不支持

- Linux / iOS；macOS 支持 14+，Windows MVP 仅支持 Windows 10 22H2 / Windows 11 x64。
- OpenAI Platform API、Anthropic、Cursor 的官方用量接口适配器还没接上；Codex 的 ChatGPT 套餐额度已单独支持。
- 除 Kimi Code / Zhipu Coding / DeepSeek / MiniMax / Volcengine Ark 外，没有通用网页自动登录采集器。
- 多设备同步、云端存储、团队共享面板。
- 自动更新、正式签名和 Apple 公证发布包。
- 绕过额度、破解套餐、模拟付费权限。

## 安装和运行

可以从 GitHub Releases 下载最新的 `TokenHealth-*.dmg`，拖到 Applications 后运行。

```bash
git clone https://github.com/IMBlues/token-health.git
cd token-health
swift run TokenHealth
```

运行后会出现在 macOS 菜单栏。点闪电图标打开面板，点齿轮进入设置，添加 Provider 后刷新即可。

## 构建 App

```bash
bash scripts/build-app.sh
open ".build/app/Token Health.app"
```

构建 DMG：

```bash
bash scripts/build-dmg.sh
```

生成的 DMG 在 `dist/` 下。当前构建脚本只做本机 ad-hoc codesign，不是正式公证包。

## Windows Electron MVP 0.1.0

Windows 客户端位于 `windows/`，与 macOS Swift 应用独立，仅支持 Windows 10 22H2 / Windows 11 x64。MVP Provider 范围只有：

- **Generic HTTP**：可配置多个 GET JSON endpoint，可选 write-only Bearer token；支持 5h、week、嵌套结构和 token 总额度结构。数字字符串只接受十进制整数，日期只接受严格 ISO 8601；HTTP endpoint 和最终重定向到 HTTP 都会在 ready 卡片显示明文传输警告，跨 origin 重定向不会转发 Bearer。编辑 endpoint 时，origin 改变必须明确替换或清除 token，不能沿用旧 token。
- **Codex**：最多一个，仅读取官方 `codex app-server` 的额度 RPC；不信任 `PATH`，自动发现范围保守，也可通过专用选择器手工选择 `codex.exe`。

Windows 客户端使用 Electron `safeStorage`（Windows DPAPI）保存独立 secret vault；DPAPI 不可用时，已有 secret 的 Provider fail closed，无 token 的公开 Generic HTTP endpoint 仍可请求。渲染进程启用隔离与 sandbox，preload 以 Electron sandbox 支持的 CommonJS `.cjs` 构建，不提供任意 fetch、命令执行或文件读取 IPC。

本地开发（普通测试、typecheck、lint、Electron bundle 可在 macOS 运行）：

```bash
cd windows
npm ci
npm test
npm run typecheck
npm run lint
npm run build
```

正式 NSIS x64 安装包必须在 Windows 上构建：

```powershell
cd windows
npm ci
npm run build:installer
```

目标产物名由 `windows/package.json` 的版本动态生成（当前为 `windows/dist/TokenHealth-Windows-0.1.0-x64-Setup.exe`），是 per-user、非 one-click、允许选择安装目录的 NSIS 安装器。`.github/workflows/windows.yml` 在目标为 `main` 的 PR、任意非 `main` feature 分支 push 和手工触发时执行锁定依赖安装、lint、typecheck、coverage 测试、Electron bundle、CommonJS preload/build smoke、Windows Electron 可执行启动 smoke、安装器构建与 SHA-256，并上传保留 14 天的 artifact；CI 不创建 Release。

### Windows 验收与已知未验证项

当前实现和纯测试可在 macOS 验证，但**不宣称已经在 Windows 实机验证**。Windows 安装器目前未做生产代码签名，下载或启动时可能出现 Microsoft Defender SmartScreen 警告。

Codex 的安全策略要求 Authenticode `Status=Valid`，并对 signer subject 做精确 allowlist。签名通过后记录 SHA-256 与 size/mtime/ctime identity，在 spawn 前立即重新检查 Authenticode 和 identity；自动路径与手工路径使用同一策略。该双检显著缩小 TOCTOU 窗口，但无法完全消除 Windows 路径替换竞争；完全绑定验证对象与启动对象需要额外的 Win32 file handle/helper，MVP 暂接受 fail-closed 双检并把实机竞争测试列为后续加固项。0.1.0 的 exact allowlist 来自 2026-07-16 对 OpenAI 官方 GitHub `openai/codex` Windows x64 release（复核 `rust-v0.104.0` 与当日 latest `rust-v0.144.5`）内嵌签名证书的核验；不使用模糊或子串匹配。Windows 实机仍应确认 PowerShell 返回的 subject 格式及执行行为：

1. 在干净的 Windows 10 22H2 或 Windows 11 x64 上安装 OpenAI 官方 Codex 并登录。
2. 从 Actions 下载安装器和 `.sha256`，运行 `Get-FileHash -Algorithm SHA256` 对照校验后安装。
3. 打开 Settings，添加 Codex；如未自动发现，点 `Select official codex.exe` 选择官方安装目录内文件。
4. 记录 UI 中完整的 `Authenticode` 状态、`Signer subject` 和 exe 路径（可同时运行 `Get-AuthenticodeSignature -LiteralPath '<path>' | Format-List Status,SignerCertificate` 交叉核验）。
5. 如 subject 或行为与当前策略不一致，将完整结果反馈给维护者，先审核并精确更新 `windows/src/main/codex.ts` 的 `APPROVED_CODEX_SIGNER_SUBJECTS`，不可降级执行；随后验证额度、60 秒缓存、自动刷新、tray、开机启动、close-to-tray 和卸载流程。

Windows 手工验收还应覆盖 Generic HTTPS/HTTP、Bearer 保存后重启、DPAPI 正常与不可用诊断、重定向、超限响应、单实例、左/右键 tray 菜单，以及 Windows 10/11 各一台 x64 环境。

## 配置说明

### Codex

添加计划后选择 `Codex`：

- 需要本机已经安装 OpenAI 官方签名的 ChatGPT 或 Codex 桌面端，并在 Codex 中通过 ChatGPT 账号登录。为避免执行被替换的程序，Token Health 不会自动运行 `PATH` 中的第三方或未签名 Codex CLI。
- Token Health 启动一个短生命周期的官方 `codex app-server` 子进程，只发送初始化握手和 `account/rateLimits/read`，不调用登录、登出、历史用量、额度重置、任务或文件接口。
- 自动刷新沿用全局 15 分钟间隔；一分钟内的重复 Codex 刷新复用最近结果或错误，不会连续启动额度查询。
- Token Health 不读取、复制或保存 Codex 登录凭证；凭证加载与必要的会话刷新仍由 Codex 自己管理。
- OpenAI API key 的按量计费与 ChatGPT Codex 套餐额度是两套体系，不会混在这个 Provider 中。

### Kimi Code

添加计划后选择 `Kimi Code`：

- 推荐点 `Login with Kimi Code`，在官方 Kimi Console 完成登录，然后点击导入会话。
- 也可以手动粘贴 Kimi Web Bearer token 或 `cookie:...` 到 API key 字段。
- 默认请求 Kimi Console 的用量接口；如果填了自定义 endpoint，则按 Generic HTTP 的 JSON 结构解析。

### Zhipu Coding

添加计划后选择 `Zhipu Coding`：

- 点 `Login with Zhipu Coding`，在 BigModel 用量页完成登录，然后导入会话。
- 会尝试读取套餐名、5 小时额度、周额度、MCP 月额度，以及近 7 天 token/tool 统计。

### DeepSeek

添加计划后选择 `DeepSeek`：

- 推荐把 `Auth` 切到 `Login`，点 `Login with DeepSeek`，在官方 DeepSeek Platform 完成登录并等用量页加载，然后导入会话。
- 会展示账户余额、今日费用、今日 token 和请求数，并把按模型拆分的今日明细放在详情里。
- 余额和今日费用默认会显示为 `¥¥¥`，需要点击旁边的小眼睛才会展开真实金额。
- 如果使用 `API` 模式，只会调用 DeepSeek 官方公开的 `/user/balance` 余额接口；官方公开文档暂未提供今日用量接口。

### MiniMax

添加计划后选择 `MiniMax`：

- 点 `Login with MiniMax`，在官方 MiniMax Platform 完成登录并等用量页加载，然后导入会话。
- 会展示 Token Plan 的 5 小时请求限额、周请求限额、视频赠送次数、积分余额、今日 token、近 7 天 token，以及今日 TOP 模型明细。

### Volcengine Ark

添加计划后选择 `Volcengine Ark`：

- 点 `Login with Volcengine Ark`，在火山方舟 Agent Plan 页面完成登录并等用量统计加载，然后导入会话。
- 会展示 Agent 燃料值（AFP）的近 5 小时、近一周、近一月用量和重置时间。

### Provider 排序

在 Settings 左侧列表里拖动 Provider 行右侧的排序柄，可以手动调整菜单面板中的展示顺序。排序会保存到本机配置。

### 用量上报 Hook

Settings 左侧的 `Usage reporting` 可以把一个或多个指定 Provider 的 `5h` / `week` 额度快照合并到同一次 POST 中，发送到自定义 HTTPS 端点。它支持 Bearer token、幂等键和可选的精确证书 SHA-256 pin，可随刷新自动上报，也可用 `Report now` 手动发送；上报失败不会影响本地额度刷新。

Provider 凭据和 Hook token 会合并保存在一个 macOS Keychain vault 中，避免安装后按 Provider 反复弹出钥匙串授权。

### Generic HTTP

如果你有自己的用量服务，可以让它返回下面这种 JSON：

```json
{
  "fiveHours": {
    "used": 12000,
    "limit": 50000,
    "resetAt": "2026-07-02T12:00:00Z"
  },
  "week": {
    "used": 240000,
    "limit": 900000,
    "resetAt": "2026-07-06T00:00:00Z"
  }
}
```

字段名也兼容部分 snake_case 和嵌套形态，详见 `UsageJSONParser`。

也支持带 `data` 包装的总额度响应：

```json
{
  "code": true,
  "data": {
    "name": "Example User",
    "total_available": 298665817,
    "total_granted": 300803492,
    "total_used": 2137675,
    "unlimited_quota": false,
    "expires_at": 0
  },
  "message": "ok"
}
```

菜单卡片会显示已用比例（例如 `0.71%`）及对应进度；展开 Provider 后，会在进度条下方显示完整的 `2,137,675 / 300,803,492 tokens`。`data.name` 会显示在 Provider 副标题中。若没有 `total_granted`，会使用 `total_used + total_available` 推导总额度；若总额度未知、为 0 或为无限额度，则回退显示已使用的 Token 数量。

## 隐私和安全

- Token Health 没有自己的后端服务。
- 请求只会发往对应 Provider 官方接口、你在 Generic HTTP 中配置的 endpoint，或你显式启用的用量上报 Hook。
- Codex Provider 通过本机官方 App Server 的私有 stdio 通道发送初始化与额度读取 RPC，并显式关闭该子进程的插件、Apps 和 analytics 功能；Codex 自身仍负责会话加载和必要刷新。
- macOS 客户端的 API key、Cookie、Web session 等凭证存放在 macOS Keychain。
- Windows 客户端的 Bearer token 存放在 Electron `safeStorage`（Windows DPAPI）加密的独立 vault 中，只可显式保留、覆盖或清除，不通过 IPC 或 UI 回读；DPAPI 不可用时只有依赖已有/新 secret 的操作 fail closed，无 token 的公开 endpoint 可继续使用。
- Codex App Server 协议以及其他 Provider 的上游网页和内部接口都可能演进；这些适配器属于 best effort，失效时欢迎提 issue 或 PR。

## 开发

```bash
swift build
swift run TokenHealth
```

主要代码：

- macOS Swift 应用在 `Sources/TokenHealth/`。
- Windows Electron MVP 在 `windows/src/main`、`windows/src/preload`、`windows/src/renderer`、`windows/src/shared`。

macOS 关键文件：

- `StatusMenuView.swift`：菜单栏面板 UI。
- `SettingsView.swift`：Provider 配置 UI。
- `Providers.swift`：各 Provider 拉取和解析逻辑。
- `UsageReporter.swift`：可配置用量上报 Hook、payload 映射和 HTTP 请求。
- `ConfigStore.swift` / `KeychainStore.swift`：本地配置和凭证存储。

## License

MIT
