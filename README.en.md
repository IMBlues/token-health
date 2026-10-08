<p align="center">
  <img src="docs/images/token-health-icon.png" alt="Token Health icon" width="128">
</p>

# Token Health

> **Your AI quota, readable at a glance.**
>
> A native macOS menu bar dashboard for people who are busy writing code.

English | [简体中文](README.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<p align="center">
  <img src="docs/images/token-health-menu.png" alt="Token Health menu bar screenshot" width="420">
</p>

Token Health reads your official usage numbers and compresses them into a few clean cards. No proxy, no intercepting requests, no quota magic, no backend of its own.

Pin the accounts you check most to the menu bar, and you can see what's left without opening anything — the provider's official logo on the left, one thin vertical bar per quota window on the right, taller meaning more used. The gourd at the far right is the global entry point:

<p align="center">
  <img src="docs/images/token-health-pinned.png" alt="Pinned accounts in the menu bar, with the gourd entry at the right" width="520">
</p>

## Supported services

| Provider | What you see |
| --- | --- |
| **Codex** | Short window, weekly quota, per-model buckets, reset countdown |
| **Cursor** | Monthly Auto + Composer and API usage, plus Grok Bot's own weekly pool; the token is read from the local `state.vscdb` read-only, with a per-model Grok bot breakdown once pinned |
| **Kimi Code** | 5-hour and weekly quota |
| **Zhipu Coding** | 5-hour and weekly quota, monthly MCP quota, token/tool breakdown |
| **DeepSeek** | Balance, today's cost, token and request breakdown |
| **MiniMax** | 5-hour and weekly quota, gifted video, credits, token breakdown |
| **Volcengine Ark** | 5-hour, weekly, and monthly AFP usage |
| **OpenCode Go** | 5-hour, weekly, and monthly dollar quota |
| **Generic HTTP** | Your own JSON usage endpoint |
| **Demo** | Safe fake data for trying out the UI |

Credentials stay in the macOS Keychain. Provider sessions are read-only and are only ever sent to that service's official endpoint.

The add-provider menu also lists **OpenAI** and **Anthropic** — neither has a built-in adapter yet: API mode takes a usage endpoint you supply yourself (it behaves like Generic HTTP), and console login isn't wired up.

## Install

Download the latest DMG from [Releases](https://github.com/IMBlues/token-health/releases), drag **Token Health.app** into Applications, and launch it — from then on it sits quietly in the menu bar.

## Run from source

```bash
git clone https://github.com/IMBlues/token-health.git
cd token-health
swift run TokenHealth
```

## Build

```bash
# Build and launch the app
bash scripts/build-app.sh
open ".build/app/Token Health.app"

# Build a distributable DMG
bash scripts/build-dmg.sh

# Build the DMG, replace the app in /Applications and relaunch (for your own machine)
bash scripts/install-release.sh
```

Local builds are ad-hoc signed and not notarized by Apple.

## Usage

Click the gear to add a provider, sign in as prompted, and refresh. Web-based services import a session from the official console; API-based ones take a key in settings.

Auto-refresh defaults to every 15 minutes and can be changed under Settings → General → Refresh (30 seconds minimum); opening the menu doesn't trigger a refresh. The first Keychain read makes macOS put up a prompt, and if it gets denied or times out, settings grows a **Retry Keychain Access** button that brings it back — no restart needed.

### Pinning accounts

Turn on **Menu Bar → Pin to menu bar** in settings, or click the pin in the top-right corner of any card in the dropdown. Each pinned account adds one icon to the menu bar: the provider's logo plus one thin bar per quota window, taller meaning more used, the color shifting from green through orange to red as usage climbs, and hovering shows the exact percentage. Click again to unpin. Icons follow the account order, with no limit on how many, and the system lays out the menu bar — ⌘-drag to rearrange.

The gourd is the global entry point (it reads the level inside the gourd, meaning what's left) and is independent of the pinned accounts. Menu bar artwork is black and white only; the bars' green/orange/red is the one color that stays.

Clicking a pinned item opens a detail popover, one level deeper than the card. Only these four have one:

| Pinned account | What the popover adds |
| --- | --- |
| **Codex** | Token totals and a by-day trend, `Lifetime` / `Peak day` / `Streak` / `Longest turn` |
| **Cursor** | Token totals and a by-day trend, the spend split, per-model Grok bot usage |
| **DeepSeek** | Balance and spend totals, a by-day trend, the token breakdown, by-model / by-key splits |
| **OpenCode Go** | Requests / tokens / cost, a by-day cost trend, the input/output breakdown, a by-model split |

Every other account opens a small menu instead (unpin / settings / quit). The popover is display-only: no filtering, no date range, no drill-down. Numbers older than 5 minutes refresh once when you open it, there's a manual refresh in the top-right, and a failed fetch keeps the previous numbers and marks the error.

DeepSeek has no quota ratio, so pinning one shows the balance figure directly, with the display currency (original / CNY / USD) picked in settings — the rate comes from the ECB once a day and falls back to the cache. Quota rows in the popover draw a used-fraction bar tinted with the same thresholds as the menu bar and the cards; DeepSeek's balance rows stay text-only, because balances report what's left and quota windows report what's spent.

### Generic HTTP

Just have your endpoint return a usage object shaped like this:

```json
{
  "fiveHours": { "used": 12000, "limit": 50000, "resetAt": "2026-07-02T12:00:00Z" },
  "week": { "used": 240000, "limit": 900000, "resetAt": "2026-07-06T00:00:00Z" }
}
```

### Usage reporting

**Settings → Integrations → Usage reporting** pushes your usage to an endpoint you host. Turn on **Enabled**, tick the accounts to include, and fill in **Endpoint** (must be `https://`) and **Client ID**; **Bearer token** (stored in the Keychain) and **Pinned certificate SHA-256** (only that certificate is then accepted) are optional. **Report now** sends one immediately, and every full refresh reports once too.

```json
{
  "client_id": "your-client-id",
  "accounts": [
    {
      "provider": "codex",
      "account_ref": "sha256:…",
      "display_name": "Codex · Pro",
      "plan": "Pro",
      "status": "ok",
      "windows": [
        { "name": "5h", "used_percent": 42, "resets_at": "2026-10-08T12:00:00Z" },
        { "name": "week", "used_percent": 18, "resets_at": "2026-10-13T00:00:00Z" }
      ]
    }
  ]
}
```

`account_ref` is the SHA-256 of the account name, so the name itself never leaves the machine. Only the `5h` and `week` windows are reported, clamped to 0–100.

## Privacy

- There is no Token Health server and no cloud sync.
- Credentials are stored in the macOS Keychain.
- Requests go only to the provider you chose, and to the Generic HTTP endpoint and usage-reporting endpoint you filled in yourself.
- It only displays usage: it doesn't bypass limits, fake paid entitlements, or proxy model requests.

## Development

```bash
swift build
bash scripts/test.sh
```

`scripts/test.sh` just feeds the `Testing.framework` path from swift-testing in CommandLineTools to `swift test`.
On a machine without Xcode, running `swift test` directly fails with `no such module 'Testing'`, which looks like broken code but isn't.

### Provider lifecycle QA

```bash
bash scripts/qa-provider-lifecycle.sh
```

Adding and deleting a provider goes through WebKit's per-identifier data stores, and crashes on that path
**slip straight past the unit tests**: a swift-testing process is not a real app bundle, so the very same calls stay
green in tests and only segfault in the real app. So this script really builds the app and really runs, as the app,
the sequence "add a provider, delete it, delete an account that never had a session" — pass or fail is the exit code,
and a crash is a 139.

It copies the built app, swaps in the `local.token-health.qa` bundle id, and runs that, so your own WebKit data stays untouched.

This is a small, native SwiftUI project. The entry point is `Sources/TokenHealth/TokenHealthApp.swift`; the two menu bar surfaces (the gourd's dropdown panel and the pinned account items) are managed by `MenuBarPanelController.swift` and `PinnedStatusItemController.swift`, settings live in `SettingsView.swift`, and the fetching implementations are in `Providers.swift` and the handful of `*UsageProvider.swift` files.

## License

MIT
