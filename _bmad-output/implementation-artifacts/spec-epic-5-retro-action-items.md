---
title: 'Epic 5 retro: fix the capture bugs, close the recovery and test gaps, reconcile the docs'
type: 'bugfix'
created: '2026-09-23'
status: 'done'
baseline_revision: '7ab855398a43f7716946705c3b72956315be9a7a'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-5-retro-2026-09-23.md',
  '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md',
]
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      The capture test doubles are still duplicated: FakeSystemAudioSource (2 copies), FakeRecording and FakeCaptureRecording, RecordingNotifier (3 copies) and Recorder (3 copies).
    evidence: |-
      This duplication existed before this change. The change moved FakePermissionChecker, the five-copy fake, into TestSupport. Moving the capture doubles too would make TestSupport depend on Capture, and nearly every test target links TestSupport. A separate capture test-support target avoids that edge. Found by the intent-alignment review (Epic 5 retro A2).
    location: >-
      Tests/CaptureTests/CaptureSessionTests.swift, Tests/AppUITests/PermissionStepsTests.swift, Tests/CaptureTests/CaptureStageFixture.swift, Tests/AppUITests/DebugCaptureTriggerTests.swift
    severity: low
---

<intent-contract>

## Intent

**Problem:** The Epic 5 retro (`epic-5-retro-2026-09-23.md`) left four action items open in `sprint-status.yaml` (`epic-5-retro-item-46` to `-49`). Item 46 is three capture bugs that would spoil the live run (F1, F2, F4). Item 48 is recovery and test gaps (F3, F5, F7). Item 49 is docs that lag the build and duplicated test fakes (S2, S4, S5, A2). Item 47 is the maintainer's live recording of real meetings. It needs real meetings and TCC grants on the maintainer's Mac, so this change does not attempt it, and it stays `open`.

**Approach:** Land items 46, 48 and 49 as one change, in the order of the Tasks list. New logic goes in `Sources/` so `swift test` reaches it. `App/` only wires it. Each task names its retro finding id in parentheses.

## Boundaries & Constraints

**Always:**
- Single-implementation primitives stay single: `StateStore`, `StageEventLogger`, `TelemetryRecorder`, `Log`, `AtomicWriter`, `MeetingIDResolver`.
- `stage_events.metadata_json` is snake_case. New `CaptureMeta` fields declare explicit `CodingKeys` and encode only when present.
- Log fields carry a sensitivity tag. A field that can hold a path or a foreign error's text is `.sensitive`.
- Every behavior change has a test that fails on the old behavior. Tests that pin old behavior are rewritten, never deleted.
- Comments state the constraint that makes the code correct. No comment narrates the change.
- A captured meeting that launch recovery relabels `recovered_after_interruption` still waits for the user. Only a capture that `stop()` landed is handed to the pipeline automatically. `CaptureStage`'s type doc states this rule.

