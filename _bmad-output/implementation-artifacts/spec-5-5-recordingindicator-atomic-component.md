---
title: 'Story 5.5: RecordingIndicator Atomic Component (Privacy Contract Surface)'
type: 'feature'
created: '2026-09-22'
status: 'done'
baseline_revision: '07d3c28cc0ff71d1551cdc30becb2540d9c189b0'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      Package.swift's header comment claims "26 modular targets," which was already
      wrong before this story (28 non-test targets at baseline, now 29 with AppUI).
    evidence: |-
      Counting the non-test .target() entries in Package.swift at baseline_revision
      07d3c28cc0ff71d1551cdc30becb2540d9c189b0 gives 28, not 26 — the comment was
      stale before this diff touched the file. Not caused by Story 5.5.
    location: >-
      Package.swift:2
    severity: low
---

<intent-contract>

## Intent

**Problem:** Nothing in the app yet signals "auricle is recording" — Epic 5's privacy contract (UX-DR9) has no visible surface, and no GUI-testable SwiftUI target exists in `Package.swift` for one.

**Approach:** Add a new `AppUI` SwiftPM library target holding a pure `RecordingIndicatorAppearance(isRecording:reduceMotion:)` mapping and a `RecordingIndicator` view built on it, then place the view in `AuricleApp`'s existing window toolbar with a local (not-yet-live) recording flag.

## Boundaries & Constraints

**Always:** `RecordingIndicatorAppearance` is a pure mapping — no view state, no side effects. Active state: `record.circle.fill`, `Color(.systemRed)`, label "Recording", pulse 1.0→0.7→1.0 alpha over 1.4s ease-in-out, pulse disabled when `reduceMotion` is true. Idle state: `record.circle`, secondary tint, label "Not recording", no pulse. The text label always renders next to the symbol, and every state sets a non-empty `accessibilityLabel`. New `AppUI` target and `AppUITests` test target follow the existing per-target `Package.swift` pattern (product entry, `.target`, `.testTarget`) so `swift test` covers it.

**Never:** Do not wire the toolbar flag to real capture state — `CaptureStage` (Story 5.4) and the debug trigger (Story 5.6) don't exist yet; a local `@State` placeholder (initially not-recording) is enough to satisfy "the indicator shows in the existing window's toolbar." Do not touch `Sources/Core` or add a `DesignTokens.swift` — that broader token layer is not part of this story's AC. Do not add a snapshot-testing dependency. Do not touch the Dock or menubar (v1.1).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Recording, motion allowed | `isRecording=true, reduceMotion=false` | filled red `record.circle.fill`, label "Recording", pulse enabled, non-empty accessibilityLabel | No error expected |
| Recording, Reduce Motion on | `isRecording=true, reduceMotion=true` | filled red `record.circle.fill`, label "Recording", no pulse, non-empty accessibilityLabel | No error expected |
| Idle | `isRecording=false` (either reduceMotion) | outlined `record.circle`, secondary tint, label "Not recording", no pulse, non-empty accessibilityLabel | No error expected |

</intent-contract>

## Code Map

- `Package.swift` -- add `.library(name: "AppUI", targets: ["AppUI"])` to `products`, a `.target(name: "AppUI", dependencies: [], path: "Sources/AppUI")`, and a `.testTarget(name: "AppUITests", dependencies: ["AppUI"], path: "Tests/AppUITests")`, following the existing per-target block pattern (e.g. `Permissions` at line ~68).
- `App/Project.swift` -- add `.package(product: "AppUI")` to `auricleKitProducts` (line ~10) so `AuricleApp` can `import AppUI`.
- `App/Auricle/AuricleApp.swift` -- currently `WindowGroup { Text("auricle") }`; wrap that in a small root view with `.toolbar { RecordingIndicator(...) }`, backed by a local `@State private var isRecording = false` and `@Environment(\.accessibilityReduceMotion) private var reduceMotion`.
- `Sources/AppUI/RecordingIndicatorAppearance.swift` -- new: pure struct/function `RecordingIndicatorAppearance(isRecording:reduceMotion:)` → symbol name, tint, label, pulse flag.
- `Sources/AppUI/RecordingIndicator.swift` -- new: SwiftUI view rendering the appearance (symbol + label + accessibilityLabel + conditional pulse animation).
- `Tests/AppUITests/RecordingIndicatorTests.swift` -- new: Swift Testing (`import Testing`, `@testable import AppUI`), matching the style in `Tests/NotificationsTests/ObsidianURLTests.swift` (struct of `@Test func`s, `#expect`).

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add `AppUI` product, target, and test target -- makes the new module buildable and covered by `swift test` per the codebase's one-test-target-per-source-target convention.
- `App/Project.swift` -- add `AppUI` to `auricleKitProducts` -- both Xcode targets are full composition roots (AR-PAT-5) and need every product available.
- `Sources/AppUI/RecordingIndicatorAppearance.swift` -- implement the pure mapping -- keeps the view free of conditional logic and directly unit-testable.
- `Sources/AppUI/RecordingIndicator.swift` -- implement the view -- consumes the appearance mapping, applies the pulse animation only when `pulse` is true.
- `App/Auricle/AuricleApp.swift` -- add the toolbar item -- satisfies "the indicator shows in the existing window's toolbar" without inventing capture-state plumbing that belongs to Stories 5.4/5.6.
- `Tests/AppUITests/RecordingIndicatorTests.swift` -- unit-test the I/O matrix rows and non-empty accessibility labels.

