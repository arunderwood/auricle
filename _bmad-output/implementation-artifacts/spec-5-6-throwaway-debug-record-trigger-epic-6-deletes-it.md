---
title: 'Story 5.6: Throwaway Debug Record Trigger (Epic 6 Deletes It)'
type: 'feature'
created: '2026-09-22'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: []
deferred: []
baseline_revision: '83cbd8e7447f59cbbdb8de9f2e1268842b7b284c'
---

<intent-contract>

## Intent

**Problem:** Epic 5 has no way to start or stop a capture yet — `CaptureStage.start()`/`.stop()` (Story 5.4) and `RecordingIndicator` (Story 5.5) exist but nothing calls them, so the process-tap backend can't be exercised end-to-end before Epic 6's real Record button (Story 6.2) lands.

**Approach:** Add a `#if DEBUG`-only `Debug > Start Recording / Stop Recording` menu command with a `Cmd-Shift-R` shortcut that toggles `CaptureStage.start()`/`.stop()` through a small testable `AppUI` controller, wires `RecordingIndicator` to the live state, and surfaces a mic-denied message with the Story 5.1 Settings deep link when the mic didn't make it into the mix.

## Boundaries & Constraints

**Always:** The menu item and shortcut exist only in Debug builds (`#if DEBUG`, absent from Release). The toggle always goes through `CaptureStage.start()`/`.stop()` — no bypassing its state machine. The mic-denied message reuses `PermissionStepContent.microphoneSkipCaption` and the deep link comes from `PermissionChecker.remediationDeepLink(for: .microphone)`, not new copy.

**Never:** Never build a production Record button or move the indicator into a window header — that is Story 6.2, which deletes this trigger. Never block a start on any permission status (`CaptureStage.start()` already tolerates a denied mic). Never fabricate the epic's per-meeting live-recording log (platform, audibility, `stage_events` metadata like `mic_included`/`tap_rebuilds`) — that is the maintainer's own record from real meetings recorded with this trigger after merge, not a build-time deliverable.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Toggle while idle, mic granted | no live meeting id; mic granted | `CaptureStage.start()` called; `isRecording = true`; no alert | No error expected |
| Toggle while idle, mic denied | no live meeting id; mic denied | `start()` called; result `micIncluded == false`; mic-denied alert set with settings deep link; `isRecording = true` (system-audio-only) | No error expected — capture still starts |
| Toggle while recording | a live meeting id is tracked | `CaptureStage.stop(meetingID:)` called; `isRecording = false`; tracked id cleared | No error expected |
| `start()` throws (e.g. already-live) | `CaptureStage.start()` throws | `isRecording` stays `false`, no tracked id set | Caught and logged; never propagated as a crash |

</intent-contract>

## Code Map

- `Sources/AppUI/DebugCaptureTrigger.swift` -- new: `@MainActor @Observable final class DebugCaptureTrigger` holding the live `MeetingID?`, exposing `isRecording: Bool`, a `microphoneDeniedAlert: MicrophoneDeniedAlert?` (message + settings `URL?`), and `toggle()`/`openMicrophoneSettings()`/`dismissMicrophoneDeniedAlert()`. Mirrors `Sources/AppUI/OnboardingCoordinator.swift:13-14`'s `@MainActor @Observable` shape.
- `Sources/Capture/CaptureStage.swift:176` `start(meetingID: MeetingID = .generate()) async throws -> CaptureStartResult` (has `.meetingID`, `.micIncluded`) and `:264` `stop(meetingID: MeetingID) async throws -> PipelineState` -- the two calls this story wires up; read-only, no changes.
- `Sources/AppUI/PermissionStepContent.swift:49` `microphoneSkipCaption` ("Recordings will have system audio only.") -- reuse verbatim; read-only.
- `Sources/Permissions/PermissionChecker.swift:154` `remediationDeepLink(for category: TCCCategory) -> URL?` -- read-only, called with `.microphone`.
- `Sources/AppUI/OnboardingConfigureModel.swift:9` `URLOpener` typealias (`@Sendable (URL) async -> Bool`) -- reuse this type for the injected opener.
- `App/Auricle/AuricleApp.swift:32,127-140` `captureStage`/`makeCaptureStage()`, `:41-49` `body`, `:199-210` `AuricleRootView` -- add a `#if DEBUG` `debugCaptureTrigger` static built from `captureStage` + `permissionChecker` + an opener (same lambda pattern as `:60-62`), a `.commands { CommandMenu("Debug") { ... } }` block with the `Cmd-Shift-R` shortcut, and wire `AuricleRootView`'s `RecordingIndicator(isRecording:)` (`:206`) plus a mic-denied `.alert` to it, all `#if DEBUG`-guarded.
- `Package.swift:320-323` `AppUITests` target dependencies (`["AppUI", "Permissions", "Capture", "Core", "VaultGlossary"]`) -- add `"State"`, `"Telemetry"`, `"Notifications"` so the new test can build a real `CaptureStage` from public API only (`StateStore.production(path:)`, `StageEventLogger(stateStore:)`, `StdoutNotifier()`), the same way `Tests/CaptureTests/CaptureStageFixture.swift` does but without `@testable`.
- `Tests/AppUITests/DebugCaptureTriggerTests.swift` -- new: exercises the I/O matrix above against a real `CaptureStage` with a fake `CaptureRecording` session.

