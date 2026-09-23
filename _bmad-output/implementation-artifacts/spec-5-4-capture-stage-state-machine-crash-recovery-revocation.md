---
title: 'Story 5.4: Capture Stage + State-Machine Integration + Crash Recovery + Mid-Capture Revocation'
type: 'feature'
created: '2026-09-22'
status: 'done'
baseline_revision: '09d921497b485bdc3cd3e0c18e19bc110bbd3bb3'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `LiveCaptureSession.restart(.microphone)` restarts the engine but cannot reinstall the input tap, which `CaptureSession` installed with the old device format.
    evidence: |-
      maybe-false. After an `AVAudioEngineConfigurationChange` (device switch) the tap may need rebuilding; the restart could then succeed while the mic delivers nothing or the wrong rate, with no mic watchdog to notice. Settled by Story 5.6's live check: switch input devices mid-capture and confirm mic audio continues. The fix needs `CaptureSession.swift`, which a separate fix PR owns.
    location: >-
      Sources/Capture/LiveCaptureSession.swift
    severity: medium (unverified)
  - summary: >-
      One device change may post several `AVAudioEngineConfigurationChange` notifications, each yielding a transient fault toward the 3-in-30s cap.
    evidence: |-
      maybe-false. If three post for one change before a restart lands, the capture fails as `transient_stream_errors`. Settled by counting notifications per device switch in Story 5.6's live run; if confirmed, coalesce faults until `restart` runs.
    location: >-
      Sources/Capture/LiveCaptureSession.swift
    severity: medium (unverified)
  - summary: >-
      A restart that fails slowly (15s or more each) lets earlier faults leave the 30s window, so `handle` and `restart` can recurse without reaching the cap.
    evidence: |-
      maybe-false. `ProcessTapSource.rebuild` and `AVAudioEngine.start` are expected to fail fast. Settled by timing a failing rebuild on hardware; if slow, cap consecutive failed restarts regardless of the window.
    location: >-
      Sources/Capture/CaptureStage.swift
    severity: medium (unverified)
  - summary: >-
      A System Audio revocation that Core Audio does report is classified `transient`, so it degrades the capture to microphone-only (or fails as `all_sources_lost` when no microphone is in the mix) with no notification, instead of failing as `permission_revoked_midstream`.
    evidence: |-
      maybe-false. The spec assumes a revoked tap only delivers exact zeros. Settled by revoking System Audio Recording mid-capture in Story 5.6 and reading the OSStatus the rebuild returns; if distinct, map it to `permissionRevoked(.systemAudio)`.
    location: >-
      Sources/Capture/CaptureFaults.swift
    severity: medium (unverified)
  - summary: >-
      Launch recovery treats any `recording` row with no live capture in this process as orphaned, so a second process recording concurrently would have its row settled mid-capture.
    evidence: |-
      maybe-false today: only the single GUI process captures. Becomes real when Story 9.5's `record` CLI verb or a second GUI instance can capture; settle there with an owner marker (PID or lease) on the row.
    location: >-
      Sources/Capture/CaptureStage.swift
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** `CaptureSession` (Story 5.2) records audio, but nothing writes a `meetings` row for it, moves it `recording → captured`, recovers a capture a crash interrupted, or reacts when the OS stops a source mid-capture. Capture state is not canonical in SQLite, and partial audio can be lost.

**Approach:** Add `Capture/CaptureStage.swift`, an actor that owns start, stop, fault handling and launch-time recovery. It writes through two new `StateStore` transactions (`beginCapture`, `finishCapture`), routed through `StageEventLogger`. Add a `capture_time_zone` column and use it for local dates in persist and summarize. Wire the stage into the GUI composition root.

## Boundaries & Constraints

