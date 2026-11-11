# Menu Bar Interaction and Settings Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Offer progress bars or percentages in pinned menu bar items, close menus reliably, and retain configuration edits across restarts.

**Architecture:** Keep the existing SwiftUI/AppKit application. Persist non-secret edits at the AppState boundary. Share a single AppKit popover controller between the main item and pinned accounts, with explicit outside-click, Escape, application-deactivation and Space-change dismissal instead of timed reopening heuristics.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Testing.

**Spec:** The user request in this chat; scope and defaults recorded below.

## Global Constraints

- One global display setting, defaulting to progress bars; monetary values remain monetary values.
- Percentages use the same quota metrics and ordering as the current bars; missing data is not 0%.
- Preserve current configuration and credentials; saving ordinary settings must not write secrets.
- Same-item clicks toggle; different items switch; outside clicks and focus changes dismiss.
- Work in the existing clean checkout; do not install over the user's running app or change production preferences during QA.

## Review Focus

- Rapid clicks and clicks held longer than 0.25 seconds must not reopen a closing popover.
- Only one main/detail popover should remain open when switching accounts.
- Popover content clicks must not dismiss the popover; Escape and clicking settings must.
- Disabling and re-enabling accounts and usage reporting must survive a new AppState without pressing Save.
- Percentages must fit at 0% and 100%, retain all quota windows, and show unknown data distinctly.

### Task 1: Persist Non-secret Configuration

**Files:** `Sources/TokenHealth/AppState.swift`; `Tests/TokenHealthTests/AppStateConfigPersistenceTests.swift`.

- [x] Add tests that mutate account and reporting bindings, reconstruct AppState, and assert the latest values survive without Save & Refresh.
- [x] Run `bash scripts/test.sh --filter AppStateConfigPersistenceTests` and confirm the persistence regression.
- [x] Add change observers that persist non-secret config values without running credential normalization/writes for every edit.
- [x] Re-run focused tests; verify secrets remain unchanged.

### Task 2: Select Menu Bar Display

**Files:** `Models.swift`, `ConfigStore.swift`, `AppState.swift`, `MenuBarItemLayout.swift`, `MenuBarItemRenderer.swift`, `MenuBarMetrics.swift`, `StatusItemPresentation.swift`, `PinnedStatusItemController.swift`, `SettingsView.swift` under `Sources/TokenHealth/`; matching Swift tests.

- [x] Add tests for default/invalid/persisted style, stable percentage geometry, actual text rendering, multiple windows, missing values, and unchanged amounts.
- [x] Run focused tests and confirm the new behavior is missing.
- [x] Add `MenuBarDisplayStyle` with bars and percentage cases, persist the preference, and wire the General picker through AppState into the presentation cache and renderer.
- [x] Re-run focused tests; percentage rendering has nonblank-pixel and text-fit checks. Native visual inspection remains unavailable as noted below.

### Task 3: Deterministic Popover Dismissal

**Files:** `StatusItemPopoverController.swift`, `MenuBarPanelController.swift`, `PinnedStatusItemController.swift`, `TokenHealthApp.swift` under `Sources/TokenHealth/`; `Tests/TokenHealthTests/MenuBarPanelControllerTests.swift` and `StatusItemPopoverControllerTests.swift`.

- [x] Add tests for a second click closing instead of reopening, switching anchors, outside versus content clicks, Escape, deactivation and cleanup.
- [x] Confirm failures before implementation.
- [x] Implement one shared application-defined popover with local/global mouse monitoring, notification-based focus dismissal and synchronous cleanup; remove timestamp suppression and unconditional re-creation.
- [x] Run focused tests, then `bash scripts/test.sh` and `bash scripts/build-app.sh`.
- [ ] Inspect a test-only fixture in the native UI; do not read or modify real account credentials or preferences.

## Verification and Review

