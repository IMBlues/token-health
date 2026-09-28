# 详情浮层的额度条 设计

日期：2026-09-28
状态：已批准，待实现（随 1.0.3 一起发布）

## 1. 背景与目标

详情浮层现在的额度行只有一行文字（`5h` …… `100%`）。百分比本身没说是「用了多少」还是「剩多少」，
而各家口径确实不一样：DeepSeek 显示的是余额（剩多少），Codex / OpenCode Go 显示的是用量（用了多少）。
同一个数字，读者要先判断语义。

**目标**：额度行下面加一条通栏进度条，把「用掉几成」一眼画出来。数字保持现状，不动。

**非目标**：不改菜单栏竖条、不改下拉卡片、不改任何取数与模型语义；DeepSeek 的余额行不画条
（余额是金额，没有「用了几成」这回事）；不加悬停、不加点击。

## 2. 设计

1. **模型**：`DetailStat` 增加 `var ratio: Double? = nil`。有默认值，既有构造点一行不用改；
   浮层只在 ratio 非 nil 时画条，为 nil 的行（余额）保持纯文字。
2. **填充方**：
   - `CodexUsageDetail.headline`：`ratio: usage.ratio`
   - `OpenCodeGoUsageDetail.headline`：`ratio: usage.ratio`（该行值形如 `$0.32 / $12.00`）
   - `DeepSeekUsageDetail`：不设（余额），保持 nil
   `TokenUsage.ratio` 是现成的 `used/limit`（封顶 1），不新增计算。
3. **视图**（`DetailPopoverView`）：headline 每行改成「标签 + 数字」一行、下面一条 4pt 通栏条。
   轨道 `secondary` 25%；填充色走 `UsageAmountFormatter.tint(forRatio:)` —— 阈值与菜单栏竖条、
   下拉卡片完全同一套（≥90% 红、≥70% 橙、其余绿），这样两处不会各说各话。
   `tint(for:)` 改为转调 `tint(forRatio:)`，只留一处阈值。
4. **最小可见宽度**：ratio > 0 但极小时给 2pt。理由与菜单栏竖条的 1.5pt 最小高度相同 ——
   0.1% 的条不兜底就是一条空槽，读起来和「一点没用」一样。
5. 比例在视图里 clamp 到 `0...1`（`TokenUsage.ratio` 已封顶，这里是防御）。

## 3. 测试

| 测试 | 覆盖 |
| --- | --- |
| `CodexUsageDetailTests` | headline 的 `ratio` 数组 `[0.12, 0.58]` |
| `OpenCodeGoUsageDetailTests` | headline 的 `ratio` 等于 usages 的 `ratio`（忘了带比例会立刻红） |
| `DeepSeekUsageDetailTests` | headline 的 ratio 全为 nil |
| `DetailPopoverRenderTests` | 带比例的行比同内容的纯文字行高（条真的画出来了） |

## 4. 验收

1. `bash scripts/test.sh` 全绿。
2. 渲染样张人工看一眼：满格红、75% 橙、极小比例有可见的一段。
3. 实机：钉住的 Codex / OpenCode Go 项弹浮层，额度行下有彩条且颜色随用量变化；DeepSeek 浮层不变。