**Always:**
- Capture never goes through `StageRunner.run`. `beginCapture` INSERTs the `meetings` row in `recording` (with `capture_started_at`, `audio_cache_path`, `capture_time_zone`) and the `stage_events.started` row in one GRDB write. `finishCapture` writes `capture_ended_at`, `duration_seconds`, `state` and the `completed`/`failed` event in one write, guarded on `state = 'recording'`.
- `StageEventLogger` stays the only caller of the `StateStore` methods that write `stage_events`, including the two new ones.
- No permission blocks a start. Every `start` creates a row. A failure after the row exists moves it to `capture_failed`.
- A failed row records its reason as `error_class` in `metadata_json`, the `StageRunner` convention: `permission_revoked_midstream`, `interrupted`, `transient_stream_errors`, `start_failed`.
- `CaptureMeta` (in `Telemetry/StageMetadata.swift`) becomes a typed struct with optional snake_case fields, so later capture fields are additive.
- A reported revocation stops the session, which finalizes the partial WAV. `audio_cache_path` keeps pointing at it.
- The capture zone falls back to the current zone when the column is NULL or names an unknown identifier. A re-run's `--rerun-<date>` always uses the current zone.
- New logic lives in `Sources/`. `App/` changes are wiring only.

**Never:**
- Never edit `Sources/Capture/CaptureSession.swift`, `ProcessTapSource.swift` or `AudioRingBuffer.swift`. A separate fix PR owns those files. Reach the session only through its public API and public init parameters.
- Never edit a shipped migration. The column arrives as migration 005.
- No debug record trigger or Record button (Stories 5.6 and 6.2). No `record`/`stop` CLI verbs (Story 9.5).
- No notification for a capture that failed for a reason other than a reported revocation.
- Do not auto-run the pipeline for a meeting that crash recovery moves to `captured`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Start | `start(meetingID:)`, mic denied or granted | Row in `recording`, `started` event, zone stored; returns `micIncluded` | Session start throws → row to `capture_failed` (`start_failed`), error rethrown |
| Stop | live capture | `captured`, `completed` event with `mic_included`, `exact_zero_seconds`, `tap_rebuilds`; `onCaptured` hook fires | Session stop throws → `capture_failed` (`interrupted`) |
| Stop twice / unknown live | row already `captured` or `capture_failed` | Returns the row's state; no new event | Row missing → `StateStoreError.meetingNotFound` |
| Recovery, audio present | `recording` row, not live, WAV with > 0 audio bytes | Header repaired; `captured`; `completed` event `reason: recovered_after_interruption` | — |
| Recovery, no audio | `recording` row, WAV missing, header-only, or unrepairable | `capture_failed`, `error_class: interrupted` | — |
| Reported revocation | fault `.permissionRevoked` | Session stopped, `capture_failed` (`permission_revoked_midstream`), `Notifier.fireCaptureFailed` | Notifications denied → notifier logs `warn` |
| Transient faults | 1st and 2nd within 30s | Source restarted inline; one `retried` event each | Restart throwing is handled as a new fault |
| Transient cap | 3rd within 30s | `capture_failed` (`transient_stream_errors`), session stopped | — |
| Zone | row with `capture_time_zone` / NULL / `"Not/AZone"` | Note date, filename date, `meeting-at-HHMM`, generic title in that zone / current zone / current zone | — |

</intent-contract>

## Code Map

