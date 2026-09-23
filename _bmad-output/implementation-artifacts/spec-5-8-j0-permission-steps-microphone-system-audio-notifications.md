---
title: 'Story 5.8: J0 Permission Steps (Microphone, System Audio, Notifications)'
type: 'feature'
created: '2026-09-22'
baseline_revision: '09d921497b485bdc3cd3e0c18e19bc110bbd3bb3'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The three J0 permission steps use Story 5.7's placeholder `DefaultPermissionStep` and a bare "Continue" view: no *why* line, no denied states, and the System Audio step never fires the OS prompt.

**Approach:** Add three real `OnboardingPermissionStep` conformances in `AppUI` (Microphone, System Audio via `SystemAudioPermissionProbe`, Notifications), a pure `PermissionStepContent` mapping from (category, last status) to copy and actions, and small coordinator additions for Skip/Continue/Open Settings. `PermissionStepView` only renders that content and forwards taps.

## Boundaries & Constraints

**Always:**
- All decision logic (which copy, which buttons, advance vs remain) lives in `Sources/AppUI` and is covered by `Tests/AppUITests/PermissionStepsTests.swift`. `App/` views only render and forward.
- Permission state goes only through `PermissionChecking` (lint rule `permission_checker_bypass`). Deep links come only from `PermissionChecking.remediationDeepLink(for:)`.
- `AppUI` depends on `Capture` (Package.swift) and the System Audio step calls `SystemAudioPermissionProbe.prompt(source:)` with an injected `SystemAudioSource`. `AuricleApp` injects `ProcessTapSource()`.
- The System Audio step never reports success. After the probe it always remains, with the hedged copy plus `[Open Settings]` and `[Continue]`. A probe error is logged at `warn` and shows the same copy.
- Every interactive control has `.accessibilityLabel` (lint rule `accessibility_label_missing`).
- No new defaults that touch real hardware, System Settings, or the real opener. The coordinator's URL opener is a required init parameter.

**Never:**
- Do not block onboarding on any denial. Every step has a forward action.
- Do not change `CaptureSession`'s mic-denied behavior. The "record with mic denied" AC is already met by Story 5.2 (see Code Map).
- Do not implement Story 5.9's self-wikilink sub-step, Doctor re-runs (Story 9.2), or an auto-advance when the user grants in System Settings and returns.
- Do not remove `DefaultPermissionStep` or change the coordinator's default step map; existing 5.7 tests rely on it.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mic step, before request | `permissionStatus == nil` | why line + "Grant Microphone access" only | — |
| Mic granted | `request(.microphone)` → `.granted` | coordinator advances to `.systemAudio` | — |
| Mic denied | → `.denied` | remains; mic-denied copy; actions `[Open Settings, Skip]`; no Try Again | — |
| Mic not determined | → `.notDetermined` | remains; same copy; actions `[Open Settings, Skip, Try Again]` | — |
| Mic Try Again | on `.notDetermined`, tap Try Again | `request(.microphone)` runs again | — |
| Mic Skip | tap Skip | advances to `.systemAudio` | — |
| Open Settings | any permission step, tap | opener receives `checker.remediationDeepLink(for: category)` | nil link → opener not called |
| System Audio request | probe runs (fake source) | source start+stop once each; `checker.request` never called; remains with `.unknown`; hedged copy; `[Open Settings, Continue]` | probe throws → `warn` log, same result |
| Notifications granted | → `.granted` | advances to `.configure` | — |
| Notifications denied | → `.denied` | remains; NFR-R8 copy; actions `[Continue]` only | — |

</intent-contract>

## Code Map

