# Codex 重置卡展示 设计

日期：2026-09-30
状态：已批准，待实现（随 1.0.3 一起发布）
前置：本文取代 `2026-09-26-codex-detail-design.md` §7.5「不解码、不展示 rateLimitResetCredits」与 §11 的同名取舍。

## 1. 背景与目标

Codex 的额度响应（`account/rateLimits/read`，我们**已经在取**）里带着重置卡：
`rateLimitResetCredits.availableCount` 与可选的明细数组。一张卡能在额度打满时把 5 小时 + 周额度一起重置，
所以「有几张、什么时候过期」是真会用到的信息 —— 尤其这张卡会过期。

**目标**：在 Codex 浮层里加一段 `Reset cards` 表，列出可用的重置卡与到期时间。

**非目标**：
- **不做「用掉一张卡」**：那要调 `account/rateLimitResetCredit/consume`，与浮层「只展示、不可交互」的原则
  冲突，也会动到 allowlist 那条安全断言。本机仍然禁用它（allowlist 测试里逐字列着）。
- 不动 `credits` 字段（那是付费余额 `hasCredits`/`balance`，另一回事）。
- 不加悬停、不加点击、不改菜单栏与下拉卡片。

## 2. 数据形状（2026-09-30 本机实测）

```json
"rateLimitResetCredits": {
  "availableCount": 1,
  "credits": [ {
    "id": "RateLimitResetCredit_97d1…",
    "resetType": "codexRateLimits",
    "status": "available",
    "grantedAt": 1790701436,
    "expiresAt": 1793293436,
    "title": "Full reset (Weekly + 5 hr)",
    "description": "Thanks for using Codex! You've been granted one free rate limit reset."
  } ]
}
```

协议里 `credits` 可为 **null**（后端只给数量）、也可被后端截断（长度小于 `availableCount`）；
`expiresAt` 为 null 表示这张卡不过期。三种都要能降级。

## 3. 设计

1. **解码**（`CodexUsageProvider.swift`）：`CodexRateLimitsResponse` 增加
   `rateLimitResetCredits: CodexResetCreditsSummary?`。新类型沿用同文件既有的宽容风格：
   `availableCount` / `expiresAt` 走 `decodeFlexibleInt64IfPresent`，字符串字段 `try?`。
   `status` 不解码 —— 这个数组按协议就是「可用的卡」，没有别的状态要画。
2. **接缝签名**：`CodexUsageDetail.make(usage:resetCredits:usages:today:)` —— 重置卡来自**额度那半**
   （`CodexRateLimitsResponse`），不是用量那半，所以要单独传进来。`snapshot()` 里调用点同步改。
3. **表格**：用 `detail.table`（Codex 没有别的表，这个位置空着）。
   - `title` = `Reset cards`，列 `["Card", "Expires"]`。
   - 行名 = `title` → `description` → `"Reset"`（依次取第一个非空）；单元格 = 到期日。
   - **到期日按本地时区**格式化为 `M/d` —— 与用量桶的 UTC 日键不同，这是一张卡对**用户**的墙钟截止时间，
     用 UTC 显示会差一天。`expiresAt` 为 null → `Never`。
   - **排序：先到期的在前**，不过期的排最后。谁的期限最紧最该先被看见。
   - 行数上限 6（与其它表同一约定）；`footnote` = 没画出的张数（按 `availableCount` 算，`+N more cards`）。
   - **降级**：没有明细但有数量 → 单行 `"N available"` / `"—"`；数量为 0 或整段缺席 → **不画这一段**。
4. **文案**：全英文，与浮层其它区块一致。

## 4. 测试

| 测试 | 覆盖 |
| --- | --- |
| `CodexUsageProviderTests`（扩） | 解码：数量 + 明细；`credits: null`；`availableCount` 写成字符串；`expiresAt: null` |
| `CodexUsageDetailTests`（扩） | 一张卡 → 行名与到期日；多张按到期先后排序、不过期的最后；空标题回落到描述；无明细有数量 → `N available`；数量 0 / 缺席 → 无表；超过 6 张 → 截断 + footnote；到期日是本地时区 |
| `DetailPopoverRenderTests` | 不变（表本来就有渲染覆盖） |

## 5. 验收

1. `bash scripts/test.sh` 全绿。
2. 渲染样张：`Reset cards` 表出现在 token 构成下面，行是卡的标题 + `10/30`。
3. 实机：钉住的 Codex 项弹浮层能看到这张表；与 `codex` TUI 里的重置卡数量一致。
