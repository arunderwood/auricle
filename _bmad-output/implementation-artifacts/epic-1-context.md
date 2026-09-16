# Epic 1 Context: Foundation — Pipeline State + Atomic-Write Backbone

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 1 bootstraps the auricle repository (hybrid SwiftPM library + Tuist-generated Xcode app project, CI) and builds the pipeline backbone every later stage plugs into: the SQLite state machine, the cache-dir handoff convention, the atomic-write primitive, and the telemetry substrate. Every wedge-validation and trust-calibration telemetry counter column is wired into the schema from day one so no later epic ever needs a migration to add a column — the repeatedly-flagged "Story 1 blocker." After this epic, a developer can iterate against synthetic stage stubs with the full pipeline skeleton, helper primitives, and lint/CI enforcement already in place. Signing/distribution and the `PermissionChecker` scaffold are deliberately deferred (to Epic 9 and Epic 5 respectively — neither has anything to attach to yet).

## Stories

- Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)
- Story 1.2: Core Primitives — AtomicWriter, IDs, CanonicalTranscript, Dialects, Config
- Story 1.3: Log Facade with Sensitivity Tagging and Redaction
- Story 1.4: SQLite Schema, StateStore, and GRDB Migrations (with Full Telemetry Counter Columns)
- Story 1.5: Orchestrator + StageRunner + CrashRecovery + RetentionScheduler Scaffold
- Story 1.6: Telemetry Recorder, StageEventLogger, and StageMetadata
- Story 1.7: CLI Executable Scaffold (`auricle` Binary with Bare-Status + Hidden `__internal-stage`)
- Story 1.8: Lint, Format, and CI Enforcement Layer

## Requirements & Constraints

- Pipeline stages are crash-isolated, idempotent subprocesses; re-running one overwrites its own artifacts deterministically without corrupting earlier stages, and each stage is also independently invocable as its own CLI subcommand with identical output to in-app execution.
- App state must survive a crash and reconcile automatically on next launch; all vault/cache writes are atomic (temp file → fsync → rename), zero partial-write events tolerated.
- Configuration persists outside Keychain and takes effect on the next pipeline invocation without an app restart; secrets (Anthropic API key, Google OAuth token) live in Keychain only — never in the config file, env vars, or logs.
- Structured logs go to the unified logging system under one subsystem with per-stage categories; secrets, transcript content, and raw API response bodies must never reach the logging layer.
- Per-meeting telemetry (timing, cost, drop counts, AI-suggestion accept/reject counts) is local-only SQLite — no telemetry endpoint exists, nothing leaves the device.
- CLI verb names, flags, and JSON schemas are a binding, versioned contract (breaking changes need a major version bump); the hidden internal worker subcommand is explicitly exempt.
- Required test coverage at this layer: atomic-write edge cases, meeting-ID resolution, canonical-transcript round-trip, JSON round-trip for every Codable contract type, crash-recovery reconciliation, migration correctness.
- Targets macOS 14+ on Apple Silicon (arm64) only; release builds must be reproducible; CI runs build/test/lint on every PR in a clean environment.

## Technical Decisions

