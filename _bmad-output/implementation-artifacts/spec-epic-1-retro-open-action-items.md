---
title: 'Epic 1 retro: close the twelve open action items'
type: 'chore'
created: '2026-09-19'
status: 'done'
baseline_revision: '9ca107bcf6409559c373797756174f578503fbea'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-1-retro-2026-09-18.md',
  '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md',
]
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      A meeting in `transcribing`, `summarizing` or a `*_failed` state still makes the bare `auricle` command print `Nothing in flight.`
    evidence: |-
      `BareInvocationResolver.resolve` checks only `recording`, `awaiting_attribution` and `awaiting_verification`. Real stages now run through `StageRunner`, so the fall-through is reachable. It is the open Story 1.7 ledger entry "A meeting in an active state other than the 3 `BareInvocation` checks" and the Epic 1 retro's RV-4, neither of which was an action item, so this change touched `BareInvocation` without covering it.
    location: >-
      Sources/Core/BareInvocationStatus.swift
    severity: low
---

<intent-contract>

## Intent

**Problem:** `epic-1-retro-2026-09-18.md` left twelve action items `open` in `sprint-status.yaml` (`epic-1-retro-item-11` to `-19`, `-21` to `-23`; item 20 is done). They cover unguarded state writes, missing failure taxonomy, non-fail-fast subprocess opens, an unfinished lint layer, an untested dispatcher-to-worker contract, unrecorded stage timing, stale plan text and an unrecorded ledger. Epic 4 adds stages that run through this code.

**Approach:** Land all twelve as one change, in the dependency order of the Tasks list. Code items keep logic in `Sources/` so `swift test` reaches it, and `App/` stays a thin wrapper. Plan items edit the planning documents in place. Each item's retro finding id is in parentheses in the Tasks list.

## Boundaries & Constraints

**Always:**
- Item numbers below are the retro's: 11 state guard, 12 Epic 6 lifecycle ACs, 13 read-only and fail-fast opens, 14 `print` lint rule, 15 dispatcher-to-worker test and exit status, 16 Story 1.2 as-built notes, 17 ledger entries, 18 stage record and logging, 19 small primitives, 21 `FailureCategory` and transition table, 22 per-writer telemetry patches, 23 NFR-R10 reword.
- Decisions already made by the maintainer (retro "Decisions (2026-09-19)"): NFR-R10 means checkpoint on quit plus SQLite's automatic checkpoint; build `FailureCategory` now and validate transitions in `StageRunner.run`; telemetry writers get per-writer patch types; `reconcile()` and the sweep share one "stuck" test with the `transcribing` budget scaled by audio length, and that lands in the Epic 6 ACs (item 12), not in code.
- Single-implementation primitives stay single: `StateStore` for state, `StageEventLogger` for `stage_events`, `TelemetryRecorder` for `telemetry`, `Log` for logging, `AtomicWriter` for writes. New SQL touching `stage_events` or `telemetry` stays inside those files.
- JSON dialect: snake_case for anything written to `stage_events.metadata_json`. Declare `CodingKeys` explicitly.
- Log fields carry a sensitivity tag. A field that can hold a path, transcript text or a foreign error's own text is `.sensitive`.
- Every behavior change has a test that fails on the old behavior. Tests that pinned the old behavior are rewritten to pin the new one, never deleted.
- No comment narrates the change. Comments state the constraint that makes the code correct.