**Never:**
- Do not wire `Orchestrator.CrashRecovery`, the stale sweep or `RetentionScheduler` into `App/`. Story 6.9 owns them. Meetings stranded in `transcribing` stay Story 6.9's.
- Do not auto-run meetings that `auricle import` created. They land `captured` and the user runs them.
- Do not make a write error fail the capture. `CaptureSession` keeps partial audio on purpose.
- Do not change the F6 capture policies (mic transient cap, config-change coalescing, channel handling). The live run settles those.
- Do not add a global CLI option or change verbs' `ParsableArguments` for the config override.
- Do not edit historical readiness reports or the retro file.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Stage ends a live capture | Trigger recording meeting A. Stage fails A (mic revoked, cap, `all_sources_lost`). | Trigger `isRecording` becomes false. Next toggle starts a new capture. | None |
| Stale end event | Trigger now recording B. An end event for A arrives. | Trigger stays recording B. | None |
| Write error, then stop | First `write` threw `diskFull`. User stops. | Row `captured`. `completed` metadata holds `write_error` and the four ring counts. | None |
| Finalize fails on stop or fault | `session.stop()` throws. WAV on disk has audio past the header. | Row `capture_failed`. WAV header repaired, best effort. | Repair failure is logged, not thrown. |
| Launch, stranded capture | `captured` row whose capture `completed` event has `mic_included` and no `reason`. | Pipeline runs to `review-diarization`. | Per-meeting failure logged. Other meetings continue. |
| Launch, recovered or imported | `captured` row whose event has `reason: recovered_after_interruption`, or import metadata. | Not run. | None |
| Config unreadable after capture | `Config.load()` throws. | Meeting stays `captured`. Warning log names the error type. Next launch retries it. | No throw. |
| Config path override | `AURICLE_CONFIG=/tmp/x/config.toml` | `Config.load()`, `ConfigWriter.set` and the CLI use that file. | Empty value is ignored. |
| Unknown key | `auricle config set bogus.key x` | Exit 1. stderr names the key and lists the settable keys. File untouched. | `ConfigWriter.WriterError.unknownKey` |
| Credential key | `auricle config set api_key x` | Exit 1 with the credential refusal. | Secret check runs before the key check. |
| Already-invalid file | File does not parse before the edit. | Exit 1. Message says the existing file is unreadable. It does not blame the edit. | New `WriterError` case. |
| Onboarding done | User on Done step. Marker written. | "You're set up" plus a Continue button. Continue shows the main window with no relaunch. | Failure keeps Try Again. |
| Cmd-Shift-R before onboarding completes | Onboarding in progress. | Menu item disabled. `toggle()` does nothing. | None |

</intent-contract>

## Code Map

