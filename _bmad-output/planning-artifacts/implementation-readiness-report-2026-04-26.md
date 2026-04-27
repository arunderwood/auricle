---
stepsCompleted: ['step-01-document-discovery', 'step-02-prd-analysis']
project: auricle
date: 2026-04-26
inputDocuments:
  prd: _bmad-output/planning-artifacts/prd.md
  architecture: null
  ux: null
  epics: null
inputDocumentStatus:
  prd: present
  architecture: missing
  ux: missing
  epics: missing
workflowType: 'implementation-readiness'
---

# Implementation Readiness Assessment Report

**Date:** 2026-04-26
**Project:** auricle

## Document Inventory

### PRD
- **Status:** ✅ Present
- **File:** `_bmad-output/planning-artifacts/prd.md`
- **Format:** Whole document (not sharded)
- **Size:** 706 lines, 12 Level 2 sections, 72 FRs, 65 NFRs
- **Last modified:** 2026-04-26

### Architecture
- **Status:** ⚠️ Missing
- **Expected location:** `_bmad-output/planning-artifacts/architecture*.md` or `architecture/index.md`
- **Impact:** Architecture-derived readiness criteria (NFR-to-component coverage, technology choices, integration designs) cannot be assessed.

### UX Design
- **Status:** ⚠️ Missing
- **Expected location:** `_bmad-output/planning-artifacts/ux*.md` or `ux/index.md`
- **Impact:** UX-derived readiness criteria (journey-to-screen coverage, interaction-flow completeness, accessibility design coverage) cannot be assessed.

### Epics & Stories
- **Status:** ⚠️ Missing
- **Expected location:** `_bmad-output/planning-artifacts/epic*.md` or `epics/index.md`
- **Impact:** Epic-to-FR coverage (the central readiness check) cannot be assessed. This is normally the **primary** signal this workflow produces.

## Discovery Notes

- No duplicate documents detected (no whole + sharded conflicts).
- This is a fresh greenfield project — only the PRD has been created (today, 2026-04-26).
- The brainstorming session that fed the PRD lives at `_bmad-output/brainstorming/brainstorming-session-2026-04-23-1644.md` and is referenced by the PRD's `inputDocuments` frontmatter.
- This assessment will primarily report **what is missing** rather than score document quality.

## PRD Analysis

The full text of every requirement lives in [prd.md → Functional Requirements](_bmad-output/planning-artifacts/prd.md) and [prd.md → Non-Functional Requirements](_bmad-output/planning-artifacts/prd.md). This section inventories each requirement by ID, scope tier, and short descriptor for downstream coverage cross-referencing. Open the PRD for the full normative text.

### Functional Requirements

**Capture (FR1–FR10):**
- FR1 [MVP] Start capture from main window
- FR2 [MVP] Stop capture from main window
- FR3 [MVP] Visible recording-state indicator
- FR4 [MVP] System-audio loopback capture (any meeting platform)
- FR5 [MVP] Simultaneous mic capture mixed with system audio
- FR6 [MVP] Request/handle Screen Recording + Microphone permissions
- FR7 [MVP] Manual discard of captured-but-unprocessed meeting
- FR8 [v1.1] Start/stop from menubar
- FR9 [v1.1] VAD pre-flight halting gate
- FR10 [v1.1] VAD halt override (UI + `--force`)

**Pipeline Orchestration & State (FR11–FR16):**
- FR11 [MVP] Pipeline as crash-isolated stages
- FR12 [MVP] Each stage as `auricle <stage>` CLI subcommand
- FR13 [MVP] Per-meeting state in main window
- FR14 [MVP] Idempotent stage re-run
- FR15 [v1.1] `auricle pending` listing
- FR16 [v1.1] Dock badge for stale-pending count

**Transcription & Diarization (FR17–FR20):**
- FR17 [MVP] On-device WhisperKit transcription (Whisper-large-v3-turbo)
- FR18 [MVP] WhisperKit built-in diarization
- FR19 [MVP] English-only
- FR20 [MVP] Local transcription (no network)

**Attribution (FR21–FR27):**
- FR21 [MVP] Native blocking attribution UI
- FR22 [MVP] Per-speaker audio snippet playback
- FR23 [MVP] Calendar-marked autocomplete (calendar attendees → vault wikilinks → previously-labeled)
- FR24 [MVP] "This is me" self-attribution
- FR25 [MVP] "Publish anyway" + `#auricle/needs-attribution`
- FR26 [MVP] Manual attribution fix in Obsidian (auricle never re-edits)
- FR27 [v1.1] CLI attribution: `--emit-snippets` and `--speakers "1=Name,..."`

**Summarization (FR28–FR34):**
- FR28 [MVP] Structured output (summary + action items + decisions)
- FR29 [MVP] `source_transcript_quote` on every action item and decision
- FR30 [MVP] Quote-grounding grep validation (drop missing-quote items)
- FR31 [MVP] Claude API as default summarization engine
- FR32 [MVP] Single constrained-JSON Claude call per meeting
- FR33 [v1.1+] Local LLM summarization path (Ollama / MLX), config-selectable
- FR34 [v1.1] Long-context drift detection on ≥60-min meetings

