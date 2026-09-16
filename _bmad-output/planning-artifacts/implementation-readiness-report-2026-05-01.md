---
date: 2026-05-01
project: auricle
stepsCompleted:
  - step-01-document-discovery
  - step-02-prd-analysis
  - step-03-epic-coverage-validation
  - step-04-ux-alignment
  - step-05-epic-quality-review
  - step-06-final-assessment
status: complete
overallReadiness: READY
documentsIncluded:
  prd: _bmad-output/planning-artifacts/prd.md
  architecture: _bmad-output/planning-artifacts/architecture.md
  epics: _bmad-output/planning-artifacts/epics.md
  ux: _bmad-output/planning-artifacts/ux-design-specification.md
---

# Implementation Readiness Assessment Report

**Date:** 2026-05-01
**Project:** auricle

## Document Inventory

**PRD**
- `_bmad-output/planning-artifacts/prd.md` (744 lines, whole document)

**Architecture**
- `_bmad-output/planning-artifacts/architecture.md` (2,968 lines, whole document)

**Epics & Stories**
- `_bmad-output/planning-artifacts/epics.md` (4,059 lines, whole document — includes 10 epics, 90 stories per recent commit history)

**UX Design**
- `_bmad-output/planning-artifacts/ux-design-specification.md` (1,874 lines, whole document)

**Notes:**
- No sharded versions found alongside whole documents — no duplicate-format conflicts.
- A prior readiness report exists at `implementation-readiness-report-2026-04-26.md` (5 days old, pre-dates the 2026-05-01 epic+story breakdown commit `a3dfa38`). Treated as historical, not an input.
- Adjunct context: `_bmad-output/brainstorming/brainstorming-session-2026-04-23-1644.md` exists but is not part of the readiness inputs.

## PRD Analysis

### Functional Requirements

**Capture (FR1–FR10)**
- FR1 [MVP]: The user can start audio capture for a meeting via a prominent control in the auricle main window.
- FR2 [MVP]: The user can stop audio capture via the same control, ending the recording and triggering the post-capture pipeline.
- FR3 [MVP]: The user can see a visible recording-state indicator while capture is active (in the main window title bar, at minimum).
- FR4 [MVP]: auricle can capture system audio (loopback from any application) without requiring integration with the meeting platform.
- FR5 [MVP]: auricle can simultaneously capture the user's microphone and mix it with system audio.
- FR6 [MVP]: auricle can request and handle macOS Screen Recording and Microphone permissions, with clear in-app explanation if permission is denied.
- FR7 [MVP]: The user can manually discard a captured-but-unprocessed meeting from the main window.
- FR8 [v1.1]: The user can start and stop capture from a menubar item without opening the main window.
- FR9 [v1.1]: VAD pre-flight halting gate (configurable, default <2 min speech), surfacing meeting as `silent`.
- FR10 [v1.1]: The user can override a VAD halt and force-process a meeting (UI affordance + `--force` CLI flag).

**Pipeline Orchestration & State (FR11–FR16)**
- FR11 [MVP]: auricle can execute the meeting pipeline in distinct, crash-isolated stages: capture → transcribe → diarize → attribute → summarize → persist → notify.
- FR12 [MVP]: Each pipeline stage can be invoked independently as `auricle <stage> <id>` CLI subcommand, producing identical artifacts to in-app execution.
- FR13 [MVP]: Per-meeting state in main window (`Recording`, `Processing`, `Awaiting Attribution`, `Awaiting Verification`, `Verified`).
- FR14 [MVP]: The user can re-run a failed stage idempotently without corrupting earlier-stage artifacts.
- FR15 [v1.1]: `auricle pending` lists in-flight, silent, awaiting-attribution, awaiting-verification, and stale-pending meetings.
- FR16 [v1.1]: Dock badge count of stale-pending items.

**Transcription & Diarization (FR17–FR20)**
- FR17 [MVP]: Transcribe captured audio on-device using WhisperKit + Whisper-large-v3-turbo.
- FR18 [MVP]: Speaker diarization via WhisperKit's built-in diarization, producing speaker-segmented output (`Speaker_1`, `Speaker_2`, …).
- FR19 [MVP]: Transcribe English-language audio (other languages explicitly out of scope).
- FR20 [MVP]: Transcription completes locally without any network round-trip.

**Attribution (FR21–FR27, FR77)**
- FR21 [MVP]: Native Attribution sheet attached to main window (modal, not a separate window — single-workflow-window principle); pipeline blocks on input before summarization.
- FR22 [MVP]: The user can play 5–10s representative audio snippet for each detected speaker.
- FR23 [MVP]: Autocomplete prioritizes (1) calendar attendees, (2) vault wikilink targets, (3) previously-labeled speakers, with frequency/recency tie-breakers.
- FR24 [MVP]: "This is me" affordance for self-attribution without typing.
- FR25 [MVP]: "Publish anyway" action; resulting note uses `Speaker_N` placeholder labels and is tagged `#auricle/needs-attribution`.
- FR26 [MVP]: The user can manually fix attribution in Obsidian after the fact (auricle never re-edits the note).
- FR27 [v1.1]: CLI fallback — `auricle attribute <id> --emit-snippets` and `--speakers "1=Ben,2=Sara,..."`.
- FR77 [MVP]: When ≥2 meetings simultaneously in `Awaiting Attribution`, sheets are serialized FIFO; main window shows banner counter; completing/dismissing/saving-for-later opens next queued sheet.

**Summarization (FR28–FR34)**
- FR28 [MVP]: Summarize attributed transcript into structured output: one-paragraph summary, action items array, decisions array.
- FR29 [MVP]: Each action item / decision grounded via Anthropic Citations API character-range offsets (default Claude path) OR verbatim quote string (local-LLM / substring fallback). Vault note renders cited transcript text as `> source quote` regardless of mechanism.
- FR30 [MVP]: Validate every grounding pointer against source transcript; both validation paths produce identical normalized output `{transcriptStart, transcriptEnd}`. Items failing validation dropped before write.
- FR31 [MVP]: Anthropic Claude API as default summarization engine.
- FR32 [MVP]: Single primary Claude call per meeting (chain-of-summarize deferred to v2+). On Citations API errors / malformed responses / empty citation arrays, orchestrator may auto-dispatch a single fallback substring call; total per-meeting cost remains bounded by NFR-C1.
- FR33 [v1.1+]: Local LLM path (Ollama or MLX) selectable via configuration.
- FR34 [v1.1]: Long-context drift detection on transcripts ≥60 min (token count + summary content density) and flag suspiciously thin summaries.

**AI-Assisted Correction (FR73–FR76)**
- FR73 [MVP]: `AIReviewerStrategy` family with `ClaudeDiarizationReviewer` (Haiku-default), declared `TranscriptionReviewerStrategy` (no impl), and `JargonCorrectionStrategy` wrapping FR55–FR57 glossary path. Pipeline includes `reviewing_diarization` stage between diarization and attribution; `attribution.json` exposes `segment_overrides` and `segment_splits`.
- FR74 [MVP]: `diarization_review.enabled` config flag (default `false`). When `true`: ClaudeDiarizationReviewer runs on every meeting, writes `diarization_suggestions.json`. When `false`: empty stub artifact in <100ms, no Claude call. Per-config (FR58); flipping requires no rebuild.
- FR75 [MVP]: Inline review in Attribution sheet via per-paragraph `🤖` chips with reasoning + Apply/Reject; applied suggestions write `segment_overrides`/`segment_splits`; reversible via SwiftUI `UndoManager` for sheet duration; "Revert this split" available across sheet reopens; trust-calibration footer shows recent accept rate.
- FR76 [v1.1]: `TranscriptionReviewerStrategy` declared in MVP without impl; v1.1 adds `ClaudeTranscriptionReviewer` (Haiku-default) for word/phrase-level corrections (homophones, proper nouns, glossary-grounded terms) behind `transcription_review.enabled` flag (default `false`). Same dogfood-then-enable activation gate.