- `Sources/State/StateStore.swift` -- add `beginCapture` and `finishCapture` beside `recordStageTransition` (:163). Same patterns: one `writer.write` closure, UPDATE-before-insert, `staleWrite`/`meetingNotFound`.
- `Sources/State/Meeting.swift` -- add `captureTimeZone` (`capture_time_zone`), last init parameter, default nil.
- `Sources/State/Migrations/` -- new `Migration005MeetingsCaptureTimeZone.swift`; register in `MigrationRegistrar.swift`.
- `Sources/Telemetry/StageEventLogger.swift` -- add two routing methods for the capture transactions. Stamps `currentMetadataSchemaVersion` like `record(event:)`.
- `Sources/Telemetry/StageMetadata.swift:80` -- `CaptureMeta` is an empty placeholder; give it optional fields. `Tests/TelemetryTests/StageMetadataRoundTripTests.swift:11,160` use `CaptureMeta()`; keep that init valid.
- `Sources/Core/PipelineTransitions.swift` -- add `(.capture, .recording) → [.captured, .captureFailed]`.
- `Sources/Core/Errors.swift:14` -- `CaptureError.permissionRevokedMidstream` already exists; reuse it.
- `Sources/Capture/CaptureSession.swift` -- READ ONLY. Public: `init(meetingID:engine:systemAudioSource:permissionChecker:cacheDirectory:…)`, `start() -> CaptureSessionStartResult`, `stop() -> URL` (idempotent), `watchdogStats`. Its consumer loop calls `systemAudioSource.rebuild()` with `try?` (:452, :486), so a thrown rebuild is invisible unless the source reports it.
- `Sources/Capture/SystemAudioSource.swift` -- the protocol a fault-reporting decorator conforms to.
- `Sources/Capture/WAVWriter.swift:98` -- `repairHeader(at:)` returns the recovered duration; throws on a non-WAV or a file under 44 bytes.
- `Sources/Capture/AudioImporter.swift:59` -- `audioFileName`, `sampleRate`; its `importAudio` shows the insert-then-log pattern and the `capture` stage row. Imported rows leave `capture_time_zone` NULL (no change there).
- `Sources/Notifications/Notifier.swift` -- `Notifier` protocol; conformers: `UserNotificationNotifier`, `StdoutNotifier`, test doubles in `Tests/NotificationsTests/NotifyStageTests.swift:10,17`, `Tests/IntegrationTests/IntegrationStubs.swift:31`, `Tests/PipelineTests/PipelineFixture.swift:55`.
- `Sources/Notifications/UserNotificationNotifier.swift` -- `center.isAuthorized()` false → `log.warn`; reuse for NFR-R8.
- `Sources/Persist/PersistStage.swift:147,250` -- capture date/time uses `clock.timeZone`; re-run date uses `clock.now()` in `clock.timeZone`. Keep `TimeSource.timeZone` as the current zone; resolve the capture zone per meeting.
- `Sources/Summarize/SummarizeStage.swift:85-100,178` -- `timeZone` flows into `UnenrichedMeetingTitle.title`; resolve from the fetched `meeting` in `run`.
- `Sources/Pipeline/PipelineRunner.swift` -- `PipelineRunner(environment:)`, `run(meetingID:options:)`; `RunOptions(to: .reviewDiarization)`. `RunPlan` starts `captured` at `transcribe`.
- `Sources/Pipeline/StageWorkerLauncher.swift:21` -- `SubprocessStageLauncher(dispatcher:)`; `SubprocessDispatcher()` defaults to the app's embedded `auricle-cli`.
- `App/Auricle/AuricleApp.swift` -- composition root; `makeNotifier()` exists but is unused; `makeNotificationDelegate()` opens its own `StateStore.production()`.
- `Package.swift:81` -- `Capture` depends on Core, State, Telemetry, Permissions; needs `Notifications`. `CaptureTests` needs `Notifications` and `GRDB` if absent.
- `Tests/CaptureTests/CaptureSessionTests.swift:11,34` -- `FakePermissionChecker`, `FakeSystemAudioSource` patterns to copy (they are `private`).
- `Tests/CaptureTests/AudioImporterTests.swift:18` -- `StateStore.forTesting(writer: DatabaseQueue())` via `@testable import State`.
- `_bmad-output/planning-artifacts/architecture.md:419` -- crash-recovery state list lacks `recording`.
- `_bmad-output/implementation-artifacts/deferred-work.md:359,370,478` -- the capture-zone and re-run-zone entries this story closes.

## Tasks & Acceptance

