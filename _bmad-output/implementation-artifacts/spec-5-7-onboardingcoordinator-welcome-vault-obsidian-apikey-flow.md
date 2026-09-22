---
title: 'Story 5.7: OnboardingCoordinator + Welcome / Vault / Obsidian / API Key / Expectation Flow'
type: 'feature'
created: '2026-09-22'
status: 'done'
baseline_revision: '2ca55f066c016bfc0cda791f2c9c49df593376de'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '_bmad-output/planning-artifacts/epics.md'
warnings: ['oversized']
deferred:
  - summary: >-
      obsidian://open?vault=<lastPathComponent> may not resolve for a vault Obsidian has
      never opened before, which would need path= instead for first-time resolution.
    evidence: |-
      Plausible per general knowledge of Obsidian's URI scheme, but not independently
      testable in this environment. It is also the literal format epics.md's Story 5.7 AC
      specifies verbatim, so this diff correctly implements what was asked; if the
      underlying URI behavior is wrong, the fix belongs in a sprint-change-proposal against
      that AC, not a silent deviation here. Settles by: testing the URI against a
      freshly-picked, never-opened-in-Obsidian vault, or checking Obsidian's own URI docs.
    location: >-
      Sources/AppUI/OnboardingConfigureModel.swift:421-432
    severity: medium (unverified)
  - summary: >-
      Branch claude/story-5-7-completion-f04b9b violates AGENTS.md's branch-naming policy
      (semantic type/short-kebab-description names, never the claude/ auto-generated prefix).
    evidence: |-
      Real and current, but pre-existing — the branch was already named this at session
      start, not produced by this diff, so no code change in this spec can fix it. Handle
      operationally by shipping from a compliantly-named branch for the PR.
    location: >-
      git branch (repository-level, not a source file)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** auricle has no first-run onboarding; the app opens straight to the empty main window with no vault, Obsidian, or API-key setup, and Story 5.8/5.9's permission and self-wikilink steps have no coordinator to plug into.

**Approach:** Add an `OnboardingCoordinator` state machine in `AppUI` over Welcome → Microphone → System Audio → Notifications → Configure (vault path, Obsidian check, API key, expectations) → Done, gated by a first-run marker in Application Support. Permission steps are a protocol (`OnboardingPermissionStep`) with a default auto-advancing implementation for this story; Story 5.8 later supplies richer conforming steps without touching the coordinator. All SwiftUI views live in `App/Auricle/Onboarding/`.

## Boundaries & Constraints