- Configuration regressions: four tests initially failed with eight assertions, then passed after AppState persistence observers were added.
- Percentage rendering: the 100% text-fit regression caught a 30pt cell that was too narrow; fixed-width 36pt cells now fit the measured 31.22pt text without resizing as values change.
- Independent read-only review found two focus/event-timing risks. The same-app key-window regression failed before the fix; key-window handling now preserves child/anchor windows and dismisses for other windows. Global mouse events use the triggering event's screen coordinates, and callbacks check popover session identity.
- Full suite: 575 tests, four optional live/external checks skipped, no failures. Existing AppDelegate concurrency warnings remain outside this change.
- Release app builds and code-signature verification pass. The installed application and live preferences were not replaced.
- Native UI automation timed out opening the isolated QA fixture. Process inspection confirmed no fixture process was left running; held-click and actual status-item acceptance remain unverified.

## Follow-up: Compact Percentage Spacing

- User reported excessive menu bar spacing after choosing percentages. A new regression reproduced a 92pt two-value image, plus 6pt status-item padding, with 4pt icon/column gaps.
- Percentage mode now uses a dedicated 10pt monospaced-digit font, fixed 29pt columns and 2pt icon/column/outer gaps. The measured maximum `100%` width is 28.62pt; zero/full values retain identical geometry.
- Two-value status items shrink from 98pt to 76pt; three-value items shrink from 138pt to 107pt. Bars and amounts retain their previous geometry and fonts.
- Full suite: 577 tests, four live/external skips, no failures. Independent read-only follow-up review found no actionable issues. Renderer bitmap previews were inspected; native menu bar capture remained unavailable.
- Rebuilt, signature-verified and installed the spacing fix with an old-version backup; restarted the installed application without changing the percentage preference.

## Follow-up: Bar-like Footprint and Quota Mode

- User clarified that percentage items should be close to bar width, permitting smaller readable numbers. Percentages now stack top-to-bottom, up to three per column. Fixed 23x7pt cells, an 8pt medium-weight font, a 10pt logo and tight margins produce a 36pt status item for one to three metrics. Four or more metrics wrap into additional columns rather than disappear.
- Actual CoreText ink bounds center the small glyphs without line-leading overlap. `100%` ink is 22.21x5.92pt, fitting the 23x7pt cell. Light/dark 1x/2x renderer previews and per-row pixel tests passed.
- Native hidden-status-item probe: current menu bar height is 22pt; the three-value image stays 34x21pt in a 36x22pt button, with imageRect (1, 0.5, 34, 21), confirming no native image downscaling.
- User also requested Used/Remaining selection for both formats. `MenuBarQuotaMode` is stored independently of display style, defaults to Used, and applies at the shared metric builder. Severity always remains consumed ratio; balances, missing data and source snapshots are not inverted. Tooltips name the selected mode, including the 50% case where the bitmap is identical.
- Full suite: 588 tests, four optional live/external skips, no failures. Independent read-only reviews found no actionable defects in stacking or quota modes.
- The complete stacking/mode build passed release and signature checks and replaced the installed app with an old-version backup. Running binary SHA-256: `5e0155416a4d21abb3fcd0fbb602468f226eec20281dd6b87690b2503c005d98`.
- Native settings automation timed out after restart, so direct control-click acceptance is not claimed. A two-second process sample showed the main thread normally waiting in the AppKit event loop, not blocked in provider or rendering code; the installed app remained running.

## Release Qualification: 1.2.0

- User requested a new release. Confirmed remote latest was 1.1.0 and local main matched origin/main before release preparation. Set version 1.2.0, build 33.
- Fresh release-tree suite passed: 588 tests, four optional live/external checks skipped. Final independent read-only review found no blockers or private data; corrected the README wording to distinguish unknown percentage text from empty bar tracks.
- Isolated native Provider lifecycle smoke passed. The compressed DMG checksum, mounted app signature, version/build metadata and resources passed verification; the entire app bundle inside the DMG matched the build output byte-for-byte.
- DMG SHA-256: `8311b229ca780fb55f1c9a769ba061fd7cbcf7cb6057302bb0491f6778150420`. Release notes disclose Apple Silicon/macOS 14+, ad-hoc signing without notarization, and the native GUI end-to-end automation limitation.