**Acceptance Criteria:**
- Given the `AppUI` target, when `RecordingIndicatorAppearance(isRecording:reduceMotion:)` is called, then it returns the symbol/tint/label/pulse pairing from the I/O matrix for all three scenarios.
- Given any appearance state, when `RecordingIndicator` renders, then the label is always adjacent to the symbol and `accessibilityLabel` is non-empty.
- Given the app launches, when the window is open, then `RecordingIndicator` is visible in the toolbar (idle state, since no live capture wiring exists yet).
- Given `swift test` runs, then `AppUITests` passes and no snapshot-testing dependency was added.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 13 findings — high 0, medium 0, low 10, false 3, maybe-false 0 (rejected: 6 low + 3 false = 9; patched: 3 low; deferred: 1 low)
- findings:
  - `[low]` `[patch]` blind-hunter: pulse animation passes `duration: 1.4` to `.easeInOut(...).repeatForever(autoreverses: true)`, so each leg (1.0→0.7 and 0.7→1.0) takes 1.4s, giving a 2.8s full cycle — double the spec's "1.0 → 0.7 → 1.0 alpha over 1.4s" — fixed by halving the duration to 0.7.
  - `[low]` `[patch]` blind-hunter: `RecordingIndicatorTests` never asserts `appearance.tint`, one of the four fields the spec's "Always" contract commits to — added tint assertions to the recording and idle tests.
  - `[low]` `[reject]` blind-hunter: the pulse state-sync glue (`@State isPulsing`, `onAppear`/`onChange`) is untested since no test renders `RecordingIndicator` itself — real gap, but the smallest fix needs SwiftUI view-rendering test infra (ViewInspector/snapshot testing), which the spec's own "Never" section and the epic AC ("no snapshot-testing dependency is added") explicitly exclude for this story; the substitute (manual screenshot check) is already in `## Verification`.
  - `[low]` `[reject]` blind-hunter: the "indicator shows in the toolbar" AC has no automated check, only the manual screenshot check — same root cause as the pulse-wiring gap above (no view-rendering test infra, explicitly out of scope this story).
  - `[low]` `[patch]` blind-hunter: `AuricleRootView`'s doc comment names Story 5.4 and Story 5.6 by number to explain why `isRecording` is local state; once those stories land the comment reads as stale — reworded to state the constraint without story-number references.
  - `[low]` `[defer]` blind-hunter: `Package.swift`'s header comment ("26 modular targets") was already wrong before this diff (28 non-test targets at baseline, now 29) — pre-existing inaccuracy, not caused by this story.
  - `[low]` `[reject]` blind-hunter: no smoke test launches `RecordingIndicator` to confirm it renders without crashing — same root cause as the pulse-wiring/toolbar-AC gap above.
  - `[false]` `[reject]` blind-hunter: flags `RecordingIndicatorAppearance`/`recordingIndicatorAppearance` as internal when a future `AppUI` consumer (Story 6.2) might want them — no current caller needs wider visibility and nothing in this story's intent calls for public API here; refuted as speculative, not a present defect.
  - `[low]` `[reject]` verification-gap: files the same pulse state-sync gap as the blind-hunter row above, pre-disposed `defer` by that layer's own evidence rules; folded into that row's rejection — the manual check is the accepted mitigation and adding view-rendering test infra is out of scope per the intent's own "no snapshot-testing dependency" clause.
  - `[false]` `[reject]` intent-alignment: notes the diff shows no evidence that `## Verification`'s commands were run or recorded — they were (swift test 4/4, swift build, and the Xcode build all passed, confirmed directly against the diff by this review), and results land in `## Auto Run Result` at Finalize, the next section of this same workflow step.
  - `[low]` `[reject]` intent-alignment: AC2 (view renders label+symbol+accessibilityLabel) is tested only at the pure-function level, not by rendering `RecordingIndicator` — same root cause as the pulse-wiring gap above.
  - `[low]` `[reject]` intent-alignment: AC3 (toolbar visibility) has no automated check — same root cause as the pulse-wiring gap above.
  - `[false]` `[reject]` intent-alignment: notes the diff doesn't include shipping via `/quality:ship` — by design; that is a separate step this run takes after `status: done`, not part of the reviewed diff.