- **Project layout:** hybrid SwiftPM library (25 targets) + Tuist-generated Xcode project (gitignored build artifact, not a source artifact) with two executables, `AuricleApp` and `auricle-cli`, both depending on the shared package. Hardened Runtime ON, App Sandbox key absent, arm64-only, macOS 14 deployment target.
- **Language mode:** Swift 6.3+, language mode 6, strict concurrency checking on — adopted at this epic's scaffold, before any real implementation code exists, since retrofitting strict concurrency later would be expensive and adopting it now is free.
- **Module boundaries are build-time enforced:** `Core` underlies everything; stage and concrete-strategy targets never import each other; `Orchestrator` depends only on interface targets, never concrete implementations. Only the two composition roots (`AuricleApp.swift`, CLI `main.swift`) plus a test helper may instantiate concrete strategies.
- **State machine:** canonical present-participle state strings (`transcribing`, `summarizing`, …) double as the crash-recovery signal. Every stage writes two transactions via `StageRunner.run`: Txn A (started + active state) before work, Txn B (completed/failed + target state) after; a stuck active state is re-dispatched idempotently on next launch. A periodic stale-sweep synthesizes a failure once a stage exceeds its wall-clock budget (~2× its own retry budget, except a fixed 90s for the AI diarization-review sub-stage, which times out to a benign passthrough instead of a failure). Four failure categories — transient, permanent, user-actionable, benign-terminal — drive consistent retry/surface behavior everywhere.
- **Source-of-truth split:** cache-dir (`~/Library/Caches/com.auricle.app/<id>/`) holds heavy per-stage JSON artifacts, immutable once written; SQLite (via GRDB) holds state, the append-only `stage_events` log, retention timers, and telemetry. No other IPC layer is permitted.
- **SQLite specifics:** WAL mode from migration #1; `DatabasePool` for the GUI, `DatabaseQueue` for subprocesses; 5s busy timeout; checkpoint on app quit and every state transition (subprocesses never checkpoint). All telemetry counter columns are declared in migration #1 even where sparse in MVP. A write-authority matrix gives each column exactly one writer, enforced through narrow `StateStore`/`Telemetry` APIs rather than SQL grants.
- **Helper-bypass discipline:** single-implementation primitives must never be reimplemented at call sites — `AtomicWriter` (file writes), `Log` (logging), `StateStore` (state reads), `StageRunner` (stage transactions), `Telemetry.record`/`StageEventLogger.record` (telemetry/event SQL), `MeetingIDResolver` (`<id>` parsing). Enforced by custom SwiftLint rules where mechanical, otherwise code review.
- **Dependency discipline:** for a well-specified, general-purpose problem, default to a native Apple framework or established package over hand-rolling; a hand-roll needs a documented reason tied to a real constraint — this applies inside `Core` too, where any dependency is an escalation to justify.
- **Core primitives:** `MeetingID` wraps a 26-char Crockford-base32 ULID; resolver accepts a full ID, a ≥6-char prefix, `current`, or `last`. `CanonicalTranscript` is the single transcript representation (NFC Unicode, LF, `<Speaker_N>: ` prefixes, UTF-8 byte offsets) and must round-trip byte-identically — load-bearing for later quote-grounding validation.
- **JSON dialect:** snake_case for cache-dir artifacts, vault frontmatter, and event/notification payloads; camelCase for CLI `--json` output and structured errors. Every Codable contract type needs a round-trip test.
- **Log facade:** wraps `os_log`, one fixed subsystem, category per stage/module; every structured field must be explicitly tagged public-safe or sensitive (defaulting to public-safe is a reject); debug-level logging strips from release builds.
- **CLI scaffold:** swift-argument-parser with the MVP verbs stubbed; bare `auricle` prints status, not help; a hidden internal subcommand handles GUI→subprocess dispatch and sits outside the versioned CLI contract; exit codes 0/1/2/3; `--json` is opt-in and every response carries a schema version.

## Cross-Story Dependencies

Story 1.1 gates the epic. Story 1.2 (core primitives) is depended on by nearly every later story and every other epic. Story 1.4 (SQLite schema with the full telemetry column set) is the hardest blocker — every later epic assumes those columns already exist. Story 1.5 (Orchestrator/StageRunner/CrashRecovery) builds on 1.2–1.4; Story 1.6 (telemetry) builds on 1.4's schema and 1.5's hook points. Story 1.7 (CLI scaffold) builds on 1.1 and only stubs verbs — real implementations land in Epic 4 and Epic 9. Story 1.8 (lint/CI) codifies rules introduced across 1.2–1.7. This epic has no dependency on any other epic; every other epic depends on it.