**Execution:**
- `Sources/State/Migrations/Migration005MeetingsCaptureTimeZone.swift`, `MigrationRegistrar.swift`, `Sources/State/Meeting.swift` -- add nullable `meetings.capture_time_zone TEXT` and the record field.
- `Sources/State/Meeting.swift` (extension) -- `public func localTimeZone(fallback: TimeZone) -> TimeZone`: the stored identifier when `TimeZone(identifier:)` resolves it, else `fallback`.
- `Sources/State/StateStore.swift` -- `beginCapture(meeting:event:)` inserts both rows in one write; the event must be `started` for `stage = capture`. `finishCapture(meetingID:endedAt:durationSeconds:targetState:event:)` updates the three columns plus state `WHERE id = ? AND state = 'recording'`, then inserts the event.
- `Sources/Telemetry/StageEventLogger.swift` -- `recordCaptureStarted(...)` and `recordCaptureFinished(...)` routing to those methods, typed with `MeetingID`/`PipelineState`/`StageEventKind`.
- `Sources/Telemetry/StageMetadata.swift` -- `CaptureMeta` fields: `micIncluded: Bool?` (`mic_included`), `exactZeroSeconds: Double?` (`exact_zero_seconds`), `tapRebuilds: Int?` (`tap_rebuilds`), `reason: String?` (`reason`), `errorClass: String?` (`error_class`), `source: String?` (`source`). All optional, all `encodeIfPresent`.
- `Sources/Core/PipelineTransitions.swift` -- add the capture entry.
- `Sources/Notifications/Notifier.swift`, `UserNotificationNotifier.swift`, `StdoutNotifier.swift` -- `CaptureFailureReason` (`permissionRevokedMidstream`); `fireCaptureFailed(meetingID:reason:)` requirement. Body: "Recording stopped — a permission was revoked. The partial audio is saved." User notifier: unauthorized → `warn`; post identifier `<id>-capture-failed`. Stdout notifier: one line. Update the four test doubles.
- `Sources/Capture/CaptureFaults.swift` (new) -- `CaptureSource` (`microphone`, `systemAudio`), `CaptureStreamFault` (`permissionRevoked(CaptureSource)`, `transient(CaptureSource, reason:)`), `FaultReportingSystemAudioSource` (decorator: forwards all calls; a throwing `start`/`rebuild` reports a transient fault, then rethrows), `TransientRestartPolicy` (pure; `record(at:) -> .restart | .fail`; fail on the 3rd event whose predecessors lie within 30s).
- `Sources/Capture/LiveCaptureSession.swift` (new) -- `CaptureRecording` protocol (`start`, `stop`, `restart(_:)`, `watchdogStats`, `faults: AsyncStream<CaptureStreamFault>`). `LiveCaptureSession` conforms: owns an `AVAudioEngine` and a `FaultReportingSystemAudioSource(ProcessTapSource())`, passes both into `CaptureSession`. It observes `AVAudioEngineConfigurationChange` on its engine. When the engine is not running after one, it classifies the fault: refresh, then `check(.microphone)`; `.denied` → `permissionRevoked(.microphone)`, else `transient(.microphone)`. `restart(.microphone)` restarts the engine; if the mic is now denied it throws `CaptureError.permissionRevokedMidstream`. `restart(.systemAudio)` calls the decorated source's `rebuild()`.
- `Sources/Capture/CaptureStage.swift` (new) -- actor. `init(stateStore:stageEventLogger:notifier:makeSession:cacheDirectory:now:timeZone:onCaptured:)`, production defaults except the store, logger and notifier. `start(meetingID: = .generate()) -> CaptureStartResult`, `stop(meetingID:) -> PipelineState`, `recoverInterruptedCaptures() -> [CaptureRecoveryOutcome]`. It keeps live captures in a dictionary with a per-capture phase, so a stop or a fault that arrives mid-teardown is ignored. One `Task` per live capture consumes `faults`. `onCaptured` runs in an unawaited `Task` after a successful `captured` write.
- `Package.swift` -- add `Notifications` to `Capture`; add test dependencies as needed.
- `App/Auricle/AuricleApp.swift` -- share one `StateStore.production()`. Build one `CaptureStage` with `makeNotifier()` and an `onCaptured` that runs `PipelineRunner` with `RunOptions(to: .reviewDiarization)` (launcher `SubprocessStageLauncher(dispatcher: SubprocessDispatcher())`, vault from `Config.load()`). Run `recoverInterruptedCaptures()` once at launch. Expose the stage for Story 5.6.
- `Sources/Persist/PersistStage.swift` -- capture date/time in `meeting.localTimeZone(fallback: clock.timeZone)`; re-run date stays in `clock.timeZone`. Update the `TimeSource` doc.
- `Sources/Summarize/SummarizeStage.swift` -- title zone = `meeting.localTimeZone(fallback: timeZone)`.
- `Tests/CaptureTests/CaptureStageTests.swift` (new) -- fake `CaptureRecording`, in-memory store; covers every I/O matrix row: start/stop transactions and events, idempotent stop, both recovery branches (real `WAVWriter` files in a temp dir), revocation saves audio + notifies + fails, restart threshold with `retried` rows, start failure.
- `Tests/CaptureTests/CaptureFaultsTests.swift` (new) -- decorator reports and rethrows; `TransientRestartPolicy` window edges (2 inside → restart, 3rd inside → fail, 3rd after 30s → restart).
- `Tests/StateTests/` -- migration adds a nullable column; existing rows NULL; `beginCapture`/`finishCapture` guard and rollback.
- `Tests/PersistTests/`, `Tests/SummarizeTests/` -- zone column used; NULL and unknown identifier fall back; re-run date uses the current zone when it differs from the capture zone.
- `Tests/TelemetryTests/`, `Tests/NotificationsTests/`, `Tests/CoreTests/` -- `CaptureMeta` round-trip with fields; `fireCaptureFailed` posts or warns; transition table entry.
- `_bmad-output/planning-artifacts/architecture.md` -- Decision 1.2 crash-recovery list names `recording` (handled by capture recovery).
- `_bmad-output/implementation-artifacts/deferred-work.md` -- close the entries at :359, :370, :478 with a pointer to this story.