- `Sources/AppUI/OnboardingPermissionStep.swift` -- protocol `OnboardingPermissionStep` + `OnboardingPermissionOutcome` (`.advance` / `.remainWithStatus`) + `DefaultPermissionStep`. Seam to conform to; keep as is.
- `Sources/AppUI/OnboardingCoordinator.swift` -- `requestCurrentPermission()` currently discards `.remainWithStatus` (`case .remainWithStatus: break`). Needs: stored `permissionStatus: PermissionStatus?` (set on remain, cleared on every step change), `currentPermissionCategory`, `permissionContent: PermissionStepContent?`, `continuePastCurrentPermission()` (advance, no-op off a permission step), `openCurrentPermissionSettings() async`, and a required `opener: URLOpener` init param.
- `Sources/AppUI/OnboardingConfigureModel.swift:8` -- `URLOpener` typealias to reuse.
- `Sources/Permissions/PermissionChecker.swift` -- `PermissionChecking` (`request`, `remediationDeepLink(for:)`). Read only.
- `Sources/Capture/CaptureSession.swift:560` -- `SystemAudioPermissionProbe.prompt(source:)`: starts `source`, sleeps 1s, stops. Read only.
- `Sources/Capture/SystemAudioSource.swift` -- protocol a test fake conforms to (`start/stop/drain/rebuild`). Pattern: `FakeSystemAudioSource` in `Tests/CaptureTests/CaptureSessionTests.swift:34`.
- `Sources/Core/Log.swift:81` -- `warn(_ message: StaticString, _ fields:)`.
- `Package.swift:171` -- `AppUI` deps `["Core", "Permissions"]` → add `"Capture"`. `Package.swift:321` -- `AppUITests` deps → add `"Capture"`.
- `App/Auricle/Onboarding/PermissionStepView.swift` -- placeholder view to replace. Keep its `isRequesting` re-entrancy guard.
- `App/Auricle/AuricleApp.swift` -- `makeOnboardingCoordinator()` composition root: inject the three real steps and the opener (`NotificationDelegate.openInDefaultApp`, same as `configure`'s).
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- existing `OnboardingCoordinator(...)` call sites gain the `opener:` argument. `Recorder`/`FakePermissionChecker` are `private` there; the new test file defines its own doubles.
- `Tests/CaptureTests/CaptureSessionTests.swift:166` -- `micPermissionDeniedRecordsSystemAudioOnlyAndNeverStartsTheMicEngine`: already proves recording starts with mic denied and system audio unknown. Satisfies the "tries to record" AC with no new code.
- `App/Auricle/Info.plist:23-26` -- `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription` already present.

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add `"Capture"` to `AppUI` and `AppUITests` dependencies -- the probe lives in `Capture`.
- `Sources/AppUI/PermissionSteps.swift` -- new: `MicrophonePermissionStep` (granted → advance, else remain with status), `SystemAudioPermissionStep(source:)` (probe, always remain `.unknown`, warn-log on throw), `NotificationsPermissionStep` (granted → advance, else remain with status).
- `Sources/AppUI/PermissionStepContent.swift` -- new: `PermissionStepAction` (`request`, `openSettings`, `skip`, `tryAgain`, `continueOnward`) and `PermissionStepContent.make(category:status:)` with title, why line, request button title, optional standing note, optional follow-up message, ordered actions. Copy per Design Notes.
- `Sources/AppUI/OnboardingCoordinator.swift` -- add the members listed in the Code Map.
- `App/Auricle/Onboarding/PermissionStepView.swift` -- render `coordinator.permissionContent`; map each action to a labelled button calling the coordinator.
- `App/Auricle/AuricleApp.swift` -- inject real steps and the opener.
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- pass an opener to every coordinator init.
- `Tests/AppUITests/PermissionStepsTests.swift` -- new: every I/O Matrix row, plus: the System Audio content's follow-up never claims a grant; content with `status == nil` offers only `.request`.

**Acceptance Criteria:**
- Given each permission step, when its content renders before any request, then it shows a non-empty why line and a request button titled "Grant Microphone access" / "Allow System Audio Recording" / "Allow notifications".
- Given the System Audio step, when content renders at any status, then the standing note says recordings contain only your microphone without the grant.
- Given `swift test` and `make check`, then both pass, including `PermissionStepsTests`.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 25 findings — high 0, medium 5, low 9, false 11, maybe-false 0
- findings:
  - `[low]` `[reject]` blind-hunter: Try Again never appears in production, because the real `PermissionChecker.request(.microphone)` maps `requestAccess`'s Bool to `.granted`/`.denied` only. — real, but the epics AC prescribes exactly "Try Again shown only while `.notDetermined`"; dropping the rule would break the AC, and making the real checker return `.notDetermined` is a Story 5.1 change.
  - `[low]` `[reject]` blind-hunter: after Open Settings → grant → return, the Microphone screen still shows denied copy and a Skip caption that is now false. — real but cosmetic: `CaptureSession` re-reads mic status at record time, so the grant still takes effect; Skip still advances. Fix needs a new re-check surface on app activation. Residual risk recorded.
  - `[false]` `[reject]` blind-hunter: `ProcessTapSource` is single-use, so a second probe would fail. — unreachable: after the first request `permissionStatus` is non-nil, so content never offers `.request` again, and steps are forward-only.
  - `[low]` `[reject]` blind-hunter: the view styles the last action prominent, making Skip primary on Microphone denied. — design choice (forward action is primary), no user harm shown.
  - `[medium]` `[patch]` blind-hunter: stale-step guard in `requestCurrentPermission()` has no test. — grouped with verification-gap row 1; test added.
  - `[low]` `[reject]` blind-hunter: `makeOnboardingCoordinator()` allocates a `ProcessTapSource` (~2 MB ring) per `App.body` evaluation. — confirmed eager ring allocation, but `App.body` re-evaluates rarely and discarded coordinators free it; fix needs a source-factory parameter.
  - `[false]` `[reject]` blind-hunter: a cancelled probe logs as a failure. — the view's unstructured `Task` is never cancelled, so `CancellationError` cannot reach the catch.
  - `[medium]` `[patch]` blind-hunter: content states untested (mic `.granted`, notifications `.granted`/`.notDetermined`/`.unknown`). — grouped with verification-gap row 2; parameterized tests added.
  - `[low]` `[reject]` blind-hunter: `FakePermissionChecker`/`Recorder` duplicated across two test files. — minor drift risk; moving to a shared helper is more than a direct correction.
  - `[false]` `[reject]` blind-hunter: `.accessibilityLabel(title)` is redundant. — required by the repo's `accessibility_label_missing` lint rule.
  - `[low]` `[reject]` edge-case-hunter: stale screen after granting in Settings. — same defect as blind-hunter row 2; same rejection.
  - `[false]` `[reject]` edge-case-hunter: missing category in the injected step map leaves Request dead. — unreachable: both the default map and `AuricleApp`'s map cover all three categories.
  - `[false]` `[reject]` edge-case-hunter: Notifications `.notDetermined` offers no retry. — unreachable: the real `requestNotifications` returns only `.granted`/`.denied`.
  - `[false]` `[reject]` edge-case-hunter: a partial step map breaks "every step has a forward action". — same unreachable condition as the row above it.
  - `[medium]` `[patch]` verification-gap: stale-step guard untested (pre-verified). — patch: gated-step test in `PermissionStepsTests.swift` asserting a late `.advance`/`.remainWithStatus` after Skip is dropped.
  - `[medium]` `[patch]` verification-gap: content table only partly covered for `.unknown`/`.notDetermined` (pre-verified). — patch: parameterized follow-up/actions assertions for every non-granted status of both categories.
  - `[low]` `[reject]` verification-gap other: production step-map wiring in `AuricleApp` is untested. — the accepted `App/` coverage limit (AGENTS.md pitfall); a regression needs a deliberate composition-root edit, and a testable factory adds public surface.
  - `[false]` `[reject]` intent-alignment: Notifications denied remains instead of advancing. — both AC clauses hold: the NFR-R8 copy renders and one tap moves on, nothing blocks; an immediate advance would hide the copy (Design Notes).
  - `[low]` `[reject]` intent-alignment: OS prompts, real tap and SwiftUI view are not exercised by tests. — accepted `App/`/hardware limit; the live tap check is gated at Story 5.6's debug hotkey per the epic plan.
  - `[false]` `[reject]` intent-alignment: Open Settings tests use a fake link map, not the real checker. — the real links are asserted in `Tests/PermissionsTests` (`remediationDeepLinkForMicrophone` etc.); this story tests the pass-through.
  - `[false]` `[reject]` intent-alignment: mic-denied recording AC has no new code. — met by `CaptureSessionTests.micPermissionDeniedRecordsSystemAudioOnlyAndNeverStartsTheMicEngine`.
  - `[medium]` `[patch]` intent-alignment: stale-step guard untested. — grouped with verification-gap row 1.
  - `[low]` `[reject]` intent-alignment: Microphone `.unknown` treated as denied; mic `.granted` content unreachable. — safe default for an `@unknown default` status; the granted branch keeps `make` total.
  - `[false]` `[reject]` intent-alignment: ship step not visible in the diff. — shipping runs after the review, outside the diff.
  - `[false]` `[reject]` intent-alignment: prominent Skip button. — duplicate of blind-hunter row 4, which is a design choice, not a defect.

## Auto Run Result

**Summary:** Replaced Story 5.7's placeholder permission steps with real Microphone, System Audio and Notifications steps. Each screen shows a *why* line, and denied states show recovery copy and buttons. A pure `PermissionStepContent` decides copy and buttons per (category, last status). The System Audio step fires `SystemAudioPermissionProbe` and always hedges. `OnboardingCoordinator` gains Skip/Continue, Open Settings, stored status, and a guard that drops a late request result.

**Files changed:**
- `Package.swift` -- `AppUI` depends on `Capture`; `AppUITests` depends on `Capture` and `Core`.
- `Sources/AppUI/PermissionSteps.swift` (new) -- the three `OnboardingPermissionStep` conformances.
- `Sources/AppUI/PermissionStepContent.swift` (new) -- copy and ordered actions per status.
- `Sources/AppUI/OnboardingCoordinator.swift` -- `permissionStatus`, `permissionContent`, `perform(_:)`, Skip/Continue, Open Settings, required `opener`, stale-result guard.
- `App/Auricle/Onboarding/PermissionStepView.swift` -- render-only view with a labelled button per action.
- `App/Auricle/AuricleApp.swift` -- injects the real steps, `ProcessTapSource()` and the shared opener.
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- passes an opener.
- `Tests/AppUITests/PermissionStepsTests.swift` (new) -- every I/O matrix row, content table, stale-result guard.

**Review findings breakdown:**
- Patched (2 entries, both medium, test-only): stale-step guard test; content-table coverage for non-granted statuses.
- Deferred: none.
- Rejected: 9 low and 11 false. Reasons are in the Review Triage Log.

**Follow-up review recommendation:** `false`. Two medium entries were patched, but both add tests only. No unverified production risk follows from them.

**Verification performed:**
- `swift test --filter AppUITests` -- 49 tests pass.
- `make check` -- exit 0 before and after patches (1548 tests, lint, both Xcode schemes, app bundle checks).

**Residual risks:**
- No live test fires the real Microphone, System Audio or Notifications prompts. The live tap check is planned for Story 5.6.
- After a user grants Microphone in System Settings and returns, the screen still shows denied copy. Skip still advances, and capture reads the real grant at record time.
- Try Again cannot appear in production, because the real checker never returns `.notDetermined` from a microphone request.

## Design Notes

**Notifications "denied → advances" reading.** Advancing immediately would hide the NFR-R8 copy before it renders. Story 5.7's review fixed that same bug class for the Obsidian message. So a denied Notifications step remains, shows the copy, and offers only `[Continue]`. Nothing blocks.

**Copy.** Titles: "Microphone", "System Audio", "Notifications". Why lines:
- Mic: "auricle records your side of the meeting through the microphone, so your own words make it into the notes."
- System Audio: "auricle records what everyone else in the meeting says by capturing your Mac's audio output. macOS asks once."
- Notifications: "auricle tells you when a meeting's summary is ready."

Follow-ups use the epics AC text verbatim: mic denied, System Audio hedge ("If you chose Allow, you're done. If not, you can turn on System Audio Recording for auricle in System Settings."), notifications denied. System Audio standing note: "Without it, recordings contain only your microphone." Skip carries the caption "Recordings will have system audio only."

## Verification

**Commands:**
- `swift test --filter AppUITests` -- expected: all pass, including `PermissionStepsTests`.
- `make check` -- expected: exits 0 (lint, both Xcode schemes, app bundle checks).