**Never:**
- No wiring of `CrashRecovery`, the stale sweep, `RetentionScheduler` or a WAL checkpoint into `App/` (Epic 6 owns it). No new migration. No `schema_version` writes.
- No write of `category` into `stage_events.metadata_json`. Nothing consumes it yet.
- Do not change `Config`, `Sources/Summarize` prompts, the summarizer strategies or the Persist renderer.
- Do not rename the Story 1.2 heading or its sprint key. The key is script-derived; the As-built note carries the truth.
- Do not edit historical readiness reports under `_bmad-output/planning-artifacts/implementation-readiness-report-*.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Sweep loses to a real Txn B | Sweep read `summarizing` at `updated_at` T. A completed `summarizing` write then bumps `updated_at` before the sweep writes. | `synthesizeFailure` writes nothing. No `failed` event row. Meeting keeps the completed row. | `StateStoreError.staleWrite(id:)`. The sweep logs at info and omits the id from its result. |
| Sweep on an unchanged meeting | Same state and `updated_at` as read | Failure recorded as today | None |
| Stale write, state differs | Meeting is `published`, guard expects `summarizing` | Event insert rolled back. State unchanged. | `staleWrite` |
| Guard, missing meeting | Guard set, no row | `meetingNotFound`, not `staleWrite` | `meetingNotFound` |
| Subprocess opens current DB | File exists, all four migrations applied | Opens | None |
| Subprocess opens missing or old DB | No file, empty file, or migrations 001-003 only | Throws, creates no file | `databaseNotFound` for no file. `schemaNotMigrated` otherwise. |
| Subprocess opens newer DB | `grdb_migrations` holds an unregistered identifier | Throws | `schemaSuperseded` |
| Bare `auricle`, no DB | No state file | `StateStore.readOnly` throws `databaseNotFound` and creates no directory or file. The CLI treats that as an empty pending list: `Nothing in flight.`, exit 0. | Only `databaseNotFound` gets this treatment |
| Bare `auricle`, several awaiting | Two `awaiting_attribution` meetings | Hint names the newest by reference timestamp, ties by larger id: `auricle attribute <id>` | None |
| Invalid transition | `(stage, activeState)` has no table entry, or an outcome targets a state outside its entry | `run` throws `StageRunner.TransitionError`. No Txn A for a bad active state. No Txn B for a bad target. | Typed error |
| Duration | Completed or failed outcome under an injected clock | `duration_ms` is whole milliseconds from Txn A's clock read. The `started` event has nil. | None |
| Log a failure move | Outcome targets a `*_failed` state | One error-level record. Other transitions log at info. Only tagged fields appear. | None |
| `ß` ULID | 13 × `ß` (26 UTF-8 bytes) | `ULIDFormat.isValid` false, `MeetingID(ulid:)` nil, resolver `notFound` for 6 × `ß` | None |
| Kill before rename | Hook throws after close, before rename, target held `old` | Temp file holds the full new data. Target still reads `old`. | Hook's error propagates |
| Worker argv round trip | `makeProcess(...).arguments` for every stage, with and without vault path | The CLI's own parse type accepts it and returns the same stage, id, version and vault path | Unknown stage and version mismatch map to `WorkerExitCode` values |
| Worker exits non-zero | Stub worker exits 2, then 64 | `CrashRecovery` observes the status and warns. `reconcile()` still returns at once. | Handler runs off the caller's queue |

</intent-contract>

## Code Map

- `Sources/State/StateStore.swift` -- `recordStageTransition` (`:122-158`), `updateMeeting` (`:91`, delete), `production`/`subprocess`/`forTesting` (`:40-64`), `StateStoreError` (`:19`). Callers of `recordStageTransition`: only `Sources/Telemetry/StageEventLogger.swift:93`. Callers of `updateMeeting`: `Sources/Summarize/SummarizeStage+PostWrite.swift:66`, `Sources/Persist/PersistStage.swift:137`, `Tests/StateTests/StateStoreTests.swift:50`, `Tests/SummarizeTests/CalendarDegradationTests.swift:203-227`.
- `Sources/State/DatabasePoolFactory.swift` -- `productionDatabasePath()` creates the directory (`:13`). `baseConfiguration()` is private and sets `journalMode = .wal`, which a read-only connection cannot do. `MigrationRegistrar.migrator` is internal to `State`. GRDB gives `hasCompletedMigrations(_:)` and `hasBeenSuperseded(_:)`; `Configuration.readonly`.
- `Sources/State/Migrations/Migration001_Initial.swift:100` -- `meetings_updated_at` trigger stamps `updated_at` with millisecond wall-clock on every UPDATE, including a same-state write.
- `Sources/Orchestrator/StageRunner.swift` -- `run` (`:63`), `staleDetectionBudgetSeconds` (`:112`), `staleTransition` (`:132`), `synthesizeFailure` (`:156`), `sweepStaleActiveStates` (`:185`, catches all errors at `:227`), `buildFailedMetadataJSON` (`:247`, `.publicSafe(existing)` at `:255`). `run` callers: `Sources/Transcribe/TranscribeStage.swift:48`, `Sources/Summarize/SummarizeStage.swift:88`, `Sources/Persist/PersistStage.swift:83` (active state `summarizing`, targets `published`/`persistFailed`), `Tests/OrchestratorTests/StageRunnerTests.swift:51,76,106`. Transcribe and Summarize complete into their own active state.
- `Sources/Orchestrator/ActiveStageInFlight.swift`, `CrashRecovery.swift` (`:71` discards the `Process`), `SubprocessDispatcher.swift` (`makeProcess` `:53`, `dispatch` `:81`; the doc comment at `:77` tells callers to set `terminationHandler` after `run()`, which races).
- `Sources/Telemetry/StageEventLogger.swift` -- `StageEventRecord` (`:24`), `record` (`:87`). `TelemetryRecorder.swift` -- `record(meetingID:patch: State.Telemetry)`. `Sources/State/Telemetry.swift` -- the 23-field record. Only real caller: `Sources/Summarize/SummarizeStage+PostWrite.swift:33-42`. Tests: `Tests/TelemetryTests/TelemetryRecorderTests.swift` (`:43` mixes writers, `:88` passes a wrong id in the patch), `Tests/StateTests/StateStoreTests.swift:131-152` and `StateStoreFactoryTests.swift:114` call `upsertTelemetry` directly and keep doing so.
- `Sources/Core/PipelineState.swift` (18 cases), `PipelineStage.swift` (9), `Log.swift` (private `emit`; no sink), `AtomicWriter.swift` (write sequence `:35-82`), `ULIDFormat.swift:37`, `MeetingID.swift:11`, `MeetingIDResolver.swift:41`, `BareInvocationStatus.swift`, `InternalStageValidation.swift`, `WorkerProtocolVersion.swift`.
- `Sources/Transcribe/TranscribeWorker.swift` -- the precedent: worker ordering and exit codes live in `Sources/` behind `Exit {code, message}` because `App/` has no tests. `Sources/Summarize/SummarizeStage.swift:117` `exitCode(for:)`.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- ArgumentParser command; inline exit codes 1/2/3; `runSummarize` maps errors inline (`:150-156`). `BareInvocation.swift` -- calls `StateStore.production()`, prints hints `auricle attribute current` / `auricle keep last`. `App/Auricle/AuricleApp.swift` is a 13-line stub.
- `config/Shared.xcconfig:7` -- `SWIFT_VERSION = 5.10`, the only setting. `App/` is 17 compiled files, 678 lines. No hits for global mutable state, `DispatchQueue`, `@MainActor`.
- `Package.swift` -- `Orchestrator` target `:66`; ArgumentParser declared `:49`, imported by no `Sources/` target today.
- `.swiftlint.yml` -- six custom rules; header comment counts them. `scripts/lint-fixtures/CustomLintRuleFixtures.swift:37` marks only the `Logger(subsystem:` alternative of `log_facade_bypass`. `scripts/verify-custom-lint-rules.sh` needs a `// expect: <rule id>` marker per fixture line and one per rule. Custom-rule `excluded:` entries are path regexes.
- `print(` call sites: `BareInvocation.swift:37-43`, `JargonWedgeVerb.swift:36-41`, `StrategyComparisonVerb.swift:82-83`, `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift:115`. None in `Sources/`.
- Plan text: `epics.md` `:169`, `:264` (AR-DATA-2), `:537`, `:964` (Story 1.4), Story 6.9 `:2807-2837`, Story 1.2 `:845-905`, `:1126`; `prd.md:639`; `architecture.md:799`, `:1061`; `epic-1-context.md:12,28,38,41`. Story 1.4's "As built" note (`epics.md:957`) is the format model.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- append-only ledger; `closes:` entries close earlier ones. Spec frontmatter `deferred:` lists to transcribe: `spec-1-4-*.md` (4), `spec-1-5-*.md` (2), `spec-1-6-*.md` (3), `spec-1-7-*.md` (6).
- Architecture anchors: failure taxonomy `architecture.md:1018-1044` (Decision 4.1), write-authority matrix `:805-829` and `:1246-1262`, state machine `:377-390` (Decision 1.2), fail-fast `:809`.

## Tasks & Acceptance

**Execution:**
- `Sources/Core/ULIDFormat.swift`, `Sources/Core/MeetingIDResolver.swift` -- reject any non-ASCII byte before uppercasing; keep lowercase input valid (DR-13) -- `ß` uppercases to `SS`, so the byte count no longer bounds the character count
- `Sources/Core/AtomicWriter.swift` -- add an internal `perform(_:to:permissions:beforeRename:)` that `write` calls with `nil`; run the hook after `close()` and before `rename` (VG-3) -- lets a test abort a real write at the kill point
- `Tests/CoreTests/AtomicWriterTests.swift` -- rewrite `killedBeforeRenameLeavesTempFileAndNoPartialTarget` to run the writer with a throwing hook, with a variant whose target already holds `old` (VG-3)
- `Sources/Core/Log.swift` -- add an internal `init(category:sink:)` whose sink receives `(OSLogType, String)` and replaces the `Logger` call; `StageRunner` takes a `log:` parameter defaulting to the production `Log` (DR-7)
- `Tests/CoreTests/LogTests.swift` -- add a test that `info`, `warn` and `error` never deliver a `.sensitive` value to the sink; closes the Story 1.3 ledger entry on the same gap
- `Sources/Core/FailureCategory.swift` (new) -- `FailureCategory` with `transient`, `permanent`, `userActionable`, `benignTerminal`, raw values `transient`, `permanent`, `user_actionable`, `benign_terminal`; `PipelineState.failureCategory: FailureCategory?` per `architecture.md:1018-1044` (DR-6). `Sources/Core/PipelineTransitions.swift` (new) -- `allowedTargets(stage:activeState:) -> Set<PipelineState>?`
- `Sources/Core/WorkerExitCode.swift` (new) -- named constants 0 success, 1 caller error, 2 state error, 3 meeting not found, 64 usage, 75 retryable; `TranscribeWorker` and `TranscribeStage` use them (VG-9)
- `Sources/Core/BareInvocationStatus.swift` -- `awaitingAttribution(id:)` and `awaitingVerification(id:)`; pick the newest meeting per state by `referenceTimestamp`, ties by larger id, for recording too; add a pure `message` property that renders each status, with hints `auricle attribute <id>` and `auricle keep <id>` (DR-14)
- `Sources/State/StateStore.swift` -- `recordStageTransition` takes `expectedState: String? = nil` and `expectedUpdatedAt: String? = nil`. The UPDATE adds them to its WHERE. On zero rows, read the row in the same closure: no row throws `meetingNotFound`, otherwise `staleWrite(id:)`; either rolls back the event insert. Add `setVaultNotePath(meetingID:path:)` and `setCalendarMatch(meetingID:title:calendarEventID:)`, each `UPDATE meetings SET <cols> WHERE id = ?` that throws `meetingNotFound` on zero rows. Delete `updateMeeting` (DR-1)
- `Sources/State/StateStore.swift`, `Sources/State/DatabasePoolFactory.swift` -- `subprocess(path:)` throws `databaseNotFound` when no file exists (creating nothing), `schemaNotMigrated` unless `hasCompletedMigrations`, `schemaSuperseded` when `hasBeenSuperseded`. Add `readOnly(path:)`: `Configuration.readonly = true`, no `journalMode`, same three checks, and a non-creating production path lookup (VG-6, DR-8)
- `Sources/Telemetry/StageEventLogger.swift` -- `StageEventRecord` gains `expectedState: PipelineState?` and `expectedUpdatedAt: String?`; `record` forwards them for `started`/`completed`/`failed` and rejects them on `retried` with a `RecordError` case
- `Sources/Telemetry/TelemetryRecorder.swift` plus one file per patch type -- `TelemetryPatch` protocol; `SummarizeTelemetryPatch` (`quoteValidationDropCount`, `summarizationPath`, `summarizationModel`, `summarizationEffortBudget`, `costUSD`, `summarizationPromptSetHash`, `groundingMethod`), `TranscribeTelemetryPatch` (`transcriptionWEREstimate`), `ReviewDiarizationTelemetryPatch` (`diarizationSuggestionsCount`, `diarizationReviewCostUSD`, `diarizationReviewModel`), `AttributeTelemetryPatch` (`attributionCompletionPath`, applied and rejected counts), `NotifyTelemetryPatch` (`timeToAttributionReadySeconds`, `timeToVaultNoteSeconds`), `RetentionTelemetryPatch` (`audioRetentionStatusAtSnapshot`). Each carries no `meetingID` and yields a `State.Telemetry` with every other field nil. `record(meetingID:patch:)` accepts only `some TelemetryPatch`. The five reserved `transcription_suggestions_*` and `transcription_review_*` columns get no patch type (VG-5)
- `Sources/Orchestrator/StageRunner.swift` -- (a) `synthesizeFailure` gains `expectedUpdatedAt: String? = nil` and always sets `expectedState` to `activeState`; the sweep passes the row's `updatedAt` and catches `staleWrite` separately. (b) `run` validates `(stage, activeState)` against `PipelineTransitions` before Txn A and the outcome's target before Txn B, throwing `TransitionError`. (c) `run` measures whole milliseconds from `now()` at Txn A to the outcome and sets `durationMS` on `completed` and `failed`. (d) Log each transition at info and each move into a failed state at error through the injected `Log`; `buildFailedMetadataJSON` tags its rejected payload `.sensitive` (DR-1, DR-6, DR-7, VG-7, VG-8)
- `Sources/Persist/PersistStage.swift`, `Sources/Summarize/SummarizeStage+PostWrite.swift` -- Persist calls `setVaultNotePath` and the post-write step calls `setCalendarMatch`, so neither writes a fetched row back. The post-write telemetry call builds a `SummarizeTelemetryPatch`
- `Sources/Orchestrator/InternalStageArguments.swift` (new), `Package.swift` -- an ArgumentParser `ParsableArguments` type holding `stage`, `id`, `workerProtocolVersion`, `vaultPath`, with a constructor and an `arguments` builder. `SubprocessDispatcher.makeProcess` builds argv from it. Add ArgumentParser to `Orchestrator` and `OrchestratorTests` (VG-9)
- `Sources/Orchestrator/SubprocessDispatcher.swift`, `CrashRecovery.swift` -- `dispatch` takes `onExit: (@Sendable (WorkerExit) -> Void)?` and installs `terminationHandler` before `run()`. `WorkerExit` holds stage, meeting id and status. `CrashRecovery.init` takes `onWorkerExit` defaulting to a warn log for non-zero status. `Outcome.redispatched` means launched; say so in its doc comment (RV-2)
- `Sources/Summarize/SummarizeWorker.swift` (new), `App/auricle-cli/Verbs/InternalStageWorker.swift` -- move the summarize error-to-exit mapping (meeting not found 3, other 2, else `exitCode(for:)`) into a `SummarizeWorker.run` that returns an exit value like `TranscribeWorker`. Move stage, id and version validation into `InternalStageArguments` returning a run or exit decision. The command uses `@OptionGroup` for the arguments and `WorkerExitCode` for every code
- `App/auricle-cli/Verbs/BareInvocation.swift` -- open with `StateStore.readOnly()`; a missing database prints `Nothing in flight.` and exits 0; other failures keep the stderr line and exit 2; print `BareInvocationStatus.message`
- `config/Shared.xcconfig` -- `SWIFT_VERSION = 6.0`; fix whatever strict concurrency reports in `App/` (DR-9)
- `.swiftlint.yml`, `scripts/lint-fixtures/CustomLintRuleFixtures.swift` -- add `print_bypass` (`regex: '\bprint\('`, `match_kinds: [identifier]`, severity `error`) excluding `BareInvocation.swift`, `JargonWedgeVerb.swift`, `StrategyComparisonVerb.swift` and `SummarizeEvalHarnessTests.swift`, each with a one-line reason. Add fixture `print("probe") // expect: print_bypass` and `os_log("probe") // expect: log_facade_bypass`. Update the header rule count (VG-1, VG-2)
- Tests, one per matrix row -- `StageRunnerTests` (guard, sweep race, duration, logging, transitions, failed-state error record, one boundary pair per budgeted state and a by-value pin of `staleDetectionBudgetSeconds` with literals in the test, and a check that every `staleTransition` target is in the table), `StateStoreTests`, `StateStoreFactoryTests` (rewrite `subprocessAtFreshPathDoesNotMigrate` to expect `databaseNotFound` and no file), `StageEventLoggerTests`, `TelemetryRecorderTests` (split `:43` by writer), `PipelineStateTests`/new tests for `FailureCategory`, `SubprocessDispatcherTests` (argv through the CLI's parse type for all nine stages), `CrashRecoveryTests` (exit 2 and 64), `BareInvocationResolverTests`, `ULIDFormatTests`, `MeetingIDResolverTests`. Update `CalendarDegradationTests` to write `audio_cache_path` through a second connection (VG-4, VG-9)
- `_bmad-output/planning-artifacts/epics.md`, `prd.md`, `architecture.md`, `epic-1-context.md` -- (23) reword NFR-R10 at `prd.md:639`, `epics.md:169`, `:264`, `:537`, `:964` (with an As-built note), `architecture.md:799`, `epic-1-context.md:38` to "checkpointed on quit, plus SQLite's automatic checkpoint". (12) add Given/When/Then blocks to Story 6.9 after `:2827`: launch runs `reconcile()` and starts `RetentionScheduler`; the sweep runs every 10 s foreground and 60 s background; `reconcile()` and the sweep share one stuck test (age budget plus liveness check); the `transcribing` budget scales with audio length; the loop lives in `Sources/Orchestrator`; extend the `AppLifecycleTests` bullet. Reword `architecture.md:1061` ("configurable" becomes "scaled by audio length") and add an As-built note to Story 1.5 that the sweep driver moves to Story 6.9. (16) Add As-built notes to Story 1.2's ACs (`CanonicalTranscript` landed in Story 3.1, `Config` in the Epic 3 follow-through, covering `vault_path`, `meetings_subdir` and the Google keys), at `epics.md:1126` and `epic-1-context.md:12`, naming Story 9.1 as owner of the remaining FR58 keys and symlink normalization
- `_bmad-output/implementation-artifacts/deferred-work.md` -- (17) append the 15 spec-only entries of Stories 1.4-1.7 in the ledger's `source_spec`/`summary`/`evidence` form. Add a `closes:` entry for the four sprint-status drift ones (1.4.4, 1.5.2, 1.6.3, 1.7.6), for 1.5.1 (closed by the state guard), and for the Story 1.3 `Log` entry (closed by the sink test). Leave open: 1.4.1 (note that item 13 fails fast through `grdb_migrations`), 1.4.2, 1.4.3, 1.6.1, 1.6.2, 1.7.1, 1.7.2, 1.7.3, 1.7.4, 1.7.5
- `_bmad-output/implementation-artifacts/epic-1-retro-2026-09-18.md`, `sprint-status.yaml` -- append a "Follow-through (2026-09-19)" section with one row per item (status and what landed, honest about anything not done); set `status: done` for each finished item among `-11` to `-19` and `-21` to `-23`

**Acceptance Criteria:**
- Given the sweep read a meeting and a real completed write then landed, when the sweep writes its failure, then no `failed` row exists and the meeting keeps the completed state
- Given a database file that is missing, old or newer than the binary, when a subprocess or the bare command opens it, then a typed error is thrown and no file or directory is created
- Given a stage returns an outcome outside its table entry, when `run` handles it, then it throws `TransitionError` and writes no Txn B
- Given every real `run` caller, when its active and target states are checked, then each pair is in `PipelineTransitions`
- Given the argv `makeProcess` builds, when the CLI's parse type reads it, then it yields the values passed in
- Given `swift build` and `swift test` with the import check, and `scripts/check.sh`, when run, then all pass, including both Xcode schemes under Swift 6 language mode

## Spec Change Log

## Review Triage Log

### 2026-09-19 — Review pass
- verdicts: 42 findings — high 3, medium 2, low 33, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (Blind Hunter) `WorkerExit.status` merges exit codes and signal numbers — real, but only a log line reads it, a worker killed by SIGHUP, SIGINT or SIGQUIT is rare, and a fix adds a field to a public type. The ordering-claim half of this bullet is triaged with the Edge Case Hunter's row on `CrashRecovery`'s doc.
  - `[low]` `[patch]` (Blind Hunter) `readOnlyConfiguration()` sits inside `baseConfiguration()`'s doc block — confirmed in the diff. Fixed while rewriting that file: each opener's comment now sits on its own function.
  - `[high]` `[patch]` (Blind Hunter) The "rejected file is left as it was" claim is tested only on rollback-journal files, and not on a WAL database — confirmed with the Edge Case Hunter's finding below: a WAL database with no `-wal` and no `-shm` failed `StateStore.readOnly` with SQLite error 14. Fixed with the group below.
  - `[low]` `[reject]` (Blind Hunter) `BareInvocation` has no test, prints a raw error name and uses `WorkerExitCode.stateError` — the wrapper is three lines, the raw error print predates this change, and the fix (a new `Sources/` type) adds public surface. The catch mapping is covered below the command by the `StateStore` tests.
  - `[low]` `[defer]` (Blind Hunter) The ledger entry about states that fall through to `Nothing in flight.` is still open — pre-existing, and the retro's RV-4 was not an action item. Recorded in `deferred`.
  - `[low]` `[reject]` (Blind Hunter) `finish(_:prefixed:)` selects one of two message contracts by a `Bool`, and `vaultGlossary()` hard-codes the prefix — a style point with no behavior change and no named caller that will diverge.
  - `[low]` `[reject]` (Blind Hunter) `WorkerExitCode.stateError`'s doc says a retry would not change the failure, yet summarize returns it for a transient one — `SummarizeStage.exitCode` returned 2 for every failure before this change; only the constant's name is new.
  - `[low]` `[reject]` (Blind Hunter) Telemetry write authority is not enforced because `upsertTelemetry` is still public and the patch protocol is open — the item's stated scope was per-writer patch types for `TelemetryRecorder`; the direct-call path is the retro's own unverified VG-15.
  - `[low]` `[patch]` (Blind Hunter) `run` throws `targetNotAllowed` after side effects with no log line — confirmed: nothing recorded why. Fixed: `run` logs each rejected transition at error before throwing, through `requireAllowed` and `logRejectedTransition`; `aRejectedTransitionIsLoggedAtErrorWithTheStageAndBothStates` covers it. Grouped with the Edge Case Hunter's row.
  - `[low]` `[reject]` (Blind Hunter) Only `synthesizeFailure` is guarded, so a late `run` still overwrites the row — by design and stated in the code and the ledger; the two-workers case is owned by Story 6.9's new liveness criterion.
  - `[low]` `[reject]` (Blind Hunter) Test scaffolding is duplicated and one test name calls sysexits values Decision 1.5 values — cosmetic; no named divergence.
  - `[low]` `[reject]` (Blind Hunter) `Orchestrator` gained an ArgumentParser dependency without a written reason, and `decide()` re-parses the stage — the doc comment on `InternalStageArguments` states why the type is shared; the re-parse is a two-line unreachable fallback.
  - `[low]` `[patch]` (Blind Hunter) `architecture.md` still calls `transcription_failed` transient — confirmed at the row this change edited, and it contradicts Decision 4.1 and `PipelineState.failureCategory`. Fixed: the row now says permanent, with `auricle run <id>` as the user's resume action.
  - `[low]` `[patch]` (Blind Hunter) "Subprocesses do NOT checkpoint" sits beside "SQLite's automatic checkpoint", which fires on any committing connection — confirmed. Fixed in four places: subprocesses "issue no explicit checkpoint".
  - `[low]` `[reject]` (Blind Hunter) `print_bypass` excludes whole files and bans only `print(` — the exclusions are the spec's, each with a reason; the other stdout writers are the retro's RV-3, which was not an action item.
  - `[low]` `[reject]` (Blind Hunter) `duration_ms` uses two wall-clock reads and clamps a backwards step to zero — the injected `now` is the seam the tests use, and a clock step during one stage is rare.
  - `[high]` `[patch]` (Edge Case Hunter) A WAL database with no `-wal` and `-shm` fails the read-only open — reproduced with a probe test against a copy of the app's schema: SQLite error 14, so bare `auricle` and every worker would reject a healthy database after a clean app quit. Fixed: `makeVerifiedQueue` opens an ordinary connection that leaves the journal mode alone; `StateStore.readOnly` is renamed `reader`. Three tests build a WAL database with no sidecars and check that the opens work and that rejected files are byte-identical.
  - `[low]` `[reject]` (Edge Case Hunter) An outcome's kind and target are not cross-checked, so a `completed` outcome can target a failed state — needs a stage bug to occur, and the fix adds a second table dimension.
  - `[low]` `[patch]` (Edge Case Hunter) No log line when `run` rejects a transition — the same defect as the Blind Hunter's row; fixed once.
  - `[low]` `[reject]` (Edge Case Hunter) Signal number and exit code are not distinguished in `WorkerExit` — same as the Blind Hunter's first row.
  - `[low]` `[patch]` (Edge Case Hunter) The bare-status comparator mixes instant order and text order when a timestamp does not parse — confirmed by reading it; the order is not total. Fixed: an unparseable timestamp counts as oldest; `anUnparseableTimestampNeverBeatsAParseableOne` checks four input orders.
  - `[low]` `[reject]` (Edge Case Hunter) `print_bypass` misses `debugPrint`, `dump`, `NSLog`, `fputs` — same as the Blind Hunter's row.
  - `[low]` `[patch]` (Edge Case Hunter) The `.swiftlint.yml` and `VaultWriterTests` comments still point at an `AtomicWriterTests` exclusion and pattern that no longer exist — confirmed by grep. Both comments now state their own rationale.
  - `[low]` `[patch]` (Edge Case Hunter) `CrashRecovery`'s doc says `onWorkerExit` runs after `reconcile()` has returned — wrong: a fast worker can report while the loop still runs. Reworded.
  - `[high]` `[patch]` (Edge Case Hunter) The claim that a missing, old or newer database always gives a typed error fails for a WAL database with no sidecars, which raised a raw `DatabaseError` — same root cause as the row above; fixed and covered by the same tests.
  - `[low]` `[reject]` (Edge Case Hunter) `InternalStageWorker.finish` and `openStateStore` hold logic in `App/` — ten lines of wiring; the follow-through already records that `App/` is reached only by building it.
  - `[low]` `[patch]` (Verification Gap) The immediate-exit `onExit` test cannot fail when the handler is installed late — the reviewer's experiment delivered every exit, so the premise is not reproducible on this platform. Fixed: the test docstring no longer claims it detects that ordering, and the dispatcher's doc states the ordering as a precaution.
  - `[medium]` `[patch]` (Verification Gap) `CrashRecovery`'s default observer is tested only through a static function, so replacing the default with a no-op passes every test — confirmed. Fixed: an internal `init(...onWorkerExit:log:)` lets `reconcileWithNoObserverWarnsWhenTheReDispatchedWorkerExitsNonzero` observe the warning from a real exit-64 worker.
  - `[medium]` `[patch]` (Verification Gap) No test asserts `grounding_method` or `summarization_prompt_set_hash` on the row the stage writes, after the call site was rewritten — confirmed by grep. Fixed with `theTelemetryRowCarriesTheGroundingMethodAndTheAnsweringModesPromptSetHash`.
  - `[low]` `[reject]` (Verification Gap) The bare command's `databaseNotFound` mapping is tested only below the command — the same three-line wrapper; regression would show at once on a fresh machine, and the fix adds a `Sources/` type. Recorded in the follow-through.
  - `[low]` `[reject]` (Verification Gap) `finish` and `openStateStore` unverified — same as the Edge Case Hunter's row.
  - `[low]` `[reject]` (Verification Gap) The default-path branches of `productionDatabasePath()` and `lookUpProductionDatabasePath()` are untested — the code reads correct, and the built CLI was run against the real path; a test needs an injectable base directory, which is a design change.
  - `[low]` `[patch]` (Verification Gap, Other findings) The dispatcher doc's premise that a late handler misses an immediate exit did not reproduce — fixed with the row on the immediate-exit test above.
  - `[low]` `[reject]` (Intent Alignment) Item 12 is documentation only, so `reconcile()` and the sweep still have no shared stuck test and the `transcribing` budget is still 60 s — the retro's own action-items text says "Add to the Epic 6 lifecycle story's ACs", and the follow-through says so; the code lands with Story 6.9.
  - `[false]` `[reject]` (Intent Alignment) Nothing in the app runs the changed lifecycle code — this is the spec's `Never` list and Epic 6's scope, not a divergence from the intent.
  - `[low]` `[reject]` (Intent Alignment) The dispatcher-to-worker test runs `InternalStageArguments`, not the `App/` command itself — the command reads that type through `@OptionGroup`; the follow-through records that the command is reached by building it.
  - `[low]` `[reject]` (Intent Alignment) The bare command's no-database behavior lives in `App/` and is untested — same as the Verification Gap's row.
  - `[false]` `[reject]` (Intent Alignment) Item 14 is verified by the fixture self-check, with exclusions wider than the retro's — the fixture check is the repo's own gate for these rules, and the extra exclusions are needed because three other files print by design.
  - `[low]` `[patch]` (Intent Alignment) The follow-through says both schemes built "without any source change in `App/`", though this change edits two `App/` files for other items — the sentence meant Swift 6 needed none. Reworded.
  - `[low]` `[reject]` (Intent Alignment) The item 11 guard is opt-in, `run` is unguarded, and timestamps are millisecond strings — each stated in the code, the spec and the follow-through.
  - `[false]` `[reject]` (Intent Alignment) `FailureCategory` has no consumer and the table has five entries — both stated in the spec's `Never` list and Design Notes; not a divergence.
  - `[false]` `[reject]` (Intent Alignment) The spec file is staged but absent from the reviewed diff — the review step excludes it on purpose and passes it only as the claims file.

## Design Notes

**Guard needs `updated_at`, not only `state`.** Transcribe and Summarize complete into their own active state, so a `state`-only guard cannot tell a finished stage from a running one. The `meetings_updated_at` trigger bumps `updated_at` on any UPDATE, including a same-state one. The sweep passes the value it read, and equality of that string is the guard. `run`'s own Txn A and Txn B stay unguarded: a stage that finishes late still wins over a sweep failure, and its predecessor state is unconstrained after a re-dispatch.

**Table key is `(stage, activeState)`.** Persist runs under `summarizing`, so a table keyed by state alone would let Persist target `summarizing`. Derive entries from `architecture.md:377-390`, the three real stages' targets and the four `staleTransition` targets. A stage with no entry cannot use `run` until its story adds one; that is intended. `reviewDiarization` and `notify` entries come from `staleTransition` and Decision 1.2. `transcription_failed` is `permanent`; the `auricle run <id>` note in Decision 4.2 is the user action a permanent failure needs.

**Missing database is not an error for the bare command.** No file means no meetings, so `Nothing in flight.` is true, and it avoids telling the user to open an app stub that does not migrate yet. A schema that is not current keeps exit 2.

**One parse type, two users.** If ArgumentParser cannot be shared through `Orchestrator` under Swift 6 mode, fall back to constants and a pure-Foundation `parse` in `Core` that the CLI's options reuse, and record under Design Notes that the test then proves the contract but not ArgumentParser's acceptance.

**Termination handler order.** `Process.terminationHandler` set after `run()` misses a fast exit, so `dispatch` installs it first. The handler receives only values (`WorkerExit`), never the `Process`.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: exit 0
- `swift test --explicit-target-dependency-import-check error` -- expected: exit 0, every new test listed in the Tasks runs and passes
- `scripts/check.sh lint` -- expected: exit 0, fixture self-check reports each marked line fired, including `print_bypass`
- `scripts/check.sh app` -- expected: exit 0, both schemes build under `SWIFT_VERSION = 6.0`
- `scripts/check.sh release` -- expected: exit 0

**Manual checks (if no CLI):**
- `git grep -n "updateMeeting\|wal_checkpoint" -- Sources App` -- expected: no output
- `grep -c "status: open" _bmad-output/implementation-artifacts/sprint-status.yaml` -- expected: counts only items this change did not finish

## Auto Run Result

Status: done

**Summary.** All twelve open Epic 1 retro action items (11 to 19, 21 to 23) are closed in one change, and each is set to `done` in `sprint-status.yaml`. Code: a state-write guard (`expectedState` and `expectedUpdatedAt`) with column-scoped writers; fail-fast `subprocess` opens and a non-writing `reader` for bare `auricle`; `FailureCategory` and a `(stage, activeState)` transition table checked by `StageRunner.run`; whole-millisecond `duration_ms` and transition logging; per-writer telemetry patch types; one shared `InternalStageArguments` type for the dispatcher and the worker, with `CrashRecovery` observing worker exit status; `SummarizeWorker` and `WorkerExitCode` in `Sources/`; the `print_bypass` lint rule; an `AtomicWriter` fault-injection hook; ASCII-only ULID checks; bare-status hints that name the newest meeting; and `SWIFT_VERSION = 6.0` for the app targets. Documents: NFR-R10 reworded, Story 6.9's lifecycle criteria, Story 1.2 and 1.5 As-built notes, the 15 spec-only ledger entries, and a follow-through table in the retro.

**Files changed (71 against the rebuilt `main`).**
- `Sources/Core`: `FailureCategory`, `PipelineTransitions`, `WorkerExitCode` (new); `BareInvocationStatus`, `AtomicWriter`, `Log`, `ULIDFormat`, `MeetingIDResolver`.
- `Sources/State`: `StateStore` (guard, column writers, `subprocess`, `reader`), `DatabasePoolFactory`.
- `Sources/Orchestrator`: `StageRunner`, `StageRunner+Logging` (new), `InternalStageArguments` (new), `SubprocessDispatcher`, `CrashRecovery`.
- `Sources/Telemetry`: `TelemetryPatch` and six per-writer patch types (new), `TelemetryRecorder`, `StageEventLogger`.
- `Sources/Summarize`, `Sources/Persist`, `Sources/Transcribe`: `SummarizeWorker` (new), post-write and persist call sites, exit codes.
- `App/auricle-cli`, `config/Shared.xcconfig`, `Package.swift`, `.swiftlint.yml`, `scripts/lint-fixtures`.
- `Tests/`: 20 test files changed or added.
- `_bmad-output/`: `epics.md`, `prd.md`, `architecture.md`, `epic-1-context.md`, `deferred-work.md`, `epic-1-retro-2026-09-18.md`, `sprint-status.yaml`.

**Review.** 42 findings: high 3 (one root cause), medium 2, low 33, false 4. Patched: 16 rows (11 distinct fixes). Deferred: 1. Rejected: 25, each with its reason in the triage log above.
- The high finding was real: a WAL database with no `-wal` and `-shm`, which is how one is left after a clean app quit, failed the new read-only open with SQLite error 14. That would have made bare `auricle` and every worker reject a healthy database. Fixed by opening an ordinary connection for the schema check.
- Patched by kind: that fix with three new tests; `CrashRecovery`'s default observer made testable; the summarize telemetry columns asserted; a log line before a rejected transition; a total order for the bare-status comparator; and doc and comment corrections.

**Deviations from the spec's Tasks text.** The Tasks asked for `StateStore.readOnly(path:)` on `Configuration.readonly = true`. That cannot open a sidecar-free WAL database, and `PRAGMA query_only` does not survive GRDB's per-read reset, so the opener is `StateStore.reader(path:)` on an ordinary connection and nothing stops a caller from writing through it. The follow-through states this. The intent contract's matrix row for bare `auricle` reads `readOnly`; the behavior it describes is unchanged and is covered by `readerAtAMissingPath…`.

**Follow-up review recommended: true.** Unverified risk: the new schema check and `reader` open an ordinary connection to the production database from a process that may run while the GUI holds a `DatabasePool` on it. Behavior under a live GUI writer (busy timeout, WAL index sharing, leftover empty `-wal` and `-shm` files after a rejected open) is covered only by single-process tests. Patched entries: 1 high, 2 medium.

**Rebuilt on main.** After the review, the Epic 2 retro work merged (#57 to #65), so the change was re-applied with a 3-way merge onto `main` at `66177a8`. Two textual conflicts, both append-only files: `deferred-work.md` (both ledger additions kept, main's first) and `CrashRecoveryTests.swift` (both test groups kept). The new `persisting` state changed the chain to summarize, then persist under `persisting`, so `PipelineTransitions` now holds `(summarize, summarizing) -> persisting or summarization_failed` and `(persist, persisting) -> published or persist_failed`; `FailureCategory` maps `persisting` to none; the stale-budget pin lists all five budgets, and its boundary test gains a `persisting` case. Summarize no longer completes into its own state, so the sweep-race tests use transcribe, which still does. One new `updateMeeting` caller in the split persist tests now clears the note path through the fixture's database handle. Re-verified: `swift test` 963 passed, lint (15 fixture lines firing), release build and both Xcode schemes green.

**Verification.**
- `swift build --explicit-target-dependency-import-check error`: exit 0.
- `swift test --explicit-target-dependency-import-check error`: exit 0, 936 tests passed (848 before the change).
- `scripts/check.sh lint`: exit 0; the fixture self-check reports 15 marked lines each firing, including `print_bypass`.
- `scripts/check.sh release` and `scripts/check.sh app`: exit 0; `xcodebuild -showBuildSettings` reports `SWIFT_VERSION = 6.0` for both schemes.
- `git grep -n "updateMeeting\|wal_checkpoint" -- Sources App`: no output. `grep -c "status: open" sprint-status.yaml`: 0.
- Matrix audit: all 16 rows have a covering test that ran and passed. The App-only half of the bare-command row was checked by running the built CLI.
- The implementer's manual CLI runs wrote to this machine's real state directory: its database was checkpointed at 10:39:42. It holds all four migrations, no rows, and `integrity_check` is `ok`.

**Residual risks.**
- `App/auricle-cli` (the `finish` and `openStateStore` wrappers and the bare command's catch mapping) is reached only by building it.
- `CrashRecovery`, the sweep and `RetentionScheduler` have no production caller until Story 6.9; the liveness check is named in its criteria, not designed.
- `WorkerExit.status` does not distinguish a signal number from an exit code.
- The state guard compares a millisecond timestamp string, so two writes inside one millisecond are indistinguishable.