**Acceptance Criteria:**
- Given the GUI calls `CaptureStage.start()`, when it returns, then one `meetings` row exists in `recording` with `capture_started_at`, `audio_cache_path` and `capture_time_zone = TimeZone.current.identifier`, plus exactly one `capture`/`started` event, written in one transaction.
- Given a live capture, when `stop(meetingID:)` runs, then the row is `captured` with `capture_ended_at` and `duration_seconds`, the `completed` event's `metadata_json` has `mic_included`, `exact_zero_seconds` and `tap_rebuilds`, and the injected `onCaptured` receives the meeting id.
- Given the app composition root, when a capture reaches `captured`, then `PipelineRunner.run` executes with `RunOptions(to: .reviewDiarization)`.
- Given `PipelineTransitions.allowedTargets(stage: .capture, activeState: .recording)`, then it returns `[.captured, .captureFailed]`.
- Given the migrated database, when Story 4.8's importer inserts a meeting, then its `capture_time_zone` is NULL.
- Given `make check`, when it runs, then it passes.
- Given a Release build of auricle open and not recording, when CPU is sampled for 60 seconds, then the average is recorded in this spec against NFR-P11 (≤ 1%).

## Spec Change Log

- 2026-09-22 — Maintainer ruling, relayed on 2026-09-22 via the Epic 5 session: when system audio is lost, keep recording the microphone. This supersedes the I/O matrix's "Transient cap" row for the system-audio source; the row still holds for the microphone. Each source now has its own `TransientRestartPolicy`. A system-audio source reaching the cap (3 faults within 30s) is marked lost instead of failing the capture: the loss time and a loss count are recorded, further system-audio faults are ignored, and a backoff task retries `restart(.systemAudio)` after 5s, 15s, 30s, then every 60s, writing one `retried` event per attempt; a successful restart records the restore time and resets the system-audio policy. The capture still fails on a microphone revocation (`permission_revoked_midstream`), on the microphone cap (`transient_stream_errors`), and with the new `error_class` `all_sources_lost` when system audio is lost while the microphone is not in the mix, or the microphone fails while system audio is lost. `CaptureMeta` gains `system_audio_lost_at`, `system_audio_restored_at` and `system_audio_loss_count`, written on the `completed` or `failed` event whenever the loss count is above zero. `architecture.md` Decisions 1.2, 4.2 and 4.4 are updated to match. The maintainer confirmed the ruling directly on 2026-09-22 and may revisit it after MVP.

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 39 findings — high 0, medium 6, low 21, false 5, maybe-false 7
- findings:
  - `[medium]` `[patch]` (blind) `restart` resumes after `stop`/`fail` tore the capture down, restarting the mic engine on a stopped session — guard phase after the retried write; `LiveCaptureSession` `stopped` flag makes `restart` a no-op.
  - `[low]` `[patch]` (blind) `LiveCaptureSession`'s `@unchecked Sendable` justification is false (`queue: nil` observer, `CaptureSession` also drives the engine) — doc rewritten.
  - `[maybe-false]` `[defer]` (blind) mic restart cannot reinstall the input tap after a format change — needs hardware and `CaptureSession.swift`; deferred to Story 5.6's live check.
  - `[medium]` `[patch]` (blind) `LiveCaptureSession` has no tests — added `LiveCaptureSessionTests`.
  - `[medium]` `[patch]` (blind) stop-while-starting untested; a throwing deferred stop makes `start` throw — deferred stop's error caught and logged; test added.
  - `[maybe-false]` `[defer]` (blind) recovery settles a `recording` row another process is still writing — single-process today; deferred to Story 9.5.
  - `[low]` `[reject]` (blind) `runPipelineAfterCapture` lives only in `App/` — it is composition, the same shape as `RunVerb.environment` in `App/auricle-cli`; the composed logic (`PipelineRunner`, `RunPlan` stopping at `review-diarization`) is tested in `Sources/`; extraction would add a public type.
  - `[low]` `[reject]` (blind) a captured meeting whose pipeline run fails or whose config is unreadable only logs — the meeting stays `captured`, visible in `auricle` status and resumable with `auricle run`; failing stages write their own events; a signal needs new surface.
  - `[low]` `[reject]` (blind) clicking the capture-failed notification opens nothing and logs "no note to open" — harmless; a distinct payload kind is new surface.
  - `[low]` `[patch]` (blind) `StateStore` doc says `recordStageTransition` is the only writer of `meetings.state` — corrected.
  - `[low]` `[reject]` (blind) `audio_cache_path` agreement relies on both factories defaulting `cacheDirectory` — they do in production; a throwing `cacheDirectory` also fails the session's writer, so the row lands `capture_failed (start_failed)` either way.
  - `[low]` `[patch]` (blind) `aFaultAfterStopIsIgnored` never reaches the phase guard (the stream is already finished) — test reworked to emit during an in-flight stop.
  - `[false]` `[reject]` (blind) NFR-P11 idle CPU not recorded — measured (mean 0.0% over 60 samples) and recorded under Auto Run Result; the fix is a spec edit in any case.
  - `[low]` `[patch]` (blind) `watchdogStats` read before `session.stop()` misses the final drain's counters — read moved after stop.
  - `[low]` `[reject]` (blind) new logs use `meeting_id` while App uses `meetingID` — the repo already mixes both (`AudioImporter` `meeting_id`, `CrashRecovery` `meetingID`); no convention to converge on.
  - `[low]` `[patch]` (edge) recovery during `start`'s `recordCaptureStarted` await fails a live capture — `live` entry reserved before the write.
  - `[medium]` `[patch]` (edge) restart after teardown — same root cause as the first blind finding; same fix.
  - `[maybe-false]` `[defer]` (edge) several configuration-change notifications per device switch hit the cap — needs hardware; deferred.
  - `[low]` `[reject]` (edge) `recordCaptureFinished` throwing after a successful `session.stop()` leaves the row `recording` — a DB write failure is rare, and next launch's recovery repairs the finalized WAV to `captured`.
  - `[low]` `[reject]` (edge) a failed `finishFailed` write lets recovery later mark a failed capture `captured` — rare DB failure; audio is kept either way.
  - `[medium]` `[patch]` (edge) deferred stop throwing inside `start` — grouped with the stop-while-starting fix.
  - `[maybe-false]` `[defer]` (edge) slow failing restarts recurse without reaching the cap — deferred; settle by timing a failing rebuild.
  - `[low]` `[patch]` (edge) backward wall-clock jump keeps future-dated faults in the window — policy keeps only entries in `[0, window)`; test added.
  - `[false]` `[reject]` (edge) `finishCapture` accepts any `targetState` — by contract `StateStore` owns no state-machine knowledge (`recordStageTransition` has the same shape); the only caller passes `captured`/`capture_failed`.
  - `[low]` `[reject]` (edge) capture-failed click logs a misleading warning — grouped with the blind click finding.
  - `[low]` `[reject]` (edge) a WAV under 0.5s recovers with `duration_seconds` 0 — rare; recovery never runs the pipeline, and transcribe reports an empty file itself.
  - `[low]` `[reject]` (edge) `restart(.systemAudio)` uses the undecorated source, unlike the spec's wording — behavior is equivalent (the throw is handled as the next fault) and avoids double counting; the fix would be a spec edit.
  - `[low]` `[reject]` (edge) a stop during `fail()`'s teardown returns `recording` — momentary; the next read shows the final state; fixing needs new phase semantics.
  - `[medium]` `[patch]` (gap) stop arriving while starting is never tested — grouped with the stop-while-starting fix.
  - `[medium]` `[patch]` (gap) nothing tests `LiveCaptureSession` — grouped with the blind test finding.
  - `[low]` `[reject]` (gap) GUI pipeline hand-off and launch recovery live only in `App/` — grouped with the blind App finding; same reason.
  - `[low]` `[patch]` (gap) recovered row's `capture_ended_at` never asserted — assertion added.
  - `[low]` `[patch]` (gap, other) stale `StateStore` doc — grouped with the blind doc finding.
  - `[medium]` `[patch]` (intent) `LiveCaptureSession` fault detection untested — grouped with the test fix.
  - `[maybe-false]` `[defer]` (intent) a Core Audio-reported System Audio revocation is classified transient — deferred to Story 5.6's live revocation check.
  - `[low]` `[reject]` (intent) App hand-off untested — grouped with the blind App finding.
  - `[false]` `[reject]` (intent) idle CPU unrecorded — measured and recorded under Auto Run Result.
  - `[false]` `[reject]` (intent) no evidence `make check` ran — it ran, exit 0, 1570 tests.
  - `[false]` `[reject]` (intent) no commit/PR and a `claude/` branch — the ship step creates a `feat/` branch, commit and PR after this review.

