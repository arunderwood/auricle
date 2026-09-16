---
title: 'Story 1.4: SQLite Schema, StateStore, and GRDB Migrations (with Full Telemetry Counter Columns)'
type: 'feature'
created: '2026-09-16'
status: 'blocked'
baseline_revision: 'b045c5227a0ccabc02316af0bed363165175b8d0'
review_loop_iteration: 0
followup_review_recommended: false
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
warnings: [oversized]
deferred:
  - summary: >-
      The `schema_version` table is created by migration #1 but nothing ever
      inserts a row into it, despite its comment implying it is kept current.
    evidence: |-
      GRDB's `DatabaseMigrator` tracks applied migrations in its own internal
      table, not this app-level `schema_version` table. No INSERT into
      `schema_version` exists anywhere in Story 1.4's diff, and nothing reads
      it either. The table and its misleading comment are copied verbatim
      from architecture.md's own Decision 2.1 SQL, which this story's frozen
      intent-contract requires be reproduced exactly, so it isn't fixable
      within this story without deviating from that frozen boundary.
    location: >-
      Sources/State/Migrations/Migration001_Initial.swift
    severity: low
  - summary: >-
      `meetings.duration_seconds`'s comment claims a `CHECK (>= 0)`
      constraint that does not actually exist in the DDL, so negative
      durations are silently accepted.
    evidence: |-
      Read the DDL directly: the column is declared `duration_seconds
      INTEGER` with only a comment, no real `CHECK` clause. No test inserts
      a negative value. The column and its comment are copied verbatim from
      architecture.md's own Decision 2.1 SQL, which this story's frozen
      intent-contract requires be reproduced exactly ("Schema is exactly
      architecture.md:691-774's SQL"), so adding a real constraint here
      would deviate from that frozen boundary. Settled by: an
      architecture-level decision to either add the constraint or strike the
      misleading comment.
    location: >-
      Sources/State/Migrations/Migration001_Initial.swift:36
    severity: medium
  - summary: >-
      The terminal-state list `'verified','retention_expired','discarded'`
      is duplicated as independent raw strings in two places with no shared
      constant.
    evidence: |-
      `idx_meetings_state`'s partial-index predicate (migration SQL) and
      `StateStore.fetchPending()`'s filter string list the same three states
      independently; a future edit to one without the other would silently
      desync them. `fetchPending()`'s doc comment already cross-references
      the index by name, partially mitigating drift risk. True unification
      is blocked by the migration SQL side needing to stay frozen-verbatim
      per architecture.md. Best resolved when a future story next touches
      this code (e.g. one adding new terminal states).
    location: >-
      Sources/State/StateStore.swift; Sources/State/Migrations/Migration001_Initial.swift
    severity: low
  - summary: >-
      `sprint-status.yaml`'s `1-4-...` entry still reads `backlog` even
      though the story is now implemented, breaking the pattern where
      Stories 1.1/1.2/1.3 each updated their own entry in the same
      changeset.
    evidence: |-
      Read `sprint-status.yaml` directly and confirmed the `1-4-...` entry
      still reads `backlog`. This workflow's own rendered instructions
      (workflow.md through step-04-review.md, followed exactly for this
      run) never reference `sprint-status.yaml` at all. Per this repo's own
      `deferred-work.md` (logged against Story 1.2), syncing that file is a
      separate, previously-documented systemic gap in how this workflow
      variant operates, not something this story's diff introduced or can
      fix on its own.
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml
    severity: low
---

<intent-contract>

## Intent

**Problem:** `Core` and `Telemetry` have no persistence layer. Every future stage needs one SQLite database with a stable schema from day one — including every wedge-validation/trust-calibration telemetry counter column — so no later epic ever needs a migration to backfill a column that should have existed from the start (FR66, Amelia's Story 1 blocker).

**Approach:** Stand up the `State` target: GRDB migration #1 creating all five canonical tables (`schema_version`, `meetings`, `stage_events`, `retention_timers`, `telemetry`) verbatim per architecture.md Decision 2.1, GRDB record types conforming to `FetchableRecord`+`MutablePersistableRecord`, a `DatabasePoolFactory` choosing `DatabasePool` (GUI) vs `DatabaseQueue` (subprocess), and a `StateStore` actor as the sole read/write API.

## Boundaries & Constraints

**Always:**
- Schema is exactly architecture.md:691-774's SQL: 5 tables, the `meetings_updated_at` AFTER UPDATE trigger, `idx_meetings_state` (partial), `idx_stage_events_meeting`, `idx_retention_pending_fires_at`.
- All 19 telemetry columns (architecture.md:742-767) exist from migration #1 — never add one later.
- WAL mode set in migration #1 (sticky in file header); `PRAGMA foreign_keys = ON` and `Configuration.busyMode = .timeout(5.0)` on every opener (AR-DATA-2).
- Before writing migration #1: spike-build GRDB `7.0.0` against this package (currently `swift-tools-version: 6.3`, Swift 6.3.1 toolchain). If clean, bump `Package.swift`'s floor from `from: "6.29.0"` to `from: "7.0.0"`; if not, keep `6.29.0` and record why (architecture.md:798).
- `StateStore` is a Swift `actor` (architecture.md:1968) and the only path to `db.read`/`db.write` on this database (AR-PAT-4); typed methods only (e.g. `fetchMeeting(id:)`, `fetchPending()`).
- Partial/filtered indexes are raw SQL (`db.execute(sql:)`) — GRDB's typed builder doesn't support `WHERE` on indexes (architecture.md:797).

**Never:**
- Don't implement `Orchestrator`, `StageRunner`, crash recovery, or any state-transition logic — Story 1.5.
- Don't create a typed `PipelineState` enum for `meetings.state`. Nothing in this story's AC requires one; `Meeting.state` is plain `String` at the record level. A typed enum's natural home is wherever transitions are implemented (Story 1.5), and inventing one here would be unrequested scope.
- Don't implement `TelemetryRecorder`/`StageEventLogger` UPSERT writer methods — Story 1.6 owns writing to these tables; this story only owns the schema + read/write plumbing.
- Don't wire GUI app-lifecycle checkpointing (`wal_checkpoint(TRUNCATE)` on quit/transition) — that's Orchestrator/App-lifecycle wiring, not this target.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh machine, first production open | no db file exists at the target path | File created at `~/Library/Application Support/com.auricle.app/auricle.sqlite3`; WAL enabled; all 5 tables + trigger + 3 indexes present | N/A |
| GUI opens the database | `StateStore.production()` | Backed by GRDB `DatabasePool` | N/A |
| Subprocess opens the database | `StateStore.subprocess()` | Backed by GRDB `DatabaseQueue` | N/A |
| Concurrent GUI + subprocess writers | both briefly hold a writer | 5s busy-timeout absorbs the contention window; no `SQLITE_BUSY` surfaced | Contention outlasting 5s surfaces GRDB's `DatabaseError` to the caller |

</intent-contract>

## Code Map

- `architecture.md:685-843` (Decision 2.1) -- authoritative SQL schema, write-authority matrix, GRDB/WAL/concurrency rules; source of truth for migration #1's DDL
- `epics.md:927-976` -- Story 1.4's full AC, including the GRDB 7 build-spike precondition
- `epics.md:263-271` -- AR-DATA-1 through AR-DATA-9 summary
- `epics.md:306-316` -- AR-PAT-1 through AR-PAT-11 (actor discipline, naming, helper-bypass enforcement -- lint enforcement itself is Story 1.8)
- `Package.swift:17-18,63,113,126` -- `State`/`StateTests` targets already declared, GRDB `from: "6.29.0"` already a dependency; only the version floor may change here
- `Sources/State/ManifestPlaceholder.swift` -- delete once real `State/` sources land (its own comment says so)
- `Tests/StateTests/.gitkeep` -- remove once real tests land
- `Sources/Core/MeetingID.swift` -- existing ULID wrapper; `meetings.id` is `TEXT PRIMARY KEY` at the GRDB/SQL level, wrap at the `StateStore` API boundary
- `Sources/Core/Log.swift` -- existing logging facade; `state` is already a listed category (AR-PAT-3) for `StateStore`'s internal logging
- `architecture.md:2252-2261` -- target source-tree sketch for `State/` (filename guidance, not per-story scope authority)

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- spike-build GRDB `7.0.0`; bump the floor if clean, else keep `6.29.0` and record why -- architecture.md:798
- `Sources/State/Migrations/Migration001_Initial.swift` -- GRDB migration creating all 5 tables + `meetings_updated_at` trigger + all 3 indexes verbatim per architecture.md:691-774 -- AR-DATA-1, AR-DATA-5
- `Sources/State/Migrations/MigrationRegistrar.swift` -- `GRDB.DatabaseMigrator` setup registering migration001, forward-only -- AR-DATA-5
- `Sources/State/Meeting.swift`, `StageEvent.swift`, `RetentionTimer.swift`, `Telemetry.swift` -- GRDB record types (`FetchableRecord`+`MutablePersistableRecord`), one column per table field -- epics.md:966-970
- `Sources/State/DatabasePoolFactory.swift` -- GUI path returns `DatabasePool`, subprocess path returns `DatabaseQueue`; sets `busyMode`, `PRAGMA foreign_keys`, WAL journal mode on every opener -- AR-DATA-2
- `Sources/State/StateStore.swift` -- `actor StateStore` with `.production()` (Pool-backed) and `.subprocess()` (Queue-backed) static factories, plus typed read/write methods -- AR-PAT-4, AR-PAT-6
- `Tests/StateTests/MigrationTests.swift` -- round-trip: migration applies to an empty DB, `PRAGMA journal_mode == "wal"`, every column exists with correct type/constraints -- epics.md:972-974
- `Tests/StateTests/ConcurrencyTests.swift` -- WAL + cross-process write contention under the busy-timeout setting -- epics.md:975
- Delete `Sources/State/ManifestPlaceholder.swift` and `Tests/StateTests/.gitkeep` once real sources/tests land

**Acceptance Criteria:**
- Given a fresh machine, when `StateStore.production()`'s underlying database is opened for the first time, then the file exists at `~/Library/Application Support/com.auricle.app/auricle.sqlite3` with all 5 tables, the trigger, and all 3 indexes present exactly per architecture.md Decision 2.1
- Given `Sources/State/`, when `swift build && swift test --filter StateTests` runs, then both succeed with zero warnings and all tests pass
- Given `Meeting`, `StageEvent`, `RetentionTimer`, `Telemetry` record types, when inserted/fetched via `StateStore`, then they round-trip losslessly through GRDB's `FetchableRecord`/`MutablePersistableRecord` conformances

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 18 findings — high 0, medium 2, low 12, false 4, maybe-false 0
- findings:
  - `[low]` `[defer]` `schema_version` table is created but nothing ever inserts into it, despite its comment ("owned exclusively by GRDB.DatabaseMigrator. No application code writes this") implying it's kept current — GRDB 7 actually tracks applied migrations in its own internal table, so this app-level table stays permanently empty (Blind Hunter) — Verified: no INSERT into `schema_version` anywhere in the diff. Real but inherited verbatim from architecture.md's own SQL/comment, which the spec's frozen `<intent-contract>` requires be reproduced exactly; not fixable within this story without deviating from that frozen boundary. Nothing reads this table either, so it's inert rather than harmful.
  - `[low]` `[patch]` `Tests/StateTests/MigrationTests.swift`'s comment says "All 19 wedge-validation / trust-calibration counter columns," but the `telemetry` table has 20 non-PK columns (confirmed by counting the DDL and the test's own `expectedColumns` array, which correctly lists all 20) — the code and test logic are correct, only the English count in the comment is wrong (Blind Hunter) — Action: reworded the comment to say 20. The same miscount also appears in this spec's own frozen `<intent-contract>` Boundaries text ("All 19 telemetry columns"); that occurrence cannot be corrected here (frozen), so it's left as a known label inaccuracy in prescriptive text with no functional effect.
  - `[medium]` `[defer]` `meetings.duration_seconds`'s comment claims `CHECK (duration_seconds >= 0) when set`, but no real SQL `CHECK` constraint exists on the column, and no test inserts a negative value — negative durations would be silently accepted (Blind Hunter) — Verified: read the DDL directly, confirmed no `CHECK` clause exists; confirmed no test exercises a negative value. Real gap, but the comment and column definition are copied verbatim from architecture.md's own Decision 2.1 SQL, which the frozen `<intent-contract>` requires be reproduced exactly ("Schema is exactly architecture.md:691-774's SQL"). Adding a real `CHECK` constraint would deviate from that frozen boundary. Settled by: an architecture-level decision to either add the constraint or strike the misleading comment.
  - `[low]` `[patch]` No test exercises `foreignKeysEnabled = true`'s cascade-on-delete behavior, despite the code's own comment naming `ON DELETE CASCADE` integrity as the reason for the setting (Blind Hunter) — Action: added a test that deletes a `meetings` row via raw SQL and asserts the corresponding `stage_events`/`retention_timers`/`telemetry` rows are gone.
  - `[low]` `[defer]` The terminal-state list `'verified','retention_expired','discarded'` is duplicated as independent raw strings in `idx_meetings_state`'s partial-index predicate and in `StateStore.fetchPending()`'s filter, with no shared constant — a future edit to one without the other would silently desync them (Blind Hunter) — Verified: both strings are independent literals in separate files. Real but low: `fetchPending()`'s doc comment already cross-references the index by name, partially mitigating drift risk; true unification is blocked by the migration SQL side needing to stay frozen-verbatim per architecture.md. Best resolved when a future story (e.g. one adding new terminal states) next touches this code.
  - `[false]` `[reject]` `StateStore` has no delete method for meetings, so the schema's `ON DELETE CASCADE` design is never exercised by any current caller (Blind Hunter) — Refutation: this story's frozen Boundaries explicitly scope it to schema + read/write plumbing; meeting deletion/discard is a distinct future capability (Epic 8) with no AC in this story requiring it. Deliberate scoping, not an oversight.
  - `[low]` `[patch]` No test inserts a `StageEvent`/`RetentionTimer`/`Telemetry` row referencing a nonexistent `meeting_id` to confirm `foreignKeysEnabled = true` actually rejects the orphan insert (Blind Hunter) — Action: added a test inserting a `StageEvent` with a nonexistent `meeting_id` and asserting it throws `DatabaseError`. Grouped with the cascade-delete gap above (same untested config flag).
  - `[false]` `[reject]` No artifact confirms the GRDB 7 spike-build gate was actually run and passed (Blind Hunter) — Refutation: `Package.resolved`'s pin change (GRDB 6.29.3 → 7.11.1) plus an independently reproduced clean `swift build`/`swift test --filter StateTests` (both re-run during this review, 0 warnings, all green) together are the evidence. The AC (epics.md:939) requires a recorded rationale only when the build is NOT clean; it was clean.
  - `[false]` `[reject]` The spec's `warnings: [oversized]` is carried with nothing addressing it (Blind Hunter) — Refutation: per the spec template's own instructions, `oversized` is an add-and-continue flag for cohesive cross-layer stories that should stay in one file, not a defect requiring remediation.
  - `[false]` `[reject]` Given the other findings, a follow-up review "looks warranted" (Blind Hunter) — Refutation: once each cited finding is actually triaged (this pass), none is a patched `high` and fewer than two `medium`s were patched (zero were), so the Finalize formula does not call for a follow-up.
  - `[low]` `[patch]` `DatabasePoolFactory.baseConfiguration()`'s doc comment ends in a dense, hard-to-parse run-on sentence about WAL/journalMode (Blind Hunter) — Action: reworded for clarity; no behavior change.
  - `[medium]` `[defer]` `Migration001_Initial.swift:36`'s `duration_seconds` column has a comment claiming a `CHECK (>= 0)` constraint that isn't actually in the DDL (Edge Case Hunter) — same claim as the duration_seconds finding above; grouped with it, same verdict and route.
  - `[low]` `[patch]` `ConcurrencyTests.swift`'s `writeContentionWithinBusyTimeoutSucceedsWithoutError` wraps the lock-holder closure in `try?`; if `guiPool.write` throws before reaching `lockAcquired.signal()`, the semaphore never signals and `lockAcquired.wait()` on the main test thread blocks forever instead of failing (Edge Case Hunter) — Verified: read the test, confirmed `try?` swallows any throw before the signal call. Action: restructured so the signal fires on all paths (via `defer`).
  - `[low]` `[patch]` Same `try?`-swallows-before-signal hang risk in `writeContentionOutlastingBusyTimeoutThrowsDatabaseError` (Edge Case Hunter) — grouped with the finding above, same verdict, route, and fix.
  - `[low]` `[patch]` `fetchPendingExcludesTerminalStates` never inserts a meeting in the `retention_expired` state, so a regression that stops excluding that state from `fetchPending()` would ship undetected (Edge Case Hunter) — Verified: read the test, confirmed only `verified` and `discarded` are exercised as excluded states. Action: added a fourth insert with `state: "retention_expired"` and an assertion it's excluded.
  - `[low]` `[patch]` `meetingRoundTripsLosslesslyThroughStateStore` asserts only 7 of `Meeting`'s 13 fields, leaving `createdAt`, `updatedAt`, `durationSeconds`, `vaultNotePath`, `verifiedAt`, `retentionPolicy` unverified against the original values, short of AC3's "round-trip losslessly" (Edge Case Hunter, medium confidence claim) — Verified: read the test, confirmed only 7 fields are asserted. Action: assert full equality (`#expect(fetched == original)`), matching the pattern already used in the Telemetry round-trip test.
  - `[low]` `[patch]` Same `fetchPending()`/terminal-state gap as above, filed independently and pre-verified (Verification Gap Reviewer) — pre-verified per this layer's own evidence rules; grouped with the Edge Case Hunter row above, same verdict, route, and fix.
  - `[low]` `[defer]` `sprint-status.yaml`'s `1-4-...` entry remains `backlog` even though the story is now implemented, diverging from the pattern where Stories 1.1/1.2/1.3's implementing commits each updated their own entry in the same changeset (Intent Alignment Auditor) — Verified: read `sprint-status.yaml` directly, confirmed the `1-4-...` entry still reads `backlog`. This workflow's own rendered instructions (`workflow.md` through `step-04-review.md`, followed exactly for this run) never reference `sprint-status.yaml` at all; per this repo's own `deferred-work.md` (Story 1.2 entry), syncing that file is a separate, previously-documented systemic gap in how this workflow variant operates — not something this story's diff introduced or can fix.

## Design Notes

GRDB 7's unverified-against-this-package status (architecture.md:798) is a real gate, not a formality: confirm the spike build succeeds before migration #1 is written, since the migration itself may need to target whichever GRDB API version wins.

`StateStore` being an `actor` (not a plain struct) is deliberate per architecture.md:1968's explicit actor list — GRDB's `DatabasePool`/`DatabaseQueue` are already internally thread-safe, but the actor boundary is what gives `StateStore`'s own typed API mutual exclusion consistent with AR-PAT-6, and matches how `Verifier` and `Telemetry` are specified elsewhere in the same architecture.

## Verification

**Commands:**
- `swift build && swift test --filter StateTests` -- expected: exit 0, all tests pass, zero `State` warnings
- `grep -rn "db\.read\|db\.write" Sources/ --include=*.swift | grep -v Sources/State/` -- expected: no matches (confirms nothing outside `StateStore` touches the database directly)

## Auto Run Result

**Summary:** Stood up the `State` target: GRDB migration #1 creating all 5 canonical tables (`schema_version`, `meetings`, `stage_events`, `retention_timers`, `telemetry`, with all 20 telemetry counter columns) verbatim per architecture.md Decision 2.1, four GRDB record types (`Meeting`, `StageEvent`, `RetentionTimer`, `Telemetry`), a `DatabasePoolFactory` choosing `DatabasePool` (GUI) vs `DatabaseQueue` (subprocess), and a `StateStore` actor as the sole read/write API with `.production(path:)` / `.subprocess(path:)` factories. Spiked GRDB 7.0.0 against this package first (clean build), so bumped the dependency floor from `6.29.0`.

**Files changed:**
- `Package.swift` / `Package.resolved` -- GRDB floor bumped `6.29.0` → `7.0.0`, resolved to `7.11.1`
- `Sources/State/Migrations/Migration001_Initial.swift` -- migration #1: all 5 tables, the `meetings_updated_at` trigger, all 3 indexes
- `Sources/State/Migrations/MigrationRegistrar.swift` -- `GRDB.DatabaseMigrator` registration
- `Sources/State/{Meeting,StageEvent,RetentionTimer,Telemetry}.swift` -- GRDB record types (`FetchableRecord`+`MutablePersistableRecord`)
- `Sources/State/DatabasePoolFactory.swift` -- path resolution + `DatabasePool`/`DatabaseQueue` openers sharing one `Configuration` (busy timeout, foreign keys, WAL)
- `Sources/State/StateStore.swift` -- `actor StateStore`, the sole read/write API
- `Tests/StateTests/{MigrationTests,ConcurrencyTests,StateStoreTests,StateStoreFactoryTests}.swift` -- 30 tests total
- Deleted `Sources/State/ManifestPlaceholder.swift`, `Tests/StateTests/.gitkeep`

**Review findings breakdown** (18 findings across Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor — full detail in `## Review Triage Log` above):
- **Patched (9 findings, all low):** telemetry column count mislabeled "19" vs actual 20 in a test comment; missing cascade-delete and orphan-insert-rejection tests for `foreignKeysEnabled`; a dense doc comment on `DatabasePoolFactory.baseConfiguration()`; two concurrency tests that could hang instead of fail on an unexpected throw; `fetchPendingExcludesTerminalStates` missing `retention_expired` coverage; `Meeting` round-trip test checking only 7 of 13 fields.
- **Deferred (4 findings):** `schema_version` table permanently empty (low, inherited verbatim from frozen architecture.md SQL/comment); `duration_seconds` comment claims a `CHECK (>= 0)` constraint that isn't actually in the DDL (medium, same frozen-verbatim-SQL constraint); terminal-state list duplicated as raw strings with no shared constant (low, one side is frozen-verbatim SQL); `sprint-status.yaml`'s `1-4-...` entry not updated to reflect implementation (low, out of this workflow variant's own scope per its rendered instructions and `deferred-work.md` precedent).
- **Rejected (4 findings, all false):** no delete method exercising the cascade design (deliberately out of this story's scope); no artifact confirming the GRDB 7 spike ran (refuted by `Package.resolved`'s pin change + a reproduced clean build); `warnings: [oversized]` left unaddressed (per spec-template design, not a defect); speculation that a follow-up review is warranted (refuted once findings were actually triaged).

**Follow-up review recommendation:** `false` -- only `low`-severity findings were patched this pass (9 of them, zero `medium`/`high`), so per the finalize formula ("true if any patched entry was high, or if two or more medium entries were patched") no follow-up is warranted.

**Verification performed:** `swift build` (clean rebuild, 0 errors, 0 warnings attributable to `State`) and `swift test --filter StateTests` (30/30 pass) re-run independently after the patch batch, not just trusted from the implementation subagent's report. `grep -rn "db\.read\|db\.write" Sources/ --include="*.swift" | grep -v Sources/State/` -- no matches, confirmed twice (before and after patches). I/O & Edge-Case Matrix audit: all 4 matrix rows (fresh-machine production open, GUI/`DatabasePool` opener, subprocess/`DatabaseQueue` opener, concurrent-writer contention within/beyond the busy timeout) have covering tests that ran and passed, verified through the actual `StateStore.production()`/`.subprocess()` entry points after an initial gap (no test exercised those methods directly) was found and closed before this diff went to review.

**Residual risks:** the two deferred `Migration001_Initial.swift` gaps (empty `schema_version` table; unenforced `duration_seconds >= 0`) are real but architecturally frozen out of this story's reach — worth flagging at the next architecture review. `sprint-status.yaml` will continue to understate progress on Epic 1 stories delivered through this workflow variant until that sync gap is addressed at the orchestration level, not the story level.

**Finalization blocked:** implementation, review, and all patches are complete and verified (`swift build` clean, `swift test --filter StateTests` 30/30, db-access boundary check clean). `git commit` fails with `error: 1Password: failed to fill whole buffer` / `fatal: failed to write commit object` on every attempt (3 tries, including a 3s retry) — this repo signs commits via SSH through 1Password's `op-ssh-sign` (`gpg.format = ssh`, `commit.gpgsign = true`), and 1Password's signing helper appears to need interactive user presence (biometric/vault unlock) that isn't available in this unattended session, even though the 1Password app and its SSH agent socket are both running. Per this workflow's own rules, bypassing signing (`--no-gpg-sign`) is not something I'll do without the user explicitly asking. Status set to `blocked` rather than `done`: all 18 files remain staged but uncommitted in the working tree.