**Always:**
- Coordinator/model/protocol logic lives in `Sources/AppUI` (unit-testable via `swift test`); SwiftUI views live in `App/Auricle/Onboarding/`.
- Vault path validation reuses `VaultWriter`'s existing exists+writable check (make it callable without creating the vault or a meetings subdir) — never duplicate that logic (AR-PAT-4).
- `self.wikilink` is never written by this story (Story 5.9's job); Done writes only `vault_path` via `ConfigWriter` and, if provided, the Anthropic key via `KeychainAPIKey.write` (never through `ConfigWriter`, which rejects secret-shaped keys).
- Marker existence/write take an injectable Application-Support directory (mirror `DatabasePoolFactory`'s pattern) so tests never touch the real one.
- Onboarding gates `AuricleApp`'s root view; marker absent → onboarding root; present → today's `AuricleRootView()`.

**Never:**
- Do not implement Story 5.8's per-permission-step copy/buttons (Open Settings / Skip / Try Again) or Story 5.2's `SystemAudioPermissionProbe` — out of scope, protocol seam only.
- Do not implement Story 5.9's self-wikilink sub-step.
- Do not auto-create the vault directory from the picker.
- Do not write a test note when checking Obsidian.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| First launch | No marker in Application Support | Onboarding root view renders at Welcome | — |
| Repeat launch | Marker present | `AuricleRootView()` renders directly, no onboarding | — |
| Vault picker: valid dir | Existing, writable directory URL | Validation succeeds, path accepted | — |
| Vault picker: missing/not-a-dir | Nonexistent path or a file path | Rejected | Surfaces `VaultWriter.WriteError.vaultPathMissing` |
| Vault picker: not writable | Existing dir, no write permission | Rejected | Surfaces `VaultWriter.WriteError.vaultPathNotWritable` |
| Obsidian installed | `obsidian://open?vault=<name>` opener returns true | Check passes, advances | — |
| Obsidian not installed | Opener returns false | Shows "Install Obsidian to use auricle's vault output", does not block | — |
| API key provided | Non-empty key string | `KeychainAPIKey.write` called, advances | — |
| API key skipped | User skips | No Keychain write, advances | — |
| Onboarding completes | Done reached | Marker written; `ConfigWriter.set("vault_path", ...)` called | — |

</intent-contract>

## Code Map

- `Sources/Persist/VaultWriter.swift` -- expose the existing private `validateVaultPath(_:)` check (directory exists + writable) as `public static func validateVaultPath(_ vaultPath: URL) throws` so onboarding can validate without resolving/creating a meetings subdir.
- `Sources/AppUI/OnboardingStep.swift` -- new: `public enum OnboardingStep: CaseIterable, Sendable { case welcome, microphone, systemAudio, notifications, configure, done }`.
- `Sources/AppUI/OnboardingPermissionStep.swift` -- new: `OnboardingPermissionOutcome { case advance, remainWithStatus(PermissionStatus) }`, `protocol OnboardingPermissionStep: Sendable { var category: TCCCategory { get }; func request(using: PermissionChecking) async -> OnboardingPermissionOutcome }`, `struct DefaultPermissionStep: OnboardingPermissionStep` (calls `checker.request(category)`, always returns `.advance`).
- `Sources/AppUI/OnboardingMarker.swift` -- new: `enum OnboardingMarker { static func exists(applicationSupportDirectory: URL) -> Bool; static func write(applicationSupportDirectory: URL) throws }`, mirrors `Sources/State/DatabasePoolFactory.swift`'s create-dir-if-needed pattern, subpath `com.auricle.app/onboarding-completed`.
- `Sources/AppUI/OnboardingConfigureModel.swift` -- new: `public typealias URLOpener = @Sendable (URL) async -> Bool`; validates vault path (via `VaultWriter.validateVaultPath`), builds the Obsidian vault URL and calls the injected `URLOpener`, writes the API key (`KeychainAPIKey.write`) or skips, and on finish calls `ConfigWriter.set("vault_path", to:)`.
- `Sources/AppUI/OnboardingCoordinator.swift` -- new: `@MainActor @Observable final class OnboardingCoordinator`. Holds `step: OnboardingStep`, injected `permissionSteps: [TCCCategory: any OnboardingPermissionStep]` (default `DefaultPermissionStep` for `.microphone`/`.systemAudioCapture`/`.notifications`), `configure: OnboardingConfigureModel`, injected `PermissionChecking`. Methods: `advance()`, `requestCurrentPermission() async`, `completeOnboarding() throws` (writes marker + vault_path).
- `App/Auricle/Onboarding/OnboardingRootView.swift` -- new: hosts `OnboardingCoordinator`, switches on `step` to the per-step view.
- `App/Auricle/Onboarding/WelcomeStepView.swift` -- new: static copy *"Let's get auricle set up — 4 quick steps"* naming Mic/System Audio/Notifications/Configure; no TCC prompt.
- `App/Auricle/Onboarding/PermissionStepView.swift` -- new: single view reused for Microphone/System Audio/Notifications; a button that calls `coordinator.requestCurrentPermission()`.
- `App/Auricle/Onboarding/ConfigureStepView.swift` -- new: sequences the 4 sub-steps (vault picker via `NSOpenPanel`, Obsidian check button, API key `SecureField` with skip, expectations copy *"Start a recording before your meeting and stop it after; you'll get a notification when the summary is ready"*).
- `App/Auricle/Onboarding/DoneStepView.swift` -- new: quiet "You're set up" state; calls `coordinator.completeOnboarding()` on appear.
- `App/Auricle/AuricleApp.swift` -- gate `WindowGroup` content: `OnboardingMarker.exists(...)` ? `AuricleRootView()` : `OnboardingRootView(...)`; supply the production `URLOpener` as `{ url in (try? await NotificationDelegate.openInDefaultApp(url)) != nil }`.
- `Package.swift` -- add `"Core"`, `"Persist"`, `"Permissions"`, `"ClaudeSummarizer"` to the `AppUI` target's `dependencies` (currently `[]`).
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- new: Swift Testing, matching `RecordingIndicatorTests.swift`'s style.

## Tasks & Acceptance

**Execution:**
- `Sources/Persist/VaultWriter.swift` -- make `validateVaultPath` public -- lets the picker validate without touching `resolveMeetingsDirectory`'s creation path, no duplicated logic.
- `Package.swift` -- add `AppUI` dependencies -- unblocks importing `Core`/`Persist`/`Permissions`/`ClaudeSummarizer` from the new files.
- `Sources/AppUI/OnboardingStep.swift`, `OnboardingPermissionStep.swift`, `OnboardingMarker.swift`, `OnboardingConfigureModel.swift`, `OnboardingCoordinator.swift` -- implement per Code Map -- the full testable state machine.
- `App/Auricle/Onboarding/*.swift` -- implement per Code Map -- the SwiftUI presentation layer, no business logic.
- `App/Auricle/AuricleApp.swift` -- gate root view on the marker -- satisfies "onboarding runs when marker absent, in the existing window."
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- cover the I/O matrix rows plus every `OnboardingStep` transition and `advance()`/`requestCurrentPermission()` against a `PermissionChecking` test double.

**Acceptance Criteria:**
- Given no marker in Application Support, when the app launches, then onboarding renders in the existing window starting at Welcome.
- Given a marker exists, when the app launches, then `AuricleRootView()` renders directly and onboarding is skipped.
- Given the current step is a permission step, when `requestCurrentPermission()` runs against the default step, then it calls `PermissionChecking.request(category)` and advances regardless of returned status.
- Given the vault picker, when a non-existent or non-writable path is chosen, then validation fails with the matching `VaultWriter.WriteError` and the step does not advance.
- Given the Obsidian check, when the opener returns false, then the non-blocking "Install Obsidian" message shows and the step still advances.
- Given the API key sub-step, when skipped, then no Keychain write occurs and the step advances.
- Given Done renders, when `completeOnboarding()` runs, then the marker is written and `ConfigWriter.set("vault_path", ...)` is called exactly once.
- Given `swift test`, then `AppUITests` passes including the new `OnboardingCoordinatorTests`.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 19 findings — high 0, medium 11, low 5, false 2, maybe-false 1
- findings:
  - `[medium]` `[patch]` blind-hunter: Obsidian check's button `Task` calls `checkObsidian()` then unconditionally sets `subStep = .apiKey` on the next line with no yield in between — the conditional "Install Obsidian to use auricle's vault output" text can never render before the view switches away, breaking the spec's own AC that the message shows. — patch: restructure so the result renders and the user (or a short delay) advances after it's observable, not synchronously in the same continuation.
  - `[maybe-false]` blind-hunter: `obsidian://open?vault=<lastPathComponent>` may not resolve for a vault Obsidian has never opened before (needs `path=` for first-time resolution) — plausible per general knowledge of Obsidian's URI scheme, but not independently executable/verifiable in this environment, and it is the literal format epics.md's Story 5.7 AC specifies verbatim. — what would settle it: manually testing the URI against a freshly-picked, never-opened-in-Obsidian vault, or checking Obsidian's own URI documentation; if true, severity is medium (unverified).
  - `[medium]` `[patch]` blind-hunter: `apiKeySubStep`'s Save button uses `try? coordinator.configure.setAPIKey(apiKeyText)` and always advances — a Keychain write failure is silently discarded and the user believes the key was saved. — patch: surface the failure and keep the user on the sub-step (or otherwise signal it) instead of swallowing it.
  - `[medium]` `[patch]` blind-hunter: `DoneStepView.onAppear` only logs `completeOnboarding()` failures; "You're set up" renders unconditionally regardless of outcome. — patch: render a retry-capable error state on failure instead of the success text.
  - `[medium]` `[patch]` blind-hunter: `completeOnboarding()` isn't atomic (vault path can land in config.toml while the marker write still fails) and there's no recovery path — a relaunch restarts onboarding from Welcome, discarding prior in-memory selections. `configure.finish()` and `OnboardingMarker.write` are each independently idempotent, so a retry affordance (the same fix as the row above) is the smallest correct mitigation. — patch: covered by the `DoneStepView` retry-state fix above; no separate change needed.
  - `[false]` `[reject]` blind-hunter: no back/cancel navigation across the six steps. — refutation: the epics AC describes only a forward state machine for onboarding itself and explicitly assigns step re-run to Settings/Doctor (Stories 9.1/9.2); the current design matches that intent, not a gap in it.
  - `[low]` `[patch]` blind-hunter: the API key `SecureField` accepts whitespace-only input (`.disabled(apiKeyText.isEmpty)` doesn't trim). — patch: trivial fix, guard on trimmed emptiness instead.
  - `[low]` `[reject]` blind-hunter: flags that the Obsidian-message bug (row 1) is exactly the class of defect `App/`-only logic can't get automated coverage for. — not worth fixing as this story's problem: building SwiftUI view-rendering test infrastructure is explicitly out of scope (this story's own boundaries, and Story 5.5's precedent already accepted the same limitation); the underlying bug it points at is separately patched above.
  - `[low]` `[reject]` blind-hunter: a second `WindowGroup` window (e.g. via "New Window") would get its own independent `OnboardingCoordinator`. — not worth fixing as this story's problem: `WindowGroup`'s default multi-window support predates this story (Story 1.1), unlikely to be exercised by the single local user during onboarding, and disabling it is more than a trivial guard.
  - `[medium]` `[patch]` edge-case-hunter: same Keychain-write-swallowed defect as the blind-hunter row above (`ConfigureStepView.swift` Save button). — patch: same fix, tracked together.
  - `[medium]` `[patch]` edge-case-hunter: `PermissionStepView`'s Continue button has no re-entrancy guard — a second tap before the in-flight `requestCurrentPermission()` `Task` completes starts a second request/advance that can skip a whole permission step. — patch: guard against a second tap while a request is in flight (e.g. a local `isRequesting` state disabling the button).
  - `[medium]` `[patch]` edge-case-hunter: same `DoneStepView` false-success defect as the blind-hunter row above. — patch: same fix, tracked together.
  - `[medium]` `[patch]` edge-case-hunter: same Obsidian-message-unreachable defect as the blind-hunter row above (filed as a claims-check finding). — patch: same fix, tracked together.
  - `[medium]` `[patch]` verification-gap: `checkObsidian()`'s constructed URL (scheme/host/`vault` query item) is never asserted by any test — both Obsidian tests use an opener closure that ignores its `URL` argument, so a regression to the URL construction would ship with a fully green suite. Pre-verified per this layer's evidence rules. — patch: add a test using the existing `Recorder<Value>` pattern to capture and assert on the opener's `URL` argument.
  - `[medium]` `[patch]` verification-gap: same Keychain-write-swallowed defect as above, filed under "Other findings." — patch: same fix, tracked together.
  - `[medium]` `[defer]` intent-alignment: branch `claude/story-5-7-completion-f04b9b` violates AGENTS.md's branch-naming policy (never the `claude/` auto-generated prefix). Real, but pre-existing — the branch was already named this at session start, not produced by this diff, and this spec's code changes can't fix a branch name. — handled operationally when this story is shipped (a compliantly-named branch for the PR), not via this spec.
  - `[low]` `[reject]` intent-alignment: `AuricleApp.swift`'s marker-gated root-view selection (the actual "onboarding runs" / "is skipped" behavior) has no automated coverage — only its two testable halves (`OnboardingMarker`, `OnboardingCoordinator`'s initial state) do, per the `App/`-vs-`Sources/` split. — same accepted, non-trivial-to-fix limitation as the blind-hunter test-coverage row above; not this story's problem to solve.
  - `[low]` `[reject]` intent-alignment: the Configure/Permission/Welcome/Done SwiftUI views' behaviors (Skip semantics, button flows, exact copy) are untested for the same `App/`-vs-`Sources/` reason. — same as the row above.
  - `[false]` `[reject]` intent-alignment: notes the self-authored spec's own verification bar doesn't demand `App/`-layer coverage the way epics.md's narrative phrasing might suggest to an outside reader. — refutation: this restates the two rows above without identifying an additional defect; a spec's verification section matching its own stated scope is not itself a defect.

## Auto Run Result

**Summary:** Added `OnboardingCoordinator`, a state machine over Welcome → Microphone → System Audio → Notifications → Configure → Done, gated behind a first-run marker in Application Support. Permission steps are behind an `OnboardingPermissionStep` protocol with a placeholder auto-advancing default (Story 5.8's seam). Configure sequences four sub-steps (vault path, Obsidian check, API key, expectations) backed by `OnboardingConfigureModel`. Done writes `vault_path` via `ConfigWriter` and the completion marker.

**Files changed:**
- `Sources/Persist/VaultWriter.swift` -- made `validateVaultPath` public so the picker can validate without creating a meetings subdirectory.
- `Package.swift` -- `AppUI` now depends on `Core`/`Persist`/`Permissions`/`ClaudeSummarizer`; `AppUITests` gained `Persist`/`Permissions`.
- `Sources/AppUI/OnboardingStep.swift`, `OnboardingPermissionStep.swift`, `OnboardingMarker.swift`, `OnboardingConfigureModel.swift`, `OnboardingCoordinator.swift` (new) -- the testable coordinator/model layer.
- `App/Auricle/Onboarding/OnboardingRootView.swift`, `WelcomeStepView.swift`, `PermissionStepView.swift`, `ConfigureStepView.swift`, `DoneStepView.swift` (new) -- the SwiftUI presentation layer.
- `App/Auricle/AuricleApp.swift` -- gates `WindowGroup` content on `OnboardingMarker.exists(...)`.
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` (new) -- 23 tests covering the marker, the configure model, and the coordinator.

**Review findings breakdown:**
- Patched (6 entries — 5 medium, 1 low): Obsidian "not installed" message could never render before the view auto-advanced (now gated behind an explicit Continue tap); a Keychain API-key write failure was silently discarded (now surfaced as an error, sub-step held); `DoneStepView` showed "You're set up" even when `completeOnboarding()` threw, with no recovery (now a retry-capable error state, safe since both underlying writes are idempotent); `PermissionStepView`'s Continue button had no re-entrancy guard, letting a double-tap skip a whole permission step (now guarded); the API key field accepted whitespace-only input (now trimmed before enabling Save); `checkObsidian()`'s constructed URL was never asserted by any test (added a `Recorder<URL>`-backed test).
- Deferred (2, both medium): `obsidian://open?vault=<name>` may not resolve for a vault Obsidian has never opened before — plausible, but it's the literal format epics.md's Story 5.7 AC specifies, so this diff correctly implements what was asked; a real fix belongs in a sprint-change-proposal against that AC, not a silent deviation here. Branch `claude/story-5-7-completion-f04b9b` violates AGENTS.md's branch-naming policy — pre-existing (set before this diff), handled operationally by shipping from a compliantly-named branch.
- Rejected (11): 2 false, 9 low. False: no back/cancel navigation across onboarding's steps matches the epics AC's own design (Settings/Doctor own step re-run, not onboarding itself); a meta-observation about the self-authored spec's verification bar restated other rows without a new defect. Low, all rejected as pre-existing/non-trivial-to-fix and out of this story's scope: three rows naming the same `App/`-vs-`Sources/` test-coverage split already documented in AGENTS.md's own pitfalls and already accepted by Story 5.5's precedent (SwiftUI view-rendering has no automated path in this repo); a second `WindowGroup` window getting an independent coordinator, which predates this story (Story 1.1) and is unlikely for a single local user.

**Follow-up review recommendation:** `true` — 5 medium-severity entries were patched (≥2 triggers this on a first pass). Named risk: the four View-layer patches (Obsidian continue-gating, API-key error surfacing, `DoneStepView`'s retry state, `PermissionStepView`'s re-entrancy guard) compile and pass the existing suite, but none has new automated coverage of its exact behavior — `App/` has no test target, so only the underlying `Sources/AppUI` model layer (already well-covered) was directly verified; the UI wiring itself was verified by build success and code inspection only.

**Verification performed:**
- `swift build --explicit-target-dependency-import-check error` -- clean, before and after patches.
- `swift test --filter AppUITests` -- 22/22 pass before patches, 23/23 pass after (new URL-assertion test added).
- `mise exec -- swiftformat --lint` / `mise exec -- swiftlint lint --strict --quiet` on every changed file -- 0 violations after one formatting fix and one refactor (extracting `saveAPIKey()` to satisfy the `accessibility_label_missing` line-proximity heuristic).
- `cd App && tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- `BUILD SUCCEEDED`, before and after patches.

**Residual risks:**
- Named above: the View-layer patches have no automated regression coverage, only manual/build verification.
- The two deferred items (Obsidian URI format's real-world resolution behavior; branch naming) are tracked in frontmatter `deferred` and require follow-up outside this spec's scope.

## Design Notes

`OnboardingPermissionStep` is the seam Story 5.8 plugs into later — it never renders a view (views stay in `App/`), it only decides whether the coordinator advances:

```swift
public protocol OnboardingPermissionStep: Sendable {
    var category: TCCCategory { get }
    func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome
}
```

`OnboardingCoordinator` is injected with `PermissionChecking` (the same shared `AuricleApp.permissionChecker` instance, per AR-PAT-4) rather than constructing its own, matching how `AuricleRootView` already receives it.

The vault-picker default (`~/checkouts/SecondBrain` per AR-DATA-9) is a picker prefill only when `Config.load()`'s `vaultPath` is nil — it is never written unless the user confirms it, and the picker never creates the directory.

## Verification

**Commands:**
- `swift test --filter AppUITests` -- expected: all tests pass, including new `OnboardingCoordinatorTests`.
- `swift build` -- expected: `AppUI` and `AuricleApp` build cleanly with the new dependencies.
- `cd App && tuist generate --no-open && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- expected: succeeds with the onboarding views compiled in.

**Manual checks (if no CLI):**
- Delete `~/Library/Application Support/com.auricle.app/onboarding-completed` (if present) and launch the Debug build; confirm onboarding renders at Welcome, walk through Configure, confirm Done gates back to `AuricleRootView()` on relaunch.