## Design Notes

**Why wrappers instead of editing `CaptureSession`.** A separate fix PR owns `CaptureSession.swift`. `CaptureSession` already takes its engine and its system-audio source as init parameters. So `LiveCaptureSession` creates both, keeps references, and observes and restarts them from outside. The decorator makes a thrown rebuild visible. The session's own `try?` would otherwise hide it.

**What counts as a reported revocation.** The only permission a status read can confirm is the microphone. System Audio status is always `.unknown`, and a revoked tap delivers exact zeros with no error. So a fault becomes `permissionRevoked` only when the failing source is the microphone and a refreshed check says `.denied`. Every Core Audio error is `transient`. It restarts, and it fails the capture on the third within 30s.

**Restart policy.** Keep timestamps of transient faults; drop those older than 30s before counting.

```swift
mutating func record(at now: Date) -> Decision {
    recent = recent.filter { now.timeIntervalSince($0) < 30 } + [now]
    return recent.count >= 3 ? .fail : .restart
}
```

**Zones.** `TimeSource.timeZone` keeps meaning "the current zone". The capture zone comes from the row, so the re-run date needs no second field.

## Verification

**Commands:**
- `swift build && swift test` -- expected: all tests pass, including new `CaptureStageTests`, `CaptureFaultsTests`, migration and zone tests.
- `make check` -- expected: exit 0 (lint, format, custom-rule fixtures, both Xcode schemes).
- `grep -n "CaptureSession.swift\|ProcessTapSource.swift\|AudioRingBuffer.swift" <(git diff --name-only main)` -- expected: no output.

