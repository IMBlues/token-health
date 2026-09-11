# Token Health

> **你的 AI 额度，抬眼就懂。**
>
> 原生 macOS 菜单栏仪表盘，给正在写代码的人。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<p align="center">
  <img src="docs/images/token-health-menu.png" alt="Token Health menu bar screenshot" width="420">
</p>

Token Health 读取官方用量，压成几张清爽的小卡片。不开代理，不碰请求，不做额度魔法，也没有自建后端。

## 支持的服务

| Provider | 你能看到 |
| --- | --- |
| **Codex** | 短周期、周额度、模型额度桶、重置倒计时 |
| **Cursor** | 月度 Auto + Composer、API、Grokbot 用量 |
| **Kimi Code** | 5 小时、周额度 |
| **Zhipu Coding** | 5 小时、周额度、MCP 月额度、token/tool 明细 |
| **DeepSeek** | 余额、今日费用、token 与请求明细 |
| **MiniMax** | 5 小时、周额度、视频赠送、积分、token 明细 |
| **Volcengine Ark** | 5 小时、周、月 AFP 用量 |
| **OpenCode Go** | 5 小时、周、月美元额度 |
| **Generic HTTP** | 自定义 JSON 用量接口 |
| **Demo** | 用来试 UI 的安全假数据 |

凭证留在 macOS Keychain。Provider 会话只读，并且只发往对应服务的官方接口。

## 安装

从 [Releases](https://github.com/IMBlues/token-health/releases) 下载最新 DMG，把 **Token Health.app** 拖进 Applications，启动后它会安静地待在菜单栏。

## 从源码运行

```bash
git clone https://github.com/IMBlues/token-health.git
cd token-health
swift run TokenHealth
```

## 构建

```bash
# 构建并启动 App
bash scripts/build-app.sh
open ".build/app/Token Health.app"

# 构建可分发 DMG
bash scripts/build-dmg.sh
```

本机构建使用 ad-hoc 签名，未经过 Apple 公证。

## 使用

点齿轮添加 Provider，按提示登录，刷新即可。网页型服务从官方控制台导入会话；API 型服务在设置里填 key。

### Cursor

Token Health 从 Cursor 本地 `state.vscdb` 只读读取 access token，然后请求 Cursor 用量接口。接口提供独立数值时显示 Auto + Composer、API、Grokbot；如果 Cursor 把 Grokbot 合并进 Auto，会明确显示 **Grokbot (included in Auto)**，不会无声消失。

### OpenCode Go

支持 API key 或内置控制台登录，展示 Go 订阅的 5 小时（$12）、周（$30）、月（$60）额度。

### Generic HTTP

让你的接口返回这样的用量对象即可：

```json
{
  "fiveHours": { "used": 12000, "limit": 50000, "resetAt": "2026-07-02T12:00:00Z" },
  "week": { "used": 240000, "limit": 900000, "resetAt": "2026-07-06T00:00:00Z" }
}
```

## 隐私

- 没有 Token Health 服务端，也没有云端同步。
- 凭证保存在 macOS Keychain。
- 请求只会发往你选择的 Provider，或你明确配置的 Generic HTTP / 上报接口。
- 只展示用量，不绕过限制、不伪造付费权限、不代理模型请求。

## 开发

```bash
swift build
swift test
```

这是一个小而原生的 SwiftUI 项目。入口从 `Sources/TokenHealth/StatusMenuView.swift`、`SettingsView.swift` 和各 Provider 实现开始。

## License

MIT