- `Sources/Capture/CaptureStage.swift` -- actor. `live` dict `:137`. Removal points: start `:196`, `:209`; stop failure `:286`; stop success `defer` `:298`; `fail()` `:418`. `stop()` builds `CaptureMeta` `:291-297`. `finishFailed` `:501`. `recoverInterruptedCaptures` `:431` writes `reason: recovered_after_interruption`. `repairedDuration` `:485` shows the header-repair call. Type doc `:40-58` holds the "never starts the pipeline for a recovered meeting" rule.
- `Sources/Capture/CaptureWatchdog.swift:5-43` -- `CaptureWatchdogStats`: ring drop and truncate counts and `firstWriteErrorDescription`. Doc says "for Story 5.4's capture metadata to read once it exists", which is stale. Same stale doc on `CaptureSession.watchdogStats` `:152`.
- `Sources/Capture/WAVWriter.swift:94` -- `repairHeader(at:) throws -> TimeInterval`, the only repair entry point. `AudioImporter.audioFileName` names the WAV.
- `Sources/Telemetry/StageMetadata.swift:85-130` -- `CaptureMeta`, all optional, snake_case `CodingKeys`, doc lists the fields.
- `Sources/Capture/LiveCaptureSession.swift:84-94,137-150` -- observer and private `engineConfigurationChanged()`. Tests: `Tests/CaptureTests/LiveCaptureSessionTests.swift`.
- `Sources/Capture/AudioImporter.swift:97-127` -- import lands `captured` with `ImportedCaptureMeta` (`source_format`, `audio_duration_seconds`).
- `Sources/AppUI/DebugCaptureTrigger.swift` -- `@MainActor @Observable`, `toggle()` swallows errors with `try?` and no log.
- `Sources/AppUI/OnboardingCoordinator.swift:108-111` -- `completeOnboarding()` writes config then marker. `Sources/AppUI/OnboardingMarker.swift` -- stateless file check.
- `Sources/AppUI/OnboardingConfigureModel.swift:14` -- `VaultPathValidationError` (copies Persist's cases so AppUI does not depend on Persist).
- `App/Auricle/AuricleApp.swift` -- marker read in `body` `:50`; Debug menu `:60-72`; `vaultPathValidationError` `:121-130`; `makeCaptureStage` `:151-164`; `runPipelineAfterCapture` `:171-194`; `recoverInterruptedCaptures` `:210`; `makeNotificationDelegate` `:218` returns `nil` before onboarding. Comment `:16-18` cites the removed `NSUserNotificationsUsageDescription`.
- `App/Auricle/Onboarding/DoneStepView.swift:49` -- logs the error as `.publicSafe`.
- `App/Auricle/Onboarding/ConfigureStepView.swift:133` -- copy promising a summary notification.
- `Sources/Pipeline/PipelineRunner.swift:89` -- `run(meetingID:options:)`. `Environment` init `:55-72`. Messages at `:143`, `:246` hard-code `~/.auricle/config.toml`. Pipeline depends on Core, State, Telemetry, Orchestrator, Persist, Notifications; not Capture or AppUI. Tests: `Tests/PipelineTests/PipelineFixture.swift`.
- `Sources/State/StateStore.swift:116,299` -- `fetchPending()`, `fetchStageEvents(meetingID:)`.
- `Sources/Core/Config.swift:97,109,219-265` -- `defaultFileURL`, `load`, `RawConfig` keys: `vault_path`, `meetings_subdir`, `google_calendar.client_id`, `google_calendar.client_secret`, `attribution.snippet_duration_seconds`, `diarization_review.enabled`, `diarization_review.model`, `self.wikilink`.
- `Sources/Core/ConfigWriter.swift:44,53-99` -- `set`, secret check `:71`, post-edit parse `:80-84`.
- `App/auricle-cli/Verbs/ConfigVerb.swift:36-44`, `RunVerb.swift` -- config messages.
- `Sources/TestSupport/` (`Package.swift:168`, deps `["Core"]`) -- holds only `MarkdownDisciplineChecker.swift`. `AppUITests` does not depend on it.
- Fakes to replace: `FakePermissionChecker` at `Tests/AppUITests/OnboardingCoordinatorTests.swift:26`, `PermissionStepsTests.swift:25`, `DebugCaptureTriggerTests.swift:54`, `Tests/CaptureTests/CaptureSessionTests.swift:12`, `Tests/NotificationsTests/PermissionCheckedNotificationAuthorizationTests.swift:13`; `DeniedMicrophoneChecker` at `LiveCaptureSessionTests.swift:9`.
- `Tests/CaptureTests/CaptureStageFixture.swift` -- `FakeRecording.emit(_:)` `:130`, `StageFixture`, `eventually` `:244`. `Tests/AppUITests/DebugCaptureTriggerTests.swift:18-49` -- `FakeCaptureRecording` without `emit`.
- Docs: `epics.md` Story 5.2 `:2537-2541`, Story 5.4 `:2635-2638`, Story 5.7 `:2739`; `architecture.md` `:462`, `:2346-2354`; `deferred-work.md` flat entry list (`source_spec` / `summary` / `evidence`); `spec-5-8-*.md:12,138`; `Package.swift:2` says "26 modular targets".

## Tasks & Acceptance

**Execution:**
- `Sources/Telemetry/StageMetadata.swift` -- add `writeError` (`write_error`), `systemRingDroppedChunks`, `systemRingTruncatedChunks`, `micRingDroppedChunks`, `micRingTruncatedChunks` (`*_chunks`) to `CaptureMeta` and its doc (F2).
- `Sources/Capture/CaptureStage.swift` -- (F1) add `public nonisolated let endedCaptures: AsyncStream<MeetingID>`, single consumer, yielding each time a meeting leaves `live` by any path; route every removal through one helper. (F2) put the watchdog stats on the stopped capture's `completed` event and on failed events that had a started session; after a `session.stop()` that throws, repair the WAV header best effort when the file holds audio past 44 bytes. (F3) state in the type doc that only a `stop()`-landed capture goes to the pipeline.
- `Sources/Capture/CaptureWatchdog.swift`, `Sources/Capture/CaptureSession.swift` -- replace the stale "once it exists" docs (F2).
- `Sources/Capture/LiveCaptureSession.swift` -- extract the configuration-change decision into an internal static function taking engine-running, mic-included, observing and the checker, returning `CaptureStreamFault?`; the observer calls it (F5).
- `Sources/AppUI/OnboardingProgress.swift` -- new `@MainActor @Observable` type: `isComplete`, initialized from `OnboardingMarker.exists`, plus a test init; `markComplete()` (F4).
- `Sources/AppUI/OnboardingCoordinator.swift` -- take an `OnboardingProgress`; add `enterApp()` that marks it complete, valid only after `completeOnboarding()` succeeded (F4).
- `Sources/AppUI/DebugCaptureTrigger.swift` -- take the stage's `endedCaptures` and an `OnboardingProgress`; clear state when the ended id equals `liveMeetingID`; expose `isAvailable`; `toggle()` does nothing while unavailable; log start and stop errors through `Log` (F1, F4, F8).
- `Sources/Core/VaultPathValidationError.swift` -- move the enum from AppUI to Core. `Sources/Persist/` -- add `VaultPathValidationError.init(_ error: VaultWriter.WriteError)` with the mapping from `AuricleApp.swift:121-130`. Update imports and target dependencies (F5).
- `Sources/Pipeline/CapturePipelineLauncher.swift` -- new type holding `runAfterCapture(_:)` (the body of `runPipelineAfterCapture`, run target a named constant, config loader injected, error type logged) and `resumeStrandedCaptures()` (the Launch rows of the matrix) (F3, F5).
- `App/Auricle/AuricleApp.swift` -- wire `CapturePipelineLauncher`, calling `resumeStrandedCaptures()` after `recoverInterruptedCaptures`; hold one shared `OnboardingProgress` and switch the root on it; disable the Debug item on `isAvailable`; make the notification delegate a `var`, rebuilt when the root view appears and none exists; use the Persist mapping; fix the `:16-18` comment (F1, F3, F4, F5, F8).
- `App/Auricle/Onboarding/DoneStepView.swift` -- add a Continue button calling `enterApp()`; log the error `.sensitive` (F4, F8).
- `App/Auricle/Onboarding/ConfigureStepView.swift` -- replace the copy with: "Start a recording before your meeting and stop it after. Auricle transcribes it on this Mac, then waits for you to name the speakers." (S4).
- `Sources/Core/Config.swift` -- `defaultFileURL` honors a non-empty `AURICLE_CONFIG` (tilde-expanded) from an injectable environment; add the settable-key registry (F7).
- `Sources/Core/ConfigWriter.swift` -- reject keys not in the registry after the secret check; parse the existing file before editing and report an already-invalid file with its own error (F7).
- `Sources/Pipeline/PipelineRunner.swift`, `App/auricle-cli/Verbs/RunVerb.swift` -- config messages name the resolved path, home abbreviated as `~` (F7).
- `Sources/TestSupport/FakePermissionChecker.swift` -- one configurable, lock-guarded fake (per-category check and request results, deep links, call log); `TestSupport` gains `Permissions`; `AppUITests` gains `TestSupport`; replace the six private fakes (A2).
- `Tests/` -- tests for every matrix row: `CaptureStageTests` (end stream on stop, fail, failed start; stats and write error on metadata; header repair), `DebugCaptureTriggerTests` (add `emit` to its fake; stage fault clears the trigger; stale id ignored; unavailable toggle), `LiveCaptureSessionTests` (classifier: denied mic is revocation, other status is transient, running engine or no mic is nil), `OnboardingCoordinatorTests` (`enterApp` flips progress), `CapturePipelineLauncherTests` (stranded vs recovered vs imported; config failure), Persist mapping test, `ConfigTests`/`ConfigWriterTests` (override, unknown key, credential order, already-invalid file, every registry key accepted).
- `Package.swift` -- line 2 drops the target count (S5, closes the 5.5 deferral).
- `_bmad-output/planning-artifacts/epics.md` -- Story 5.2 adds the 5 s no-callback rebuild; Story 5.4 states the per-source policy (third system-audio fault in 30 s degrades to mic-only with 5/15/30/60 s restore backoff; third mic fault fails as `transient_stream_errors`, or `all_sources_lost` when system audio is already lost); Story 5.7 takes the new copy (S2, S4).
- `_bmad-output/planning-artifacts/architecture.md` -- Decision 1.4 capture paragraph gets the no-callback trigger and mic-only degradation; the `Sources/Capture/` tree lists the actual files and drops the two that live elsewhere (S2).
- `_bmad-output/implementation-artifacts/deferred-work.md` -- add the 5.5 header item as resolved, the two 5.10 items (untested `ConfigVerb.Set.run` wiring, inline tables), and this change's deferrals (S5).
- `_bmad-output/implementation-artifacts/spec-5-8-*.md` -- append a reconciliation line under Auto Run Result pointing at the five logged 5.8 entries (S5).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- items 46, 48, 49 to `done`; 47 stays `open`.

**Acceptance Criteria:**
- Given the Debug app is recording through Cmd-Shift-R, when the stage ends the capture itself, then the toolbar indicator and menu title show idle without another key press.
- Given a completed capture event, when its `metadata_json` is read, then `mic_included`, `exact_zero_seconds`, `tap_rebuilds` and the four `*_chunks` counts are present, and `write_error` is present exactly when a write failed.
- Given a scratch config file, when `AURICLE_CONFIG=<file> auricle config set self.wikilink '[[X]]'` runs, then only that file changes.
- Given `make check`, when it runs, then it passes with no new lint suppressions.

## Spec Change Log

## Review Triage Log

### 2026-09-23 — Review pass
- verdicts: 43 findings — high 0, medium 0, low 31, false 12, maybe-false 0
- findings:
  - `low` `reject` blind: `ConfigWriter.set` refuses an edit that would repair an already-invalid file — matches the matrix row "Already-invalid file → Exit 1"; the message now sends the user to the file, which removes the dead end F7 named; a config that `Config` cannot read is rare, and allowing repairs adds a branch.
  - `low` `patch` blind: a second `toggle()` during an in-flight `start()` resets and clears `endedDuringStart` — `start()` now returns at once while a start is in flight; test added.
  - `low` `patch` blind: the `endedCaptures` listener keeps looping after the trigger is gone — `guard let self else { return }` inside the loop.
  - `false` `reject` blind: `isStoppedCapture` infers "stopped" from `mic_included` and could misfire after a future writer change — no current writer except `stop()` sets `mic_included`; `aCapturedMeetingNoStopLandedWaitsForTheUser` pins the recovered and imported cases.
  - `low` `reject` blind: the settable-key registry is not checked against the keys `RawConfig` decodes — a missing key fails loudly on the first `config set`; a structural check needs reflection over private types.
  - `low` `reject` blind: `everySettableKeyIsAcceptedAndReadBack` asserts only `!= Config()` — a key routed to the wrong field would still fail `parsesEveryKnownKey`; per-field assertions add a table for little gain.
  - `low` `reject` blind: `AURICLE_CONFIG` has no user documentation — no config documentation exists in `docs/` or the README to extend; the variable's doc comment is the reference.
  - `low` `patch` blind: doc comments say writes go to `~/.auricle/config.toml` — `ConfigWriter.swift` and `OnboardingConfigureModel.swift` now name the config file and the override.
  - `low` `patch` blind: nothing says the override covers only the config file — `Config.fileOverrideVariable` doc now says the database and caches stay in their macOS directories.
  - `false` `reject` blind: `configDisplayPath` can name a different file from the one `loadConfig` read — both resolve through the same process environment in production; only tests inject a loader.
  - `low` `patch` blind: the new "vault_path is not set in …" message text is untested — grouped with verification-gap finding 2; test added.
  - `low` `patch` blind: "Auricle transcribes it" capitalizes the product name — lowercased in `ConfigureStepView.swift` and `epics.md` Story 5.7.
  - `false` `reject` blind: `sprint-status.yaml` says `done` while the spec says `in-review` — review state is transient; the spec reaches `done` at finalize.
  - `low` `reject` blind: spec `deferred: []` while `deferred-work.md` gained entries for this spec — the fix edits this build's spec.
  - `false` `reject` blind: the Spec Change Log and Review Triage Log are empty — the review fills them.
  - `false` `reject` blind: the `closes:` entry is noise with an undefined shape — `closes:` / `resolution:` is the ledger's resolution form (precedent at the 5.x entries), and it must name a logged entry.
  - `low` `reject` blind: `WindowRootView.body` builds a coordinator on each evaluation — the old `App.body` did the same, and `OnboardingRootView`'s `@State` keeps the first; caching adds state for no observed cost.
  - `low` `reject` blind: notification-delegate install lives in `App/` and is left to the live run — grouped with verification-gap finding 3.
  - `low` `reject` blind: a second `eventually` helper in `AppUITests` — `AppUITests` cannot see the `CaptureTests` fixture; moving it to `TestSupport` is a larger change for a 10-line helper.
  - `low` `reject` blind: test helpers leak temp directories — the pre-existing `makeStage` pattern; the OS clears the temp directory.
  - `low` `reject` blind: two tests prove a negative with a short sleep — a bounded wait only weakens those tests; it cannot make them fail spuriously.
  - `low` `reject` blind: `theMappingMatchesWhatValidationActuallyThrows` covers only `.missing` — the unit mapping tests cover every case; making a directory non-writable in a test is platform-fragile.
  - `low` `patch` edge-case: re-entrant `toggle()` during `start()` — grouped with the blind finding above; same fix.
  - `low` `reject` edge-case: `set` refuses an edit that would repair the file — grouped with the first blind finding; same reason.
  - `low` `reject` edge-case: a relative `AURICLE_CONFIG` resolves against each process's working directory — a developer-only testing variable; resolving it adds a branch and a failure mode.
  - `low` `reject` edge-case: `displayPath` abbreviates everything when home is `/` — only for accounts with no home directory, which do not run auricle.
  - `low` `patch` edge-case: `rateCorrectionCount` is not persisted while the stats doc says the snapshot is copied — the doc now says every counter except rate corrections is copied.
  - `low` `reject` edge-case: a failed start whose `stop()` throws gets no header repair — a start that fails has at most milliseconds of audio; the repair adds a branch.
  - `false` `reject` edge-case: recovery's `completed` event lacks the stats fields the AC names — the AC is about a stopped capture; recovery has no session to read, and `isStoppedCapture` relies on that difference.
  - `low` `patch` verification-gap: no test delivers an end while `start()` is in flight — test added.
  - `low` `patch` verification-gap: the config display path in runner messages is untested — `PipelineRunnerTests` case with `configDisplayPath: "/tmp/x/config.toml"` added.
  - `low` `reject` verification-gap: the launch resume and the delegate install exist only in `App/` — `App/` has no test harness (AGENTS.md pitfall); the logic behind both is in tested `Sources/` types, and each call site is one line; the maintainer's live run (retro item 47) exercises both.
  - `low` `reject` intent-alignment: retro item 47 (record real meetings) is not done — it needs real meetings and TCC grants on the maintainer's Mac; `sprint-status.yaml` keeps it `open`.
  - `false` `reject` intent-alignment: a disk-full capture is still recorded `captured` and run — retro item 1 asks to save the error; the spec's Never keeps partial audio on purpose.
  - `false` `reject` intent-alignment: launch recovery never repairs a `capture_failed` row's WAV — a failed finalize now repairs the header at failure time, so no new `capture_failed` row carries an unpatched header.
  - `false` `reject` intent-alignment: a row whose `captured` write throws becomes recovered and is not run — launch recovery gives it a path, and the `CaptureStage` type doc states that recovered audio waits for the user.
  - `low` `patch` intent-alignment: the 5.2 spec was not updated for PR #121 — reconciliation paragraph appended to its Auto Run Result.
  - `low` `patch` intent-alignment: the 5.1 spec still calls the deep links unverified — reconciliation line appended to its Auto Run Result.
  - `low` `defer` intent-alignment: the capture test doubles are still duplicated — pre-existing duplication; moving them adds a `TestSupport → Capture` edge; logged in `deferred` and `deferred-work.md`.
  - `false` `reject` intent-alignment: the process lessons are not implemented — the retro lists them apart from its four numbered action items, and the tracker holds only the four.
  - `false` `reject` intent-alignment: an environment variable rather than a CLI flag — F7 names either; Design Notes record why workers need the environment.
  - `low` `reject` intent-alignment: tests stop at the `Sources/` boundary — grouped with verification-gap finding 3.
  - `false` `reject` intent-alignment: tracker `done` versus spec `in-review` — grouped with the blind finding on the same claim.

## Design Notes

Why an `AsyncStream` for F1: the stage is built before the trigger, so an init closure would reach the trigger only through a static and a main-actor hop. The trigger subscribes in its init instead.

Why an environment variable for F7: stage workers are subprocesses that load `Config` themselves. They inherit the environment, but a CLI flag would need threading through `SubprocessDispatcher`. One variable covers every verb, every worker and the GUI.

How launch tells a stopped capture from the rest: `stop()` always writes `mic_included`. Recovery writes only `reason`. Import writes its own metadata. So the rule is: the latest `capture`/`completed` event decodes as `CaptureMeta` with `micIncluded != nil` and `reason == nil`. `CaptureMeta` owns this as a documented property so Pipeline needs no dependency on Capture.

## Verification

**Commands:**
- `swift build && swift test` -- expected: all suites pass, including the new ones.
- `make check` -- expected: exit 0 (lint, fixtures, `swift test`, release build, both schemes, embedded CLI check).
- `AURICLE_CONFIG=<scratch>/config.toml <built auricle-cli> config set bogus.key x; echo $?` -- expected: `1`, no write to `~/.auricle/config.toml`.

**Manual checks (if no CLI):**
- Onboarding hand-off and the Debug menu need a GUI session. The maintainer's live run (retro item 47) covers them.

## Auto Run Result

Status: done

**Summary.** Closes Epic 5 retro action items 1, 3 and 4 (`sprint-status.yaml` items 46, 48, 49). Item 47, the maintainer's live recording of real meetings, stays `open`. It is the gate for accepting Epic 5.

- F1: `CaptureStage.endedCaptures` reports every capture end. `DebugCaptureTrigger` returns to idle when the stage ends its capture, ignores stale ends, ignores a second press during a start, and logs start and stop errors.
- F2: the capture's `completed` event, and a `failed` event from a started session, carry `write_error` and four ring drop/truncate counts. A failed finalize repairs the WAV header, best effort.
- F3/F5: `CapturePipelineLauncher` (Sources/Pipeline) runs a captured meeting to `awaiting_attribution`. At launch it resumes stopped captures that never ran. Recovered and imported meetings still wait for the user. The vault-path error mapping and the engine config-change classifier are now in tested `Sources/` code.
- F4: `OnboardingProgress` drives the window. Done has a Continue button that opens the main window without a relaunch. Cmd-Shift-R is disabled until onboarding completes.
- F7: `AURICLE_CONFIG` points `Config`, `ConfigWriter` and the CLI at another config file. `config set` rejects unknown keys (the credential check runs first), and reports an already-invalid file as such. Config messages name the file in use, with home shown as `~`.
- S2/S4/S5/A2: `epics.md` 5.2/5.4/5.7, `architecture.md` Decision 1.4 and the Capture source tree, the onboarding copy, `deferred-work.md`, reconciliation notes in the 5.1/5.2/5.8 specs, `Package.swift:2`, and one shared `FakePermissionChecker` in `TestSupport`.

**Files changed**
- `Sources/Capture/CaptureStage.swift`, `CaptureStage+Recovery.swift` (new) -- end stream, stats on events, header repair after a failed finalize, recovery split out for the line limit.
- `Sources/Capture/CaptureWatchdog.swift`, `CaptureSession.swift`, `LiveCaptureSession.swift` -- current docs; testable config-change classifier.
- `Sources/Telemetry/StageMetadata.swift` -- five new `CaptureMeta` fields; `isStoppedCapture`.
- `Sources/AppUI/DebugCaptureTrigger.swift`, `OnboardingProgress.swift` (new), `OnboardingCoordinator.swift`, `OnboardingConfigureModel.swift` -- trigger sync and gating; onboarding hand-off.
- `Sources/Core/Config.swift`, `ConfigWriter.swift`, `VaultPathValidationError.swift` (new) -- override, key registry, display path, invalid-file error; error type moved to Core.
- `Sources/Persist/VaultPathValidationError+WriteError.swift` (new) -- the Persist-to-Core error mapping.
- `Sources/Pipeline/CapturePipelineLauncher.swift` (new), `PipelineRunner.swift` -- capture hand-off and launch resume; config path in messages.
- `Sources/TestSupport/FakePermissionChecker.swift` (new), `Package.swift` -- shared fake; `TestSupport` depends on `Permissions`; `AppUITests` depends on `TestSupport`; header comment.
- `App/Auricle/AuricleApp.swift`, `Onboarding/DoneStepView.swift`, `Onboarding/ConfigureStepView.swift`, `App/auricle-cli/Verbs/RunVerb.swift` -- wiring, Continue button, copy, config path in message.
- `Tests/**` -- new `CaptureStageEndedAndStatsTests`, `CapturePipelineLauncherTests`, `VaultPathValidationErrorTests`; extended trigger, onboarding, config, config-writer, metadata, live-session and runner tests; six private fakes replaced.
- `_bmad-output/**` -- epics, architecture, deferred-work, 5.1/5.2/5.8 spec notes, sprint-status items 46/48/49 to `done`.

**Review findings.** 43 findings: 31 low, 12 false. 10 entries patched, all low: the trigger's re-entrant start, the listener loop, two missing tests, product-name casing, three doc-comment corrections, and the 5.1/5.2 spec reconciliations. One deferred: the remaining duplicated capture test doubles. The rest were rejected. Each reason is in the Review Triage Log. Notable rejects:
- `config set` still refuses an edit that would repair an already-invalid file. This matches the matrix row. The message now points the user at the file.
- The launch resume and the notification-delegate install are one-line `App/` call sites with no automated test. Retro item 47 covers them.

**Follow-up review:** `false`. This pass patched 0 high and 0 medium entries.

**Verification**
- `make check` exit 0 after the patches: lint, fixtures, 1706 tests in 37 suites, release build, both Xcode schemes, embedded `auricle-cli`, `NSAudioCaptureUsageDescription`.
- Every I/O matrix row has a covering test, and each ran and passed.
- The Debug `auricle-cli` was run with `AURICLE_CONFIG` set to a scratch file:
  - `config set bogus.key x` exited 1 and listed the settable keys.
  - `config set api_key x` exited 1 with the credential refusal.
  - `config set self.wikilink '[[X]]'` exited 0 and wrote only the scratch file.
  - The checksum of `~/.auricle/config.toml` was unchanged.

**Residual risks**
- The GUI paths have not been run: the Continue hand-off, the disabled Debug item during onboarding, and notification clicks after onboarding. Retro item 47 covers them.
- A capture stopped in the first moments after launch could be run twice. This is logged in `deferred-work.md`.
- A disk-full capture is recorded but still lands `captured` and runs. The spec's Never keeps partial audio on purpose.