**Manual checks (if no CLI):**
- Idle CPU: build `AuricleApp` Release, launch it, then `top -l 61 -s 1 -stats pid,cpu -pid <pid>`; record the mean in `## Auto Run Result`.

## Auto Run Result

**Summary:** `CaptureStage` now owns capture start, stop, fault handling and launch recovery. It writes through two new single-transaction `StateStore` methods routed via `StageEventLogger`. A new nullable `meetings.capture_time_zone` column dates notes, filenames and generic titles in the capture zone; re-run suffixes stay in the current zone. The GUI builds one stage, runs recovery at launch, and runs the pipeline to `review-diarization` after a successful stop. `CaptureSession.swift`, `ProcessTapSource.swift` and `AudioRingBuffer.swift` are untouched.

**Files changed:**
- `Sources/Capture/CaptureStage.swift` — the capture stage actor.
- `Sources/Capture/LiveCaptureSession.swift` — `CaptureRecording` seam and its production adapter over `CaptureSession`.
- `Sources/Capture/CaptureFaults.swift` — fault types, fault-reporting source decorator, 3-in-30s restart policy.
- `Sources/State/StateStore.swift`, `Meeting.swift`, `Migrations/Migration005MeetingsCaptureTimeZone.swift`, `MigrationRegistrar.swift` — capture transactions, zone column, `localTimeZone(fallback:)`.
- `Sources/Telemetry/StageEventLogger.swift`, `StageMetadata.swift` — capture routing methods; typed `CaptureMeta`.
- `Sources/Core/PipelineTransitions.swift` — `(.capture, .recording)` entry.
- `Sources/Notifications/Notifier.swift`, `UserNotificationNotifier.swift`, `StdoutNotifier.swift` — `fireCaptureFailed(meetingID:reason:)`.
- `Sources/Persist/PersistStage.swift`, `Sources/Summarize/SummarizeStage.swift` — capture-zone dates and titles.
- `App/Auricle/AuricleApp.swift` — shared store, capture stage, launch recovery, post-capture pipeline run.
- `Package.swift` — `Capture` depends on `Notifications`.
- Tests: new `CaptureStageTests`, `CaptureFaultsTests`, `LiveCaptureSessionTests`, `CaptureTransactionTests`, `MigrationFiveTests`, zone tests in Persist and Summarize; updates to notifier, telemetry, transition and fixture tests.
- `architecture.md` (Decision 1.2 recovery list), `deferred-work.md` (closes the capture-zone entries).

