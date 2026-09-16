---
title: 'Story 1.6: Telemetry Recorder, StageEventLogger, and StageMetadata'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: 'c8006e9b3c32b29e1a3c22a6317af96d25e2e76c'
review_loop_iteration: 0
followup_review_recommended: false
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
warnings: [oversized]
deferred:
  - summary: >-
      `StageMetadata`'s Codable conformance wraps each case's payload under a
      case-name key, diverging from architecture.md's documented flat
      `metadata_json` shape.
    evidence: |-
      Read `StageMetadata.swift`'s `encode(to:)`: it writes
      `{"transcribe": {...}}` rather than the flat `{"model_id": ...}` shape
      architecture.md's Decision 4.5 illustrates. The wrapper exists to solve
      a real constraint: `capture`/`attribute`'s placeholder payloads are both
      content-identical empty objects, undecodable without a discriminator
      key. epics.md's own AC only requires snake_case dialect, not a specific
      flat/wrapped shape, and no production caller exists yet to break.
      Settled by: whichever story builds the first real stage consumer of
      this JSON decides definitively whether generic self-describing decode
      (needs the wrapper) or stage-column-driven decode (doesn't) is the
      actual usage pattern.
    location: >-
      Sources/Telemetry/StageMetadata.swift
    severity: low
  - summary: >-
      architecture.md's own `StageMetadata` Codable sketch lists only 6
      cases, omitting `reviewDiarization`, even though the same Decision 4.5
      section otherwise documents `reviewing_diarization` payloads.
    evidence: |-
      Confirmed via direct read of architecture.md's sketch (~line 1216).
      Pre-existing architecture-document inconsistency, not caused by this
      diff (which correctly follows epics.md's 7-case AC) and not fixable
      from this story — architecture.md is a planning artifact outside this
      story's scope to edit.
    location: >-
      architecture.md (Decision 4.5, StageMetadata sketch)
    severity: low
  - summary: >-
      `sprint-status.yaml`'s Epic 1 entries (1-4, 1-5, 1-6) all still read
      `backlog` even though all three stories are implemented and reviewed.
    evidence: |-
      Read `sprint-status.yaml` directly and confirmed all three entries
      still read `backlog`. Same recurring, already-documented systemic gap
      first logged against Story 1.4 and again against Story 1.5: this
      workflow variant's rendered instructions never reference
      `sprint-status.yaml`, so syncing it is an orchestration-level gap, not
      something fixable at the individual-story level.
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml
    severity: low
---

<intent-contract>

## Intent

**Problem:** `StageRunner` (Story 1.5) writes `stage_events` directly via `StateStore`, and nothing exists to write the `telemetry` table's rollup columns — so structured per-stage metadata has no typed shape, and `auricle stats` (Epic 9) has no populated counters to read from day one.

**Approach:** Build the `Telemetry` target: a `StageMetadata` `Codable` enum (7 per-stage payload cases per Decision 4.5), `StageEventLogger.record(event:)` as the sole `stage_events` writer (refactoring `StageRunner` to call it instead of `StateStore` directly), and `TelemetryRecorder.record(meetingID:patch:)` as a partial UPSERT into `telemetry`. Extends Story 1.4's schema with migration #2 (`stage_events.metadata_schema_version`, required by this story's AC but absent from migration #1 — architecture.md's Decision 4.5 assumes a column Decision 2.1's own SQL never included).

## Boundaries & Constraints

**Always:**
- `StageEventLogger` is the only caller of `StateStore.recordStageTransition`/`insertStageEvent` for `stage_events` rows going forward; `StageRunner.run`/`synthesizeFailure` are refactored to call `StageEventLogger.record(event:)` instead of `StateStore` directly (the AC's explicit requirement). This is call-site discipline (code review now, lint in Story 1.8), not new Swift access control — `StateStore`'s methods stay `public`.
- `StageEventLogger.record(event:)` sets `metadata_schema_version` on every insert (all 4 event kinds: started/completed/failed/retried), not just ones with rich metadata.
- `started`/`completed`/`failed` events go through `StateStore.recordStageTransition` (atomic stage_events + meetings.state write, unchanged from Story 1.4/1.5); `retried` events go through the existing `StateStore.insertStageEvent` (no state change on a mid-stage retry).
- `StageMetadata`'s 7 cases (`capture`, `transcribe`, `reviewDiarization`, `attribute`, `summarize`, `persist`, `notify`) and their `MetaContent` types are `Codable`, snake_case-dialect (`CodingKeys`) per AR-PAT-2, matching `stage_events.metadata_json`'s storage convention. `verify`/`discard` have no dedicated case (matching the AC's own 7-case list); their events carry no typed metadata.
- `TelemetryRecorder.record(meetingID:patch:)` performs a partial UPSERT: only the `patch` value's non-nil fields appear in the `DO UPDATE SET` clause, reusing the existing `State.Telemetry` record type as the patch shape (nil means "don't touch this column," not "set to NULL" — no caller ever needs to null out an owned column).
- `PipelineStage` (Story 1.5) moves from `Sources/Orchestrator/` to `Sources/Core/`, alongside `PipelineState`: `Telemetry` needs it (for `StageEventRecord.stage` and `StageMetadata`'s case-to-stage correspondence) and cannot depend on `Orchestrator` (`Orchestrator` already depends on `Telemetry`; the reverse would be circular).
- `Sources/Telemetry`'s `Package.swift` dependency gains `"State"` (needed for `StateStore`/`State.Telemetry`); every other stage target already declares both, so this brings `Telemetry` in line with the established pattern.

**Never:**
- Don't implement real stage business logic or populate `MetaContent` fields beyond what architecture.md's Decision 4.5 gives concrete example shapes for (`transcribe`, `reviewDiarization`, `summarize`, `persist`, `notify`); `capture`/`attribute` ship as minimal placeholder structs since no example shape exists yet and their real fields are each future stage's own call.
- Don't add Swift-level enforcement (access control, protocols) preventing direct `StateStore` calls from bypassing `StageEventLogger` — that mechanical enforcement is Story 1.8's swiftlint rule, per AR-PAT-4's own enforcement-layer list.
- Don't implement `auricle stats` (Epic 9) or any reader of the `telemetry` table — this story only builds the writer side.
- Don't change `StateStore.recordStageTransition`'s atomicity contract (still one `writer.write` per call) — `StageEventLogger` wraps it, doesn't replace it.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `StageEventLogger.record` with a `started`/`completed`/`failed` event | typed `StageEventRecord` with a `targetState` | `stage_events` row inserted + `meetings.state` updated atomically, `metadata_schema_version` set | N/A |
| `StageEventLogger.record` with a `retried` event | typed `StageEventRecord`, no `targetState` | `stage_events` row inserted only; `meetings.state` unchanged, `metadata_schema_version` set | N/A |
| Every `StageMetadata` case | round-trip through JSON | encode → decode → equal to the original | N/A |
| `TelemetryRecorder.record` first write for a meeting | `patch` with some fields non-nil | `telemetry` row created (`INSERT`) with only those columns populated | N/A |
| `TelemetryRecorder.record` second write, different columns | `patch` targeting different non-nil fields | existing row's new columns set; previously-set columns from the first write untouched (`ON CONFLICT DO UPDATE SET <only this patch's columns>`) | N/A |
| `StageRunner.run` end-to-end after the refactor | success and failure paths (Story 1.5's own scenarios, re-verified) | identical externally-observable behavior to Story 1.5 -- same `stage_events`/`meetings.state` outcomes, now routed through `StageEventLogger` | N/A |

</intent-contract>

## Code Map

- `epics.md:1019-1047` -- Story 1.6's full AC
- `architecture.md:1201-1253` (Decision 4.5) -- `stage_events` event table, `StageMetadata` enum sketch + per-stage example JSON, `metadata_schema_version` note, `telemetry` rollup table + UPSERT pattern
- `epics.md:292-302` (AR-AI-1 through AR-AI-9), specifically AR-AI-5 -- telemetry writer-partitioning rule (documented convention, not mechanically enforced here)
- `epics.md:307` (AR-PAT-2) -- JSON dialect rule (snake_case for `stage_events.metadata_json`)
- `Sources/State/StateStore.swift:118-149` -- `recordStageTransition` (unchanged contract, now called only by `StageEventLogger`); `insertStageEvent` (line 96, reused for `retried` events); needs one new method for telemetry UPSERT
- `Sources/State/StageEvent.swift` -- existing record type; add `metadataSchemaVersion: Int?` field + `CodingKeys` entry
- `Sources/State/Telemetry.swift` -- existing record type (20 fields, all-optional); reused directly as `TelemetryRecorder`'s `patch` parameter type
- `Sources/State/Migrations/{Migration001_Initial,MigrationRegistrar}.swift` -- migration #1 pattern to mirror for migration #2; `MigrationRegistrar` registers migrations in order, forward-only (AR-DATA-5)
- `Sources/Orchestrator/PipelineStage.swift` -- relocates to `Sources/Core/PipelineStage.swift` (see Boundaries); `Sources/Orchestrator/{StageRunner,CrashRecovery,ActiveStageInFlight}.swift` and their test files update their import accordingly
- `Sources/Orchestrator/StageRunner.swift` -- `run`/`synthesizeFailure` refactor to call `StageEventLogger.record(event:)`; gains a `StageEventLogger` init parameter alongside `StateStore`
- `Tests/OrchestratorTests/StageRunnerTests.swift`, `CrashRecoveryTests.swift` -- construct a `StageEventLogger` (backed by the same `StateStore`) instead of passing `StateStore` alone; assertions on `stage_events`/`meetings.state` outcomes should be unaffected (same atomic write underneath)
- `Package.swift:63` -- `Telemetry` target's dependency list gains `"State"`, matching every other stage target's existing `["Core", "State", "Telemetry", ...]` pattern
- `Sources/Core/Log.swift` -- existing logging facade; `telemetry` is already a listed category (AR-PAT-3)
- `Sources/Telemetry/ManifestPlaceholder.swift`, `Tests/TelemetryTests/.gitkeep` -- delete once real sources/tests land

## Tasks & Acceptance

**Execution:**
- `Sources/Orchestrator/PipelineStage.swift` → `Sources/Core/PipelineStage.swift` -- relocate (no content change); update the `import` in `StageRunner.swift`, `CrashRecovery.swift`, `ActiveStageInFlight.swift`, and their test files from `Orchestrator`-local to `Core`
- `Package.swift` -- add `"State"` to the `Telemetry` target's `dependencies`
- `Sources/State/Migrations/Migration002_StageEventsMetadataSchemaVersion.swift` -- new migration: `ALTER TABLE stage_events ADD COLUMN metadata_schema_version INTEGER DEFAULT 1;` -- Decision 4.5, AR-DATA-5 (forward-only)
- `Sources/State/Migrations/MigrationRegistrar.swift` -- register migration #2 after migration #1
- `Sources/State/StageEvent.swift` -- add `metadataSchemaVersion: Int?` field + `CodingKeys` (`metadata_schema_version`)
- `Sources/State/StateStore.swift` -- extend `recordStageTransition`/`insertStageEvent` to accept `metadataSchemaVersion`; add `upsertTelemetry(_ patch: Telemetry) async throws` performing a dynamic partial UPSERT (only `patch`'s non-nil, non-`meetingID` fields in `DO UPDATE SET`) -- Decision 4.5's UPSERT pattern
- `Sources/Telemetry/StageMetadata.swift` -- `public enum StageMetadata: Codable, Equatable, Sendable` with 7 cases (`capture(CaptureMeta)`, `transcribe(TranscribeMeta)`, `reviewDiarization(ReviewDiarizationMeta)`, `attribute(AttributeMeta)`, `summarize(SummarizeMeta)`, `persist(PersistMeta)`, `notify(NotifyMeta)`); each `MetaContent` type `Codable, Equatable, Sendable` with snake_case `CodingKeys`. Populate `TranscribeMeta` (`model_id`, `audio_duration_s`, `transcript_chars`), `ReviewDiarizationMeta` (`model_id`, `input_tokens`, `output_tokens`, `cost_usd`, `suggestions_count`, `review_skipped`), `SummarizeMeta` (`model_id`, `effort_budget`, `input_tokens`, `output_tokens`, `thinking_tokens`, `cost_usd`, `quote_validation_drop_count`, `grounding_method`), `PersistMeta` (`vault_note_path`, `frontmatter_schema_version`), `NotifyMeta` (`notification_id`, `delivered`) per architecture.md:1231-1235; `CaptureMeta`/`AttributeMeta` ship as minimal placeholder structs (no example shape given)
- `Sources/Telemetry/StageEventLogger.swift` -- `public actor StageEventLogger` wrapping a `StateStore`; `StageEventRecord` struct (meetingID, stage, event kind, occurredAt, targetState (nil for `retried`), durationMS, errorMessage, metadata); `record(event:) async throws` -- routes to `recordStageTransition` (has `targetState`) or `insertStageEvent` (`retried`, no `targetState`), JSON-encoding `metadata` via the snake_case dialect and always setting `metadataSchemaVersion`
- `Sources/Telemetry/TelemetryRecorder.swift` -- `public actor TelemetryRecorder` wrapping a `StateStore`; `record(meetingID:patch: State.Telemetry) async throws` calling `StateStore.upsertTelemetry`
- `Sources/Orchestrator/StageRunner.swift` -- add a `StageEventLogger` init parameter; `run`'s Txn A/Txn B and `synthesizeFailure` call `stageEventLogger.record(event:)` instead of `stateStore.recordStageTransition` directly
- `Tests/OrchestratorTests/StageRunnerTests.swift`, `CrashRecoveryTests.swift` -- update construction to inject a `StageEventLogger`; re-verify all of Story 1.5's existing assertions still hold post-refactor
- `Tests/TelemetryTests/StageMetadataRoundTripTests.swift` -- every `StageMetadata` case round-trips losslessly through JSON (the AC's own named test file)
- `Tests/TelemetryTests/StageEventLoggerTests.swift` -- started/completed/failed route through `recordStageTransition` (state changes), `retried` routes through `insertStageEvent` (state unchanged); `metadata_schema_version` set on all 4 kinds
- `Tests/TelemetryTests/TelemetryRecorderTests.swift` -- first-write creates a sparse row; a second write with different non-nil fields updates only those columns, leaving the first write's columns intact
- `Tests/StateTests/MigrationTests.swift` -- add a case asserting `stage_events.metadata_schema_version` exists after migration #2
- Delete `Sources/Telemetry/ManifestPlaceholder.swift`, `Tests/TelemetryTests/.gitkeep` once real sources/tests land

**Acceptance Criteria:**
- Given any `StageRunner.run` call (success or failure path), when it completes, then `StageEventLogger.record(event:)` was the code path that wrote the resulting `stage_events` row -- `StageRunner` itself no longer calls `StateStore.recordStageTransition` directly
- Given a `TelemetryRecorder.record` UPSERT for a meeting with no existing `telemetry` row, when a second `TelemetryRecorder.record` call patches different columns, then both writers' columns are present in the final row -- neither overwrote the other's data
- Given `swift build && swift test --filter TelemetryTests` (and `OrchestratorTests`, `StateTests`, `CoreTests` for the relocation/refactor), then all succeed with zero warnings and all tests pass

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 14, false 2, maybe-false 0
- findings:
  - `[low]` `[defer]` `StageMetadata`'s hand-written `Codable` conformance wraps each case's payload under a case-name key (`{"transcribe": {...}}`), but architecture.md's Decision 4.5 documents each stage's `metadata_json` as a **flat** object with no wrapper (Blind Hunter) — Verified: read `StageMetadata.swift`'s `encode(to:)`; confirmed the wrapper key. Real divergence from architecture's illustrative examples, but epics.md's own AC only requires snake_case dialect, not a specific flat/wrapped shape, and the wrapper exists to solve a genuine constraint (`capture`/`attribute`'s placeholders are content-identical `{}`, undecodable without a discriminator). No production caller exists yet to break. Settled by: whichever story builds the first real stage consumer of this JSON decides definitively whether generic self-describing decode or stage-column-driven decode (which wouldn't need a wrapper) is the real usage pattern.
  - `[low]` `[defer]` architecture.md's own `StageMetadata` Codable sketch (~line 1216) lists only 6 cases, omitting `reviewDiarization`, even though the same Decision 4.5 section's event table and per-stage metadata list both describe `reviewing_diarization` payloads — unlike the `metadata_schema_version` gap, this second architecture.md inconsistency isn't flagged anywhere in this story's spec or code (Blind Hunter) — Verified: confirmed via direct read of architecture.md's sketch. Pre-existing architecture-document gap, not caused by this diff (which correctly follows epics.md's 7-case AC); no code fix available, purely a documentation nit in a planning artifact outside this story's scope to edit.
  - `[low]` `[patch]` `startedCompletedAndFailedWithoutATargetStateThrowBeforeTouchingTheStore`'s name claims to cover all three kinds' missing-`targetState` validation, but its body only constructs and asserts a `.started` record (Blind Hunter) — Action: added `.completed`/`.failed` constructions to the same test, each omitting `targetState` and asserting the same throw.
  - `[low]` `[patch]` Same gap independently confirmed and pre-verified (Verification Gap Reviewer) — grouped with the row above, same fix.
  - `[low]` `[patch]` No test exercises migration #2 against a database that already has `stage_events` rows written under migration #1 alone -- the first genuine schema-upgrade path in this codebase (Blind Hunter) -- I independently confirmed via a temporary scratch test that `ALTER TABLE ... ADD COLUMN ... DEFAULT 1` correctly backfills pre-existing rows (the underlying mechanism is sound), but no permanent test protects this. Action: added a test in `MigrationTests.swift` that migrates with #1 only, inserts a row, then migrates to #2, asserting the new column backfills to `1`.
  - `[low]` `[patch]` `StageEventLogger.record`'s `.retried` branch never reads `event.targetState` -- a caller that mistakenly sets it gets no signal it was silently dropped (Blind Hunter) -- Verified: read the `.retried` case, confirmed `targetState` is unused. Action: added a guard throwing a new `RecordError` case when a `.retried` event carries a non-nil `targetState`, mirroring the existing `missingTargetState` pattern.
  - `[low]` `[patch]` Same gap independently confirmed with a proposed assertion (Edge Case Hunter) -- grouped with the row above, same fix.
  - `[low]` `[patch]` Several new doc comments narrate the change itself rather than describing the code as it stands (`"as of this story, neither does StageRunner itself"` in `StageRunner.swift`; `"as of this story"` in `StageEventLogger.swift`; `"this story's Design Notes flag..."` in `TelemetryRecorder.swift`) (Blind Hunter) -- Verified: grepped and confirmed all three. This directly violates the maintainer's own standing comment-style rule (no diff narration, no "as of this story" framing). Action: reworded all three to state the invariant as it stands, with no reference to "this story."
  - `[low]` `[patch]` `TelemetryRecorder`'s doc comment says `record(meetingID:patch:)` gives "the write-authority matrix... one enforcement point," but nothing in the method actually validates which columns a given caller may patch -- any caller can patch any column, including ones AR-AI-5 assigns to a different writer (Blind Hunter) -- Verified: read `record(meetingID:patch:)`; confirmed no column-ownership check exists. Action: reworded the comment to say column-level partitioning is a caller-discipline convention (per AR-AI-5), not something this method validates -- matching how `StageEventLogger`'s docs already correctly caveat the analogous stage_events single-writer rule.
  - `[low]` `[patch]` `StateStore.nonNilPatchColumns` silently returns `[]` on any JSON-encoding failure (e.g. a `NaN`/`infinite` `Double`), indistinguishable from an intentionally-empty patch -- a caller passing a corrupt value would see a silent no-op UPSERT instead of an error (Blind Hunter) -- Verified: read the `guard ... else { return [] }`. Action: changed to throw instead of silently returning `[]` on an encoding failure.
  - `[low]` `[patch]` architecture.md's Decision 4.5 documents a `started` event's `metadata_json` as `{}` ("just a timestamp marker"), but `StageRunner.run`'s `.started` call never sets `metadataJSON`, so the column stores SQL `NULL` instead (Blind Hunter) -- Verified: read `StageRunner.run`'s Txn A construction, confirmed no `metadataJSON` set. Action: explicitly pass `metadataJSON: "{}"` for the `.started` event.
  - `[low]` `[patch]` `StateStore.upsertTelemetry` discards the row `upsertAndFetch` returns, paying for an unused `RETURNING` round-trip (Blind Hunter) -- Verified: read the `_ = try record.upsertAndFetch(...)` call. Action: switched to plain `upsert(db, ...)` (no fetch), same behavior, no wasted round-trip.
  - `[false]` `[reject]` `TelemetryRecorder.record` called with a patch having no non-identity fields set could produce an empty `DO UPDATE SET` clause and throw invalid SQL on an existing row (Edge Case Hunter) -- Refutation: empirically tested via a temporary scratch test (`recorder.record` with an all-nil patch against an existing row) -- it completes without error and leaves the existing row's values untouched; GRDB's `upsertAndFetch` handles an empty `doUpdate` column list gracefully. Scratch test removed after confirming.
  - `[false]` `[reject]` `recordStageTransition` could be called without `metadataSchemaVersion`, falling back to its `nil` default instead of the schema's `DEFAULT 1` (Edge Case Hunter) -- Refutation: read `StageEventLogger.record`, the sole caller post-refactor -- it always explicitly passes `Self.currentMetadataSchemaVersion` on both the transition and retried-event code paths; the parameter's `nil` default is never actually exercised by any real call site.
  - `[low]` `[patch]` `StageMetadata.init(from:)` iterates its 7 recognized keys in a fixed order and returns the first successful decode; a hand-crafted `metadata_json` containing two or more recognized keys at once would silently decode the wrong case with the others' data dropped, no error (Edge Case Hunter) -- Verified: read the `if let ... else if let ...` decode chain, confirmed no check that exactly one key is present. Real but unreachable via any code path that only ever encodes one key per value; still a cheap, direct fix. Action: added a check that exactly one recognized key is present before decoding, throwing otherwise.
  - `[low]` `[defer]` `sprint-status.yaml`'s Epic 1 entries (now `1-4`, `1-5`, and `1-6`) all still read `backlog` (Intent Alignment Auditor) -- Verified: read `sprint-status.yaml` directly. Same recurring, already-documented systemic gap logged against Stories 1.4 and 1.5 -- this workflow variant never touches the file; not fixable at the individual-story level.

## Design Notes

**Why `metadata_schema_version` needs a new migration rather than belonging to migration #1:** architecture.md's Decision 4.5 (line 1227) states the column exists, describing it as part of "the schema... locked in Decision 2.1" -- but Decision 2.1's own `CREATE TABLE stage_events` SQL (verbatim-copied into migration #1 in Story 1.4) never actually includes it. This is a pre-existing inconsistency between two architecture.md sections, not something either Story 1.4 or this story's diff introduced. Since Story 1.4's "no future migration needed" guarantee was specifically about the `telemetry` table's wedge-validation columns (Amelia's Story 1 blocker), not `stage_events`, adding migration #2 here doesn't violate anything -- it's exactly what `GRDB.DatabaseMigrator`'s forward-only model exists for (AR-DATA-5).

**Why `PipelineStage` moves to `Core` rather than `Telemetry` importing `Orchestrator`:** `Orchestrator` already depends on `Telemetry` (Package.swift); `Telemetry` depending back on `Orchestrator` would be circular. `Core` is the one target both already depend on, and `PipelineState` already lives there -- `PipelineStage` belongs beside it. This is a real architectural gap Story 1.5 left (that story's own Code Map reasoned `PipelineStage` was Orchestrator-only without anticipating Telemetry's later need for the same vocabulary), corrected here rather than deferred, since the fix is a pure relocation with no behavior change and blocks this story's own compile otherwise.

**Why `StateStore.recordStageTransition`/`insertStageEvent` stay `public` rather than becoming `internal` to force all callers through `StageEventLogger`:** they're `State`-target methods; `internal` would make them invisible to `Telemetry` (a different target) entirely, which can't work since `StageEventLogger` itself needs to call them. Swift's access control can't express "callable only from one specific other module" -- the "only `StageEventLogger` writes `stage_events`" rule is necessarily a call-site convention, enforced by code review now and Story 1.8's lint rule later, matching how every other AR-PAT-4 primitive in this codebase is already enforced.

**Naming caution:** `Sources/Telemetry/TelemetryRecorder.swift` lives inside the `Telemetry` *module*, but reuses `State.Telemetry` (the GRDB record *type*) as its patch shape. Reference it as `State.Telemetry` explicitly at every use site in this target, even though an unqualified `Telemetry` would resolve correctly today -- the coincidental name match between the module and the type is exactly the kind of thing that reads as a typo to a future reader.

## Verification

**Commands:**
- `swift build && swift test --filter TelemetryTests` -- expected: exit 0, all tests pass, zero `Telemetry` warnings
- `swift test --filter OrchestratorTests` -- expected: still 0 failures after the `StageRunner`/`PipelineStage` refactor (regression check on Story 1.5's work)
- `swift test --filter StateTests` -- expected: still 0 failures after migration #2 and the `StageEvent`/`StateStore` extensions (regression check on Story 1.4's work)
- `swift test --filter CoreTests` -- expected: still 0 failures after `PipelineStage` relocates into `Core`
- `grep -rln "\.write \{\|\.read \{" Sources/ --include="*.swift" | grep -v Sources/State/` -- expected: no matches (the actual codebase convention, not the literal `db\.read`/`db\.write` substrings the earlier spec's grep mistakenly checked for) -- confirms nothing outside `StateStore` opens a raw GRDB transaction

## Auto Run Result

**Summary:** Built the `Telemetry` target: `StageMetadata` (7-case Codable enum + 7 `MetaContent` types), `StageEventLogger` (the sole `stage_events` writer going forward, wrapping `StateStore`), and `TelemetryRecorder` (partial UPSERT into `telemetry` via a new `StateStore.upsertTelemetry`). Refactored `StageRunner` (Story 1.5) to call `StageEventLogger.record(event:)` instead of `StateStore` directly, per this story's AC. Added migration #2 (`stage_events.metadata_schema_version`) to close a gap where architecture.md's Decision 4.5 assumed a column Decision 2.1's own SQL never included. Relocated `PipelineStage` from `Orchestrator` to `Core` (Telemetry needs it; Telemetry can't depend on Orchestrator, which already depends on Telemetry).

**Files changed:**
- `Sources/State/Migrations/Migration002_StageEventsMetadataSchemaVersion.swift` -- new migration, registered after #1
- `Sources/State/{StageEvent,StateStore}.swift` -- `metadataSchemaVersion` field; `upsertTelemetry` (hand-rolled partial UPSERT SQL, post-patch)
- `Sources/Core/PipelineStage.swift` -- relocated from `Orchestrator`
- `Sources/Telemetry/{StageMetadata,StageEventLogger,TelemetryRecorder}.swift` -- the target's full source
- `Sources/Orchestrator/StageRunner.swift` -- refactored to call `StageEventLogger`
- `Package.swift` -- `Telemetry` target gained a `State` dependency
- `Tests/TelemetryTests/{StageMetadataRoundTripTests,StageEventLoggerTests,TelemetryRecorderTests}.swift`, `Tests/CoreTests/PipelineStateTests.swift` (relocation), `Tests/StateTests/MigrationTests.swift` (migration #2 coverage), `Tests/OrchestratorTests/StageRunnerTests.swift` (updated for the refactor) -- 101 tests pass repo-wide
- Deleted `Sources/Telemetry/ManifestPlaceholder.swift`, `Tests/TelemetryTests/.gitkeep`

**Review findings breakdown** (16 findings across Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor — full detail in `## Review Triage Log` above):
- **Patched (11 findings, all low):** a test whose name overclaimed its own coverage (only `.started` tested, not `.completed`/`.failed`); a missing migration-upgrade-path test (verified the underlying SQLite mechanism was already sound via a temporary scratch test before adding the permanent one); a silently-dropped `targetState` on `.retried` events (now throws); three doc comments that narrated the change itself rather than the code as it stands (a direct violation of the maintainer's standing comment-style rule, fixed regardless of low severity); an overclaimed "enforcement" comment on `TelemetryRecorder`; a silent no-op on JSON-encoding failure in the telemetry UPSERT path (now throws); a `started` event storing `NULL` instead of architecture's documented `{}`; a wasted `RETURNING` round-trip in the UPSERT (rewritten as hand-rolled SQL); and a ambiguous-multi-key decode gap in `StageMetadata` (now validated).
- **Deferred (3 findings, all low):** `StageMetadata`'s wrapper-key JSON shape diverging from architecture.md's flat illustrative examples (a real but currently-inert divergence — no production caller exists yet); a second, pre-existing architecture.md inconsistency (its own `StageMetadata` sketch omits `reviewDiarization`); the same recurring `sprint-status.yaml` staleness (now three stories out of sync).
- **Rejected (2 findings, both false):** a claimed empty-`DO UPDATE SET`-clause SQL error, refuted by direct empirical test (a temporary scratch test proved GRDB/SQLite handle it gracefully); a claimed `metadataSchemaVersion` nil-default gap, refuted by reading the sole caller (`StageEventLogger`), which always passes it explicitly.

**Follow-up review recommendation:** `false` -- every patched finding this pass was `low` severity; no `high` was patched and fewer than two `medium`s were patched (zero were).

**Verification performed:** `swift build` (clean, 0 warnings) and full `swift test` (101/101 pass across all targets) re-run independently after the patch batch, not just trusted from the subagent's report. Directly read the rewritten `StateStore.upsertTelemetry`/`jsonObject(for:)` (the highest-risk patch, a hand-rolled SQL rewrite replacing GRDB's `upsertAndFetch`) to confirm correctness rather than relying on tests alone. `grep -rln '\.write {\|\.read {' Sources/ --include="*.swift" | grep -v Sources/State/` -- no matches, confirmed before and after patches. I/O & Edge-Case Matrix audit: all 6 matrix rows have covering tests that ran and passed; patches added coverage, removed none.

**Residual risks:** the two `StageMetadata`-shape-related deferred findings should be revisited once a real stage (Epic 3/4) becomes the first actual producer of `stage_events.metadata_json` -- that story will settle whether the wrapper-key shape this story chose is the right one, or whether decoding via the already-known `stage_events.stage` column (which wouldn't need a wrapper) is the real usage pattern. `sprint-status.yaml` continues to understate Epic 1 progress across all three stories delivered this session.
