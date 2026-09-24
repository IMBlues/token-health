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
| **Cursor** | Monthly Auto + Composer, API, and Grokbot usage |
| **Kimi Code** | 5-hour and weekly quota |
| **Zhipu Coding** | 5-hour and weekly quota, monthly MCP quota, token/tool breakdown |
| **DeepSeek** | Balance, today's cost, token and request breakdown |
| **MiniMax** | 5-hour and weekly quota, gifted video, credits, token breakdown |
| **Volcengine Ark** | 5-hour, weekly, and monthly AFP usage |
| **OpenCode Go** | 5-hour, weekly, and monthly dollar quota |
| **Generic HTTP** | Your own JSON usage endpoint |
| **Demo** | Safe fake data for trying out the UI |

Credentials stay in the macOS Keychain. Provider sessions are read-only and are only ever sent to that service's official endpoint.

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
```

Local builds are ad-hoc signed and not notarized by Apple.

## Usage

Click the gear to add a provider, sign in as prompted, and refresh. Web-based services import a session from the official console; API-based ones take a key in settings.

The top of the menu shows how long ago the last refresh happened (`2/2 updated · 3m ago`). Auto-refresh defaults to every 15 minutes, and opening the menu doesn't trigger a refresh; change the interval under Settings → General → Refresh, down to a minimum of 30 seconds.

### Cursor

Token Health reads the access token from Cursor's local `state.vscdb` (read-only), then calls Cursor's usage endpoint. When the endpoint reports them separately, Auto + Composer, API, and Grokbot each get their own number; if Cursor folds Grokbot into Auto, it says **Grokbot (included in Auto)** outright instead of quietly dropping it.

### OpenCode Go

Supports an API key or the built-in console login, and shows the Go subscription's 5-hour ($12), weekly ($30), and monthly ($60) quota.

### Generic HTTP

Just have your endpoint return a usage object shaped like this:

```json
{
  "fiveHours": { "used": 12000, "limit": 50000, "resetAt": "2026-07-02T12:00:00Z" },
  "week": { "used": 240000, "limit": 900000, "resetAt": "2026-07-06T00:00:00Z" }
}
```

### Pinning accounts

Turn on **Menu Bar → Pin to menu bar** in settings, or click the pin in the top-right corner of any card in the dropdown — the two do the same thing.
Each pinned account adds one icon to the menu bar: the provider's official logo on the left, one thin vertical bar per quota window on the right, taller meaning more used, with the color shifting from green through orange to red as usage climbs. Hover to see the exact percentage of each window. Click again to unpin.

Icons follow the account order in settings, with no limit on how many — the system lays out the menu bar, and you can ⌘-drag to rearrange. The gourd is the global entry point (it reads the level inside the gourd, meaning what's left) and is independent of the pinned accounts.

Menu bar artwork is black and white only: the system draws the gourd and each provider's logo in black or white to match the menu bar's appearance, and the bars' green/orange/red is the one color that stays.

DeepSeek has no quota ratio, so pinning one shows the balance figure directly (with no unit), and you can pick the display currency in settings (original / CNY / USD).
The exchange rate is fetched once a day from ECB data, falling back to the last cached value if that fails. Conversion only affects that menu bar number; the card and settings always show the original value in its original currency.

Clicking a pinned DeepSeek item opens a detail popover: balance, request count / tokens / spend for `Today` and `This month`, a by-day trend for the month, the token breakdown (`Output` / `Cache hit` / `Cache miss`), and a `By model · this month` split.
Everything comes from the response already fetched at refresh time — no extra requests.

It is display-only: no filtering, no date range, no drill-down. For deeper analysis, go back to the vendor's console.
Numbers in the detail view older than 5 minutes refresh once automatically when you open it, and there's a manual refresh in the top-right; if a fetch fails, the previous numbers stay and the error is marked.

DeepSeek accounts can also pick a display currency (original / CNY / USD) in the same section. The rate is fetched from ECB data once a day, falling back to the last cached value; on first use with no rate available it falls back to a built-in default, clearly marked in settings.
Conversion only affects that menu bar number; the card and settings always show the original value in its original currency.

## Privacy

- There is no Token Health server and no cloud sync.
- Credentials are stored in the macOS Keychain.
- Requests go only to the provider you chose, or to a Generic HTTP / reporting endpoint you configured yourself.
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

This is a small, native SwiftUI project. Start from `Sources/TokenHealth/StatusMenuView.swift`, `SettingsView.swift`, and the provider implementations.

### Icons

The brand artwork has exactly one master: `AppSupport/GourdBrand/gourd-transparent.png` (a tilted gourd, a ribbon tied at its neck, white liquid resting at the fill line).
Every icon and menu bar mark is generated from it:

```bash
python3 scripts/generate-icons.py
```

That produces three things: `AppSupport/TokenHealth.icns` (the Finder / DMG icon, laid out on Apple's icon grid),
`Sources/TokenHealth/Resources/TokenHealthMark.png` (the menu bar one, a template image the system tints to match the menu bar),
and `TokenHealthIconLight/Dark.png` (light and dark versions of the app icon, the dark one inverted from the light one).

## License

MIT
