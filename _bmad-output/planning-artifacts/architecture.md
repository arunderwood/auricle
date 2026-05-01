---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/brainstorming/brainstorming-session-2026-04-23-1644.md
  - _bmad-output/planning-artifacts/ux-design-specification.md  # Step 9 Principle 8, Step 10 Consolidated Attribution + Round-2 + AI Correction Phased Roadmap, Step 11 Component Strategy — surgical amendments applied 2026-05-01
workflowType: 'architecture'
project_name: 'auricle'
user_name: 'Andrewunderwood'
date: '2026-04-26'
lastStep: 8
status: 'complete'
completedAt: '2026-04-28'
amendments:
  - date: '2026-05-01'
    source: 'ux-design-specification.md'
    summary: 'UX-design-workflow amendments: single-window architecture (Attribution sheet), reviewing_diarization pipeline state, AIReviewerStrategy family (new Decision Group 5), NFR-C1 cost-ceiling tiers, telemetry schema extension for AI-correction category.'
  - date: '2026-05-01'
    source: 'bmad-party-mode review (Sally / Mary / Amelia)'
    summary: 'Second-pass clarifications surfaced by multi-agent review: transcript-pane disclosure collapsed-by-default + label text; AIHintChip + ThisIsMeButton accessibility contracts (NFR-A1/A3/A5); false_positive_count explicitly marked v1.1 forward-instrumentation (gap #11); 30-day cost-widget SQL aggregation specified; divide-by-zero handling for kill criteria (suggestions_count=0 → insufficientSignal, not pass); renderTranscript signature + resolution order + golden-fixture matrix; subprocess→GUI handoff race-free contract (state-advance is canonical signal, file-watch is latency optimizer); cache-dir file-watch vs SQLite WAL distinction (two independent watchers); telemetry UPSERT writer-partitioning rule (subprocess writes count/cost/model; GUI writes applied/rejected; no overlap); NFR-P9 explicit memory budget table for Attribution sheet open-state. PRD-coherence findings deferred to a separate PRD review.'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements (72 total — 50 MVP, 16 v1.1, 6 v2+):**

The PRD organizes capability into 13 areas. Architecturally, they cluster into six pipeline stages plus three cross-cutting surfaces:

- **Pipeline stages (the spine):** Capture (FR1–FR10) → Transcribe (FR17, FR19, FR20) → Diarize (FR18) → Attribute (FR21–FR27) → Summarize (FR28–FR34) → Persist (FR35–FR41) → Notify (FR42–FR44). Each stage is independently invocable as `auricle <stage> <id>` (FR11, FR12) and crash-isolated as a subprocess (NFR-R4). The Mac app dispatches; the CLI is the same code path.
- **State & orchestration (cross-cutting):** Per-meeting state machine (FR13), idempotent re-runs (FR14), pending-list surface (FR15), Dock badge (FR16), structured logging (FR61), crash recovery (FR62, NFR-R6), local SQLite telemetry (FR66).
- **Lifecycle & retention (cross-cutting):** Two-stage audio retention coupled to verification click (FR44–FR50), config persistence (FR58, FR59), permission detection (FR60), graceful Cmd-Q (FR64), Sparkle update [v1.1] (FR65).
- **Enrichment surfaces (off the hot path):** Google Calendar OAuth (FR51–FR54), vault-glossary extraction (FR55–FR57). Both degrade gracefully if unreachable.

**Non-Functional Requirements (65 total):**

The architecture-shaping NFRs:

- **Performance budgets are tight and reference-hardware-pinned.** End-to-end P50 ≤2 min and P95 ≤5 min for a 30-min meeting on M5 Max (NFR-P1); transcribe ≤30s (NFR-P3); summarize P50 ≤60s (NFR-P5); idle CPU ≤1% (NFR-P11); idle GUI memory ≤200 MB (NFR-P9); peak memory ≤4 GB (NFR-P10); cold start ≤1.5s (NFR-P12). These constraints lock WhisperKit-on-ANE for transcription and force model-load isolation into the subprocess. NFR-P9 is the binding ceiling for the Attribution sheet's open-state memory (Decision 5.3 adopts ~98 MB as the working target — shared `AVAudioFile` for paragraph playback + ~5 MB pre-loaded speaker-snippet buffers + view model state — leaving headroom for SwiftUI overhead).
- **Reliability NFRs use "zero events tolerated" framing.** Atomic vault writes (NFR-R1), zero unverified-audio-deletion (NFR-R3), quote-grounding hard gate (NFR-R7). These elevate the vault-write path, the retention-arm path, and the QuoteValidator to load-bearing correctness boundaries.
- **Security/privacy posture is local-first by construction.** Keychain-only secrets (NFR-S1), no plaintext persistence, no telemetry endpoint exists (NFR-S8, NFR-Pr2), audio never sent to any API (NFR-Pr4). Architecturally this means there is no remote-observability plane to design — only structured `os_log` and local SQLite.
- **Maintainability NFRs lock language stack.** Swift / SwiftUI / AppKit only in MVP (NFR-M1); subprocess isolation per stage (NFR-M2); structured logging per stage (NFR-M3); CI-runnable smoke test (NFR-M5); reproducible builds (NFR-M7). Pyannote sidecar in v2+ is the deliberately-scoped exception.
- **Integration NFRs name binding contracts.** Frontmatter schema is versioned and migration-aware (NFR-I4); CLI argument signatures are stable, breaking changes require major bump (NFR-I7); summarization model identifier is configurable (NFR-I6).
- **Accessibility NFRs apply to the attribution UI in particular** — keyboard navigability with Spacebar snippet playback (NFR-A2), VoiceOver labels (NFR-A1), color-not-sole-conveyor for the recording indicator and calendar-attendee priority badge (NFR-A3).
- **Cost ceiling pins the Claude prompt design.** Tiered per Decision 5.6: NFR-C1 default ≤$0.50/30-min meeting at MVP (Opus summarize only; jargon correction inline within the same call); ≤$0.60 ceiling kicks in only when the user opts into diarization review (Haiku review pass + Opus summarize); ≤$0.05 at v1.1 via prompt caching + glossary scoping (NFR-C2). Local-LLM strategy (FR33) drops all of these to $0. The summarization architecture must be cache-friendly; the AI-reviewer category (Decision Group 5) reuses the same `cache_control` discipline.

**Scale & Complexity:**

- Primary domain: **native macOS desktop application with on-device ML inference, local persistence, and thin remote API enrichment**. The "scale" axis (concurrent users, throughput) does not apply — this is single-user, single-machine, sequential per-meeting processing.
- Complexity level: **medium-high technical, low domain**. Drivers: local ML pipeline (WhisperKit + ANE), system-audio loopback (ScreenCaptureKit), diarization-to-attribution UX, atomic vault contracts, two-stage retention coupled to a notification-click event, pipeline crash isolation across subprocess boundaries. Domain has no compliance regime, no multi-tenancy, no team semantics.
- Estimated architectural components (rough — to be refined in step-06):
  - **6 pipeline-stage modules:** `Capture`, `Transcribe`, `Diarize`, `Attribute`, `Summarize`, `Persist`.
  - **3 cross-cutting modules:** `Orchestrator` (state machine + subprocess dispatch), `State` (SQLite layer), `Telemetry` (per-stage timing/counters).
  - **3 enrichment / support modules:** `Calendar` (Google OAuth + event matching), `VaultGlossary` (wikilink-target enumeration), `VaultWriter` (atomic-write primitive shared by Persist).
  - **2 platform-integration modules:** `Notifications` (UNUserNotificationCenter + retention-timer arming), `Permissions` (TCC detection + remediation).
  - **2 product-surface targets:** `AuricleApp` (SwiftUI/AppKit GUI), `auricle-cli` (swift-argument-parser CLI). Both depend on the modules above.

### Technical Constraints & Dependencies

**Locked from the brainstorming session (architecturally non-negotiable):**

- **Platform:** macOS 14+ (Sonoma), Apple Silicon only. M5 Max is reference hardware for performance budgets; M1 is the floor.
- **Language stack:** Swift / SwiftUI / AppKit only in MVP. Swift Package Manager for source dependencies. Xcode project for the bundle. No Python/Node/Electron in MVP.
- **No App Sandbox.** Hardened Runtime is on; sandboxing is off. App Store distribution is excluded for the lifetime of the product (sandbox conflict with ScreenCaptureKit + vault writes).
- **Distribution:** Developer ID code signing + notarization required (Gatekeeper). `.dmg` or `.app` zip via GitHub Releases at MVP; Sparkle EdDSA-signed appcast in v1.1.
- **Single-user, single-machine.** No accounts, no multi-tenancy, no sharing, no compliance regime.
- **English-only.** Locked.
- **No bot-in-meeting.** Capture is OS-level loopback. Locked.
- **No OpenAI as a summarization vendor.** Locked.

**External dependencies (in order of architectural coupling):**

- **WhisperKit** (Swift Package) — transcribe + built-in diarize. Highest coupling — the model load is the dominant memory cost and the latency floor. Whisper-large-v3-turbo on ANE is the locked default.
- **ScreenCaptureKit** (Apple framework) — system-audio loopback. Apple-controlled API surface, has changed shape across recent macOS versions; capture stage is the most likely site of OS-update breakage.
- **AVFoundation / CoreAudio** — microphone capture, audio mixing, snippet playback (`AVPlayerView` or `QLPreviewPanel` for in-UI snippets).
- **Anthropic SDK / HTTPS client** — single Claude Messages API call per meeting. Configurable model identifier (default `claude-sonnet-4-6`). Stage is swappable per FR33.
- **Google Calendar API v3** (REST) — read-only OAuth 2.0 with PKCE; refresh token in Keychain. Off the hot path; degrades to `#auricle/needs-calendar-enrichment` on failure.
- **SQLite** (system library, accessed via `sqlite3` / GRDB / similar) — single local database for state, retention, telemetry. Schema is versioned and migrated forward.
- **swift-argument-parser** — CLI interface (NFR-I7 binding contract).
- **Sparkle [v1.1]** — auto-update, EdDSA-signed appcasts.
- **Obsidian** — consumer of the vault output via `obsidian://open` URL scheme. No plugin required, no Obsidian config assumed beyond a writable vault.
- **Local LLM runtimes [v1.1+]** — Ollama (HTTP) or MLX (in-process Swift). Plug into the `summarize` stage via the strategy interface introduced for FR33.

**Filesystem layout (architectural fixture, not a runtime question):**

- `~/Library/Application Support/com.auricle.app/` — config (TOML or JSON), SQLite database, schema-version markers.
- `~/Library/Caches/com.auricle.app/<meeting-id>/` — per-meeting in-flight artifacts: `audio.wav`, `transcript.json`, `diarization.json`, `snippets/speaker_N.wav`, `summary.json`. 0600 permissions (NFR-S3).
- `~/checkouts/SecondBrain/Meetings/` (configurable, FR35) — output markdown notes with frontmatter contract.
- macOS Keychain — Anthropic API key, Google OAuth refresh token (NFR-S1).

### Cross-Cutting Concerns Identified

These concerns recur across components and need to be settled once at the architecture level so every stage handles them the same way:

1. **Pipeline state machine and SQLite schema.** Single source of truth for "what stage is this meeting in, what's the next action." Used by the GUI's per-meeting list (FR13), the CLI's `auricle pending` (FR15), the retention timer (FR46), the crash-recovery on relaunch (NFR-R6), and the telemetry rollup (FR66). Architecturally: one `MeetingState` table + one `StageEvent` table + retention/telemetry tables; every stage updates state on transition.
2. **Cache-dir handoff contract.** Each stage reads named inputs from `~/Library/Caches/com.auricle.app/<meeting-id>/` and writes named outputs there. The contract is the file naming + JSON schema for transcript/diarization/summary. This is what makes idempotent stage re-runs (FR14, NFR-R5) work.
3. **Atomic-write primitive.** `temp → fsync → rename` (NFR-R1, FR36) is used by every artifact writer (cache-dir JSON files AND vault markdown). One implementation, one test.
4. **Quote-grounding validator.** Single gatekeeper between `summarize` output and `persist` input (FR30, NFR-R7). Drops items that fail literal substring match. Logs drops at info level. Tested with a corpus.
5. **Frontmatter schema and versioning.** Single canonical schema (`auricle.schema_version` field, FR39, FR41, NFR-I4) used by `persist` for write and by `attribute` re-runs (which need to read the existing frontmatter to know which speakers were already named). Breaking changes are major-version events.
6. **Structured logging convention.** `os_log` subsystem `com.auricle.app`, category per stage (NFR-M3, FR61). Used by the GUI for in-app log inspection and by the CLI for stderr surfacing. Log redaction for secrets (NFR-S7) is enforced at this layer.
7. **Notification → URL-scheme → retention-arm wiring.** `UNUserNotificationCenterDelegate` is the single landing point. On click: open Obsidian via `NSWorkspace.shared.open(url:)`, write verification timestamp to SQLite, arm retention timer (FR42→FR43→FR44→FR46). Must survive Mac app restart (notification can fire after a quit/relaunch), so the click handler reads meeting-ID from the notification payload and does not depend on in-memory state.
8. **Permission detection and remediation.** ScreenRecording, Microphone, Notifications (FR60, NFR-S2). Detected on launch and before any capture attempt; the GUI surfaces remediation paths (deep-links into System Settings panes); the CLI surfaces a remediation message at stage entry.
9. **Configurable engine strategy for summarization.** `summarize` stage takes a `SummarizerStrategy` (Claude / Ollama / MLX). Selected from config (FR58); strategy plugs into the same input contract (transcript + glossary → constrained-JSON output) and the same QuoteValidator follows.
10. **Telemetry collection at stage boundaries.** Every stage records start/end timestamps, success/failure, and stage-specific counters (e.g., `quote_validation_drop_count` at summarize; `cost_usd` at summarize-Claude; `time_to_notification_seconds` rolled up at notify). Storage is local SQLite (NFR-S8). Surfaced to the user in the main window.
11. **Vault frontmatter is for vault consumers; SQLite is for auricle's operational state.** Frontmatter holds what a vault consumer needs to interpret the note correctly: **human-readable fields** (title, date, tags, attendees as wikilinks) AND **auricle-managed identity / lineage** (`auricle.meeting_id`, `auricle.schema_version`, and `auricle.supersedes` when applicable). SQLite holds everything that is mutable, forensic, or purely operational (capture timestamps, cache file paths, calendar event IDs, pipeline timings, cost data, retention timer state, model identifiers, telemetry counters). The two stores are linked by `auricle.meeting_id` — one stable identifier the user passes to `auricle status <id>` (or any other CLI verb) to surface operational detail. **Frontmatter never duplicates SQLite content.** This principle prevents drift: future proposals like "expose retention status in frontmatter so it shows up in Obsidian Bases" collide with the principle and the right answer becomes a CLI verb / report rather than a frontmatter field. The identity/lineage carve-out (`supersedes`) is recognized as load-bearing for vault consumers and earns its place; new identity/lineage fields require explicit justification before being added. (Driven from step-04 Group 2 elicitation and refined by Round 1 of the Group 2 architecture roundtable.)

### Architectural Questions to Resolve

These four questions are not answered by the PRD but materially shape downstream decisions. They will be resolved in step-04 (architectural decisions) and step-06 (component structure) rather than carried forward as implicit assumptions.

1. **Subprocess vs in-process boundary per stage.** FR12 binds every stage to be *invocable* as `auricle <stage>`, but the PRD does not specify whether the GUI must *dispatch* every stage via subprocess. In practice the boundary is likely: `transcribe`+`diarize` and `summarize` are subprocess-isolated (heavy memory, isolation against external-call hangs); `capture`, `attribute`, `persist`, and `notify` are in-GUI-process (interactive, latency-sensitive, small). The CLI exposes every stage as a subprocess regardless — that's a separate guarantee. Naming this explicitly avoids both over-engineering of subprocess plumbing for stages that don't need it and under-engineering of isolation for stages where the GUI process would otherwise blow past memory budgets.

2. **`DiarizerStrategy` abstraction.** The summarization stage has a swappable backend baked in (FR33: Claude / Ollama / MLX). Diarization does not — WhisperKit-built-in is hard-coded. The PRD's own Open Resolutions appendix flags WhisperKit diarization quality as "verify before implementing" with pyannote 3.1 as the documented v2+ fallback. If diarization swaps later, retrofitting the strategy slot AND adding Python-sidecar runtime support to a Swift-only build (NFR-M1) is a double refactor. Stubbing `DiarizerStrategy` now (with `WhisperKitDiarizer` as the only impl) is cheap insurance against a risk the PRD already names.

3. **Re-publish semantics.** Journey 5 references `auricle run <id> --reattribute` as "a hypothetical CLI verb worth designing." It interacts directly with two binding rules: never edit existing vault files (DP4, FR36, NFR-R2) and stable, deterministic filenames (FR40). Re-published notes therefore can't overwrite the original (the user may have manually edited it) and can't reuse the same filename. Candidate behaviors: write a sibling file with a re-run-date suffix and frontmatter `auricle.supersedes: <original-filename>`, or refuse to re-publish without explicit user confirmation. This is a small architectural decision but load-bearing for any re-attribute path; resolving it now prevents inconsistent later behavior.

4. **`CalendarSource` interface.** Calendar integration is hard-coded to Google Calendar (FR51). EventKit/Calendar.app is named in the PRD as a possible future addition. Stubbing a `CalendarSource` interface now (with `GoogleCalendarSource` as the only impl) makes future EventKit support a strategy plug-in rather than a rewrite. Cost is one protocol declaration.

### Known One-Way Doors / Accepted Limits

Constraints the PRD locks deliberately, where the architecture should *acknowledge* the cost of reversal rather than design around it. Naming them explicitly so future-self knows the cost rather than discovering it under deadline pressure.

- **Post-hoc-only pipeline forecloses streaming features.** ScreenCaptureKit and WhisperKit both support streaming inference; the brainstorm chose post-hoc. Re-introducing streaming (live transcript display, "alert when my name is mentioned", real-time captioning) is a re-architecture of the pipeline shape — capture becomes a producer, transcribe consumes a stream not a file, the cache-dir filesystem-handoff between stages goes away. Not a refactor risk *given current scope*; a known one-way door if streaming features are ever requested.
- **Notification-click as the sole verification trigger needs an explicit fallback.** NFR-R8 implies a manual verification path in the GUI when Notifications permission is revoked, but no FR formalizes it. If the user opens the note directly from Obsidian (skipping the notification click), the meeting sits in `awaiting verification` and audio is held silently. Architecture should formalize a manual `Verify` affordance (GUI + `auricle keep <id>` CLI verb) so that NFR-Pr6 (conservative retention defaults) does not drift into "audio kept indefinitely by accident."
- **Single Claude call per meeting (FR32) is fine; the JSON schema design must not accidentally foreclose multi-pass.** Chain-of-summarize is explicitly v2+ (FR71). The discipline is to shape the constrained-JSON output schema as *renderer-input* (the persist stage reads it) rather than *call-shape* (one schema = one Claude call), so a future multi-pass implementation populates the same schema across multiple calls without redesigning the renderer. Costs nothing to do right the first time; expensive to retrofit.

### Code-Design Discipline (SOLID)

The codebase will follow SOLID principles, applied with project scope in mind (single-user tool, one engineer, intermittent attention — premature abstraction is its own cost). SOLID is not invoked generically; each principle maps to a specific architectural commitment.

- **SRP — Single Responsibility.** The decoupled-stage architecture (DP1, FR12) already aligns: each stage module has exactly one reason to change. Reinforcement: keep stage modules independent (Capture must not import Transcribe; Transcribe must not import Diarize even though they share model state internally — that sharing lives inside the transcribe-stage subprocess). Also: split Persist into `FrontmatterRenderer` (data → markdown), `VaultWriter` (markdown → atomic-write to disk), and `FilenameResolver` (meeting → filename) so each is independently testable.