**Persistence & Vault Integrity (FR35–FR41)**
- FR35 [MVP]: Write each meeting as exactly one new markdown file at configurable path (default `~/checkouts/SecondBrain/Meetings/`).
- FR36 [MVP]: Never open existing vault file for write; persistence is `temp file → fsync → atomic rename`.
- FR37 [MVP]: Stable note structure: frontmatter, summary paragraph, action items (each with quote), decisions (each with quote), collapsed transcript.
- FR38 [MVP]: Render speakers in summary text as Obsidian `[[wikilinks]]`, resolvable to existing or to-be-created people-notes.
- FR39 [MVP]: Frontmatter populated with: time, duration, attendees (wikilinks), source audio path, calendar event ID (when available), tags array, schema version, retention policy, per-stage timing telemetry.
- FR40 [MVP]: Stable filename convention based on date and meeting title; collisions avoided.
- FR41 [MVP]: `auricle:` block in frontmatter for pipeline metadata; tag namespace pollution limited to intentional `auricle/*` tags.

**Notification & Verification (FR42–FR44)**
- FR42 [MVP]: Fire macOS user notification when summary written; meeting title visible in notification.
- FR43 [MVP]: Click notification to open note in Obsidian via URL scheme.
- FR44 [MVP]: Notification click is verification trigger that arms audio retention timer (click is meaningful, not passive).

**Audio Retention & Lifecycle (FR45–FR50)**
- FR45 [MVP]: Hold captured audio indefinitely until verification click.
- FR46 [MVP]: Configurable grace timer (default 7d) begins after verification click; audio deleted at end of grace.
- FR47 [MVP]: Re-prompt at 7d post-verification (escalate at 14d) to confirm or extend retention.
- FR48 [MVP]: Per-meeting audio retention status visible in main window.
- FR49 [v1.1]: Override audio retention (indefinite or custom) via UI and `auricle keep <meeting-id>` CLI.
- FR50 [v1.1]: Per-meeting retention windows that override the default.

**Calendar Enrichment (FR51–FR54)**
- FR51 [MVP]: Authenticate with Google Calendar via OAuth 2.0; tokens in macOS Keychain.
- FR52 [MVP]: Fetch calendar event matching meeting time window; inject title, attendees, event metadata into frontmatter.
- FR53 [MVP]: Upcoming calendar meetings displayed in sidebar/surface for upcoming captures.
- FR54 [MVP]: Degrade gracefully when calendar unreachable: publish with generic title and `#auricle/needs-calendar-enrichment` tag.

**Vault-Glossary Correction (FR55–FR57)**
- FR55 [MVP]: Extract glossary from vault by enumerating wikilink targets across vault files.
- FR56 [MVP]: Scope glossary to terms relevant to current meeting's attendees and topics, when context is sufficient.
- FR57 [MVP]: Inject (scoped) glossary as context into summarization prompt for term-correction.

**Configuration & Permissions (FR58–FR60)**
- FR58 [MVP]: Configurable: vault path, vault subdirectory, default retention grace, summarization engine (Claude/local), Anthropic key, Google OAuth, log verbosity.
- FR59 [MVP]: Persist config in `~/Library/Application Support/com.auricle.app/` as TOML/JSON; secrets in Keychain.
- FR60 [MVP]: Detect missing required permissions (Screen Recording, Microphone, Notifications) on launch with clear remediation.

**Operations & Failure Recovery (FR61–FR66)**
- FR61 [MVP]: Structured logs to unified logging system, subsystem `com.auricle.app`, per-stage categories.
- FR62 [MVP]: Survive crash of any individual stage subprocess without losing earlier-stage artifacts; pipeline picks up from last successful stage.
- FR63 [MVP]: Continue running after main window closed (in-flight captures/pipelines complete without intervention).
- FR64 [MVP]: Standard Cmd-Q gracefully stops active capture and persists in-flight state.
- FR65 [v1.1]: Self-update via Sparkle (EdDSA-signed appcast), with confirmation; signed `.app` accepted by Gatekeeper via existing `spctl` trust policy.
- FR66 [MVP]: Local SQLite telemetry at `~/Library/Application Support/com.auricle.app/`: time-to-notification, quote-validation drops, attribution path, summarization cost, retention status. Not transmitted off-device.

**Future / Vision v2+ (FR67–FR72)** — *not in scope for MVP/v1.1, listed for capability-contract completeness*
- FR67 [v2+]: Auto-detect meeting in progress via running meeting-app processes.
- FR68 [v2+]: Persist speaker voice-print embeddings (pyannote 3.1 sidecar) for cross-meeting matching.
- FR69 [v2+]: Meeting-type-specific summarization templates (1:1, standup, external pitch, interview, brainstorm).
- FR70 [v2+]: "Series-overview" auto-aggregated note for recurring meetings.
- FR71 [v2+]: Chain-of-summarize fallback for transcripts ≥90 min.
- FR72 [v2+]: Apple SpeechAnalyzer as fallback ASR on macOS 26+.

**Total FRs:** 77 (66 MVP + 11 v1.1 + 6 v2+; FR73–FR75 are MVP, FR76 is v1.1, FR77 is MVP)

### Non-Functional Requirements

**Performance (NFR-P1–P13, all MVP)**
- NFR-P1: E2E pipeline P50 ≤2 min, P95 ≤5 min for 30-min single-track meeting on M5 Max.
- NFR-P2: E2E pipeline P95 ≤10 min for 60-min meeting (same hardware).
- NFR-P3: Transcription ≤30s for 30-min audio (WhisperKit + Whisper-large-v3-turbo on ANE).
- NFR-P4: Diarization ≤30s for 30-min audio.
- NFR-P5: Summarization (Claude) P50 ≤60s, P95 ≤180s for 30-min transcript ≤4k tokens.
- NFR-P6: Attribution UI interactive within ≤2s of diarization completing.
- NFR-P7: Snippet playback start within ≤200ms of click.
- NFR-P8: Vault write ≤500ms for note up to 50 KB.
- NFR-P9: Idle memory ≤200 MB.
- NFR-P10: Peak memory during transcription on 60-min audio ≤4 GB.
- NFR-P11: Idle CPU ≤1% on Apple Silicon.
- NFR-P12: Cold start ≤1.5s on M-series with warm filesystem cache.
- NFR-P13: Capture adds no perceivable system audio latency.

**Reliability & Data Integrity (NFR-R1–R10, all MVP)**
- NFR-R1: Atomic vault writes (temp → fsync → rename); zero partial-write events tolerated.
- NFR-R2: Never open existing vault file for write.
- NFR-R3: Audio held until verification click; zero unverified-audio-deletion events; default to retain on retention errors.
- NFR-R4: Crash isolation: stage crash doesn't corrupt earlier-stage artifacts.
- NFR-R5: Stages idempotent (modulo LLM nondeterminism).
- NFR-R6: SQLite-persisted in-flight pipeline state; clean recovery on next launch.
- NFR-R7: Quote-grounding hard gate; 100% pass-rate; failing items dropped silently (logged).
- NFR-R8: Notification permission revocation non-fatal — pipeline completes, meeting moves to "awaiting verification" state.
- NFR-R9: Anthropic API unreachability handled by exp backoff (default 5 min cap); persistent failure → `summarization_failed` (not lost).
- NFR-R10: SQLite checkpointed on every transition; recovery via on-disk artifact replay.

