import Foundation
import Testing
@testable import TokenHealth

/// 这个缓存是「内容没变就别再写一遍」的判据。写回 `NSStatusItem` 不只是白干活：AppKit 会为它
/// 复制一份按钮位图并重设按钮外观，后者又经 KVO 回到重绘入口。判据一旦漏判成「变了」，
/// 重绘就会自己喂自己，永远停不下来。
struct AppliedValueCacheTests {
    @Test
    func appliesTheFirstValue() {
        var cache = AppliedValueCache<Int>()

        let applied = cache.shouldApply(1, for: UUID())

        #expect(applied)
    }

    @Test
    func skipsAValueIdenticalToTheLastAppliedOne() {
        var cache = AppliedValueCache<Int>()
        let id = UUID()

        let first = cache.shouldApply(1, for: id)
        let second = cache.shouldApply(1, for: id)
        let third = cache.shouldApply(1, for: id)

        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test
    func appliesAgainOnceTheValueChanges() {
        var cache = AppliedValueCache<Int>()
        let id = UUID()

        let first = cache.shouldApply(1, for: id)
        let second = cache.shouldApply(2, for: id)
        let third = cache.shouldApply(2, for: id)

        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test
    func tracksEachIDSeparately() {
        var cache = AppliedValueCache<Int>()
        let first = UUID()
        let second = UUID()

        let appliedToFirst = cache.shouldApply(1, for: first)
        let appliedToSecond = cache.shouldApply(1, for: second)
        let appliedToFirstAgain = cache.shouldApply(1, for: first)

        #expect(appliedToFirst)
        #expect(appliedToSecond)
        #expect(!appliedToFirstAgain)
    }

    /// 状态项被移除后旧记录得跟着走：重新钉上是一个新项，内容一样也得画。
    @Test
    func forgettingAnIDMakesTheSameValueApplyAgain() {
        var cache = AppliedValueCache<Int>()
        let id = UUID()
        let first = cache.shouldApply(1, for: id)

        cache.forget(id)
        let afterForgetting = cache.shouldApply(1, for: id)

        #expect(first)
        #expect(afterForgetting)
    }

    /// 详情浮层记的是可选快照：从「有数据」回到 nil 也算变化，别被 nil == nil 糊过去。
    @Test
    func anOptionalValueReturningToNilCountsAsAChange() {
        var cache = AppliedValueCache<UUID?>()
        let id = UUID()

        let fresh = cache.shouldApply(UUID(), for: id)
        let cleared = cache.shouldApply(nil, for: id)
        let clearedAgain = cache.shouldApply(nil, for: id)

        #expect(fresh)
        #expect(cleared)
        #expect(!clearedAgain)
    }
}