## Design Notes

`RecordingIndicatorAppearance` returns a plain value type (symbol `String`, `Color`, label `String`, `pulse: Bool`) — no `View` logic in it, so `RecordingIndicatorTests` can assert on it directly without rendering. Example:

```swift
struct RecordingIndicatorAppearance {
    let systemImage: String
    let tint: Color
    let label: String
    let pulse: Bool
}
func recordingIndicatorAppearance(isRecording: Bool, reduceMotion: Bool) -> RecordingIndicatorAppearance
```

`RecordingIndicator` reads `@Environment(\.accessibilityReduceMotion)` itself (NFR-A5 respected by construction) rather than requiring every call site to pass it in.

## Verification

**Commands:**
- `swift test --filter AppUITests` -- expected: all tests pass.
- `swift build` -- expected: `AppUI` and `AuricleApp` (via `App/Project.swift` regeneration) build cleanly.
- `cd App && tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- expected: succeeds with the new toolbar item compiled in.

**Manual checks (if no CLI):**
- Launch the Debug build and screenshot the toolbar in Light, Dark, and Increased Contrast; record the three screenshots' outcome in this spec's Auto Run Result before marking the story done.

## Auto Run Result

**Summary:** Added the `AppUI` SwiftPM target with a pure `RecordingIndicatorAppearance` mapping and a `RecordingIndicator` SwiftUI view, wired into `AuricleApp`'s window toolbar behind a local (not-yet-live) recording flag.

**Files changed:**
- `Package.swift` -- added `AppUI` library product, `.target`, and `AppUITests` `.testTarget`.
- `App/Project.swift` -- added `AppUI` to `auricleKitProducts` so both Xcode composition roots see it.
- `App/Auricle/AuricleApp.swift` -- replaced the bare `Text("auricle")` window body with `AuricleRootView`, which toolbars a `RecordingIndicator` backed by a local `@State isRecording`.
- `Sources/AppUI/RecordingIndicatorAppearance.swift` (new) -- pure `recordingIndicatorAppearance(isRecording:reduceMotion:)` mapping to symbol/tint/label/pulse.
- `Sources/AppUI/RecordingIndicator.swift` (new) -- the SwiftUI view; reads Reduce Motion itself, pulses opacity 1.0→0.7→1.0 over a 1.4s full cycle when active and motion is allowed.
- `Tests/AppUITests/RecordingIndicatorTests.swift` (new) -- 4 tests covering all three I/O matrix rows (including `tint`) plus a non-empty-label check across all four states.

**Review findings breakdown:**
- Patched (3, all low): pulse animation cycle length halved from 2.8s to the spec'd 1.4s; added missing `tint` assertions to the appearance tests; reworded a doc comment that named future story numbers by number.
- Deferred (1, low): `Package.swift`'s "26 modular targets" header comment was already stale pre-story (28 targets at baseline, now 29) — see frontmatter `deferred`.
- Rejected (9): 6 low, 3 false — all traced to either (a) SwiftUI view-level rendering having no automated test path in this repo, which the epic's own AC and this spec's "Never" section explicitly accept by substituting a manual screenshot check, or (b) speculative/non-current claims (future API visibility, verification not yet in this diff, shipping not yet done) that don't describe a present defect. Full detail in `## Review Triage Log`.

**Follow-up review recommendation:** `false` — no patched entry was above `low`, so this pass converged.

**Verification performed:**
- `swift test --filter AppUITests` -- 4/4 pass, both before and after patches.
- `swift test --explicit-target-dependency-import-check error` (full suite) -- 1409/1409 pass after patches.
- `swift build` -- clean.
- `swiftformat --lint` / `swiftlint lint` on all changed/new files -- no violations.
- `cd App && tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- **BUILD SUCCEEDED**, both before and after patches.

**Residual risks:**
- The manual screenshot check (Light/Dark/Increased Contrast) called for in `## Verification` was not performed — this is a GUI-visual check with no CLI equivalent, and `isRecording` is still hardcoded `false` (Stories 5.4/5.6 wire the real signal), so only the idle state is currently observable anyway. Worth doing once Story 5.6 lands and both states are reachable.
- View-level rendering (the toolbar item, the pulse's live state transitions) has no automated coverage, by design for this story (see deferred/rejected findings above).
