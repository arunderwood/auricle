# Epic 1 Context: Foundation — Pipeline State + Atomic-Write Backbone

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 1 bootstraps the auricle repository (hybrid SwiftPM + Xcode/Tuist project, CI) and builds the pipeline backbone every later stage plugs into: the SQLite state machine, the cache-dir handoff convention, the atomic-write primitive, and the telemetry substrate. The telemetry counter columns for wedge-validation and trust-calibration are wired into the schema from day one specifically so no later epic has to migrate the table to add a column — this is called out repeatedly in planning as "the Story 1 blocker." After this epic, a developer can iterate against synthetic stage stubs with the full pipeline skeleton, helper primitives, and enforcement layers (lint/CI) already in place. Signing/distribution and the `PermissionChecker` scaffold are explicitly deferred out of this epic (to Epic 9 and Epic 5 respectively).

## Stories

- Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)
- Story 1.2: Core Primitives — AtomicWriter, IDs, CanonicalTranscript, Dialects, Config (`CanonicalTranscript` and `Config` split to follow-up stories during delivery — see `deferred-work.md`)
- Story 1.3: Log Facade with Sensitivity Tagging and Redaction
- Story 1.4: SQLite Schema, StateStore, and GRDB Migrations (with Full Telemetry Counter Columns)
- Story 1.5: Orchestrator + StageRunner + CrashRecovery + RetentionScheduler Scaffold
- Story 1.6: Telemetry Recorder, StageEventLogger, and StageMetadata
- Story 1.7: CLI Executable Scaffold (`auricle` Binary with Bare-Status + Hidden `__internal-stage`)
- Story 1.8: Lint, Format, and CI Enforcement Layer

## Requirements & Constraints

- Pipeline stages are crash-isolated subprocesses and idempotent — re-running one overwrites artifacts deterministically without corrupting earlier stages.
- App state must survive a crash and reconcile on next launch; vault/cache writes are atomic (temp → fsync → rename), zero partial writes.
- Config persists outside Keychain and applies on next invocation without restart; secrets (Anthropic key, Google OAuth token) live in Keychain only, never in the config file or env vars.
- Structured logs go to the unified logging system under one subsystem with per-stage categories; secrets, transcript content, and API response bodies must never reach the logging layer.
- Per-meeting telemetry (timing, cost, drop counts, AI-suggestion accept/reject counts) is local-only SQLite — no telemetry endpoint exists.
- CLI names/flags/JSON schemas are a binding, versioned contract (breaking changes need a major version bump); the hidden internal worker subcommand is explicitly exempt.
- Required test coverage: atomic-write edge cases, ID resolution, canonical-transcript round-trip, JSON round-trip for every Codable contract type, crash-recovery reconciliation, migration correctness.
- Release builds must be reproducible; CI runs build/test/lint on every PR in a clean environment.

## Technical Decisions

- **Project layout:** hybrid SwiftPM library (25 targets) + Tuist-generated Xcode project (gitignored) with two executables, `AuricleApp` and `auricle-cli`, both depending on the package. Hardened Runtime ON, Sandbox OFF, arm64-only, macOS 14+.
- **Module boundaries are build-time enforced:** `Core` underlies everything; stage and concrete-strategy targets never import each other; `Orchestrator` depends only on interfaces. Only the two composition roots (`AuricleApp.swift`, CLI `main.swift`) plus a test helper may instantiate concrete strategies.
- **State machine:** canonical present-participle state strings (`transcribing`, `summarizing`, …) double as the crash-recovery signal. Every stage writes two transactions via `StageRunner.run`: Txn A (started + active state) before work, Txn B (completed/failed + target state) after. A stuck active state is re-dispatched idempotently on next launch. A periodic stale sweep synthesizes a failure once a stage exceeds its wall-clock budget (~2× its inner retry budget). Four failure categories — transient, permanent, user-actionable, benign-terminal — drive consistent retry/surface behavior.
- **Source-of-truth split:** cache-dir (`~/Library/Caches/com.auricle.app/<id>/`) holds heavy per-stage JSON artifacts (transcript/diarization immutable post-write); SQLite (via GRDB) holds state, the append-only `stage_events` log, retention timers, and telemetry. No other IPC layer is permitted (no XPC/pipes/shared memory).
- **SQLite specifics:** WAL mode from migration #1; `DatabasePool` for the GUI, `DatabaseQueue` for subprocesses. All telemetry counter columns are declared in migration #1 even where sparse in MVP, so no future epic needs a schema migration. A write-authority matrix gives each column exactly one writer, enforced through narrow `StateStore`/`Telemetry` APIs rather than SQL grants.
- **Helper-bypass discipline:** single-implementation primitives must not be reimplemented at call sites — `AtomicWriter` (all file writes), `Log` (all logging), `StateStore` (all state reads), `StageRunner` (stage transactions), `Telemetry.record`/`StageEventLogger.record` (telemetry/event SQL), `MeetingIDResolver` (`<id>` parsing). Enforced by custom SwiftLint rules where mechanical, otherwise code review.
- **Core primitives:** `MeetingID` wraps a 26-char Crockford-base32 ULID; resolver accepts full ID, ≥6-char prefix, `current`, or `last`. `CanonicalTranscript` is the single transcript representation (NFC Unicode, LF, `<Speaker_N>: ` prefixes, UTF-8 byte offsets) and must round-trip byte-identically — load-bearing for Epic 3's quote-grounding validators.
- **JSON dialect:** snake_case for cache-dir artifacts, vault frontmatter, `stage_events.metadata_json`, and notification payloads; camelCase for CLI `--json` output and structured errors. Every Codable contract type needs a round-trip test.
- **Log facade:** wraps `os_log`, subsystem `com.auricle.app`, category per stage/module; every field must be explicitly tagged `.publicSafe` or `.sensitive` (defaulting to public is a reject); `debug` strips in release builds.
- **CLI scaffold:** swift-argument-parser with the 10 MVP verbs stubbed (real behavior lands later); bare `auricle` prints status, not help; `__internal-stage` is a hidden subcommand for GUI→subprocess dispatch, excluded from the versioned contract; exit codes 0/1/2/3; `--json` is opt-in and carries `schemaVersion`.

## Cross-Story Dependencies

Story 1.1 gates the epic. Story 1.2 (Core primitives) is depended on by nearly every later story and every other epic. Story 1.4 (SQLite schema with full telemetry columns) is the hardest blocker — every later epic assumes those columns already exist. Story 1.5 (Orchestrator/StageRunner/CrashRecovery) builds on 1.2–1.4; Story 1.6 (Telemetry) builds on 1.4's schema and 1.5's hook points. Story 1.7 (CLI scaffold) builds on 1.1 and only stubs verbs — real implementations land in Epic 4 and Epic 9. Story 1.8 (lint/CI) codifies rules introduced across 1.2–1.7. No dependency on other epics; every other epic depends on this one.