**Review findings:** 39 findings. 10 root-cause patches applied (3 medium entries, 7 low); 5 deferred as maybe-false (mic tap reinstall, config-change bursts, slow-restart recursion, Core Audio-reported System Audio revocation, multi-process recovery); the rest rejected with reasons in the triage log.

**Follow-up review recommended:** true. Patched: medium 3, low 7. Unverified risk: the restart-after-stop reentrancy fix (phase guard in `CaptureStage.restart` plus the `stopped` flag in `LiveCaptureSession`) is proven only against fakes; a real `AVAudioEngine` restart racing a stop is untested.

**Verification:**
- `make check` — exit 0 before review (1570 tests) and re-run after the patches: exit 0, 1576 tests.
- Protected-file grep on `git diff --name-only` — no match.
- Idle CPU, NFR-P11: Release `AuricleApp` (ad-hoc signed for measurement), launched with `CFFIXED_USER_HOME` pointing at a scratch home so the real database was not touched, sampled with `top -l 61 -s 1`. Mean 0.0%, max 0.0% over 60 samples. Passes ≤ 1%. The scratch home was empty: no config, no vault and no existing database, so the app sat on onboarding for the whole run; the idle main window with a configured vault was not measured.

**Residual risks:** no hardware test of fault detection or mic restart (Story 5.6 is the live check); the App-side post-capture pipeline hand-off has no automated test; the five deferred items above.