- **OCP — Open/Closed.** Engines and sources are open to extension via strategy interfaces, closed to modification. The PRD already names this for summarization (`SummarizerStrategy`: Claude / Ollama / MLX per FR33). Extending the same discipline: `DiarizerStrategy` (against the WhisperKit-quality risk flagged in the PRD's Open Resolutions), `TranscriberStrategy` (against the Parakeet-TDT and Apple SpeechAnalyzer fallback paths in the same Open Resolutions), and `CalendarSource` (against future EventKit support). Adding a new engine or source must not require modifying the orchestrator.

- **LSP — Liskov Substitution.** Substitutability is *behavioral*, not just typed. Every `SummarizerStrategy` impl must produce the same constrained-JSON shape and pass through the same `QuoteValidator` gate. Every `CalendarSource` impl must degrade the same way on failure (`#auricle/needs-calendar-enrichment` per FR54). Every `DiarizerStrategy` impl must produce a compatible diarization artifact JSON. Strategy contracts include not just type signatures but failure modes, retry semantics, and artifact-shape guarantees.

- **ISP — Interface Segregation.** Protocols stay narrow and input-focused. `SummarizerStrategy` exposes `summarize(transcript:glossary:) -> SummaryJSON` — not `summarize(meeting:)` (which would tightly couple to `Meeting`'s shape and let the strategy peek at unrelated fields). `VaultWriter` does not expose schema-version logic (that's `FrontmatterRenderer`'s concern). Each protocol's surface area is the minimum required for its caller, which keeps test stubs small.

- **DIP — Dependency Inversion.** The `Orchestrator` depends on protocol abstractions (`SummarizerStrategy`, `DiarizerStrategy`, `TranscriberStrategy`, `CalendarSource`, `VaultWriter`, `Notifier`, `StateStore`), never on concrete types. Concrete implementations are wired at exactly one composition root per binary: `AuricleApp.main()` for the GUI, `auricle-cli/main.swift` for the CLI. Tests instantiate the orchestrator with stub implementations — which is what makes the CI-runnable end-to-end smoke test (NFR-M5) cheap to maintain rather than a chronically-flaky integration test.

**SOLID is not applied where it isn't earning its way.** A single-user tool with one engineer cannot afford genericity for hypothetical futures. Concretely: do not wrap `URLSession`, `Keychain`, or `os_log` in protocols unless there are actually two implementations or a real testing need. Do not introduce a `LoggerStrategy`, a `KeychainStore` protocol, or a `ConfigSource` protocol "just in case." The PRD has explicitly named the swap points (summarizer, calendar, possibly diarizer, possibly transcriber); apply SOLID at those boundaries and at the orchestrator's testing-contract boundary (anything network- or filesystem-dependent), and do not extend it speculatively elsewhere. **YAGNI is the guard rail; SOLID is the discipline applied at named boundaries.**

## Starter Template Evaluation

### Primary Technology Domain

Native macOS desktop application (Swift / SwiftUI / AppKit) with a co-bundled CLI binary, on-device ML pipeline, local SQLite state, and atomic-write filesystem persistence. The standard "starter template" framing (Next.js, T3, oclif, Tauri, Electron) does not apply — the PRD locks first-party Apple frameworks (NFR-M1) and excludes every cross-platform runtime.

### Starter Options Considered

The PRD pre-makes every decision a starter would otherwise make: language (Swift, NFR-M1), UI framework (SwiftUI/AppKit), build system (Xcode + SwiftPM), CLI framework (swift-argument-parser, NFR-I7), distribution (Developer ID signed `.app` via GitHub Releases), update framework (Sparkle v1.1), ML runtime (WhisperKit), state store (SQLite), HTTP client (URLSession), serialization (Codable). There is no community starter that adds value over an Xcode-generated macOS App + SwiftPM dependencies.

The one substantive open question is **project structure**: pure Xcode project, pure SwiftPM `Package.swift`, or hybrid.

- **Pure Xcode project:** friction-free signing/notarization, weaker target-boundary enforcement (modules are Xcode targets created via GUI wizards), project file is XML (binary-ish for diffing).
- **Pure SwiftPM:** all configuration in version-controlled Swift, strong target-boundary enforcement (a target literally cannot import another target unless declared in the manifest — a SOLID enforcement mechanism at build-system level), but rougher ergonomics for `.app` bundle output (Info.plist, asset catalogs, entitlements, signing).
- **Hybrid (selected):** SwiftPM `Package.swift` for all library targets (stage modules, strategy protocols, orchestrator, tests); thin Xcode project for the two executable targets (`AuricleApp` GUI, `auricle-cli`) which depend on the SwiftPM library.

### Selected Approach: Hybrid SwiftPM Library + Xcode App Project

**Rationale for Selection:**

- **SwiftPM target boundaries enforce SRP at the build-system level.** Each stage module is a separate SwiftPM library target whose dependencies are explicit in `Package.swift`. `Capture` can be declared with no dependency on `Transcribe`; the build system rejects any accidental import. This is the strongest mechanical enforcement of the SOLID discipline locked above.
- **Strategy protocols live in protocol-only targets.** `SummarizerInterface`, `DiarizerInterface`, `TranscriberInterface`, `CalendarInterface` are tiny SwiftPM library targets containing only the protocol declarations. Concrete implementations (`ClaudeSummarizer`, `WhisperKitDiarizer`, `GoogleCalendarSource`, etc.) are separate targets that depend on the interface target. The orchestrator depends on the interface targets, not the implementation targets — DIP enforced by manifest, not by convention.
- **Xcode project remains the build-and-ship surface.** Code signing, notarization (`xcrun notarytool`), hardened runtime, entitlements, Info.plist, asset catalogs, and the `.app`/`.dmg` artifact pipeline all stay in Xcode where the tooling is mature and matches Apple's documented release flow.
- **Both executables share the same library code.** `AuricleApp` (SwiftUI GUI) and `auricle-cli` (swift-argument-parser CLI) are two Xcode targets, both depending on the same SwiftPM library. There is no language boundary, no IPC protocol, no parallel implementation — exactly what the PRD calls for in §Project Type.
- **CI-runnable smoke test (NFR-M5) is straightforward.** `swift test` from the repo root runs all library-target tests without needing Xcode. The Xcode project's executable targets are tested via `xcodebuild` in a separate CI step.
- **First-timer-friendly: most module work happens in SwiftPM library targets, edited as plain Swift files in any editor or in Xcode.** Only the executable shell, signing, and bundling require Xcode-GUI work — that's a one-time setup, not a recurring per-module cost.

**Initialization (first implementation story):**

```bash
mkdir auricle && cd auricle
swift package init --type library --name AuricleKit
# Edit Package.swift to declare modular library targets:
#   - protocol-only targets: SummarizerInterface, DiarizerInterface,
#     TranscriberInterface, CalendarInterface
#   - cross-cutting targets: Core, State, Telemetry, AtomicWrite, QuoteValidator
#   - stage targets: Capture, Transcribe, Diarize, Attribute, Summarize, Persist,
#     Notifications, Permissions, VaultGlossary
#   - integration targets: ClaudeSummarizer, WhisperKitTranscriber, WhisperKitDiarizer,
#     GoogleCalendarSource
#   - test targets per library
# External SwiftPM dependencies declared in Package.swift:
#   - WhisperKit (transcribe + diarize)
#   - GRDB.swift (SQLite, type-safe migrations)
#   - swift-argument-parser (CLI)
#   - Sparkle [v1.1, deferred]
# Then in Xcode:
#   File > New > Project > macOS > App > "Auricle" (SwiftUI, Swift)
#   Add the SwiftPM root as a local package dependency
#   Add a second target: Command Line Tool > "auricle-cli"
#   Configure: Hardened Runtime ON, Sandbox OFF, code signing identity,
#              Info.plist (LSUIElement=NO, microphone & screen-recording usage descriptions),
#              entitlements (com.apple.security.device.audio-input, notifications)
```

**Architectural Decisions Provided by This Approach:**

**Language & Runtime:** Swift 5.10+ targeting macOS 14+; no other runtimes.

**Module Boundaries:** Enforced by SwiftPM `Package.swift` — a target's allowed imports are declared in the manifest, not in code conventions. Mechanical SOLID enforcement.

**Composition Root:** Two well-defined entry points — `AuricleApp.main()` (GUI) and `auricle-cli/main.swift` (CLI). Each wires concrete strategy implementations to the orchestrator. Tests use a third entry point with stubs.

**Build Tooling:** Xcode for `.app` bundle output, signing, notarization. SwiftPM (`swift build`, `swift test`) for library development and CI.

**SQLite Layer:** GRDB.swift. Provides type-safe queries, native migration support, and modern Swift API. Depended on by the `State` target only; no other module touches SQLite directly.

**Testing Framework:** Swift Testing (Swift 5.10+ first-party `@Test` macro framework) for new test code; XCTest only where Swift Testing doesn't yet cover (e.g., performance tests). Per-library-target test targets.

**Code Organization:** One library target per concern. The directory layout *is* the architecture diagram.

**Development Experience:** `swift test` from the command line for fast library iteration; Xcode for app-shell development, debugging, and shipping.

**Build Order Implication:** This structure aligns with the brainstorm's risk-front-loaded build sequence. The pipeline-plumbing libraries (`Transcribe`, `Summarize`, `Persist`, `QuoteValidator`) and the CLI executable can be built and dogfooded against pre-existing audio recordings *before* the SwiftUI app shell or any ScreenCaptureKit code exists. SwiftUI work begins only when the underlying pipeline is validated.

**Note:** Project initialization using this approach should be the first implementation story. Subsequent stories build out one library target at a time, in the brainstorm's risk-front-loaded order: pipeline plumbing first, then capture, then attribution UI, then app shell + notifications + calendar + vault-glossary.

## Distribution Model

This decision was elevated out of step-04 Group 4 (security & operations) for early resolution because it directly amends the PRD's NFR-C4 cost ceiling and NFR-S2 signing posture. The PRD has been updated in lockstep.

### Decision: Self-managed Code Signing CA + per-Mac `spctl` Trust Policy

auricle is signed with a self-managed code-signing certificate (personal CA + per-tool leaf cert) and trusted on each user Mac via a one-time `spctl` assessment-policy registration. **Apple Developer Program ($99/year) is not used** for the project's documented use case (single user, multiple personally-owned Macs).

### Rationale

- The PRD's locked constraints — single-user, "multiple personally-owned Macs," no public distribution — make Apple's notarization unnecessary. Notarization solves "convince other people's Macs that this software is safe"; auricle's only audience is the user himself.
- Apple-supported mechanism: `sudo spctl --add --type execute --requirement 'anchor H"<ca-hash>"'` registers a custom Gatekeeper assessment policy that accepts any binary signed by certificates chained to the named CA. This is the documented path for organizational / internal code-signing use cases and is not a workaround.
- TCC permission stability (NFR-S3 spirit, FR60) requires a stable signing identity. A self-managed CA + leaf cert combined with stable bundle identifier (`com.auricle.app`) provides exactly this — TCC permissions for Screen Recording, Microphone, and Notifications persist across rebuilds and Sparkle updates without re-grant.
- Sparkle update mechanism (FR65) is unaffected. Sparkle's appcast EdDSA signature validation (NFR-S9) is independent of Apple code signing. Downloaded `.app` updates are accepted by Gatekeeper via the per-Mac `spctl` trust rule established once at first install on each Mac.
- Build pipeline simplification: no notarization step (`xcrun notarytool submit`), no notarization wait time (typically 5–15 minutes), no notarization-API-throttle risk on rapid iteration. Release script is `xcodebuild` + `codesign` + (v1.1) Sparkle appcast generation.

### Implementation

**One-time artifacts (created once, on the originating Mac):**

- Personal "Andrew Code Signing CA" certificate — root, self-signed, marked CA-capable (Basic Constraints: `CA: TRUE`). Generated via Keychain Access > Certificate Assistant > Create a Certificate (Identity Type: Self-Signed Root, Certificate Type: Code Signing) or via `openssl`.
- "Auricle Code Signing" leaf certificate — signed by the CA, used as the per-build signing identity in Xcode.
- The CA `.cer` file (public certificate, no private key) is checked into the auricle repo at `assets/AndrewCodeSigningCA.cer` so it travels with the source. The private keys for both CA and leaf live only in the originating Mac's login Keychain and are never exported (only that Mac can sign new builds; other Macs only verify signatures).

**Per-Mac trust setup — `scripts/setup-trust.sh` (idempotent):**

```bash
#!/usr/bin/env bash
set -euo pipefail
CA_CERT="${1:-./assets/AndrewCodeSigningCA.cer}"

# 1. Import CA cert as a trusted root in System.keychain
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain "$CA_CERT"

# 2. Compute SHA-256 fingerprint of the CA cert
CA_HASH=$(openssl x509 -in "$CA_CERT" -inform DER -noout -fingerprint -sha256 \
  | sed 's/.*=//' | tr -d ':')

# 3. Register Gatekeeper assessment policy: trust anything chained to this CA
sudo spctl --add --type execute --label 'AndrewCA' \
  --requirement "anchor H\"$CA_HASH\""

# 4. Verify
echo "Trust setup complete. Verify with:"
echo "  spctl --assess --verbose /Applications/Auricle.app"
```

**Per-build signing (in Xcode):**

- Project's Signing & Capabilities pane: Signing Identity = "Auricle Code Signing" (the leaf cert).
- Hardened Runtime: enabled.
- Sandbox: disabled (per PRD §Implementation Considerations).
- No notarization step in the release script.
- Release artifact: `.app` bundle (or `.dmg` for distribution), signed and ready for Sparkle distribution or manual `/Applications` install on any Mac that has run the trust-setup script.

**`auricle doctor` integration (per Group 1.5 CLI surface):**

The `auricle doctor` CLI verb includes a "Gatekeeper trust check" that runs `spctl --assess --verbose <bundle-path>` and inspects the result:

- If `accepted` → reports OK
- If `rejected` → prints the exact remediation: the path to `scripts/setup-trust.sh` and the underlying `spctl --add` command. Self-service trust recovery without the user needing to remember the procedure.

### Trade-offs Accepted

- **Not shareable with other people without per-recipient trust setup.** The personal CA cert is not in any public trust chain. Sharing auricle with someone else would require either (a) that person trusting the CA on their Mac (security regression for them — they'd implicitly trust any other binary signed with this CA), or (b) re-signing with Apple Developer ID + notarization for that distribution. Acceptable per PRD's single-user constraint.
- **No App Store distribution.** Already excluded by PRD §Project Type (sandbox conflict with ScreenCaptureKit + vault writes outside `~/Library/Containers/`).
- **No automatic notarization malware-scanning.** The user is the developer and the user — the trust relationship is self-attested. Not a meaningful loss for a personally-built tool the user maintains.
- **Per-Mac one-time trust setup.** ~5 minutes friction when adding auricle to a new Mac; eliminated for all subsequent updates (Sparkle handles them seamlessly) and for any future personal tools also signed by leaf certs chained to the same CA.
- **Private key custody.** The CA and leaf private keys live in one Mac's Keychain. If that Mac dies, new builds become impossible until a new CA is generated and re-trusted on every Mac. Mitigation: export the CA private key encrypted to a password manager (e.g., 1Password Secrets, Keychain export with a strong passphrase) as a one-time backup.

### Documented Alternative — Apple Developer ID + Notarization

If auricle is ever distributed to other people (open-source release with general install instructions, gift to a friend, contractor work), the migration path is purely additive:

1. Enroll in Apple Developer Program ($99/year)
2. Generate a Developer ID Application certificate
3. Re-sign release builds with the Developer ID cert (Xcode signing identity change; bundle identifier stays `com.auricle.app`)
4. Add notarization step to the release script: `xcrun notarytool submit ./Auricle.dmg --keychain-profile <profile> --wait`
5. Staple the notarization ticket: `xcrun stapler staple ./Auricle.dmg`
6. Drop the per-Mac `scripts/setup-trust.sh` requirement for new users (no longer needed for Developer-ID-signed builds)

Existing users on personally-owned Macs who already trust the self-managed CA are unaffected: the new builds, signed with Developer ID, are accepted by Gatekeeper natively (Apple's trust chain) and the old `spctl` policy for the personal CA remains harmlessly registered.

**No architecture decisions need to change for this migration.** The signing identity changes, but the bundle identifier, TCC permissions, Sparkle mechanism, build structure, and module boundaries all carry over unchanged. This makes the self-managed-CA approach a low-risk default — the migration cost to Developer ID is bounded and well-understood.

## Core Architectural Decisions

These decisions are organized into four thematic groups. Each group resolves a coherent cluster of cross-cutting choices that downstream stories must conform to.

### Decision Priority Analysis

**Critical (block MVP implementation):**
- Subprocess vs in-process boundary per stage (Group 1)
- Pipeline state machine canonical states (Group 1) — including `reviewing_diarization` per Group 5
- Cache-dir handoff layout + JSON contract names (Group 1) — including `diarization_suggestions.json` per Group 5
- Audio file format (Group 1)
- CLI argument surface (Group 1)
- SQLite schema for state, retention, telemetry (Group 2) — telemetry columns include AI-reviewer category per Group 5
- Frontmatter schema for the vault note (Group 2)
- Re-publish semantics (Group 2)
- Filename convention rules (Group 2)
- Claude API output schema and grounding mechanism (Group 3 — depends on Citations spike outcome)
- Error / failure-state taxonomy (Group 4)
- AI-reviewer strategy family + `attribution.json` schema extension (`segment_overrides` + `segment_splits`) (Group 5)

**Important (shape architecture, drafted iteratively):**
- Claude system prompt structure and glossary injection format (Group 3)
- Retry / backoff policies per stage (Group 4) — including 90s wall-clock budget for `reviewing_diarization` per Group 5
- Notification → retention-arm wiring + manual `verify` fallback (Group 4)
- Telemetry collection points and event schema (Group 4)
- Permission detection and remediation flow (Group 4)
- Pre-committed kill criteria + trust-calibration surfaces for AI category (Group 5)

**Deferred (post-MVP):**
- Sparkle update flow concrete config (v1.1)
- Local-LLM `SummarizerStrategy` impl details (v1.1+)
- `ClaudeTranscriptionReviewer` impl (Phase 3, v1.x — interface declared per Decision 5.5)
- Phase 4 unified reviewer (single Claude call producing all three correction types) (v1.x+)
- Pyannote sidecar `DiarizerStrategy` impl details (v2+)
- Cross-meeting voice-print embeddings + persistence (v2+)

### Group 1: Pipeline Orchestration

#### Decision 1.1: Subprocess vs in-process boundary

Per-stage execution model:

- **Subprocess (spawned by GUI; also independently invocable by CLI):** `transcribe`+`diarize` (combined; share WhisperKit model state in one subprocess), `summarize`. Rationale: WhisperKit ~4GB peak (NFR-P10) must die when work completes; Claude network call may hang and must not freeze the GUI; both satisfy NFR-R4 crash isolation cleanly.
- **In-GUI process:** `capture` (long-running ScreenCaptureKit handle, SwiftUI-controlled), `attribute` (SwiftUI window with audio playback), `persist` (small, latency-sensitive), `notify` (UNUserNotificationCenter delegate must live in app process), `verify`, `discard`.
- **CLI exposes every stage as an independently-runnable subprocess** regardless of how the GUI dispatches it (FR12 binding contract). The CLI binary is the same Swift code path; any stage can be re-run from the terminal for failure recovery, debugging, or scripted use.

This boundary keeps memory budgets enforceable (heavy stages die when done), keeps interactive surfaces responsive (UI state stays in one process), and keeps the CLI surface fully general (no stage is GUI-only at the binary level).

#### Decision 1.2: Pipeline state machine

Canonical state names persisted as strings in SQLite (grep-friendly, version-stable across schema migrations). Active "in-progress" states use the present-participle form (`transcribing`, `summarizing`); these states are also the canonical reconciliation signal for crash recovery (see two-transaction pattern below).

**Linear happy path:**
```
recording → captured → transcribing → reviewing_diarization → awaiting_attribution
  → attributing → summarizing → published → awaiting_verification
  → verified → retention_expired
```

(`transcribing` covers the combined transcribe+diarize subprocess from Decision 1.1 — they share a WhisperKit model load and run in one subprocess; one state name reflects one subprocess.)

**`reviewing_diarization` (UX spec Step 10 lock-in, MVP, flag-controlled):** an AI sub-stage that runs the `DiarizationReviewerStrategy` (Decision Group 5) over `transcript.json` + `diarization.json` and writes `diarization_suggestions.json` to the cache-dir. Spawned as its own short-lived subprocess (per Decision 5.3) immediately after the WhisperKit subprocess terminates — sequencing is "WhisperKit subprocess exits → memory freed → AI reviewer subprocess starts → AI reviewer subprocess exits → state advances to `awaiting_attribution`." When `diarization_review.enabled = false` (MVP default per Path C), the state is still entered but passes through in <100ms (no Claude call; an empty stub `diarization_suggestions.json` is written). Failure is non-blocking: a malformed Claude response or network unreachability transitions through the state with an empty suggestions file and a `stage_events.failed` row tagged `category: 'benign_terminal'`-equivalent at the stage level (the meeting still advances to `awaiting_attribution`; the Attribution sheet renders without AI hints). The wall-clock stale budget is 90s (Decision 4.2 lock-in).

**Terminal / error branches:**
- `silent` — VAD halted, v1.1 only (FR9 / FR10). **Benign-terminal** category per Decision 4.1.
- `discarded` — user-initiated via main window or `auricle discard`
- `capture_failed` — ScreenCaptureKit error (including `permission_revoked_midstream` reason). **Permanent.**
- `transcription_failed` — WhisperKit error after subprocess-restart retry. **Permanent** (unless audio file is suspect — `--force` available for retry).
- `summarization_failed` — Claude unreachable beyond NFR-R9 timeout. **Transient** — queues for resume; `auricle run <id>` is the resume verb.
- `persist_failed` — vault write error after 1 retry. **Transient** — `auricle run <id>` resumes.
- `published_partial` — published with `Speaker_N` placeholders (`--publish-anyway`) AND summarize had no usable output. **User-actionable**: user fixes attribution + summary in Obsidian, or runs `auricle run <id> --reattribute` later. Carries `auricle/needs-attribution` and `auricle/needs-summary` tags in frontmatter.

**Source-of-truth model:** the cache-dir AND SQLite together are the canonical source of truth, with strict division of labor.

- **Cache-dir** (`~/Library/Caches/com.auricle.app/<meeting-id>/`) holds the heavy artifacts each stage produces (`transcript.json`, `diarization.json`, `summary.json`, etc., per Decision 1.3). These are the canonical stage outputs; atomic via temp-write + fsync + rename.
- **SQLite** holds the state machine, the audit log (`stage_events`), the retention timer queue, and the per-meeting telemetry. State transitions are owned conceptually by the `Orchestrator` module but **executed by whichever process just finished a stage**. (See Group 2 Decision 2.1 for the write-authority matrix.)

**Two-transaction pattern per stage:**

Each stage execution writes SQLite in two small transactions:

1. **Txn A (start):** `INSERT INTO stage_events(stage=X, event='started', occurred_at=now)` AND `UPDATE meetings SET state='<active state>'` (e.g. `transcribing`, `summarizing`). Single transaction.
2. **Txn B (end):** `INSERT INTO stage_events(stage=X, event='completed' | 'failed', occurred_at=now, duration_ms, error_message)` AND `UPDATE meetings SET state='<target state>'`. Single transaction.

If a subprocess crashes between Txn A and Txn B, the database state is unambiguous: `meetings.state` is stuck in an active "_ing" form, and the most recent `stage_events` row for that meeting has `event='started'` with no matching `completed` or `failed`. The active state itself IS the reconciliation signal — no separate sweep table is needed.

**Crash recovery (NFR-R6, FR62):** on launch (GUI or CLI), the Orchestrator runs `SELECT id FROM meetings WHERE state IN ('transcribing','reviewing_diarization','attributing','summarizing','published')` (the active states) and re-dispatches the corresponding stage. NFR-R5 idempotency means the second run overwrites the cache artifact and Txn B commits cleanly. Orphan `started` rows in `stage_events` from the crashed run are intentionally retained as forensic audit trail (consistent with the append-only nature of the events log).

**`auricle pending` (FR15) gets live visibility for free:** a single `SELECT * FROM meetings WHERE state NOT IN ('verified','discarded','retention_expired',<all *_failed states>)` returns every in-flight meeting including those currently being processed.

**No in-memory shadow state.** Every state read is from SQLite. The GUI uses GRDB `DatabasePool` for concurrent reads + own-stage writes; subprocesses use GRDB `DatabaseQueue` for their own narrow writes. WAL mode handles concurrent multi-process access cleanly given the sequential-per-meeting workload (see Group 2 Decision 2.1 for the GRDB / WAL / file-watch specifics).

#### Decision 1.3: Cache-dir handoff layout

Per-meeting directory at `~/Library/Caches/com.auricle.app/<meeting-id>/`:

| File | Owner | Purpose |
|---|---|---|
| `audio.wav` | `capture` | Captured audio (see Decision 1.4) |
| `transcript.json` | `transcribe` | WhisperKit transcript output (versioned schema). **Immutable** post-write — AI corrections never modify this file (Decision 5.3 cache-immutability invariant). |
| `diarization.json` | `diarize` | Speaker segments with timestamps + per-segment confidence (versioned schema). **Immutable** post-write — AI corrections never modify this file (Decision 5.3). |
| `snippets/speaker_N.wav` | `diarize` (or `attribute --emit-snippets`) | Per-speaker representative clips, 5–10s each, for attribution UI |
| `diarization_suggestions.json` | `reviewing_diarization` (`DiarizationReviewerStrategy`, Decision Group 5) | AI-proposed speaker corrections (per-segment splits + over/under-segmentation hints). Empty stub when `diarization_review.enabled = false`. Schema is consumed by the Attribution sheet (UX spec Step 10). |
| `transcription_suggestions.json` | (declared schema, no MVP impl — Decision 5.5 Phase 3) | AI-proposed word/phrase transcription corrections. Slot reserved for v1.x; not written in MVP. |
| `attribution.json` | `attribute` | User's speaker→name mapping after attribution stage; carries `segment_overrides` (manual reassignment) and `segment_splits` (AI-applied splits) per Decision 5.4. |
| `calendar.json` | `summarize` (preceded by calendar enrichment) | Calendar event metadata when enrichment succeeded |
| `glossary.json` | `summarize` (preceded by vault-glossary build) | Vault-glossary terms injected into the prompt (for debugging) |
| `summary.json` | `summarize` | Constrained output from Claude, post-validation (groundings retained per Group 3) |
| `state.json` | `Orchestrator` | Mirror of SQLite state for terminal debugging only — not authoritative |

Every JSON file carries a top-level `"schema_version": <integer>` field. All writes go through the atomic-write primitive (`temp → fsync → rename`). Re-runs overwrite atomically (previous file replaced via temp+rename; no partial state ever visible). Permissions: 0600 per NFR-S3.

The cache-dir is the IPC mechanism between subprocess stages — there is no shared memory, no message queue, no other coordination layer beyond SQLite for state and the cache-dir for artifacts.

#### Decision 1.4: Audio file format

**PCM 16-bit, 16kHz mono WAV.**

Rationale:
- Whisper-native format (no resampling at transcribe time — model expects 16kHz mono)
- Universal reader (no codec dependency for snippet playback or external tooling)
- Trivial byte-slice for snippet extraction (`AVAudioFile` can read arbitrary frame ranges directly)
- ~115 MB per 60-min meeting (acceptable for cache; deletes after retention per NFR-Pr6)

Alternatives rejected:
- 24-bit / 48 kHz — no quality benefit for ASR; 3× the disk; resampling required before Whisper
- AAC / m4a — codec dependency adds complexity to snippet playback; non-byte-sliceable for snippets
- CAF — codec dependency; less universal than WAV; no meaningful advantage

Mic + system audio are mixed during capture (single ScreenCaptureKit + AVAudioEngine pipeline) into one mono stream. No multi-channel separation in MVP — the brainstorm chose mixing for simplicity, and diarization quality is handled by the `DiarizerStrategy` slot, not by per-channel separation.

#### Decision 1.5: CLI argument surface (binding contract per NFR-I7)

The CLI is both a developer tool AND a user-facing failure-recovery surface. Per NFR-I7, every verb name and flag in this surface is a binding product contract; renaming or removing post-1.0 is a major version bump (additions are not). This decision was refined through two rounds of multi-agent roundtable review (architect / developer / tech-writer in Round 1; analyst / UX-designer / PM as contrarians in Round 3). Substantive findings folded in:

- The MVP binding surface was deliberately tightened from ~17 verbs to **10 verbs**. Verbs that don't have a clear MVP user job were either deferred to v1.1 (`pending`, `retain`, `attribute --emit-snippets/--speakers`, `doctor --fix`, `logs`, `--generate-completion-script`) or cut entirely (`transcribe`/`summarize`/`persist` standalone — reachable via `run --only <stage>`; `export` — the vault note IS the export; `config show` — same as `config get` with no key; `notify` — pipeline side-effect, not a user verb; `diarize` — combined into `transcribe` in MVP).
- `process` → `run` with `--from / --to / --only <stage>` for orthogonal stage control that survives v2+ stage additions.
- `attribute` defaults to **interactive** (the failure-recovery scenario most needs the GUI; scripts pass `--batch`).
- `mark-verified` → **`keep`** (warmer name; the soft "I confirm this meeting" companion to `retain`'s harder "explicitly override retention").
- `auricle` with no args returns **status, not help** (answers the question the user came with).
- Error format is **hybrid**: one human sentence as default human stderr; structured 4-line block in `--json` and persistent log entries.
- Device boundary is **not exposed in the CLI surface.** `auricle list` implicitly means "what auricle on this Mac knows about." For "any meeting note across all my Macs" the user queries the vault in Obsidian (Search / Bases / Dataview) — auricle's CLI does not try to be a vault search tool.
- JSON output schemas are part of the binding contract (per NFR-I7), with explicit `schemaVersion` per response.

`<id>` is a meeting ID — a ULID (Crockford base32, 26 chars) assigned at capture start; see ID resolution below for accepted input forms.

##### MVP verb surface (10 verbs)

Verbs are grouped logically (the `auricle help` output surfaces these groups); the framework is flat — no required subcommand grouping except for `config`.

**Capture lifecycle:**

| Command | Purpose |
|---|---|
| `auricle record [<id>]` | Start capture. `<id>` optional; if absent, generate a new ULID and use it. If present and there's no captured audio yet, use that ID; if present and audio already exists, exit 1 (use `--replace` to override). |
| `auricle stop` | Stop active capture. Idempotent: exits 0 with stderr message if nothing is recording. |
| `auricle discard <id>` | Delete cached audio + meeting state for a captured-but-unwanted meeting. Does NOT touch the vault note (DP4: never delete vault files). The verb name is deliberate — `delete` would falsely imply vault deletion. |

**Pipeline:**

| Command | Purpose |
|---|---|
| `auricle run <id> [--force] [--from <stage>] [--to <stage>] [--only <stage>] [--reattribute] [--publish-anyway]` | Run the pipeline post-capture. **Default (no flags) is also the resume verb for transient failures** (`summarization_failed`, `persist_failed`): runs forward from the meeting's current state. `--force` re-runs all stages (idempotent per NFR-R5) and is also the override path for permanent failures (`capture_failed`, `transcription_failed`) where the user has investigated and wants to retry. `--from` / `--to` / `--only <stage>` give orthogonal stage control. `--reattribute` is `--from attribute` semantically (ergonomic alias); preserves the existing armed retention timer (re-attribution is content fix, not re-verification). `--publish-anyway` skips attribution and publishes with `Speaker_N` placeholder names + `auricle/needs-attribution` tag (Journey 2 explicit support per FR25); if summarize then fails, meeting transitions to `published_partial` per Decision 4.1. **`auricle run <id>` does NOT auto-verify on success** — verification requires an explicit user act (notification click, GUI confirm, or `auricle keep <id>`). |

`run` composes naturally with future pipeline stages added in v2+ without changing the contract surface — `--from` / `--to` / `--only` take stage names as string arguments, surviving the addition of new stages.

Individual-stage verbs (`auricle transcribe <id>`, `summarize <id>`, etc.) are intentionally NOT exposed at the top level — they're reachable via `run --only <stage>`. This keeps the surface user-shaped (one verb for "make my meeting into a note") rather than engineer-shaped (one verb per pipeline phase). `notify` is a pipeline side-effect, not a user verb — internal to the `Notifier` module only.

**Attribution (the one stage that has its own verb because it's interactive):**

| Command | Purpose |
|---|---|
| `auricle attribute <id> [--batch]` | **Default: interactive.** CLI process performs `NSWorkspace.open auricle://attribute/<id>` and exits 0 — opens the GUI attribution window. With `--batch`: applies the last-known speaker mapping if any; otherwise exits 1 with actionable error (e.g., "no speaker mapping; run with --interactive or pass --speakers"). Errors gracefully on headless sessions (e.g. SSH) — falls through to batch behavior. |

`attribute` has its own verb (rather than only being reachable via `run --only attribute`) because it's the one stage that's expected to be invoked directly by a stressed user during failure recovery; making the bare `auricle attribute <id>` invocation Just Work via the GUI honors the brainstorm's "CLI is the failure-recovery surface" framing.

**Verification:**

| Command | Purpose |
|---|---|
| `auricle keep <id>` | Manual verification: confirms the user has reviewed the meeting note. Sets `meetings.verified_at = now()` and arms the retention timer (same write path as the GUI's notification-click handler). Used when Notifications permission is revoked, when the user opens the note directly from Obsidian (skipping the notification-click), or when verifying from a CLI session. Resolves the gap surfaced in step-02's known-one-way-doors analysis. |

**Inspection:**

| Command | Purpose |
|---|---|
| `auricle list [--all] [--json]` | List meetings auricle on **this Mac** knows about (default: non-terminal; `--all` includes verified and discarded). The CLI does not query the vault — for "any meeting note across all my Macs," use Obsidian's vault search. |
| `auricle status <id> [--json]` | Show meeting state + artifact paths + retention status + a copy-pasteable `log show --predicate ...` invocation for inspecting structured logs. |

**Configuration & operations:**

| Command | Purpose |
|---|---|
| `auricle config get [<key>]` | Read a single config value, or all values if no key supplied (with secrets redacted). |
| `auricle config set <key> <value>` | Write a single config value. |
| `auricle doctor` | Permission + Gatekeeper-trust + vault-path checks; diagnoses with inline `fix:` text the user runs themselves. (Auto-remediation is a v1.1 ergonomic improvement; see below.) |

**Bare invocation:**

| Command | Purpose |
|---|---|
| `auricle` (no args) | Status, not help. Prints the most relevant current state: "Recording 01HZ... — 14m 22s" if a capture is in flight; "Last meeting awaiting attribution: `auricle attribute current`" if there's an unresolved meeting; "Last meeting awaiting your review: `auricle keep last`" if there's an unverified meeting; "Nothing in flight." otherwise. The user gets answered, not interrogated. Help is the explicit fallback (`auricle help` or `auricle --help`). |
| `auricle help [<verb>]` | Help (also `auricle --help` and `auricle <verb> --help`). |

##### v1.1 additions (additive — non-binding at MVP)

These are deferred from MVP, NOT placed in an `experimental` namespace (we don't need that ceremony at single-user scale). They will ship as additive verbs / flags in v1.1+, at which point they enter the binding contract.

| Command | Purpose |
|---|---|
| `auricle pending [--json]` | List only non-terminal meetings (subset of `list`'s default). Convenience for scripting. |
| `auricle retain <id> [--indefinite \| --days N \| --release]` | Override audio retention. `--release` reverts an existing override back to the global config's grace window (closes the retention-release gap surfaced by Mary). The three flags are mutually exclusive. |
| `auricle attribute <id> --emit-snippets` | Write per-speaker WAV snippets to cache and exit (CLI fallback when the GUI is unusable). |
| `auricle attribute <id> --speakers "1=Name,2=Name,..."` | Apply manual speaker mapping and resume the pipeline (CLI fallback). |
| `auricle doctor --fix` | Auto-remediation per failed check (running `setup-trust.sh`, prompting for missing config values, etc.). MVP `doctor` diagnoses only. |
| `auricle logs <id> [--stage <name>]` | Print structured logs for a meeting from `os_log`. MVP equivalent: `auricle status <id>` includes the `log show --predicate ...` invocation as a copy-pasteable line. |
| `auricle --generate-completion-script <bash\|zsh\|fish>` | Print shell-completion script (swift-argument-parser standard). Useful but not a product contract; defer. |

`diarize` becomes available as a separate verb if/when diarization is decoupled from transcribe (v2+ pyannote-sidecar `DiarizerStrategy` slot). Until then, `auricle run --only diarize <id>` is unsupported because there's no separate diarize stage to run.

##### ID resolution (shared `MeetingIDResolver` across GUI and CLI)

A single `MeetingIDResolver` type lives in the shared SwiftPM library. Every CLI verb that takes `<id>` calls into it; the GUI uses the same resolver for any internal ID lookups. Inputs accepted:

| Input form | Resolves to |
|---|---|
| Full ULID (26 chars) | Exact match |
| ULID prefix (≥6 chars) | Unique prefix match. Ambiguous prefix → exit 1 with the list of matching IDs. (ULID's Crockford alphabet means a 6-char prefix is ~1B values; ambiguity is rare in practice.) |
| `current` | The meeting currently in active capture (`meetings.state = 'recording'`). Errors if no active recording. |
| `last` | The most recently created meeting (highest `created_at`). |

##### Output conventions

- **Default human output to stdout:** plain text, ANSI color only when stdout is a TTY (auto-detected; safely falls back when piped).
- **Default human errors to stderr:** **one sentence**, including the next action. Example: *"Couldn't attribute 01HZ7K — no speaker mapping yet. Try `auricle attribute 01HZ7K` to set names."* Warm, concise, actionable.
- **`--json`:** machine-readable JSON to stdout. Available on every inspection verb (`list`, `status`, `config get`, and v1.1's `pending`). When `--json` is used, errors also become JSON to stderr in the structured shape (see below). The JSON schema for each verb's output is part of the binding contract.
- **`--quiet`:** exit code only, suppress stdout output. Available on action verbs (`stop`, `record`, `discard`, `keep`, and v1.1's `retain`).
- **stderr for diagnostics, stdout for data:** so `auricle list --json | jq` works without filtering noise.
- **`--json` is always opt-in.** No TTY-detection of `--json` — auto-detection breaks in CI, tmux, and `tee`.

##### JSON schema versioning (part of the binding contract per NFR-I7)

Every `--json` response includes a top-level `"schemaVersion": <int>` field:

```json
{
  "schemaVersion": 1,
  "meetings": [...]
}
```

JSON schemas are documented alongside this verb table. Adding new fields is additive (consumers ignore unknown fields per Postel's law). Removing or renaming fields requires bumping `schemaVersion` and is a major version bump per NFR-I7. There is one schema per verb's response shape; they evolve independently.

##### Error message templates

**Default human (one sentence, to stderr):**

> Couldn't attribute 01HZ7K — no speaker mapping yet. Try `auricle attribute 01HZ7K` to set names.

The pattern: *"\<what failed\> \<concise cause\>. \<next action with concrete command\>."*

**`--json` mode (structured, to stderr):**

```json
{
  "schemaVersion": 1,
  "error": {
    "summary": "Couldn't attribute 01HZ7K",
    "meetingId": "01HZ7K...",
    "state": "awaiting_attribution",
    "cause": "no speaker mapping",
    "fix": "auricle attribute 01HZ7K",
    "see": "auricle doctor"
  }
}
```

The structured form is also written to `os_log` for every error (regardless of CLI mode), so log-grep over time gets the same structured shape.

##### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (including idempotent no-ops like `stop` when nothing is recording, or `run` when the meeting is already published without `--force`) |
| 1 | User error: bad ID, conflicting flags, missing required argument, ambiguous prefix |
| 2 | State error: subprocess crash, permission denied, vault unreachable |
| 3 | Not found: meeting ID doesn't exist |

##### Flag conflicts (resolved at parse time, exit 1 with clear error)

- `--force` (`run`) and `--reattribute` (`run`): `--force` implies `--reattribute`. Compatible; `--force` wins on precedence.
- `--from <stage>` and `--only <stage>` (`run`): mutually exclusive (different control models).
- `--publish-anyway` (`run`) and `--from attribute` / `--only attribute` (`run`): mutually exclusive (`--publish-anyway` skips attribution; `--from/--only attribute` forces it).
- `--indefinite` and `--days N` and `--release` (v1.1 `retain`): mutually exclusive.
- `--emit-snippets` and `--speakers` (v1.1 `attribute`): mutually exclusive.
- `--batch` and `--emit-snippets` / `--speakers` (`attribute`): mutually exclusive.

##### `doctor` output format

```
auricle doctor — system check
==============================
[OK]   Microphone permission granted
[OK]   Screen Recording permission granted
[FAIL] Notifications permission denied
       fix: System Settings > Notifications > Auricle > Allow Notifications
[OK]   Gatekeeper trust configured for the auricle code-signing CA
[FAIL] Vault path /Users/andrew/checkouts/SecondBrain does not exist
       fix: Create the directory, or run: auricle config set vault_path <path>

2 of 5 checks passed.
```

`[OK]` / `[FAIL]` glyphs by default; `✓` / `✗` (or color) when stdout is a TTY. Exit 0 if all checks pass; exit 2 if any fail. (v1.1 adds `--fix` for auto-remediation.)

##### `auricle` (no args) status output examples

```
$ auricle
Recording 01HZ7K... — 14m 22s, capturing fine.
Stop with: auricle stop
```

```
$ auricle
Last meeting awaiting your attribution:
  Tuesday Sync with Ben (01HZ7K...) — 32m, captured 4m ago
  Resolve with: auricle attribute current
```

```
$ auricle
Last meeting awaiting your review:
  Tuesday Sync with Ben (01HZ7K...) — published 12m ago to ~/checkouts/SecondBrain/Meetings/2026-04-28-tuesday-sync-with-ben.md
  Confirm with: auricle keep last
```

```
$ auricle
Nothing in flight. Run `auricle help` for usage, or `auricle record` to start capturing.
```

##### swift-argument-parser implementation notes

- Top-level type is `AsyncParsableCommand` with `subcommands: [...]`. Every verb is async because capture / persist / network calls are async.
- `config` is a `ParsableCommand` with nested `Get` / `Set` subcommands. `config get` with no key argument is the "show all" path.
- `attribute`'s interactive (default) vs `--batch` vs (v1.1) `--emit-snippets` / `--speakers` modes are modeled with `@OptionGroup` + `validate()` to enforce mutual exclusion (swift-argument-parser does not have native `mutuallyExclusive`; verify the validate-at-parse pattern).
- `<id>` arguments use `@Argument` with `CompletionKind.custom` for tab completion, completing from `auricle list --json | jq -r '.meetings[].id'` (when `--generate-completion-script` ships in v1.1).
- ID resolution lives in the shared SwiftPM library (`MeetingIDResolver`); CLI verbs do not parse `<id>` themselves.
- The bare `auricle` (no subcommand) is implemented as a default subcommand on the top-level `AsyncParsableCommand` that runs the status query.

(Renaming or removing any verb / flag / JSON field above requires a major version bump per NFR-I7. Adding new verbs / flags / JSON fields is additive and does not.)

### Group 2: Persistence & Data

This group covers SQLite schema, frontmatter contract, re-publish semantics, filename convention, and vault path defaulting. Decisions here were refined through a multi-agent architecture roundtable; significant outcomes folded in below include the cache-dir + SQLite source-of-truth model (now reflected in Decision 1.2 above), GRDB process-handling patterns, the cross-Mac filename uniqueness strategy, write-authority partitioning, and clarified field semantics.

#### Decision 2.1: SQLite schema, access patterns, and file lifecycle

The single SQLite database lives at `~/Library/Application Support/com.auricle.app/auricle.sqlite3`. Accessed via GRDB.swift (per Starter Template Evaluation). WAL mode is enabled and persists in the file header; set in migration #1.

**Five tables:**

```sql
-- Migration tracking; owned exclusively by GRDB.DatabaseMigrator. No application code writes this.
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL                   -- ISO8601 UTC, 'YYYY-MM-DDTHH:MM:SSZ'
);

-- One row per captured meeting; the meeting's lifecycle anchor.
CREATE TABLE meetings (
    id TEXT PRIMARY KEY,                       -- ULID (Crockford base32, 26 chars), e.g. '01HJK3PQXY7N8M...'
    state TEXT NOT NULL,                       -- canonical state name from Decision 1.2
    created_at TEXT NOT NULL,                  -- ISO8601 UTC
    updated_at TEXT NOT NULL,                  -- ISO8601 UTC; maintained by AFTER UPDATE trigger (see below)
    capture_started_at TEXT,                   -- ISO8601 UTC; set by capture stage on record start
    capture_ended_at TEXT,                     -- ISO8601 UTC; set by capture stage on stop
    duration_seconds INTEGER,                  -- NULL until capture_ended_at is set; CHECK (duration_seconds >= 0) when set
    title TEXT,                                -- initial from calendar enrichment or generic 'Meeting at <ts>'; refined by summarize sub-step
    calendar_event_id TEXT,                    -- 'google:abc...' format, namespace-prefixed for future CalendarSource implementations
    vault_note_path TEXT,                      -- absolute vault path; set by persist; updated to latest publish on re-publish
    audio_cache_path TEXT,                     -- absolute path under cache-dir; set by capture; immutable once set
    verified_at TEXT,                          -- ISO8601 UTC; set by verify (notification click handler) or `auricle keep <id>`
    retention_policy TEXT                      -- NULL = use global config at timer-arm time; non-NULL = explicit override ('indefinite' or 'custom:<days>')
);
-- Partial index on active states for fast pending-list queries
CREATE INDEX idx_meetings_state ON meetings(state)
  WHERE state NOT IN ('verified','retention_expired','discarded');

-- Append-only stage event log; replayable for audit and forensic crash analysis
CREATE TABLE stage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    stage TEXT NOT NULL,                       -- 'capture'|'transcribe'|'attribute'|'summarize'|'persist'|'notify'|'verify'|'discard'
    event TEXT NOT NULL,                       -- 'started'|'completed'|'failed'|'retried'
    occurred_at TEXT NOT NULL,                 -- ISO8601 UTC
    duration_ms INTEGER,                       -- only set on 'completed'/'failed' events
    error_message TEXT,                        -- only set on 'failed' events
    metadata_json TEXT                         -- stage-specific structured data, e.g. {"cost_usd":0.32,"thinking_tokens":3200}
);
CREATE INDEX idx_stage_events_meeting ON stage_events(meeting_id, occurred_at);

-- Retention timer queue; one row per meeting once verification fires
CREATE TABLE retention_timers (
    meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
    armed_at TEXT NOT NULL,                    -- ISO8601 UTC; verification click timestamp
    fires_at TEXT NOT NULL,                    -- ISO8601 UTC; when audio should be deleted
    last_reminded_at TEXT,                     -- ISO8601 UTC; for 7d / 14d escalation reminders
    status TEXT NOT NULL DEFAULT 'pending'     -- 'pending'|'fired'|'overridden'
);
CREATE INDEX idx_retention_pending_fires_at ON retention_timers(fires_at) WHERE status = 'pending';

-- Per-meeting telemetry rollup; one row populated incrementally via UPSERT (different stages contribute different columns)
CREATE TABLE telemetry (
    meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
    time_to_attribution_ready_seconds INTEGER,  -- machine-time only: awaiting_attribution.entered_at - capture.completed_at (the part NFR-P1 budgets)
    time_to_vault_note_seconds INTEGER,         -- user-perceived end-to-end: notify.completed_at - capture.completed_at (includes user-paced attribute time)
    transcription_wer_estimate REAL,
    quote_validation_drop_count INTEGER,
    attribution_completion_path TEXT,          -- 'inline_ui'|'cli_speakers_flag'|'publish_anyway'
    summarization_path TEXT,                   -- 'claude_api'|'local_llm'
    summarization_model TEXT,                  -- 'claude-opus-4-7'|'claude-sonnet-X'|'ollama:...'
    summarization_effort_budget TEXT,          -- 'minimal'|'low'|'moderate'|'high' or numeric token count
    cost_usd REAL,                             -- summarize stage cost only (Opus); see *_cost_usd siblings below for AI-reviewer costs
    -- AI-reviewer category telemetry (Decision Group 5; sparse — populated only when corresponding feature runs)
    diarization_suggestions_count INTEGER,         -- count of AI-proposed corrections emitted by reviewer
    diarization_suggestions_applied_count INTEGER, -- count user accepted (per-suggestion Apply or Apply all)
    diarization_suggestions_rejected_count INTEGER,-- count user explicitly rejected
    diarization_review_cost_usd REAL,              -- Haiku cost for the review pass; '0' for local-LLM impls (Decision 5.6)
    diarization_review_model TEXT,                 -- 'claude-haiku-4-5' | 'local:<name>' (Decision 5.6 telemetry contract)
    -- Transcription review category (Decision 5.5 Phase 3 — declared, sparse in MVP)
    transcription_suggestions_count INTEGER,
    transcription_suggestions_applied_count INTEGER,
    transcription_suggestions_rejected_count INTEGER,
    transcription_review_cost_usd REAL,
    transcription_review_model TEXT,
    audio_retention_status_at_30d TEXT         -- backfilled by a periodic retention scheduler
);

-- Trigger: maintain meetings.updated_at automatically (removes a class of bug)
CREATE TRIGGER meetings_updated_at AFTER UPDATE ON meetings
BEGIN
    UPDATE meetings SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = NEW.id;
END;
```

**Time format:** all SQLite timestamps are **ISO8601 UTC with `Z` suffix** (`2026-04-28T17:30:15Z` or `2026-04-28T17:30:15.123Z`). Local time is used only in filename slugs (Decision 2.4); everywhere else is UTC. Sorting and DST-correctness depend on this discipline.

**File lifecycle vs DB cascade:** `ON DELETE CASCADE` removes child rows in `stage_events`, `retention_timers`, and `telemetry` when a `meetings` row is deleted — but it **does NOT delete files** at `audio_cache_path` or `vault_note_path`. Silent file leaks are the bug this would otherwise produce. The contract:

- **Cache-dir cleanup** (`audio_cache_path` and the meeting's entire cache subdirectory): performed explicitly by the caller before the `DELETE FROM meetings` SQL runs. Never rely on cascade for filesystem state.
- **Vault note cleanup**: auricle never deletes vault notes (DP4: never edit existing vault files; this extends to "never delete either"). If the user wants to delete a meeting's note, they do so manually in Obsidian; the SQLite row can then be reaped via `auricle discard <id>` which removes the cache-dir but not the vault file.
- A periodic CLI verb (`auricle prune --dry-run` / `auricle prune --commit`, future v1.1+) can reconcile orphan cache directories against `meetings` rows that no longer exist.

**GRDB / WAL / concurrency model** (each row a binding implementation rule):

| Concern | Rule | Notes |
|---|---|---|
| GUI process | Use `DatabasePool` | Concurrent reads with own writes; needed for live UI |
| Subprocess (transcribe, summarize, etc.) | Use `DatabaseQueue` | Single writer, simpler lock semantics; subprocesses don't need read concurrency |
| Cross-process safety | SQLite WAL + POSIX advisory locks | Verified supported by GRDB; sequential per-meeting workload + single-user means contention is theoretical, not actual |
| Busy timeout | `Configuration.busyMode = .timeout(5.0)` on every opener | Subprocess transactions are <50ms; 5s is generous |
| Foreign keys | `PRAGMA foreign_keys = ON` per connection | GRDB enables by default; verify in test |
| WAL persistence | Set `journal_mode=WAL` in migration #1 | Sticky in file header; subsequent opens inherit |
| Checkpointing | GUI runs `PRAGMA wal_checkpoint(TRUNCATE)` on app quit AND on every state transition (NFR-R6) | Subprocesses do NOT checkpoint — let GUI own it |
| Reactive observation | **GRDB `ValueObservation` is in-process only** — does not see external writes | GUI must use file-watch (`DispatchSource.makeFileSystemObjectSource` on `db.sqlite3-wal`, 100ms debounce) OR poll `meetings.updated_at` while a subprocess is in-flight. Recommended: file-watch |
| Migrations | Use `GRDB.DatabaseMigrator`; never hand-roll | Migrations are forward-only; identified by string ID |
| Partial indexes | Created via raw SQL (`db.execute(sql:)`) — GRDB's typed builder doesn't support `WHERE` clause on indexes | Not a blocker, just don't expect the type-safe builder |

**Write-authority matrix:** which process / stage writes which columns. The Orchestrator's narrow API (linked into both GUI and CLI binaries) is the enforcement surface; SQLite has no row-level perms.

| Table.Column(s) | Writer | Notes |
|---|---|---|
| `schema_version.*` | `GRDB.DatabaseMigrator` (GUI on app launch) | Subprocesses never migrate; fail-fast if version mismatch on open |
| `meetings.id`, `created_at`, initial `state='recording'`, `capture_started_at`, `audio_cache_path`, initial `title` (from calendar if available), `calendar_event_id` (initial), `retention_policy` (NULL or override per config) | GUI `capture` stage on row INSERT | `id` = ULID generated client-side; `audio_cache_path` immutable post-INSERT |
| `meetings.capture_ended_at`, `duration_seconds`, `state='captured'` | GUI `capture` stage on stop | Single transaction |
| `meetings.state` (every transition after capture) | The process executing the stage that just completed | Same transaction as the matching `stage_events` insert (Txn B per Decision 1.2) |
| `meetings.title` (refined), `calendar_event_id` (refined) | `summarize` subprocess | Calendar enrichment is a sub-step of summarize, not a separate stage; may overwrite initial values with calendar-confirmed ones |
| `meetings.vault_note_path` | GUI `persist` stage | Updated to latest publish on re-publish (see Decision 2.3) |
| `meetings.verified_at` | GUI `verify` stage (notification click handler OR `auricle keep <id>` CLI) | Single transaction with `retention_timers` insert |
| `meetings.updated_at` | `meetings_updated_at` trigger | Application code never sets this directly |
| `stage_events.*` | The process executing that stage | Rule: writer of stage X owns all `started`/`completed`/`failed`/`retried` rows for stage X. No exceptions |
| `retention_timers.*` (INSERT, `armed_at`, `fires_at`) | GUI `verify` stage handler | |
| `retention_timers.last_reminded_at`, `status` | GUI retention scheduler | Periodic background task in the GUI |
| `telemetry.time_to_notification_seconds` | GUI `notify` stage | UPSERT |
| `telemetry.transcription_wer_estimate` | `transcribe` subprocess | UPSERT |
| `telemetry.quote_validation_drop_count`, `summarization_path`, `summarization_model`, `summarization_effort_budget`, `cost_usd` | `summarize` subprocess | UPSERT (row may not exist yet) |
| `telemetry.attribution_completion_path` | GUI `attribute` stage | UPSERT |
| `telemetry.diarization_suggestions_count`, `diarization_review_cost_usd`, `diarization_review_model` | `reviewing_diarization` subprocess (`DiarizationReviewerStrategy`) | UPSERT; written even when flag is off (count=0, cost=0, model=`'flag_off'`) for sparse-but-explicit telemetry |
| `telemetry.diarization_suggestions_applied_count`, `diarization_suggestions_rejected_count` | GUI `attribute` stage (Attribution sheet view model) | UPSERT; debounced incremental writes track user accept/reject actions during the sheet session |
| `telemetry.transcription_suggestions_*` columns | (declared; no writer in MVP per Decision 5.5 Phase 3) | Slot reserved |
| `telemetry.audio_retention_status_at_30d` | GUI retention scheduler | Backfilled at 30d mark |

Read access is unscoped — any process may read any table. The write-authority discipline is enforced via narrow Orchestrator entry points, not SQLite ACLs.

**Field semantics for non-obvious columns** (Paige's request from the architecture roundtable):

| Column | Format | Set when | Nulled when |
|---|---|---|---|
| `meetings.id` | ULID, Crockford base32, 26 chars | Capture stage row INSERT | Never |
| `meetings.audio_cache_path` | Absolute path; `~/Library/Caches/com.auricle.app/<id>/audio.wav` | Capture stage start (with row INSERT) | Never (the file may be deleted by retention sweeper, but the column value persists as forensic record) |
| `meetings.vault_note_path` | Absolute path; e.g. `/Users/andrew/checkouts/SecondBrain/Meetings/2026-04-28-tuesday-sync-with-ben.md` | Persist stage success | On re-publish: updated to point at latest publish, NOT cleared (the previous original is preserved on disk per Decision 2.3) |
| `meetings.calendar_event_id` | `<source>:<id>` namespaced, e.g. `google:abc123` | Capture (initial guess from active calendar event) OR refined by summarize sub-step | If calendar enrichment fails permanently, stays NULL (frontmatter then carries `auricle/needs-calendar-enrichment` tag) |
| `meetings.retention_policy` | NULL (= use global config at timer-arm time) OR `'indefinite'` OR `'custom:<days>'` (e.g. `'custom:30'`) | Capture stage INSERT (NULL by default; non-NULL if user has a per-meeting override prepared) OR Settings UI / `auricle retain` | Never (NULL is meaningful; use UPDATE to NULL it explicitly to revert to global default) |
| `meetings.duration_seconds` | Integer seconds, ≥ 0 | Capture stop | Never |
| `stage_events.metadata_json` | JSON object, stage-specific schema | Stage execution | Never (append-only) |

**Why no `attendees` table:** per-meeting attendees are denormalized into the frontmatter (as wikilinks per FR38) and into the calendar metadata. SQLite doesn't need them for state, retention, or telemetry queries. A normalized table would be premature complexity.

**Why no transcript / diarization / summary content in SQLite:** those are file-shaped artifacts living in the cache-dir per Decision 1.3. SQLite holds the pointer (`audio_cache_path` + the cache-dir convention), not the content.

**Migration approach:** GRDB's `DatabaseMigrator` pattern — each migration is a Swift closure named by string ID, applied in order, never reordered or removed. Forward-only; no rollback support. New schema versions bump only when a table structure changes; data-only migrations (e.g., backfilling `telemetry.audio_retention_status_at_30d`) run as separate maintenance tasks, not as schema migrations.

#### Decision 2.2: Frontmatter schema

The vault note's frontmatter is the canonical contract DP2 protects. It holds **only what the human reader, the Obsidian vault graph, or auricle's `--reattribute` reader actually needs**. Everything operational lives in SQLite (cross-cutting concern #11).

**Standard MVP shape (`auricle.schema_version: 1`):**

```yaml
---
title: "Tuesday Sync with Ben"
date: 2026-04-28
tags:
  - auricle/meeting
attendees:
  - "[[Ben]]"
  - "[[Andrew Underwood]]"
auricle:
  meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"   # ULID, Crockford base32, 26 chars
  schema_version: 1
---
```

**Speaker rendering in body text:** Obsidian wikilinks per FR38. `[[Ben]] outlined the timeline...`

**Quote-grounded items render as Obsidian blockquotes** (final shape depends on the Citations spike outcome — see Open Resolutions in PRD; placeholder shape):

```markdown
## Action Items

- [[Ben]] will draft the project brief by end of week
  > I'll take a first pass at the brief by Friday

## Decisions

- Move the launch date to May 15
  > Yeah let's push it to the 15th, that gives us another week
```

**Variants (decision table — when each applies and what changes):**

| Variant | Trigger | Tag(s) added | Other changes vs standard |
|---|---|---|---|
| **Standard** | Calendar enrichment succeeded AND attribution completed | `auricle/meeting` | (baseline above) |
| **Publish anyway** | User clicked "Publish anyway" in attribution UI (FR25) without completing attribution | `auricle/meeting` + `auricle/needs-attribution` | `attendees` contains `[[Speaker_1]]`, `[[Speaker_2]]`, etc. — placeholder wikilinks |
| **Calendar enrichment failed** | Calendar API unreachable OR no matching event found (FR54) | `auricle/meeting` + `auricle/needs-calendar-enrichment` | `title` becomes generic `"Meeting at 2026-04-28T10:30 PT"`; `attendees` is `[]` (empty list) |
| **Re-published** | `auricle run <id> --reattribute` (or any path triggering re-publish) | `auricle/meeting` (no special tag) | `auricle.supersedes` field added pointing to original filename (see Decision 2.3) |
| **Combination** (e.g., publish-anyway + calendar-failed) | Both triggers fire | Both flag tags | Both shape changes |

**Frontmatter schema versioning policy:**

- **`auricle.schema_version` is required and stable forever.** The field name itself never changes; this is the bootstrap that enables future readers.
- **Additive changes within a major version:** new fields under `auricle.*` may be added without bumping `schema_version` (consumers ignore unknown fields per Postel's law).
- **Breaking changes** (field renames, type changes, removals, semantic changes) require bumping `schema_version` (e.g., `1 → 2`) AND require auricle's reader to handle ALL historical schema versions ever shipped. Bumping is documented in release notes.
- **The `--reattribute` reader inspects `auricle.schema_version` first**, then dispatches to the version-specific parser. If the version is older than any ever-shipped value, fail-fast with a clear error pointing to the earliest auricle version capable of reading that note.
- **Forward-incompatible reads** (note from a future auricle version on an older auricle binary) are also fail-fast errors. The user is expected to keep auricle versions aligned across personally-owned Macs (single-user assumption; multi-Mac doesn't mean multi-version).

#### Decision 2.3: Re-publish semantics

DP4 + FR36 + NFR-R2 (never edit existing vault files) collides with FR40 (stable deterministic filenames). Resolution: re-publish writes a sibling file with a deterministic suffix; the original is preserved untouched; both notes carry frontmatter linkage.

**When `auricle run <id> --reattribute` (or any other re-publish path) runs:**

1. Confirm the original vault note still exists at `meetings.vault_note_path`. If it doesn't (user deleted it), treat as fresh publish (no rerun suffix; standard filename per Decision 2.4).
2. Construct re-run filename: `<original-filename-without-ext>--rerun-<YYYY-MM-DD>.md`
   - Example: `2026-04-28-tuesday-sync-with-ben.md` → `2026-04-28-tuesday-sync-with-ben--rerun-2026-05-15.md`
   - The double-hyphen separator (`--`) before `rerun` provides visual distinction from the single-hyphen slug separators inside the original filename.
3. **Multiple reruns on the same calendar day:** append a counter: `--rerun-<YYYY-MM-DD>-2.md`, `--rerun-<YYYY-MM-DD>-3.md`. Re-run date is in the user's local timezone (consistent with Decision 2.4's date-prefix rule).
4. Write the re-run note via the atomic-write primitive. Frontmatter includes `auricle.supersedes: "<original-filename>"` (just the filename, no path — Obsidian resolves wikilink-style).
5. Update `meetings.vault_note_path` to point at the re-run note (the latest publish becomes the canonical one for `auricle status` lookups).
6. Notification body distinguishes: *"auricle: re-published Tuesday Sync with Ben (rerun 2026-05-15)"*.
7. Historical publishes are queryable via `stage_events` rows where `stage='persist'` and `event='completed'` for that meeting.

**The original is never modified by auricle.** If the user wants to record that the original is superseded, they edit the original's frontmatter manually in Obsidian. This is consistent with DP4 and DP2's "engagement happens upfront, not downstream" — the user reconciles which note is canonical, in Obsidian, where they're already working.

**SQLite's `meetings.vault_note_path` reflects the most recent publish only.** Historical publish paths are reconstructible from `stage_events` if ever needed but are not first-class queryable.

#### Decision 2.4: Filename convention

Filename pattern:

```
<YYYY-MM-DD>-<slug>.md
```

Where:

1. **`<YYYY-MM-DD>`** — date based on `capture_started_at` in the user's local timezone at capture time (not UTC; user-recognizable). The only local-time concession in the system; everywhere else is UTC.
2. **`<slug>`** — derived from meeting context (rules below).
3. **`.md`** extension.

**Cross-Mac uniqueness — accepted trade-off (not by-construction):** the user explicitly chose cleaner filenames over by-construction cross-Mac uniqueness. The realistic collision surface for the documented use case (single user, multiple personally-owned Macs) is narrow: cross-Mac collision requires two Macs to capture meetings with identical `capture_started_at` calendar date AND identical normalized slugs (most likely same calendar event from a synced Google Calendar). In practice the user is usually on one Mac at a time, and the failure mode (git conflict surfaced at sync time, or iCloud silent `(2)` rename) is annoying but recoverable manually. If the collision rate ever becomes a real problem in dogfood, a deterministic id-suffix can be re-introduced as an additive change without breaking the canonical filename convention.

**Slug source priority (try each; fall through if it produces an empty or unusable slug):**

1. **Calendar event title** (if calendar enrichment succeeded)
2. **`with-<attendee-1>-and-<attendee-2>`** for ≤3 attendees with named attribution; **self-attribution is omitted** (a 1:1 with Ben → `with-ben`, not `with-andrew-and-ben`)
3. **`meeting-at-<HHMM>`** generic fallback; uses 24h local time, 4 digits, no separator (e.g., `meeting-at-0930`)
4. **`meeting-<first-8-chars-of-id>`** — terminal fallback if all higher-priority sources somehow yield empty (defensive only; should be unreachable in practice)

**Slug normalization steps (applied in order):**

1. Unicode NFKD decomposition (decomposes accented characters into base + combining mark)
2. Strip all non-ASCII characters (drops the combining marks AND any character that doesn't have a decomposed ASCII form, e.g., `北京` → empty, emoji → empty)
3. Lowercase
4. Replace any run of `[^a-z0-9]+` with single hyphen
5. Strip leading and trailing hyphens
6. Collapse consecutive hyphens
7. Length cap at 60 characters; truncate at the last hyphen boundary at or before 60 chars (avoids mid-word cuts; if no hyphen found, hard-cut at 60)
8. If result is empty after all normalization → **fall through to next slug source priority**

**Slug edge cases (named explicitly so the fallback chain is testable):**

| Input | Outcome |
|---|---|
| `"Café résumé"` (calendar title) | NFKD strips accents → `cafe-resume` (slug source 1 succeeds) |
| `"北京会议"` (calendar title; CJK) | NFKD + ASCII strip → empty → fall through to source 2 |
| `"🎉 Launch!"` (calendar title; emoji + ASCII) | NFKD + ASCII strip → `launch` (slug source 1 succeeds) |
| `"🎉🎉🎉"` (calendar title; all-emoji) | NFKD + ASCII strip → empty → fall through to source 2 |
| No calendar title; attendees `["Ben","Andrew"]` (Andrew is self) | Fall through to source 2 → `with-ben` |
| No calendar; no named attribution; capture at 14:23 | Fall through to source 3 → `meeting-at-1423` |
| Title `"This is an extremely long meeting title that exceeds the slug length cap"` | After normalization, truncated at last hyphen ≤60 chars → `this-is-an-extremely-long-meeting-title-that-exceeds-the` (or similar) |

**Filename collision handling:**

- **Same-Mac collisions detected at write time** (same date, identical normalized slug — e.g., a recurring "Standup" meeting captured twice on the same day): append a `-2` / `-3` ordinal counter before `.md`. Counter is deterministic (always picks the next available ordinal), not random.
- **Re-publish vs same-day-collision discriminator:** the two paths use different suffixes, on different axes:
  - Same-day collision (different meeting that happens to slugify the same): `<date>-<slug>-2.md` (single hyphen, ordinal counter)
  - Re-publish (same meeting, intentional re-run): `<date>-<slug>--rerun-<YYYY-MM-DD>.md` (double hyphen, date suffix per Decision 2.3)
  - The persist stage knows which path it's on (re-publish is triggered explicitly via `--reattribute`); no ambiguity in code, just visually distinct in the filesystem.
- **Cross-Mac collisions** (same date, identical slug, different meetings on different Macs): not detected pre-publish on either Mac (each Mac sees no local conflict at write time). Surfaces at sync time as a git merge conflict OR an iCloud silent `(2)` rename. Accepted as low-probability, manually recoverable. See trade-off discussion above.

**Example filenames:**

| Scenario | Filename |
|---|---|
| Standard 1:1 with Ben, calendar match | `2026-04-28-tuesday-sync-with-ben.md` |
| Published-anyway, no attribution | `2026-04-28-project-kickoff.md` |
| Calendar failed, no attribution | `2026-04-28-meeting-at-1030.md` |
| All-emoji title, attendees `["Ben"]` | `2026-04-28-with-ben.md` |
| Same date AND identical slug as an existing file | `2026-04-28-standup-2.md` (ordinal counter) |
| Re-publish of standard 1:1 with Ben on 2026-05-15 | `2026-04-28-tuesday-sync-with-ben--rerun-2026-05-15.md` |
| Second re-publish same day | `2026-04-28-tuesday-sync-with-ben--rerun-2026-05-15-2.md` |

#### Decision 2.5: Vault path defaulting

The single PRD knob "vault path" (FR35, FR58) is split into two configurable values for greater flexibility:

| Config key | Default | Purpose |
|---|---|---|
| `vault_path` | `~/checkouts/SecondBrain` | Root of the Obsidian vault |
| `meetings_subdir` | `Meetings` | Subdirectory within the vault for auricle's output |

**Effective publish path:** `{vault_path}/{meetings_subdir}/<filename>.md`

**Validation rules:**

- `vault_path` must exist and be writable. **auricle does NOT auto-create it** (creating someone's vault by accident is a worse failure than refusing to publish). On launch, if `vault_path` doesn't exist or isn't writable, a remediation surface appears in the GUI and `auricle doctor` reports it. The CLI surfaces a clear error message with the resolved path and the failure reason.
- `vault_path/meetings_subdir`:
  - **If missing:** auto-created on first publish (auricle owns this subdirectory; auto-creation is safe). Permissions inherited from `vault_path`.
  - **If exists as a directory:** use it.
  - **If exists as a file:** fail-fast with a clear error at config-load time and on first publish attempt. `auricle doctor` flags this in its checks.
  - **If exists as a directory but not writable:** fail-fast with a clear error.
- Path is normalized (tilde expansion, symlink resolution) once at config load; the canonical absolute path is what's stored in `meetings.vault_note_path` (per Decision 2.1 field semantics).

**Why split into two knobs:** users may keep their vault at a non-default location (`~/Documents/Vault`, `~/Notes`, etc.) but want auricle's notes in a non-default subdirectory (`auricle/`, `inbox/Meetings/`, etc.). One knob conflated those two decisions; two knobs separate them cleanly. The cost is one extra config key.

### Group 4: Failure / Recovery / Security

This group covers error taxonomy, retry policies, the verification wiring path, permission detection, and telemetry collection. Several decisions formalize wiring paths referenced throughout earlier groups but never explicitly specified. Decisions here were refined through a multi-agent roundtable (engineering / UX / journey-coherence); substantive findings folded in below include the addition of a 4th `benign_terminal` failure category, the explicit failure-visibility surface (a real gap the prior decisions left invisible), the user-agency requirements for retries, the `Verifier` as Swift `actor` with idempotent SQL, in-voice Info.plist permission strings, and the formal `published_partial` state for the publish-anyway + summarize-fail combination.

#### Decision 4.1: Failure-state taxonomy and category-driven behavior

Four categories. Every stage failure or terminal-non-success state maps to one category; each category has consistent behavior so an implementer doesn't have to think per-stage.

| Category | Definition | Behavior | Example states |
|---|---|---|---|
| **Transient** | Likely to succeed on retry; cause is environmental (network, rate limit, ephemeral filesystem issue) | Auto-retry with backoff per Decision 4.2 *up to a cap*, with user-visible progress and a Stop-Trying affordance; on cap-exhaustion, escalate to user-actionable | `summarization_failed` (Claude API 5xx/timeout), `persist_failed` (transient FS error) |
| **Permanent** | Won't succeed without user intervention; cause is structural (bad audio, malformed config, missing permission, vault unwritable) | Mark `*_failed` terminally, push to pending list, surface to user with remediation, do NOT auto-retry | `capture_failed` (ScreenCaptureKit fundamentally rejected, including `permission_revoked_midstream`), `transcription_failed` (WhisperKit error after subprocess-restart retry) |
| **User-actionable** | Pipeline is waiting on user input by design; not a "failure" but a known halt | Mark `awaiting_*`, surface in UI / `auricle list`, no auto-retry; user resumes via explicit action | `awaiting_attribution`, `awaiting_verification` |
| **Benign terminal** | Pipeline completed correctly by detecting "nothing to do"; not a failure but not a happy-path outcome either | Mark with the specific terminal state; surface in UI as informational, not as a failure; user can discard or `--force` to override | `silent` (v1.1, VAD halted; FR9). Forward-compat for any future "successful detection of nothing" outcome (e.g., a future `<60s_audio` rejection rule). |

Implementation: `enum FailureCategory { case transient, permanent, userActionable, benignTerminal }` is a property on the canonical state name (not a separate column in SQLite — derived from `meetings.state`). The dispatcher consults it to decide retry vs surface; the GUI consults it to decide which color/affordance to render; the CLI consults it to decide exit code mapping per Decision 1.5.

State machine additions (folded back into Decision 1.2):
- `published_partial` — published with `Speaker_N` placeholders (because `--publish-anyway` was used) AND summarize had no usable output (it failed or was skipped). User-actionable: user can manually fix in Obsidian and run `auricle run <id> --reattribute` later. Note exists in vault with the action-items / decisions sections empty or omitted; carries `auricle/needs-attribution` AND a new `auricle/needs-summary` tag.

#### Decision 4.2: Per-stage retry / backoff policy and user agency

| Stage | Retry trigger | Policy | Cap | Terminal failure → state |
|---|---|---|---|---|
| `capture` | ScreenCaptureKit transient stream interruption | Best-effort stream restart inline | 3 failures within 30s | `capture_failed` (permanent) |
| `capture` | Permission revoked mid-stream | None — fire notification immediately, save partial audio | n/a | `capture_failed` with reason `permission_revoked_midstream` (permanent) |
| `transcribe` | WhisperKit OOM, model load failure | 1 retry after fresh subprocess restart | 1 retry | `transcription_failed` (permanent unless audio file is suspect) |
| `attribute` | N/A — never auto-retries | Pipeline halts at `awaiting_attribution`; user resumes via GUI or CLI | n/a | n/a (user-actionable, never terminal) |
| `summarize` | Claude API 429 / 5xx / network timeout | Exponential backoff: 1s → 2s → 4s → 8s → 16s | **5 min total budget (cap, not floor)** — configurable | `summarization_failed` (transient — queues for resume on next dispatch) |
| `persist` | Vault write error (disk full, transient permission flap, target file locked) | 1 retry after 1s | 1 retry | `persist_failed` (transient — retryable via `auricle run <id>`) |
| `notify` | UNUserNotificationCenter error | 1 retry | 1 retry | n/a (notification failure ≠ pipeline failure — see below) |

**Critical principle — stage idempotency:** Per NFR-R5, every stage is idempotent. A retry is just re-running the stage. The two-transaction pattern from Decision 1.2 (`stage_events` append-only) means each retry adds an audit row; the meeting state reflects only the most recent attempt's outcome. `attempt_number` is reconstructable from `SELECT COUNT(*) FROM stage_events WHERE meeting_id=? AND stage=? AND event IN ('started','retried')` — no separate column needed.

**User agency on retries (Sally's required UX):**

- The 5min summarize budget is a **cap, not a forced wait.** The user must always be able to give up early.
- **GUI:** during active retry, the meeting row in the main window shows a sub-line *"Retry 3 of 5 — next attempt in 4s"* with an inline "Stop trying" button. Pressing it: cancels in-flight HTTP request, transitions to `summarization_failed` immediately, leaves the meeting available for manual `auricle run <id>` resume later.
- **CLI:** when `auricle run <id>` is invoked in a foreground TTY and a retry is in flight, SIGINT (Ctrl-C) cancels the in-flight request and transitions to `summarization_failed`. Exit code 130 (standard for SIGINT). When `auricle run <id>` is non-interactive (piped, scripted), full budget applies; SIGTERM from the parent process is honored.
- **Subprocess token billing risk on crash:** if the summarize subprocess crashes after the request reaches Anthropic but before the response arrives, those tokens were billed; the retry pays again. Anthropic's API does not support idempotency-key headers (verify on every release). This is an accepted rare double-bill risk; logged in telemetry as a known cost edge case.

**Wall-clock budgets and stale-active-state detection (Round-2 roundtable lock-in — addresses Sally's silent-spinner UX P0):**

The retry-policy table above defines retry budgets *within* a stage. A separate, coarser budget defines the maximum wall-clock time a stage can remain in its active "_ing" state before the GUI synthesizes a failure transition. Without this, an in-session subprocess SEGFAULT (no Txn B written, no exit-code observed in time, e.g. parent paused or busy) leaves the chip showing "in-flight" indefinitely — the spinner-that-lies failure mode.

| Active state | Wall-clock stale-detection budget | Synthesized transition on stale |
|---|---|---|
| `transcribing` | 2 × NFR-P3 transcribe budget (≈ 60s for typical 30-min meeting; configurable) | `transcription_failed` (transient — `auricle run <id>` resumes) |
| `reviewing_diarization` | **90s fixed** (per-stage override; not 2× typical Haiku response) | Treated as benign timeout, NOT failure: an empty `diarization_suggestions.json` stub is written and the meeting advances to `awaiting_attribution`. A `stage_events.failed` row is recorded with `error_class='ai_reviewer_timeout'` for telemetry. The Attribution sheet renders without AI hints (acoustic warnings only, per UX spec Step 10 "AI review behavior — non-blocking"). Budget rationale: long-tail Anthropic latency (network stall, 503) drives a conservative ceiling; this is the first stage to use a per-stage override (the table previously assumed 2× of the inner-stage retry budget for every stage). |
| `attributing` | None — user-paced; no auto-failure | n/a |
| `summarizing` | 2 × NFR-P5 summarize budget (≈ 12 min — covers the 5-min retry budget × 2) | `summarization_failed` (transient — queues for resume) |
| `published` (waiting for notify) | 30s | `notify` retry path; if still stuck, log warn and proceed to `awaiting_verification` (notify failure is non-blocking per below) |

**Implementation:** the `Orchestrator` runs a periodic stale-detection sweep (every 10s while the GUI is foreground, every 60s when backgrounded). For each meeting in an active "_ing" state, it computes `now - meetings.updated_at` and compares against the budget for that state. On exceedance, it calls `StageRunner.synthesizeFailure(meetingID:reason: .staleActiveState(budget:))` which writes a `stage_events` row with `event='failed'`, `error_class='stale_active_state'`, and transitions the meeting to the corresponding `*_failed` state. The synthesized transition is just like a normal failure for downstream UX (chip flips to amber, banner surfaces, `auricle list` re-sorts).

**Why budget × 2 rather than budget × 1:** the inner-stage retry budget is the legitimate ceiling for a healthy execution. Budget × 2 gives one full retry-budget of grace for slow-but-real progress (laptop on battery, ANE thermal throttle, cold model load) before declaring stale. False-positive stale detection would punish slow but correct execution; budget × 2 is a conservative cushion.

**The GUI parent observing a subprocess `Process.terminationStatus` is a complementary path** (faster detection when termination IS observed) but the stale-detection sweep is the load-bearing safety net — it works even when the parent missed the termination event, force-quit and relaunched, hibernated, etc. Crash recovery on next launch (Decision 1.2) handles the cross-launch case; stale-detection handles in-session.

**Notify policy clarification — the most-flagged gap (Sally + Mary):**

Notify failure does NOT block the pipeline (the meeting moves to `awaiting_verification` regardless), BUT silent skip is unacceptable — users were demonstrated to lose track of meetings entirely. Required compensating surfaces:

| Surface | When it shows | What |
|---|---|---|
| **`auricle doctor` (MVP)** | Always | "N meetings are awaiting your verification (oldest: M days). Run `auricle list` to see them, or `auricle keep <id>` to confirm." |
| **`auricle list` (MVP)** | Default invocation | Sorts non-terminal-stale meetings to top with a `[awaiting verification, X days]` annotation |
| **GUI on-launch banner (MVP)** | App launch when any `awaiting_verification` is older than 24h | Non-modal banner: *"3 meetings are waiting for you to confirm them — last one from Tuesday."* Click → main window with those meetings highlighted. |
| **Dock badge (v1.1, FR16)** | Always when stale-pending count > 0 | Numeric badge equal to count of meetings older than the configured stale threshold |
| **Menu bar status (v1.1, FR8)** | Always when app is running | Small dot color reflects worst state (yellow for any `awaiting_*`, red for any `*_failed`) |

The user can never reach a state where a captured meeting is awaiting their verification but they have no awareness path.

#### Decision 4.3: Notification → Verifier → retention wiring

The single most critical wiring path in the system (FR42→43→44, NFR-R3 spirit). Single `Verifier` Swift `actor` is the converge point for all callers.

**Verifier API** (in shared SwiftPM library):

```swift
public actor Verifier {
    private let database: DatabaseQueue
    private let retentionWindow: () -> TimeInterval  // resolved from config at call time

    public func markVerified(meetingId: ULID) async throws {
        try await database.write { db in
            // Idempotent: if already verified, second call is a no-op (verified_at unchanged).
            // The COALESCE pattern means even concurrent callers don't race.
            let updatedRow = try Meeting
                .filter(Column("id") == meetingId.string)
                .updateAndFetchOne(db, [
                    Column("verified_at"): SQL("COALESCE(verified_at, ?)", [now()])
                ])
            guard let row = updatedRow else { throw VerifierError.meetingNotFound }

            // Only insert retention timer if this call is the one that flipped verified_at.
            // (If verified_at was already set, this is a no-op replay; skip the INSERT.)
            if row.verified_at == proposedTimestamp {
                try RetentionTimer(
                    meetingId: meetingId.string,
                    armed_at: row.verified_at,
                    fires_at: row.verified_at + retentionWindow()
                ).insert(db)
                // UNIQUE(meeting_id) constraint on retention_timers catches any race;
                // duplicate INSERT throws and is silently caught (we already armed).
            }
        }
    }
}
```

`actor` provides serialized access from the Swift type system. SQL idempotency via `COALESCE` provides correctness even under cross-process races. `UNIQUE(meeting_id)` on `retention_timers` is the belt-and-suspenders backstop.

**Three converging callers:**

1. **GUI notification-click delegate** — `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`:
   - Read `meeting_id`, `schema_version`, `payload_version` from `UNNotificationRequest.content.userInfo`
   - Call `NSWorkspace.shared.open(URL(string: "obsidian://open?vault=...&file=..."))`
   - `Task { await verifier.markVerified(meetingId: ...) }`
   - **Both writes happen regardless of whether Obsidian launches successfully** — the click is the verification act per FR44; the open is a courtesy. (Handles "Obsidian not installed" / "vault moved" gracefully.)
2. **GUI in-window confirm affordance** — for users who opened the note from Obsidian directly. Same `verifier.markVerified` call.
3. **CLI `auricle keep <id>`** — same call.

**Notification payload format** (binding contract; survives Sparkle upgrades):

```json
{
  "meeting_id": "01HZ7K...",
  "schema_version": 1,
  "payload_version": 1
}
```

Click handler MUST tolerate unknown `payload_version` from a future binary by falling back to "lookup meeting by ID, present in main window" rather than failing. `UNUserNotificationCenter`'s pending-notifications database survives `.app` replacement (verify behavior across Sparkle upgrades during implementation).

**`--reattribute` and the retention timer:**

When `auricle run <id> --reattribute` runs and successfully re-publishes the note (per Decision 2.3), the retention timer is **preserved**, not reset. The user already verified the original note; re-attribution is a content fix, not a re-verification. Re-arming the timer would punish the user for fixing attribution. (This rule applies to all re-publish paths, not just `--reattribute`.)

**Re-execution and verification:** `auricle run <id>` (without `--reattribute`) does NOT auto-verify on success. Verification requires an explicit user act (notification click, GUI confirm, or `auricle keep <id>`). Re-execution is content recovery; verification is human review.

**Resume semantics for transient failures:** `auricle run <id>` (with no flags) is the resume verb for any meeting in a transient failure state (`summarization_failed`, `persist_failed`). It runs forward from the meeting's current state. For permanent failures (`capture_failed`, `transcription_failed`), `auricle run <id> --force` is required to override and re-attempt; the implementation may also require user confirmation since permanent failures usually need investigation before retry.

#### Decision 4.4: Permission detection and remediation flow

Required permissions, in dependency order:

| Permission | TCC category | When required | Remediation deep link |
|---|---|---|---|
| Screen Recording | `kTCCServiceScreenCapture` | Before any capture attempt | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Microphone | `kTCCServiceMicrophone` | Before any capture attempt | `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| Notifications | TCC via `UNUserNotificationCenter` | Before notify stage; not strictly blocking (Decision 4.2) | `x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications` |
| Calendar (Google OAuth) | Not TCC; OAuth refresh-token in Keychain | Before calendar enrichment in summarize stage | Re-auth flow via system browser; on persistent failure, meeting publishes with `auricle/needs-calendar-enrichment` tag (graceful degradation per FR54) |

**Detection points:**

- **App launch:** check all four; populate `auricle doctor` results; if Screen Recording or Microphone is denied, surface a non-modal banner in main window with one-click jump to System Settings.
- **Before capture (`record` invocation):** re-check Screen Recording + Microphone (user may have revoked between launches). If missing, error with deep link.
- **Before notify:** check Notifications; if revoked, log `warn` and complete pipeline without firing notification (per Decision 4.2 retry+fallback policy).
- **Mid-capture (revocation event):** ScreenCaptureKit will throw on revocation. Catch the throw, save the partial audio, mark `capture_failed` with reason `permission_revoked_midstream`, fire a notification immediately: *"Recording stopped — Screen Recording permission was revoked. The partial audio is saved."*

**Info.plist usage descriptions** (these are user-visible in Apple's TCC dialog — purpose-first, plain voice):

| Key | String |
|---|---|
| `NSScreenCaptureUsageDescription` | *"auricle records your meeting audio so it can transcribe what's said."* |
| `NSMicrophoneUsageDescription` | *"auricle captures your voice alongside the meeting so your contributions are in the notes."* |
| `NSUserNotificationsUsageDescription` (where applicable) | *"auricle pings you when a meeting is ready to review — usually just a click to confirm."* |
| Calendar OAuth consent screen | *"auricle reads your calendar to title meetings and identify who's in the room."* |

**`auricle doctor` UX (MVP):** conversational, narrated, not a checklist:

```
auricle doctor — system check
==============================
[1 of 4]  Microphone permission                        ✓ granted
[2 of 4]  Screen Recording permission                  ✗ not granted
            auricle needs this to capture your meeting audio.
            → System Settings > Privacy & Security > Screen Recording
            → After granting, run: auricle doctor
[3 of 4]  Notifications permission                     ✓ granted
[4 of 4]  Vault path /Users/andrew/checkouts/SecondBrain  ✓ exists, writable

Summary: 3 of 4 checks passed. 1 issue to resolve.
2 meetings are awaiting your verification (oldest: 5 days).
  Run `auricle list` to see them.
```

`v1.1` `--fix` mode auto-runs the deep link, polls for grant, and re-checks per check.

**Cross-Mac note:** TCC permissions are per-Mac. Each Mac requires its own grant; auricle's per-Mac `~/Library/Application Support/com.auricle.app/auricle.sqlite3` is its own canonical-status store. `auricle doctor` is the single check for whether THIS Mac is ready.

#### Decision 4.5: Telemetry collection points (local-only, per NFR-S8 / NFR-Pr2)

Telemetry writes happen at deterministic stage boundaries; the schema is locked in Decision 2.1's `stage_events` and `telemetry` tables. This decision specifies WHEN each row is written, WHAT goes in `metadata_json`, and HOW logs are redacted.

**`stage_events` (append-only audit log, populated by every stage):**

| Event | Emitted at | `metadata_json` content |
|---|---|---|
| `started` | Txn A of every stage | `{}` (just a timestamp marker) |
| `completed` | Txn B of every stage on success | `{"duration_ms": ..., "stage_specific": <Codable type>}` |
| `failed` | Txn B of every stage on failure | `{"duration_ms": ..., "error_class": "...", "error_message": "...", "category": "transient|permanent|user_actionable|benign_terminal"}` |
| `retried` | At each retry attempt within a stage's lifetime | `{"attempt_number": N, "previous_error_class": "...", "backoff_ms": ...}` |

**`metadata_json` typing** — per-stage metadata is typed at the call site via Swift `Codable`, then serialized to JSON for storage:

```swift
enum StageMetadata: Codable {
    case capture(CaptureMeta)
    case transcribe(TranscribeMeta)
    case attribute(AttributeMeta)
    case summarize(SummarizeMeta)
    case persist(PersistMeta)
    case notify(NotifyMeta)
}
```

A `metadata_schema_version` column on `stage_events` allows migration of metadata shapes over time independently of the table schema.

**Stage-specific `completed` metadata content:**

- `transcribe`: `{"model_id": "whisper-large-v3-turbo", "audio_duration_s": 1827, "transcript_chars": 23847}`
- `reviewing_diarization`: `{"model_id": "claude-haiku-4-5", "input_tokens": ..., "output_tokens": ..., "cost_usd": ..., "suggestions_count": ..., "review_skipped": false}` — when `diarization_review.enabled = false`, payload is `{"model_id": "flag_off", "cost_usd": 0, "suggestions_count": 0, "review_skipped": true}`. For future local-LLM impls (Decision 5.5 Phase 2/4): `{"model_id": "local:<name>", "cost_usd": 0, ...}`. The `cost_usd: 0` + `model_id: "local:<name>"` contract is locked in MVP telemetry schema so v1.1+ swap is a config change, not a schema migration (Winston's Round-2 lock).
- `summarize`: `{"model_id": "claude-opus-4-7", "effort_budget": "moderate", "input_tokens": ..., "output_tokens": ..., "thinking_tokens": ..., "cost_usd": ..., "quote_validation_drop_count": ..., "grounding_method": "..."}` (`grounding_method` field becomes `"citations"` or `"substring"` post-spike)
- `persist`: `{"vault_note_path": "...", "frontmatter_schema_version": 1}`
- `notify`: `{"notification_id": "...", "delivered": true|false}`

**`telemetry` rollup (per-meeting, populated incrementally via UPSERT at stage boundaries):**

| Column | Populated by | Source |
|---|---|---|
| `time_to_attribution_ready_seconds` | `notify` stage on completion (or backfilled at `awaiting_attribution` entry, whichever fires first) | machine-time only: `awaiting_attribution.entered_at - capture.completed_at`. **This is the column NFR-P1's 2-min P50 budget applies to** (the part the architecture controls). |
| `time_to_vault_note_seconds` | `notify` stage on completion | user-perceived end-to-end: `notify.completed_at - capture.completed_at`. **Includes user-paced `attribute` time.** No hard budget; this is the headline number in `auricle stats` (v1.1) and the user's mental model of "how long did auricle take." |
| `transcription_wer_estimate` | (v1.1) bootstrapped from divergence between transcript and corrected summary | Calculated post-summarize, written by a v1.1 module |
| `quote_validation_drop_count` | `summarize` stage | From the grounding validator's dropped-item count |
| `attribution_completion_path` | `attribute` stage | One of `inline_ui` / `cli_speakers_flag` / `publish_anyway` |
| `summarization_path` | `summarize` stage | `claude_api` (MVP) or `local_llm` (v1.1+) |
| `summarization_model`, `summarization_effort_budget`, `cost_usd` | `summarize` stage | From the Claude API response metadata |
| `diarization_suggestions_count`, `diarization_review_cost_usd`, `diarization_review_model` | `reviewing_diarization` stage (Decision Group 5) | Count of AI-emitted suggestions, Haiku cost (or `0` for local-LLM), model id (or `flag_off`/`local:<name>`) |
| `diarization_suggestions_applied_count`, `diarization_suggestions_rejected_count` | `attribute` stage (Attribution sheet view model writes via UPSERT during sheet session) | Count of user-accepted/rejected AI suggestions; powers Mary's pre-committed kill criteria (Decision 5.7) and the trust-calibration footer (UX spec Step 10 Round-2) |
| `transcription_suggestions_*` columns | (declared, no MVP writer per Decision 5.5 Phase 3) | Slot reserved for v1.x transcription reviewer |
| `audio_retention_status_at_30d` | (v1.1) periodic background job | One of `deleted_after_grace` / `kept_explicit` / `unverified_held` |

UPSERT pattern: `INSERT INTO telemetry(meeting_id, ...) VALUES (?, ...) ON CONFLICT(meeting_id) DO UPDATE SET ...`. SQLite + WAL handles cross-process UPSERT atomicity; verify GRDB busy-timeout setting handles the rare contention case (Decision 2.1 GRDB rules).

**Logging via `os_log` with redaction (NFR-S7):**

A `Log` facade in the shared SwiftPM library wraps `os_log` and enforces redaction:

```swift
public enum LogSensitivity {
    case publicSafe       // bundle id, stage name, meeting id, durations, exit codes
    case sensitive        // anything else: API responses, transcript content, attendee emails, file paths inside user dirs
}
```

The facade routes `publicSafe` fields through `%{public}@` and `sensitive` fields through `%{private}@`. File-output logs (if/when introduced) bypass `os_log`'s privacy modifiers, so the facade also redacts at message construction for any field tagged `sensitive`. API keys, OAuth tokens, and Anthropic response bodies are NEVER passed to the facade in any form — they're scrubbed at the source.

**Privacy and locality (binding):**

- All telemetry writes are local SQLite. **No remote endpoint exists. No third-party crash reporter is used.** (NFR-S8, NFR-Pr2.)
- Logs go to `os_log` (subsystem `com.auricle.app`, category-per-stage); inspectable via `log show --predicate 'subsystem == "com.auricle.app"'` and never leave the machine.
- The user can query their own telemetry via direct SQL against `auricle.sqlite3`. A v1.1+ `auricle stats` verb may surface common queries; not in MVP binding contract.
- Anthropic API responses contain cost / token metadata; that metadata is captured locally but the API call payload itself (transcript text + glossary) is the only off-machine flow per NFR-Pr1.

#### Decision 4.6: Failure visibility surfaces (the Sally + Mary unification)

Group 4 was nearly silent on how failure states are shown to the user; this decision makes the surfaces explicit.

**Window architecture (UX spec Step 9 Principle 8 lock-in):** auricle's primary surface is a **single main window**. Modal workflow tasks during the pipeline (notably speaker attribution) appear as **sheets attached to the main window** — never as separate `NSWindowController`-per-meeting windows that auto-foreground. Multi-meeting concurrency is handled by a **sheet queue + banner counter** (one sheet at a time; banner shows pending count; user dismisses or completes the current sheet, then summons the next via banner action or row click). Notifications fire for `awaiting_attribution` and `summary_ready` transitions; the GUI **never auto-foregrounds** — the user always initiates engagement. Rarely-used user-initiated surfaces (Settings via Cmd-, ; Doctor) remain conventional separate windows. This **supersedes** the prior assumption (carried in earlier project-structure trees) of a `App/Auricle/AttributionWindow/` separate-window target — see updated Project Structure tree below.

**MVP failure-visibility surfaces:**

| Surface | Trigger | Behavior |
|---|---|---|
| **Per-meeting state chip** in main window's meeting list | Always, for every meeting | Color-coded by `FailureCategory`: green (verified / retention-expired terminal-success), blue (in-flight active state like `transcribing` / `reviewing_diarization`), yellow (any `awaiting_*`), amber (any `*_failed` transient — retryable), red (any `*_failed` permanent), grey (`silent`, `discarded`). Color is never the sole conveyor — chip carries glyph + label per NFR-A3. |
| **Row-expand inline operations console** (UX spec Step 9 IA) | User clicks the chevron on a meeting row | In-row pipeline timeline (per-stage glyph for capture / transcribe / review-diarization / attribute / summarize / persist), contextual actions (Retry, Discard, Open attribution), retention countdown, copy-pasteable `log show` line. Replaces the prior assumption that drill-in required a separate window. |
| **Attribution sheet** (UX spec Step 10 Consolidated Spec) | User clicks "Open attribution" in row-expand OR clicks the "Attribute next ›" banner action | `.sheet(item: $attributingMeetingID)` rises from the main window with the consolidated Attribution UI (calendar coverage strip, speaker rows as visual center of gravity, **transcript-pane disclosure collapsed by default with the label *"Review transcript paragraph-by-paragraph (N with hints)"*** per UX spec Step 10 Round-2 hierarchy refinement, AI hints rendered inside the disclosure when expanded, trust-calibration footer, asymmetric bottom-button hierarchy: `[Continue]` primary `.borderedProminent`, `[Save for later]` secondary `.bordered`, `[Publish unattributed]` tertiary text-link). Approximate sheet size 600×700, content-fit, non-resizable. Dismiss via `[Save for later]` / Esc / Cmd-W preserves partial state via incremental `attribution.json` writes (debounced 500ms). |
| **Multi-meeting attribution banner** (UX spec Step 9) | ≥2 meetings simultaneously in `awaiting_attribution` | "⏳ N meetings awaiting your attribution — Attribute next ›". Click banner action OR a specific row → sheet rises; after dismissal, banner updates count. Never auto-foregrounds. |
| **Inline "Retry now" button** per failed-state row | Meeting in any transient `*_failed` state | Triggers `auricle run <id>` equivalent; streams progress |
| **On-launch banner** | App launch when any `awaiting_verification` > 24h OR any `*_failed` exists | Non-modal banner with count + click-through to highlighted meetings |
| **`auricle doctor`** (per Decision 4.4) | On-demand | Includes failure / pending counts in the summary |
| **`auricle list` default sort** | On-demand | Non-terminal-stale meetings at top with state annotation. UI sort priority (UX spec Step 9): `recording > awaiting_attribution > awaiting_verification > *_failed (transient before permanent) > transcribing|reviewing_diarization|summarizing > published > verified > retention_expired > silent|discarded`, then by `capture_started_at desc`. |
| **Trust-calibration footer in Attribution sheet** (UX spec Step 10 Round-2) | Sheet open, `diarization_review.enabled = true`, telemetry has data | Subtle ambient line: "🤖 Reviewed N segments, flagged M · Accept rate: X/Y this week". Reads from `telemetry.diarization_suggestions_*` columns. Hidden when AI flag is off or no data. |
| **Rolling 30-day cost widget** (UX spec Step 10 Round-2 Mary) | Always (small footer line beneath meeting list, in `RollingCostFooterView.swift`) | Aggregate API cost over rolling 30 days, broken down by stage (`summarize`, `reviewing_diarization`). Catches Opus drift, model-swap surprises, runaway summary-retry costs. **Aggregation contract:** view model issues two sibling queries against `telemetry` joined to `meetings` on `meeting_id`, filtered by `meetings.created_at > datetime('now', '-30 days')` (SQLite UTC-aware) — `SELECT SUM(cost_usd) FROM telemetry t JOIN meetings m ON t.meeting_id=m.id WHERE m.created_at > datetime('now','-30 days')` for summarize spend; `SELECT SUM(diarization_review_cost_usd), summarization_model || '|' || diarization_review_model AS combo FROM telemetry t JOIN meetings m ON t.meeting_id=m.id WHERE m.created_at > datetime('now','-30 days') GROUP BY combo` for the reviewer column with model-swap visibility. **Empty-state rendering:** if both sums are NULL or zero, footer reads *"$0.00 spent in last 30 days"* (NOT hidden — silence is a signal). **Refresh:** view-model recomputes on `meetings.updated_at` change via `GRDB.ValueObservation` (in-process, in-GUI; this is the one file-watch path that legitimately uses ValueObservation since it's GUI-process-local read-only telemetry). **Model-swap surprise display:** if more than one distinct `combo` value appears in the window, footer surfaces a "→" delimiter showing the most recent two (e.g. *"Last 30d: $14.20 — opus-4-7+haiku-4-5 → opus-5-0+haiku-4-5"*). |
| **Stale-active-state synthesized failure** (Round-2 lock-in) | Active "_ing" state held longer than the per-stage budget (per Decision 4.2 wall-clock budgets table) | `Orchestrator` periodic sweep calls `StageRunner.synthesizeFailure(...)` → `stage_events.failed` row written, meeting transitions to `*_failed`, chip flips blue → amber, on-launch banner picks it up. For `reviewing_diarization` specifically, the "synthesis" is the benign-timeout pass-through to `awaiting_attribution` rather than a `*_failed` transition. **This is the load-bearing fix for the silent-spinner UX failure mode** — the user never sees an "in-flight" chip lying about a dead subprocess for longer than its budget. |

**v1.1 additions:**
- **Dock badge** (FR16): numeric count of stale-pending items
- **Menu bar status** (FR8): small dot reflects worst state across all meetings
- **`auricle stats` CLI verb**: surfaces telemetry rollups (drop rates, costs, latencies over time)

The principle: **the user can never discover that a meeting was lost only by accidentally noticing it.** Every failure mode has at least one always-on surface that makes it visible without explicit user search.

### Group 3: Summarization Contracts

This group covers how the summarize stage consumes a transcript and produces grounded action items + decisions. Architecture is no longer spike-gated — a four-agent roundtable resolved the prior Citations-vs-substring spike question by committing to a dual-strategy architecture with a smoke-test inside the summarize-stage implementation story. Substantive findings folded in include the normalized `GroundingPointer` shape, the orchestrator-mediated fallback pattern, the canonicalization invariant as a build-time contract, the trust-calibration requirement (J1.5) surfaced by Mary, and the prompt-builder + snapshot-test discipline against drift between strategies.

#### Decision 3.1: `SummarizerStrategy` protocol and normalized output

The summarize stage consumes a transcript and a vault-glossary; it produces a `SummaryWithGrounding` value. Concrete strategies (Claude+Citations, Claude+substring, Ollama/MLX local-LLM) implement the same protocol and produce the same output shape.

```swift
public protocol SummarizerStrategy {
    func summarize(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig
    ) async throws -> SummaryWithGrounding
}

public struct SummaryWithGrounding: Codable {
    public let schemaVersion: Int  // = 1
    public let summary: String                  // one-paragraph narrative
    public let actionItems: [GroundedItem]
    public let decisions: [GroundedItem]
    public let groundingMethod: GroundingMethod // 'citations' | 'substring' — populated by the strategy
    public let cost: SummarizerCost             // tokens / cost_usd / thinking_tokens
}

public struct GroundedItem: Codable {
    public let text: String
    public let grounding: GroundingPointer  // ALWAYS the normalized shape, regardless of which strategy produced it
}

/// Normalized pointer into the canonical transcript. Both Citations and substring strategies
/// resolve to this shape AT THE VALIDATOR BOUNDARY. The persist stage and renderer never
/// see anything else.
public struct GroundingPointer: Codable {
    public let transcriptStart: Int   // character offset (see canonicalization invariant)
    public let transcriptEnd: Int     // character offset, exclusive
    public let sourceMethod: GroundingMethod  // telemetry only — 'citations' | 'substring'
}

public enum GroundingMethod: String, Codable {
    case citations
    case substring
}
```

**Why the normalized shape (vs. a tagged union):** Winston's catch — carrying both `cited_text` *and* `quote_string` as parallel optional fields in the domain model is "indecision frozen in JSON." Both validators resolve to character-range offsets at the validator boundary; the renderer always reads `transcript[start..<end]` regardless of which strategy produced the pointer. `sourceMethod` is metadata for telemetry, not a control flag for downstream code.

**Why no separate "raw response" field:** strategies translate from their own raw API output (Anthropic Citations response, free-form quote string, local-LLM JSON, etc.) into the normalized shape inside their own implementation. Nothing outside the strategy needs to know the raw response format. This satisfies LSP — substituting one `SummarizerStrategy` for another genuinely produces equivalent downstream behavior.

#### Decision 3.2: Two grounding strategies — Citations primary, substring as v1.1 + fallback

**`ClaudeCitationsSummarizer` (MVP default):**
- Calls `messages.create` on `claude-opus-4-7` with the transcript provided as a Document with `citations: { enabled: true }`
- Asks for action items and decisions in structured JSON; each item must include a `citations` array referencing the document
- Receives Anthropic-constructed `CitationCharLocation` objects with `start_char_index` / `end_char_index` (verify against current API docs at implementation time — these are offsets into the canonical transcript representation that was submitted; encoding TBD by API spec, see canonicalization invariant below)
- Maps each `CitationCharLocation` directly to a `GroundingPointer { transcriptStart, transcriptEnd, sourceMethod: .citations }`
- Validates each pointer via `CitationGroundingValidator` (sanity-checks bounds; well-formed responses always pass)

**`ClaudeSubstringSummarizer` (MVP fallback + v1.1 local-LLM path):**
- Calls `messages.create` on `claude-opus-4-7` (same prompt skeleton, no Citations enabled) — asks for items with a `source_transcript_quote` field of type string
- Maps each returned quote string to a `GroundingPointer { transcriptStart, transcriptEnd, sourceMethod: .substring }` by performing literal substring search in the canonical transcript
- Validates via `SubstringGroundingValidator`: items where the quote is not found verbatim in the canonical transcript are dropped, with the drop reason logged at `warn` level and recorded in `telemetry.quote_validation_drop_count`

**`OllamaSummarizer` (v1.1+, deferred):** Same shape as `ClaudeSubstringSummarizer` but talks to a local Ollama HTTP endpoint instead of Anthropic. Uses `SubstringGroundingValidator`. Out of MVP scope; mentioned for forward-compat.

**Both Claude strategies share a single `SummarizationPromptBuilder`** (Amelia's recommendation against prompt drift): system prompt, glossary injection, attendee context formatting are all generated by one builder. The two strategies differ ONLY in (a) whether Citations is enabled in the API call and (b) what shape the output JSON requests. Snapshot tests on the emitted prompt string fail the build if the two strategies' prompts drift apart in the shared portions.

#### Decision 3.3: Orchestrator-mediated fallback (NOT in-strategy retry)

The fallback decision lives in a `SummarizerOrchestrator` in the summarize stage's entrypoint, NOT inside `ClaudeCitationsSummarizer` itself (Amelia's structural call — keeps strategies single-responsibility per SOLID-I; strategies never know about each other).

```swift
public actor SummarizerOrchestrator {
    let primary: SummarizerStrategy
    let fallback: SummarizerStrategy?
    let telemetry: TelemetrySink

    public func summarize(...) async throws -> SummaryWithGrounding {
        do {
            let result = try await primary.summarize(...)
            telemetry.record(grounding: .citations, /* ... */)
            return result
        } catch let error as SummarizerError where error.isFallbackEligible {
            guard let fallback else { throw error }
            telemetry.record(fallbackTriggered: error)
            let result = try await fallback.summarize(...)
            telemetry.record(grounding: .substring, /* ... */)
            return result
        }
    }
}
```

Typed errors that trigger fallback (and only these):
- `SummarizerError.citationsUnavailable` — API returned a response with no Citations data when Citations was requested
- `SummarizerError.malformedResponse` — Citations response shape didn't validate
- `SummarizerError.rateLimited` — throughput limit hit
- `SummarizerError.featureToggleDisabled` — Anthropic disabled Citations on this model (defensive against future API changes)

Errors that do NOT trigger fallback (re-thrown):
- Network timeouts (handled by Decision 4.2's retry policy at the HTTP layer)
- Auth errors (configuration problem, surface to user)
- Quota / billing errors (J6 hidden journey from Group 4 Open Resolutions; surface to user with `auricle keep` permission to top up and resume)

Fallback is bounded to one attempt. If fallback also fails, meeting transitions to `summarization_failed` per Decision 4.1. NFR-C1 cost ceiling applies across primary + fallback; the orchestrator passes a remaining-budget hint to the fallback strategy.

#### Decision 3.4: Canonicalization invariant (Winston's load-bearing risk; build-time contract)

**The bug to prevent:** Citations API returns offsets into the text the API received; substring matches against the transcript stored on disk. If those two representations diverge in whitespace, line breaks, speaker labels, timestamp interpolation, or Unicode normalization form, the two validators will silently disagree about what character offset 1,247 refers to.

**The invariant:** there is exactly ONE canonical transcript representation. It is:
- Generated once by the transcribe stage and written atomically to `transcript.json` in the cache-dir
- The text passed to Anthropic's Citations API
- The text searched by `SubstringGroundingValidator`
- The text from which the renderer extracts cited spans for the vault note (`transcript[start..<end]`)

**Implementation rules:**

1. The transcribe stage emits a `CanonicalTranscript` value containing the transcript text in a single explicit form: NFC-normalized Unicode, LF line endings, no leading/trailing whitespace per line, speaker labels prefixed as `<Speaker_N>: ` at the start of each utterance (no other formatting).
2. Character offsets are **UTF-8 byte offsets into the NFC-normalized representation.** This is verified against Anthropic's API spec at implementation time — if Anthropic uses a different convention (UTF-16 code units, codepoints, or graphemes), the canonical representation includes a translation step in `CanonicalTranscript` that exposes the same offset semantics Anthropic returns. (Verify at implementation time; documented as a per-stage `verify` item per Decision 4.5.)
3. **Build-time contract test** (`tests/CanonicalTranscriptContractTests.swift`): asserts that the same `CanonicalTranscript` value, when serialized to JSON and re-deserialized, produces byte-identical text; that the API-submission representation matches the on-disk representation; and that the substring validator's offset interpretation matches the Citations-validator's offset interpretation. **Build fails if these invariants are violated.**
4. **Cross-mode fixture test:** golden transcript fixtures with hand-curated expected items run through BOTH grounding strategies (with stubbed LLM responses producing equivalent content via different shapes) and assert byte-identical renderer output. This proves the swap is real, not aspirational.

This is the single most important architectural detail of Group 3. Without it, the dual-strategy approach is unsound; with it, it is genuinely robust.

#### Decision 3.5: Claude prompt skeleton, glossary injection, prompt caching

**Prompt caching strategy** (NFR-C1 cost ceiling depends on this — tiers per Decision 5.6):

| Component | Cached? | Cache TTL | Why |
|---|---|---|---|
| System prompt (instructions, output format) | Yes — always cached | Default (5 min within session, longer with explicit cache control) | Stable across all meetings; recoupable cost |
| Glossary | Yes — cached when stable | Per-session | Vault wikilinks change slowly; cache hit on most consecutive meetings |
| Attendee context | Yes — cached when stable | Per-session | Same attendees often recur in 1:1s and standing meetings |
| Transcript | **No** — never cached | n/a | Unique per meeting |

Prompt caching uses Anthropic's `cache_control` blocks (Anthropic API feature). Estimated savings: ~50% input-token cost on consecutive calls within a session window. Verify exact cache-token-cost ratio at implementation time.

**System prompt skeleton (illustrative; final wording during build):**

```
You extract structured action items and decisions from a meeting transcript.

Rules:
1. Every action item must be assigned to a specific person mentioned in the transcript.
2. Every action item and decision must be supported by a verbatim quote from the transcript [Citations path: provided as a citation pointer / Substring path: provided as a verbatim string in `source_transcript_quote`].
3. If you cannot find a verbatim grounding, omit the item. Do not paraphrase grounding.
4. Use the glossary below to disambiguate names and terms; if a term in the transcript matches a glossary entry, render it accordingly.
5. Output a one-paragraph summary, then arrays of action items and decisions.

[Citations path adds: Use Anthropic Citations to ground each item.]
[Substring path adds: Each item must include a `source_transcript_quote` field reproducing the exact transcript text, character-for-character including punctuation. Do not normalize, expand contractions, or remove disfluencies.]
```

**Glossary injection format:**

The vault-glossary builder (FR55–FR57) extracts wikilink-target page names from the user's vault, scoped where possible to attendees and topics of the current meeting. The glossary is injected as a structured block in the prompt:

```
Glossary (terms from your vault, prefer these spellings):
- People: [[Ben Smith]], [[Priya Patel]], [[Andrew Underwood]]
- Projects: [[chicken-palace]], [[GL1200]], [[meshcore]]
- Concepts: [[packet radio]], [[AX.25]]
```

Glossary terms are wrapped in `[[wikilink]]` form even in the prompt (matches vault rendering; reduces post-processing). The summarizer is instructed to use these spellings for matching terms in the transcript.

**Cost-friendly call shape:** glossary scoping (FR56) keeps glossary token counts bounded (~200 tokens typical, vs. unscoped vault-wide enumeration which could be 5000+). The `cache_control` mark sits between glossary and transcript so glossary caches but the transcript is fresh per call.

#### Decision 3.6: Smoke-test protocol (Story N hour 1; locks the default before dogfood)

The Citations-vs-substring choice is not deferred to "dogfood guesswork" — there is an explicit smoke-test moment inside the summarize-stage build story.

**Trigger:** First hour of the summarize-stage implementation story, after the strategy interface and both implementations are functional.

**Inputs:** ≥5 of Andrew's existing meeting recordings (already on disk; this is the first time any auricle build phase requires input from real meeting data). Required mix: ≥1 1:1 (≤3 attendees) AND ≥1 multi-party (≥4 attendees). The remaining 3+ can be any mix.

**Procedure:** Each transcript is run through `ClaudeCitationsSummarizer` AND `ClaudeSubstringSummarizer` via the same `SummarizationPromptBuilder`-generated prompt. Outputs are compared on:

| Metric | What it measures |
|---|---|
| Drop rate | Items dropped by the validator (each strategy's `quote_validation_drop_count`) |
| Recall | Items present in Andrew's memory of the meeting that survived to the rendered note |
| Precision | False-keeps — items the validator accepted that don't actually represent real commitments |
| Cost | API tokens including extended-thinking output |
| Qualitative | Did the grounded quote read sensibly when rendered as a `> source quote` blockquote? |

**Default-flip rule (Mary's amendment, trust asymmetry):**
- **If Citations matches or beats substring on every transcript:** Citations is locked as MVP default.
- **If substring catches anything Citations missed (any false-drop, any recall miss) on any transcript in the smoke-test set:** default flips to substring; revisit before dogfood begins. The trust-poison cost of a single missed commitment in dogfood vastly exceeds the cost of running with a slightly-less-capable validator that doesn't drop real items.

**Outcome documentation:** smoke-test results are recorded in a build log (`tests/fixtures/smoke-test-results.md` or similar) — captures which transcripts were used, the metric scores, and the rationale for the default-validator choice. Future-Andrew (or future maintainers) can re-run the smoke-test set when Anthropic ships new Citations behavior or when prompt design evolves.

#### Decision 3.7: J1.5 trust-calibration surface (Mary's hidden requirement)

J1's success criterion is "Andrew defaults to auricle's notes by month 2." That requires Andrew to know how often the validator is right, not just that it's right on average. Trust is calibrated, not binary.

**Required surfaces (preserving DP2 — no confidence flags in vault frontmatter):**

| Surface | Tier | Content |
|---|---|---|
| `auricle status <id>` (MVP) | MVP | Shows `grounding_method` for the meeting, total items, drop count, and a copy-pasteable `log show` invocation that surfaces per-item grounding details (item text + grounding pointer + transcript span text) |
| `auricle logs <id> --stage summarize` (v1.1) | v1.1 | Direct surfacing of per-item grounding details without needing to construct a `log show` command. JSON output with `--json`. |
| `auricle stats` (v1.1+, FR-equivalent forward-compat) | v1.1+ | Aggregate drop rates / costs / latencies by grounding_method over time |
| Telemetry in `telemetry` table | MVP | `grounding_method`, `quote_validation_drop_count`, populated per Decision 4.5 |

The vault note itself (per DP2) carries no confidence indicators — items either survived grounding validation (rendered) or were dropped (logged at `warn` level, never written). The audit surface lives entirely in the CLI inspection path, separate from the user's reading flow.

**Cross-cutting concern alignment:** this decision explicitly satisfies the J1.5 requirement surfaced in the architecture roundtable and recorded in PRD §Open Resolutions. No new cross-cutting concern is added (the existing #11 "vault frontmatter is for vault consumers; SQLite is for auricle's operational state" governs — audit data is operational state, accessed via auricle's CLI, not via vault tooling).

#### Decision 3.8: Long-context drift detection (FR34, v1.1)

Forward-compat mention; not implemented at MVP.

**FR34** says auricle can detect long-context drift on transcripts ≥60 minutes (token count + summary content density) and flag suspiciously thin summaries. v1.1 implementation:

- After summarize completes, compute `summary_density = (summary_word_count + sum(action_item_word_counts) + sum(decision_word_counts)) / transcript_word_count`
- Compute baseline density from telemetry rollups across past meetings of similar duration
- If a meeting's density is < N standard deviations below baseline AND transcript word count ≥ 60-minute threshold (~7500 words at typical speech pace), flag with `auricle/needs-review` frontmatter tag and a warn-level log entry
- The exact threshold N is empirically tuned during v1.1 build; documented as an Open Resolution

**MVP behavior:** no drift detection. Summaries are accepted regardless of density. The known failure mode (Claude producing thin summaries on long meetings) is monitored manually via dogfood. If the failure rate is high enough to warrant earlier action, drift detection can be promoted from v1.1 to a late-MVP addition (per the additive-not-binding rule).

#### Decision 3.9: Local-LLM strategy contract (FR33, v1.1+)

Forward-compat. The `OllamaSummarizer` (and a possible future `MLXSummarizer`) implements the same `SummarizerStrategy` protocol with these constraints:

- Outputs must conform to the same `SummaryWithGrounding` shape with `groundingMethod: .substring`
- Uses the same `SummarizationPromptBuilder` for prompt generation (snapshot tests prevent drift)
- Uses `SubstringGroundingValidator` (no Citations API on local LLMs)
- Cost is $0 (NFR-C3)
- Latency target: comparable to or better than Claude path (otherwise no v1.1 promotion)

The v1.1 build phase determines whether local LLMs hit the quality bar; if yes, the strategy ships and becomes a config option (NFR-I8). Until then, only the Claude strategies exist; the protocol is shaped to accommodate the future arrival without architectural change.

### Group 5: AI-Assisted Correction (the Product Category)

This group treats AI-assisted correction as a **product category** (per UX spec Step 10 "AI Correction as a Product Category — Phased Roadmap"), not a single feature. The category has three siblings sharing one architectural pattern: **jargon correction** (Phase 1, MVP, enabled — already wired into the `summarize` stage via `GlossaryInjector`), **diarization correction** (Phase 1, MVP, behind flag default-off — the new architectural surface this group specifies), and **transcription correction** (Phase 3, v1.x — declared, no MVP impl). A future Phase 4 unifies all three into a single Claude call.

The user's elected build path is **Path C: build all architectural slots in MVP, with the diarization-review feature behind a flag default-off** for iterative validation. This group locks the slots so the Phase 2 enable-flip is a config change, not a refactor.

#### Decision 5.1: `AIReviewerStrategy` protocol family and shared output shape

The reviewer family is a SOLID-I sibling of `SummarizerStrategy` (Group 3). Concrete reviewers consume cache-dir artifacts and produce a `*_suggestions.json` artifact that downstream UI views consume.

```swift
public protocol AIReviewerStrategy {
    associatedtype Input: Codable
    associatedtype Output: Codable & Suggestion

    func review(
        input: Input,
        config: AIReviewerConfig
    ) async throws -> AIReviewerResult<Output>
}

public protocol Suggestion: Codable {
    var suggestionId: String { get }   // stable id for telemetry + per-suggestion Apply tracking
    var reasoning: String { get }       // human-readable explanation rendered in expandable AI hint chip
}

public struct AIReviewerResult<O: Suggestion>: Codable {
    public let schemaVersion: Int
    public let suggestions: [O]
    public let cost: AIReviewerCost     // input_tokens, output_tokens, cost_usd, model_id
    public let reviewedSegmentCount: Int  // populates the trust-calibration footer "Reviewed N segments, flagged M"
}
```

**Three sibling concrete protocols (declared in MVP, populated per-phase):**

| Protocol | Input | Output `Suggestion` shape | Cache artifact | Phase |
|---|---|---|---|---|
| `DiarizationReviewerStrategy` | `(CanonicalTranscript, DiarizationArtifact)` | `DiarizationSuggestion { suggestionId, reasoning, kind: .underSegmentation/.overSegmentation, segmentId, proposedSplits[] }` | `diarization_suggestions.json` | Phase 1 (concrete: `ClaudeDiarizationReviewer`, Haiku-default, flag-controlled) |
| `TranscriptionReviewerStrategy` | `(CanonicalTranscript, AudioFingerprint)` | `TranscriptionSuggestion { suggestionId, reasoning, charRange, proposedReplacement }` | `transcription_suggestions.json` | Phase 3 (declared interface only; no MVP impl) |
| `JargonCorrectionStrategy` | `(SummaryDraft, Glossary)` | `JargonCorrection { suggestionId, reasoning, charRange, originalSpan, correctedSpan }` | (inline within `summary.json`; no separate file — corrections happen during the summarize call) | Phase 1 (wraps existing `GlossaryInjector`; no behavior change in MVP) |

**Why a family rather than three independent strategies:** all three share (a) the same prompt-caching pattern with a stable system prompt + per-meeting variable input, (b) the same "user accept/reject + telemetry rollup" UX pattern, (c) the same `*_cost_usd` + `*_model` telemetry contract, and (d) the same suggestions-are-always-additive cache-immutability invariant (Decision 5.3). Naming the family makes the Phase 4 unification (single Claude call producing all three suggestion types) a contract-preserving evolution rather than a re-architecture.

#### Decision 5.2: Concrete `ClaudeDiarizationReviewer` (Haiku-default, flag-controlled)

The MVP concrete impl of `DiarizationReviewerStrategy`:

- **Model:** `claude-haiku-4-5` by default (config: `diarization_review.model`). Haiku is the cost/latency target; Opus is overkill for "are these two segments the same voice?" pattern-matching.
- **Feature flag:** `diarization_review.enabled` (config; default `false` per Path C). When off, the `reviewing_diarization` state is still entered but the strategy short-circuits in <100ms with an empty `AIReviewerResult` and a telemetry payload `{model_id: "flag_off", cost_usd: 0, suggestions_count: 0, review_skipped: true}`. The Phase 2 enable-flip is a single config change.
- **Prompt skeleton:** structured prompt asking Claude to flag segments where (a) acoustic similarity hints two speakers labeled as one (under-segmentation) — propose splits; or (b) acoustic similarity hints one speaker labeled as two (over-segmentation) — propose merge.
- **Prompt caching:** system prompt + diarization-review instructions are `cache_control`-marked (Anthropic API feature). Per-meeting transcript+diarization is the variable portion. Estimated cost: ~$0.02–0.05 per 30-min meeting (vs. ~$0.40–0.50 for Opus summarize); see Decision 5.6 cost contract.
- **Output:** structured JSON with one suggestion per flagged segment. Each suggestion carries a stable `suggestionId` (so per-suggestion Apply telemetry survives sheet reopens).
- **HTTP infrastructure reuse:** shares `AnthropicHTTPClient` and `KeychainAPIKey` with `ClaudeSummarizer` (target `ClaudeAIReviewers` depends on the same primitives; no duplicate HTTP layer).
- **One-shot, not streaming (Amelia's MVP scoping):** Haiku response for ~80 segments is ~3s; render when complete. Streaming UI is a Phase 2+ refinement (~2 days saved at MVP).

#### Decision 5.3: Subprocess isolation + cache-artifact immutability invariant

**Subprocess isolation (Winston's Round-2 lock):** the `reviewing_diarization` stage runs in a **dedicated subprocess** spawned by the Orchestrator AFTER the WhisperKit transcribe+diarize subprocess terminates. Sequencing:

```
WhisperKit subprocess starts → transcript.json + diarization.json written → WhisperKit subprocess exits (frees ~2-4GB)
  ↓
AI Reviewer subprocess starts → reads transcript.json + diarization.json → calls Anthropic Haiku → writes diarization_suggestions.json → exits
  ↓
Orchestrator: meetings.state = 'awaiting_attribution'
```

**Why a separate subprocess (not in-GUI-process, not bundled with WhisperKit):**

- Three independent failure modes — WhisperKit OOM, Anthropic network, malformed Claude response — get clean isolation. WhisperKit OOM cannot crash the AI reviewer mid-call; an Anthropic 503 cannot leave WhisperKit's 4GB resident.
- Memory hygiene: WhisperKit's ~2-4GB working set is freed before the network call; ANE doesn't sit idle holding state during a slow HTTPS round-trip.
- The reviewer subprocess is small and cheap to spawn (~50ms cold start; the 90s wall-clock budget per Decision 4.2 has plenty of headroom).
- Bundled invocation: `auricle-cli __internal-stage review-diarization <id> --worker-protocol-version 1` (hidden subcommand pattern from Decision 1.1 / Subprocess Boundaries).

**NFR-P9 memory contract (Attribution sheet open-state, ≤200 MB ceiling):**

| Component | Budget | Notes |
|---|---|---|
| Shared `AVAudioFile` handle for paragraph playback | <5 MB | Single file; `framePosition` per play (Amelia: cold seek <20ms on SSD; meets NFR-P7 ≤200ms). NOT pre-loaded `AVAudioPCMBuffer` — that pattern blows the budget. |
| Speaker representative snippet buffers | ~5 MB total | Pre-loaded `AVAudioPCMBuffer` per speaker; ~7 speakers × short clips. Worth caching since they're re-played frequently. |
| `attribution.json` + `diarization_suggestions.json` view model state | <10 MB | In-memory `@Observable AttributionViewModel`; bounded by transcript size. |
| SwiftUI view-tree + tokens + lazy paragraph rows | <70 MB | LazyVStack defers off-screen paragraph allocation. |
| Headroom (system, Foundation, GRDB connections, AppKit shims) | balance to 200 | The remaining ~110 MB. |
| **Working target** | **~98 MB** | Per Amelia's UX-spec Round-2 lock; comfortably under NFR-P9 ceiling. |

The budget is enforced by a snapshot test in `Tests/AttributeTests/` that opens the sheet against a 30-min-meeting fixture and asserts `mach_task_basic_info.resident_size < 200 MB`. Builds fail on regression.

**Cache-artifact immutability invariant (Winston's Round-2 lock):** `transcript.json` and `diarization.json` are **immutable** cache artifacts post-write (per Decision 1.3). AI-applied splits do **NOT** modify these files. Instead, the AI's proposals live in `diarization_suggestions.json` (read-only, written once by the reviewer); any user-applied splits live in `attribution.json` as a `segment_splits` field (Decision 5.4). The renderer composes the rendered transcript view as a **pure function** over `(diarization.json, attribution.overrides, attribution.splits)` — idempotent, fully testable, no hidden mutation chain.

This invariant matters because:
1. Re-running `reviewing_diarization` (e.g., on a model upgrade) must be safe — the stage reads `transcript.json` + `diarization.json`, not its own previous output.
2. Re-running `attribute` (e.g., `auricle run <id> --reattribute`) must be safe — the attribution overrides + splits replay deterministically.
3. The Phase 4 unified reviewer can produce a single `unified_suggestions.json` consuming the same immutable cache inputs without touching any prior artifact.

A build-time test (`Tests/AIReviewerInterfaceTests/ImmutabilityContractTests.swift`) asserts that no reviewer or stage code path opens `transcript.json` or `diarization.json` for write; lint-rule enforcement supplements at code-review time.

**Subprocess → GUI handoff contract (race-free, Amelia Round-2 lock-in):**

The GUI Attribution sheet may open before, during, or after the `reviewing_diarization` subprocess finishes. The handoff must not depend on event-ordering luck.

| Concern | Rule |
|---|---|
| **Subprocess write** | Reviewer subprocess writes `diarization_suggestions.json` via `AtomicWriter` (Cross-Cutting Concern #3 — `temp → fsync → rename`) so the file appears atomically. THEN, in the same Txn B as the stage-completion `stage_events` row, it bumps `meetings.updated_at` (the trigger handles this on any UPDATE) and transitions `meetings.state` to `awaiting_attribution`. **The SQLite write is the authoritative "ready" signal** — the file's existence on disk is the secondary signal. |
| **GUI read at sheet-open** | Sheet view model `init` runs a single check-then-watch sequence: (a) read `meetings.state` — if it's `awaiting_attribution` or beyond, the suggestions file is guaranteed to exist (or be the empty-stub when flag-off); read it directly. (b) If the meeting is still `reviewing_diarization`, render the sheet with a "🤖 analyzing…" indicator at the top of the (collapsed) transcript pane and start watching. |
| **File-watch target paths (two distinct watchers)** | **Watcher A — cache-dir `diarization_suggestions.json`:** `DispatchSource.makeFileSystemObjectSource` on the parent cache-dir for `.create`/`.delete` (file may not exist yet) AND on the file itself for `.write` once it appears. 100ms debounce. Triggered to re-read suggestions content. **Watcher B — SQLite `meetings.updated_at` for state transitions:** `GRDB.ValueObservation` on `meetings WHERE id = ?` (in-process, GUI-only — this is the one observation pattern that legitimately uses ValueObservation since it watches in-process DB writes from other GUI work AND cross-process subprocess writes via WAL; combined with `DispatchSource` on `db.sqlite3-wal` for cross-process change detection per Decision 2.1's GRDB rules). The two watchers are independent — Watcher A re-renders the suggestions content; Watcher B updates the sheet's "🤖 analyzing…" → "ready" affordance. |
| **Race-loss fallback** | If Watcher A misses the `.create` event (DispatchSource race on parent-dir watching when the file is created near sheet-open), Watcher B catches state advance to `awaiting_attribution` and triggers a one-shot "read the file directly" path that bypasses the file watcher. Belt + suspenders: state advance is the canonical signal; file watch is the latency optimizer. |
| **CLI parity** | `auricle attribute <id>` from a terminal session opens the GUI sheet (per Decision 1.5 — interactive default); the sheet's view-model init runs the same check-then-watch sequence. CLI's `--batch` mode reads the suggestions file directly off `meetings.state` advance and never starts a watcher. |

**Telemetry write-authority partitioning (race-free UPSERT, Amelia Round-2 lock-in):**

`telemetry` columns within the AI-reviewer category are split into two non-overlapping writer regions to avoid UPSERT conflicts between the subprocess and the GUI:

| Column | Writer | Lifetime |
|---|---|---|
| `diarization_suggestions_count`, `diarization_review_cost_usd`, `diarization_review_model` | **Reviewer subprocess only** (`reviewing_diarization` stage) | Written once at stage completion via UPSERT; never updated thereafter for that meeting |
| `diarization_suggestions_applied_count`, `diarization_suggestions_rejected_count` | **GUI Attribute stage only** (Attribution sheet view model) | Written incrementally during sheet session via UPSERT; debounced 500ms; final write on sheet dismissal |

Each column belongs to exactly one writer. `INSERT ... ON CONFLICT(meeting_id) DO UPDATE SET <only-this-writer's-columns>` ensures atomic per-writer updates without stomping the other writer's columns. SQLite + WAL handles cross-process UPSERT atomicity. The same partitioning rule applies to future correction-category siblings (`transcription_suggestions_*`): the reviewer subprocess writes count/cost/model; the GUI sheet writes applied/rejected. **No column has two writers.**

#### Decision 5.4: `attribution.json` schema extension (`segment_overrides` + `segment_splits`)

The Attribution sheet's three rename mechanics (default global rename, per-paragraph reassign, AI-applied splits — UX spec Step 10) require schema extensions to `attribution.json`. Schema is **additive** (existing readers ignore unknown fields per the additive-not-breaking rule from Decision 2.2's frontmatter versioning).

```json
{
  "schemaVersion": 1,
  "speakers": {
    "Speaker_1": "[[Andrew Underwood]]",
    "Speaker_2": "[[Ben]]",
    "Speaker_3": "Speaker_3"
  },
  "segment_overrides": [
    { "segment_id": 42, "speaker": "[[Sara]]", "applied_from": "manual" }
  ],
  "segment_splits": [
    {
      "original_segment_id": 87,
      "applied_from": "ai_suggestion",
      "suggestion_id": "abc123",
      "splits": [
        { "new_id": "87.0", "start": 4.15, "end": 4.32, "speaker": "[[Ben]]" },
        { "new_id": "87.1", "start": 4.32, "end": 4.40, "speaker": "[[Sara]]" },
        { "new_id": "87.2", "start": 4.40, "end": 4.55, "speaker": "[[Ben]]" }
      ]
    }
  ]
}
```

**Field semantics:**

| Field | Source | Semantics |
|---|---|---|
| `speakers` | Default global rename mechanic | Speaker_N → `[[Wikilink]]` mapping; applies to all paragraphs of that speaker unless overridden. Empty / missing values mean "render as `Speaker_N` placeholder." |
| `segment_overrides[]` | Per-paragraph reassign mechanic | One entry per paragraph the user reassigned to a different speaker than the default mapping. `applied_from: 'manual'` always for this array. |
| `segment_splits[]` | AI-suggestion Apply mechanic (or future Cmd-Z-undoable manual split) | One entry per AI-applied split. `original_segment_id` references the immutable `diarization.json` segment; `splits[]` contains 2+ replacement sub-segments. `applied_from: 'ai_suggestion'` (with `suggestion_id` linking to `diarization_suggestions.json`) or `'manual'` (suggestion_id null). |

**Renderer contract** (load-bearing for testability):

```swift
public struct RenderedTranscript {
    public let segments: [RenderedSegment]   // ordered by start time
}
public struct RenderedSegment {
    public let id: String                    // either the original segment_id from diarization.json, or "<orig>.N" sub-id from a split
    public let startSeconds: Double
    public let endSeconds: Double
    public let speakerLabel: String          // wikilink-form (e.g. "[[Ben]]") or "Speaker_N" placeholder; resolved through (overrides → splits → speakers map → fallback)
    public let text: String                  // verbatim from CanonicalTranscript[start..<end]; never edited
    public let appliedFrom: AttributionSource? // .manual | .aiSuggestion(suggestionId) | nil if from default speaker map
}

public enum AttributionSource: Equatable {
    case manual
    case aiSuggestion(suggestionId: String)
}

public func renderTranscript(
    diarization: DiarizationArtifact,
    overrides: [SegmentOverride],
    splits: [SegmentSplit],
    speakers: [String: String]   // Speaker_N → "[[Wikilink]]" or original key for unattributed
) -> RenderedTranscript
```

Pure function; no I/O; deterministic. **Resolution order per segment:** (1) check `splits[]` for a split replacing this `original_segment_id` — emit the sub-segments; (2) check `overrides[]` for a per-segment speaker override; (3) fall back to `speakers[Speaker_N]` mapping; (4) fall back to `Speaker_N` literal placeholder. Lives in `Sources/Attribute/AttributionRenderer.swift`. Golden fixtures at `Tests/AttributeTests/Fixtures/renderer/` covering every combination of `(no overrides, overrides only, splits only, both)` × `(all speakers attributed, partial, none)` × `(splits referencing valid segment ids, dangling split with no matching diarization segment — must be ignored not crash)`.

**Atomic-write discipline:** writes are debounced 500ms via `Task.debounce` (or equivalent: cancellation-safe accumulation pattern; the wiring lands in **Story 8** as part of `MainWindow/AttributionViewModel.swift`) inside the `AttributionViewModel`, routed through `AtomicWriter` (Cross-Cutting Concern #3). Per-row `@State` never directly writes; the view model owns the durable state. `Task.debounce` semantics differ from typical Combine debounce — implementation uses a per-write `Task` with `Task.sleep(for: .milliseconds(500))` and cancels the prior pending Task on each user mutation; the live Task awakens, reads the latest in-memory draft, and atomic-writes once.

**Cancellation preservation:** `Save for later` / Esc / Cmd-W dismisses the sheet; the most-recent debounced write completes before SwiftUI tears down the view (the dismiss handler `await`s the in-flight write Task). Stale-active-state recovery (Decision 4.2) reopens the sheet with partial state pre-populated if the GUI crashes mid-attribution.

#### Decision 5.5: Phased roadmap (Path C lock-in)

Forward-compat plan; codified to make Phase 2 / 3 / 4 enable-flips contract-preserving.

| Phase | When | Action |
|---|---|---|
| **Phase 1 — MVP** | Initial release | Jargon correction live (FR55–57, already in summarize); diarization-review architectural slots present (interface + cache schema + telemetry columns + state machine + subprocess + Attribution sheet UI), feature flag `diarization_review.enabled = false` by default; transcription-review slots declared (interface + cache schema + telemetry columns), no impl. |
| **Phase 2 — early v1 (post-MVP dogfood)** | After ~30-day MVP dogfood | Run smoke-test protocol (≥5 captured meetings, evaluate Haiku precision/recall); if `applied/suggestions ≥ 40%` over 4 weeks per Decision 5.7 kill criteria, flip `diarization_review.enabled = true` and bump auricle to v1.1. |
| **Phase 3 — v1.x** | Post-Phase-2 | Implement `ClaudeTranscriptionReviewer`; surface in transcript pane (chip + reasoning + Apply/Reject); same dogfood-then-enable pattern. Cross-pollinates with jargon correction (vault-glossary grounding for proposed corrections). |
| **Phase 4 — v1.x+** | Earned by Phase 2/3 success | Unify into a single Claude call producing `unified_suggestions.json` (reduces tokens; one round-trip). Single transcript-pane surface for all three correction types. |

**No-backtracking guarantees** (the design discipline that makes the phasing safe):

- Schema additions are additive — new optional fields can be added to `attribution.json` and `*_suggestions.json` without breaking existing readers.
- State-machine additions can be no-ops — `reviewing_diarization` already passes through quickly when flag is off; future states adopt the same pattern.
- Strategy slots reuse the SOLID-I family — adding `ClaudeTranscriptionReviewer` doesn't touch `ClaudeDiarizationReviewer`'s code.
- Cache-dir handoff contract holds — all cache artifacts remain immutable per Decisions 1.3 + 5.3.
- The renderer is a pure function — adding correction sources doesn't restructure rendering logic.

#### Decision 5.6: NFR-C1 cost ceiling tiers

The cost ceiling has tiers reflecting opt-in to the AI-correction category. NFR-C1's $0.50 default holds for the MVP shipping configuration; the $0.60 ceiling kicks in only when the user opts into diarization review. Local-LLM strategy (FR33) drops all of these to $0.

| Mode | Calls per meeting | Cost ceiling |
|---|---|---|
| **Default MVP** (jargon correction inline within summarize prompt; flag-off diarization review) | 1 (Opus summarize) | **≤ $0.50** (NFR-C1 unchanged) |
| **MVP with diarization review enabled (Phase 2)** | 2 (Haiku review + Opus summarize) | **≤ $0.60** (NFR-C1 with explicit opt-in) |
| **v1.x with transcription review enabled (Phase 3)** | 3 (Haiku review × 2 + Opus summarize) | targeted ≤ $0.70 |
| **v1.x+ unified (Phase 4)** | 2 (single Haiku unified review + Opus summarize) | targeted ≤ $0.55 |

The 30-day rolling cost widget on the meeting list (UX spec Step 10 Round-2 Mary) shows aggregate spend broken down by stage; Opus drift, model-swap surprises, and runaway summary-retry costs surface visually before the next billing cycle.

**Telemetry contract:** every reviewer subprocess writes `metadata_json.cost_usd` + `metadata_json.model_id` to the `stage_events` row AND UPSERTs `telemetry.<category>_review_cost_usd` + `<category>_review_model`. The `cost_usd: 0` + `model_id: "local:<name>"` pattern is locked in MVP schema so v1.1+ local-LLM swap is a config change, not a schema migration (Winston's Round-2 lock-in folded into Decision 4.5).

#### Decision 5.7: Pre-committed kill criteria + trust calibration

To avoid AI features that quietly underperform but stay shipped, the diarization reviewer has explicit kill criteria codified in the architecture (Mary's Round-2 lock-in). The product is designed to **make low quality visible** rather than rely on user complaint.

**Kill criteria** (computed from `telemetry.diarization_suggestions_*` columns):

| Metric | Threshold | Action | Computability |
|---|---|---|---|
| `applied_count / suggestions_count` over 4 rolling weeks | < 0.40 | `auricle stats` (v1.1+) flags the meeting class; recommends the user review prompt design or disable flag | **MVP-computable.** Both columns have writers (subprocess writes `suggestions_count`; GUI Attribute writes `applied_count`). |
| `false_positive_count / applied_count` (manually-corrected post-publish) | > 0.20 | Same flag — user-applied splits that needed re-correction in Obsidian indicate the AI is misleading the user | **v1.1 only.** No MVP writer for `false_positive_count` exists — the metric requires post-publish detection of vault-edits to attributed paragraphs. This is the same forward-instrumentation gap surfaced in Architecture Validation §"Gap Disposition" #11 (closed-loop trust calibration). MVP captures the ingredients (`applied_count`, `segment_splits[]` with `applied_from: 'ai_suggestion'`, vault file path); v1.1 adds the vault-file-hash-on-persist + background diff job that produces the `false_positive_count` column. The kill criterion ships with the threshold codified, but `auricle stats` reports it as `n/a — instrumented in v1.1` until that work lands. |

**Divide-by-zero handling** (the `suggestions_count = 0` edge case — silent AI, no flagged segments):

```
if suggestions_count == 0:
    accept_rate = nil  // not "0%", not "100%"; explicitly absent
    kill_criterion_status = .insufficientSignal  // NOT .pass — "no suggestions" is calibration data, not a quality signal
```

This propagates to:
- **Trust-calibration footer:** when `suggestions_count == 0` for the rolling window, the footer reads *"🤖 Reviewed N segments, flagged 0"* (UX spec Step 10 Round-2 Mary "explicit absence replaces silent absence") — NOT *"Accept rate: —/—"*.
- **Auto-collapse trigger** (UX spec Step 10 Round-2 "if accept rate < 40%, AI hints collapse"): the trigger explicitly requires `suggestions_count > 0` AND `applied_count / suggestions_count < 0.40`. With `suggestions_count == 0`, hints stay at their last user-set state — silence is not distrust.
- **`auricle stats` (v1.1+) report:** `insufficientSignal` rolls up as a separate row from `passing` / `failing` so a user with 4 weeks of silent AI doesn't see a green check that misrepresents calibration status.

The general rule: **rate-style kill criteria with a denominator of zero are "no signal," not "pass."** Future correction-category criteria adopt the same convention.

User-facing surfaces (UX spec Step 10):

- **Trust-calibration footer in Attribution sheet:** "🤖 Reviewed N segments, flagged M · Accept rate: X/Y this week" — silent absence is replaced with explicit absence (when `M = 0`, footer reads "Reviewed N segments, flagged 0").
- **Auto-collapse:** if accept rate drops below 40% over recent meetings, the 🤖 chips collapse all expanded reasoning by default — the system gets quieter when the user signals distrust. Implementation reads from `telemetry.diarization_suggestions_*` rolling aggregate.
- **Per-Apply Cmd-Z + persistent revert:** every Apply action is undoable via Cmd-Z within the session AND via inline "Revert this split" affordance after sheet reopen (the `segment_splits[]` row is removed from `attribution.json`).
- **J0 banner when API key missing for AI review:** "Diarization review unavailable — add Anthropic key in Settings to enable." One-time, dismissable.

**Cross-cutting alignment:** these criteria operationalize the J1.5 trust-calibration concern (Decision 3.7) for the diarization category. The `auricle stats` v1.1 verb surfaces the metric; MVP's footprint is the telemetry columns + the trust-calibration footer.

## Implementation Patterns & Consistency Rules

This section codifies the cross-cutting consistency rules that prevent AI-agent drift across stories. Many patterns were already locked in the Group 1–4 decision tables; this section names them as a single set, fills the gaps where AI agents could otherwise differ, and defines the enforcement layer (build-time, CI, and code-review).

### Conflict Points Identified

11 areas where AI agents could otherwise make different choices, addressed below: Swift naming, file naming, SwiftPM target layout, JSON dialect (snake_case vs camelCase), Codable conventions, error typing, async/actor/class discipline, markdown output formatting, helper-bypass discipline, composition-root discipline, and the test-organization split.

### Naming Patterns

#### Swift Code Naming

Standard Swift API Design Guidelines apply. Project clarifications:

- **Types** (struct / class / enum / actor / protocol): `PascalCase`. Example: `SummarizerOrchestrator`, `MeetingID`, `FailureCategory`.
- **Functions, properties, parameters, locals**: `camelCase`. Example: `markVerified(meetingId:)`, `transcriptStart`.
- **Constants**: `camelCase` (Swift convention; never `SCREAMING_SNAKE_CASE` even for module-level constants).
- **Enum cases**: `camelCase`. Example: `case transient`, `case publicSafe`.
- **Protocols**: noun- or role-based, no `-able` suffix unless purely behavioral. `SummarizerStrategy`, `CalendarSource` ✓ ; `Summarizable` ✗.
- **Acronyms**: Swift API Design Guidelines (capitalize all letters when leading, all-lowercase when trailing): `urlString`, `meetingID`, `parseJSON()`. Two-letter and longer acronyms are treated uniformly: `idResolver`, `urlSession`.
- **Generic parameters**: single capital letter (`T`, `U`, `V`) for fully generic; descriptive PascalCase (`Strategy`, `Source`) when the parameter has a domain role.
- **Boolean properties / accessors**: positive form, prefixed with `is`/`has`/`should`/`can`: `isVerified`, `hasGroundedQuote`. Avoid double negatives.

#### File Naming

- One **primary** type per file; filename matches the primary type's name: `SummarizerOrchestrator.swift`, `MeetingIDResolver.swift`. (Closely-coupled secondary types — small Codable payload structs, internal enums — may live in the same file.)
- **Extensions** in their own file when ≥10 lines or when they conform a project type to an external protocol: `Meeting+Codable.swift`, `URL+VaultPath.swift`.
- **Test files**: `<TypeUnderTest>Tests.swift`. Example: `SummarizerOrchestratorTests.swift`.
- **Snapshot fixtures**: `Tests/<Target>Tests/Snapshots/<TestName>.txt` (or `.json`).
- **Non-Swift files in the repo**: `kebab-case` for shell scripts, certs, asset catalogs, JSON fixtures. Example: `scripts/setup-trust.sh`, `assets/AndrewCodeSigningCA.cer`.

#### SwiftPM Target Names

- Targets: `PascalCase`, named for their concern. `Capture`, `Transcribe`, `Summarize`, `Persist`, `SummarizerInterface`, `ClaudeSummarizer`, `WhisperKitDiarizer`, `GoogleCalendarSource`.
- Test targets: `<Target>Tests`. Example: `CaptureTests`, `SummarizeTests`.
- Source directory mirrors target: `Sources/Capture/...` ↔ target `Capture`. Test directory mirrors test target: `Tests/CaptureTests/...`.
- Protocol-only ("interface") targets are named `<Concern>Interface`: `SummarizerInterface`, `DiarizerInterface`, `TranscriberInterface`, `CalendarInterface`.
- Concrete strategy targets are named `<Vendor><Concern>`: `ClaudeSummarizer`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`. (`Vendor` is whatever uniquely identifies the implementation — API name, library name, or runtime.)

#### Database Naming

Locked in Decision 2.1 (`snake_case` SQL, plural table names for entity collections, `idx_<table>_<columns>` indexes, `<table>_<event>` triggers). No additions in this section.

#### CLI Verb / Flag Naming

Locked in Decision 1.5 (lowercase verbs, `kebab-case` flags, `<verb>` `<id>` `[--flags]` shape, JSON `schemaVersion` field). No additions in this section.

#### JSON Field Naming — the dialect rule

The project uses **two** JSON dialects, intentionally. AI agents MUST honor the dialect rule:

| Surface | Dialect | Rationale |
|---|---|---|
| Cache-dir artifacts (`transcript.json`, `diarization.json`, `summary.json`, `attribution.json`, `calendar.json`, `glossary.json`, `state.json`) | `snake_case` | Matches SQLite columns, Anthropic API conventions, and the `jq` / terminal-inspection workflow. |
| Vault frontmatter under the `auricle:` key (`meeting_id`, `schema_version`, `supersedes`) | `snake_case` | Same; consumed by tools (Obsidian Bases, Dataview) where snake_case is conventional. |
| `stage_events.metadata_json` payloads stored in SQLite | `snake_case` | Same context as cache artifacts; matches surrounding SQL columns. |
| All `auricle <verb> --json` responses | `camelCase` (`schemaVersion`, `meetingId`, etc.) | Consumed primarily by Swift code (Andrew's own scripts via `JSONDecoder` default key strategy); matches Swift property names directly. Locked in Decision 1.5. |
| Structured error JSON (CLI `--json` mode and `os_log` payloads) | `camelCase` | Same surface as CLI output. |
| Notification `userInfo` payload | `snake_case` (`meeting_id`, `schema_version`, `payload_version`) | Treated as a "system" artifact (cross-process, persists across Sparkle upgrades); consistent with cache-artifact convention. Locked in Decision 4.3. |

**Codable strategy:**
- **CLI output types**: use Swift's default property names (camelCase); no `CodingKeys` required.
- **Cache-artifact, frontmatter, and notification-payload types**: declare `enum CodingKeys: String, CodingKey` to map snake_case JSON to camelCase Swift properties.
- Round-trip tests (encode → decode → equality) are **required** for every JSON-shaped contract type; missing tests are a code-review reject.

#### Logging Categories

- Subsystem: `com.auricle.app` (single value, locked).
- Category: lowercase, matches the stage or module name. Stage categories: `capture`, `transcribe`, `attribute`, `summarize`, `persist`, `notify`, `verify`, `discard`. Module categories: `orchestrator`, `state`, `telemetry`, `permissions`, `vault-glossary`, `verifier`.
- Convention: one `Log` instance per file, declared at file top: `private let log = Log(category: "summarize")`.

#### Notification / URL Scheme Names

- URL scheme: `auricle://` (registered in `Info.plist`).
- Scheme path patterns: `auricle://attribute/<meeting-id>`, `auricle://status/<meeting-id>`. Verbs match CLI verb names where applicable; new schemes follow the same `auricle://<verb>/<arg>` shape.
- Notification action identifiers (when v1.1 adds inline notification actions): dot-namespaced and bundle-prefixed: `com.auricle.app.notification.verify`, `com.auricle.app.notification.discard`.

### Structural Patterns

#### Repository Layout

```
auricle/
├── Package.swift                       # SwiftPM manifest — module-boundary truth
├── Sources/
│   ├── Capture/                        # one library target per concern
│   ├── Transcribe/
│   ├── Summarize/
│   ├── ...
│   ├── auricle-cli/                    # CLI executable target
│   └── ...
├── Tests/
│   ├── CaptureTests/
│   ├── SummarizeTests/
│   │   ├── Fixtures/                   # small audio clips, JSON goldens
│   │   └── Snapshots/                  # snapshot-test outputs
│   └── ...
├── App/
│   └── Auricle.xcodeproj/              # Xcode project for GUI .app bundle
├── scripts/
│   └── setup-trust.sh                  # per-Mac trust setup, etc.
├── assets/
│   └── AndrewCodeSigningCA.cer         # public CA cert (no private key)
└── _bmad-output/                       # planning artifacts
```

#### Within a Target

- Source files live at the target root. **Subdirectories within a target** are introduced only when a target exceeds ~15 source files OR holds ~3+ logically distinct sub-concerns. Default: flat.
- Subdirectory naming when introduced: `PascalCase` matching the conceptual cluster (e.g., `Sources/Summarize/Strategies/ClaudeSubstringSummarizer.swift`). Subdirectories DO NOT change the import path — they're pure file-system organization.
- If a target needs deeper structure than 1 level of subdirectories, **break it into a smaller target** instead. The rule: target boundaries are the architecture; subdirectories are housekeeping.

#### Test Organization

- One test target per source target. Source-only targets without tests are explicitly justified in `Package.swift` comments (e.g., interface-only targets where there's nothing to test).
- **Swift Testing** (`@Test` macro, `#expect`) for new test code — including unit, integration, and contract tests.
- **XCTest** only where Swift Testing's coverage hasn't reached parity (today: performance tests via `XCTMetric`, `XCTPerformanceMetric`). Mark these explicitly with a comment: `// XCTest: performance — Swift Testing has no @Test perf equivalent yet.`
- Tests use the same library target's types directly (no separate "test helpers" target unless ≥3 test targets need to share fixtures, in which case introduce a `TestSupport` target).
- Fixtures live under `Tests/<Target>Tests/Fixtures/`. Large recordings (>5 MB) stay outside the repo, referenced by absolute path in environment variables for local-only tests, marked `.serialized` and skipped on CI.

#### Composition Roots

- Exactly one composition root per binary:
  - GUI: `App/Auricle/AuricleApp.swift` (the `@main`-annotated `App` struct)
  - CLI: `Sources/auricle-cli/main.swift` (the swift-argument-parser `AsyncParsableCommand`'s top-level type)
- Composition roots are the **only** places that instantiate concrete strategies (`ClaudeCitationsSummarizer`, `WhisperKitTranscriber`, `GoogleCalendarSource`, etc.) and inject them into the orchestrator.
- Tests use a third entry point per test target — typically a helper named `makeTestOrchestrator(...)` or a `TestComposition` struct — that wires stub strategies. Stubs live under `Tests/<Target>Tests/Stubs/`.
- **No type outside a composition root may instantiate a concrete strategy by name.** Code review rejects `let summarizer = ClaudeCitationsSummarizer(...)` in any non-composition-root file. This is the mechanical version of DIP from §Code-Design Discipline (SOLID).

### Format Patterns

#### Swift Type Discipline

- **Value types by default**: `struct` for data, `enum` for sums, `actor` for mutable shared state. `class` is reserved for: subclasses of Apple framework types (e.g., `NSDocument`, `NSWindowController`) and reference-identity-required cases (rare; flagged in code review).
- **Errors are typed enums** conforming to `Error`. One enum per error domain: `CaptureError`, `TranscribeError`, `SummarizerError`, `PersistError`, `VerifierError`. Cases carry associated values for context (`.permissionDenied(category: TCCCategory)`, `.streamInterrupted(reason: String)`).
- **`NSError` bridging**: only at Apple-framework callback boundaries; immediately translated into a typed Swift error before propagating further.
- **Optionals over sentinels**: `String?` not `""`; `Int?` not `-1`. Never use 0 to mean "absent" for an Int that could legitimately be 0.
- **Strong typing for IDs**: `MeetingID` wraps a ULID `String`; the type system rejects accidental string substitution. Same pattern for any cross-cutting identifier (`CalendarEventID`, `StageEventID`).

#### API Contract Formats

- Every JSON-shaped contract carries a top-level `schema_version` (snake_case dialect) or `schemaVersion` (camelCase dialect) per the dialect rule.
- ISO8601 UTC `YYYY-MM-DDTHH:MM:SSZ` (or `…SS.fffZ` for sub-second precision) is the only timestamp format anywhere in the system **except** filename slugs (per Decision 2.1, 2.4).
- ULIDs are stored as 26-char Crockford-base32 `String` in SQLite and notification payloads; wrapped as `MeetingID` in Swift. Conversion is type-checked at the boundary, not scattered through the code.

#### Markdown Output (Vault Notes)

- Frontmatter under `---` fences (YAML), exactly the schema in Decision 2.2.
- Section headers: **`## ` only** (two-hash) for sections; **never `# `** (the filename owns the document title); **never beyond `### `** (three-hash). Obsidian outline depth stays shallow — this is a deliberate constraint to keep notes scannable.
- Wikilinks: `[[Display Name]]` for people, projects, concepts (per FR38 + the user's global Second Brain rule).
- Verbatim quotes: `> ` blockquote prefix, single space after `>`. One quote per line in the source markdown; soft-wrapping handled by the renderer.
- **No** emoji, **no** horizontal rules (`---` outside frontmatter), **no** tables (Obsidian renders tables inconsistently across themes; bullet lists are universal).
- File ends with a single trailing newline; UTF-8 encoded; LF line endings.

### Communication Patterns

#### Async / Concurrency Discipline

- `async`/`await` everywhere for project code. **No completion-handler callbacks** for new code; existing Apple-framework callback APIs are wrapped immediately into async (`withCheckedContinuation` or `withCheckedThrowingContinuation`) at the boundary.
- `actor` for any type holding mutable state shared across tasks. Examples: `Verifier` (Decision 4.3), `SummarizerOrchestrator` (Decision 3.3), `StateStore`, `Telemetry`.
- **No manual locking** (`NSLock`, `os_unfair_lock`, `DispatchSemaphore`) in project code — actors are the project pattern. Apple-framework callbacks that require a lock-equivalent get an actor wrapper.
- **`@MainActor`** for SwiftUI views and the AppKit-touching layer of the GUI. Backend types (`Orchestrator`, strategies, etc.) are not `@MainActor`-bound.

#### Cross-Process Communication

- Cross-process IPC mechanisms allowed: **SQLite writes** (Decision 2.1) and **cache-dir artifacts** (Decision 1.3). That's the entire surface.
- **Forbidden**: XPC, Mach ports, named pipes, shared memory, pasteboard, distributed objects. If a future need arises, surface it as an architecture decision (revising Decision 1.2's "no other coordination layer beyond SQLite for state and the cache-dir for artifacts").
- Subprocess invocations use `Process` (Swift's `Foundation.Process`) with structured I/O: subprocess writes JSON to stdout, text/JSON-error to stderr per Decision 1.5.

#### Error Propagation

- Stages and strategies **throw typed errors** (per type-discipline rules above).
- The `Orchestrator` catches typed errors and routes to `FailureCategory` (Decision 4.1) for retry vs surface.
- User-facing error messages are produced by the CLI / GUI layer — never by stage code. Stage code throws; the layer above translates.
- Internal-only details (Swift `Error` `description`, stack traces) are emitted to `os_log` at the catch site and never surface to the user. `auricle status <id>` provides the discovery path (Decision 4.5).

#### State Management

- **Single source of truth**: SQLite for state, cache-dir for artifacts (Decision 1.2).
- **No in-memory shadow state**. All state reads go through the `StateStore` module's typed API. Direct `db.read { ... }` outside `StateStore` is a code-review reject — types funnel through `StateStore.fetchMeeting(id:)`, `StateStore.fetchPending()`, etc.
- The `Orchestrator` re-reads state on every dispatch; it never carries a `Meeting` object across stage boundaries between subprocess invocations. (Within one subprocess invocation, holding a `Meeting` value across the stage's logic is fine; that subprocess writes back via `StateStore` at exit.)
- GUI state observation via GRDB `ValueObservation` for in-process changes + `DispatchSource.makeFileSystemObjectSource` on `db.sqlite3-wal` for cross-process changes (per Decision 2.1 — `ValueObservation` is in-process only).

#### Idempotency & Two-Transaction Pattern

- Every stage is idempotent (NFR-R5).
- The **two-transaction pattern** (Decision 1.2: Txn A = "started" + active state; Txn B = "completed/failed" + target state) is enforced by a **`StageRunner.run { ... }` helper** in the `Orchestrator` target. Stages never write to `meetings.state` or `stage_events` directly — they call into `StageRunner`, which owns both transactions and the failure handling.
- Direct `db.write { ... }` on `meetings` or `stage_events` outside `StageRunner` is a code-review reject.

### Process Patterns

#### Helper Discipline (the bypass-prohibition rule)

The project has several **single-implementation primitives**, each owned by exactly one target. AI agents MUST go through the helper, not around it:

| Primitive | Owner target | Used for | Bypass = code-review reject |
|---|---|---|---|
| `AtomicWriter` | `Core` | Every artifact write (cache JSON, vault markdown) | Direct `Data.write(to:)`, `String.write(to:atomically:encoding:)` |
| `VaultWriter` | `Persist` | Vault markdown writes (wraps `AtomicWriter` + path resolution + collision handling) | Any direct write under `vault_path/meetings_subdir/` |
| `CacheArtifactWriter` | `Core` | Cache-dir JSON writes (wraps `AtomicWriter` + `schema_version` injection) | Any direct write under `~/Library/Caches/com.auricle.app/<id>/` |
| `Verifier` (actor) | `Verify` | Marking a meeting verified + arming retention timer | Any direct write to `meetings.verified_at` or insert to `retention_timers` |
| `Log` (facade) | `Core` | Every log call | Direct `os_log(...)`; direct `print(...)` outside CLI bare-output paths |
| `Telemetry.record(...)` | `Telemetry` | All telemetry inserts | Direct SQL on the `telemetry` table |
| `StageEventLogger.record(...)` | `Telemetry` | All `stage_events` inserts | Direct SQL on `stage_events` |
| `StageRunner.run { ... }` | `Orchestrator` | Stage execution wrapping (the two-transaction pattern) | Direct writes to `meetings.state` |
| `PermissionChecker` | `Permissions` | All permission checks | Direct `AVCaptureDevice.authorizationStatus(for:)`, etc. |
| `MeetingIDResolver` | `Core` | Every `<id>` argument resolution | Custom ULID-prefix matching code |

The helpers have one implementation, one test, one set of edge-case decisions. Reinventing them in stage code creates inconsistency and reopens fixed bugs.

#### Atomic-Write Enforcement (Reinforcing #3 from Cross-Cutting Concerns)

- `AtomicWriter.write(_ data: Data, to path: URL)` is the only filesystem-write primitive. It implements `temp → fsync → rename` per NFR-R1 and FR36.
- All higher-level writers (`VaultWriter`, `CacheArtifactWriter`) compose on top of `AtomicWriter`.
- A repo-level grep CI check fails the build if `Data.write(to:)`, `String.write(to:atomically:encoding:)`, or `FileManager.createFile(...)` appears anywhere outside `AtomicWriter.swift` itself.

#### Permission Detection

- Single `PermissionChecker` type owned by the `Permissions` target. All callers go through it.
- Checks are memoized for the lifetime of the process; refresh on AppKit-broadcast settings-change notifications (`NSWorkspace.shared.notificationCenter`).
- Detection points (Decision 4.4): app launch, before stage entry, on revocation events. Each detection point calls `PermissionChecker.refresh()` first to invalidate the memoized cache.

#### Telemetry & Logging Convention

(Locked mostly in Decision 4.5; rules restated here as enforcement language.)

- Every log call is `log.info(...)` / `log.warn(...)` / `log.error(...)` / `log.debug(...)` on a `Log` instance — never `os_log(...)` directly.
- Every call site **must** specify sensitivity at the field level: `log.info("transcribe completed", duration: .publicSafe(durationMs), audioPath: .sensitive(path))`. Defaulting to `publicSafe` is a code-review reject; defaulting to `sensitive` is permissible (conservative is fine).
- Log levels:
  - `debug` — build-time only, stripped in release via compile-time flag
  - `info` — default; every stage emits one `info` line per state transition (paired with the `stage_events` row)
  - `warn` — potential issue surfaced to user (e.g., quote-validation drops, calendar enrichment failure-but-publish-anyway)
  - `error` — failure paired with a state transition into `*_failed`
- API keys, OAuth tokens, transcript content, attendee emails, and Anthropic response bodies are **never** passed to the `Log` facade in any form. They're scrubbed at the source (the HTTP-client layer wraps the response so log-emitters see only redacted metadata).

### Enforcement Guidelines

**All AI agents MUST:**

1. Honor SwiftPM target boundaries — accidental cross-target imports are a build error and must remain so.
2. Use the helper APIs (table above) instead of their underlying primitives.
3. Match every binding-contract surface (CLI verb/flag names per Decision 1.5; frontmatter schema per Decision 2.2; cache-dir filenames per Decision 1.3; SQLite columns per Decision 2.1).
4. Honor the JSON dialect rule (snake_case for system surfaces, camelCase for CLI surfaces).
5. Use typed Swift error enums; never raise `NSError` from project code, never use string error codes.
6. Treat every stage as idempotent and every artifact write as atomic.
7. Use Swift Testing for new tests, XCTest only where coverage hasn't reached parity (commented justification).
8. Place concrete-strategy instantiation only inside composition roots.

**Pattern Enforcement (mechanical):**

- **Build-time**: SwiftPM rejects cross-target imports per `Package.swift` declarations.
- **Lint-time (`swiftformat`/`swiftlint` config in repo root)**:
  - Naming rules (PascalCase types, camelCase functions/properties, kebab-case flags via `swiftlint` custom rules)
  - File-layout rules (one primary type per file, extension-file naming)
  - Helper-bypass detection (custom `swiftlint` rules grepping for `Data.write(to:`, direct `os_log(`, direct `JSONDecoder().decode(... transcript ...)` outside the canonicalization layer, etc.)
- **CI-time tests**:
  - JSON contract round-trip tests for every `Codable` conformance representing a contract type
  - Snapshot tests on `SummarizationPromptBuilder` outputs (Decision 3.2 — fail build on prompt drift)
  - Canonicalization invariant tests (Decision 3.4 — fail build on offset divergence between Citations and substring strategies)
  - Cross-mode fixture tests (Decision 3.4 — same input, both strategies, byte-identical renderer output)
  - GRDB migration round-trip tests (every migration applies cleanly to an empty DB and to the prior version's DB)
- **Code-review checklist** (the human layer for what tooling can't catch):
  - Helper-bypass patterns (any direct call to a wrapped primitive)
  - String-typed errors / `NSError` bridges escaping their introduction site
  - Concrete-strategy instantiation outside a composition root
  - State writes outside `StateStore` / `StageRunner` / `Verifier`
  - JSON dialect violations (snake_case in CLI output, or camelCase in cache artifacts)
  - Markdown output features outside the allowed set (extra header depth, tables, emoji)
  - Logging sensitivity defaults

**Pattern Updates:**

- Updates to these patterns require (a) a paragraph in this document explaining the change and rationale, and (b) either a CI-verifiable enforcement update or an explicit note that enforcement is human-only.
- Patterns that turn out to be wrong are revised in place — this document is not append-only.

### Pattern Examples

**Atomic vault write — good:**

```swift
public func persist(meeting: Meeting, summary: SummaryWithGrounding) throws {
    let path = vaultWriter.resolvePath(for: meeting)
    let markdown = FrontmatterRenderer.render(meeting: meeting, summary: summary)
    try vaultWriter.write(markdown, to: path)  // wraps AtomicWriter
}
```

**Atomic vault write — anti-pattern:**

```swift
try markdown.write(to: path, atomically: false, encoding: .utf8)
// REJECT: bypasses AtomicWriter; loses fsync; may leave partial file on crash
```

**Typed error — good:**

```swift
public enum CaptureError: Error {
    case permissionDenied(category: TCCCategory)
    case streamInterrupted(reason: String)
    case permissionRevokedMidstream
}
throw CaptureError.permissionDenied(category: .screenCapture)
```

**Typed error — anti-pattern:**

```swift
throw NSError(domain: "auricle.capture", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "permission denied"])
// REJECT: not pattern-matchable; loses category; doesn't compose with FailureCategory
```

**Actor-protected state — good:**

```swift
public actor Verifier {
    public func markVerified(meetingId: MeetingID) async throws { ... }
}
```

**Actor-protected state — anti-pattern:**

```swift
public final class Verifier {
    private let lock = NSLock()
    public func markVerified(meetingId: MeetingID) throws {
        lock.lock(); defer { lock.unlock() }
        // ...
    }
}
// REJECT: actors are the project pattern; manual locks reintroduce bugs actors prevent
```

**JSON dialect — good (cache artifact, snake_case):**

```swift
struct TranscriptArtifact: Codable {
    let schemaVersion: Int
    let segments: [Segment]
    let modelId: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case segments
        case modelId = "model_id"
    }
}
```

**JSON dialect — good (CLI output, camelCase):**

```swift
struct StatusResponse: Codable {
    let schemaVersion: Int  // serializes as "schemaVersion" — default keys
    let meeting: MeetingStatus
}
```

**JSON dialect — anti-pattern:**

```swift
// camelCase in a cache artifact
struct TranscriptArtifact: Codable {
    let schemaVersion: Int
    let segments: [Segment]
    let modelId: String
    // REJECT: cache artifacts use snake_case dialect — see dialect rule
}
```

**Stage execution — good:**

```swift
try await stageRunner.run(stage: .transcribe, meetingId: id) { db in
    let audioPath = try StateStore.fetchAudioPath(meetingId: id, db)
    let transcript = try await whisperKit.transcribe(audio: audioPath)
    try CacheArtifactWriter.write(transcript, for: id, named: "transcript.json")
    return .completed(metadata: .transcribe(.init(...)))
}
```

**Stage execution — anti-pattern:**

```swift
try db.write { db in
    try db.execute(sql: "UPDATE meetings SET state = 'transcribing' WHERE id = ?", arguments: [id])
}
// ... do transcription ...
try db.write { db in
    try db.execute(sql: "UPDATE meetings SET state = 'awaiting_attribution' WHERE id = ?", arguments: [id])
    try db.execute(sql: "INSERT INTO stage_events ...")
}
// REJECT: bypasses StageRunner; misses Txn A; misses error handling; loses metadata typing
```

**Helper bypass — anti-pattern:**

```swift
os_log("transcribe completed in %lld ms", log: .default, type: .info, durationMs)
// REJECT: bypasses Log facade; no sensitivity tagging; uses default subsystem instead of com.auricle.app
```

## Project Structure & Boundaries

This section is the concrete, file-and-directory-level realization of every decision above. AI agents implementing stories should treat the target list as the single source of truth for "where does this code live" — every concern below maps to exactly one target.

### Complete Project Directory Structure

```
auricle/
├── Package.swift                          # SwiftPM manifest — the module-boundary truth
├── Package.resolved                       # SwiftPM lockfile, committed
├── README.md
├── LICENSE
├── .gitignore
├── .swiftformat                           # naming + layout rules (see step-05 enforcement)
├── .swiftlint.yml                         # custom rules including helper-bypass detection
├── .github/
│   └── workflows/
│       ├── ci.yml                         # swift test + xcodebuild + lint + contract tests
│       └── release.yml                    # tag-triggered .app build, sign, Sparkle appcast
│
├── Sources/                               # SwiftPM library targets
│   ├── Core/                              # shared primitives — depended on by nearly everything
│   │   ├── AtomicWriter.swift             # the only filesystem-write primitive
│   │   ├── CacheArtifactWriter.swift      # cache-dir JSON writes (wraps AtomicWriter)
│   │   ├── CanonicalTranscript.swift      # NFC-normalized transcript representation (Dec 3.4)
│   │   ├── Codable+Dialects.swift         # JSON dialect helpers (snake/camel coding-key strats)
│   │   ├── Config.swift                   # config-file load/save, tilde expansion
│   │   ├── FailureCategory.swift          # enum (Dec 4.1)
│   │   ├── Log.swift                      # logging facade with sensitivity tagging
│   │   ├── MeetingID.swift                # ULID wrapper
│   │   ├── MeetingIDResolver.swift        # `<id>` argument resolution (Dec 1.5)
│   │   ├── PipelineState.swift            # canonical state-name enum (Dec 1.2)
│   │   ├── SchemaVersion.swift            # schema-version constants for every contract
│   │   └── ULID.swift                     # ULID generation (Crockford base32)
│   │
│   ├── State/                             # SQLite layer
│   │   ├── StateStore.swift               # public API — every state read/write goes through here
│   │   ├── Meeting.swift                  # GRDB record type
│   │   ├── StageEvent.swift               # GRDB record type
│   │   ├── RetentionTimer.swift           # GRDB record type
│   │   ├── Telemetry.swift                # GRDB record type for the telemetry table
│   │   ├── Migrations/
│   │   │   ├── Migration001_Initial.swift
│   │   │   └── MigrationRegistrar.swift   # GRDB.DatabaseMigrator setup
│   │   └── DatabasePoolFactory.swift      # GUI uses Pool, subprocess uses Queue (Dec 2.1)
│   │
│   ├── Telemetry/                         # telemetry + audit-event writers
│   │   ├── TelemetryRecorder.swift        # Telemetry.record(...) public API
│   │   ├── StageEventLogger.swift         # StageEventLogger.record(...) public API
│   │   └── StageMetadata.swift            # the Codable enum from Dec 4.5
│   │
│   ├── Orchestrator/                      # state machine + subprocess dispatch
│   │   ├── Orchestrator.swift             # the public façade (used by composition roots)
│   │   ├── StageRunner.swift              # two-transaction pattern wrapper (Dec 1.2)
│   │   ├── SubprocessDispatcher.swift     # spawns auricle-cli __internal-stage for subprocess stages
│   │   ├── CrashRecovery.swift            # on-launch reconciliation (Dec 1.2 / FR62)
│   │   └── RetentionScheduler.swift       # periodic retention-timer firing (FR46)
│   │
│   ├── Permissions/                       # TCC + Gatekeeper-trust checks
│   │   ├── PermissionChecker.swift        # the public API
│   │   ├── TCCCategory.swift              # enum mapping to deep-link URLs (Dec 4.4)
│   │   └── GatekeeperTrust.swift          # spctl assessment-policy probe (Distribution Model)
│   │
│   ├── Capture/                           # FR1–FR10
│   │   ├── CaptureSession.swift           # ScreenCaptureKit + AVAudioEngine pipeline
│   │   ├── AudioMixer.swift               # mic + system audio → mono 16kHz PCM (Dec 1.4)
│   │   ├── WAVWriter.swift                # PCM16 WAV file writer
│   │   ├── CaptureError.swift
│   │   └── CaptureMetadata.swift          # StageMetadata.capture payload
│   │
│   ├── TranscriberInterface/              # protocol-only target
│   │   ├── TranscriberStrategy.swift
│   │   ├── TranscriptArtifact.swift       # cache-dir transcript.json shape
│   │   └── TranscriberError.swift
│   │
│   ├── DiarizerInterface/                 # protocol-only target
│   │   ├── DiarizerStrategy.swift
│   │   ├── DiarizationArtifact.swift      # cache-dir diarization.json shape
│   │   └── DiarizerError.swift
│   │
│   ├── SummarizerInterface/               # protocol-only target (Dec 3.1)
│   │   ├── SummarizerStrategy.swift
│   │   ├── SummaryWithGrounding.swift     # the normalized output shape
│   │   ├── GroundedItem.swift
│   │   ├── GroundingPointer.swift
│   │   ├── GroundingMethod.swift
│   │   ├── SummarizerConfig.swift
│   │   └── SummarizerError.swift          # typed errors that drive Dec 3.3 fallback
│   │
│   ├── AIReviewerInterface/               # protocol-only target (Dec Group 5 — AI correction category)
│   │   ├── AIReviewerStrategy.swift       # base associatedtype protocol (Dec 5.1)
│   │   ├── Suggestion.swift               # the Codable suggestion-id + reasoning protocol
│   │   ├── AIReviewerResult.swift         # generic result wrapper with cost + reviewedSegmentCount
│   │   ├── AIReviewerCost.swift           # input_tokens, output_tokens, cost_usd, model_id
│   │   ├── DiarizationReviewerStrategy.swift   # sibling protocol — input/output shape for diarization (Dec 5.1)
│   │   ├── DiarizationSuggestion.swift          # diarization_suggestions.json schema + segment_splits payload
│   │   ├── TranscriptionReviewerStrategy.swift # sibling — declared, no MVP impl (Dec 5.5 Phase 3)
│   │   ├── TranscriptionSuggestion.swift        # declared schema; transcription_suggestions.json
│   │   ├── JargonCorrectionStrategy.swift       # sibling — wraps existing GlossaryInjector (Dec 5.1 Phase 1)
│   │   └── AIReviewerError.swift
│   │
│   ├── CalendarInterface/                 # protocol-only target
│   │   ├── CalendarSource.swift
│   │   ├── CalendarEvent.swift
│   │   └── CalendarError.swift
│   │
│   ├── Transcribe/                        # FR17, FR19, FR20
│   │   ├── TranscribeStage.swift          # consumes audio.wav → transcript.json + diarization.json
│   │   └── TranscribeMetadata.swift
│   │
│   ├── Diarize/                           # FR18 — separate target for strategy-swap forward-compat
│   │   ├── DiarizeStage.swift             # invoked from same subprocess as TranscribeStage
│   │   ├── SnippetExtractor.swift         # writes snippets/speaker_N.wav (Dec 1.3)
│   │   └── DiarizeMetadata.swift
│   │
│   ├── Attribute/                         # FR21–FR27
│   │   ├── AttributionMapping.swift       # speaker_N → name; the cache-artifact reader/writer
│   │   ├── AttributionStage.swift         # reads attribution.json; writes refined identities
│   │   └── AttributionMetadata.swift
│   │
│   ├── Summarize/                         # FR28–FR34
│   │   ├── SummarizeStage.swift           # the subprocess entry point for summarize
│   │   ├── SummarizerOrchestrator.swift   # primary/fallback wiring (Dec 3.3)
│   │   ├── SummarizationPromptBuilder.swift # shared prompt skeleton (Dec 3.5)
│   │   ├── GlossaryInjector.swift         # FR56 vault-glossary scoping
│   │   └── SummarizeMetadata.swift
│   │
│   ├── ClaudeSummarizer/                  # concrete strategy target
│   │   ├── ClaudeCitationsSummarizer.swift
│   │   ├── ClaudeSubstringSummarizer.swift
│   │   ├── CitationGroundingValidator.swift
│   │   ├── SubstringGroundingValidator.swift
│   │   ├── AnthropicHTTPClient.swift      # URLSession wrapper; redacts response bodies pre-log
│   │   └── KeychainAPIKey.swift           # reads anthropic key from macOS Keychain (NFR-S1)
│   │
│   ├── ClaudeAIReviewers/                 # concrete strategy target (Dec 5.2)
│   │   ├── ClaudeDiarizationReviewer.swift # Haiku-default, flag-controlled (diarization_review.enabled)
│   │   └── (future: ClaudeTranscriptionReviewer.swift, ClaudeUnifiedReviewer.swift) # Phase 3, Phase 4
│   │   # Note: shares AnthropicHTTPClient + KeychainAPIKey with ClaudeSummarizer (Package.swift dep)
│   │
│   ├── ReviewDiarization/                 # the reviewing_diarization stage (Dec 5.3 subprocess)
│   │   ├── ReviewDiarizationStage.swift   # subprocess entry point; wraps strategy in stage lifecycle
│   │   ├── ReviewDiarizationPromptBuilder.swift # cache-friendly prompt skeleton
│   │   └── ReviewDiarizationMetadata.swift # StageMetadata.reviewDiarization payload
│   │
│   ├── WhisperKitTranscriber/             # concrete strategy target
│   │   ├── WhisperKitTranscriber.swift
│   │   └── WhisperKitModelLoader.swift    # whisper-large-v3-turbo on ANE (Dec 1.4 PRD lock)
│   │
│   ├── WhisperKitDiarizer/                # concrete strategy target
│   │   └── WhisperKitDiarizer.swift       # uses WhisperKit's built-in diarize (PRD-locked)
│   │
│   ├── GoogleCalendarSource/              # concrete strategy target
│   │   ├── GoogleCalendarSource.swift
│   │   ├── GoogleOAuthFlow.swift          # PKCE flow; refresh token in Keychain (NFR-S1)
│   │   └── EventMatcher.swift             # active-event-at-capture-time logic
│   │
│   ├── VaultGlossary/                     # FR55–FR57
│   │   ├── VaultGlossaryBuilder.swift     # scans vault for [[wikilink]]-target page names
│   │   └── GlossaryCache.swift            # ~/Library/Caches/.../glossary-cache.json
│   │
│   ├── Persist/                           # FR35–FR41
│   │   ├── PersistStage.swift
│   │   ├── FrontmatterRenderer.swift      # data → markdown (with the Dec 2.2 schema)
│   │   ├── VaultWriter.swift              # markdown → atomic write, path-resolution + collision
│   │   ├── FilenameResolver.swift         # Dec 2.4 slug rules
│   │   └── PersistMetadata.swift
│   │
│   ├── Verify/                            # the verification + retention-arm wiring
│   │   ├── Verifier.swift                 # the actor (Dec 4.3)
│   │   ├── ManualVerifyHandler.swift      # invoked by `auricle keep <id>` and GUI confirm
│   │   └── NotificationClickHandler.swift # invoked by UNUserNotificationCenterDelegate
│   │
│   └── Notifications/                     # FR42–FR44
│       ├── Notifier.swift                 # the public API
│       ├── NotificationPayload.swift      # Codable, snake_case dialect (Dec 4.3)
│       └── NotificationCategoryRegistrar.swift # registers UNNotificationCategory on launch
│
├── Tests/                                 # one test target per source target
│   ├── CoreTests/
│   │   ├── AtomicWriterTests.swift
│   │   ├── CanonicalTranscriptTests.swift # the Dec 3.4 build-time invariant tests
│   │   ├── LogRedactionTests.swift
│   │   ├── MeetingIDResolverTests.swift
│   │   └── ULIDTests.swift
│   ├── StateTests/
│   │   ├── MigrationTests.swift           # round-trip every migration (step-05 CI gate)
│   │   ├── StateStoreTests.swift
│   │   └── ConcurrencyTests.swift         # WAL + cross-process write contention
│   ├── TelemetryTests/
│   │   └── StageMetadataRoundTripTests.swift
│   ├── OrchestratorTests/
│   │   ├── StageRunnerTests.swift         # two-transaction pattern verification
│   │   ├── CrashRecoveryTests.swift
│   │   └── SubprocessDispatcherTests.swift
│   ├── PermissionsTests/
│   ├── CaptureTests/
│   │   ├── AudioMixerTests.swift
│   │   ├── WAVWriterTests.swift
│   │   └── Fixtures/                      # tiny audio fixtures only
│   ├── TranscribeTests/
│   ├── DiarizeTests/
│   ├── AttributeTests/
│   ├── SummarizeTests/
│   │   ├── PromptBuilderSnapshotTests.swift # Dec 3.2 prompt-drift CI gate
│   │   ├── CrossModeFixtureTests.swift     # Dec 3.4 Citations/substring equivalence
│   │   ├── Fixtures/
│   │   │   ├── transcripts/                # canned transcripts for the smoke-test set
│   │   │   └── stub-llm-responses/         # canned LLM responses for deterministic tests
│   │   └── Snapshots/
│   │       └── prompts/
│   ├── ClaudeSummarizerTests/
│   ├── AIReviewerInterfaceTests/
│   │   ├── ImmutabilityContractTests.swift  # Dec 5.3 — no reviewer code path opens transcript/diarization for write
│   │   └── SuggestionSchemaRoundTripTests.swift
│   ├── ClaudeAIReviewersTests/
│   │   ├── ClaudeDiarizationReviewerTests.swift # against stubbed Anthropic responses
│   │   └── PromptCachingContractTests.swift     # cache_control marker placement
│   ├── ReviewDiarizationTests/
│   │   ├── ReviewDiarizationStageTests.swift    # flag-off short-circuit; subprocess lifecycle
│   │   └── RendererPureFunctionTests.swift      # (diarization, overrides, splits) → RenderedTranscript golden fixtures (Dec 5.4)
│   ├── WhisperKitTranscriberTests/
│   ├── WhisperKitDiarizerTests/
│   ├── GoogleCalendarSourceTests/
│   ├── VaultGlossaryTests/
│   ├── PersistTests/
│   │   ├── FrontmatterRendererTests.swift  # snapshot tests over the Dec 2.2 variants
│   │   ├── FilenameResolverTests.swift     # the Dec 2.4 slug-edge-case table
│   │   └── VaultWriterTests.swift
│   ├── VerifyTests/
│   │   └── VerifierConcurrencyTests.swift  # Dec 4.3 idempotency under cross-process race
│   ├── NotificationsTests/
│   └── TestSupport/                        # shared fixtures + stub strategies (per step-05 rule)
│       ├── StubSummarizerStrategy.swift
│       ├── StubCalendarSource.swift
│       ├── StubTranscriberStrategy.swift
│       ├── StubDiarizerStrategy.swift
│       ├── StubDiarizationReviewerStrategy.swift # Dec 5.1 stub for tests
│       └── TestComposition.swift           # makeTestOrchestrator(...) helper
│
├── App/
│   ├── Auricle.xcodeproj/                  # the only Xcode project — produces both binaries
│   │   └── ...                             # (GUI scheme + CLI scheme; both depend on SwiftPM lib)
│   │
│   ├── Auricle/                            # GUI executable target source
│   │   ├── AuricleApp.swift                # @main App struct — composition root for GUI
│   │   ├── MainWindow/                     # single-window architecture (UX spec Step 9 Principle 8)
│   │   │   ├── MainWindowView.swift        # row-expand IA: meeting list + sheet presenter (Dec 4.6)
│   │   │   ├── MeetingListView.swift       # LazyVStack of MeetingRowView cells; sort priority per Dec 4.6
│   │   │   ├── MeetingRowView.swift        # collapsed/expanded row with @State expanded: Bool
│   │   │   ├── OperationsConsoleView.swift # row-expand contents: pipeline timeline + actions + log line
│   │   │   ├── PipelineTimelineView.swift  # mini visualization of per-stage progress
│   │   │   ├── OnLaunchBannerView.swift    # awaiting-attribution queue banner + on-launch banner (Dec 4.2 + 4.6)
│   │   │   ├── UpcomingEventStripView.swift # calendar-attendee strip (J0, J1)
│   │   │   ├── RollingCostFooterView.swift # 30-day cost widget (Dec 4.6 + UX Step 10 Round-2)
│   │   │   ├── AttributionSheet.swift      # .sheet(item: $attributingMeetingID) — replaces former AttributionWindow
│   │   │   ├── AttributionViewModel.swift  # @Observable; owns attribution.json + diarization_suggestions.json state
│   │   │   ├── AttributionTranscriptPane.swift # disclosure-collapsed transcript pane (UX spec Step 10 Round-2)
│   │   │   ├── TranscriptParagraph.swift   # per-paragraph row: speaker label + ParagraphPlayButton + reassign + AI hint
│   │   │   ├── SpeakerRow.swift            # speaker row: SnippetPlayer + ThisIsMeButton + autocomplete + optional AIHintChip (over-segmentation case)
│   │   │   ├── ThisIsMeButton.swift        # `.bordered` style; states: idle / active (✓ when this row maps to self.wikilink) / disabled (Settings-required, reads "Set me first…");
│   │   │   │                               # micro-interaction: subtle attention-pulse on first-run when zero speakers attributed AND focused, gated by Reduce Motion (NFR-A5 — no pulse, only color-state)
│   │   │   ├── SnippetPlayerView.swift     # AVPlayerView-wrapped snippet playback
│   │   │   ├── ParagraphPlayButton.swift   # shared AVAudioFile + seek (Amelia's MVP scoping)
│   │   │   ├── AIHintChip.swift            # 🤖 chip with expand/collapse + accept/reject (Dec 5.7);
│   │   │   │                               # accessibility contract (NFR-A1, NFR-A3): collapsed-state `accessibilityLabel` summarizes hint count + kind (e.g. "AI hint: may be 2 voices");
│   │   │   │                               # expanded-state full reasoning text + Apply/Reject buttons are screen-reader navigable;
│   │   │   │                               # color is never the sole conveyor — chip carries 🤖 glyph + label (NFR-A3)
│   │   │   ├── TrustCalibrationFooter.swift # accept-rate display in Attribution sheet (Dec 5.7)
│   │   │   └── CoverageStrip.swift         # calendar-attendee gap-awareness diagnostic
│   │   ├── DoctorWindow/                   # rare user-initiated separate window — Principle 8 carve-out
│   │   │   └── DoctorView.swift
│   │   ├── Settings/                       # macOS Settings scene (Cmd-,) — Principle 8 carve-out
│   │   │   └── SettingsView.swift          # vault path, model, retention window, diarization_review.enabled
│   │   ├── DesignSystem/                   # auricle-specific atomic components (UX spec Step 11)
│   │   │   ├── DesignTokens.swift          # colors, motion, spacing — no hardcoded values elsewhere
│   │   │   ├── RecordingIndicator.swift    # privacy-contract surface; pulse + Reduce Motion behavior
│   │   │   ├── StateChip.swift             # per-meeting state visibility; 8 variants per FailureCategory
│   │   │   ├── CountdownAnnotation.swift   # retention countdown ("Audio deletes in 5 days")
│   │   │   ├── VarianceWarningGlyph.swift  # acoustic diarization uncertainty hint
│   │   │   ├── CalendarAttendeeBadge.swift # matched / unmatched / candidate states
│   │   │   └── WaveformView.swift          # pre-computed amplitude envelope render
│   │   ├── AppDelegate.swift               # NSApplicationDelegate adapter for SwiftUI
│   │   ├── NotificationDelegate.swift      # UNUserNotificationCenterDelegate (Dec 4.3)
│   │   ├── URLSchemeHandler.swift          # handles auricle:// URLs
│   │   ├── Info.plist                      # NS*UsageDescription strings (Dec 4.4)
│   │   ├── Auricle.entitlements            # Hardened Runtime; sandbox OFF
│   │   └── Assets.xcassets/
│   │
│   └── auricle-cli/                        # CLI executable target source
│       ├── main.swift                      # composition root for CLI
│       ├── Verbs/                          # one file per swift-argument-parser subcommand
│       │   ├── RecordVerb.swift            # binding contract (Dec 1.5)
│       │   ├── StopVerb.swift
│       │   ├── DiscardVerb.swift
│       │   ├── RunVerb.swift
│       │   ├── AttributeVerb.swift
│       │   ├── KeepVerb.swift
│       │   ├── ListVerb.swift
│       │   ├── StatusVerb.swift
│       │   ├── ConfigVerb.swift            # Get + Set nested subcommands
│       │   ├── DoctorVerb.swift
│       │   ├── BareInvocation.swift        # `auricle` (no args) status surface
│       │   └── InternalStageWorker.swift   # hidden subcommand for GUI subprocess invocation
│       │                                   # — NOT in NFR-I7 binding contract; see boundaries
│       ├── Output/
│       │   ├── HumanFormatter.swift        # plain text / TTY-color stderr
│       │   └── JSONFormatter.swift         # camelCase dialect; schemaVersion-stamped
│       └── ExitCodes.swift                 # Dec 1.5 exit-code mapping
│
├── scripts/
│   ├── setup-trust.sh                      # per-Mac Gatekeeper trust setup (Distribution Model)
│   ├── build-release.sh                    # xcodebuild + codesign + (v1.1) Sparkle appcast
│   └── lint.sh                             # local swiftformat + swiftlint runner
│
├── assets/
│   └── AndrewCodeSigningCA.cer             # public CA cert (no private key)
│
└── _bmad-output/                           # planning artifacts (this document, PRD, etc.)
    ├── brainstorming/
    └── planning-artifacts/
        ├── architecture.md
        ├── prd.md
        └── ...
```

### Architectural Boundaries

#### Module Boundaries (mechanical, build-time-enforced)

`Package.swift` is the single declarative source of truth for module boundaries. The dependency graph (truncated to the load-bearing edges):

```
Core ←──────────────────── (depended on by every other library target)

State          → Core
Telemetry      → Core, State
Permissions    → Core
Orchestrator   → Core, State, Telemetry, Permissions

SummarizerInterface → Core
DiarizerInterface   → Core
TranscriberInterface → Core
AIReviewerInterface → Core, DiarizerInterface, TranscriberInterface  # consumes diarization + transcript artifacts (Dec 5.1)
CalendarInterface    → Core

Transcribe     → Core, State, Telemetry, TranscriberInterface, DiarizerInterface
Diarize        → Core, State, Telemetry, DiarizerInterface
ReviewDiarization → Core, State, Telemetry, AIReviewerInterface  # the reviewing_diarization stage (Dec 5.3)
Capture        → Core, State, Telemetry, Permissions
Attribute      → Core, State, Telemetry, AIReviewerInterface  # consumes diarization_suggestions.json schema for sheet rendering
Summarize      → Core, State, Telemetry, SummarizerInterface, CalendarInterface, VaultGlossary
Persist        → Core, State, Telemetry
Verify         → Core, State, Telemetry, Notifications
Notifications  → Core, State
VaultGlossary  → Core

ClaudeSummarizer        → Core, SummarizerInterface
ClaudeAIReviewers       → Core, AIReviewerInterface, ClaudeSummarizer  # reuses AnthropicHTTPClient + KeychainAPIKey (Dec 5.2)
WhisperKitTranscriber   → Core, TranscriberInterface
WhisperKitDiarizer      → Core, DiarizerInterface
GoogleCalendarSource    → Core, CalendarInterface

# Composition roots — only these may import concrete-strategy targets
AuricleApp     → Orchestrator, ClaudeSummarizer, ClaudeAIReviewers, WhisperKitTranscriber, WhisperKitDiarizer, GoogleCalendarSource, every stage target, every UI dependency
auricle-cli    → Orchestrator, ClaudeSummarizer, ClaudeAIReviewers, WhisperKitTranscriber, WhisperKitDiarizer, GoogleCalendarSource, every stage target, swift-argument-parser
```

**Critical edges that DO NOT exist** (rejected by `Package.swift`):
- Stage targets do NOT depend on each other (Capture cannot import Transcribe; Transcribe cannot import Diarize even though they share a subprocess at runtime — the sharing is composed at the composition root, not via cross-target imports).
- Strategy targets do NOT depend on each other (`ClaudeSummarizer` cannot import `WhisperKitTranscriber`).
- The `Orchestrator` target does NOT import any concrete strategy — only the interface targets. Concrete wiring lives only in composition roots.
- Test targets depend only on their own source target, the `TestSupport` target, and any required interface target. They do NOT import concrete strategies (tests use stubs).

#### Subprocess Boundaries (runtime, not build-time)

Per Decision 1.1, the subprocess boundary is a runtime decision dispatched by `Orchestrator/SubprocessDispatcher.swift`. Runtime boundaries in MVP:

| Stage | Process | Spawned by | Bundled invocation |
|---|---|---|---|
| `record` / `capture` | GUI process (in-app) | N/A | direct call |
| `transcribe` + `diarize` (combined) | Subprocess | `SubprocessDispatcher.spawn(.transcribe, meetingId:)` | `auricle-cli __internal-stage transcribe <id> --worker-protocol-version 1` |
| `reviewing_diarization` | **Dedicated subprocess** (Dec 5.3); spawned AFTER WhisperKit subprocess terminates | `SubprocessDispatcher.spawn(.reviewDiarization, meetingId:)` | `auricle-cli __internal-stage review-diarization <id> --worker-protocol-version 1` |
| `attribute` | GUI process (in-app, **sheet on main window** per Dec 4.6 / UX Step 9 Principle 8 — NOT a separate window) | N/A | direct call |
| `summarize` | Subprocess | `SubprocessDispatcher.spawn(.summarize, meetingId:)` | `auricle-cli __internal-stage summarize <id> --worker-protocol-version 1` |
| `persist` | GUI process (in-app) | N/A | direct call |
| `notify` | GUI process (in-app) | N/A | direct call |
| `verify` | GUI process or CLI process — wherever the call originates | N/A | direct call into `Verifier` actor |

**The `__internal-stage` hidden subcommand** (Step-06 refinement, accepted from Advanced Elicitation):

The GUI-spawned subprocess work uses a deliberately-hidden CLI subcommand — `auricle-cli __internal-stage <stage> <id> --worker-protocol-version <N>` — that is **NOT** part of the NFR-I7 binding contract. Distinguishing properties:

- Implemented in `App/auricle-cli/Verbs/InternalStageWorker.swift` with `shouldDisplay: false` on its `CommandConfiguration`
- Excluded from `auricle help` output and shell-completion scripts
- Independently versioned via `--worker-protocol-version` flag (separate from CLI binding-contract version)
- Direct-coupled to `SubprocessDispatcher` only; no documentation surface for users
- May be renamed, restructured, or replaced wholesale across releases without violating NFR-I7

**Why the separation:** Decision 1.5's user-facing CLI surface (`record`, `run`, `keep`, etc.) is a binding product contract — renames and removals require major-version bumps. The GUI-internal worker invocation has different evolutionary pressures (refactoring, telemetry-shape changes, future stage splits) and shouldn't drag the user-facing surface along. Splitting the worker into a hidden subcommand keeps the binding rule applying only where it should — to the verbs Andrew (or any future user) types in a terminal.

**CLI exposure for users is independent and unchanged:** the user-facing `auricle run --only transcribe <id>` (Decision 1.5) still works for terminal users invoking the same stage. The two paths converge on the same `TranscribeStage` library code, but route through different CLI entry points (binding `RunVerb` vs hidden `InternalStageWorker`). Library code never knows which path invoked it.

**Bundle layout for subprocess invocation:** the Xcode build process bundles the CLI executable inside the GUI `.app`:

```
Auricle.app/
└── Contents/
    ├── MacOS/
    │   ├── Auricle              # the GUI binary
    │   └── auricle-cli          # the CLI binary (for subprocess dispatch from GUI)
    ├── Info.plist
    ├── Resources/
    │   └── Assets.car
    └── _CodeSignature/
```

The GUI spawns the CLI via `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")`. The CLI binary is also installable on `$PATH` via a separate copy (e.g., to `~/.local/bin/auricle`) for terminal use.

#### Data Boundaries

| Data class | Storage | Read by | Written by |
|---|---|---|---|
| Meeting state, audit log, retention queue, telemetry rollup | SQLite at `~/Library/Application Support/com.auricle.app/auricle.sqlite3` (Dec 2.1) | Every stage via `StateStore` | Per Dec 2.1's write-authority matrix |
| Per-meeting in-flight artifacts (audio, transcript, diarization, attribution, summary, calendar, glossary) | Cache-dir at `~/Library/Caches/com.auricle.app/<meeting-id>/` (Dec 1.3) | The next stage in the pipeline; CLI inspection verbs | The producing stage; via `CacheArtifactWriter` |
| Vault notes (the user-facing output) | `<vault_path>/<meetings_subdir>/<filename>.md` (Dec 2.5) | Obsidian, the user; (read by `Persist` for `--reattribute`) | `Persist` via `VaultWriter` |
| Secrets (Anthropic key, Google OAuth refresh token) | macOS Keychain (NFR-S1) | `ClaudeSummarizer/KeychainAPIKey`, `GoogleCalendarSource/GoogleOAuthFlow` | OAuth flow + first-run config setup |
| Glossary cache | `~/Library/Caches/com.auricle.app/glossary-cache.json` | `Summarize`'s `GlossaryInjector` | `VaultGlossary/VaultGlossaryBuilder` |
| Configuration | TOML or JSON at `~/Library/Application Support/com.auricle.app/config.toml` | All processes via `Core/Config` | GUI Settings UI; `auricle-cli config set` |
| Logs | `os_log` (subsystem `com.auricle.app`) | `auricle status <id>` (`log show` invocation); macOS Console.app | `Core/Log` facade |

**No data crosses these boundaries by any mechanism other than the ones in the table.** No XPC, no shared memory, no UserDefaults for cross-process state. (UserDefaults may be used for in-process GUI window state — geometry, last-selected meeting ID — but never for state that subprocesses also need to read.)

#### Composition-Root Boundaries

The two composition roots — `App/Auricle/AuricleApp.swift` and `App/auricle-cli/main.swift` — are the only places where concrete strategies are instantiated. Their bodies look structurally similar:

```swift
// App/Auricle/AuricleApp.swift (sketch)
@main
struct AuricleApp: App {
    let orchestrator: Orchestrator = {
        let summarizer = ClaudeCitationsSummarizer(/* with substring as fallback */)
        let transcriber = WhisperKitTranscriber()
        let diarizer = WhisperKitDiarizer()
        let diarizationReviewer = ClaudeDiarizationReviewer()  // Dec 5.2; flag-controlled at call time
        let calendar = GoogleCalendarSource()
        return Orchestrator(
            summarizer: summarizer,
            transcriber: transcriber,
            diarizer: diarizer,
            diarizationReviewer: diarizationReviewer,
            calendar: calendar,
            stateStore: StateStore.production(),
            telemetry: TelemetryRecorder.production()
        )
    }()
    var body: some Scene { /* ... */ }
}

// App/auricle-cli/main.swift (sketch)
@main
struct AuricleCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auricle",
        subcommands: [
            RecordVerb.self, StopVerb.self, DiscardVerb.self,
            RunVerb.self, AttributeVerb.self, KeepVerb.self,
            ListVerb.self, StatusVerb.self, ConfigVerb.self,
            DoctorVerb.self,
            InternalStageWorker.self  // hidden — shouldDisplay: false
        ],
        defaultSubcommand: BareInvocation.self
    )
    // composition lives in a shared `Composition.shared` instance read by each verb
}
```

Tests use a third composition root, `Tests/TestSupport/TestComposition.swift`'s `makeTestOrchestrator(...)`, which wires stub strategies.

### Requirements to Structure Mapping

#### FR-Cluster Mapping

| FR cluster | PRD FRs | Primary target(s) | Supporting targets |
|---|---|---|---|
| Capture | FR1–FR10 | `Capture` | `Permissions`, `State` |
| Transcribe + Diarize | FR17–FR20 | `Transcribe`, `Diarize` | `WhisperKitTranscriber`, `WhisperKitDiarizer`, `TranscriberInterface`, `DiarizerInterface`, `State` |
| AI-assisted correction (Decision Group 5) | UX Spec Step 10; FR55–FR57 (jargon, Phase 1 inline); new FRs TBD for diarization (Phase 1 flagged-off) and transcription (Phase 3) | `ReviewDiarization`, `AIReviewerInterface`, `ClaudeAIReviewers` | `App/Auricle/MainWindow/AttributionSheet.swift` + `AttributionTranscriptPane.swift` + `AIHintChip.swift` + `TrustCalibrationFooter.swift`, `State.telemetry` columns |
| Attribute | FR21–FR27 | `Attribute` | `App/Auricle/MainWindow/AttributionSheet.swift` (single-window architecture per UX Step 9 Principle 8 — replaces former `App/Auricle/AttributionWindow/`), `State` |
| Summarize | FR28–FR34 | `Summarize` | `SummarizerInterface`, `ClaudeSummarizer`, `VaultGlossary`, `CalendarInterface`, `GoogleCalendarSource` |
| Persist | FR35–FR41 | `Persist` | `Core/AtomicWriter`, `State` |
| Notify | FR42–FR44 | `Notifications` | `App/Auricle/NotificationDelegate`, `Verify` |
| Retention | FR45–FR50 | `Verify`, `Orchestrator/RetentionScheduler` | `State` |
| Calendar | FR51–FR54 | `GoogleCalendarSource` | `CalendarInterface`, `Summarize` (consumer) |
| Vault glossary | FR55–FR57 | `VaultGlossary` | `Summarize` (consumer) |
| Config + Permissions | FR58–FR60 | `Core/Config`, `Permissions` | `App/Auricle/Settings`, `auricle-cli/Verbs/ConfigVerb` |
| Logging | FR61 | `Core/Log` | every target (logging is cross-cutting) |
| Crash recovery | FR62, NFR-R6 | `Orchestrator/CrashRecovery` | `State` |
| Cmd-Q graceful exit | FR64 | `App/Auricle/AppDelegate` | — |
| Sparkle (v1.1) | FR65 | `App/Auricle` (Sparkle SDK) | — |
| Telemetry | FR66 | `Telemetry`, `State.telemetry` table | every stage (each contributes UPSERT columns) |
| State machine + pending list | FR13–FR16 | `Orchestrator`, `State` | `auricle-cli/Verbs/ListVerb`, `App/Auricle/MainWindow` |
| CLI surface | FR11–FR12 + Decision 1.5 binding contract | `auricle-cli` | every library target |

#### Cross-Cutting Concern Mapping

| Concern (from §Cross-Cutting Concerns Identified) | Lives in |
|---|---|
| 1. Pipeline state machine + SQLite schema | `State`, `Orchestrator` |
| 2. Cache-dir handoff contract | `Core/CacheArtifactWriter`, `Core/CanonicalTranscript`, plus per-stage Codable types in each interface target |
| 3. Atomic-write primitive | `Core/AtomicWriter` (single implementation; bypass-detection lint rule per step-05) |
| 4. Quote-grounding validator | `ClaudeSummarizer/CitationGroundingValidator` + `ClaudeSummarizer/SubstringGroundingValidator` (validators are tightly coupled to their grounding strategy per Dec 3.1) |
| 5. Frontmatter schema and versioning | `Persist/FrontmatterRenderer` (writer); `Persist/PersistStage`'s `--reattribute` reader (reader) |
| 6. Structured logging convention | `Core/Log` (facade enforced by lint rule) |
| 7. Notification → URL-scheme → retention-arm wiring | `Notifications/`, `Verify/Verifier`, `App/Auricle/NotificationDelegate`, `App/Auricle/URLSchemeHandler` |
| 8. Permission detection and remediation | `Permissions/PermissionChecker`, `App/Auricle/DoctorWindow`, `auricle-cli/Verbs/DoctorVerb` |
| 9. Configurable engine strategy | `SummarizerInterface` + composition-root wiring |
| 10. Telemetry collection at stage boundaries | `Telemetry/StageEventLogger`, `Telemetry/TelemetryRecorder` (both wrapped by `StageRunner.run`) |
| 11. Vault frontmatter for vault consumers; SQLite for operational state | architectural principle — enforced by `Persist/FrontmatterRenderer`'s narrow input shape (`MeetingForFrontmatter`) which intentionally excludes operational fields |

### Integration Points

#### Internal Communication

- **Library-to-library** (within one process): direct Swift function calls through public APIs. No event bus, no notification center for project events (NotificationCenter is reserved for AppKit-system notifications).
- **GUI ↔ subprocess**: spawn CLI via `Process` with `__internal-stage` args; SQLite + cache-dir for state and artifacts; subprocess exit code maps to retry/surface decision.
- **Orchestrator ↔ stages**: `StageRunner.run { ... }` wraps every stage call, owning the two-transaction pattern + telemetry emission. Stages return a typed outcome value; the runner translates it to SQL.
- **Notification ↔ Verifier**: `App/Auricle/NotificationDelegate` extracts payload, calls `verifier.markVerified(meetingId:)`. Same call path used by `auricle keep <id>` (CLI) and the in-window confirm button (GUI).
- **`auricle://` URL scheme**: GUI registers handler at launch; CLI dispatches `NSWorkspace.shared.open(URL(string: "auricle://attribute/<id>"))` to invoke the GUI's attribution flow from a terminal.

#### External Integrations

| External system | Library target | Auth | Failure mode |
|---|---|---|---|
| WhisperKit | `WhisperKitTranscriber`, `WhisperKitDiarizer` | None (local) | Subprocess restart + 1 retry → `transcription_failed` (Dec 4.2) |
| Anthropic Claude API | `ClaudeSummarizer/AnthropicHTTPClient` | API key from Keychain | Exponential backoff to 5min cap → `summarization_failed` (Dec 4.2); fallback strategy first (Dec 3.3) |
| Google Calendar API v3 | `GoogleCalendarSource` | OAuth 2.0 PKCE; refresh token in Keychain | Graceful degradation: meeting publishes with `auricle/needs-calendar-enrichment` tag (FR54) |
| ScreenCaptureKit + AVFoundation | `Capture` | TCC permissions (Screen Recording, Microphone) | `capture_failed` (permanent); permission revocation mid-stream saves partial audio (Dec 4.4) |
| UNUserNotificationCenter | `Notifications`, `App/Auricle/NotificationDelegate` | TCC permission (Notifications) | Compensating surfaces in main window + `auricle list` (Dec 4.2) |
| Obsidian (vault consumer) | `Persist/VaultWriter` (writer); `obsidian://open` URL scheme (notify click) | None (filesystem) | If Obsidian not installed, click handler still marks verified — open is a courtesy (Dec 4.3) |
| macOS Keychain | `ClaudeSummarizer/KeychainAPIKey`, `GoogleCalendarSource/GoogleOAuthFlow` | TCC (implicit) | Missing key → `auricle doctor` flag; surfaced as user-actionable |
| Sparkle (v1.1) | `App/Auricle` (Sparkle SPM dependency) | EdDSA-signed appcast (NFR-S9) | Update failure is non-fatal; user can ignore |

#### Data Flow (a single happy-path meeting)

```
USER: clicks Record (or runs `auricle record`)
  ↓
[GUI process / CLI process]
  Capture/CaptureSession → writes audio.wav to cache-dir
  StateStore: meetings.state = 'recording' → 'captured'
  StageEventLogger: capture started, capture completed
  ↓
USER: clicks Stop (or `auricle stop`)
  ↓
[GUI process spawns subprocess via __internal-stage; CLI process runs in-place via run --only]
  SubprocessDispatcher → auricle-cli __internal-stage transcribe <id> --worker-protocol-version 1
    Transcribe/TranscribeStage + Diarize/DiarizeStage (shared subprocess)
    WhisperKitTranscriber → transcript.json
    WhisperKitDiarizer → diarization.json + snippets/speaker_N.wav
    StateStore: 'transcribing' → 'reviewing_diarization'
  WhisperKit subprocess exits (frees ~2-4GB)
  ↓
[GUI process spawns reviewer subprocess — Dec 5.3]
  SubprocessDispatcher → auricle-cli __internal-stage review-diarization <id> --worker-protocol-version 1
    ReviewDiarization/ReviewDiarizationStage
    ClaudeAIReviewers/ClaudeDiarizationReviewer (Haiku) → diarization_suggestions.json
      (or empty stub when diarization_review.enabled = false; <100ms passthrough)
    StateStore: 'reviewing_diarization' → 'awaiting_attribution'
  ↓
[GUI process — interactive, single-window architecture per UX Step 9 Principle 8]
  Notification fires + main-window banner updates ("⏳ N meetings awaiting your attribution")
  User clicks row OR banner action → AttributionSheet rises (.sheet(item:) on MainWindowView)
  Attribute/AttributionStage → attribution.json (with segment_overrides + segment_splits per Dec 5.4)
  AttributionSheet dismisses; main window returns to focus
  StateStore: 'attributing' → 'summarizing'
  ↓
[GUI process spawns subprocess]
  SubprocessDispatcher → auricle-cli __internal-stage summarize <id> --worker-protocol-version 1
    Summarize/SummarizeStage
    VaultGlossary/VaultGlossaryBuilder → glossary
    GoogleCalendarSource → calendar.json (if reachable)
    SummarizerOrchestrator(primary: ClaudeCitations, fallback: ClaudeSubstring)
    Validator → summary.json
    StateStore: 'summarizing' → 'published' (after persist)
  ↓
[GUI process]
  Persist/PersistStage
  FrontmatterRenderer → markdown
  VaultWriter → atomic write to <vault>/<filename>.md
  Notifications/Notifier → fires UNUserNotification
  StateStore: 'published' → 'awaiting_verification'
  ↓
USER: clicks notification (or runs `auricle keep <id>`)
  ↓
[GUI process — NotificationDelegate]
  Verify/Verifier.markVerified(...)
    StateStore: meetings.verified_at = now()
    StateStore: insert retention_timers row
    StateStore: 'verified'
  NSWorkspace.open("obsidian://open?file=<note>")
  ↓
[Background, after retention window]
  Orchestrator/RetentionScheduler
  StateStore: 'retention_expired'
  Filesystem: cache-dir <meeting-id>/ deleted
```

Every arrow is either:
- a public-API call (Swift function within one process)
- a SQLite write read by another process via `StateStore`
- a cache-dir artifact read by the next stage via `CacheArtifactWriter`

### File Organization Patterns

#### Configuration Files
- Repo-level config: `Package.swift`, `.swiftformat`, `.swiftlint.yml`, `.github/workflows/*.yml`, `scripts/*.sh`
- Per-target config: not used — targets self-describe via `Package.swift`
- Runtime config (user): `~/Library/Application Support/com.auricle.app/config.toml` (managed by `Core/Config`)

#### Source Organization
Per step-05 structural rules: one primary type per file, flat layout within each target until a target exceeds ~15 source files. The targets above are sized to stay within that bound; if any exceeds it, it splits rather than introduces subdirectories.

#### Test Organization
One test target per source target, named `<Target>Tests`. Test fixtures under `Tests/<Target>Tests/Fixtures/`. Snapshot outputs under `Tests/<Target>Tests/Snapshots/`. Shared stubs and `makeTestOrchestrator(...)` in `Tests/TestSupport/`. Swift Testing for new code; XCTest only where commented.

#### Asset Organization
- Repo assets (cert, etc.): `assets/`
- App bundle assets (icons, color sets): `App/Auricle/Assets.xcassets/`
- Test fixtures: per-test-target `Fixtures/` and `Snapshots/` subdirectories

### Development Workflow Integration

#### Library Development
`swift test` from the repo root runs all SwiftPM library-target tests without invoking Xcode. This is the dominant inner-loop iteration path for Capture/Transcribe/Summarize/Persist library code. The first ~10 implementation stories likely never need to open Xcode.

#### Executable Development
`xcodebuild -project App/Auricle.xcodeproj -scheme Auricle build` builds the GUI; `-scheme auricle-cli` builds the CLI. From Xcode's UI, both schemes are runnable from the scheme picker.

#### Build Process
- **CI (GitHub Actions)**:
  1. `swift build` — verify SwiftPM library compiles
  2. `swift test` — run all library tests including contract tests, snapshot tests, the canonicalization invariant test
  3. `xcodebuild build` for both Xcode schemes — verify executables compile
  4. `swiftformat --lint` and `swiftlint` — fail on naming or layout drift; fail on helper-bypass detections
- **Release** (`scripts/build-release.sh`):
  1. `xcodebuild archive` for the GUI scheme
  2. `codesign` with the leaf cert chained to "Andrew Code Signing CA" (per Distribution Model)
  3. (v1.1) Generate Sparkle appcast entry with EdDSA signature
  4. Output: `Auricle-<version>.dmg` (or `.zip`) ready for GitHub Releases

#### Deployment Structure
- GitHub Releases hosts the signed `.app`/`.dmg` and the Sparkle appcast XML (v1.1+)
- Per-Mac install: download → `cp -R Auricle.app /Applications/` → run `scripts/setup-trust.sh` once (per Distribution Model). Subsequent updates flow through Sparkle without re-trust.

### Reconciliation Notes

**Step-05 path correction:** Step-05's "Composition Roots" referenced `Sources/auricle-cli/main.swift` for the CLI composition root. This step finalizes that path as `App/auricle-cli/main.swift` (the CLI is an Xcode "Command Line Tool" target inside the `App/Auricle.xcodeproj` project, per the Starter Template Evaluation). The substantive rule is unchanged — there is exactly one CLI composition root, and concrete strategies are instantiated only there — only the path is corrected. Step-05's other paths (`App/Auricle/AuricleApp.swift` for the GUI; `Tests/TestSupport/TestComposition.swift` for tests) are unchanged.

**`__internal-stage` subcommand (step-06 Advanced Elicitation refinement):** GUI-spawned subprocess work uses a hidden `auricle-cli __internal-stage <stage> <id>` subcommand instead of repurposing the user-facing `auricle run --only <stage> <id>` verb. This decouples the GUI worker contract from the NFR-I7 user-facing binding contract — internal worker invocations can evolve (rename flags, restructure args, split stages) without forcing major version bumps. The user-facing `run --only <stage>` verb continues to work for terminal users invoking the same stage; both paths converge on the same library code.

## Architecture Validation Results

This validation pass combined a structured walk through coherence, requirements coverage, and implementation readiness with a multi-agent cynical-review roundtable (Winston/architect, Amelia/developer, Mary/analyst, Sally/UX in Round 1; Winston + John/PM in Round 2). The roundtable substantially changed the gap inventory from the initial structured walk; the final scope was driven by a "single-user dogfood reality" framing — the architecture is mental scaffolding for a tool Andrew is the engineer AND user of, not a product launch.

### Coherence Validation ✓

The 25 decisions across Groups 1–5 are internally consistent and do not contradict each other. (Group 5 — AI-Assisted Correction — was added after the UX-design workflow surfaced AI correction as a product category; it amends Decisions 1.2, 1.3, 2.1, 4.2, 4.5, and 4.6 in place rather than displacing them, and adds 7 new Decisions 5.1–5.7.) The roundtable surfaced under-specification (not contradiction) in three places, all folded back into the relevant decisions in place rather than tracked as a delta list:

- **Decision 4.2 — Wall-clock budgets and stale-active-state detection** added: in-session subprocess SEGFAULT no longer leaves the chip showing "in-flight" indefinitely. Detection runs in the `Orchestrator` periodic sweep; failure synthesis flows through `StageRunner.synthesizeFailure(...)`. (Round-1 finding from Sally + Winston.)
- **Decision 4.5 + Decision 2.1 telemetry table** updated: NFR-P1 budget now applies to `time_to_attribution_ready_seconds` (machine-time only); a separate `time_to_vault_note_seconds` captures user-perceived end-to-end latency including `attribute` time. The original `time_to_notification_seconds` column is retired in favor of the dual columns. (Round-1 finding from Sally.)
- **Decision 4.6 — Stale-active-state synthesized failure surface** added to the failure-visibility table: completes the "user never sees a lying spinner" guarantee. (Round-1 finding from Sally + Winston, mechanically wired by the new `StageRunner.synthesizeFailure` API.)

### Requirements Coverage Validation ✓

13 capability areas mapped to specific targets in step-06; MVP coverage 95%+. NFR coverage comprehensive after the NFR-P1 dual-column reframing above. Remaining FR27 gap (attribution confidence visualization) deferred to UX-design phase.

### Implementation Readiness Validation — GREEN

**Story 1 (project initialization):** unblocked. Scaffolding doesn't depend on any of the deferred items.

**Story 2 (`Core` primitives):** unblocked. The `URLRouter`, `MeetingIDResolver` protocol, and other small API surfaces surfaced by Amelia get specified in this story, not the architecture.

**Story 3+:** unblocked. The deferred items (cache durability relocation, orphan-subprocess lock-file, closed-loop trust-calibration substrate) are documented as known sharp edges; if any bites in dogfood, future-Andrew addresses it then.

### Gap Disposition

The Round-1 roundtable surfaced 11 gaps. After Round 2's scope-call, they sort into four categories. The `J1` reference in each category answers "does this break Andrew defaults to auricle by month 2?"

**Folded into existing decisions in place (3 — the "preserve J1" set):**

1. **Silent-spinner UX (Sally + Winston)** — wall-clock budgets in Decision 4.2; stale-detection synthesis row in Decision 4.6. The only Round-1 finding that genuinely threatens J1 trust on meeting #3.
2. **NFR-P1 reframing (Sally)** — dual telemetry columns in Decision 2.1 + Decision 4.5. Honest measurement.
3. **TOML config format** — confirmed (Starter Template Evaluation already accepts; one SPM dep, `TOMLKit` or similar).

**Deferred to story-time specification (5 — too detailed for architecture, perfect for the story that touches them):**

4. **`StageRunner.synthesizeFailure(meetingID:reason:)` API** (Amelia) — concrete signature and `metadata_json` shape land in Story 6 (Subprocess wiring). The architecture commits to the existence of the API (referenced in Decision 4.2 + 4.6 above); Story 6 specifies the implementation.
5. **`URLRouter` in `Core` + `auricle://` URL grammar** (Amelia + Sally) — Story 2 (`Core` primitives) or Story 7 (CLI skeleton) lands the parser, route enum, and malformed-URL toast UX.
6. **VM-factory pattern for SwiftUI views** (Amelia) — Story 8+ (first SwiftUI window) chooses between `EnvironmentObject`-injected factory vs. `@Observable` (Swift 5.9+) with manual subscription. Defer the choice until the first concrete view exists.
7. **`MeetingIDResolver` protocol split** (Amelia) — Story 2 splits the type when the first test stub needs it.
8. **Malformed `auricle://` URL toast** (Sally) — Story 8+ (GUI shell) lands the toast component.

**Documented known sharp edges (defer with eyes open — N=1 dogfood absorbs them; revisit if they bite):**

9. **Cache-dir durability domain mismatch (Winston)** — `~/Library/Caches/com.auricle.app/<meeting-id>/` is OS-evictable. Per-meeting JSON artifacts could theoretically vanish under disk pressure between an artifact write and the SQLite Txn B that marks the stage complete. **Mitigation accepted as known sharp edge:** the periodic-sweep stale-detection (Decision 4.2 lock-in above) catches this case as a normal failed transition; the meeting transitions to `*_failed` and `auricle run <id>` re-runs the stage. Idempotency holds. The non-determinism risk (LLM summarize re-running and producing a different summary than the first execution) is acknowledged; the user notices and accepts. If this proves disruptive in dogfood, future-Andrew relocates artifacts to Application Support — bounded refactor.
10. **Orphan subprocess after GUI force-quit (Winston)** — same mitigation: stale-detection sweep + crash-recovery on next launch. Lock-file mechanism deferred until a concrete race shows up.
11. **Closed-loop trust calibration is foreclosed for now (Mary)** — DP2 (no confidence flags in vault) + DP4 (re-publish writes a sibling, never modifies original) + the explicit decision NOT to add a fourth persistence layer for the diff substrate together mean the v1.1 closed-loop telemetry would need to instrument forward from when it's built (3 months of dogfood data after column addition) rather than retroactively. Andrew's `auricle stats` (v1.1) drop rates remain process metrics, not validated quality metrics, until that instrumentation exists. **This is an accepted scope choice**, not a hidden bug — Mary's diagnosis is preserved as a known limitation in this validation section. The fix (capture vault file hash on persist; v1.1 reads + diffs on a background job) is specified for v1.1; not pre-instrumented.

**Deferred to UX-design phase (1):**

12. **First-meeting onboarding (Sally)** — architecture supports it (the SwiftUI window state machine is exposed for whatever onboarding UI fills it); next BMad workflow (UX design, narrowly scoped to attribution UI + main-window state surfaces per the user's stated next step) defines the actual onboarding affordances.

### Architecture Completeness Checklist

**✓ Requirements Analysis** — project context analyzed, scale and complexity assessed, technical constraints identified, cross-cutting concerns mapped.

**✓ Architectural Decisions** — 25 decisions across 5 groups, plus Round-2 lock-ins folded into Decisions 2.1, 4.2, 4.5, 4.6, and the UX-design-workflow amendments folded into Decisions 1.2, 1.3, 2.1, 4.2, 4.5, 4.6 + new Decision Group 5 (Decisions 5.1–5.7 — AI-Assisted Correction as a product category). Technology stack fully specified. Integration patterns defined.

**✓ Implementation Patterns** — naming conventions, structure patterns, communication patterns, process patterns documented. Helper-discipline table covers 10 single-implementation primitives + lint enforcement.

**✓ Project Structure** — complete directory structure, component boundaries, integration points, FR-cluster + cross-cutting-concern mapping. Five small specifications (`URLRouter`, `MeetingIDResolver` protocol, VM-factory, `StageRunner.synthesizeFailure` signature, malformed-URL toast) land in the stories that need them rather than carried in the architecture document.

**✓ Validation** — coherence, coverage, readiness all green. Multi-agent roundtable findings disposed.

### Architecture Readiness Assessment

**Overall Status:** READY FOR IMPLEMENTATION (Story 1 + Story 2 unblocked today; subsequent stories unblocked in sequence).

**Confidence Level:** High. The Round-2 scope-call by John (PM) reframed the validation against the actual J1 success criterion — "Andrew defaults to auricle by month 2" — rather than a generic "production-ready" rubric. Three architectural commitments earn their MVP weight (silent-spinner fix, NFR-P1 honesty, TOML config); five small specs defer to the stories that touch them; three findings document accepted scope (cache durability, orphan subprocess, closed-loop telemetry foreclosure). The architecture has not bloated to fix every theoretical concern — it has fixed the J1-blockers and named the rest honestly.

**Key Strengths (validated by roundtable):**
- Mechanical SOLID enforcement via SwiftPM target boundaries
- Strong IPC contract decoupling (SQLite + cache-dir + URL scheme + `__internal-stage` subcommand)
- Helper-discipline pattern (10 primitives + lint-rule enforcement)
- Dual-strategy summarization with build-time canonicalization invariant (Decision 3.4)
- CLI as first-class product surface with hidden worker subcommand for binding-contract isolation
- Stale-active-state detection (new) closes the silent-spinner UX gap with a single periodic-sweep mechanism

**Accepted Limitations (named honestly, not hidden):**
- N=1 dogfood absorbs cache-dir eviction and orphan-subprocess edge cases until they prove disruptive
- v1.1 closed-loop trust calibration instruments forward from build-time, not retroactively
- First-meeting onboarding deferred to UX-design phase

**Areas for Future Enhancement:**
- Streaming pipeline (deliberate one-way door per step-02)
- Cross-meeting voice-print embeddings (v2+, FR26)
- Local-LLM summarization (v1.1+, Decision 3.9 protocol-shaped accommodation)
- Closed-loop trust calibration via vault-edit detection (v1.1+)

### Implementation Handoff

**Pre-Story-1 actions:** none. The architecture document is the handoff artifact. Decisions 2.1, 4.2, 4.5, 4.6 carry the Round-2 lock-ins in place; downstream stories read those decisions as authoritative.

**Story 1 — Project Initialization:**

```bash
mkdir auricle && cd auricle
swift package init --type library --name AuricleKit
# Edit Package.swift to declare the modular target list from step-06.
# SPM dependencies: WhisperKit, GRDB.swift, swift-argument-parser, TOMLKit (config), Sparkle (v1.1, deferred).
# Initialize App/Auricle.xcodeproj with two targets (AuricleApp + auricle-cli) depending on the SwiftPM library.
# Configure: Hardened Runtime ON, Sandbox OFF, Info.plist (NS*UsageDescription strings, CFBundleURLTypes for auricle://),
#            entitlements (com.apple.security.device.audio-input, notifications), code-signing identity per Distribution Model.
# Run scripts/setup-trust.sh on the dev Mac.
# CI: .github/workflows/ci.yml runs swift build, swift test, xcodebuild build, swiftformat --lint, swiftlint.
# Verify: empty swift test passes; xcodebuild build passes for both schemes.
```

**Story sequence (locked):**

1. **Story 1**: Project initialization (above).
2. **Story 2**: `Core` primitives — `AtomicWriter`, `Log` facade, `MeetingID`, `MeetingIDResolver` (+ protocol split when test stubs need it), `URLRouter` + `auricle://` grammar, `CacheArtifactWriter`, `CanonicalTranscript`.
3. **Story 3**: `State/StateStore` + GRDB migration #1 (with the dual NFR-P1 telemetry columns from Decision 4.5 lock-in **and the AI-reviewer telemetry columns from Decision Group 5**) + `Orchestrator/StageRunner` (with `synthesizeFailure(...)` API per Decision 4.2 lock-in).
4. **Story 4**: `Persist` + `FrontmatterRenderer` + `VaultWriter` + golden-fixture snapshot tests.
5. **Story 5**: `Summarize` + `SummarizerInterface` + `ClaudeSummarizer` (both validators) + canonicalization invariant tests + Decision 3.6 smoke-test execution. Also: `AIReviewerInterface` (protocol family per Decision 5.1) — declared, no concrete impl yet.
6. **Story 6**: `Transcribe` + `Diarize` + `WhisperKit*` + `ReviewDiarization` stage + `ClaudeAIReviewers/ClaudeDiarizationReviewer` (Decisions 5.2, 5.3) + `Orchestrator/SubprocessSupervisor` (integrates `synthesizeFailure(...)` and stale-detection sweep per Decision 4.2 + 4.6 lock-ins, including the 90s wall-clock budget for `reviewing_diarization`). Cache-immutability contract test (Decision 5.3) lands here.
7. **Story 7**: `auricle-cli` skeleton (binding-contract verbs + hidden `__internal-stage` worker subcommand, including the `review-diarization` worker per Decision 5.3).
8. **Story 8+**: `Capture` + `Permissions` + `App/Auricle` GUI shell (single-window architecture per UX Step 9 Principle 8; with amber-chip stale-state UX + VM-factory pattern + malformed-URL toast + first-meeting onboarding handed off to UX-design phase) + `MainWindow/AttributionSheet` (replaces former AttributionWindow per Decision 4.6 + UX Step 9) including AI-hint UI (`AIHintChip`, `TrustCalibrationFooter`) flagged-off in MVP per Path C + `Notifications` + `Verify` + `Calendar` + `VaultGlossary`.

This sequence preserves the brainstorm's risk-front-loaded ordering: the pipeline-plumbing libraries (Stories 2–6) and the CLI executable (Story 7) can be built and dogfooded against pre-existing audio recordings before Story 8's SwiftUI app shell or any ScreenCaptureKit code exists. The AI-reviewer slots (Decision Group 5) are wired in Story 6 alongside the WhisperKit subprocess so the full `transcribing → reviewing_diarization → awaiting_attribution` chain is testable end-to-end before UI work begins.