**Persistence & Vault Integrity (FR35–FR41):**
- FR35 [MVP] One markdown file per meeting at configurable vault path
- FR36 [MVP] Atomic write (temp → fsync → rename); never edit existing files
- FR37 [MVP] Stable note structure (frontmatter, summary, action items, decisions, transcript)
- FR38 [MVP] Speakers as `[[wikilinks]]` resolvable in vault
- FR39 [MVP] Frontmatter contract (time, duration, attendees, audio path, calendar id, tags, schema version, retention, telemetry)
- FR40 [MVP] Stable filename convention (date + meeting title), collision-safe
- FR41 [MVP] `auricle:` block in frontmatter; tags scoped to `auricle/*`

**Notification & Verification (FR42–FR44):**
- FR42 [MVP] macOS notification on summary ready
- FR43 [MVP] Click → opens note in Obsidian via URL scheme
- FR44 [MVP] Click is the verification trigger arming the retention timer

**Audio Retention & Lifecycle (FR45–FR50):**
- FR45 [MVP] Hold audio indefinitely until verification click
- FR46 [MVP] 7-day grace timer post-verification (configurable default)
- FR47 [MVP] Re-prompt at 7d, escalate at 14d before deletion
- FR48 [MVP] Per-meeting retention status visible in main window
- FR49 [v1.1] Retention override (UI + `auricle keep <id>`)
- FR50 [v1.1] Per-meeting configurable retention windows

**Calendar Enrichment (FR51–FR54):**
- FR51 [MVP] Google Calendar OAuth (Keychain-stored tokens)
- FR52 [MVP] Match captured meeting to calendar event; inject metadata
- FR53 [MVP] Upcoming meetings sidebar
- FR54 [MVP] Graceful degradation when calendar unreachable (`#auricle/needs-calendar-enrichment`)

**Vault-Glossary Correction (FR55–FR57):**
- FR55 [MVP] Extract glossary from vault wikilink targets
- FR56 [MVP] Scope glossary to meeting attendees/topics when possible
- FR57 [MVP] Inject glossary into summarization prompt for term correction

**Configuration & Permissions (FR58–FR60):**
- FR58 [MVP] Configurable: vault path, retention default, summarization engine, API key, Google account, log verbosity
- FR59 [MVP] Config in `~/Library/Application Support/com.auricle.app/`; secrets in Keychain
- FR60 [MVP] Detect missing required permissions on launch with remediation path

**Operations & Failure Recovery (FR61–FR66):**
- FR61 [MVP] Structured logging via `os_log` under `com.auricle.app`
- FR62 [MVP] Per-stage crash isolation; pickup-from-last-success
- FR63 [MVP] App stays alive on window close (capture continues)
- FR64 [MVP] Cmd-Q gracefully stops capture and persists state
- FR65 [v1.1] Sparkle self-update with signed appcasts
- FR66 [MVP] Local SQLite telemetry (per-meeting metrics, no remote reporting)

**Future / Vision v2+ (FR67–FR72):**
- FR67 [v2+] Auto-detect meeting in progress (process-watching)
- FR68 [v2+] Cross-meeting voice-print matching (pyannote sidecar)
- FR69 [v2+] Meeting-type templates
- FR70 [v2+] Series-overview auto-aggregation for recurring meetings
- FR71 [v2+] Chain-of-summarize fallback for ≥90-min transcripts
- FR72 [v2+] Apple SpeechAnalyzer fallback ASR (macOS 26+)

**Total FRs:** 72 (50 MVP, 16 v1.1, 6 v2+)

### Non-Functional Requirements

**Performance (NFR-P1–NFR-P13):** P50/P95 latency budgets per stage and end-to-end (≤2 min P50 30-min meeting); memory ceiling (200 MB idle, 4 GB peak); cold-start (≤1.5s); zero added system-audio latency. All quantified with reference hardware (M5 Max) and methodology.

**Reliability & Data Integrity (NFR-R1–NFR-R10):** Atomic vault writes (zero partial-write events tolerated); never edit existing vault files; zero unverified-audio-deletion events tolerated; stage crash isolation; idempotent stage re-runs; SQLite state checkpointing; quote-grounding as hard gate; graceful Anthropic API offline behavior with backoff.

**Security (NFR-S1–NFR-S9):** Keychain-only secrets; Developer ID signing + notarization + hardened runtime; 0600 cache permissions; TLS 1.2+ with cert validation; OAuth PKCE with minimum scopes; log redaction of secrets; no off-machine telemetry; Sparkle EdDSA signature validation [v1.1].

**Privacy (NFR-Pr1–NFR-Pr7):** No off-machine data flow except configured stages (Claude, Calendar); no telemetry to any third party; user-owned-directories-only artifact storage; audio never sent to API; conservative retention defaults; no participant indication of capture (the user is responsible for jurisdictional consent).

