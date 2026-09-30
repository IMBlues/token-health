import CoreGraphics

/// 菜单栏一项被点下去时干什么：有详情的弹详情浮层，其余的弹 Unpin/Settings/Quit 小菜单。
enum StatusItemInteraction: Equatable {
    case detailPopover
    case menu(displayName: String)
}

/// 一次重绘要写进 `NSStatusItem` 的全部内容：画什么（指标、logo 颜色、缩放）加上
/// tooltip 与点击行为。这些就是渲染器与状态项需要的全部输入 —— 布局是它们的纯函数，
/// 不必再单独比一遍。
///
/// 相等就意味着这一帧没有任何新东西要写，而这一点是要紧的：每一次写入都会让 AppKit
/// 为状态项复制一份按钮位图并重设按钮外观，后者又经 KVO 回到重绘入口。少写一次，
/// 就少一整圈。
struct StatusItemPresentation: Equatable {
    /// 账号换了 Provider 时指标可能碰巧一样，但 logo 换了，位图也跟着换。
    var providerKind: ProviderKind
    /// 画进菜单栏的指标，含「还没数据」时的那个占位项。
    var metrics: [MenuBarMetric]
    /// logo 只有黑与白两种，做成可比较的值，而不是拿 `NSColor` 去比。
    var logoIsWhite: Bool
    var scale: CGFloat
    var tooltip: String
    var interaction: StatusItemInteraction
}
