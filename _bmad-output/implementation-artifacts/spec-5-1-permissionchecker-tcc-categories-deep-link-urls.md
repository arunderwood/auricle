---
title: 'Story 5.1: PermissionChecker + TCC Categories + Deep-Link URLs'
type: 'feature'
created: '2026-09-22'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: true
baseline_revision: '07d3c28cc0ff71d1551cdc30becb2540d9c189b0'
context: ['{project-root}/_bmad-output/planning-artifacts/architecture.md']
warnings: ['oversized']
deferred:
  - summary: >-
      Two ACs (the three remediation deep links opening the correct System
      Settings pane; whether macOS ever shows NSUserNotificationsUsageDescription)
      remain empirically unverified on this Mac.
    evidence: |-
      This run had no screen/accessibility-automation access. All three deep
      links returned exit 0 from `open` with no OS-level error, but pane
      correctness was not visually confirmed. NSUserNotificationsUsageDescription
      was removed from Info.plist on documented-platform-behavior grounds
      (UNUserNotificationCenter shows no custom string on any platform), not a
      live on-device trigger. A maintainer should open each of the three deep
      links once, and correct architecture.md Decision 4.4 or restore the
      Info.plist key if either determination is wrong.
    location: >-
      _bmad-output/planning-artifacts/architecture.md:1186-1233, App/Auricle/Info.plist
    severity: low
  - summary: >-
      SystemNotificationCenter.isAuthorized()'s check-then-maybe-request-then-compare
      composition has no test coverage anywhere in the repo.
    evidence: |-
      Verification-gap review (pre-verified): UserNotificationNotifierTests
      bypasses SystemNotificationCenter entirely via FakeCenter, and Package.swift's
      test targets only cover Sources/* — App/ has no swift test target
      (the pitfall AGENTS.md already documents). This is a pre-existing,
      documented App/-layer coverage gap this story relocates but does not
      newly create. Closing it properly means moving the composition logic
      into a Sources/ module or adding an App/ test target — bigger than this
      story's scope.
    location: >-
      App/Auricle/NotificationDelegate.swift:45-56
    severity: medium
---

<intent-contract>

## Intent

**Problem:** TCC/notification-permission checks are scattered today — `App/Auricle/NotificationDelegate.swift`'s `SystemNotificationCenter` calls `UNUserNotificationCenter` directly — and no shared status/remediation API exists for Capture, onboarding, Doctor, or the notification path to converge on (AR-PAT-4, AR-FAIL-6).

**Approach:** Add `Sources/Permissions/PermissionChecker.swift` (+ `TCCCategory.swift`) as the single memoized `check`/`request`/`refresh`/`remediationDeepLink` API over four TCC categories, enforce it with a new swiftlint custom rule, and route the one existing direct call through it.

## Boundaries & Constraints

**Always:** All TCC/notification-permission OS calls happen only inside `PermissionChecker.swift`. `.systemAudioCapture` and `.calendarOAuth` report `.unknown` from both `check` and `request`, with no OS call — `Permissions` has no reachable check for either (the process-tap grant has no public read API; the OAuth token lives in `GoogleCalendarSource`, which `Permissions` does not depend on). Status is memoized per category for the process lifetime; `refresh()` clears the memo (lazy re-query on next `check`) and is wired to `NSWorkspace.shared.notificationCenter` settings-change notifications. `request(_:)`'s result overwrites the memo before returning. `remediationDeepLink(for:)` returns `nil` only for `.calendarOAuth`.

**Never:** Never call `AVCaptureDevice.authorizationStatus(for:)`/`.requestAccess(for:)`, `UNUserNotificationCenter().notificationSettings()`/`.requestAuthorization(options:)`, `CGPreflightScreenCaptureAccess()`, or `CGRequestScreenCaptureAccess()` outside `PermissionChecker.swift`. Never trigger the System Audio Recording OS prompt from `Permissions` — that stays in `Capture`'s `SystemAudioPermissionProbe` (Story 5.2/5.8), which `Permissions` cannot call (`Capture` depends on `Permissions`, not the reverse). Never implement an OAuth flow in `PermissionChecker` — `.calendarOAuth` is status-only. Never relocate `SystemNotificationCenter` out of `App/Auricle/NotificationDelegate.swift` — its doc comment ("The real adapter lives in App/") is an existing, intentional layering decision this story doesn't change, so `Sources/Notifications` does not gain a `Permissions` dependency.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| systemAudioCapture check/request | any state | `.unknown`, no OS call | No error expected |
| calendarOAuth check/request | any state | `.unknown`, no OS call | No error expected |
| microphone/notifications repeat check | memo already populated this process | returns memoized value, no re-query | No error expected |
| refresh() called | memo populated | memo cleared; next `check` re-queries | No error expected |
| remediationDeepLink(.calendarOAuth) | n/a | `nil` | No error expected |
| remediationDeepLink(other 3 categories) | n/a | the verified System Settings URL | No error expected |

</intent-contract>

## Code Map

- `Sources/Permissions/TCCCategory.swift` -- new; `TCCCategory` (`.systemAudioCapture`, `.microphone`, `.notifications`, `.calendarOAuth`) and `PermissionStatus` (`.granted`, `.denied`, `.notDetermined`, `.unknown`) — file layout per architecture.md:2340-2341
- `Sources/Permissions/PermissionChecker.swift` -- new; `PermissionChecking` protocol + `PermissionChecker` conformance (architecture.md:2340)
- `Sources/Permissions/ManifestPlaceholder.swift` -- delete once real code lands (its own header says so)
- `Tests/PermissionsTests/PermissionCheckerTests.swift` -- new
- `App/Auricle/NotificationDelegate.swift:45-56` -- `SystemNotificationCenter.isAuthorized()` currently calls `UNUserNotificationCenter.current().notificationSettings()` / `.requestAuthorization(options:)` directly; this is the one existing bypass the AC names
- `App/Auricle/AuricleApp.swift:28` (`makeNotifier()`) -- constructs `SystemNotificationCenter()` with no args; needs a `PermissionChecker` instance passed in
- `App/Auricle/Info.plist` -- has `NSScreenCaptureUsageDescription` (to remove), `NSMicrophoneUsageDescription` and `NSUserNotificationsUsageDescription` (both missing Decision 4.4's trailing period)
- `_bmad-output/planning-artifacts/architecture.md:1186-1233` -- Decision 4.4 table holds the deep-link candidates and Info.plist strings this story verifies/records
- `.swiftlint.yml:116-` -- `custom_rules` block; add `permission_checker_bypass` following the existing entries' shape (regex + `match_kinds` + `excluded`)
- `scripts/lint-fixtures/CustomLintRuleFixtures.swift` -- add one `// expect: permission_checker_bypass` line per banned call shape; `scripts/verify-custom-lint-rules.sh` already asserts every `custom_rules` id has a marked line
- `scripts/check.sh:95-144` (`phase_app`) -- after the embedded-`auricle-cli` assertion, add a `plutil` check for `NSAudioCaptureUsageDescription` in the built bundle's `Info.plist`

## Tasks & Acceptance

**Execution:**
- `Sources/Permissions/TCCCategory.swift` -- declare `TCCCategory` and `PermissionStatus` with the exact cases above -- AC's required enum shape
- `Sources/Permissions/PermissionChecker.swift` -- declare `PermissionChecking` (`check`, `request`, `refresh`, `remediationDeepLink`) and `PermissionChecker`; inject the microphone/notifications OS queries as closures (mirroring `Core/Log.swift`'s `sink` closure convention) so `Tests/PermissionsTests` can drive them without live TCC state; `.microphone` uses `AVCaptureDevice.authorizationStatus(for: .audio)`/`.requestAccess(for: .audio)`; `.notifications` uses `UNUserNotificationCenter.current().notificationSettings()`/`.requestAuthorization(options:)`, mapping `.authorized`/`.provisional` to `.granted` -- AR-PAT-4 single-implementation primitive
- `Sources/Permissions/PermissionChecker.swift` -- observe `NSWorkspace.shared.notificationCenter` settings-change notifications and call `refresh()` on receipt -- AR-PAT-PermissionDetection
- `Sources/Permissions/PermissionChecker.swift` -- implement `remediationDeepLink(for:)`: `.systemAudioCapture` → `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture`, `.microphone` → `…?Privacy_Microphone`, `.notifications` → `x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications` (Decision 4.4 candidates), `.calendarOAuth` → `nil`
- `Sources/Permissions/ManifestPlaceholder.swift` -- delete
- `App/Auricle/NotificationDelegate.swift` -- change `SystemNotificationCenter.isAuthorized()` to call `PermissionChecker.check(.notifications)`, then `.request(.notifications)` if `.notDetermined`, returning `true` only for `.granted` -- moves the direct call behind `PermissionChecker`
- `App/Auricle/AuricleApp.swift` -- construct one `PermissionChecker` and pass it into `SystemNotificationCenter`'s initializer (add a stored property) -- keeps the memoized checker's state shared for the process
- `.swiftlint.yml` -- add `permission_checker_bypass` to `custom_rules`, banning the five call shapes listed in Boundaries, excluded only for `Sources/Permissions/PermissionChecker.swift`
- `scripts/lint-fixtures/CustomLintRuleFixtures.swift` -- add one marked violation line per banned call shape
- `App/Auricle/Info.plist` -- remove `NSScreenCaptureUsageDescription`; add `NSAudioCaptureUsageDescription` as a literal key (not `INFOPLIST_KEY_`) = `"auricle records your meeting audio so it can transcribe what's said."`; add the trailing period to `NSMicrophoneUsageDescription`'s string
- Verify on this Mac: `open` each of the three remediation deep links (System Audio Recording, Microphone, Notifications) and confirm each opens the correct System Settings pane; update Decision 4.4's table in `architecture.md` with the verified URL if it differs from the candidate
- Verify on this Mac: trigger a live Notifications permission request from a debug build and observe whether macOS shows the `NSUserNotificationsUsageDescription` string; record the finding, and either remove the key from `Info.plist` (never shown) or add Decision 4.4's trailing period to it (shown)
- `scripts/check.sh` (`phase_app`) -- add a `plutil` assertion that the built `AuricleApp.app`'s `Info.plist` contains `NSAudioCaptureUsageDescription`, failing the phase if absent
- `Tests/PermissionsTests/PermissionCheckerTests.swift` -- unit-test the I/O matrix above: memoization, `refresh()` invalidation, `.systemAudioCapture`/`.calendarOAuth` always `.unknown`, `remediationDeepLink` for all four categories

**Acceptance Criteria:**
- Given the `Permissions` target, when `PermissionChecker` is declared, then its public API is `check(_:) async -> PermissionStatus`, `request(_:) async -> PermissionStatus`, `refresh()`, `remediationDeepLink(for:) -> URL?`, over the four `TCCCategory` cases and four `PermissionStatus` cases
- Given any caller outside `PermissionChecker.swift`, when it calls one of the five banned OS APIs, then `swiftlint lint` fails via `permission_checker_bypass`, and `scripts/verify-custom-lint-rules.sh` proves each banned call shape still fires
- Given `App/Auricle/NotificationDelegate.swift`'s `SystemNotificationCenter`, when it checks or requests notification authorization, then it calls `PermissionChecker` and no longer calls `UNUserNotificationCenter.current().notificationSettings()`/`.requestAuthorization(options:)` directly
- Given the built `AuricleApp.app`, when `scripts/check.sh app` runs, then it fails if `NSAudioCaptureUsageDescription` is absent from the bundle's `Info.plist`, and passes once present with Decision 4.4's exact string
- Given `App/Auricle/Info.plist`, when the story lands, then `NSScreenCaptureUsageDescription` is absent, `NSAudioCaptureUsageDescription` is a literal key with Decision 4.4's exact string including the trailing period, and `NSMicrophoneUsageDescription`'s string matches Decision 4.4 exactly including the trailing period
- Given the three System Settings remediation deep links, when each is opened on this Mac, then it opens the correct pane, and `architecture.md` Decision 4.4 records the verified URL

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 17 findings — high 0, medium 4, low 10, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind-hunter) `scripts/check.sh`'s new `NSAudioCaptureUsageDescription` `plutil` check only verifies the key is present/extractable, never compares its value to Decision 4.4's exact string — a wrong or truncated string would still pass. Action: extended the check to compare the extracted value against the expected string.
  - `[low]` `[patch]` (blind-hunter) `Sources/Permissions/PermissionChecker.swift` imports `Core` but never references a `Core` symbol. Action: removed the unused import.
  - `[false]` `[reject]` (blind-hunter) claimed `TCCCategory.swift`'s "no public read/request API" comment contradicts the swiftlint rule naming `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` as banned — refuted: those two functions read/request the older Screen Recording TCC category, not the process-tap grant Decision 4.4 and epics.md Story 5.1 explicitly say has no public API; the AC itself lists them as banned defensively, not as evidence of an available check.
  - `[low]` `[patch]` (blind-hunter) `PermissionChecker` registers a live `NSWorkspace.shared.notificationCenter` observer in every instance (11 in `PermissionCheckerTests` alone) and never removes it. Action: added a `deinit` that removes the observer.
  - `[medium]` `[patch]` (blind-hunter) the private `status(for: AVAuthorizationStatus)` / `status(for: UNAuthorizationStatus)` mapping functions — the logic that decides granted/denied/notDetermined/unknown per OS status, including `.restricted`/`.provisional`/`.ephemeral` — have zero test coverage; every test injects `PermissionStatus` directly, bypassing the mapping. Action: loosened access to `internal` and added direct case-by-case tests.
  - `[medium]` `[patch]` (blind-hunter) the `NSWorkspace.didActivateApplicationNotification` → `refresh()` wiring (the bundle-ID filter in `startObservingSettingsChanges()`) has no test. Action: extracted the bundle-ID comparison into a small pure, directly-tested function; the untestable `NSNotification`/`NSRunningApplication` plumbing around it stays thin.
  - `[false]` `[reject]` (blind-hunter) claimed the `permission_checker_bypass` regex's unqualified `.notificationSettings(`/`.requestAuthorization(options:` alternatives are an unaddressed risk — refuted: the rule's own inline comment already documents and accepts this tradeoff, matching every other `custom_rules` entry's identical, already-accepted regex-matching limitation stated in this file's header.
  - `[low]` `[defer]` (blind-hunter) two spec ACs (deep-link pane correctness, live Notifications-prompt string) remain empirically unverified because this run had no screen/accessibility automation — real but not resolvable by more code; already disclosed in the spec's Design Notes and `## Auto Run Result`, needs the maintainer.
  - `[low]` `[patch]` (blind-hunter) `architecture.md`'s new sentence states `UNUserNotificationCenter` shows no custom string "on any platform" as settled fact, while the spec's own Design Notes flags this as unverified-on-this-Mac reasoning, not an empirical result. Action: reworded the `architecture.md` sentence to say so explicitly.
  - `[low]` `[reject]` (edge-case-hunter) concurrent first-time `check()` calls for the same category can each see an empty memo and both re-query — real, but both underlying OS queries are read-only/idempotent (no prompt, no side effect), so the only cost is duplicate work; the fix (in-flight query coalescing) is more than a direct correction, and duplicate idempotent queries are unlikely to matter in practice.
  - `[medium]` `[patch]` (edge-case-hunter) a `check()` in flight when a `request()` for the same category completes can, on resuming, overwrite `request()`'s freshly-granted memo value with its own now-stale result. Action: `check()` now only writes the memo if nothing claimed it while it awaited, instead of unconditionally overwriting.
  - `[low]` `[patch]` (edge-case-hunter) the `NSWorkspace` observer is registered from inside a detached `Task` in `init`, leaving a brief window where an activation is silently missed. Action: register the observer synchronously in `init`; only the closure's `refresh()` call needs actor isolation.
  - `[low]` `[patch]` (edge-case-hunter) the observer's bundle-ID comparison (`activated.bundleIdentifier == Bundle.main.bundleIdentifier`) doesn't guard against both sides being `nil`. Action: `guard let` on `Bundle.main.bundleIdentifier` before comparing.
  - `[false]` `[reject]` (edge-case-hunter, deletion, low confidence) flagged removing `NSScreenCaptureUsageDescription` as possibly regressing an existing caller — refuted: epics.md's own Story 5.1 AC mandates the removal ("auricle no longer uses screen capture"), and no caller of the Screen Recording CG functions exists in production code.
  - `[low]` `[reject]` (edge-case-hunter, claim) the spec's Tasks/AC text says "five banned call shapes" where the boundaries list and the actual lint rule/fixtures cover six — real miscount, but its only fix is editing this spec's prose; code is already fully correct. Rejected per the standing rule against findings whose fix is only a spec edit.
  - `[low]` `[patch]` (edge-case-hunter, claim — same defect as the first `scripts/check.sh` row above) confirms the AC's "passes ... with Decision 4.4's exact string" is not actually checked by the `plutil` presence-only assertion. Action: shares the fix above.
  - `[medium]` `[defer]` (verification-gap, pre-verified, filed disposition `defer`) `SystemNotificationCenter.isAuthorized()`'s new check-then-maybe-request-then-compare composition (`App/Auricle/NotificationDelegate.swift`) has no test anywhere — `UserNotificationNotifierTests` bypasses it via `FakeCenter`, and `App/` has no `swift test` target. Pre-existing, documented (AGENTS.md) App/-layer coverage gap this story relocates but does not newly create; closing it properly (move the composition into a `Sources/` module, or add an App/ test target) is bigger than this story's scope.

## Design Notes

`PermissionChecker` needs reference semantics for its memo plus safe concurrent access under Swift 6.3 strict concurrency — an `actor` is the natural fit (like `Verifier`), with `refresh()` bridged from the synchronous `NSWorkspace` notification callback via `Task { await checker.refresh() }`. Sketch of the injection point that keeps `Tests/PermissionsTests` independent of live TCC state:

```swift
public actor PermissionChecker: PermissionChecking {
    private var memo: [TCCCategory: PermissionStatus] = [:]
    private let queryMicrophone: () async -> PermissionStatus
    private let queryNotifications: () async -> PermissionStatus
    // production init supplies the real AVFoundation/UserNotifications
    // closures; PermissionCheckerTests supplies canned ones.
}
```

`Tests/PermissionsTests` needs no `FakePermissionChecker` of its own — it tests the real `PermissionChecker` with injected closures. A consumer test double (e.g. `FakeCenter` in `Tests/NotificationsTests/UserNotificationNotifierTests.swift`) is the existing per-test-target convention for AR-PAT-7 and isn't needed here since App/'s `SystemNotificationCenter` has no `swift test` coverage today (a pre-existing, documented gap — see AGENTS.md's App/-logic pitfall — that this story doesn't newly introduce or is asked to close).

**Unresolved manual verification (needs the maintainer, not more code):** this run had no screen/accessibility-automation access, so the two on-this-Mac manual checks below could not be completed visually:
- All three remediation deep links (`open`'d directly) returned exit 0 with no OS-level error, but which System Settings pane each actually lands on was not visually confirmed. `architecture.md` Decision 4.4 still reads "Candidate" for the System Audio Recording and Microphone URLs — a maintainer should open each once and confirm, then drop the "Candidate" wording (or correct the URL) if needed.
- `NSUserNotificationsUsageDescription` was removed from `Info.plist` on documented-platform-behavior grounds (`UNUserNotificationCenter`'s permission dialog shows no custom app-supplied string on any platform, unlike `AVCaptureDevice`'s), not from a live on-device trigger of the prompt — a maintainer who knows otherwise should restore the key with Decision 4.4's trailing period.

## Verification

**Commands:**
- `swift build && swift test --filter PermissionsTests` -- expected: builds clean, new tests pass
- `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` -- expected: no violations
- `./scripts/verify-custom-lint-rules.sh` -- expected: every custom rule, including `permission_checker_bypass`, fires on its marked fixture line
- `scripts/check.sh app` -- expected: passes, including the new `NSAudioCaptureUsageDescription` assertion
- `scripts/check.sh lint` -- expected: passes

**Manual checks (if no CLI):**
- `open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"` (and the Microphone / Notifications equivalents) on this Mac -- expected: System Settings opens directly to the matching privacy pane
- Trigger a live Notifications permission request from a debug build -- expected: observe and record whether the `NSUserNotificationsUsageDescription` string is shown

## Auto Run Result

**Summary:** Implemented Story 5.1 — `Permissions/PermissionChecker.swift` is now the single memoized `check`/`request`/`refresh`/`remediationDeepLink` API over four `TCCCategory` cases, enforced by a new swiftlint custom rule, with the one existing direct `UNUserNotificationCenter` call in `App/Auricle/NotificationDelegate.swift` routed through it.

**Files changed:**
- `Sources/Permissions/TCCCategory.swift` (new) — `TCCCategory` + `PermissionStatus` enums
- `Sources/Permissions/PermissionChecker.swift` (new) — `PermissionChecking` protocol + `PermissionChecker` actor: memoized check/request, synchronous `NSWorkspace` observer registration + `deinit` cleanup, race-safe memo writes, extracted `shouldRefresh`/`status(for:)` helpers
- `Sources/Permissions/ManifestPlaceholder.swift` (deleted)
- `Tests/PermissionsTests/PermissionCheckerTests.swift` (new) — 17 tests: I/O matrix, both status-mapping functions, `shouldRefresh`
- `App/Auricle/NotificationDelegate.swift` — `SystemNotificationCenter.isAuthorized()` now calls `PermissionChecker` instead of `UNUserNotificationCenter` directly
- `App/Auricle/AuricleApp.swift` — constructs one process-lifetime `PermissionChecker`, passed into `SystemNotificationCenter`
- `App/Auricle/Info.plist` — `NSScreenCaptureUsageDescription` removed; `NSAudioCaptureUsageDescription` added (literal key, Decision 4.4 string); `NSMicrophoneUsageDescription` given its trailing period; `NSUserNotificationsUsageDescription` removed (see Residual risks)
- `.swiftlint.yml` — new `permission_checker_bypass` custom rule
- `scripts/lint-fixtures/CustomLintRuleFixtures.swift` — 6 marked violation lines for the new rule
- `scripts/check.sh` — `phase_app` now asserts the built bundle's `NSAudioCaptureUsageDescription` exactly matches Decision 4.4's string, not just that the key is present
- `_bmad-output/planning-artifacts/architecture.md` — Decision 4.4 records the `NSUserNotificationsUsageDescription` removal rationale, explicitly marked as documented-platform-behavior reasoning rather than an on-device confirmation

**Review findings breakdown** (17 findings across blind-hunter, edge-case-hunter, verification-gap; full detail in `## Review Triage Log` above):
- **Patched (9 distinct fixes, 10 findings):** `scripts/check.sh` exact-string check (2 findings, same root cause); unused `import Core` removed; `PermissionChecker` observer leak fixed with `deinit`; `status(for:)` mapping functions given direct test coverage; settings-change → `refresh()` wiring given direct test coverage via extracted `shouldRefresh`; `check()`/`request()` race on the memo fixed; observer registration moved synchronous into `init`; nil-bundle-ID guard added; `architecture.md` wording softened to disclose it's unverified-on-device.
- **Rejected (4):** doc-comment-vs-lint-rule "contradiction" (refuted — different TCC categories); regex receiver-unqualification risk (already documented, accepted, consistent with every other rule in the file); `NSScreenCaptureUsageDescription` removal safety (refuted — epics.md's own AC mandates it); "five vs six banned call shapes" spec miscount (real, but its only fix is editing this spec's prose — rejected per the standing rule against spec-only-edit findings).
- **Deferred (2):** the two on-this-Mac manual verifications (deep-link pane correctness, live Notifications-prompt string) — no screen/accessibility automation was available in this run; `SystemNotificationCenter.isAuthorized()`'s composition has no test — a pre-existing, documented `App/`-layer coverage gap this story relocates but doesn't newly create.

**Follow-up review recommendation:** `true`. Three `medium`-severity findings were patched in this pass (the `status(for:)` mapping coverage, the settings-change refresh wiring coverage, and the `check()`/`request()` memo race fix) — together they touch the actor's concurrency behavior non-trivially. A follow-up pass should specifically re-examine the race fix and the `nonisolated(unsafe)` observer-handle pattern under the full patched diff, now that both exist together, rather than trusting each patch's isolated correctness.

**Verification performed:**
- `swift build` — clean
- `swift test` (full suite) — 1422/1422 passed (was 1415 before patches; +7 new tests)
- `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` — 0 violations, 385 files
- `./scripts/verify-custom-lint-rules.sh` — 21/21 marked lines fired, including all 6 `permission_checker_bypass` lines
- `scripts/check.sh app` — passed, including the new exact-string `NSAudioCaptureUsageDescription` assertion
- `scripts/check.sh lint` — passed
- Manual: `open`'d all three remediation deep links on this Mac — each returned exit 0 with no OS-level error; pane correctness was not visually confirmed (no screen/accessibility automation available)
- Manual: live Notifications-prompt string was not triggered/observed (same limitation); the `Info.plist` key removal rests on documented `UNUserNotificationCenter` platform behavior instead

**Residual risks:**
- The three remediation deep links (System Audio Recording, Microphone, Notifications) are unverified for pane-correctness on this Mac — `architecture.md` Decision 4.4 still reads "Candidate" for two of them. Low risk: they are macOS's own documented System Settings deep-link scheme, and `open` accepted all three without error.
- `NSUserNotificationsUsageDescription` was removed from `Info.plist` based on documented platform behavior, not a live on-device trigger of the prompt. Low risk given `architecture.md`'s own prior wording already hedged this key as "(where applicable)."
- `SystemNotificationCenter.isAuthorized()`'s new composition logic is untestable in this repo's current `App/`-has-no-test-target structure (pre-existing, AGENTS.md-documented gap).