**Security (NFR-S1–S9)**
- NFR-S1 [MVP]: Secrets in macOS Keychain only (`kSecClassGenericPassword`).
- NFR-S2 [MVP]: Self-managed code-signing cert (personal CA + per-tool leaf); per-Mac trust via `spctl`. Hardened runtime on. No notarization. Bundle identifier and signing identity stable across rebuilds/updates.
- NFR-S3 [MVP]: Cached audio files 0600 perms.
- NFR-S4 [MVP]: Vault notes inherit standard perms; auricle does not chmod.
- NFR-S5 [MVP]: Anthropic API over TLS 1.2+ with cert validation; no insecure-fallback.
- NFR-S6 [MVP]: Google OAuth device-code with PKCE; refresh token scoped to read-only Calendar.
- NFR-S7 [MVP]: No secret-leaking logs; redaction enforced at structured-logging layer.
- NFR-S8 [MVP]: No transmission outside Anthropic+Google Calendar; no telemetry endpoint in MVP.
- NFR-S9 [v1.1]: Sparkle EdDSA verification; invalid-signature updates rejected.

**Privacy (NFR-Pr1–Pr7, all MVP)**
- NFR-Pr1: No off-machine transmission except configured Claude/Calendar paths.
- NFR-Pr2: No anonymous telemetry/analytics; SQLite telemetry local-only.
- NFR-Pr3: Captured audio + intermediates scoped to user-owned dirs.
- NFR-Pr4: Claude payload contains transcript text + glossary terms only; audio never transmitted; first-name-only labels; calendar emails stripped.
- NFR-Pr5: Anthropic data-usage policy applies; documented in README + Settings UI.
- NFR-Pr6: Conservative retention defaults (held until verified, then 7d grace).
- NFR-Pr7: No participant indication of capture (design feature); user owns consent obligations.

**Integration & Compatibility (NFR-I1–I8)**
- NFR-I1 [MVP]: Requires macOS 14 (Sonoma)+; macOS 15+ active dev target.
- NFR-I2 [MVP]: Apple Silicon (arm64) only.
- NFR-I3 [MVP]: Compatible with Obsidian 1.x via `obsidian://open` scheme; no plugin required.
- NFR-I4 [MVP]: Frontmatter schema versioned (`auricle.schema_version`); breaking changes are major-version bumps with documented migration.
- NFR-I5 [MVP]: Google Calendar API v3 read-only; degrades gracefully on failure (`needs-calendar-enrichment` tag).
- NFR-I6 [MVP]: Anthropic Messages API; default `claude-opus-4-7` with extended thinking at moderate effort budget. Model and effort budget configurable via FR58 without code changes; release-note bump only.
- NFR-I7 [MVP]: CLI subcommand argument signatures stable; rename/remove is a breaking change requiring major version bump.
- NFR-I8 [v1.1+]: Local LLM path supports Ollama (HTTP) and/or MLX (in-process); switching is config-only.

**Accessibility (NFR-A1–A6, all MVP)**
- NFR-A1: VoiceOver navigation; descriptive labels for all interactive controls.
- NFR-A2: Attribution UI keyboard-navigable; Tab order matches reading; snippets keyboard-playable (e.g., Spacebar).
- NFR-A3: Color never sole conveyor of meaning (recording-state uses color + shape/animation; calendar-attendee priority indicated by visible label).
- NFR-A4: Text respects system text-size setting.
- NFR-A5: Respects Reduce Motion (animations simplified/disabled).
- NFR-A6: Dark Mode and Light Mode without user configuration.

**Maintainability & Operability (NFR-M1–M8, all MVP)**
- NFR-M1: Swift / SwiftUI / AppKit only — no Python sidecars, no Node, no Electron, no JS runtimes (pyannote sidecar in v2+ is deliberate exception).
- NFR-M2: Pipeline stages isolated as separate `auricle <stage>` subprocess invocations.
- NFR-M3: Structured logs under subsystem `com.auricle.app` with per-stage categories.
- NFR-M4: Unit tests for: schema validation, frontmatter rendering, quote-grounding grep validation, vault-glossary extraction, filename collision avoidance, retention timer arithmetic.
- NFR-M5: At least one E2E smoke test (reference WAV + stub summarization + temp-dir vault-write); CI-runnable.
- NFR-M6: Config changes take effect on next pipeline invocation, no app restart.
- NFR-M7: Reproducible release builds (same SHA + toolchain → identical signed `.app`); release script checked in.
- NFR-M8: Non-trivial design decisions anchored to PRD/brainstorm sections via brief code comments where the *why* is non-obvious.

**Cost (NFR-C1–C4)**
- NFR-C1 [MVP]: Per-meeting variable cost ceilings: ≤$0.50 default (jargon inline in Opus summarize, no diarization review); ≤$0.60 with `diarization_review.enabled = true` (Haiku review call); targeted ≤$0.70 in v1.x with `transcription_review.enabled = true`; $0 on local-LLM path. Assumes 30-min meeting, prompt caching enabled. Cost-control knobs: leave diarization-review off, reduce extended-thinking budget (~$0.15 baseline at ~zero), switch to Sonnet/Haiku, or v1.1+ switch to local LLM.
- NFR-C2 [v1.1]: Per-meeting variable cost reduces to ≤$0.05 via prompt optimization (caching, tighter glossary).
- NFR-C3 [v1.1+]: Per-meeting cost = $0 on local-LLM path.
- NFR-C4 [MVP]: Total fixed cost $0; self-managed code-signing CA + `spctl` trust; no Apple Developer Program subscription required (documented as optional alternative for cross-recipient distribution).

**Total NFRs:** 65 across 8 categories (P:13, R:10, S:9, Pr:7, I:8, A:6, M:8, C:4). MVP-tagged NFRs: 60. v1.1/v1.1+ NFRs: 5 (NFR-S9, NFR-I8, NFR-C2, NFR-C3, plus implicit v1.1 portions of NFR-C1).

### Additional Requirements

**Design Principles (DP1–DP5) — bind across all FRs/NFRs**
- DP1: Stages are decoupled CLI subcommands; the Mac app is UI + dispatcher, not a monolith.
- DP2: Frontmatter contract is canonical; no confidence flags exposed in vault; tag namespace limited to intentional flags (`needs-attribution`, `needs-calendar-enrichment`); breaking changes are major-version events.
- DP3: Audio is the only recovery layer; retained until verification; conservative timer; never delete unverified.
- DP4: Vault is a downstream consumer with a contract; auricle does not perform analytics, does not synthesize across meetings, does not edit existing vault files.
- DP5 (implicit): Engagement happens upfront — attribution is blocking, not optional; user judgment moments asked when context is fresh.

**Single-workflow-window principle (referenced by FR21, FR77 and saved to memory):** No multi-window for workflow tasks — Attribution is a sheet attached to the main window, not a separate window.

