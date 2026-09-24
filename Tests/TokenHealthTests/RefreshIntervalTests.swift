import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct RefreshIntervalTests {
    @Test
    func clampsIntervalsBelowTheMinimum() {
        #expect(AppState.normalizedRefreshInterval(10) == AppState.minimumRefreshInterval)
        #expect(AppState.normalizedRefreshInterval(29.6) == AppState.minimumRefreshInterval)
    }

    @Test
    func keepsIntervalsAtOrAboveTheMinimum() {
        #expect(AppState.normalizedRefreshInterval(30) == 30)
        #expect(AppState.normalizedRefreshInterval(90.4) == 90)
        #expect(AppState.normalizedRefreshInterval(900) == 900)
    }

    @Test
    func fallsBackToTheDefaultForMissingOrInvalidIntervals() {
        #expect(AppState.normalizedRefreshInterval(nil) == AppState.defaultRefreshInterval)
        #expect(AppState.normalizedRefreshInterval(0) == AppState.defaultRefreshInterval)
        #expect(AppState.normalizedRefreshInterval(-60) == AppState.defaultRefreshInterval)
        #expect(AppState.normalizedRefreshInterval(.nan) == AppState.defaultRefreshInterval)
        #expect(AppState.normalizedRefreshInterval(.infinity) == AppState.defaultRefreshInterval)
    }
}
