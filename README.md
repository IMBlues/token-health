# Token Health

> macOS 菜单栏里的 AI Token 余额仪表盘，先照顾 Kimi Code / Zhipu Coding 这类有滚动额度的 Coding 套餐。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<p align="center">
  <img src="docs/images/token-health-menu.png" alt="Token Health menu bar screenshot" width="420">
</p>

Token Health 是一个原生 SwiftUI 菜单栏 App，用来把 AI Coding 服务的短周期额度、周额度、重置时间和一些明细用一个小面板看清楚。它不做额度绕过，也不代理你的请求，只是读取你授权后的官方网页/API 数据并展示。

## 已支持

| Provider | 状态 | 能看到什么 | 认证方式 |
| --- | --- | --- | --- |
| Kimi Code | 可用 | 5 小时窗口、周额度、重置倒计时 | Kimi Console Web 登录导入会话，或手动填 Bearer/Cookie |
| Zhipu Coding | 可用 | 5 小时窗口、周额度、MCP 月调用数、近 7 天 token/tool 明细 | BigModel Web 登录导入会话 |
| DeepSeek | 可用 | 余额、今日费用、今日 token / 请求明细 | DeepSeek Platform Web 登录导入会话；API key 模式可读官方余额 |
| Generic HTTP | 可用 | 5 小时窗口、周额度 | 自定义 JSON endpoint，可选 Bearer token |
| Demo | 可用 | 假数据，用来验证 UI | 无需凭证 |
| OpenAI / Anthropic / Cursor | 占位 | 仅在你自己提供兼容 Generic HTTP 的 usage endpoint 时可用 | API endpoint + key |

## 暂不支持

- Windows / Linux / iOS，当前只支持 macOS 14+。
- OpenAI、Anthropic、Cursor 的官方用量接口适配器还没接上。
- 除 Kimi Code / Zhipu Coding / DeepSeek 外，没有通用网页自动登录采集器。
- 多设备同步、云端存储、团队共享面板。
- 自动更新、正式签名和 Apple 公证发布包。
- 绕过额度、破解套餐、模拟付费权限。

## 安装和运行

```bash
git clone https://github.com/IMBlues/token-health.git
cd token-health
swift run TokenHealth
```

运行后会出现在 macOS 菜单栏。点闪电图标打开面板，点齿轮进入设置，添加 Provider 后刷新即可。

## 构建 App

```bash
bash scripts/build-app.sh
open .build/app/TokenHealth.app
```

构建 DMG：

```bash
bash scripts/build-dmg.sh
```

生成的 DMG 在 `dist/` 下。当前构建脚本只做本机 ad-hoc codesign，不是正式公证包。

## 配置说明

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

## 隐私和安全

- Token Health 没有自己的后端服务。
- 请求只会发往对应 Provider 官方接口，或你在 Generic HTTP 中配置的 endpoint。
- API key、Cookie、Web session 等凭证存放在 macOS Keychain。
- 上游网页和内部接口可能变化，Kimi/Zhipu 适配器属于 best effort，失效时欢迎提 issue 或 PR。

## 开发

```bash
swift build
swift run TokenHealth
```

主要代码在 `Sources/TokenHealth/`：

- `StatusMenuView.swift`：菜单栏面板 UI。
- `SettingsView.swift`：Provider 配置 UI。
- `Providers.swift`：各 Provider 拉取和解析逻辑。
- `ConfigStore.swift` / `KeychainStore.swift`：本地配置和凭证存储。

## License

MIT