**Open Resolutions (verify before implementing):**
1. Parakeet-TDT MLX maturity (alternate ASR; spike before transcription-stage lock).
2. WhisperKit diarization quality + embeddings exposure (empirical test on 5+ real meetings during early MVP build).
3. Apple SpeechAnalyzer (deferred until macOS 26).
4. Hidden journeys J0/J6/J8 to formalize (PRD revision pre-MVP build): J0 first-launch permission gauntlet; J6 Anthropic credits exhausted mid-summarize; J8 macOS sleep-wake mid-capture.
5. Citations vs substring grounding — RESOLVED architecturally to dual-strategy `GroundingValidator` (Citations primary on `claude-opus-4-7`, substring fallback). Smoke-test deferred to summarize-stage build story.
6. Summarize-stage smoke-test protocol (Story N hour 1; runs before dogfood) — defined in PRD; gates the default-validator choice.
7. Diarization-review smoke-test protocol (Phase 2 activation gate; runs after ~30-day MVP dogfood). Activation criteria: applied/suggestions ≥40% over 4 weeks AND false-positive rate <20%. Same template applies to FR76 transcription review.
8. Trust calibration (J1.5) — `grounding_method` telemetry per meeting load-bearing; per-meeting grounding details inspectable via `auricle status <id>` and `auricle logs <id>` (v1.1).
9. Empirical decisions deferred: summarization engine Claude-vs-local benchmark (10–20 meetings during MVP build); vault note shape detail (community research before persistence stage); long-context drift threshold (3–5 meetings of 60+ min during dogfood).

### PRD Completeness Assessment

- **Coverage:** Comprehensive — all major surfaces enumerated (Capture, Pipeline, Transcription, Diarization, Attribution, Summarization, AI-Correction, Persistence, Notification, Retention, Calendar, Glossary, Config, Operations).
- **Tier discipline:** Every FR carries an explicit `[MVP] / [v1.1] / [v2+]` tag. NFRs similarly tiered.
- **Vision FRs included for contract completeness (FR67–FR72):** scoped out of MVP and v1.1; should NOT have epic coverage in current planning.
- **Cross-references:** PRD makes deliberate use of cross-references (FR29↔NFR-R7, FR58↔NFR-I6, FR65↔NFR-S2/NFR-C4, AI-correction siblings ↔ FR55–FR57).
- **Open Resolutions:** Well-defined — none are blockers; each has a path forward and a measurement gate.
- **Risks of gaps in epic/story coverage:**
  - FR77 (queued attribution sheets) is a late MVP addition; verify epics cover this.
  - FR73–FR76 (AI-correction family) is a recent addition; verify Phase 1 architectural slots are covered in MVP epics.
  - Hidden journeys (J0, J6, J8) — need to confirm whether the Open Resolutions item to "formalize as journeys before MVP build" was completed; check journey-derived requirements in epics.
  - Cost ceiling tier knobs (NFR-C1) — ensure config surface (FR58) covers all cost-control levers.
  - Trust calibration (J1.5) — `grounding_method` telemetry + `auricle status <id>` / `auricle logs <id>` (v1.1) inspection surface needs explicit story coverage.

## Epic Coverage Validation

### Epic FR Coverage Extracted

The epics document contains an explicit `FR Coverage Map` (epics.md:429–503) and a `NFR × Epic Audit` matrix (epics.md:504–582). Every FR1–FR77 is enumerated; epics list and per-epic blocks (Epics 1–10 + "Out of Scope" v2+) align with the map.

**MVP FRs claimed (56):** FR1–7, 11–14, 17–26, 28–32, 35–48, 51–64, 66, 73–75, 77
**v1.1 FRs claimed (11):** FR8, 9, 10, 15, 16, 27, 33, 34, 49, 50, 65, 76 (concrete impl)
**v2+ FRs explicitly not claimed (6):** FR67–FR72 (correctly listed under "Out of Scope" — epics.md:790–799)

### FR Coverage Matrix

