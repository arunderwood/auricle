---
title: 'Story 1.5: Orchestrator + StageRunner + CrashRecovery + RetentionScheduler Scaffold'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: 'ed6ce077c5f1b06d0240c3f5ba70ee14121d69a6'
review_loop_iteration: 0
followup_review_recommended: true
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
warnings: [oversized]
deferred:
  - summary: >-
      `StateStore.recordStageTransition`'s `meetings` UPDATE has no guard
      against the meeting's state having changed since it was last read,
      creating a race between the stale-detection sweep and a stage's own
      legitimate completion.
    evidence: |-
      Read `recordStageTransition` directly: `UPDATE meetings SET state = ?
      WHERE id = ?` has no `WHERE state = ?` guard or post-write
      `changesCount` check. Concretely: the stale sweep reads a meeting's
      state via `fetchPending()`, then separately calls `synthesizeFailure`;
      if the stage's own real Txn B (a legitimate completion) lands in that
      window, the sweep's write would silently overwrite a real success with
      a synthesized failure. `StageRunner.run`'s own Txn B has the same
      class of gap against any concurrent out-of-band state change during
      `work()`. Real and reachable in principle, but no production caller
      exists yet for `StageRunner`/`CrashRecovery` — Epic 3/4's stage
      implementations will be the first real callers. A correct fix needs
      new API surface (an expected-prior-state parameter and a "transition
      no longer applies" outcome threaded through `run` and the sweep),
      which exceeds a trivial patch. Settled by: adding optimistic-
      concurrency guarding to `recordStageTransition` before any real stage
      implementation starts calling `StageRunner.run` under true concurrent
      workloads.
    location: >-
      Sources/State/StateStore.swift; Sources/Orchestrator/StageRunner.swift
    severity: medium
  - summary: >-
      `sprint-status.yaml`'s `1-4-...` and `1-5-...` entries both still read
      `backlog` even though both stories are implemented and reviewed.
    evidence: |-
      Read `sprint-status.yaml` directly and confirmed both entries still
      read `backlog`. Same recurring, already-documented systemic gap first
      logged against Story 1.4 (and, per `deferred-work.md`'s Story 1.2
      entry, known before this session too): this workflow variant's
      rendered instructions never reference `sprint-status.yaml` at all, so
      syncing it is an orchestration-level gap, not something fixable at the
      individual-story level.
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml
    severity: low
---

<intent-contract>

## Intent

**Problem:** No mechanism exists for wrapping stage execution in the canonical two-transaction pattern (AR-PIPE-3), detecting a stage stuck longer than its wall-clock budget, or reconciling state on relaunch after a crash — so a subprocess crash or force-quit would leave the chip lying about an in-flight stage forever (FR11, FR14, FR62, NFR-R5, NFR-R6).

**Approach:** Build the `Orchestrator` target's scaffold: `StageRunner` (the two-transaction wrapper + `synthesizeFailure`), `CrashRecovery` (on-launch reconciliation), a periodic stale-detection sweep, `RetentionScheduler` (periodic polling scaffold only), and `SubprocessDispatcher` (spawns `auricle-cli __internal-stage` subprocesses). No stage's real business logic (WhisperKit, Claude, etc.) exists yet — this story builds the reusable mechanism future stages call into.

## Boundaries & Constraints

**Always:**
- `StageRunner.run(stage:meetingID:activeState:work:)` performs Txn A (`stage_events.started` + `meetings.state = activeState`) before invoking `work`, then Txn B from `work`'s returned `StageOutcome` (`.completed`/`.failed`, each carrying its own `targetState`) after — one atomic `StateStore` write per transaction, per AR-PIPE-3.
- If `work` throws, `StageRunner.run` propagates the error and performs no Txn B — this is architecturally identical to a real subprocess crash between Txn A and Txn B, and is what `CrashRecovery`/the stale sweep exist to reconcile. `StageRunner` does not catch-and-translate thrown errors into a synthesized failure itself.
- Stale-detection budgets (AR-FAIL-2 / Decision 4.2, architecture.md:1054-1060), applied only to `transcribing`, `reviewing_diarization`, `summarizing`, `published` (not `attributing` — user-paced, no budget): 60s, 90s (fixed), 720s (architecture's stated ≈12min figure), 30s respectively.
- `reviewing_diarization` stale → benign passthrough to `awaiting_attribution` with `stage_events.failed`, `error_class='ai_reviewer_timeout'` — NOT a `*_failed` state (per Decision 4.2, and the AC's own explicit carve-out).
- `published` stale → passthrough to `awaiting_verification` with `error_class='stale_active_state'` — NOT a `*_failed` state. No `*_failed` state exists for this case (`published_partial` is a distinct, unrelated trigger — confirmed by grep: it fires only for `--publish-anyway` + summarize-no-output, never for a stuck notify). This narrows the AC's general "other active states → `*_failed`" phrasing for this one state, consistent with architecture.md's explicit, unambiguous carve-out for it.
- `transcribing`/`summarizing` stale → `transcription_failed`/`summarization_failed` with `error_class='stale_active_state'`, per the AC's general rule.
- `CrashRecovery` queries `meetings WHERE state IN ('transcribing','reviewing_diarization','attributing','summarizing','published')` on launch (the AC's own literal query) and re-dispatches via `SubprocessDispatcher` for the 4 states with an automatic closure to re-run; `attributing` is detected/logged only — it is user-paced with nothing to automatically re-invoke.
- `SubprocessDispatcher` spawns `auricle-cli __internal-stage <stage> <id> --worker-protocol-version 1` via `Foundation.Process` (AR-PAT-8) with an injectable executable-path resolver, since the real `auricle-cli` binary doesn't exist until Story 1.7 — tests substitute a stub path.
- `RetentionScheduler` in this story is the periodic-poll scaffold only: query `retention_timers WHERE status = 'pending' AND fires_at <= now()` on a timer, and invoke an injectable per-row handler. No audio deletion (Epic 8).

**Never:**
- Don't implement real stage business logic (WhisperKit, Claude, cache-dir artifact writes) — every `work` closure in this story's own tests is a stand-in.
- Don't write the `diarization_suggestions.json` stub file during the `reviewing_diarization` benign passthrough — `CacheArtifactWriter` doesn't exist yet (not built in Story 1.2); `synthesizeFailure` performs only the SQLite-side transition. Deferred to whichever story implements the real `ReviewDiarization` stage.
- Don't build a fully-wired `Orchestrator` facade taking concrete strategy dependencies (summarizer, transcriber, etc., per architecture.md's composition-root sketch) — those strategy types don't exist yet; premature for this scaffold story.
- Don't create a stage→active/target-state lookup table inside `StageRunner` itself — callers (future stage implementations) supply `activeState` and each `StageOutcome` carries its own `targetState`, since only the calling stage code knows its own state machine.
- Don't wire GUI app-lifecycle hooks (foreground/backgrounded sweep-interval switching, `wal_checkpoint` on quit) — no App target exists yet. The sweep interval is a plain configurable parameter (default 10s); the foreground/backgrounded distinction is a future GUI-lifecycle story's concern.
- Don't add a typed `PipelineStage`/`PipelineState` parameter to `StateStore`'s new method — `StateStore.recordStageTransition` takes raw `String`s, consistent with Story 1.4's `Meeting.state: String` design; `Orchestrator` types convert via `.rawValue` at the call boundary.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Stage succeeds | `work` returns `.completed(targetState:, metadataJSON:)` | Txn A then Txn B both applied; `meetings.state` ends at `targetState` | N/A |
| Stage returns typed failure | `work` returns `.failed(targetState:, errorClass:, ...)` | Txn A then Txn B applied with `event='failed'`; `meetings.state` ends at the failure's `targetState` | N/A |
| Stage closure throws | `work` throws before returning | Txn A applied, Txn B never runs; error propagates to caller | Meeting left in `activeState` — surfaced later by stale sweep or crash recovery |
| Crash recovery on launch | a meeting is in one of the 5 active states | `transcribing`/`reviewing_diarization`/`summarizing`/`published` are re-dispatched via `SubprocessDispatcher`; `attributing` is detected and logged only | N/A |
| Stale sweep: `reviewing_diarization` past 90s | `updated_at` older than 90s | Passthrough to `awaiting_attribution`, `error_class='ai_reviewer_timeout'` | N/A |
| Stale sweep: `published` past 30s | `updated_at` older than 30s | Passthrough to `awaiting_verification`, `error_class='stale_active_state'` | N/A |
| Stale sweep: `transcribing`/`summarizing` past budget | `updated_at` older than budget | Transition to `transcription_failed`/`summarization_failed`, `error_class='stale_active_state'` | N/A |
| Retention scheduler tick | a `retention_timers` row is `status='pending'` and `fires_at <= now()` | The injected handler is invoked for that row | N/A |

</intent-contract>

## Code Map

- `epics.md:979-1017` -- Story 1.5's full AC
- `architecture.md:1029-1066` (Decision 4.2) -- retry policy table + wall-clock stale-detection budget table + sweep implementation description (this story's primary source for exact budgets/behavior)
- `architecture.md:1995-1996,2185-2208` -- `StageRunner.run { ... }` pattern description + the "good"/anti-pattern pseudocode (illustrative only; superseded where it conflicts with Story 1.4's already-built `StateStore` actor API -- see Design Notes)
- `epics.md:250-259` (AR-PIPE-1 through AR-PIPE-8) -- subprocess/in-process boundary, canonical state list, two-transaction pattern, cache-dir layout, `__internal-stage` contract
- `epics.md:282-291` (AR-FAIL-1 through AR-FAIL-7) -- failure categories, stale budgets, failure-visibility surfaces
- `prd.md:613,615` -- NFR-P3 (30s transcribe budget), NFR-P5 (P50 60s/P95 180s summarize budget) -- source for the 60s/720s stale figures
- `prd.md:556` -- FR46 (7-day retention grace timer default)
- `architecture.md:1082-1120` (Decision 4.3) -- `Verifier` actor pattern, for reference only (not this story's scope; illustrates the idiom used elsewhere for actor + `StateStore`)
- `Sources/State/StateStore.swift` -- existing actor from Story 1.4; extend with one new combined-write method, reuse `fetchMeeting`/`fetchPending`/`insertRetentionTimer`/etc. as-is
- `Sources/State/Meeting.swift`, `StageEvent.swift`, `RetentionTimer.swift` -- existing GRDB record types (Story 1.4), field shapes to match when constructing rows
- `Sources/Core/Log.swift` -- existing logging facade; `orchestrator` is already a listed category (AR-PAT-3)
- `Sources/Core/MeetingID.swift` -- existing ULID wrapper, reuse for meeting identity at the `Orchestrator`/`StageRunner` API boundary
- `Sources/Orchestrator/ManifestPlaceholder.swift`, `Tests/OrchestratorTests/.gitkeep` -- delete once real sources/tests land
- `Package.swift:66` -- `Orchestrator` target already declared with deps `["Core", "State", "Telemetry", "Permissions"]`; `Telemetry`/`Permissions` are still placeholders (Story 1.6/Epic 5) — do not import or call into either

## Tasks & Acceptance

**Execution:**
- `Sources/Core/PipelineState.swift` -- new: `public enum PipelineState: String, Sendable, Codable` with all 18 AR-PIPE-2 canonical states (`recording`, `captured`, `transcribing`, `reviewingDiarization = "reviewing_diarization"`, `awaitingAttribution = "awaiting_attribution"`, `attributing`, `summarizing`, `published`, `awaitingVerification = "awaiting_verification"`, `verified`, `retentionExpired = "retention_expired"`, `silent`, `discarded`, `captureFailed = "capture_failed"`, `transcriptionFailed = "transcription_failed"`, `summarizationFailed = "summarization_failed"`, `persistFailed = "persist_failed"`, `publishedPartial = "published_partial"`) -- AR-PIPE-2
- `Sources/Orchestrator/PipelineStage.swift` -- new: `public enum PipelineStage: String, Sendable, Codable` with 9 cases matching `stage_events.stage` (`capture`, `transcribe`, `reviewDiarization = "review-diarization"` per AR-AI-3's `__internal-stage review-diarization` naming, `attribute`, `summarize`, `persist`, `notify`, `verify`, `discard`) -- epics.md:722
- `Sources/State/StateStore.swift` -- add `recordStageTransition(meetingID:stage:event:occurredAt:targetState:durationMS:errorMessage:metadataJSON:) async throws`: one `writer.write { }` closure that inserts a `StageEvent` row and updates `meetings.state`, atomically -- AR-PIPE-3
- `Sources/Orchestrator/StageRunner.swift` -- new: `public actor StageRunner` wrapping a `StateStore`; `StageOutcome` enum (`.completed(targetState: PipelineState, metadataJSON: String? = nil)`, `.failed(targetState: PipelineState, errorClass: String, errorMessage: String? = nil, metadataJSON: String? = nil)`); `run(stage:meetingID:activeState:work:) async throws -> StageOutcome`; `synthesizeFailure(meetingID:stage:activeState:reason:) async throws` implementing the per-state budget table above -- AR-PIPE-3, AR-FAIL-2
- `Sources/Orchestrator/SubprocessDispatcher.swift` -- new: spawns `Foundation.Process` invoking `<executable> __internal-stage <stage> <id> --worker-protocol-version 1`; executable path resolved via an injectable closure (production default: `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")`; tests inject a stub) -- AR-PIPE-7, AR-PAT-8
- `Sources/Orchestrator/CrashRecovery.swift` -- new: on-launch reconciliation running the AC's literal query, re-dispatching the 4 automatically-re-runnable active states via `SubprocessDispatcher`, logging (not dispatching) meetings found in `attributing` -- FR62, NFR-R5, NFR-R6
- `Sources/Orchestrator/RetentionScheduler.swift` -- new: periodic-timer scaffold (configurable interval) polling `retention_timers WHERE status='pending' AND fires_at <= now()` via `StateStore`, invoking an injectable per-row handler -- FR46
- `Tests/OrchestratorTests/StageRunnerTests.swift` -- two-transaction pattern under success and failure paths (both `.failed` outcome and an unhandled throw), per AC
- `Tests/OrchestratorTests/CrashRecoveryTests.swift` -- simulates a subprocess crash between Txn A and Txn B (a meeting left in an active state with an orphan `started` stage_events row) and asserts reconciliation dispatches correctly, including the `attributing` no-dispatch case
- `Tests/OrchestratorTests/SubprocessDispatcherTests.swift` -- asserts the constructed `Process` invocation (executable path, arguments) is correct without actually running a real `auricle-cli`
- `Tests/OrchestratorTests/RetentionSchedulerTests.swift` -- asserts a due `pending` timer triggers the handler and a not-yet-due or non-`pending` one does not
- Delete `Sources/Orchestrator/ManifestPlaceholder.swift`, `Tests/OrchestratorTests/.gitkeep` once real sources/tests land

**Acceptance Criteria:**
- Given a stage closure that returns `.completed`, when `StageRunner.run` executes it, then `stage_events` gains a `started` row and a `completed` row, and `meetings.state` ends at the closure's returned `targetState`
- Given the periodic stale-detection sweep finds a meeting in each of the 4 budgeted active states past its budget, when the sweep runs, then each transitions exactly as specified in the I/O matrix above (verified per-state, not just for one representative state)
- Given `swift build && swift test --filter OrchestratorTests` (and `StateTests`, since `StateStore` gains a method), then both succeed with zero warnings and all tests pass

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 27 findings — high 1, medium 8, low 15, false 3, maybe-false 0
- findings:
  - `[high]` `[patch]` `CrashRecovery.stageToRedispatch` maps `.published: .notify` and re-dispatches it via `SubprocessDispatcher`, but AR-PIPE-1 explicitly lists `notify` among stages that run **in-process**, and this story's own AC states "in-process stages are called directly through the orchestrator's narrow API" as a contrasting clause to the subprocess path (Blind Hunter) — Verified: read `CrashRecovery.swift` directly, confirmed `.published: .notify` in the map and the unconditional `dispatcher.dispatch(stage: stage, ...)` call. Action: since no in-process notify API exists yet either, changed `.published` to the same log-only treatment as `.attributing` rather than building an actively-wrong subprocess-dispatch path; a future story that builds the in-process notify invocation can wire real re-dispatch then.
  - `[medium]` `[patch]` `CrashRecovery.reconcile()`'s `for meeting in candidates` loop has no per-iteration error handling — one `dispatcher.dispatch` throw aborts the whole batch, silently leaving every remaining stuck meeting unreconciled with no log (Blind Hunter) — Verified: read the loop directly, confirmed the unguarded `try dispatcher.dispatch(...)`. Action: wrapped the dispatch call in `do/catch`, logging the failure and continuing to the next candidate rather than propagating.
  - `[medium]` `[patch]` Same missing-isolation defect independently confirmed (Verification Gap Reviewer, pre-verified) — grouped with the row above, same fix.
  - `[medium]` `[patch]` Same missing-isolation defect independently confirmed with a proposed test case (Edge Case Hunter) — grouped with the two rows above, same fix.
  - `[medium]` `[patch]` `StageRunner.sweepStaleActiveStates()`'s `for meeting in candidates` loop has no per-iteration error handling — one `synthesizeFailure` throw aborts the whole sweep pass, leaving every remaining stale candidate untransitioned that tick (Blind Hunter) — Verified: read the loop directly, confirmed the unguarded `try await synthesizeFailure(...)`. Action: wrapped the call in `do/catch`, logging and continuing.
  - `[medium]` `[patch]` Same missing-isolation defect independently confirmed (Verification Gap Reviewer, pre-verified) — grouped with the row above, same fix.
  - `[medium]` `[patch]` Same missing-isolation defect independently confirmed with a proposed test case (Edge Case Hunter) — grouped with the two rows above, same fix.
  - `[low]` `[patch]` `CrashRecovery.stageToRedispatch` and `StageRunner.stageInFlight` independently encode the identical state→stage mapping in two files, with only a comment ("the same mapping...") asserting they agree — nothing enforces it (Blind Hunter) — Verified: read both; confirmed byte-identical mapping logic duplicated. Action: consolidated into one shared `internal` lookup in the `Orchestrator` module (both files are the same target, so no public surface is needed) referenced by both call sites.
  - `[low]` `[patch]` Same duplication independently confirmed (Verification Gap Reviewer, "Other findings," verified per standard rules) — grouped with the row above, same fix.
  - `[low]` `[reject]` The spec's own Verification section greps for the literal substrings `db\.read`/`db\.write`, but the actual codebase convention is `writer.write { db in ... }`/`writer.read { db in ... }` — the check passes today by accident, not because it verifies what it claims (Blind Hunter) — Real, but its fix is editing this build's spec's Verification section, which is categorically rejected regardless of merit per the classify rules. Independently confirmed via manual code inspection that no target actually bypasses `StateStore`.
  - `[low]` `[patch]` `meetings.updated_at` is always trigger-written with 3-digit fractional seconds in production, but `StageRunnerTests.swift`'s stale-sweep test seeds `updatedAt` via a hand-built non-fractional string that bypasses the `meetings_updated_at` trigger, so `ISO8601UTC.date(from:)`'s fractional-seconds branch — the one production always takes — is never exercised (Blind Hunter) — Verified: confirmed the trigger always produces `%f` fractional seconds, and the test's seed helper doesn't route through it. Action: added a test seeding `updatedAt` via a real fractional-second string matching the trigger's actual output format.
  - `[low]` `[patch]` No test verifies stale-detection budget behavior exactly at the boundary (`asOf.timeIntervalSince(updatedAt) >= Double(budgetSeconds)` is inclusive `>=`, but every test seed is clearly past or clearly under budget) (Blind Hunter) — Verified: read the comparison and the test seeds; confirmed no exact-boundary case. Action: added a test asserting a meeting exactly at its budget is treated as stale (matching the `>=`, not `>`, semantics).
  - `[low]` `[patch]` `RetentionScheduler.run()` (the actual periodic loop) has zero test coverage; its doc comment's cancellation-timing claim is unverified, and no test seeds more than one simultaneously-due timer in a single poll (Blind Hunter) — Verified: `RetentionSchedulerTests.swift` only calls `pollOnce()` directly; confirmed via `grep` no test references `.run(`. Action: added a `run()` test asserting cancellation stops the loop before a next poll (using a short interval + explicit cancel), and a `pollOnce` test with two simultaneously-due timers across different meetings.
  - `[low]` `[reject]` `SubprocessDispatcher.DispatchError` has only `.executableNotFound`; any other `Process.run()` failure (permission error, non-executable file) propagates as an untyped, untested error rather than a custom case (Blind Hunter) — Real but no concrete bad outcome: the raw error still propagates (nothing is silently lost), it's simply not wrapped in a nicer enum. No current caller needs the distinction (no production caller exists yet), and building out a fuller typed taxonomy with tests for each Foundation failure mode is more than a direct correction.
  - `[low]` `[patch]` `PipelineState`/`PipelineStage` don't conform to `CaseIterable`, which would enable one exhaustive test asserting every raw value matches architecture.md's canonical spelling (Blind Hunter) — No current typo exists (hand-verified), but the fix is trivial and adds real ongoing protection. Action: added `CaseIterable` to both enums plus one test per enum asserting every case's raw value against the architecture doc's canonical list.
  - `[false]` `[reject]` `RetentionScheduler` ships a periodic `run()` loop while `StageRunner`'s sweep does not, and the spec's stated reason for omitting the sweep's loop ("no App target exists yet") would apply equally to `RetentionScheduler` (Blind Hunter) — Refutation: the two aren't symmetric. The stale sweep's cadence is explicitly tied to GUI foreground/backgrounded state (architecture.md:1062, "10s foreground / 60s backgrounded") — a fixed-interval loop shipped now would need to be replaced once GUI lifecycle exists. `RetentionScheduler`'s cadence (FR46) has no such foreground/backgrounded requirement anywhere, so its fixed-interval loop is correct as-is and never needs replacing.
  - `[medium]` `[defer]` `StateStore.recordStageTransition`'s `UPDATE meetings SET state = ? WHERE id = ?` has no guard against the meeting's state having changed since it was last read — (a) `StageRunner.run`'s Txn B could overwrite a concurrent out-of-band state change made while `work()` was executing, and (b) more concretely, the stale sweep reads `meetings.updated_at` via `fetchPending()`, then separately calls `synthesizeFailure`; if the stage's own legitimate Txn B lands in that narrow window, the sweep's write would overwrite a real success with a synthesized failure (Edge Case Hunter, two related findings) — Verified: read `recordStageTransition`; confirmed no `WHERE state = ?` guard or `changesCount` check exists anywhere in the write path. Real and reachable in principle, but no caller exists yet (`StageRunner`/`CrashRecovery` have no production caller — Epic 3/4's stage implementations are the first real callers). A correct fix needs new API surface (an expected-prior-state parameter plus a "transition no longer applies" outcome threaded through both `run` and the sweep), which exceeds a trivial patch. Settled by: adding optimistic-concurrency guarding to `recordStageTransition` before any real stage implementation starts calling `StageRunner.run` for true concurrent workloads.
  - `[low]` `[patch]` `CrashRecovery.reconcile()` silently `continue`s past a meeting whose `id` fails `MeetingID` ULID validation, with no log identifying that a candidate was skipped or why (Edge Case Hunter) — Verified: confirmed the unguarded `guard let meetingID = ... else { continue }`. Action: added a `log.warn` before each `continue`.
  - `[low]` `[patch]` `StageRunner.sweepStaleActiveStates()` silently `continue`s past a meeting whose `updatedAt` fails to parse under either `ISO8601UTC` format, with no log (Edge Case Hunter) — grouped with the row above, same fix (added logging before `continue`).
  - `[low]` `[patch]` `StageRunner.sweepStaleActiveStates()` also silently `continue`s past an already-detected-stale meeting whose `id` fails ULID validation, with no log (Edge Case Hunter) — grouped with the two rows above, same fix.
  - `[low]` `[patch]` `RetentionScheduler.run()`'s `while !Task.isCancelled { try await pollOnce(); try await Task.sleep(...) }` propagates any `pollOnce()` throw straight out of `run()`, stopping the periodic loop entirely on a single transient failure (e.g. a DB busy error) rather than logging and continuing to the next tick (Edge Case Hunter) — Verified: read `run()` directly, confirmed no error handling around `pollOnce()`. Action: wrapped `pollOnce()` in `do/catch` inside the loop, logging failures and continuing to the next tick.
  - `[low]` `[patch]` `StageRunner`'s `metadataJSON(errorClass:mergingInto:)` silently discards caller-supplied `metadataJSON` if it's syntactically valid JSON but not a JSON object (e.g. an array) — the failed cast falls back to an empty object with no warning (Edge Case Hunter) — Verified: read the function, confirmed `try? ... as? [String: Any]` failing leaves `object` empty with no log. Action: added a `log.warn` when the cast fails.
  - `[low]` `[patch]` `StateStore.recordStageTransition`'s `meetings` `UPDATE` doesn't check whether any row actually matched `meetingID` — in a test/tooling context with foreign keys not enforced (e.g. `StateStore.forTesting(writer: DatabaseQueue())`, which this diff's own new tests use), a nonexistent `meetingID` would insert a `stage_events` row while the `meetings.state` update silently no-ops (Edge Case Hunter) — Verified: confirmed no `db.changesCount` check exists. In production (foreign keys enforced via `DatabasePoolFactory`) the `stage_events.meeting_id` FK constraint would already reject the whole transaction, so this is a test-environment-specific gap, not a production correctness gap. Action: added a `changesCount == 0` check that throws, catching the case cheaply regardless of FK enforcement.
  - `[false]` `[reject]` `CrashRecovery.reconcile()`'s own doc comment claims it "runs the AC's literal query," but it actually calls `StateStore.fetchPending()` (a broader, pre-existing Story 1.4 query) and narrows via an in-Swift `Set` filter, not the AC's literal `SELECT ... WHERE state IN (...)` SQL (Edge Case Hunter, filed as a claim) — Refutation: functionally equivalent — `fetchPending()`'s result is a superset of the AC's query, and the `Set`-based filter narrows it to the exact same 5-state candidate set the literal SQL would produce. No behavioral divergence; verified by reading both `fetchPending()`'s SQL and `reconcilableActiveStates`'s membership.
  - `[false]` `[reject]` Same claim independently raised, framed as a descriptive divergence between the AC's SQL-level description and the implementation's Swift-level filtering (Intent Alignment Auditor) — grouped with the row above, same refutation.
  - `[low]` `[defer]` `sprint-status.yaml`'s `1-4-...` and `1-5-...` entries both still read `backlog` even though both stories are now implemented and reviewed (Intent Alignment Auditor) — Verified: read `sprint-status.yaml` directly. Same recurring, already-documented systemic gap logged against Story 1.4 (this workflow variant never touches `sprint-status.yaml`, a separate, previously-identified orchestration-level gap per `deferred-work.md`'s Story 1.2 entry) — not new, not fixable at the story level, logged again per "never drop, merge, or silently skip."

## Design Notes

**Why the `StageRunner.run` closure doesn't take a raw `db` parameter, despite architecture.md's own pseudocode (`{ db in ... StateStore.fetchAudioPath(meetingId: id, db) }`):** that sketch predates Story 1.4's actual `StateStore` implementation, which is an `actor` exposing async instance methods (`fetchMeeting(id:) async throws -> Meeting?`, etc.) with no raw `Database` handle ever exposed outside `Sources/State/`. Passing a raw `db` into stage closures would let them bypass `StateStore`'s actor isolation entirely — the opposite of AR-PAT-4's intent. This story's closures are plain `async throws -> StageOutcome`; stage code that needs DB access calls `StateStore`'s existing async methods.

**Why `StageRunner` takes `activeState`/`targetState` as parameters rather than deriving them from `stage` internally:** no real stage implementation exists yet (Transcribe/Summarize/ReviewDiarization/etc. are all still placeholders), and several stages have genuinely different state-machine shapes (`attribute` is user-paced with no auto-failure; `capture` creates its own row rather than transitioning from a prior state). Hardcoding a stage→state table now would mean guessing at business logic five future epics will define. The generic two-transaction mechanism is this story's job; each future stage's own state machine is that stage's story's job.

## Verification

**Commands:**
- `swift build && swift test --filter OrchestratorTests` -- expected: exit 0, all tests pass, zero `Orchestrator` warnings
- `swift test --filter StateTests` -- expected: still 0 failures after `StateStore`'s new method (regression check on Story 1.4's work)
- `grep -rn "db\.read\|db\.write" Sources/ --include="*.swift" | grep -v Sources/State/` -- expected: no matches (confirms `StageRunner`/`CrashRecovery`/`RetentionScheduler` go through `StateStore`, not raw GRDB)

## Auto Run Result

**Summary:** Built the `Orchestrator` target's scaffold: `PipelineState` (Core, 18 canonical states) and `PipelineStage` (9 stages); `StateStore.recordStageTransition` (Story 1.4's `StateStore`, extended); `StageRunner` actor (`run` two-transaction wrapper, `synthesizeFailure`, `sweepStaleActiveStates`); `CrashRecovery` (on-launch reconciliation); `RetentionScheduler` (periodic-poll scaffold); `SubprocessDispatcher` (spawns `auricle-cli __internal-stage` via injectable-path `Foundation.Process`). No real stage business logic exists yet — every closure in this story's own tests is a stand-in for future stage implementations.

**Files changed:**
- `Sources/Core/PipelineState.swift` -- 18-case canonical state enum, `CaseIterable`
- `Sources/Orchestrator/{PipelineStage,ActiveStageInFlight,StageRunner,CrashRecovery,RetentionScheduler,SubprocessDispatcher,ISO8601UTC}.swift` -- the scaffold's full source
- `Sources/State/StateStore.swift` -- added `recordStageTransition` (atomic combined write) and `fetchDueRetentionTimers` (needed so `RetentionScheduler` never bypasses `StateStore`, per the spec's own db-access boundary rule)
- `Tests/OrchestratorTests/{StageRunnerTests,CrashRecoveryTests,SubprocessDispatcherTests,RetentionSchedulerTests,PipelineStageTests}.swift`, `Tests/CoreTests/PipelineStateTests.swift` -- 22 Orchestrator tests + 2 new Core tests
- Deleted `Sources/Orchestrator/ManifestPlaceholder.swift`, `Tests/OrchestratorTests/.gitkeep`

**Review findings breakdown** (27 findings across Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor — full detail in `## Review Triage Log` above):
- **Patched (18 findings: 1 high, 6 medium, 11 low):** the high finding was real and architecturally significant — `CrashRecovery` was about to re-dispatch the in-process `notify` stage as a subprocess, contradicting AR-PIPE-1 and this story's own AC; fixed by treating `published` as log-only (mirroring `attributing`) until an in-process notify API exists. The medium findings were both instances of an unguarded loop aborting an entire batch on one failure (`CrashRecovery.reconcile()`, `StageRunner.sweepStaleActiveStates()`), now isolated per-candidate with logging. The low findings were test-coverage gaps (fractional-timestamp parsing, exact budget boundary, `RetentionScheduler.run()`'s cancellation behavior, multi-timer polling, `CaseIterable` exhaustiveness), silent-skip logging gaps (malformed IDs, unparseable timestamps, discarded non-object metadata), a duplicated state→stage mapping (now consolidated into `ActiveStageInFlight`), and a missing `changesCount` guard on `recordStageTransition`.
- **Deferred (2 findings):** an optimistic-concurrency gap in `recordStageTransition` (medium — real but unreachable today since no production caller exists yet; needs new API surface, so deferred until a real stage implementation calls `StageRunner.run` under true concurrent workloads); `sprint-status.yaml` not reflecting either 1.4 or 1.5's completion (low — the same recurring, already-documented orchestration-level gap first logged against Story 1.4).
- **Rejected (7 findings, 4 low / 3 false):** a verification-command wording issue whose only fix is editing this spec (categorically rejected); an incomplete `SubprocessDispatcher` error taxonomy (real but no concrete bad outcome — errors still propagate, just untyped); the asymmetric `RetentionScheduler.run()` vs. no-`StageRunner`-sweep-loop scoping (refuted — the sweep's cadence is tied to GUI foreground/backgrounded state per architecture, `RetentionScheduler`'s isn't); and two independently-raised claims that `CrashRecovery.reconcile()` doesn't run "the AC's literal query" (refuted — functionally equivalent to `StateStore.fetchPending()` plus a `Set` filter).

**Follow-up review recommendation:** `true` -- a `high`-severity finding (the notify-as-subprocess bug) was patched this pass. Specific unverified risk to confirm next pass: that the `published`→log-only fix and the new per-candidate error isolation in `CrashRecovery.reconcile()`/`StageRunner.sweepStaleActiveStates()` behave correctly once a real composition root and real stage implementations exist to actually call this machinery — none of it has a production caller yet, so today's tests exercise the mechanism in isolation, not its eventual integration.

**Verification performed:** `swift build` (clean rebuild, 0 errors, 0 warnings) and `swift test --filter OrchestratorTests` (22/22), `--filter StateTests` (31/31, no regression), `--filter CoreTests` (28/28, no regression) all re-run independently after the patch batch. `grep -rn "db\.read\|db\.write" Sources/ --include="*.swift" | grep -v Sources/State/` -- no matches, confirmed both before and after patches. Directly read `CrashRecovery.swift` and `ActiveStageInFlight.swift` post-patch to confirm the notify fix and consolidated mapping are correct, not just test-green. I/O & Edge-Case Matrix audit: all 8 matrix rows have covering tests that ran and passed (verified pre-patch; patches added coverage, didn't remove any).

**Residual risks:** the deferred optimistic-concurrency gap (`recordStageTransition`) is a real design debt that must be resolved before any real stage implementation starts driving concurrent load through `StageRunner`/`CrashRecovery` -- flagged explicitly so it isn't forgotten once Epic 3/4 land. `sprint-status.yaml` will continue to understate Epic 1 progress until the orchestration-level sync gap is addressed.
