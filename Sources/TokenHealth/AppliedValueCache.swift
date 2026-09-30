import Foundation

/// 记住每个 id 上一次「写出去」的值，用来跳过内容没变的重写。
///
/// 菜单栏项与详情浮层两处栽在同一个坑上：把没变的同一份内容再写一遍并不便宜。
/// 写回 `NSStatusItem` 会让 AppKit 复制一份按钮位图、重设按钮外观，而按钮外观的变化
/// 又经 KVO 回到重绘入口；详情浮层那边则是让整棵 SwiftUI 视图树重新求值。
struct AppliedValueCache<Value: Equatable> {
    private var applied: [UUID: Value] = [:]

    /// 这个值是不是新的。是新的就记下来，调用方接着去写；不是就什么都别做。
    mutating func shouldApply(_ value: Value, for id: UUID) -> Bool {
        guard applied[id] != value else {
            return false
        }
        applied[id] = value
        return true
    }

    /// 对应的东西没了（状态项被移除、浮层被关掉）就忘掉记录，
    /// 免得下次重建时是一个全新的东西，却被上一个的旧记录挡住。
    mutating func forget(_ id: UUID) {
        applied.removeValue(forKey: id)
    }
}