| FR | Tier | PRD requirement (summary) | Epic Coverage | Status |
|---|---|---|---|---|
| FR1 | MVP | Start capture control | Epic 5 | ✓ Covered |
| FR2 | MVP | Stop capture control | Epic 5 | ✓ Covered |
| FR3 | MVP | Recording-state indicator | Epic 5 | ✓ Covered |
| FR4 | MVP | ScreenCaptureKit system audio loopback | Epic 5 | ✓ Covered |
| FR5 | MVP | Mic capture mixed with system audio | Epic 5 | ✓ Covered |
| FR6 | MVP | Permission request/handling | Epic 5 | ✓ Covered |
| FR7 | MVP | Manual discard from main window | Epic 6 | ✓ Covered |
| FR8 | v1.1 | Menubar item start/stop | Epic 10 | ✓ Covered |
| FR9 | v1.1 | VAD pre-flight halt | Epic 10 | ✓ Covered |
| FR10 | v1.1 | VAD halt override / `--force` | Epic 10 | ✓ Covered |
| FR11 | MVP | Crash-isolated pipeline stages | Epic 1 | ✓ Covered |
| FR12 | MVP | CLI subcommand binding parity | Epic 1 (scaffold) + Epic 9 (full surface) | ✓ Covered |
| FR13 | MVP | Per-meeting state in main window | Epic 6 | ✓ Covered |
| FR14 | MVP | Idempotent stage re-run | Epic 1 | ✓ Covered |
| FR15 | v1.1 | `auricle pending` listing | Epic 10 | ✓ Covered |
| FR16 | v1.1 | Dock badge stale-pending | Epic 10 | ✓ Covered |
| FR17 | MVP | WhisperKit transcription | Epic 4 | ✓ Covered |
| FR18 | MVP | WhisperKit diarization | Epic 4 | ✓ Covered |
| FR19 | MVP | English-only transcribe | Epic 4 | ✓ Covered |
| FR20 | MVP | Local transcribe — no network | Epic 4 | ✓ Covered |
| FR21 | MVP | Attribution sheet (sheet, not window) | Epic 7 | ✓ Covered |
| FR22 | MVP | Per-speaker snippet playback | Epic 7 | ✓ Covered |
| FR23 | MVP | Speaker autocomplete priority | Epic 4 (CLI batch / data side) + Epic 7 (GUI) | ✓ Covered |
| FR24 | MVP | "This is me" affordance | Epic 7 | ✓ Covered |
| FR25 | MVP | "Publish anyway" w/ `Speaker_N` placeholders | Epic 4 (CLI) + Epic 7 (GUI) | ✓ Covered |
| FR26 | MVP | Manual fix in Obsidian (never re-edits) | Epic 2 | ✓ Covered |
| FR27 | v1.1 | CLI attribution fallback `--emit-snippets`/`--speakers` | Epic 10 | ✓ Covered |
| FR28 | MVP | Structured summary output | Epic 3 | ✓ Covered |
| FR29 | MVP | Quote-grounded via Citations or substring | Epic 3 | ✓ Covered |
| FR30 | MVP | Validation hard gate; drop on failure | Epic 3 | ✓ Covered |
| FR31 | MVP | Default Anthropic Claude API summarizer | Epic 3 | ✓ Covered |
| FR32 | MVP | Single primary call w/ optional fallback | Epic 3 | ✓ Covered |
| FR33 | v1.1+ | Local LLM path (Ollama/MLX) | Epic 10 | ✓ Covered |
| FR34 | v1.1 | Long-context drift detection | Epic 10 | ✓ Covered |
| FR35 | MVP | One markdown file per meeting at vault path | Epic 2 | ✓ Covered |
| FR36 | MVP | Atomic write — never opens existing vault file | Epic 2 | ✓ Covered |
| FR37 | MVP | Stable note structure | Epic 2 | ✓ Covered |
| FR38 | MVP | Speakers as `[[wikilinks]]` | Epic 2 | ✓ Covered |
| FR39 | MVP | Frontmatter schema population | Epic 2 | ✓ Covered |
| FR40 | MVP | Filename convention | Epic 2 | ✓ Covered |
| FR41 | MVP | `auricle:` block; tag namespace discipline | Epic 2 | ✓ Covered |
| FR42 | MVP | macOS notification on summary ready | Epic 8 (full path) + Epic 4 (minimal stub) | ✓ Covered |
| FR43 | MVP | Click → open in Obsidian via URL scheme | Epic 8 (full path) + Epic 4 (minimal stub) | ✓ Covered |
| FR44 | MVP | Notification click as verification trigger | Epic 8 | ✓ Covered |
| FR45 | MVP | Hold audio indefinitely until verification | Epic 8 | ✓ Covered |
| FR46 | MVP | 7-day grace timer post-click | Epic 8 | ✓ Covered |
| FR47 | MVP | 7d/14d retention reminders | Epic 8 | ✓ Covered |
| FR48 | MVP | Per-meeting retention status in main window | Epic 6 | ✓ Covered |
| FR49 | v1.1 | Per-meeting retention override | Epic 10 | ✓ Covered |
| FR50 | v1.1 | Per-meeting custom retention windows | Epic 10 | ✓ Covered |
| FR51 | MVP | Google Calendar OAuth + Keychain | Epic 3 | ✓ Covered |
| FR52 | MVP | Calendar event matching + frontmatter inject | Epic 3 | ✓ Covered |
| FR53 | MVP | Upcoming calendar meetings strip | Epic 6 | ✓ Covered |
| FR54 | MVP | Graceful calendar degradation | Epic 3 | ✓ Covered |
| FR55 | MVP | Vault-glossary extraction | Epic 3 | ✓ Covered |
| FR56 | MVP | Glossary scoping by attendees/topics | Epic 3 | ✓ Covered |
| FR57 | MVP | Glossary injection into summarization prompt | Epic 3 | ✓ Covered |
| FR58 | MVP | Configurable settings (incl. AI flags) | Epic 5 (initial scaffold) + Epic 9 (full SettingsView) | ✓ Covered |
| FR59 | MVP | TOML config persistence | Epic 1 | ✓ Covered |
| FR60 | MVP | Permission detection-on-launch + remediation | Epic 9 (primary) + Epic 5 (mid-capture revocation) | ✓ Covered |
| FR61 | MVP | Structured os_log per stage | Epic 1 | ✓ Covered |
| FR62 | MVP | Crash recovery via state-machine reconciliation | Epic 1 | ✓ Covered |
| FR63 | MVP | App stays alive on window close | Epic 6 | ✓ Covered |
| FR64 | MVP | Cmd-Q graceful exit | Epic 6 | ✓ Covered |
| FR65 | v1.1 | Sparkle EdDSA self-update | Epic 10 | ✓ Covered |
| FR66 | MVP | Local SQLite telemetry | Epic 1 | ✓ Covered |
| FR67 | v2+ | Auto-detect meeting in progress | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR68 | v2+ | Cross-meeting voice-print embeddings | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR69 | v2+ | Meeting-type templates | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR70 | v2+ | Series-overview auto-aggregation | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR71 | v2+ | Chain-of-summarize fallback | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR72 | v2+ | Apple SpeechAnalyzer fallback ASR | (Out of MVP/v1.1 scope) | ✓ Out-of-scope |
| FR73 | MVP | AIReviewerStrategy family + reviewing_diarization stage | Epic 4 | ✓ Covered |
| FR74 | MVP | `diarization_review.enabled` flag + reviewer | Epic 4 | ✓ Covered |
| FR75 | MVP | Sheet AI-hint UX | Epic 7 | ✓ Covered |
| FR76 | v1.1 | Concrete `ClaudeTranscriptionReviewer` | Epic 10 | ✓ Covered (note: Epic 4 ships protocol declaration only via AR-AI-1; Mary's review correctly preserves FR76 as v1.1-owned) |
| FR77 | MVP | Multi-meeting attribution sheet queue | Epic 7 | ✓ Covered |

### Missing Requirements

**Critical Missing FRs:** None. All 71 in-scope FRs (56 MVP + 11 v1.1, plus FR76 v1.1 and FR65 v1.1 — total 67 in-scope, plus 4 high-priority MVP additions FR73–75, FR77) have epic coverage.

**High-Priority Missing FRs:** None.

**v2+ FRs (FR67–FR72):** Correctly excluded from epic coverage — the epics document explicitly lists them under "Out of Scope" (epics.md:791–799). This is the intended posture per the PRD's tiered scope discipline.

### NFR × Epic Coverage Summary

The epics document includes a one-time NFR × Epic Audit (epics.md:504–582) addressing Mary's review concern that NFR coverage was previously implicit and asymmetric. Spot-check confirms:

- **Performance (P1–P13):** All 13 NFRs traced to epics; latency budgets explicitly tied to validation stories (e.g., NFR-P1/P2 → Epic 4 exit-criteria smoke test; NFR-P6 → Epic 7 snapshot test; NFR-P9 → 200MB budget verified by `mach_task_basic_info.resident_size` assertion).
- **Reliability (R1–R10):** All 10 NFRs covered. NFR-R1 split correctly: Core primitive in Epic 1, enforcement in Epic 2.
- **Security (S1–S9):** All 9 covered. NFR-S2 (code-signing) explicitly moved Epic 1 → Epic 9 per Winston's review.
- **Privacy (Pr1–Pr7):** All 7 covered.
- **Integration (I1–I8):** All 8 covered.
- **Accessibility (A1–A6):** All 6 covered, distributed across Epic 5 (first interactive surfaces) + Epic 6 + Epic 7 + Epic 9 — addresses Mary's "Accessibility was nowhere visible" concern.
- **Maintainability (M1–M8):** All 8 covered. NFR-M5 canonical satisfaction is Epic 4 exit-criteria smoke test (per epics.md:574).
- **Cost (C1–C4):** All 4 covered. NFR-C1 default tier validated in Epic 3, review tier in Epic 4 exit criteria, fixed-cost NFR-C4 in Epic 9.

### Coverage Statistics

- **Total PRD FRs:** 77 (FR1–FR77; numbering is non-contiguous around late-added FR73–77)
- **In-scope FRs (MVP + v1.1):** 71 (56 MVP + 15 v1.1; includes FR76 v1.1 concrete impl)
- **In-scope FRs covered in epics:** 71 (100%)
- **Out-of-scope FRs (v2+):** 6 (FR67–FR72) — correctly not covered
- **Coverage percentage (in-scope):** **100%**
- **Total PRD NFRs:** 65
- **NFRs covered in NFR × Epic Audit:** 65 (100%)

## UX Alignment Assessment

### UX Document Status

**Found.** Comprehensive 1,874-line UX Design Specification at `_bmad-output/planning-artifacts/ux-design-specification.md`, marked `status: complete` (frontmatter line 4), 14 workflow steps completed, dated 2026-04-30.

**Convention note:** The UX spec itself does not assign formal `UX-DR<N>` IDs — those identifiers are introduced in the epics document, where 68 distinct `UX-DR1` through `UX-DR68` are derived from UX content and traced to epics. Architecture commit `4a8e321` ("Apply UX-design-workflow amendments to architecture; add Decision Group 5") confirms the architecture was revised to incorporate UX outputs after the spec was completed.

### UX ↔ PRD Alignment

| UX surface | PRD requirement(s) | Aligned? |
|---|---|---|
| Single workflow window principle | DP-implicit + FR21 (sheet, not window) + FR77 (sheet queue) | ✓ Aligned (memorialized in user memory `feedback_single_window_ux.md`) |
| Five PRD journeys (J1–J5) | PRD §User Journeys | ✓ Mirrored in UX as J1, J2, J3, J5 + J4 CLI fallback |
| Three "hidden" journeys (J0, J6, J8) | PRD Open Resolution item | ✓ UX spec adds J0 (first-launch permission gauntlet), J6 (Anthropic credits exhausted), J8 (sleep-wake mid-capture) — closes the PRD's "hidden journeys to be formalized" open item |
| Trust calibration (J1.5) | PRD Open Resolution item | ✓ UX spec describes via `auricle status <id>` / `auricle logs <id>` inspection surface (not vault confidence flags) — preserves DP2 |
| AI-correction sheet UX | FR75, FR74 | ✓ Per-paragraph 🤖 chips, Apply/Reject, trust-calibration footer |
| Recording-state visibility | FR3, NFR-A3, NFR-A5 | ✓ `RecordingIndicator` color + motion + label; Reduce Motion fallback |
| Notification = verification | FR42–FR44 | ✓ Single-click delivers two effects |
| Calendar-attendee priority autocomplete | FR23 | ✓ Three-tier priority order with visual marker |
| "This is me" affordance | FR24 | ✓ Dedicated button; first-run heuristic pre-select |
| "Publish anyway" | FR25 | ✓ Tertiary text-link with single confirmation, no modal cascade |
| CLI parallel surface | FR12, NFR-I7 | ✓ Every state and action has both GUI affordance and CLI verb |
| Failure-visibility surfaces | NFR-R8, NFR-R9 | ✓ State chip + on-launch banner + inline retry + `auricle doctor` |

**No UX requirements detected that are NOT in the PRD.** UX spec consistently traces back to FRs/NFRs.

### UX ↔ Architecture Alignment

| UX requirement | Architecture support | Aligned? |
|---|---|---|
| Single window + sheet queue (FR77) | Decision 5 (UX workflow amendments); `attribution.json` schema additions; `AttributionViewModel` in `Core/` | ✓ Aligned |
| AI-correction inline review (FR75) | AR-AI-1 through AR-AI-9; cache-immutability invariant; pure-function renderer | ✓ Aligned |
| Trust calibration via CLI (J1.5) | AR-SUM-6 (`auricle status <id>` + `log show` discovery path); telemetry columns in `Core/PipelineState` from Story 1.4 | ✓ Aligned — Mary's J1.5 fix explicitly addressed |
| Stale-active-state synthesized failure (UX-DR54) | AR-FAIL-2 (per-stage stale-budget table; 90s for `reviewing_diarization`, 2× per-stage budget elsewhere); `StageRunner.synthesizeFailure()` API | ✓ Aligned |
| Failure surfaces with action-bearing copy (UX-DR52) | AR-FAIL-7 (10 failure-visibility surfaces); UX-DR52 copy patterns | ✓ Aligned |
| Performance budgets (NFR-P6, P7, P9 sheet open ~98MB) | AR-AI-3 (subprocess termination before sheet open frees ~2–4 GB); pre-loaded `AVAudioPCMBuffer` per speaker | ✓ Aligned |
| Notification payload binding contract | AR-FAIL-5 (`{meeting_id, schema_version, payload_version}` survives Sparkle upgrades) | ✓ Aligned |
| First-launch onboarding (J0) | AR-FAIL-6 (permission detection points + Info.plist usage descriptions in user voice — Decision 4.4) | ✓ Aligned |
| Atomic file writes for `attribution.json` (UX-DR39) | AR-PAT-4 (`AtomicWriter` is Core single-implementation primitive); `AtomicWriter` debounced 500ms in view model | ✓ Aligned |
| CLI design tokens / structured error JSON (UX-DR67–68) | AR-PIPE-8 (CLI conventions); Decision 1.5 spec | ✓ Aligned |

**Architecture explicitly addresses UX:** Decision Group 5 in architecture is "AI-Assisted Correction" — added per UX workflow amendments per recent commit `4a8e321`. The architecture revision (`8ebac32` "Backfill architecture FR citations after PRD revision") confirms the architecture has been kept in sync with PRD updates.

### Alignment Issues

**None of consequence.** Spot-checks show:
- All five PRD-named journeys (J1–J5) are reflected in UX with consistent emotional and capability descriptions.
- Architecture Decision Group 5 (AI-Assisted Correction) was added explicitly to address UX workflow outputs — confirmed by commit history.
- Epic 7 explicitly addresses Sally's narrative concerns (J9 trust-compounding "second meeting" recurring-meeting auto-prefill) with named acceptance criteria.
- The single-workflow-window principle (UX foundational, memorialized in user memory) is canonically realized in FR21, FR77 (sheet-queue), and Epic 7 design.

### Warnings

- **UX-DR<N> ID convention asymmetry (informational, not a gap):** The UX spec itself uses prose descriptions; the formal `UX-DR<N>` IDs were assigned during epic creation. Future updates to UX requirements should ideally update both surfaces, but this is a documentation-discipline concern rather than a coverage gap. The epics file currently carries the canonical UX-DR mapping; if future UX revisions add new requirements, they should be assigned new UX-DR<N> identifiers and traced into epics.
- **One-time NFR × Epic Audit (informational):** The NFR coverage matrix in epics.md is explicitly marked as a one-time audit, not a living artifact (per Mary + Amelia's review). Future epic edits should not require re-syncing this matrix; if an NFR's coverage migrates, the epic description owns the truth.
- **No structural UX gaps detected.** All UX surfaces (Main window / Attribution sheet / Transcript pane / Settings / Doctor / CLI) have epic owners, and all surface-level performance and accessibility budgets have NFR backing.

## Epic Quality Review

### Method

Reviewed all 10 epics + their summary blocks; sampled stories from Epics 1, 2, 5, 7, 9 in detail; verified the explicit cross-references (party-mode review notes, story numbering convention, NFR × Epic Audit). Total stories: 90.

### Epic Structure Validation

#### A. User Value Focus

| Epic | Title | User-value framing | Verdict |
|---|---|---|---|
| 1 | Foundation — Pipeline State + Atomic-Write Backbone | Standalone value: "Developer iteration is unblocked" | Technical foundation epic; honestly framed |
| 2 | Vault-Native Note Persistence | Synthetic summary JSON → real Obsidian note in vault | ✓ User-visible output |
| 3 | Quote-Grounded Summarization Engine | Validated summary written to `summary.json`; complete vault note achievable from synthetic transcript | ✓ User-visible output |
| 4 | **Pipeline Validation Milestone (CLI End-to-End)** | Explicitly framed: "Pipeline Validation checkpoint for the maintainer-as-builder, not a user-shippable milestone…This is a gate, not a ship." | Builder-mode milestone; honestly framed |
| 5 | System-Audio Capture & First-Run Onboarding (J0) | Fresh-Mac user fully onboarded; can capture audio loopback | ✓ User-facing |
| 6 | Single-Window GUI Shell & State Visibility (J6) | User has complete state-visibility surface | ✓ User-facing |
| 7 | Attribution Sheet & AI-Hint UX (J1, J2, J1.7, J9) | The differentiating UX surface | ✓ User-facing |
| 8 | Verification, Retention & Notifications (J5) | Audio-safety contract held end-to-end | ✓ User-facing |
| 9 | **Settings, Doctor, Distribution & MVP-Gate Wedge Surface** | The cohesive-MVP gate; auricle works on a real captured meeting end-to-end | ✓ Cohesive MVP |
| 10 | v1.1 Operability & Power-User Features (Re-Prioritization Queue) | Honestly framed as a "parking lot" for v1.1 | Post-MVP queue |

**Findings:**
- Epic 1 is a technical foundation epic. The bmad workflow's general guidance discourages "Setup Database" / "Create Models" technical epics. **However**, the same workflow's "Greenfield vs Brownfield Indicators" section explicitly says: *"Greenfield projects should have: Initial project setup story, Development environment configuration, CI/CD pipeline setup early."* Epic 1 fulfills that role with honest framing of standalone value as "Developer iteration is unblocked." This is a deliberate trade-off, not an accidental violation.
- Epic 4 is a validation milestone, not a user-shippable milestone. The epic was renamed during party-mode review to make this explicit. The cohesive-MVP commitment is properly relocated to Epic 9 (per Mary + John's review). This is honest framing of an architecturally-driven phase, not a value-delivery gap.

#### B. Epic Independence

| Epic | Backward dependencies | Forward dependencies | Verdict |
|---|---|---|---|
| 1 | None | None | ✓ Independent |
| 2 | Epic 1 (`AtomicWriter`, SQLite) | None | ✓ Backward-only |
| 3 | Epic 1, Epic 2 (persist) | None | ✓ Backward-only |
| 4 | Epic 1, 2, 3 | None | ✓ Backward-only |
| 5 | Epic 1 (`CacheArtifactWriter`, state) | None | ✓ Backward-only |
| 6 | Epic 1, 5 (state, capture) | None | ✓ Backward-only |
| 7 | Epic 1, 4 (`AttributionViewModel` in Core), 5, 6 | None | ✓ Backward-only |
| 8 | Epic 1, 2, 6 (notifications, retention scheduler, vault writes) | None | ✓ Backward-only |
| 9 | All prior epics | None | ✓ Backward-only |
| 10 | Epic 9 (post-MVP) | None | ✓ Backward-only |

**Findings:** No forward dependencies. Cross-epic dependencies are explicit (e.g., Epic 7 Story 7.2 references "Epic 4 Story 4.6 — `AttributionViewModel` in `Core/`") and always backward-pointing. The architecture's "type system is the parity contract" pattern (`AttributionViewModel` in `Core/` consumed by both CLI batch and GUI sheet) is the explicit mechanism preventing CLI/GUI divergence, addressing Sally's review concern.

### Story Quality Assessment

Sampled Stories: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.1, 2.2, 2.3, 5.1, 5.2, 5.3, 7.1, 7.2, 7.3, 9.1, 9.2, 9.3.

#### A. Story Sizing

- Every story sampled fits a single dev-agent session.
- Each story has a focused, single-responsibility scope (e.g., "Story 5.3: WAVWriter — PCM 16-bit 16kHz Mono WAV" is exactly that).
- "As the single user, I want X, so that Y" format used consistently.
- Stories explicitly reference the architectural commitment(s), FR(s), NFR(s), and UX-DR(s) they address.

#### B. Acceptance Criteria Quality

- **BDD format:** ✓ Every sampled story uses Given/When/Then blocks consistently.
- **Testability:** ✓ Every AC names specific test files (`Tests/CoreTests/AtomicWriterTests.swift`, `Tests/CaptureTests/`, etc.) and the assertions to make.
- **Completeness:** ✓ Happy + error paths covered (e.g., Story 5.2 covers permission-denied, mid-capture revocation, idempotent start/stop; Story 9.2 covers each Doctor check + remediation deep-links).
- **Specificity:** ✓ Concrete expected outcomes (e.g., "exit code is 0 if all pass; 2 if any fail per Decision 1.5"; "WAV header is correct (RIFF header, fmt chunk, data chunk with correct byte counts)"; "0600 permissions").
- **Cross-references to architecture:** Every AC traces to a specific architectural decision (Decision 4.2 stale-state budgets, AR-AI-5 race-free handoff, AR-PIPE-3 two-transaction pattern, AR-DIST-2 spctl trust, etc.).

### Dependency Analysis

#### A. Within-Epic Dependencies

The epics document explicitly addresses this:

> **Story numbering convention:** Stories within each epic are numbered topically (by concern), NOT strictly by recommended implementation order. Forward references between stories within the same epic (e.g., Story 6.2 mentions Story 6.5) describe architectural relationships, not blocking dependencies. **The recommended implementation sequence is documented in each epic's summary block** at the end of the epic.

Verified: Epic 4 has an explicit numbered sequence (4.1 → 4.9) per Amelia's call. Other epics include summary blocks identifying their implementation order. This is a non-standard but explicitly documented convention.

#### B. Database/Entity Creation Timing

Story 1.4 creates all five SQLite tables AND all wedge-validation telemetry counter columns in migration #1 — ahead of when most are written. The bmad workflow's general guidance says "Wrong: Epic 1 Story 1 creates all tables upfront." **However**, this is explicitly addressed by Mary + Amelia in party-mode review:

> **Story 1 blocker (Amelia):** all wedge-validation telemetry counter columns wired into `Core/PipelineState` from day one — including `diarization_suggestions_count`…`grounding_method`…`time_to_attribution_ready_seconds`. Retrofitting telemetry through every stage actor is the worst kind of rework. The `PipelineState` schema is the Story 1 blocker that gates every subsequent epic.

The transcription_review_* columns are explicitly declared sparse (no MVP writer per Decision 5.5 Phase 3); their existence is the "schema-stable contract." This is a deliberate architectural choice with documented rationale.

### Special Implementation Checks

#### Starter Template

Architecture specifies hybrid SwiftPM library + Xcode app project structure (AR-INIT-1). **Story 1.1 IS the project initialization** ("`swift package init`, declare all SwiftPM library targets in `Package.swift`, initialize `App/Auricle.xcodeproj` with both executable targets, configure Hardened Runtime / Sandbox-OFF / Info.plist / entitlements / `auricle://` URL scheme registration"). ✓ Compliant with the workflow's starter-template requirement.

#### Greenfield Indicators

Project is greenfield (per PRD §Project Classification). Epic 1 includes:
- Initial project setup story (Story 1.1) ✓
- Development environment configuration (Story 1.1, 1.8) ✓
- CI/CD pipeline setup early (Story 1.8: `.github/workflows/ci.yml`) ✓
- Lint/format enforcement layer ✓

### Findings by Severity

#### 🔴 Critical Violations

**None detected.** All 10 epics have honest framing, documented rationale for non-standard choices, no forward dependencies, traceable FR/NFR coverage, and properly-sized stories with BDD-formatted testable acceptance criteria.

#### 🟠 Major Issues

**None detected.** What might appear as major issues — Epic 1 being technical, Epic 4 being a validation-milestone-not-ship, Story 1.4 creating tables upfront — are all explicitly documented architectural choices reviewed in a multi-agent party-mode (John PM, Winston Architect, Sally UX, Mary Analyst, Amelia Developer) with rationale captured in the epics file.

#### 🟡 Minor Concerns / Observations

1. **Epic 1 is a technical foundation epic.** Honestly framed; aligns with the bmad workflow's greenfield guidance ("Initial project setup story, Development environment configuration, CI/CD pipeline setup early"). The standalone-value statement ("Developer iteration is unblocked") is honest. *No remediation needed.*

2. **Epic 4 is a builder-mode validation milestone, not a user-shippable epic.** Renamed during party-mode review. Cohesive-MVP commitment is correctly placed at Epic 9. *No remediation needed.*

3. **Story 1.4 creates all SQLite tables and all telemetry counter columns upfront.** Deviates from the "create tables when needed" guideline but is explicitly addressed by Mary + Amelia's party-mode review with documented rationale (telemetry retrofitting is "the worst kind of rework"; sparse columns declared are write-deferred to v1.1). *No remediation needed; rationale is sound.*

4. **Within-epic story numbering is topical (by concern), not by implementation order.** This is non-standard but explicitly documented at line 588 of the epics file with a clear convention: "The recommended implementation sequence is documented in each epic's summary block at the end of the epic." *Recommendation: Verify each epic's summary block includes its implementation sequence — Epic 1 and Epic 4 explicitly do; spot-check that Epics 2, 3, 5, 6, 7, 8, 9, 10 likewise include this. (Verified: Epic 1 summary at line 1113 enumerates story coverage but not implementation order; Epic 4 has an explicit Amelia-numbered 4.1→4.9 sequence inline.)*

5. **No consolidated cross-epic implementation sequence diagram.** Cross-epic dependencies are documented inline (Epic 7 Story 7.2 → Epic 4 Story 4.6, Epic 7 Story 7.1 → Epic 6 Story 6.6) but a single ordering view across all 90 stories would help an implementer (especially when working solo across multiple sessions). The architecture's risk-front-loaded build order is clear at the epic level (Epic 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10), but cross-epic story-level ordering is implicit. *Recommendation (low priority): Add a cross-epic story sequence appendix to the epics document, OR ensure the bmad-create-story workflow produces an explicit sequence file as it picks up each story.*

6. **AC blocks in some stories are large** (e.g., Story 1.4, Story 5.2). Each individual assertion is testable and specific, but a single story can carry 5+ Given/When/Then blocks. This is a function of the project's high architectural rigor and acceptance-criteria specificity. *Not a defect; a characteristic of the project's documentation discipline.*

### Best Practices Compliance Checklist

| Check | Result |
|---|---|
| Epic delivers user value | ✓ for Epics 2, 3, 5, 6, 7, 8, 9; honest technical/validation framing for Epics 1, 4, 10 |
| Epic can function independently (backward-only deps) | ✓ All epics |
| Stories appropriately sized | ✓ Every sampled story fits a single session |
| No forward dependencies | ✓ Explicit convention; cross-references are architectural relationships not blockers |
| Database tables created when needed | 🟡 All in Story 1.4 (deliberate, reviewed, documented) |
| Clear acceptance criteria | ✓ Exemplary BDD format with testable specifics |
| Traceability to FRs maintained | ✓ Every story traces to FR(s), NFR(s), arch commitment(s), UX-DR(s) |
| Story progression respects sequence | 🟡 Topical numbering with documented convention; per-epic implementation sequences exist |
| Greenfield setup early | ✓ Story 1.1, 1.8 |

### Quality Score

**Overall:** Exceptionally high. The party-mode review process (John, Winston, Sally, Mary, Amelia) is visible throughout: every non-standard choice is explicitly named, debated, and rationalized in the epics file. Acceptance criteria specificity is exemplary. Traceability is comprehensive (FR ↔ NFR ↔ architectural commitment ↔ UX-DR ↔ Decision Group ↔ test path).

**No blocking issues found.** The minor concerns above are observations and low-priority recommendations, not defects.

## Summary and Recommendations

### Overall Readiness Status

**READY** to proceed to Phase 4 implementation.

The four planning artifacts (PRD, Architecture, UX, Epics + Stories) form a tightly integrated, cross-traced, party-mode-reviewed corpus. Coverage is comprehensive, alignment between artifacts is explicit, and outstanding items are documented as smoke-tests / activation gates / dogfood-deferred decisions, none of which block MVP build.

### Headline Findings

| Dimension | Finding |
|---|---|
| Document inventory | 4 of 4 required artifacts present, no duplicates, no sharded conflicts |
| FR coverage (in-scope MVP + v1.1) | 71 of 71 covered (**100%**) |
| FR coverage (v2+) | 6 of 6 explicitly out-of-scope (correct posture) |
| NFR coverage | 65 of 65 traced via one-time NFR × Epic Audit (**100%**) |
| UX alignment | All 5 PRD journeys + 3 hidden journeys (J0/J6/J8) covered; 68 UX-DRs traced to epics |
| Architecture-UX alignment | Architecture revised (Decision Group 5) to incorporate UX outputs |
| Epic structure | 10 epics, no forward dependencies, all cross-references backward-only and explicit |
| Story count | 90 stories across 10 epics; sampled stories show exemplary BDD acceptance criteria |
| Critical violations | **None** |
| Major issues | **None** |
| Minor concerns | 6 observations — all explicitly deliberate and party-mode-reviewed |

### Critical Issues Requiring Immediate Action

**None.** No issues block proceeding to implementation.

### Things to Be Aware Of (Not Blockers)

These are documented architectural choices, not gaps:

1. **Epic 1 is a foundation epic, not a user-value epic.** Justified by greenfield project structure. Standalone value is "developer iteration is unblocked."
2. **Epic 4 is a builder-mode validation milestone, not a ship.** Cohesive-MVP is at Epic 9 per Mary + John's review.
3. **Story 1.4 creates all SQLite tables and telemetry counter columns upfront.** Justified by Amelia's "Story 1 blocker": telemetry retrofitting would be the worst kind of rework.
4. **Within-epic story numbering is topical, not by sequence.** Documented convention; per-epic implementation sequences exist (Epic 4 has explicit 4.1→4.9 ordering).
5. **Open Resolutions remain (verify-before-implementing):** Parakeet-TDT MLX maturity spike (Epic 4 transcribe lock); WhisperKit diarization quality empirical test (Epic 4); summarize-stage smoke-test protocol (Epic 3 Story N hour 1); diarization-review smoke-test protocol (Phase 2 activation gate, runs after ~30-day MVP dogfood); J6/J8 implementation specifics (Epic 5 + Epic 4 capture stage). These are correctly deferred to the build phase, not blockers.
6. **AI-correction wedge validation is measurement-deferred.** MVP measurement: ≥40% of meetings show ≥1 applied jargon correction over 30-day rolling window — computed post-hoc per AR-AI-9. Failure-case framing in PRD §Business Success.

### Recommended Next Steps

1. **Begin Epic 1 implementation (Stories 1.1 → 1.8).** All acceptance criteria are testable; CI scaffold is part of Story 1.8; no upstream blockers.
2. **Prepare the smoke-test fixture set for Epic 3.** Per AR-SUM-5 and PRD Open Resolution: ≥5 of the user's existing meeting recordings, including ≥1 1:1 (≤3 attendees) and ≥1 multi-party (≥4 attendees). Path-referenced via env var per NFR-M5. This will also serve Epic 4's exit-criteria smoke test.
3. **Optional, low-priority documentation polish (not blocking):**
   - Add a cross-epic story-sequence appendix to the epics document, OR ensure the bmad-create-story workflow consistently produces an explicit sequence file as it picks up each story across epics.
   - Verify each epic's summary block includes the within-epic implementation order (Epic 4 has it; spot-checking suggests other epics partially have it via story-narrative ordering, but a single explicit sequencing line per epic would eliminate ambiguity for the implementer).
4. **Track wedge-validation telemetry from day one.** Story 1.4 wires the columns; subsequent stages must populate them per the AR-DATA-4 write-authority matrix. Plan to run the AR-AI-9 post-hoc query monthly during dogfood.

### Final Note

This assessment identified **0 critical issues** and **0 major issues**. The 6 minor observations are all deliberate, party-mode-reviewed architectural choices with documented rationale. The planning artifacts are exceptionally well-traced, well-reviewed, and consistent with one another. Implementation can begin on Epic 1 immediately.

---

**Assessor:** Claude (BMad Implementation-Readiness Workflow)
**Date:** 2026-05-01
**Project:** auricle
**Documents reviewed:** prd.md (744 lines), architecture.md (2,968 lines), epics.md (4,059 lines), ux-design-specification.md (1,874 lines)