**Integration & Compatibility (NFR-I1–NFR-I8):** macOS 14+ Apple Silicon; Obsidian 1.x via URL scheme (no plugin required); versioned frontmatter schema with documented migration; Google Calendar API v3 read-only; Anthropic Messages API with configurable model; stable CLI argument signatures; v1.1+ local LLM via Ollama/MLX.

**Accessibility (NFR-A1–NFR-A6):** VoiceOver navigation; keyboard-navigable attribution UI with Spacebar snippet playback; color never sole conveyor of meaning; Dynamic-Type respect; Reduce Motion respect; Dark/Light Mode native.

**Maintainability & Operability (NFR-M1–NFR-M8):** Swift-only (no Python/Node/Electron in MVP); CLI-subprocess pipeline isolation; structured per-stage `os_log` categories; unit tests for schema/quote-grounding/glossary/filename/retention; CI-runnable end-to-end smoke test; runtime config changes; reproducible release builds; rationale comments where why-is-non-obvious.

**Cost (NFR-C1–NFR-C4):** ≤\$0.10 per 30-min meeting at MVP, ≤\$0.05 at v1.1, \$0 on local-LLM path; \$99/year Apple Developer as only fixed cost.

**Total NFRs:** 65 (across 8 categories — Performance, Reliability, Security, Privacy, Integration, Accessibility, Maintainability, Cost)

### Additional Requirements & Constraints

**Design Principles (architectural commitments, not FRs):**
- DP1: Stages are decoupled CLI subcommands; the Mac app is a UI + dispatcher, not a monolith
- DP2: The frontmatter contract is canonical (speakers as wikilinks, no confidence flags exposed in vault, no tag noise beyond `auricle/*`)
- DP3: Audio is the only recovery layer (never auto-deleted before user verification)
- DP4: The vault is a downstream consumer with a contract (auricle outputs structured data, does not perform analytics)
- DP5 (implicit): Engagement happens upfront, not downstream (attribution is blocking, not optional)

**Hard constraints (locked decisions from brainstorm):**
- macOS-only, Apple Silicon-only, English-only, single-user/single-machine
- No bot in meeting, no SaaS hosting, no OpenAI vendor, no multi-user/team mode
- No App Store distribution (sandboxing conflict with audio capture)

**Open Resolutions (verify-before-implementing flags requiring empirical resolution during build):**
- Parakeet-TDT MLX maturity (alternate ASR if WhisperKit insufficient)
- WhisperKit diarization quality + embeddings exposure (UX impact + v2 voice-print prep)
- Apple SpeechAnalyzer quality (tertiary fallback, macOS 26+)
- Summarization engine: Claude vs. local LLM benchmark on 10–20 real meetings
- Vault note shape detail (filename / location / attendees-frontmatter convention; needs community pattern research)
- Long-context drift threshold (measure on real 60+ min meetings; v1.1 guard threshold)

### PRD Completeness Assessment

The PRD is **complete and high-quality** for its scope. Specifically:

- **Information density:** Every section carries weight. No fluff phrases, no implementation leakage in FRs, no vague NFRs.
- **Measurability:** All performance, reliability, cost, and integration NFRs are quantified with specific numeric thresholds, reference hardware, and measurement methodologies. Reliability NFRs use "zero events tolerated" framing where appropriate.
- **Traceability:** FRs are organized by capability area; each scope-tier-tagged. NFRs explicitly link back to user-facing claims (e.g., NFR-P1 backs the "≤ 2 min wait after meeting" promise). Design Principles tie back to brainstorming session.
- **Coverage:** All 5 user journeys map to FR clusters. All locked architectural decisions from brainstorm are reflected. Domain step appropriately skipped (general-purpose tool, no regulatory regime). Innovation analysis is honest (the novelty is the *combination*, not any single component).
- **Scope discipline:** Three explicit scope tiers (MVP / v1.1 / v2+). MVP cuts have documented rationale per item. Excluded-forever items explicitly listed.
- **Empirical resolution honesty:** Open resolutions appendix names what cannot be settled in the PRD and must be resolved with real-world data during build. This is unusual but valuable.

**Areas where the PRD intentionally defers detail (not gaps, but trail markers for downstream artifacts):**
- Concrete Mac app screen layouts and visual design — appropriately deferred to UX design artifact
- File-level architecture (module boundaries, Swift package layout, specific class shapes) — appropriately deferred to architecture artifact
- Sequence-of-operations / state machines at code level — appropriately deferred to architecture artifact
- Database schema for the SQLite state file — appropriately deferred to architecture artifact
- Specific Claude prompt design (system prompt, few-shot examples, JSON schema) — appropriately deferred to architecture / build phase
- Specific frontmatter field schema (exact YAML structure, field types) — appropriately deferred to architecture artifact (the *contract* is established; the *exact shape* is a downstream lock-in informed by community research)

These are not PRD failures; they're proper layering. They will be assessment criteria when architecture and UX documents are eventually produced.