## Tasks & Acceptance

**Execution:**
- `Sources/AppUI/DebugCaptureTrigger.swift` -- implement the controller -- isolates the start/stop/mic-denied decision in a `swift test`-covered `AppUI` type, per AGENTS.md's "new logic only in `App/` has no coverage" pitfall.
- `Package.swift` -- add `State`, `Telemetry`, `Notifications` to `AppUITests` -- unblocks building a real `CaptureStage` in tests without `@testable`.
- `Tests/AppUITests/DebugCaptureTriggerTests.swift` -- cover the I/O matrix rows -- the only automated proof this story can produce; the epic's live-meeting log is out of scope for this task (see Boundaries).
- `App/Auricle/AuricleApp.swift` -- add the `#if DEBUG` menu command, shortcut, and indicator/alert wiring -- satisfies the menu/shortcut AC and keeps `App/` a thin wrapper over the tested controller.

**Acceptance Criteria:**
- Given a Debug build, when it launches, then `Debug > Start Recording / Stop Recording` exists with `Cmd-Shift-R`, both absent from a Release build.
- Given capture is not running, when the trigger fires, then `DebugCaptureTrigger.toggle()` calls `CaptureStage.start()` and `isRecording` becomes `true`, driving `RecordingIndicator` into its active state.
- Given `CaptureStartResult.micIncluded == false`, when `toggle()` completes, then `microphoneDeniedAlert` carries `PermissionStepContent.microphoneSkipCaption` and `PermissionChecker.remediationDeepLink(for: .microphone)`.
- Given capture is running, when the trigger fires, then `toggle()` calls `CaptureStage.stop(meetingID:)` and `isRecording` becomes `false`.
- Given `swift test`, when it runs, then `AppUITests` passes, including `DebugCaptureTriggerTests`.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 15 findings — high 0, medium 3, low 6, false 5, maybe-false 1
- findings:
  - `[low]` `[reject]` blind-hunter: `toggle()` has no re-entrancy guard, so two near-simultaneous triggers could both read `liveMeetingID == nil` and both call `stage.start()` — refuted as harmful: `CaptureStage.start()`'s own actor-level `captureAlreadyLive` check registers the winner synchronously before its first `await`, so the loser's `start()` always throws and is a no-op; exactly one capture starts either way. Unlikely in normal single-user debug use, and adding a reentrancy flag is more than a trivial fix.
  - `[low]` `[patch]` blind-hunter: `toggle()`'s doc comment claims start/stop failures are "logged inside `CaptureStage` itself," but the `captureAlreadyLive` guard-clause throw (`CaptureStage.swift:179-181`) has no log call, unlike the `session.start()`-failure path a few lines later — fixed by rewording the comment to not overclaim logging coverage.
  - `[low]` `[reject]` blind-hunter (grouped with verification-gap's stop-failure row below): no test covers `stage.stop(meetingID:)` throwing inside `toggle()` — real gap, but this is the trigger's own documented "no user-facing error path" design for throwaway Debug-only scaffolding Epic 6 deletes; the failure needs an actual WAV-finalize/hardware fault to reach, and a proper fix (state reconciliation plus a dedicated stop-failure fixture) is more than a trivial correction.
  - `[medium]` `[patch]` blind-hunter: the regenerated `epic-5-context.md`'s Cross-Story Dependencies section dropped the "Shared files across stories" bullet and both "Open maintainer decision" bullets (ad-hoc signing, ScreenCaptureKit capture fallback) with no replacement, losing two still-open decisions future epic-5 planning passes rely on — fixed by restoring those bullets into the regenerated section.
  - `[false]` `[reject]` blind-hunter (grouped with intent-alignment's rewrite-scope row below): `epic-5-context.md` was rewritten far beyond a "Story 5.6" touch-up — refuted: `compile-epic-context.md`'s task spec produces a full-document regeneration by design, mandated by step-01 since `architecture.md` postdated the cached context; this is the epic-context caching mechanism working as intended, not scope creep from this story. The one real defect from the regeneration is the specific content loss, captured separately above.
  - `[low]` `[patch]` blind-hunter: `Sources/AppUI/DebugCaptureTrigger.swift` itself carries no `#if DEBUG` guard — only its call sites in `AuricleApp.swift` do — so the type still compiles into a Release build as unreachable dead code, against the story's "throwaway Debug-only" framing — fixed by wrapping the file's content in `#if DEBUG ... #endif`.
  - `[maybe-false]` `[reject]` blind-hunter: the `Debug` menu's dynamic title, read from a static `@Observable` property inside `.commands`, has no test or manual check confirming it actually refreshes after a toggle — Scene-level Observation tracking for `.commands` content is plausible but unconfirmed without a live GUI check. If true, the only consequence is a stale label string — the toggle action and the toolbar indicator (which the manual check does cover) work correctly regardless — so the if-true severity is only low; per the maybe-false/low rule, rejected rather than deferred.
  - `[false]` `[reject]` blind-hunter: `.accessibilityLabel(title)` on `Button(title)` and the alert's buttons look redundant — refuted: the project's custom `accessibility_label_missing` SwiftLint rule requires an explicit accessibility label on every interactive control regardless of implicit derivation, and `scripts/check.sh lint` (which enforces that rule) passes cleanly on these exact lines — required policy compliance, not arbitrary duplication.
  - `[false]` `[reject]` blind-hunter: `FakeCaptureRecording.restart(_:)` being a no-op leaves watchdog-restart interaction untested — refuted: `DebugCaptureTrigger` never calls `restart()`; that is `CaptureStage`'s own internal watchdog mechanism, already covered by the existing `CaptureStageTests`/`CaptureStageSystemAudioLossTests` suites, and out of this story's intent, which only wires start/stop.
  - `[medium]` `[patch]` edge-case-hunter (grouped with verification-gap's alert row below): `toggle()` never clears `microphoneDeniedAlert` on a later mic-included start (or on stop), so a stale "Microphone Not Included" alert from an earlier denied session persists and misleadingly reappears for a session that actually included the mic — fixed by clearing `microphoneDeniedAlert` when a start succeeds with `result.micIncluded == true`, plus a test covering deny → stop → grant.
  - `[medium]` `[patch]` verification-gap (same defect as edge-case-hunter's row above): confirms the stale-alert gap with line citations (`DebugCaptureTrigger.swift:43-59`, `AuricleApp.swift:263-289`) and notes none of the six existing tests vary `micIncluded` across two toggles on the same trigger instance — fix and test as above.
  - `[low]` `[reject]` verification-gap (same defect as blind-hunter's stop-throws row above): a thrown `stage.stop()` leaves the trigger reporting idle while `CaptureStage` may still consider the meeting live, and the next start silently no-ops — filed as pre-verified; this is the trigger's own documented design choice for throwaway scaffolding, not worth a dedicated fixture at this story's scope.
  - `[false]` `[reject]` intent-alignment: notes the epic-level reading (validating the process-tap backend against real meetings) is not exercised by this diff's tests — refuted: the spec's own Boundaries section explicitly and intentionally excludes the live-meeting log as out of scope ("the maintainer's own record... not a build-time deliverable"); a declined reading stated up front in the spec is not an unaddressed divergence.
  - `[low]` `[reject]` intent-alignment: `Sources/Capture/CaptureSession.swift`'s new `public init(micIncluded:)` is not listed in the spec's Code Map, even though the diff adds it — real gap in the spec's own documentation, but the only fix is to edit this build's spec, which is rejected by rule.
  - `[false]` `[reject]` intent-alignment (grouped with blind-hunter's rewrite-scope row above): the diff's edit to `epic-5-context.md` rewrites prose covering stories 5.1–5.10, not just 5.6 — same refutation as above: expected behavior of the epic-context recompilation task, not a story-5.6-specific overreach.

## Design Notes

`CaptureStage` is an actor with no public "is a capture live" query, so `DebugCaptureTrigger` tracks the `MeetingID` from `start()`'s result itself and passes it back to `stop(meetingID:)`:

```swift
public func toggle() async {
    if let meetingID = liveMeetingID {
        _ = try? await stage.stop(meetingID: meetingID)
        liveMeetingID = nil
        isRecording = false
    } else {
        guard let result = try? await stage.start() else { return }
        liveMeetingID = result.meetingID
        isRecording = true
        if !result.micIncluded {
            microphoneDeniedAlert = .init(
                message: PermissionStepContent.microphoneSkipCaption,
                settingsURL: checker.remediationDeepLink(for: .microphone),
            )
        }
    }
}
```

The epic's "record real meetings, log platform/audibility/`stage_events` metadata per meeting" acceptance criteria describe the maintainer's own ongoing use of this trigger during normal work after this ships ("no separate test session is scheduled" — epics.md's own words). This spec's scope ends at making that use possible; it cannot produce that log itself.

## Verification

**Commands:**
- `swift test --filter AppUITests` -- expected: all tests pass, including the new `DebugCaptureTriggerTests`.
- `swift build` -- expected: `AppUI` and `AuricleApp` build cleanly.
- `cd App && tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- expected: Debug build compiles with the `Debug` menu present.

**Manual checks (if no CLI):**
- Launch a Debug build; confirm `Debug > Start Recording / Stop Recording` appears and `Cmd-Shift-R` toggles the toolbar `RecordingIndicator`, matching Story 5.5's own no-snapshot-testing boundary.
- The epic's live-meeting dogfood walkthrough (real Teams/Meet/Zoom recording, `audio.wav` in cache, `auricle attribute`/`auricle run` finishing the note) is the maintainer's own end-to-end check after merge, not reproducible in this build step.

## Auto Run Result

**Summary:** Added a `#if DEBUG`-only `Debug > Start Recording / Stop Recording` menu command (`Cmd-Shift-R`) that toggles `CaptureStage.start()`/`.stop()` through a new `DebugCaptureTrigger` controller, wired `RecordingIndicator` to its live state, and surfaced a mic-denied alert (Story 5.1 deep link) when a start's mic isn't included. A review pass found and patched a stale-alert bug and three lower-severity issues.

**Files changed:**
- `Sources/AppUI/DebugCaptureTrigger.swift` (new) -- `@MainActor @Observable` controller: `toggle()`, `openMicrophoneSettings()`, `dismissMicrophoneDeniedAlert()`; wrapped in `#if DEBUG` after review.
- `Tests/AppUITests/DebugCaptureTriggerTests.swift` (new) -- 7 tests covering all 4 I/O matrix rows, the settings/dismiss helpers, and the post-patch stale-alert regression case.
- `App/Auricle/AuricleApp.swift` -- `#if DEBUG` `debugCaptureTrigger` static, `Debug` `CommandMenu` with the `Cmd-Shift-R` shortcut, `AuricleRootView` wired to the trigger's `isRecording` and `microphoneDeniedAlert`.
- `Package.swift` -- added `State`, `Telemetry`, `Notifications` to `AppUITests` dependencies.
- `Sources/Capture/CaptureSession.swift` -- added `public init(micIncluded:)` to `CaptureSessionStartResult` (the synthesized memberwise init was internal-only); needed so the test target can construct one without `@testable`.
- `_bmad-output/implementation-artifacts/epic-5-context.md` -- recompiled (stale versus `architecture.md`) per step-01; review restored three bullets the recompile had dropped.

**Review findings breakdown (15 findings, 4 layers):**
- Patched (4): `toggle()`'s doc comment overclaimed `CaptureStage` logging coverage (low); `epic-5-context.md` dropped the "Shared files" and both "Open maintainer decision" bullets on recompile (medium); `DebugCaptureTrigger.swift` wasn't itself `#if DEBUG`-gated (low); `toggle()` never cleared a stale `microphoneDeniedAlert` on a later mic-granted start (medium, found independently by two layers).
- Deferred: none.
- Rejected (10, with reason): re-entrancy on rapid double-toggle — `CaptureStage`'s own actor guard already prevents a duplicate live capture; swallowed `stage.stop()` failure — the trigger's documented no-error-path design for throwaway scaffolding, found by two layers; `epic-5-context.md` rewritten beyond story scope — expected behavior of the epic-context recompile task, found by two layers; `Debug`-menu title reactivity unverified — if-true severity is only cosmetic (maybe-false + low routes to reject); `.accessibilityLabel` calls "redundant" — required by the project's own `accessibility_label_missing` lint rule, which passes; `FakeCaptureRecording.restart` no-op — out of scope, `DebugCaptureTrigger` never calls `restart()`; epic-level live-meeting validation not exercised by tests — explicitly declined in the spec's own Boundaries; `CaptureSession.swift` missing from the Code Map — real gap, but its only fix is editing this spec, rejected by rule.

**Follow-up review recommendation:** `true`. Two `medium` entries were patched in this first pass. Named risk: the `epic-5-context.md` bullet restoration was reworded by the implementation subagent to match the recompiled section's prose rather than checked word-for-word against the original decision record — worth a follow-up read to confirm the restored "Open maintainer decision" bullets (ad-hoc signing, ScreenCaptureKit fallback) still say exactly what they said before, not a paraphrase that drifted.

**Verification performed:** `swift test --filter AppUITests` (75/75, including 7 `DebugCaptureTriggerTests`) before and after patching; `swift build` and `swift build -c release` clean, including `AppUI` compiling with `DebugCaptureTrigger` excluded from the Release configuration; `scripts/check.sh lint` clean after a swiftformat pass fixed indentation the `#if DEBUG` patch introduced; `tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` succeeded with the `Debug` menu compiled in.

**Residual risks:** The named follow-up-review risk above. The epic's own live-meeting dogfood acceptance criteria (per-meeting platform/audibility/`stage_events` log) remain the maintainer's own post-merge practice, out of this build's scope per the spec's Boundaries.
