---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics', 'step-03-create-stories', 'step-04-final-validation']
status: complete
completedAt: 2026-05-01
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/ux-design-specification.md
---

# auricle - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for auricle, decomposing the requirements from the PRD, UX Design Specification, and Architecture decisions into implementable stories.

## Requirements Inventory

### Functional Requirements

#### Capture (FR1–FR10)

- **FR1 [MVP]:** The user can start audio capture for a meeting via a prominent control in the auricle main window.
- **FR2 [MVP]:** The user can stop audio capture via the same control, ending the recording and triggering the post-capture pipeline.
- **FR3 [MVP]:** The user can see a visible recording-state indicator while capture is active (in the main window title bar, at minimum).
- **FR4 [MVP]:** auricle can capture system audio (loopback from any application playing audio) without requiring integration with the meeting platform.
- **FR5 [MVP]:** auricle can simultaneously capture the user's microphone audio and mix it with system audio for a complete two-sided recording.
- **FR6 [MVP]:** auricle can request and handle macOS System Audio Recording and Microphone permissions, with clear in-app explanation if permission is denied.
- **FR7 [MVP]:** The user can manually discard a captured-but-unprocessed meeting from the main window, removing the cached audio.
- **FR8 [v1.1]:** The user can start and stop capture from a menubar item without opening the main window.
- **FR9 [v1.1]:** auricle can pre-flight a captured audio file with VAD and halt the pipeline if speech-content is below a configurable threshold (default: <2 minutes of speech).
- **FR10 [v1.1]:** The user can override a VAD halt and force-process a meeting via UI affordance and CLI flag (`auricle process <id> --force`).

#### Pipeline Orchestration & State (FR11–FR16)

- **FR11 [MVP]:** auricle can execute the meeting pipeline in distinct, crash-isolated stages: capture → transcribe → diarize → attribute → summarize → persist → notify.
- **FR12 [MVP]:** Each pipeline stage can be invoked independently as an `auricle <stage> <id>` CLI subcommand, producing identical artifacts to in-app execution.
- **FR13 [MVP]:** The user can see a per-meeting state in the main window indicating which stage is in progress, awaiting user action, or complete (`Recording`, `Processing`, `Awaiting Attribution`, `Awaiting Verification`, `Verified`).
- **FR14 [MVP]:** The user can re-run a failed stage idempotently without corrupting artifacts from earlier stages.
- **FR15 [v1.1]:** The user can list all in-flight, silent, awaiting-attribution, awaiting-verification, and stale-pending meetings via `auricle pending`.
- **FR16 [v1.1]:** auricle can display a Dock badge count of stale-pending items (meetings awaiting verification beyond N days).

#### Transcription & Diarization (FR17–FR20)

- **FR17 [MVP]:** auricle can transcribe captured audio to text on-device using WhisperKit with the Whisper-large-v3-turbo model.
- **FR18 [MVP]:** auricle can perform speaker diarization on captured audio using WhisperKit's built-in diarization, producing speaker-segmented transcript output (`Speaker_1`, `Speaker_2`, …).
- **FR19 [MVP]:** auricle can transcribe English-language audio (other languages explicitly out of scope).
- **FR20 [MVP]:** auricle can complete transcription on the user's local machine without any network round-trip.

#### Attribution (FR21–FR27, FR77)

- **FR21 [MVP]:** The user can review detected speakers in a native Attribution sheet attached to the main window (modal, not a separate window — single-workflow-window principle) after diarization completes, with the pipeline blocked on their input before summarization runs.
- **FR22 [MVP]:** The user can play a short representative audio snippet (5–10 seconds) for each detected speaker via an in-UI playback control.
- **FR23 [MVP]:** The user can assign a name to each detected speaker via an autocomplete input that prioritizes (1) calendar attendees of the current meeting (visually marked), (2) existing vault wikilink targets, (3) previously-labeled speakers, with frequency/recency tie-breakers.
- **FR24 [MVP]:** The user can mark themselves as a specific speaker without typing — a "this is me" affordance.
- **FR25 [MVP]:** The user can publish a meeting without completing attribution via a "Publish anyway" action; the resulting note uses `Speaker_N` placeholder labels and is tagged `#auricle/needs-attribution` in frontmatter.
- **FR26 [MVP]:** The user can manually fix attribution in Obsidian after the fact (auricle never re-edits the note, so manual fixes are permanent and uncontested).
- **FR27 [v1.1]:** The user can complete attribution via CLI when the native UI is unavailable: `auricle attribute <id> --emit-snippets` writes WAV snippets to the cache directory; `auricle attribute <id> --speakers "1=Ben,2=Sara,..."` accepts a manual mapping and resumes the pipeline.
- **FR77 [MVP]:** When ≥2 meetings are simultaneously in `Awaiting Attribution`, auricle serializes the Attribution sheet — only one sheet is open at a time. The main window displays a banner counter ("3 meetings waiting for attribution") with a click target that opens the next queued sheet; completing/dismissing/saving-for-later the active sheet causes the next queued meeting's sheet to rise. Sheet ordering is FIFO by capture-stop timestamp.

#### Summarization (FR28–FR34)

- **FR28 [MVP]:** auricle can summarize an attributed transcript into a structured output containing: a one-paragraph summary, an array of action items, an array of decisions.
- **FR29 [MVP]:** Each action item and each decision in the structured output is grounded in the source transcript via a verifiable pointer — either character-range offsets returned by Anthropic's Citations API (the default Claude path) or a verbatim quote string (the local-LLM path FR33 v1.1+, and the automatic fallback path when Citations is unavailable). The rendered vault note displays the cited transcript text as a `> source quote` blockquote regardless of which mechanism produced the grounding.
- **FR30 [MVP]:** auricle can validate every grounding pointer against the source transcript (Citations bounds check OR literal substring match). Items failing validation are dropped before the note is written. Both validation paths produce identical normalized output (`{transcriptStart, transcriptEnd}`) so the renderer is grounding-method-agnostic.
- **FR31 [MVP]:** auricle can summarize via the Anthropic Claude API as the default summarization engine.
- **FR32 [MVP]:** auricle uses a single primary Claude call per meeting (chain-of-summarize deferred to v2+). On Citations API errors, malformed responses, or empty citation arrays, the orchestrator may automatically dispatch a single fallback call using the substring-grounding strategy; total per-meeting cost remains bounded by NFR-C1 across all calls.
- **FR33 [v1.1+]:** auricle can summarize via a local LLM path (Ollama or MLX) as an alternative to Claude, selected by configuration.
- **FR34 [v1.1]:** auricle can detect long-context drift on transcripts ≥60 minutes (token count + summary content density) and flag suspiciously thin summaries for user attention.

#### AI-Assisted Correction (FR73–FR76)

- **FR73 [MVP]:** auricle ships an `AIReviewerStrategy` family with concrete `ClaudeDiarizationReviewer` (Haiku-default), declared `TranscriptionReviewerStrategy` (no impl), and `JargonCorrectionStrategy` wrapping the existing glossary path (FR55–FR57). The pipeline includes a `reviewing_diarization` stage between diarization and attribution; `attribution.json` exposes `segment_overrides` and `segment_splits` schema fields for AI-applied corrections.
- **FR74 [MVP]:** auricle reads a `diarization_review.enabled` configuration flag (default `false`). When `true`, `ClaudeDiarizationReviewer` runs on every meeting and writes per-segment speaker corrections plus proposed splits to `diarization_suggestions.json`. When `false`, the stage writes an empty stub artifact in <100ms with no Claude call.
- **FR75 [MVP]:** When diarization-review suggestions exist, the user can review them inline in the Attribution sheet via per-paragraph `🤖` chips that expand to show reasoning and Apply/Reject controls. Applied suggestions write to `attribution.json` `segment_overrides`/`segment_splits` and are reversible via SwiftUI `UndoManager` for the duration of the sheet, with a "Revert this split" affordance available across sheet reopens. The Attribution sheet renders a trust-calibration footer showing recent accept rate (e.g., "Reviewed 47 segments, flagged 4 · Accept rate: 8/11 this week").
- **FR76 [v1.1]:** auricle declares `TranscriptionReviewerStrategy` and a `transcription_suggestions.json` cache schema in MVP without implementation. v1.1 adds `ClaudeTranscriptionReviewer` (Haiku-default), surfacing word/phrase-level transcription corrections (homophones, proper nouns, technical terms grounded in the vault glossary) in the transcript pane behind a `transcription_review.enabled` flag (default `false`).

#### Persistence & Vault Integrity (FR35–FR41)

- **FR35 [MVP]:** auricle can write each meeting as exactly one new markdown file to the user's Obsidian vault at a configurable path (default: `~/checkouts/SecondBrain/Meetings/`).
- **FR36 [MVP]:** auricle never opens an existing vault file for write; all persistence is `temp file → fsync → atomic rename`.
- **FR37 [MVP]:** auricle can render meeting notes with a stable structure: frontmatter block, one-paragraph summary, action items section (each with quote), decisions section (each with quote), collapsed transcript section.
- **FR38 [MVP]:** auricle can render speakers in summary text as Obsidian `[[wikilinks]]`, resolvable to existing or to-be-created people-notes in the vault.
- **FR39 [MVP]:** auricle can populate frontmatter with: meeting time, duration, attendees (as wikilinks), source audio path, calendar event ID (when available), tags array, schema version, retention policy, and per-stage timing telemetry.
- **FR40 [MVP]:** auricle can use a stable, predictable filename convention based on date and meeting title (e.g., `2026-04-28-tuesday-sync-with-ben.md`), avoiding collisions.
- **FR41 [MVP]:** auricle can record its own pipeline metadata in an `auricle:` block in the frontmatter without polluting the vault's tag namespace beyond `auricle/*` tags.

#### Notification & Verification (FR42–FR44)

- **FR42 [MVP]:** auricle can fire a macOS user notification when a meeting summary has been written to the vault, with the meeting title visible in the notification.
- **FR43 [MVP]:** The user can click the notification to open the resulting note in Obsidian via URL scheme.
- **FR44 [MVP]:** auricle can detect the notification click and use it as the verification trigger that arms the audio retention timer (the click is a meaningful event, not a passive open).

#### Audio Retention & Lifecycle (FR45–FR50)

- **FR45 [MVP]:** auricle can hold captured audio indefinitely until the user clicks the verification notification.
- **FR46 [MVP]:** auricle can begin a configurable grace timer (default 7 days) after the verification click, after which the captured audio is deleted from cache.
- **FR47 [MVP]:** auricle can re-prompt the user at 7 days post-verification (escalate at 14 days) to confirm or extend retention before deletion.
- **FR48 [MVP]:** The user can see per-meeting audio retention status (e.g., "Audio deletes in 5 days", "Audio kept (indefinite)", "Audio deleted") in the main window.
- **FR49 [v1.1]:** The user can override audio retention for a specific meeting (indefinite or custom window) via the main window UI and via `auricle keep <meeting-id>` CLI.
- **FR50 [v1.1]:** The user can configure per-meeting retention windows that override the default.

#### Calendar Enrichment (FR51–FR54)

- **FR51 [MVP]:** auricle can authenticate against Google Calendar via OAuth 2.0, storing tokens in the macOS Keychain.
- **FR52 [MVP]:** auricle can fetch the calendar event matching the time window of a captured meeting and inject title, attendees, and event metadata into the resulting note's frontmatter.
- **FR53 [MVP]:** auricle can display upcoming calendar meetings in a sidebar or surface in the main window, providing context for upcoming captures.
- **FR54 [MVP]:** auricle can degrade gracefully when calendar enrichment is unreachable (offline, API error, no matching event), publishing the note with a generic title and `#auricle/needs-calendar-enrichment` tag.

#### Vault-Glossary Correction (FR55–FR57)

- **FR55 [MVP]:** auricle can extract a glossary of terms from the user's Obsidian vault by enumerating wikilink targets (page names) across vault files.
- **FR56 [MVP]:** auricle can scope the glossary to terms relevant to the current meeting's attendees and topics, when sufficient context is available.
- **FR57 [MVP]:** auricle can inject the (scoped) glossary as context into the summarization prompt for term-correction during summary generation.

#### Configuration & Permissions (FR58–FR60)

- **FR58 [MVP]:** The user can configure: vault path, vault subdirectory for meeting notes, default audio retention grace window, summarization engine choice (Claude / local), Anthropic API key, Google OAuth account, log verbosity, and `summarization.prompt_dir` (override directory under `~/.auricle/prompts/`; default is the prompt set bundled with the build). Includes `diarization_review.enabled` and `diarization_review.model` per FR74.
- **FR59 [MVP]:** auricle can persist user-editable configuration in `~/.auricle/` as a structured file (TOML or JSON), separate from secrets (Keychain, NFR-S1) and from machine-managed operational state (the SQLite database, FR66). Any file the user is expected to edit, extend, or place config into lives under `~/.auricle/`.
- **FR60 [MVP]:** auricle can detect missing required permissions (System Audio Recording, Microphone, Notifications) on launch and surface a clear remediation path to the user.

#### Operations & Failure Recovery (FR61–FR66)

- **FR61 [MVP]:** Each pipeline stage can produce structured logs to the macOS unified logging system under subsystem `com.auricle.app`, with per-stage categories.
- **FR62 [MVP]:** auricle can survive a crash of any individual stage subprocess without losing artifacts from already-completed stages — the next pipeline run picks up from the last successful stage.
- **FR63 [MVP]:** auricle continues running after the main window is closed, allowing in-flight captures and pipelines to complete without user intervention.
- **FR64 [MVP]:** The user can quit the auricle app entirely via standard Cmd-Q, which gracefully stops any active capture and persists in-flight state.
- **FR65 [v1.1]:** auricle can self-update via Sparkle, fetching EdDSA-signed appcast updates from the project's release feed with user confirmation. Downloaded `.app` is signed with the self-managed code-signing certificate and accepted by Gatekeeper via the existing `spctl` trust policy.
- **FR66 [MVP]:** auricle can locally store per-meeting telemetry (time-to-attribution-ready, time-to-vault-note, quote-validation drops, attribution path, summarization cost, retention status, AI-reviewer counts/cost/model) in a SQLite database at `~/Library/Application Support/com.auricle.app/`, accessible to the user but not transmitted off-device.

#### Future / Vision (FR67–FR72) — v2+, out of MVP/v1.1 scope

- **FR67 [v2+]:** Auto-detect "meeting in progress" by observing running meeting-app processes.
- **FR68 [v2+]:** Persist speaker voice-print embeddings (via pyannote 3.1 sidecar) and match unlabeled speakers across meetings.
- **FR69 [v2+]:** **Select** a meeting-type-specific summarization template automatically from calendar metadata, from a curated set. Having per-meeting-type prompts is available from MVP via FR58's `summarization.prompt_dir`; what defers is auricle choosing for the user.
- **FR70 [v2+]:** Produce a "series-overview" auto-aggregated note for recurring meetings.
- **FR71 [v2+]:** Use chain-of-summarize fallback for very long transcripts (≥90 min) when single-call drift is detected.
- **FR72 [v2+]:** Use Apple SpeechAnalyzer as a fallback ASR path on macOS 26+.

### NonFunctional Requirements

#### Performance (NFR-P1–NFR-P13)

- **NFR-P1 [MVP]:** End-to-end pipeline (capture stop → notification fired) completes in **P50 ≤ 2 minutes, P95 ≤ 5 minutes** for a 30-minute single-track meeting on M5 Max hardware. Budget applies to `time_to_attribution_ready_seconds` (machine-time only).
- **NFR-P2 [MVP]:** End-to-end pipeline completes in **P95 ≤ 10 minutes** for a 60-minute meeting on the same reference hardware.
- **NFR-P3 [MVP]:** Transcription stage completes in ≤ 30 seconds for a 30-minute audio file using WhisperKit with Whisper-large-v3-turbo on ANE.
- **NFR-P4 [MVP]:** Diarization stage completes in ≤ 30 seconds for a 30-minute audio file (run as part of or immediately after transcription).
- **NFR-P5 [MVP]:** Summarization stage (Claude path) completes in P50 ≤ 60 seconds, P95 ≤ 180 seconds for a 30-minute transcript at ≤4k tokens.
- **NFR-P6 [MVP]:** Attribution UI loads detected speakers and is interactive within ≤ 2 seconds of the diarization stage completing.
- **NFR-P7 [MVP]:** Audio snippet playback in the attribution UI starts within ≤ 200 ms of click (perceptually instant).
- **NFR-P8 [MVP]:** Vault write (atomic temp + rename) completes in ≤ 500 ms for a meeting note up to 50 KB markdown.
- **NFR-P9 [MVP]:** auricle's idle memory footprint when no recording or processing is active is ≤ 200 MB. Attribution sheet open-state working target ~98 MB.
- **NFR-P10 [MVP]:** Peak memory footprint during transcription on a 60-minute audio file is ≤ 4 GB (driven by WhisperKit model load + audio buffers).
- **NFR-P11 [MVP]:** Idle CPU usage when no recording or processing is active is ≤ 1% CPU on Apple Silicon.
- **NFR-P12 [MVP]:** Cold start of the auricle app (Dock click → main window interactive) completes in ≤ 1.5 seconds.
- **NFR-P13 [MVP]:** During active capture, auricle adds no perceivable system audio latency (passive loopback only — does not insert in the audio chain).

#### Reliability & Data Integrity (NFR-R1–NFR-R10)

- **NFR-R1 [MVP]:** Vault writes are atomic: temp file → fsync(2) → rename(2). Zero partial-write events tolerated.
- **NFR-R2 [MVP]:** auricle never opens an existing vault file for write.
- **NFR-R3 [MVP]:** Captured audio is held until the user clicks the verification notification. Zero unverified-audio-deletion events tolerated. Default behavior on any retention-system error is to retain audio, not delete.
- **NFR-R4 [MVP]:** Each pipeline stage is crash-isolated as a separate `auricle <stage>` subprocess invocation. A crash in any single stage does not corrupt artifacts from earlier completed stages.
- **NFR-R5 [MVP]:** Each pipeline stage is idempotent — re-running it produces the same output deterministically.
- **NFR-R6 [MVP]:** auricle persists in-flight pipeline state in a SQLite database, and recovers cleanly from app crashes by re-reading state on next launch.
- **NFR-R7 [MVP]:** Quote-grounding validation is a hard gate: 100% of action items and decisions in published notes have a `source_transcript_quote` that survives validation. Items failing the check are dropped silently before persistence (logged at info level).
- **NFR-R8 [MVP]:** auricle handles the macOS Notification permission being revoked at any time without crashing — pipeline still completes, notification simply fails to deliver, meeting moves to "awaiting verification" state visible in the main window.
- **NFR-R9 [MVP]:** auricle handles the Anthropic API being unreachable by retrying with exponential backoff up to a configurable timeout (default 5 minutes); on persistent failure, the meeting is marked `summarization_failed` in pending state, not lost.
- **NFR-R10 [MVP]:** auricle's local SQLite state file is checkpointed on quit, plus SQLite's automatic checkpoint; corruption recovery is by replay from on-disk artifacts rather than from backup.

#### Security (NFR-S1–NFR-S9)

- **NFR-S1 [MVP]:** All secrets (Anthropic API key, Google OAuth refresh token) are stored in the macOS Keychain (`kSecClassGenericPassword`), never in plaintext on disk, never in environment variables, never in config files.
- **NFR-S2 [MVP]:** auricle binaries are signed with a self-managed code-signing certificate (personal CA + per-tool leaf cert) and trusted on each user Mac via a one-time `spctl` assessment-policy registration. Hardened runtime is enabled. Notarization is not used (Apple Developer ID intentionally avoided per NFR-C4).
- **NFR-S3 [MVP]:** Cached audio files are written with 0600 permissions (user-only read/write).
- **NFR-S4 [MVP]:** Vault notes inherit standard vault file permissions; auricle does not chmod existing files.
- **NFR-S5 [MVP]:** Anthropic API requests are made over TLS 1.2+ with certificate validation; no insecure-fallback path exists.
- **NFR-S6 [MVP]:** Google OAuth uses the device-code flow (or installed-application flow) with PKCE; refresh tokens are scoped to the minimum required Calendar API surface (read-only access to user's primary calendar).
- **NFR-S7 [MVP]:** auricle does not log secrets or API responses containing secrets to the unified logging system. Log redaction is enforced at the structured-logging layer.
- **NFR-S8 [MVP]:** auricle does not transmit transcripts, summaries, or audio anywhere except (a) the Anthropic API for the summarization stage when configured, and (b) the user's local vault filesystem. No telemetry endpoint exists in MVP.
- **NFR-S9 [v1.1]:** Sparkle update verification uses EdDSA signature validation; updates with invalid signatures are rejected.

#### Privacy (NFR-Pr1–NFR-Pr7)

- **NFR-Pr1 [MVP]:** No audio, transcript, summary, or vault content is transmitted off the user's machine except as explicitly required by a configured stage (Claude API for summarization, Google Calendar API for enrichment). All other stages are strictly local.
- **NFR-Pr2 [MVP]:** No anonymous usage telemetry, error reporting, or analytics is transmitted to any third party. Local SQLite telemetry is for the user's own dashboards only.
- **NFR-Pr3 [MVP]:** Captured audio, transcripts, and intermediate artifacts are scoped to user-owned directories and never written to system-wide locations.
- **NFR-Pr4 [MVP]:** When the Claude summarization path is used, the API call payload contains the transcript text and the vault glossary terms only. Audio is **never** transmitted; speaker labels are first-name-only by convention; calendar email addresses are stripped before payload assembly.
- **NFR-Pr5 [MVP]:** Anthropic's data-usage policy applies to the summarization API call. auricle documents the data flow clearly in the README and Settings UI to support informed consent.
- **NFR-Pr6 [MVP]:** Audio retention defaults are conservative (held until verified, then 7-day grace). The user can shorten or extend retention, but the default is biased toward "delete sooner" rather than "keep forever."
- **NFR-Pr7 [MVP]:** auricle gives no indication to other meeting participants that capture is occurring (this is a design feature: capture is OS-level, invisible). The user is responsible for legal/ethical recording-consent obligations.

#### Integration & Compatibility (NFR-I1–NFR-I8)

- **NFR-I1 [MVP]:** auricle requires macOS 14 (Sonoma) or later. macOS 15+ is the active development target.
- **NFR-I2 [MVP]:** auricle requires Apple Silicon (arm64). Intel Mac support is not provided.
- **NFR-I3 [MVP]:** auricle is compatible with the current major release of Obsidian (1.x) via the `obsidian://open` URL scheme. No Obsidian plugin required.
- **NFR-I4 [MVP]:** auricle's frontmatter schema is documented and versioned (`auricle.schema_version` field in every note). Breaking changes increment the major version and ship with a documented migration path.
- **NFR-I5 [MVP]:** auricle integrates with Google Calendar API v3 read-only. Calendar API failures degrade gracefully — meeting captures still complete with `#auricle/needs-calendar-enrichment` tag.
- **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and effort level are both configurable; default at MVP is `claude-opus-5` at `medium` effort (named levels `low`/`medium`/`high`/`xhigh`/`max` — no numeric override on this model generation). Both knobs are tunable via config (per FR58) without code changes.
- **NFR-I7 [MVP]:** auricle's CLI subcommands have stable, documented argument signatures. Renaming or removing a CLI flag is a breaking change requiring a major version bump.
- **NFR-I8 [v1.1+]:** auricle's local LLM path supports Ollama (HTTP API) and/or MLX (in-process). Specific runtime is configurable; switching is a config-only change, not a reinstall.

#### Accessibility (NFR-A1–NFR-A6)

- **NFR-A1 [MVP]:** Main window UI supports VoiceOver navigation. All interactive controls have descriptive accessibility labels.
- **NFR-A2 [MVP]:** All interactive controls in the attribution UI are keyboard-navigable. Tab order matches visual reading order. Speaker snippets can be played via keyboard (Spacebar after focus).
- **NFR-A3 [MVP]:** Color is never the sole conveyor of meaning. Recording-state indicator uses both color (red) and shape/animation (pulsing dot). Calendar-attendee priority in autocomplete is indicated by visible label, not just color.
- **NFR-A4 [MVP]:** Text in the main window respects the system text-size setting (Dynamic Type analogue on macOS).
- **NFR-A5 [MVP]:** auricle respects the system Reduce Motion setting; animations are simplified or disabled when this is on.
- **NFR-A6 [MVP]:** auricle works with the system Dark Mode and Light Mode settings without user configuration.

#### Maintainability & Operability (NFR-M1–NFR-M8)

- **NFR-M1 [MVP]:** auricle is implemented in Swift / SwiftUI / AppKit only — no Python sidecars, no Node bridges, no Electron, no JavaScript runtimes, in MVP. (pyannote sidecar in v2+ is the deliberate exception.)
- **NFR-M2 [MVP]:** Pipeline stages are isolated as separate `auricle <stage>` subprocess invocations to support crash isolation, terminal-debugging, and re-running individual stages.
- **NFR-M3 [MVP]:** Each pipeline stage produces structured logs to the unified logging system under subsystem `com.auricle.app` with a category matching the stage name. Logs inspectable via `log show --predicate 'subsystem == "com.auricle.app"'`.
- **NFR-M4 [MVP]:** auricle has unit tests for: schema validation, frontmatter rendering, quote-grounding grep validation, vault-glossary extraction, filename collision avoidance, retention timer arithmetic.
- **NFR-M5 [MVP]:** auricle has at least one end-to-end smoke test using a checked-in reference WAV file, a stub summarization, and a vault-write to a temp directory. CI-runnable.
- **NFR-M6 [MVP]:** Configuration changes (vault path, retention, summarization engine) take effect on next pipeline invocation, without requiring app restart.
- **NFR-M7 [MVP]:** auricle release builds are reproducible: same git SHA + same toolchain → identical signed `.app`. Release script is checked in.
- **NFR-M8 [MVP]:** All non-trivial design decisions in the codebase are anchored to specific PRD or brainstorm sections via brief code comments where the *why* is non-obvious — for navigational purposes.

#### Cost (NFR-C1–NFR-C4)

- **NFR-C1 [MVP]:** Per-meeting variable cost ceilings by configuration tier: ≤ $0.50 default (jargon correction inline; no diarization review), ≤ $0.60 when `diarization_review.enabled = true`, targeted ≤ $0.70 in v1.x with `transcription_review.enabled = true`, $0 on local-LLM path (FR33). All ceilings assume a 30-minute meeting with attendee context and vault glossary, default model (`claude-opus-5` summarize at `medium` effort, `claude-haiku-4-5` reviewers), prompt caching enabled.
- **NFR-C2 [v1.1]:** Per-meeting variable cost reduces to ≤ $0.05 for a 30-minute meeting via prompt optimization (caching system instructions, scoping glossary tighter).
- **NFR-C3 [v1.1+]:** Per-meeting cost reduces to $0 when local-LLM summarization path is configured.
- **NFR-C4 [MVP]:** Total fixed cost: $0. Distribution uses a self-managed code-signing certificate, trusted on each user Mac via `spctl` assessment policy — no Apple Developer Program subscription required. No subscription dependencies, no SaaS components.

### Additional Requirements

#### Project Initialization & Starter Template

- **AR-INIT-1:** Hybrid SwiftPM library + Tuist-generated Xcode app project structure. Library targets in `Sources/` declared in `Package.swift`. The Xcode project at `App/Auricle.xcodeproj` is GENERATED from `Project.swift` by `tuist generate` and is gitignored, never committed; it produces both the GUI binary (`AuricleApp`, product `.app`) and the CLI binary (`auricle-cli`, product `.commandLineTool`), each depending on the root SwiftPM package declared as `.local(path: ".")` and linked per-product via `.package(product:)`. SwiftPM target boundaries enforce SOLID at build-system level (cross-target imports rejected).
- **AR-INIT-2:** External SwiftPM dependencies declared in `Package.swift`: WhisperKit, GRDB.swift, swift-argument-parser, TOMLKit (config), Sparkle (v1.1, deferred).
- **AR-INIT-3:** Build configuration lives in plain-text files, never in the Xcode GUI (AR-PAT-11). `config/Shared.xcconfig` carries `ENABLE_HARDENED_RUNTIME=YES`, `MACOSX_DEPLOYMENT_TARGET=14.0`, `ARCHS=arm64`, `PRODUCT_BUNDLE_IDENTIFIER=com.auricle.app`, `CODE_SIGN_ENTITLEMENTS`; the App Sandbox key is absent entirely. `App/Auricle/Info.plist` (committed, hand-edited) carries `LSUIElement=NO`, the NS*UsageDescription strings (per Decision 4.4), and CFBundleURLTypes for the `auricle://` scheme. `App/Auricle/Auricle.entitlements` (committed) carries `com.apple.security.device.audio-input`. `Project.swift` references these by path — `infoPlist: .file(path:)`, `entitlements: .file(path:)`, and `settings: .settings(configurations: [.debug(name:xcconfig:), .release(name:xcconfig:)], defaultSettings: .none)` so the xcconfigs are authoritative and Tuist injects nothing.
- **AR-INIT-4:** CI (`.github/workflows/ci.yml`) runs `mise install`, `swift build`, `swift test`, `tuist generate --no-open`, `xcodebuild build` for both schemes, `swiftformat --lint`, `swiftlint`. CI additionally asserts `App/Auricle.xcodeproj` is NOT tracked by git (`git ls-files --error-unmatch` must fail) — a committed generated project is a regression of AR-INIT-1. Release workflow (`release.yml`) runs `mise install` + `tuist generate` + `xcodebuild archive` + `codesign` + (v1.1) Sparkle appcast generation.
- **AR-INIT-5:** SwiftPM target list comprises: `Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`, `Capture`, `TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`, `Transcribe`, `Diarize`, `Attribute`, `Summarize`, `ClaudeSummarizer`, `ClaudeAIReviewers`, `ReviewDiarization`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`, `VaultGlossary`, `Persist`, `Verify`, `Notifications`, plus matching `<Target>Tests` test targets and `TestSupport`.
- **AR-INIT-6:** Developer toolchain is declared and version-pinned in `mise.toml` (Tuist, SwiftFormat, SwiftLint). `mise install` reproduces the exact toolchain on a fresh Mac and in CI; version drift would break NFR-M7's byte-identical-rebuild guarantee. Tuist is used as the open-source CLI only — the hosted Tuist cache/server tier is NOT adopted (NFR-C4: total fixed cost $0).
- **AR-INIT-7:** `Package.swift` declares `swift-tools-version: 6.3` (matching the Xcode 26.4.1 / `mise.toml`-pinned toolchain), putting every target under Swift 6 language mode with strict concurrency checking by default. Adopted at Story 1.1's scaffold — before `Sources/` holds anything but placeholder files — because retrofitting strict concurrency onto code written under Swift 5 assumptions is expensive, and adopting it now, while there is no code to retrofit, is not. Verified: `swift build` succeeds cleanly across all 25 library targets and their dependencies under this tools-version.

#### Distribution & Trust

- **AR-DIST-1:** Self-managed code-signing CA + per-Mac `spctl` trust policy. Personal "Auricle Root CA" + "Auricle Code Signing" leaf cert; CA `.cer` checked in at `assets/auricle-root-ca.cer`; private keys remain on originating Mac only.
- **AR-DIST-2:** `scripts/setup-trust.sh` (idempotent) imports CA cert as trusted root in System.keychain, computes SHA-256 fingerprint, registers Gatekeeper assessment policy via `spctl --add --requirement 'anchor H"<ca-hash>"'`. Run once per user Mac at first install.
- **AR-DIST-3:** Bundle layout: `Auricle.app/Contents/MacOS/` contains both the `Auricle` GUI binary and the `auricle-cli` CLI binary. GUI spawns CLI subprocesses via `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")`. CLI is also installable on `$PATH` via separate copy.
- **AR-DIST-4:** Stable bundle identifier `com.auricle.app` and signing identity preserve TCC permission grants across rebuilds and Sparkle updates.

#### Pipeline Orchestration Contracts (Decision Group 1)

- **AR-PIPE-1:** Subprocess vs in-process boundary per stage: `transcribe`+`diarize` (combined), `summarize`, `reviewing_diarization` run as subprocesses spawned by the GUI (and independently by CLI). `capture`, `attribute`, `persist`, `notify`, `verify`, `discard` run in-process. CLI exposes every stage as an independently-runnable subprocess regardless of GUI dispatch.
- **AR-PIPE-2:** Canonical pipeline state names (persisted as strings in SQLite): `recording → captured → transcribing → reviewing_diarization → awaiting_attribution → attributing → summarizing → persisting → published → awaiting_verification → verified → retention_expired`. Plus terminal/error branches: `silent`, `discarded`, `capture_failed`, `transcription_failed`, `summarization_failed`, `persist_failed`, `published_partial`.
- **AR-PIPE-3:** Two-transaction pattern per stage: Txn A (`stage_events.started` + `meetings.state = '<active>'`) then Txn B (`stage_events.completed|failed` + `meetings.state = '<target>'`). The active "_ing" state is the canonical reconciliation signal for crash recovery (no separate sweep table). Crash recovery on launch re-dispatches stages stuck in active states.
- **AR-PIPE-4:** Cache-dir handoff layout at `~/Library/Caches/com.auricle.app/<meeting-id>/` containing: `audio.wav`, `transcript.json` (immutable), `diarization.json` (immutable), `snippets/speaker_N.wav`, `diarization_suggestions.json`, `transcription_suggestions.json` (declared, no MVP impl), `attribution.json` (with `segment_overrides` + `segment_splits` per Decision 5.4), `calendar.json`, `glossary.json`, `summary.json`, `state.json`. Every JSON file carries a top-level `schema_version` field. All writes via atomic-write primitive. Permissions 0600. Cache-dir is the IPC mechanism (no shared memory, no message queue).
- **AR-PIPE-5:** Audio file format: PCM 16-bit, 16kHz mono WAV. Mic + system audio mixed during capture into one mono stream.
- **AR-PIPE-6:** CLI binding contract (NFR-I7) with 10 MVP verbs: `record`, `stop`, `discard`, `run` (with `--from`/`--to`/`--only`/`--force`/`--reattribute`/`--publish-anyway`), `attribute` (interactive default), `keep`, `list`, `status`, `config get|set`, `doctor`. Bare `auricle` returns status (not help). v1.1 additions: `pending`, `retain`, `attribute --emit-snippets`/`--speakers`, `doctor --fix`, `logs`, completion-script generation. ID resolution via shared `MeetingIDResolver` (full ULID, ULID prefix ≥6 chars, `current`, `last`).
- **AR-PIPE-7:** Hidden `auricle-cli __internal-stage <stage> <id> --worker-protocol-version <N>` subcommand for GUI-spawned subprocess work; NOT part of NFR-I7 binding contract; `shouldDisplay: false`; independently versioned.
- **AR-PIPE-8:** CLI output conventions: human stdout/stderr in plain text with TTY-aware ANSI color, `--json` opt-in (never auto-detected), schemaVersion-stamped JSON responses, `--quiet` flag for action verbs, exit codes 0/1/2/3 (success/user error/state error/not found).

#### Persistence & Data Contracts (Decision Group 2)

- **AR-DATA-1:** Single SQLite database at `~/Library/Application Support/com.auricle.app/auricle.sqlite3` accessed via GRDB.swift; WAL mode enabled in migration #1. Five tables: `schema_version`, `meetings`, `stage_events`, `retention_timers`, `telemetry`. `meetings.id` is a 26-char ULID (Crockford base32). All timestamps ISO8601 UTC with `Z` suffix.
- **AR-DATA-2:** GRDB concurrency: GUI uses `DatabasePool`; subprocesses use `DatabaseQueue`. WAL persistence sticky in file header. Cross-process safety via WAL + POSIX advisory locks. `Configuration.busyMode = .timeout(5.0)`. `PRAGMA foreign_keys = ON`. GUI runs `PRAGMA wal_checkpoint(TRUNCATE)` on app quit; between quits SQLite's automatic checkpoint bounds the WAL. Subprocesses issue no explicit checkpoint.
- **AR-DATA-3:** Reactive observation: `GRDB.ValueObservation` is in-process only — does not see external writes. GUI must use file-watch (`DispatchSource.makeFileSystemObjectSource` on `db.sqlite3-wal`, 100ms debounce) for cross-process observation.
- **AR-DATA-4:** Write-authority matrix per Decision 2.1 — every column has exactly one writer (GUI capture stage / subprocess executing the stage / GUI verify stage / GUI retention scheduler / Reviewer subprocess / GUI Attribute stage). Telemetry UPSERT writers are partitioned: subprocess writes count/cost/model; GUI writes applied/rejected. No column has two writers.
- **AR-DATA-5:** Migrations via `GRDB.DatabaseMigrator` — forward-only, identified by string ID, never reordered or removed. Schema version bumps only when a table structure changes.
- **AR-DATA-6:** Frontmatter schema (`auricle.schema_version: 1`) carries title, date, tags (`auricle/meeting`, optionally `auricle/needs-attribution`, `auricle/needs-calendar-enrichment`, `auricle/needs-summary`), attendees as `[[wikilinks]]`, and an `auricle:` block with `meeting_id` (ULID) and `schema_version`. Speakers in body text are wikilinks; quote-grounded items render as `> source quote` blockquotes. Frontmatter never duplicates SQLite content (cross-cutting concern #11). `auricle.supersedes` is added on re-publish.
- **AR-DATA-7:** Re-publish semantics: writes a sibling file with `--rerun-<YYYY-MM-DD>[-N]` suffix; original is preserved untouched; both notes carry frontmatter linkage via `auricle.supersedes`. SQLite's `meetings.vault_note_path` reflects the most recent publish. Retention timer is preserved on re-publish (re-attribution is content fix, not re-verification).
- **AR-DATA-8:** Filename convention: `<YYYY-MM-DD>-<slug>.md` where date is local-timezone capture date and slug is derived via priority chain (calendar event title → `with-<attendee-1>[-and-<attendee-2>]` → `meeting-at-<HHMM>`). Slug normalization: NFKD → strip non-ASCII → lowercase → kebab → 60-char cap at hyphen boundary. Same-Mac collisions append `-2`/`-3` ordinal counter. Cross-Mac collisions accepted as low-probability, manually recoverable.
- **AR-DATA-9:** Vault path config split into two keys: `vault_path` (default `~/checkouts/SecondBrain`) and `meetings_subdir` (default `Meetings`). `vault_path` must exist and be writable (auricle does NOT auto-create). `meetings_subdir` auto-created on first publish.

#### Summarization Contracts (Decision Group 3)

- **AR-SUM-1:** `SummarizerStrategy` protocol with normalized output `SummaryWithGrounding` (containing `summary`, `actionItems`, `decisions`, `groundingMethod`, `cost`). All grounding pointers normalized to `GroundingPointer { transcriptStart, transcriptEnd, sourceMethod }` at validator boundary. Renderer reads `transcript[start..<end]` regardless of source strategy.
- **AR-SUM-2:** Two MVP grounding strategies: `ClaudeSubstringSummarizer` (the default per the Decision 3.6 outcome, and the v1.1+ local-LLM path) and `ClaudeCitationsSummarizer` (Citations API on `claude-opus-5`; built and tested, not wired as a primary or a fallback). Both share a single `SummarizationPromptBuilder` (snapshot tests fail build on prompt drift between strategies).
- **AR-SUM-3:** `SummarizerOrchestrator` mediates fallback (NOT in-strategy retry). Fallback triggers on typed errors (`citationsUnavailable`, `malformedResponse`, `rateLimited`, `featureToggleDisabled`); bounded to one attempt; NFR-C1 cost ceiling applies across primary + fallback.
- **AR-SUM-4:** Canonicalization invariant — exactly ONE canonical transcript representation: NFC-normalized Unicode, LF line endings, no leading/trailing whitespace per line, speaker labels prefixed `<Speaker_N>: `. Character offsets are UTF-8 byte offsets into that representation, **an internal convention with no external contract**: the Citations path submits a custom content document (one block per utterance) and receives `content_block_location` block indices, so no character index crosses the API boundary. Build-time contract test (`tests/CanonicalTranscriptContractTests.swift`) asserts round-trip stability, that block index *N* maps to a stable `[start, end)` range under the same segmentation, and that the substring validator resolves into that space; cross-mode fixture tests (golden transcripts through both strategies producing byte-identical renderer output) fail the build on violation.
- **AR-SUM-5:** Anthropic prompt caching: system prompt + glossary + attendee context use `cache_control` blocks; transcript is never cached (unique per meeting). Smoke-test protocol (Story N hour 1, runs before dogfood): both strategies on ≥5 real captured meetings (≥1 1:1, ≥1 multi-party); default flips to substring if substring catches anything Citations missed. Smoke-test results recorded at `Tests/fixtures/strategy-comparison-results.md`.
- **AR-SUM-6:** Trust-calibration surfaces (preserving DP2 — no confidence flags in vault): `auricle status <id>` (MVP) shows `grounding_method`, total items, drop count, and a copy-pasteable `log show` invocation. `auricle logs <id> --stage summarize` (v1.1) and `auricle stats` (v1.1+) build on the same `telemetry` columns.

#### Failure / Recovery / Security (Decision Group 4)

- **AR-FAIL-1:** Four failure categories: `transient` (auto-retry with budget + Stop-Trying affordance), `permanent` (mark `*_failed`, surface to user, no auto-retry), `userActionable` (mark `awaiting_*`, no auto-retry, user resumes), `benignTerminal` (correct detection of "nothing to do" — `silent`, future similar). `enum FailureCategory` is a property derived from canonical state name.
- **AR-FAIL-2:** Per-stage retry/backoff policy per Decision 4.2: capture (best-effort stream restart, 3 fails in 30s); transcribe (1 retry after fresh subprocess restart); summarize (exponential backoff 1→2→4→8→16s, 5min total budget); persist (1 retry after 1s); notify (1 retry, non-blocking failure). Wall-clock stale-detection: `transcribing` 2× NFR-P3 budget; `reviewing_diarization` **90s fixed** (synthesizes empty-stub passthrough, not failure); `summarizing` 2× NFR-P5 budget; `persisting` 60s fixed; `published` 30s. Orchestrator periodic sweep (every 10s foreground, 60s backgrounded) calls `StageRunner.synthesizeFailure(...)`.
- **AR-FAIL-3:** User agency on retries: GUI inline "Retry N of M — next attempt in Xs [Stop trying]"; CLI `Ctrl-C` (SIGINT) cancels retries (exit code 130). Subprocess token billing risk on crash logged in telemetry.
- **AR-FAIL-4:** `Verifier` Swift `actor` is the single converge point for all verification callers (notification-click, GUI confirm, `auricle keep`). Idempotent SQL via `COALESCE`; `UNIQUE(meeting_id)` constraint on `retention_timers`. Both writes (open Obsidian + arm timer) happen regardless of whether Obsidian launches successfully.
- **AR-FAIL-5:** Notification payload format (binding contract surviving Sparkle upgrades): `{meeting_id, schema_version, payload_version}`. Click handler tolerates unknown `payload_version` from future binary by falling back to "lookup meeting by ID, present in main window."
- **AR-FAIL-6:** Permission detection points: app launch (all four categories — System Audio Recording, Microphone, Notifications, Calendar OAuth; System Audio Recording always reads as unknown because macOS has no public check); before capture (Microphone); before notify; mid-capture (revocation event saves partial audio + `capture_failed` with reason `permission_revoked_midstream`). Info.plist usage descriptions in user voice (not boilerplate).
- **AR-FAIL-7:** Failure-visibility surfaces (Decision 4.6) — single window architecture: per-meeting state chip in main-window meeting list, row-expand inline operations console, Attribution sheet with sheet queue, on-launch banner, multi-meeting attribution banner, inline "Retry now" button per failed-state row, `auricle doctor` summary, `auricle list` default sort, trust-calibration footer, rolling 30-day cost widget, stale-active-state synthesized failure. v1.1 adds Dock badge, menu bar status, `auricle stats`. The principle: user can never discover a meeting was lost only by accidentally noticing it.

#### AI-Assisted Correction (Decision Group 5)

- **AR-AI-1:** `AIReviewerStrategy` protocol family with three sibling concrete protocols: `DiarizationReviewerStrategy` (Phase 1 MVP — concrete `ClaudeDiarizationReviewer` Haiku-default, flag-controlled), `TranscriptionReviewerStrategy` (Phase 3 v1.x — declared, no MVP impl), `JargonCorrectionStrategy` (Phase 1 MVP — wraps existing `GlossaryInjector`).
- **AR-AI-2:** `ClaudeDiarizationReviewer` MVP impl: `claude-haiku-4-5` model (configurable via `diarization_review.model`), `diarization_review.enabled` flag (default `false` per Path C). When off, stage short-circuits in <100ms with empty stub artifact + telemetry payload `{model_id: "flag_off", cost_usd: 0, suggestions_count: 0, review_skipped: true}`. Prompt skeleton uses `cache_control` for stable system prompt; per-meeting transcript+diarization is variable. Shares `AnthropicHTTPClient` + `KeychainAPIKey` with `ClaudeSummarizer`. One-shot (not streaming) at MVP.
- **AR-AI-3:** `reviewing_diarization` runs in a dedicated subprocess spawned by Orchestrator AFTER WhisperKit subprocess terminates (frees ~2–4GB before the network call). Bundled invocation: `auricle-cli __internal-stage review-diarization <id> --worker-protocol-version 1`. Three independent failure modes (WhisperKit OOM / Anthropic network / malformed Claude response) get clean isolation.
- **AR-AI-4:** Cache-artifact immutability invariant: `transcript.json` and `diarization.json` are **immutable** post-write. AI corrections never modify these files. AI proposals live in `diarization_suggestions.json` (read-only, written once). User-applied corrections live in `attribution.json` `segment_overrides` + `segment_splits` fields. Renderer composes `(diarization, overrides, splits) → RenderedTranscript` as a pure function (idempotent, golden-fixture tested). Build-time test (`Tests/AIReviewerInterfaceTests/ImmutabilityContractTests.swift`) asserts no reviewer/stage code path opens immutable artifacts for write.
- **AR-AI-5:** Subprocess → GUI handoff contract (race-free): subprocess writes `diarization_suggestions.json` via `AtomicWriter`, then in same Txn B bumps `meetings.updated_at` and transitions state. SQLite write is the authoritative "ready" signal; file existence is secondary. GUI sheet's view model `init` runs check-then-watch sequence: read `meetings.state` for guarantee, render "🤖 analyzing…" if still in `reviewing_diarization`, watch via two independent watchers (Watcher A: `DispatchSource` on cache-dir suggestions file, 100ms debounce; Watcher B: `GRDB.ValueObservation` on `meetings WHERE id=?`).
- **AR-AI-6:** `attribution.json` schema extension (additive — existing readers ignore unknown fields): `speakers` (Speaker_N → wikilink), `segment_overrides[]` (per-paragraph reassign, `applied_from: 'manual'`), `segment_splits[]` (AI-applied splits with `original_segment_id`, `suggestion_id`, `applied_from`, `splits[]`). Atomic-write via `AtomicWriter` debounced 500ms in `AttributionViewModel`. Cancellation preservation: dismiss handler awaits in-flight write Task.
- **AR-AI-7:** Phased roadmap (Path C): Phase 1 MVP — jargon live, diarization slots present + flag default-off, transcription slots declared. Phase 2 v1.1 — flip diarization flag on after smoke-test (≥5 real meetings, applied/suggestions ≥40% over 4 weeks AND false-positive rate <20%). Phase 3 v1.x — implement `ClaudeTranscriptionReviewer`. Phase 4 v1.x+ — unified single-call reviewer producing all three correction types.
- **AR-AI-8:** Pre-committed kill criteria + trust calibration (Decision 5.7): `applied_count / suggestions_count < 0.40` over 4 rolling weeks → flag for review. `suggestions_count == 0` → `accept_rate = nil` and `kill_criterion_status = .insufficientSignal` (NOT pass). Auto-collapse trigger requires `suggestions_count > 0 AND applied_count / suggestions_count < 0.40`. Cmd-Z within session + persistent "Revert this split" affordance across sheet reopens.
- **AR-AI-9:** AI-correction wedge validation (cross-cutting with PRD §Business Success): MVP measurement is ≥40% of meetings show ≥1 applied jargon correction over 30-day rolling window — computable post-hoc from cache-dir `summary.json` + `transcript.json` + `glossary.json` (no new telemetry column needed).

#### Implementation Patterns & Cross-Cutting Concerns

- **AR-PAT-1:** Naming conventions — Swift code: PascalCase types, camelCase functions/properties, no SCREAMING_SNAKE_CASE, no `-able` protocol suffix. Files: one primary type per file, filename matches type. SwiftPM targets: PascalCase, named for concern; `<Concern>Interface` for protocol-only targets, `<Vendor><Concern>` for concrete strategies. Tests: `<TypeUnderTest>Tests.swift`. Non-Swift files: kebab-case.
- **AR-PAT-2:** JSON dialect rule — snake_case for cache artifacts, frontmatter `auricle:` block, `stage_events.metadata_json`, notification `userInfo` payload; camelCase for `auricle <verb> --json` responses and structured error JSON. Codable types for cache/frontmatter/notification declare `enum CodingKeys: String, CodingKey` to map snake_case JSON to camelCase Swift properties. Round-trip tests required for every JSON-shaped contract type.
- **AR-PAT-3:** Logging — single subsystem `com.auricle.app`; lowercase category per stage/module (`capture`, `transcribe`, `attribute`, `summarize`, `persist`, `notify`, `verify`, `discard`, `orchestrator`, `state`, `telemetry`, `permissions`, `vault-glossary`, `verifier`). One `Log` instance per file at file top. Sensitivity tagging at every call site (`.publicSafe(...)` / `.sensitive(...)`). Default to `publicSafe` is a code-review reject; default to `sensitive` permissible. API keys, OAuth tokens, transcript content, attendee emails, Anthropic response bodies NEVER passed to `Log` facade.
- **AR-PAT-4:** Single-implementation primitives owned by exactly one target (bypass = code-review reject + lint detection): `AtomicWriter` (Core), `VaultWriter` (Persist), `CacheArtifactWriter` (Core), `Verifier` actor (Verify), `Log` facade (Core), `Telemetry.record(...)` (Telemetry), `StageEventLogger.record(...)` (Telemetry), `StageRunner.run { ... }` (Orchestrator), `PermissionChecker` (Permissions), `MeetingIDResolver` (Core).
- **AR-PAT-5:** Composition roots — exactly one per binary: GUI at `App/Auricle/AuricleApp.swift`, CLI at `App/auricle-cli/main.swift`, tests at `Tests/TestSupport/TestComposition.swift`. Concrete strategies (`ClaudeCitationsSummarizer`, `WhisperKitTranscriber`, `GoogleCalendarSource`, etc.) instantiated only inside composition roots. Direct strategy instantiation outside composition root is a code-review reject (the mechanical version of DIP).
- **AR-PAT-6:** Concurrency discipline — `async`/`await` everywhere; no completion-handler callbacks for new code; `actor` for any mutable shared state; `@MainActor` for SwiftUI/AppKit-touching layer; backend types not `@MainActor`-bound; no manual locking (`NSLock`/`os_unfair_lock`/`DispatchSemaphore`).
- **AR-PAT-7:** Error discipline — typed Swift `enum`s conforming to `Error`; one enum per error domain (`CaptureError`, `TranscribeError`, `SummarizerError`, `PersistError`, `VerifierError`); `NSError` bridging only at Apple-framework callback boundaries with immediate translation.
- **AR-PAT-8:** Cross-process IPC mechanisms allowed: SQLite writes + cache-dir artifacts. Forbidden: XPC, Mach ports, named pipes, shared memory, pasteboard, distributed objects. Subprocess invocations use `Foundation.Process` with structured stdout JSON / stderr text-or-JSON-error.
- **AR-PAT-9:** Markdown output discipline — frontmatter under `---` fences (YAML, exact Decision 2.2 schema); `## ` only for sections (filename owns the document title); never beyond `### `; wikilinks `[[Display Name]]` for people/projects/concepts; verbatim quotes `> ` blockquote; no emoji, no horizontal rules outside frontmatter, no tables; UTF-8 with LF line endings, single trailing newline.
- **AR-PAT-10:** Pattern enforcement layers: build-time SwiftPM target boundaries, lint-time naming/layout/helper-bypass detection in `.swiftformat`/`.swiftlint.yml`, CI-time JSON contract round-trip tests + `SummarizationPromptBuilder` snapshot tests + canonicalization invariant tests + cross-mode fixture tests + GRDB migration round-trip tests, code-review checklist for human-only enforcement.
- **AR-PAT-11:** No GUI-required development tasks. Every step that produces, configures, signs, or releases a build must be executable from a non-interactive shell. Xcode, Keychain Access, and System Settings may be *used* by preference — they must never be *required*. A plan step whose only documented path is a GUI navigation sequence is a planning defect. Enforcement: CI runs the full build-and-sign path headlessly; a step CI cannot run is a step that does not exist. This governs developer tasks only — end-user GUI affordances (System Settings permission remediation per FR6/FR60, Keychain Access as the API-key reveal path, manual frontmatter edits in Obsidian per FR26) are product behavior and are unaffected.

### UX Design Requirements

#### Window Architecture & IA

- **UX-DR1 [MVP]:** Single workflow window architecture (Principle 8). auricle's primary surface is a single main window. Modal workflow tasks (notably speaker attribution) appear as **sheets attached to the main window** — never as separate `NSWindowController`-per-meeting windows that auto-foreground. Multi-meeting concurrency handled via sheet queue + banner counter. Settings (Cmd-,) and Doctor remain as conventional separate windows since user-initiated and rarely used.
- **UX-DR2 [MVP]:** Row-expand inline IA for the main meeting list (Variant 1). `LazyVStack` of `MeetingRowView` cells; each row has `@State expanded: Bool` toggling a per-row inline operations console showing pipeline timeline, contextual actions (Retry / Discard / Open attribution), retention countdown, and copy-pasteable `log show` line.
- **UX-DR3 [MVP]:** Meeting list sort priority: `recording > awaiting_attribution > awaiting_verification > *_failed (transient before permanent) > transcribing|reviewing_diarization|summarizing|persisting > published > verified > retention_expired > silent|discarded`, then by `capture_started_at desc`. Bottom filters: `[Show verified · Show discarded]` toggle chips (defaults: verified on, terminal off).
- **UX-DR4 [MVP]:** Window sizing — Main window: resizable, `@SceneStorage`-persisted, default 800×600, minimum ~700×500. Attribution sheet: ~600×700 content-fit, non-resizable per macOS sheet conventions, minimum 540×500. Settings: macOS Settings scene system-driven. Doctor: fixed narrow column ~480×fitToContent.

#### Design System & Tokens

- **UX-DR5 [MVP]:** Apple HIG-native + thin semantic-token layer. SwiftUI standard controls (Button, TextField, List, LazyVStack, Form, Section, LabeledContent, sheet, confirmationDialog), Apple text styles (`.title`/`.body`/`.caption`/etc.), system semantic colors (auto Dark/Light/Increased-Contrast), 8pt grid spacing with 4pt sub-unit, SF Symbols only.
- **UX-DR6 [MVP]:** `DesignTokens.swift` in `Sources/Core/` holds three earned project-specific token groups: state-chip palette (8 variants mapped to FailureCategory: recording / active / success / awaiting / retryable / permanent / benign / partial), recording indicator (privacy-contract surface), calendar-attendee marker (`person.crop.circle.badge.checkmark` + accent tint). All colors via semantic tokens; no hardcoded RGB anywhere.
- **UX-DR7 [MVP]:** Typography: SwiftUI text style API exclusively. `.headline` for window/row titles, `.subheadline` (`.semibold`) for section headers, `.body` for speaker names + autocomplete + status, `.caption` (`.monospacedDigit`) for timestamps + counters, `.footnote` for coverage strip + progress lines. Code/CLI samples within GUI use `.system(.body, design: .monospaced)`. Monospaced digits via `.monospacedDigit()` modifier where values mutate.
- **UX-DR8 [MVP]:** Iconography mapping (SF Symbols only): recording active `record.circle.fill` (filled red, pulsing), recording idle `record.circle`, play/pause `play.circle`/`pause.circle`, "this is me" / calendar attendee `person.crop.circle.badge.checkmark`, verified `checkmark.circle.fill`, awaiting `hand.point.up.left.fill`, retryable `arrow.clockwise.circle`, permanent failure `exclamationmark.triangle.fill`, silent `circle.dashed`, discarded `trash`, published partial `hand.point.up.left` + `exclamationmark` overlay, variance warning `exclamationmark.triangle.fill` (small).

#### Atomic Components

- **UX-DR9 [MVP]:** `RecordingIndicator` atomic component — privacy contract surface. Active state filled red with gentle pulse 1.0→0.7→1.0 alpha over 1.4s ease-in-out; Reduce Motion: filled red, no pulse. Idle state outlined `record.circle`, secondary color. Always paired with text "Recording" — color never alone. Lives in `Sources/Core/UI/` (or App design-system layer).
- **UX-DR10 [MVP]:** `StateChip` atomic component — per-meeting state visibility with 8 variants mapped to FailureCategory. Each variant carries color + glyph + label per NFR-A3. `accessibilityLabel` per variant ("Awaiting your attribution", "Retry needed", etc.).
- **UX-DR11 [MVP]:** `VarianceWarningGlyph` atomic component — acoustic diarization uncertainty hint (`⚠ may be 2 voices`). States: present / absent. Tooltip + descriptive accessibility label.
- **UX-DR12 [MVP]:** `AIHintChip` atomic component — 🤖 indicator for AI-suggested corrections. States: collapsed (chip only) / expanded (reasoning + Apply/Reject controls) / auto-collapsed when accept rate < 40%. Collapsed-state `accessibilityLabel` summarizes hint count + kind ("AI hint: may be 2 voices"). Expanded-state full reasoning text + Apply/Reject buttons screen-reader navigable. Color never sole conveyor — chip carries 🤖 glyph + label (NFR-A3).
- **UX-DR13 [MVP]:** `CalendarAttendeeBadge` atomic component — calendar attendee in coverage strip / autocomplete. States: matched (green check), unmatched (`•unmatched` annotation), candidate (default badge). `accessibilityLabel`: "From this meeting's calendar invite."
- **UX-DR14 [MVP]:** `SnippetPlayer` atomic component — per-speaker representative audio clip playback. States: idle (`▶`), playing (`⏸` + animated waveform), error (inline message). Uses pre-loaded `AVAudioPCMBuffer` per speaker (~5MB total for 7 speakers); warmed on sheet appear. Spacebar plays focused snippet (NFR-A2); ≤200ms cold playback (NFR-P7).
- **UX-DR15 [MVP]:** `WaveformView` atomic component — pre-computed amplitude envelope render. Static (default) / animating progress (during playback). `Sources/Diarize/SnippetExtractor.swift` extended to write `snippets/speaker_N.envelope` (Float32 array, ~200 samples) for waveform pre-render.
- **UX-DR16 [MVP]:** `ParagraphPlayButton` atomic component — audio scrubbing per transcript paragraph. Idle / playing. Uses **shared `AVAudioFile` + seek** (NOT pre-loaded PCMBuffers — would blow NFR-P9 memory budget). Single file handle, `framePosition` per play. Cold seek <20ms on SSD. Spacebar plays focused paragraph.
- **UX-DR17 [MVP]:** `CountdownAnnotation` atomic component — retention countdown ("Audio deletes in 5 days"). States: counting (N > 0) / indefinite ("Audio kept (indefinite)") / expired ("Audio deleted"). Plain-text countdown reads as natural sentence to VoiceOver.
- **UX-DR18 [MVP]:** `TrustCalibrationFooter` atomic component — accept-rate display in Attribution sheet. States: hidden (no data / AI flag off) / visible ("🤖 Reviewed N segments, flagged M · Accept rate: X/Y this week"). When `suggestions_count == 0`, footer reads "🤖 Reviewed N segments, flagged 0" (explicit absence replaces silent absence).
- **UX-DR19 [MVP]:** `CoverageStrip` atomic component — calendar attendee gap-awareness diagnostic. States: all matched / partial / none matched / no calendar context. Each badge has its own accessibility label per state.
- **UX-DR20 [MVP]:** `PipelineTimelineView` atomic component — mini visualization of pipeline progress in row-expand operations console. Per-stage: pending / active / completed / failed / skipped. Stage labels screen-readable; current stage announced.
- **UX-DR21 [MVP]:** `ThisIsMeButton` atomic component — `.bordered` style; states: idle / active (✓ when row maps to `self.wikilink`) / disabled ("Set me first…" linking to Settings when self.wikilink not configured); first-run subtle attention-pulse on focused row when zero speakers attributed, gated by Reduce Motion (NFR-A5 — no pulse, only color-state).

#### Composite Views

- **UX-DR22 [MVP]:** `MainWindowView` composite view at `App/Auricle/MainWindow/MainWindowView.swift` — top-level container with header (Record button + RecordingIndicator + settings/help), `UpcomingEventStripView`, `OnLaunchBannerView`, `MeetingListView`, sheet presenter (`.sheet(item: $attributingMeetingID)`), `RollingCostFooterView`. Owns `@SceneStorage` window size, `@State` filter visibility, `@State attributingMeetingID: MeetingID?`.
- **UX-DR23 [MVP]:** `MeetingListView` + `MeetingRowView` — `LazyVStack` of `MeetingRowView` cells with collapsed/expanded states. Collapsed shows StateChip + title + duration + state-annotation + chevron. Expanded shows `OperationsConsoleView` inline below.
- **UX-DR24 [MVP]:** `OperationsConsoleView` composite view — row-expand inline content showing `PipelineTimelineView` (per-stage glyph for capture / transcribe / review-diarization / attribute / summarize / persist), contextual action buttons (Retry / Discard / Open attribution / Keep audio indefinitely), retention countdown via `CountdownAnnotation`, copy-pasteable `log show` line.
- **UX-DR25 [MVP]:** `OnLaunchBannerView` composite view — observes `meetings` table for `awaiting_*` and `*_failed` states; serves both as launch banner (when `awaiting_verification` > 24h or any `*_failed` exists) AND as the multi-meeting attribution-queue banner ("⏳ N meetings awaiting your attribution — Attribute next ›"). Click → highlights relevant meetings in main window.
- **UX-DR26 [MVP]:** `UpcomingEventStripView` composite view — calendar-driven upcoming-event sidebar in the main window (e.g., "Pacific quarterly review · in 14 min ›"). Composes `CalendarAttendeeBadge` variants. Observes calendar enrichment cache. Serves J0/J1 priming of the "click Record" decision. Doesn't render when no upcoming events in next ~2h (no empty state needed).
- **UX-DR27 [MVP]:** `RollingCostFooterView` composite view at `App/Auricle/MainWindow/RollingCostFooterView.swift` — small footer line beneath meeting list showing aggregate API cost over rolling 30 days, broken down by stage (`summarize`, `reviewing_diarization`). Two GRDB queries against `telemetry` joined to `meetings`, filtered by `created_at > datetime('now','-30 days')`. Empty-state rendering: "$0.00 spent in last 30 days" (NOT hidden — silence is a signal). Refresh via `GRDB.ValueObservation` on `meetings.updated_at`. Model-swap surprise display (most recent two distinct combos with "→" delimiter).

#### Attribution Sheet (Defining Interaction)

- **UX-DR28 [MVP]:** `AttributionSheet` composite view at `App/Auricle/MainWindow/AttributionSheet.swift` — presented via `.sheet(item: $attributingMeetingID)` from MainWindowView. Replaces former `App/Auricle/AttributionWindow/` separate-window target. Approximate 600×700, content-fit, non-resizable. Hierarchy (Step 10 Round-2 refinement): top calendar coverage strip → dominant middle (speaker rows — visual center of gravity) → subtle disclosure "▸ Review transcript paragraph-by-paragraph (N with hints)" collapsed by default → trust-calibration footer when AI flag on with data → bottom asymmetric button hierarchy. Auto-presented? **No** — user-initiated only via row click, banner action, or notification click.
- **UX-DR29 [MVP]:** `SpeakerRow` composite view — composes `SnippetPlayer`, `WaveformView`, `ThisIsMeButton`, autocomplete `TextField`, status indicator, optional `AIHintChip` for over-segmentation case ("may be Speaker_2 again [Use same name as Speaker_2] [Reject]"). Row tints subtle green when attributed. Heuristic pre-select longest-cumulative-speaking row to `self.wikilink` with `[undo]` affordance.
- **UX-DR30 [MVP]:** `AttributionTranscriptPane` composite view at `App/Auricle/MainWindow/AttributionTranscriptPane.swift` — disclosure-collapsed transcript pane below speaker rows. Composes `TranscriptParagraph` ×N (lazy via LazyVStack), `ParagraphPlayButton`, `AIHintChip` per paragraph. Observes `diarization_suggestions.json` via `DispatchSource` file watch.
- **UX-DR31 [MVP]:** `TranscriptParagraph` composite view — per-paragraph row showing speaker label (with reassign dropdown to other speakers), timestamp, `ParagraphPlayButton`, AI 🤖 chip in gutter. AI chip click expands inline reasoning + per-segment Apply / Reject controls + [Apply all] / [Reject suggestions] batch actions + "Reassign whole paragraph" dropdown. Local `@State` for AI hint expanded.
- **UX-DR32 [MVP]:** Three rename mechanics, complementary: (1) **Default global rename** in speaker rows — type a name in autocomplete, all paragraphs labeled with that Speaker_N update to `[[Name]]`. (2) **Per-paragraph reassign** in transcript pane via dropdown next to paragraph's speaker label — recorded as `segment_override` in `attribution.json`. (3) **AI-assisted splits** for under-segmentation flagged by Claude review — per-suggestion [Apply] commits split, [Apply all]/[Reject suggestions] batch, recorded as `segment_split` in `attribution.json`.
- **UX-DR33 [MVP]:** Autocomplete priority order (FR23): (1) calendar attendees of the current meeting (visually marked via `CalendarAttendeeBadge` with `person.crop.circle.badge.checkmark` glyph + accent tint), (2) existing vault wikilink targets, (3) previously-labeled speakers (with frequency/recency tie-breakers). Recurring-meeting auto-prefill: when ≥3 prior labelings of same calendar attendees, speakers pre-filled via previously-labeled tier. Threshold via `attribution.recurring_meeting_threshold` (default 3).
- **UX-DR34 [MVP]:** Asymmetric bottom-button hierarchy (Sally's Step 10 Round-2 refinement): **[Continue]** primary `.borderedProminent` (enabled when ≥1 speaker attributed), **[Save for later]** secondary `.bordered`, **Publish unattributed (⌘⇧↩)** tertiary text-link smaller off to the side. Continue produces attributed `[[wikilinks]]` + remaining `Speaker_N` (with `auricle/needs-attribution` tag only if any unattributed remain). Publish unattributed uses all `Speaker_N` placeholders + `auricle/needs-attribution` tag. Save for later dismisses sheet preserving partial state via incremental `attribution.json` writes.
- **UX-DR35 [MVP]:** Coverage-diagnostic strip at top of Attribution sheet (`CoverageStrip`) — calendar attendees with status badges (green check matched / `•unmatched` / plain candidate). Bottom progress line: "3 of 4 speakers attributed · 1 calendar attendee not matched."
- **UX-DR36 [MVP]:** Variance warning glyph on rows where `diarization.json` indicates high intra-segment voice-profile variance — non-blocking, does NOT gate Continue; user can play snippet to judge. (No automatic merge in MVP — manual merge is a v1.1 feature.)
- **UX-DR37 [MVP]:** Attribution sheet keyboard flow (NFR-A2): Tab moves focus between rows / transcript paragraphs / bottom buttons; Spacebar plays / pauses focused snippet OR focused transcript paragraph; ↓/↑ in autocomplete navigate suggestions; Enter accepts selected suggestion; Cmd-M applies "This is me" to focused row; Cmd-Z undoes last attribution change (renames, reassigns, applied AI splits); Cmd-Enter Continue (if ≥1 attributed); Cmd-Shift-Enter Publish unattributed; Cmd-W / Esc Save for later (preserves state).
- **UX-DR38 [MVP]:** Attribution sheet performance budgets — sheet load to interactive ≤2s (NFR-P6); snippet playback cold first play ≤200ms (NFR-P7); memory at sheet open ≤200MB (NFR-P9), working target ~98 MB. Performance verified via snapshot test in `Tests/AttributeTests/` opening sheet against 30-min-meeting fixture and asserting `mach_task_basic_info.resident_size < 200 MB`.
- **UX-DR39 [MVP]:** Sheet-level `@Observable AttributionViewModel` owns `attribution.json` + `diarization_suggestions.json` state; per-row `@State expanded: Bool` stays local; scroll position via `@SceneStorage` survives sheet reopen; debounced incremental writes via `Task.debounce` 500ms in view model (NOT per-row `@State` writes).
- **UX-DR40 [MVP]:** Attribution success metrics: 2-speaker 1:1 fully attributed ≤10s (one click confirm pre-selected "me" + one autocomplete); 7-speaker unfamiliar-team meeting fully attributed ≤90s; 7-speaker time-pressed → "Publish unattributed" ≤10s; mouse-free completion 100% (NFR-A2); calendar-attendee marking 100% when enrichment succeeded; recurring meeting auto-pre-filled when ≥3 prior labelings.

#### Onboarding (J0)

- **UX-DR41 [MVP]:** First-launch / permission gauntlet flow (J0 — 4 quick steps): Step 1 Microphone access → Step 2 System Audio Recording (a 1-second capture triggers the prompt; the grant cannot be read back) → Step 3 Notifications access → Step 4 Configure (vault path + Obsidian check + API key; calendar connection lives in Settings). Each step shows a "why" line above the request so the system TCC dialog isn't a surprise. Denied permissions don't terminally block — auricle works with Notifications denied (banner-and-list alternative), Calendar denied (`#auricle/needs-calendar-enrichment` tags), Anthropic key missing. Nothing hard-blocks capture: a denied microphone records system audio only.
- **UX-DR42 [MVP]:** Self wikilink config — set during onboarding, default = system account name (`NSFullUserName()`); a configured value wins over the calendar-derived identity; user-editable in Settings as `self.wikilink`. Required for "This is me" affordance to be active (otherwise button reads "Set me first…" linking to Settings).
- **UX-DR43 [MVP]:** Empty meeting list (J0 fresh install) — centered text: *"Click ⏺ Record to capture your first meeting"*. After onboarding completion, `auricle doctor` runs once silently; result feeds in-window banner only if anything failed.
- **UX-DR44 [MVP]:** Info.plist usage descriptions in user voice (purpose-first, plain voice — Decision 4.4): `NSAudioCaptureUsageDescription` "auricle records your meeting audio so it can transcribe what's said." (a literal Info.plist key; missing, it fails silently); `NSMicrophoneUsageDescription` "auricle captures your voice alongside the meeting so your contributions are in the notes"; `NSUserNotificationsUsageDescription` (where applicable) "auricle pings you when a meeting is ready to review — usually just a click to confirm"; Calendar OAuth consent screen "auricle reads your calendar to title meetings and identify who's in the room."
- **UX-DR45 [MVP]:** TCC remediation deep links, verified on the target macOS by Story 5.1 and recorded in architecture Decision 4.4. Candidates: System Audio Recording → `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture`; Microphone → `…?Privacy_Microphone`. Calendar OAuth re-auth flow opens system browser; on persistent failure, meeting publishes with `auricle/needs-calendar-enrichment` tag (graceful degradation per FR54).

#### Doctor / Settings Surfaces

- **UX-DR46 [MVP]:** `DoctorView` at `App/Auricle/DoctorWindow/DoctorView.swift` — separate window (Principle 8 carve-out), user-initiated via Help menu or banner action. Conversational narrated check format (NOT red/green checklist): per-check status glyph ✓/✗ + label + remediation deep link as `Link` element. Per Decision 4.4: prints `[OK]`/`[FAIL]` plain default, ✓/✗ when stdout TTY in CLI parity. Includes failure / pending counts in summary ("2 meetings are awaiting your verification (oldest: 5 days). Run `auricle list` to see them.").
- **UX-DR47 [MVP]:** `SettingsView` at `App/Auricle/Settings/SettingsView.swift` — macOS Settings scene (Cmd-,), Principle 8 carve-out (separate window). Apple `Form` + `Section` + `LabeledContent` scaffold. Configurable: vault path (`vault_path`, `meetings_subdir`), default audio retention grace window, summarization engine choice (Claude / local), Anthropic API key, Google OAuth account, log verbosity, `diarization_review.enabled`, `diarization_review.model`, `self.wikilink`, `attribution.heuristic_self_preselect`, `attribution.show_coverage_strip`, `attribution.snippet_duration_seconds`, `attribution.max_suggestions`, `attribution.recurring_meeting_threshold`. Auto-saves on field commit (NFR-M6). Secrets shown as `••••••••` with `[Update]` button.
- **UX-DR48 [MVP]:** No custom validation UI — fields validate on edit; errors inline beside field as `.caption` text in `.systemRed`. No save buttons. OAuth re-auth is single button → opens system browser → returns; no in-app credential typing for OAuth flows.

#### Notifications & Verification

- **UX-DR49 [MVP]:** Notification → user-initiated engagement pattern. macOS notifications fire on state changes that need user attention (`awaiting_attribution`, `summary_ready`, `capture_failed`, `awaiting_verification`). **Never auto-foreground** any window or sheet. Click notification → focus main window + sheet rises (or row scrolls into view).
- **UX-DR50 [MVP]:** Notification = verification pattern. Single click on summary-ready notification fires both effects: open note in Obsidian via `obsidian://open?vault=...&file=...` URL scheme AND arm the 7-day audio retention timer. Both writes happen regardless of whether Obsidian launches successfully (FR43+FR44).
- **UX-DR51 [MVP]:** Manual `Verify` affordance for users who opened the note from Obsidian directly — GUI in-window confirm button + `auricle keep <id>` CLI verb both call `Verifier.markVerified` (idempotent). Closes the gap from Decision 4.3 (notification-click as sole verification trigger needs explicit fallback).

#### Failure & Recovery UX

- **UX-DR52 [MVP]:** Failure surfaces are sentence-shaped + action-bearing — pattern: *"<what failed> — <concise cause>. <next action with concrete command>."* CLI: "Couldn't attribute 01HZ7K — no speaker mapping yet. Try `auricle attribute 01HZ7K` to set names." GUI inline: "Summarization failed — Claude API timeout after 5 retries (credits exhausted). [Retry now]" Doctor: "[FAIL] Screen Recording permission · auricle needs this to capture meeting audio. → System Settings > Privacy & Security > Screen Recording". Never stack-trace dumps, red-X horror screens, or modal apology theater.
- **UX-DR53 [MVP]:** Active retry UX — inline progress in row-expand: *"Retry 3 of 5 — next attempt in 4s [Stop trying]"* with inline button. Pressing [Stop trying] cancels in-flight HTTP request, transitions to `summarization_failed` immediately. CLI: SIGINT (Ctrl-C) cancels in-flight retry, exit code 130.
- **UX-DR54 [MVP]:** Stale-active-state synthesized failure — chip flips blue → amber when subprocess goes stale (90s for `reviewing_diarization`, 2× per-stage budget elsewhere); on-launch banner picks it up. **Load-bearing fix for the silent-spinner UX failure mode** — user never sees an "in-flight" chip lying about a dead subprocess for longer than its budget.
- **UX-DR55 [MVP]:** AI review unreachable / malformed — sheet shows acoustic warnings only; non-blocking degradation. AI review pending indicator: `🤖 analyzing...` line at top of transcript pane until suggestions populate. J0 banner when API key missing for AI review: *"Diarization review unavailable — add Anthropic key in Settings to enable."* One-time, dismissable, gentle.

#### Interaction Patterns

- **UX-DR56 [MVP]:** Single inline confirmation pattern (no modal cascade) for destructive-ish actions (Publish unattributed, Discard, Keep indefinitely): button transforms in-place to `[Confirm: <action> ›]` with explanatory micro-copy; second click commits; click-elsewhere or Esc cancels. NEVER a SwiftUI `.alert()` cascade — speed matters for J2.
- **UX-DR57 [MVP]:** Button hierarchy (locked across the app, max one primary per surface): Primary `.borderedProminent` for the action user came to perform ([Continue], [Record]); Secondary `.bordered` for alternative valid action / not destructive ([Save for later], [Stop trying], [Discard], [Open in Obsidian]); Tertiary text-link plain text + accent for escape hatch / less common (Publish unattributed (⌘⇧↩), [undo] per row, [Reject suggestions]).
- **UX-DR58 [MVP]:** Cancellation never destroys — incremental writes mean closing a sheet, quitting the app, or even crashing all preserve state. Resume is `[Retry now]` from row-expand or `auricle run <id>` from CLI — same semantic.
- **UX-DR59 [MVP]:** Undo pattern — Cmd-Z undoes most recent action in focused surface. In Attribution sheet: undoes last speaker rename, per-paragraph reassign, or AI-suggestion application. Backed by SwiftUI `UndoManager`. Per-row `[undo]` affordance: inline undo on heuristic-pre-filled "me" row. "Revert this split" affordance: on previously-applied AI splits, available across sheet reopens. Cmd-Z is session-scoped; closing sheet retains on-disk state but undo stack clears.
- **UX-DR60 [MVP]:** Confident dismissal motion for sheets/windows — `withAnimation(.easeOut(duration: 0.15))` slide-out gated by `@Environment(\.accessibilityReduceMotion)` (NFR-A5) → fade-only fallback. No toasts. No checkmarks. No "Saved!" overlays. State chip flip + counter increment + per-row tint are the feedback.
- **UX-DR61 [MVP]:** No celebration on completion (Step 4 emotional principle: don't ceremony any single moment). No streak counters / gamification (belonging is explicitly NOT optimized for). No skeleton loaders / shimmer effects — loading is explicit and labeled (state chip + monospaced timer).

#### Empty / Loading States

- **UX-DR62 [MVP]:** Empty state copy: empty meeting list (J0 fresh install) shows centered "Click ⏺ Record to capture your first meeting"; no upcoming events in next 2h → strip simply doesn't render; no `awaiting_*` or `*_failed` meetings → failure-visibility banner doesn't render; calendar enrichment offline → strip shows "No calendar context — fix in Obsidian after."; AI review unavailable (no API key) → one-time banner "Diarization review unavailable — add Anthropic key in Settings to enable."; pipeline in-progress → state chip + monospaced timer + row stays visible; AI review running with sheet open → `🤖 analyzing...` line at top of transcript pane; VAD halted (silent meeting, v1.1) → row chip gray + row-expand "VAD detected only 18s of speech in 2h audio" + [Discard] / [Force process].

#### Voice & Copy

- **UX-DR63 [MVP]:** Voice & copy rules — plain English, no jargon in user-facing strings ("Couldn't attribute" not "Attribution failed"). No emoji in functional copy (avoid AI-emoji noise); glyphs (SF Symbols, ⏺ ⏹ 🔴 🤖) are the visual indicators; text is plain. First-name + verb voice in TCC dialogs and notifications. Sentence case for buttons ("Save for later", "Publish unattributed"); title case only for proper nouns and the app name.

#### Accessibility (verifies NFR-A1 through NFR-A6)

- **UX-DR64 [MVP]:** Compliance: WCAG 2.2 AA minimum, AAA where reachable. AA by construction via Apple semantic colors. AAA for body text on `.systemBackground` in both Dark/Light modes. AA for captions on `.tertiaryLabel`. Yellow chip paired with bold-weight label for combined contrast on text-on-yellow.
- **UX-DR65 [MVP]:** Accessibility implementation rules — Always: use Apple text styles, use `DesignTokens`, set `accessibilityLabel` on every interactive control, set `accessibilityHint` where action's effect not obvious, gate motion behind `@Environment(\.accessibilityReduceMotion)` with non-motion alternative, test in Dark/Light every view change, pair every color with glyph + label. Never: hardcode RGB/HSB/hex, use `.font(.system(size:))` outside `DesignTokens`, build animations with no Reduce Motion fallback, use red as only failure differentiator (color-vision violation), skip `accessibilityLabel`, add tooltip-only descriptions for important content.
- **UX-DR66 [MVP]:** Accessibility testing strategy — Snapshot tests CI-runnable per NFR-M5: per-component at multiple text-size settings (compact / default / accessibility-extra-large), in Dark and Light modes, with Increased Contrast on/off, state-chip mapping (every canonical state → expected color token + glyph + label). Snapshot files in `Tests/CoreTests/Snapshots/`. Manual VoiceOver pass pre-MVP-gate on all five surfaces (Main window, Attribution sheet, Transcript pane, Settings, Doctor). Manual keyboard-only pass with mouse disabled. Reduce Motion pass. Color-vision testing via macOS Color Filters (Protanopia / Deuteranopia / Increased Contrast). SwiftLint custom rule catches missing `accessibilityLabel` on interactive controls.

#### CLI Design Language (parallel surface)

- **UX-DR67 [MVP]:** CLI is parallel surface, not fallback — every meaningful state and action has both a GUI affordance and a CLI verb. Same state machine in both. CLI design tokens per Decisions 1.5/4.4/4.6: Default human output plain text stdout, ANSI color only when TTY (auto-detected, safely falls back when piped); default human errors one sentence to stderr ending with concrete next action; machine-readable mode `--json` opt-in (never auto-detected) with `schemaVersion`-stamped per response; doctor glyphs `[OK]`/`[FAIL]` plain default and ✓/✗ when TTY; status-as-default (bare `auricle` returns current state, not help); exit codes 0 success / 1 user error / 2 state error / 3 not found.
- **UX-DR68 [MVP]:** CLI structured error JSON (in `--json` mode and `os_log` payloads): `{schemaVersion, error: {summary, meetingId, state, cause, fix, see}}`. Structured form also written to `os_log` for every error regardless of CLI mode, so log-grep over time gets same structured shape.

### FR Coverage Map

| FR | Epic | Brief description |
|---|---|---|
| FR1 | Epic 5 | Start Record control in main window |
| FR2 | Epic 5 | Stop Record control |
| FR3 | Epic 5 | Recording-state indicator visible during capture |
| FR4 | Epic 5 | Core Audio process-tap system audio loopback |
| FR5 | Epic 5 | Microphone capture mixed with system audio |
| FR6 | Epic 5 | System Audio Recording + Microphone permission handling |
| FR7 | Epic 6 | Manually discard captured-but-unprocessed meeting from main window |
| FR8 | Epic 10 | Menubar item start/stop (v1.1) |
| FR9 | Epic 10 | VAD pre-flight halt (v1.1) |
| FR10 | Epic 10 | VAD halt override / `--force` (v1.1) |
| FR11 | Epic 1 | Crash-isolated pipeline stages |
| FR12 | Epic 1 + Epic 9 | CLI subcommand binding scaffold (Ep 1) + parity polish (Ep 9) |
| FR13 | Epic 6 | Per-meeting state in main window |
| FR14 | Epic 1 | Idempotent stage re-run |
| FR15 | Epic 10 | `auricle pending` listing (v1.1) |
| FR16 | Epic 10 | Dock badge for stale-pending (v1.1) |
| FR17 | Epic 4 | WhisperKit transcription on-device |
| FR18 | Epic 4 | WhisperKit diarization |
| FR19 | Epic 4 | English-only transcribe |
| FR20 | Epic 4 | Local transcribe — no network round-trip |
| FR21 | Epic 7 | Attribution sheet attached to main window |
| FR22 | Epic 7 | Per-speaker audio snippet playback |
| FR23 | Epic 4 + Epic 7 | Speaker autocomplete data side / CLI batch (Ep 4) + GUI priority order (Ep 7) |
| FR24 | Epic 7 | "This is me" affordance + heuristic pre-select |
| FR25 | Epic 4 + Epic 7 | Publish-anyway CLI path (Ep 4) + GUI affordance (Ep 7) |
| FR26 | Epic 2 | auricle never re-edits vault notes (manual fixes permanent) |
| FR27 | Epic 10 | CLI attribution fallback `--emit-snippets`/`--speakers` (v1.1) |
| FR28 | Epic 3 | Structured summary output (paragraph + action items + decisions) |
| FR29 | Epic 3 | Quote grounding via Citations or substring |
| FR30 | Epic 3 | Grounding validation hard gate; drop on failure |
| FR31 | Epic 3 | Default Anthropic Claude API summarizer |
| FR32 | Epic 3 | Single primary call with optional one-shot fallback |
| FR33 | Epic 10 | Local-LLM summarization path (v1.1+) |
| FR34 | Epic 10 | Long-context drift detection (v1.1) |
| FR35 | Epic 2 | One markdown file per meeting at configurable vault path |
| FR36 | Epic 2 | Atomic write — never opens existing vault file |
| FR37 | Epic 2 | Stable note structure (frontmatter + sections) |
| FR38 | Epic 2 | Speakers in summary as `[[wikilinks]]` |
| FR39 | Epic 2 | Frontmatter schema population |
| FR40 | Epic 2 | Filename convention with date + slug |
| FR41 | Epic 2 | `auricle:` block for pipeline metadata in frontmatter |
| FR42 | Epic 8 (Epic 4 minimal) | macOS user notification on summary ready |
| FR43 | Epic 8 (Epic 4 minimal) | Click notification → open in Obsidian via URL scheme |
| FR44 | Epic 8 | Notification click as verification trigger |
| FR45 | Epic 8 | Hold audio indefinitely until verification click |
| FR46 | Epic 8 | 7-day grace timer post-click |
| FR47 | Epic 8 | 7d/14d retention reminders |
| FR48 | Epic 6 | Per-meeting retention status in main window |
| FR49 | Epic 10 | Per-meeting retention override (`auricle keep`) (v1.1) |
| FR50 | Epic 10 | Per-meeting custom retention windows (v1.1) |
| FR51 | Epic 3 | Google Calendar OAuth + Keychain token |
| FR52 | Epic 3 | Calendar event matching + frontmatter injection |
| FR53 | Epic 6 | Upcoming calendar meetings strip in main window |
| FR54 | Epic 3 | Graceful calendar degradation (`#auricle/needs-calendar-enrichment`) |
| FR55 | Epic 3 | Vault-glossary extraction from wikilink targets |
| FR56 | Epic 3 | Glossary scoping by attendees/topics |
| FR57 | Epic 3 | Glossary injection into summarization prompt |
| FR58 | Epic 5 + Epic 9 | Initial config scaffold (Ep 5) + full SettingsView (Ep 9) |
| FR59 | Epic 1 | Config persistence in `~/.auricle/` / TOML |
| FR60 | Epic 9 (primary) + Epic 5 (mid-capture revocation handling) | Permission detection-on-launch + Doctor surfacing live together in Epic 9 (Winston's "hidden coupling" fix — detection logic and Doctor surface are the same feature). Epic 5 owns mid-capture revocation handling (capture stage's TCC error path) since that's a capture-stage runtime concern. PermissionChecker scaffold lives in Epic 5 (where it's first exercised). |
| FR61 | Epic 1 | Structured os_log logging per stage |
| FR62 | Epic 1 | Crash recovery via state-machine reconciliation |
| FR63 | Epic 6 | App stays alive on window close |
| FR64 | Epic 6 | Cmd-Q graceful exit |
| FR65 | Epic 10 | Sparkle EdDSA-signed self-update (v1.1) |
| FR66 | Epic 1 | Local SQLite telemetry storage |
| FR67–FR72 | Vision (out of MVP/v1.1 scope) | v2+ — not in any epic |
| FR73 | Epic 4 | AIReviewerStrategy family + reviewing_diarization stage + attribution.json schema |
| FR74 | Epic 4 | `diarization_review.enabled` flag + ClaudeDiarizationReviewer + cache-write |
| FR75 | Epic 7 | Sheet AI-hint UX (🤖 chips + Apply/Reject + footer + Cmd-Z) |
| FR76 | Epic 10 only | Concrete `ClaudeTranscriptionReviewer` impl (v1.1). Note: Epic 4 ships the AIReviewerStrategy *family* (per AR-AI-1) which includes the `TranscriptionReviewerStrategy` protocol declaration as part of architectural slot-laying; FR76 itself is the v1.1 concrete impl behind the `transcription_review.enabled` flag. Per Mary's review: don't claim FR76 credit in MVP for a requirement MVP doesn't satisfy. |
| FR77 | Epic 7 | Multi-meeting attribution sheet queue |

### NFR × Epic Audit (one-time, per party-mode review)

> Per Mary's review: NFR coverage was implicit and asymmetric (Performance landed in Epic 3/4 by inference, Accessibility was nowhere visible). Per Amelia's call: this matrix is a one-time audit, not a living artifact — generate it, file it, don't maintain it. If an NFR migrates between epics during story creation, that's evidence to update the epic description, not this matrix.

| NFR | Epic | Notes |
|---|---|---|
| **Performance (P)** | | |
| NFR-P1 (E2E P50 ≤2 min, P95 ≤5 min for 30-min meeting) | Epic 4 (validated) + Epic 9 (`auricle stats` surfaces) | Telemetry counters in Epic 1; smoke-test validates in Epic 4 exit criteria |
| NFR-P2 (E2E P95 ≤10 min for 60-min meeting) | Epic 4 (validated) | Same fixture set; longer meeting validates here |
| NFR-P3 (transcribe ≤30s for 30-min audio) | Epic 4 | WhisperKit on ANE; verified in Story 4.1 |
| NFR-P4 (diarize ≤30s for 30-min audio) | Epic 4 | Verified in Story 4.2 |
| NFR-P5 (summarize P50 ≤60s, P95 ≤180s) | Epic 3 | Verified in eval harness |
| NFR-P6 (Attribution UI loads ≤2s) | Epic 7 | Verified in `Tests/AttributeTests/` snapshot test |
| NFR-P7 (snippet playback ≤200ms cold) | Epic 7 | Pre-loaded `AVAudioPCMBuffer` per speaker |
| NFR-P8 (vault write ≤500ms for ≤50KB) | Epic 2 | Verified in `Tests/PersistTests/VaultWriterTests.swift` |
| NFR-P9 (idle memory ≤200MB; sheet ~98MB target) | Epic 7 | Snapshot test asserts `mach_task_basic_info.resident_size < 200 MB` |
| NFR-P10 (peak memory ≤4GB during 60-min transcribe) | Epic 4 | WhisperKit subprocess constraint |
| NFR-P11 (idle CPU ≤1%) | Epic 5 | App lifecycle baseline; verified post-Epic-5 |
| NFR-P12 (cold start ≤1.5s) | Epic 6 | First measurable when main window exists |
| NFR-P13 (no perceivable system audio latency during capture) | Epic 5 | Passive loopback contract |
| **Reliability (R)** | | |
| NFR-R1 (atomic vault writes; zero partial-write events) | Epic 2 (enforcement) + Epic 1 (primitive) | `AtomicWriter` in Core; `VaultWriter` wraps it |
| NFR-R2 (never opens existing vault file for write) | Epic 2 | DP4 lock; verified by lint rule |
| NFR-R3 (zero unverified-audio-deletion events) | Epic 8 | Retention timer arms only on click |
| NFR-R4 (crash-isolated stages) | Epic 1 | Subprocess boundary contract |
| NFR-R5 (idempotent stages) | Epic 1 (contract) + every stage epic (impl) | `StageRunner` wraps the two-transaction pattern |
| NFR-R6 (state-machine recovery on launch) | Epic 1 | `Orchestrator/CrashRecovery.swift` |
| NFR-R7 (quote-grounding hard gate, 100%) | Epic 3 | `QuoteValidator` drops failing items pre-persist |
| NFR-R8 (Notification permission revoked → graceful degradation) | Epic 8 | Compensating surfaces in Epic 6 banner + Epic 9 doctor |
| NFR-R9 (Anthropic API unreachable → exponential backoff + fail-state) | Epic 3 | `summarization_failed` transient state |
| NFR-R10 (SQLite checkpointed on quit, plus SQLite's automatic checkpoint) | Epic 1 (policy), Epic 6 Story 6.9 (the quit-time call) | GUI checkpoint policy |
| **Security (S)** | | |
| NFR-S1 (Keychain-only secrets) | Epic 3 (Anthropic key) + Epic 5 (initial Keychain plumbing if needed during onboarding) | `KeychainAPIKey`, `GoogleOAuthFlow` |
| NFR-S2 (self-managed code-signing) | Epic 9 | Moved here from Epic 1 per Winston |
| NFR-S3 (cache audio 0600) | Epic 1 (primitive) + Epic 5 (capture write site) | `CacheArtifactWriter` enforces |
| NFR-S4 (no chmod on existing files) | Epic 2 | Vault freedom |
| NFR-S5 (TLS 1.2+ on Anthropic) | Epic 3 | URLSession default + cert validation |
| NFR-S6 (Google OAuth PKCE) | Epic 3 | Read-only scope to primary calendar |
| NFR-S7 (no secrets in os_log) | Epic 1 | `Log` facade redaction |
| NFR-S8 (no telemetry endpoint) | Epic 1 | Local-only by construction |
| NFR-S9 (Sparkle EdDSA verification) | Epic 10 | v1.1 |
| **Privacy (Pr)** | | |
| NFR-Pr1 (no off-machine data flow except configured) | Epic 3 (Anthropic) + Epic 5 (Calendar) | Per-stage data-flow policy |
| NFR-Pr2 (no telemetry/analytics third-party) | Epic 1 | Architectural constraint |
| NFR-Pr3 (artifacts in user-owned dirs only) | Epic 1 (cache + AppSupport paths) + Epic 2 (vault) | Path scoping |
| NFR-Pr4 (Anthropic payload = transcript + glossary only; no audio, first-name speakers, no emails) | Epic 3 | Scrubbing in `AnthropicHTTPClient` |
| NFR-Pr5 (data-flow documented in README + Settings) | Epic 9 | SettingsView privacy section |
| NFR-Pr6 (conservative retention defaults) | Epic 8 | 7-day grace post-click |
| NFR-Pr7 (no indication to other meeting participants) | Epic 5 | OS-level capture is invisible by design |
| **Integration (I)** | | |
| NFR-I1 (macOS 14+) | Epic 1 | Xcode project target |
| NFR-I2 (Apple Silicon arm64) | Epic 1 | Xcode project target |
| NFR-I3 (Obsidian 1.x via URL scheme) | Epic 2 (frontmatter) + Epic 8 (URL-open click handler) | No plugin required |
| NFR-I4 (frontmatter schema versioned + migration-aware) | Epic 2 | `auricle.schema_version` field |
| NFR-I5 (Google Calendar API v3 read-only + graceful degradation) | Epic 3 | `GoogleCalendarSource` |
| NFR-I6 (Anthropic Messages API + configurable model + effort level) | Epic 3 | `claude-opus-5` default at `medium` effort; FR58 config knob |
| NFR-I7 (CLI argument-surface stability) | Epic 1 (scaffold) + Epic 9 (full surface) | Major version bump on rename/remove |
| NFR-I8 (local LLM Ollama + MLX configurable) | Epic 10 | v1.1+ |
| **Accessibility (A)** | | |
| NFR-A1 (VoiceOver on every interactive control) | Epic 5 (first interactive surface) + Epic 6 + Epic 7 + Epic 9 | SwiftLint custom rule + manual VoiceOver pass per surface pre-MVP-gate |
| NFR-A2 (keyboard navigation, Tab order, Spacebar plays focused snippet) | Epic 7 (load-bearing — Attribution sheet) + Epic 5 + Epic 6 + Epic 9 | Manual mouse-disabled completion test per surface |
| NFR-A3 (color never sole conveyor) | Epic 5 (RecordingIndicator) + Epic 6 (StateChip + state palette) + Epic 7 (AIHintChip / VarianceWarningGlyph) | `DesignTokens` enforcement |
| NFR-A4 (Dynamic Type) | Epic 5 + Epic 6 + Epic 7 + Epic 9 | Apple text styles by construction |
| NFR-A5 (Reduce Motion) | Epic 5 (recording pulse) + Epic 6 (state animations) + Epic 7 (sheet dismissal + AI auto-collapse) | `@Environment(\.accessibilityReduceMotion)` gating |
| NFR-A6 (Dark/Light mode) | Epic 5 + Epic 6 + Epic 7 + Epic 9 | Apple semantic colors via `DesignTokens` |
| **Maintainability (M)** | | |
| NFR-M1 (Swift/SwiftUI/AppKit only in MVP) | Epic 1 | Architectural constraint |
| NFR-M2 (subprocess isolation per stage) | Epic 1 (contract) + Epic 4 (heavy-stage isolation) | Per Decision 1.1 |
| NFR-M3 (structured os_log per stage category) | Epic 1 | `Log` facade |
| NFR-M4 (unit tests for primitives) | Epic 1 + Epic 2 + Epic 3 + every subsequent epic | Per-target test target convention |
| NFR-M5 (CI-runnable end-to-end smoke test) | Epic 4 (Story 4.10 Part A pipeline test = the canonical NFR-M5 satisfaction) | Plus Epic 1 scaffold |
| NFR-M6 (config takes effect on next pipeline invocation) | Epic 9 (full config surface) + Epic 1 (config persistence layer) | Per Decision 4.5 |
| NFR-M7 (reproducible builds) | Epic 9 (release script) + Epic 1 (build determinism) | Same git SHA + same toolchain → identical .app |
| NFR-M8 (PRD/brainstorm-anchored code comments) | Every epic | Authoring convention |
| **Cost (C)** | | |
| NFR-C1 (per-meeting cost ceilings tiered) | Epic 3 (default tier validation) + Epic 4 (review tier validation in exit criteria) | Empirically held in smoke test + eval harness |
| NFR-C2 (≤$0.05/30-min meeting v1.1) | Epic 10 | Prompt optimization v1.1 |
| NFR-C3 ($0 local-LLM path) | Epic 10 | v1.1+ |
| NFR-C4 ($0 fixed cost — no Apple Developer Program) | Epic 9 | Self-managed CA + spctl trust policy |

---

## Epic List

> **Story numbering convention:** Stories within each epic are numbered topically (by concern), NOT strictly by recommended implementation order. Forward references between stories within the same epic (e.g., Story 6.2 mentions Story 6.5) describe architectural relationships, not blocking dependencies. **The recommended implementation sequence is documented in each epic's summary block** at the end of the epic. A dev agent picking up an epic should read the summary's sequencing line first to identify which story to implement next, then read the story itself. This convention keeps story numbering readable and grouped by concern (atomics together, composite views together, polish stories at the end) without forcing the reader to mentally reconstruct the dependency graph.

> **Revision note (2026-05-01, post party-mode review):** Epic structure was stress-tested by John (PM), Winston (Architect), Sally (UX), Mary (Analyst), and Amelia (Developer) before approval. Folded changes: (a) Epic 4 renamed to "Pipeline Validation Milestone" with explicit exit criteria; (b) wedge-validation telemetry counter columns wired into `Core/PipelineState` from Epic 1, and minimal `auricle stats` readout promoted from v1.1 to MVP (Epic 9) — MVP cannot ship without the instrument that proves MVP worked; (c) Epic 3 expanded to include explicit eval harness (frozen transcripts + expected-quote-grounding assertions) beyond the smoke-test go/no-go gate; (d) signing/distribution moved Epic 1 → Epic 9; PermissionChecker scaffold moved Epic 1 → Epic 5; (e) FR76 removed from Epic 4 (Epic 4 ships the protocol declaration via AR-AI-1 as a slot-laying commitment, but FR76 itself = the v1.1 concrete impl, owned by Epic 10); (f) FR60 hidden coupling resolved — detection-on-launch + Doctor surfacing both in Epic 9, mid-capture revocation handling in Epic 5; (g) trust calibration (J1.5) acceptance criteria explicitly named in Epic 9 for `auricle status <id>` and `auricle logs <id>`; (h) note added that `AttributionViewModel` lives in `Core/` (consumed by both Epic 4 CLI batch and Epic 7 GUI sheet) — eliminates CLI/GUI divergence risk on FR23/FR25. Rejected after debate: Epic 5 → 5a/5b split (Sally), Epic 7.5 AI-hint UX carve-out (Sally), Epic 10 split per-feature (John). Sally's narrative concerns are flagged in the relevant epic descriptions; Epic 10 description acknowledges its parking-lot framing.

### Epic 1: Foundation — Pipeline State + Atomic-Write Backbone

Project bootstraps (Xcode + SwiftPM hybrid, CI workflows, all 25 SwiftPM target declarations); SQLite state machine + cache-dir handoff + atomic-write primitive + telemetry infrastructure ready for stages to plug in. **The wedge-validation + trust-calibration telemetry counter columns are wired into `Core/PipelineState.swift` and the SQLite `telemetry` table from day one** — including `diarization_suggestions_count`, `diarization_suggestions_applied_count`, `diarization_suggestions_rejected_count`, `diarization_review_cost_usd`, `diarization_review_model`, `transcription_*` (declared, sparse), `quote_validation_drop_count`, `grounding_method`, `time_to_attribution_ready_seconds`, `time_to_vault_note_seconds`, `cost_usd`, `attribution_completion_path` (per Decision 2.1 + Decision 4.5 + Decision 5.7). Retrofitting telemetry through every stage actor is the worst kind of rework (Amelia); the `PipelineState` schema is the Story 1 blocker that gates every subsequent epic.

**Story 1 is the project initialization itself** (per Architecture §Implementation Handoff): `swift package init`, declare all SwiftPM library targets in `Package.swift`, initialize `App/Auricle.xcodeproj` with both executable targets, configure Hardened Runtime / Sandbox-OFF / Info.plist / entitlements / `auricle://` URL scheme registration, `.github/workflows/ci.yml` runs `swift build` + `swift test` + `xcodebuild build` + `swiftformat --lint` + `swiftlint`. Out-of-scope for Epic 1 (moved to Epic 9): the actual code-signing / `spctl` trust-policy / distribution release script. Out-of-scope for Epic 1 (moved to Epic 5): `PermissionChecker` scaffold (lives where first exercised — capture stage).

**Standalone value:** Developer iteration is unblocked; pipeline backbone works against synthetic stage stubs; telemetry counter substrate is in place so subsequent epics never have to refactor `PipelineState` to add a column.

**FRs covered:** FR11, FR12 (binding scaffold — the executable target with `auricle` and the hidden `__internal-stage` worker subcommand exist; per-verb implementation lands in Epic 4/9), FR14, FR59, FR61, FR62, FR66

**NFRs primarily addressed:** NFR-R1 (atomic-write primitive), NFR-R4 (subprocess crash isolation contract), NFR-R5 (idempotent stage re-run), NFR-R6 (state-machine recovery on launch), NFR-R10 (SQLite checkpointing), NFR-M1, NFR-M2, NFR-M3, NFR-M4 (unit tests for primitives), NFR-M5 (end-to-end smoke test scaffold), NFR-M7 (reproducible builds), NFR-M8, NFR-S3 (cache-dir 0600 enforcement), NFR-S7 (Log facade redaction), NFR-S8 (no telemetry endpoint exists), NFR-Pr2, NFR-Pr3, NFR-I1, NFR-I2, NFR-I7 (CLI argument-surface stability scaffold).

**Architectural commitments primarily addressed:** AR-INIT-1 through AR-INIT-5, AR-PIPE-1 through AR-PIPE-5, AR-PIPE-6 (verb-skeleton scaffold; full surface in Epic 4/9), AR-PIPE-7 (`__internal-stage` hidden subcommand pattern), AR-PIPE-8 (CLI conventions), AR-DATA-1 through AR-DATA-5 (SQLite schema + GRDB rules + write-authority + migrations), AR-FAIL-1 (FailureCategory enum), AR-FAIL-2 (`StageRunner.synthesizeFailure` API + per-stage stale-budget table — including 90s for `reviewing_diarization`), AR-PAT-1 through AR-PAT-10 (every enforcement layer — naming, JSON dialects, logging discipline, helper primitives, composition roots, async/actor patterns, typed errors, IPC restrictions, markdown discipline, build/lint/CI).

---

### Epic 2: Vault-Native Note Persistence

Given a synthetic summary JSON, auricle writes a correctly-formatted Obsidian note in the vault — atomic, stable filename, versioned frontmatter schema, never edits existing files. Persist stage with `FrontmatterRenderer`, `VaultWriter`, `FilenameResolver`, atomic-write through `Core/AtomicWriter`, schema versioning, re-publish semantics with `auricle.supersedes`.

**Standalone value:** auricle's vault contract is held end-to-end against synthetic summary input; an Obsidian-native note appears at the configured vault path with stable filename and schema-valid frontmatter.

**FRs covered:** FR26, FR35, FR36, FR37, FR38, FR39, FR40, FR41

**NFRs primarily addressed:** NFR-R1, NFR-R2, NFR-R7 (the persist-side hard gate consumed downstream by Epic 3), NFR-P8, NFR-S4, NFR-I3, NFR-I4.

**Architectural commitments primarily addressed:** AR-DATA-6, AR-DATA-7, AR-DATA-8, AR-DATA-9, AR-PAT-9 (markdown discipline).

**UX-DRs primarily addressed:** UX-DR63 (voice & copy as it pertains to frontmatter / markdown output).

---

### Epic 3: Quote-Grounded Summarization Engine

Given a `CanonicalTranscript` + glossary + calendar event, auricle produces a validated `SummaryWithGrounding` with quote-grounded action items + decisions, dropping items that fail validation. `SummarizerStrategy` family with `ClaudeSubstringSummarizer` (the default after the Decision 3.6 comparison) + `ClaudeCitationsSummarizer` (ships unwired), `SummarizerOrchestrator` mediating an optional fallback (none wired), build-time canonicalization invariant (Decision 3.4 — `Tests/CoreTests/CanonicalTranscriptContractTests.swift` fails build on offset divergence between strategies), prompt builder with snapshot tests + Anthropic prompt caching, smoke-test execution per Decision 3.6. Calendar enrichment (Google OAuth + event matching + graceful degradation) and vault-glossary builder (wikilink-target scan + scoping + prompt injection) ship here as inputs to summarization.

**Eval harness explicitly in scope (Mary's review):** Beyond the Decision 3.6 smoke-test (which is a one-time go/no-go gate that picks Citations vs. substring as default), this epic ships a regression eval harness: `Tests/SummarizeTests/Fixtures/eval/` with frozen transcripts (≥5 of the user's existing meeting recordings at plan time; as built, six public fixtures, with real-recording validation moved to Epic 4) + expected quote-grounded action-items / decisions + assertions on quote-grounding pass-rate, drop-count, and false-positive rate. Story `3.x Summarization eval harness` is a named deliverable, not implicit. This is the artifact that prevents Epic 3's load-bearing slip risk (Mary: "highest-risk epic — wedge lives here, validator is novel, slip cascades into Epic 4 and Epic 7").

**Standalone value:** Given a transcript + glossary + calendar.json, the summarizer produces a validated summary written to `summary.json` in cache-dir; combined with Epic 2's persist stage, this means a complete vault note can be produced from synthetic transcript input. The eval harness gives an automatable regression guardrail before Epic 4 layers on real audio.

**FRs covered:** FR28, FR29, FR30, FR31, FR32, FR51, FR52, FR54, FR55, FR56, FR57

**NFRs primarily addressed:** NFR-P5, NFR-R7 (quote-grounding hard gate enforced here), NFR-R9 (Anthropic retry/backoff), NFR-S1 (Anthropic API key + Google OAuth tokens in Keychain), NFR-S5 (TLS 1.2+), NFR-S6 (Google OAuth PKCE), NFR-S7, NFR-S8, NFR-Pr1, NFR-Pr4, NFR-Pr5, NFR-I5, NFR-I6, NFR-C1 default tier, NFR-C2.

**Architectural commitments primarily addressed:** AR-SUM-1 through AR-SUM-6.

---

### Epic 4: Pipeline Validation Milestone (CLI End-to-End)

> **Renamed from "On-Device Audio → Vault Note (CLI-Dogfoodable Milestone)" per John's review** — this is a *Pipeline Validation* checkpoint for the maintainer-as-builder, not a user-shippable milestone for the maintainer-as-meeting-haver. Pre-existing audio + CLI is not a meeting workflow. The cohesive-MVP commitment lives at Epic 9.

User (in builder mode) has a meeting audio file on disk → registers it with the hidden `auricle __internal-import <audio-file>` (Story 4.8), which prints a meeting id → runs `auricle run <id> --publish-anyway` (or `--speakers "1=Ben,..."` via batch attribution) from terminal → gets a complete Obsidian note. WhisperKit transcribe + diarize subprocess, `ReviewDiarization` stage as dedicated subprocess (with `ClaudeDiarizationReviewer` Haiku-default flag-controlled per Path C), AI-correction `AIReviewerStrategy` family + concrete `ClaudeDiarizationReviewer`, `attribution.json` schema (`segment_overrides`, `segment_splits`), attribution stage with batch CLI mode, basic notification + Obsidian URL-open path, primary CLI verb surface (`record`, `stop`, `discard`, `run`, `attribute --batch`, `keep`, `list`, `status`).

**`AttributionViewModel` lives in `Attribute/`** (per Amelia's mitigation for Sally's CLI/GUI divergence concern): the same view-model is consumed by CLI batch attribution (this epic) AND the Epic 7 GUI sheet. The type system is the parity contract — no need for a separate parity-contract document, no risk of "two products sharing one FR number."

**Explicit exit criteria (per John + Amelia):**
- Story `4.10` is the named exit gate, in two parts: a CI pipeline test (`Tests/IntegrationTests/PipelineEndToEndTests.swift`) and a manual live run (`Tests/scripts/run-epic4-exit-criteria.sh`).
- Concrete live invocation: `auricle __internal-import <audio-file>`, then `auricle run <id> --publish-anyway`, against ≥5 of the user's existing meeting recordings (path-referenced by environment variable, never checked in).
- Quote-grounding pass-rate target, measured by the live run: ≥80% on action items + decisions across the fixture set (validates wedge — adjustable based on Epic 3 eval-harness baseline).
- Cost ceiling held, measured by the live run: ≤NFR-C1 default tier per meeting; ≤NFR-C1 v1.1+ tier per meeting when `diarization_review.enabled = true`.
- Each fixture produces a vault note at the configured path with schema-valid frontmatter; every action item / decision rendered as a `> source quote` blockquote that survives literal substring match.
- `meetings.verified_at` is NULL on each fixture, read from the state store because `auricle status <id>` is a stub until Story 9.6 (verification is human action, not automatic on `auricle run` — per Decision 4.3).
- The CI pipeline test runs on every PR under `swift test` with stub strategies and one small checked-in WAV (NFR-M5); the live run uses real WhisperKit and live Anthropic calls on recordings that stay outside the repository.

**Out of scope (architectural slot ≠ FR satisfaction):** FR76 (`ClaudeTranscriptionReviewer` concrete impl) is *not* claimed by this epic. AR-AI-1 ships the `TranscriptionReviewerStrategy` protocol declaration as part of slot-laying so v1.1's Phase 3 Path C activation is a concrete-impl story not a refactor — but the *requirement* FR76 is owned by Epic 10.

**Story sequence (10 planned stories, 4.11 to 4.15 added later — sequencing matters; 4.9 cannot land before 4.1–4.8):**
1. `4.1` WhisperKit transcribe stage (FR17, FR19, FR20)
2. `4.2` Diarize stage + snippet extraction (FR18)
3. `4.3` `ReviewDiarization` stage + state machine entry (FR74 with flag default-off path validated in <100ms)
4. `4.4` `AIReviewerInterface` protocol family + null `TranscriptionReviewerStrategy` (FR73; AR-AI-1)
5. `4.5` `ClaudeDiarizationReviewer` concrete impl behind flag (FR74 with flag-on path)
6. `4.6` `AttributionViewModel` in `Attribute/` + attribution batch CLI (FR23 data-side, FR25 CLI publish-anyway)
7. `4.7` `auricle run` verb skeleton + `__internal-stage` worker dispatch wiring
8. `4.8` Builder-mode audio import (`auricle __internal-import`)
9. `4.9` Basic notification stub + Obsidian URL-open (FR42 minimal, FR43 minimal — the Verifier+timer wiring lands in Epic 8)
10. `4.10` Exit-criteria gate (CI pipeline test + live run, per criteria above)

**Standalone value:** auricle works end-to-end via CLI on pre-existing audio recordings — the architecture's risk-front-loaded validation checkpoint. Validates Claude summarization quality on real transcripts, validates WhisperKit diarization quality, validates the AI-correction wedge thesis, validates the entire pipeline before any GUI investment. **This is a gate, not a ship.**

**FRs covered:** FR17, FR18, FR19, FR20, FR23 (data-side / CLI batch path), FR25 (CLI publish-anyway), FR27 (mechanism only: the `--speakers` batch path; the documented fallback surface stays [v1.1]), FR42 (basic notification stub), FR43 (basic Obsidian URL open), FR73, FR74

**NFRs primarily addressed:** NFR-P3, NFR-P4, NFR-P10 (peak memory for WhisperKit), NFR-Pr1 (transcribe local), NFR-Pr4, NFR-C1 v1.1+ tier (when diarization review enabled — empirically validated by exit-criteria smoke test), NFR-I8 (local LLM v1.1+ protocol slot).

**Architectural commitments primarily addressed:** AR-AI-1 through AR-AI-9, AR-PIPE-6 (primary CLI verb surface — full surface in Epic 9), AR-PIPE-7 (`__internal-stage` subcommand for subprocess dispatch), AR-PIPE-8 (CLI conventions).

---

### Epic 5: System-Audio Capture & First-Run Onboarding (J0)

Fresh Mac → user grants permissions through 4-step onboarding gauntlet → clicks Record → captures meeting audio loopback (system audio from a Core Audio global process tap, mic from AVAudioEngine, mixed to PCM 16-bit 16kHz mono WAV in cache-dir) → can stop → the pipeline runs to `awaiting_attribution`. Capture runs in the GUI process; the `record` / `stop` CLI verbs are Story 9.5's. `RecordingIndicator` atomic component provides the visible privacy contract surface. `PermissionChecker` + `TCCCategory` deep-link remediation **scaffold lives here** (Winston's call — moved from Epic 1 because PermissionChecker is first exercised by capture stage). Info.plist usage descriptions in user voice. Mid-capture permission revocation handling (capture stage TCC error path) lives here too.

**Throwaway debug Record trigger:** Epic 5 ships a debug-only Record trigger (menu item or hotkey) so capture mechanics can be exercised before Epic 6's main window UI exists. Epic 6 deletes this trigger when the proper Record button + main window header land. This avoids "Record button has nowhere to live" pressure collapsing the Epic 5/6 boundary (Winston's recommendation).

**On Sally's Epic 5a/5b split concern:** the J0 onboarding *narrative* (welcome → vault picker → Obsidian handshake → first-meeting expectation-setting → quiet success states) is its own coherent arc, but for a solo developer with no QA org, story-level partition inside this epic is sufficient (Amelia's call). Stories within Epic 5 sequence the capture-plumbing track and the onboarding-narrative track in parallel; capture logic lives in `Permissions` and `Capture`, onboarding logic in a new `AppUI` SwiftPM target (so `swift test` covers it), and `App/Auricle/Onboarding/` holds only SwiftUI views. The relationship-milestone vs. capability-milestone framing is documented so the onboarding stories explicitly own the Day-1-trust contract — they don't get implemented as the appendix to capture mechanics.

**Standalone value:** Fresh-Mac user is fully onboarded and can capture audio loopback from any meeting platform without bot integration. Pipeline now has auricle-captured audio (not just pre-existing recordings) flowing into Epic 4's transcribe stage.

**FRs covered:** FR1, FR2, FR3, FR4, FR5, FR6, FR58 (initial config scaffold for vault path / API key / `self.wikilink` during onboarding, with `ConfigWriter` — full SettingsView in Epic 9), FR60 (mid-capture revocation)

**NFRs primarily addressed:** NFR-P11, NFR-P13, NFR-S3 (cache audio 0600), NFR-Pr3, NFR-Pr7, NFR-A1 through NFR-A6 (accessibility for the first interactive surfaces).

**Architectural commitments primarily addressed:** AR-FAIL-6 (permission detection points + remediation flow + Info.plist user voice; mid-capture revocation handling).

**UX-DRs primarily addressed:** UX-DR9 (RecordingIndicator), UX-DR41 (J0 onboarding gauntlet), UX-DR42 (self.wikilink config), UX-DR44 (Info.plist usage descriptions in user voice), UX-DR45 (TCC remediation deep links).

---

### Epic 6: Single-Window GUI Shell & State Visibility (J6)

User opens auricle, sees the single main window with meeting list, can see per-meeting state at a glance, expand a row inline to see operations console, retry transient failures inline, see retention countdowns + 30-day cost widget + upcoming calendar events strip. Failure-visibility surfaces (Decision 4.6) all wired here. `MainWindowView` + `MeetingListView`/`MeetingRowView` + `OperationsConsoleView` + `OnLaunchBannerView` + `UpcomingEventStripView` + `RollingCostFooterView` composite views, `StateChip` + `CountdownAnnotation` + `PipelineTimelineView` atomic components.

**Standalone value:** User has a complete state-visibility surface — every meeting state is legible at a glance, every failure has at least one always-on surface, every transient failure has an inline retry, app stays alive on window close while keeping the user oriented.

**FRs covered:** FR7, FR13, FR48, FR53, FR63, FR64

**NFRs primarily addressed:** NFR-P12 (cold start), NFR-A1 through NFR-A6, NFR-I3, NFR-Pr2 (rolling cost widget + telemetry visibility — local only).

**Architectural commitments primarily addressed:** AR-FAIL-1 (FailureCategory chip mapping), AR-FAIL-2 (stale-active-state synthesis surfacing), AR-FAIL-7 (failure-visibility surfaces).

**UX-DRs primarily addressed:** UX-DR1, UX-DR2, UX-DR3, UX-DR4, UX-DR5, UX-DR6, UX-DR7, UX-DR8, UX-DR10, UX-DR11, UX-DR17, UX-DR20, UX-DR22, UX-DR23, UX-DR24, UX-DR25, UX-DR26, UX-DR27, UX-DR52, UX-DR53, UX-DR54, UX-DR56, UX-DR57, UX-DR58, UX-DR60, UX-DR61, UX-DR62, UX-DR63, UX-DR64, UX-DR65, UX-DR66.

---

### Epic 7: Attribution Sheet & AI-Hint UX (J1, J2, J1.7, J9)

When a meeting reaches `awaiting_attribution`, user opens the Attribution sheet (rises from main window — never a separate window — single-window principle), names speakers via calendar-marked autocomplete + "this is me" pre-select + recurring-meeting auto-prefill, reviews AI-suggested diarization corrections inline (per-paragraph 🤖 chips with Apply/Reject), or escapes via Publish unattributed. Three rename mechanics (default global / per-paragraph reassign / AI splits). Asymmetric bottom-button hierarchy. Sheet queue for multi-meeting concurrency. Trust-calibration footer + per-Apply Cmd-Z + persistent revert.

**Same `AttributionViewModel` as Epic 4** (lives in `Attribute/`, not in the GUI target): the type system is the parity contract between CLI batch attribution and the GUI sheet — the rename mechanics and `attribution.json` schema invariants apply to both surfaces by construction.

**On Sally's Epic 7.5 (AI-hint UX as separate flag-gated epic) concern:** AI-hint UX (`AIHintChip`, `TrustCalibrationFooter`, `AttributionTranscriptPane`, paragraph-level Apply/Reject) ships in this epic *behind the `diarization_review.enabled` flag* per Path C. The flag-gating already isolates the AI-correction work — when the flag is off, the entire AI-hint surface code is dead-but-loaded; when on (Phase 2 v1.1), it activates without code changes. Splitting into a separate epic would be process theater without a QA org demanding a separate gate (Amelia's call). Mitigation: stories within Epic 7 explicitly tag AI-hint UX stories as `[flag-gated]` so reviewers can identify what activates only on Phase 2 flip — and the same fixture set used in Epic 3 + Epic 4 exit-criteria flows through the AI-hint UX with `diarization_review.enabled = true` to validate Phase 2 activation criteria when the time comes.

**On Sally's "second meeting" / J9 trust-compounding concern:** J9 (recurring 1:1 auto-prefill via FR23 previously-labeled tier with `attribution.recurring_meeting_threshold` default 3) is in Epic 7. Stories explicitly tag J9 acceptance criteria — auricle "remembering Nina from last Tuesday" is the trust-compounding moment, and it deserves a named acceptance criterion (e.g., "Given 3 prior labelings of the same calendar attendees, when the same meeting recurs, then the speaker rows pre-fill via previously-labeled tier with no user input required → 1-keystroke Cmd-Enter completion"). This is where Day-30 retention is actually won; flagging it so it doesn't get lost as "just another autocomplete tier."

**Standalone value:** auricle's differentiating UX is complete — the only blocking human-in-the-loop step in MVP works end-to-end; the AI-correction wedge (diarization sibling, flag-default-off MVP) ships its slot.

**FRs covered:** FR21, FR22, FR23 (GUI priority order), FR24, FR25 (GUI affordance), FR75, FR77

**NFRs primarily addressed:** NFR-P6 (Attribution UI ≤2s), NFR-P7 (snippet playback ≤200ms), NFR-P9 (sheet open-state memory ≤200MB, working target ~98MB), NFR-A1 through NFR-A6.

**Architectural commitments primarily addressed:** AR-AI-3 (subprocess→GUI handoff race-free contract), AR-AI-4 (cache-immutability invariant + pure-function renderer), AR-AI-5 (sheet-open watcher), AR-AI-6 (attribution.json schema usage), AR-AI-7 (Path C activation visibility), AR-AI-8 (kill criteria + trust calibration footer surfacing).

**UX-DRs primarily addressed:** UX-DR12, UX-DR13, UX-DR14, UX-DR15, UX-DR16, UX-DR18, UX-DR19, UX-DR21, UX-DR28, UX-DR29, UX-DR30, UX-DR31, UX-DR32, UX-DR33, UX-DR34, UX-DR35, UX-DR36, UX-DR37, UX-DR38, UX-DR39, UX-DR40, UX-DR55, UX-DR59.

---

### Epic 8: Verification, Retention & Notifications (J5)

User gets the summary-ready macOS notification, single click both opens the note in Obsidian (via `obsidian://open` URL scheme) and arms the 7-day audio retention timer; manual verify covers users who opened directly from Obsidian (GUI confirm + `auricle keep <id>` CLI); 7d/14d reminders fire before deletion. `Verifier` Swift `actor` is the single converge point. Notification payload format binding contract surviving Sparkle upgrades. Retention scheduler periodic background job. Audio cache cleanup on retention expiry.

**Standalone value:** The audio-safety contract (NFR-R3 zero unverified-audio-deletions) is held end-to-end; the verification-as-a-meaningful-event UX pattern works for both notification-click and Obsidian-direct-open paths.

**FRs covered:** FR42 (full path), FR43 (full path), FR44, FR45, FR46, FR47

**NFRs primarily addressed:** NFR-R3 (zero unverified-audio-deletion), NFR-R8 (notification-permission-revoked graceful), NFR-Pr6 (conservative retention defaults).

**Architectural commitments primarily addressed:** AR-FAIL-4 (Verifier actor + idempotent SQL), AR-FAIL-5 (notification payload format binding contract), AR-PAT-4 (Verifier helper-discipline primitive).

**UX-DRs primarily addressed:** UX-DR49, UX-DR50, UX-DR51.

---

### Epic 9: Settings, Doctor, Distribution & MVP-Gate Wedge Surface

The MVP gate. Three additions vs. the original Epic 9 scope, all from party-mode review:
1. **Distribution moved here from Epic 1** (Winston's call): self-managed code-signing CA + per-Mac `spctl` trust policy, `scripts/setup-trust.sh` (idempotent), Bundle layout (Auricle.app/Contents/MacOS/auricle-cli co-bundled), `auricle doctor`'s Gatekeeper trust check. Sparkle stays in Epic 10 (v1.1).
2. **Minimal `auricle stats` (wedge-validation surface) promoted from Epic 10 to MVP** (Mary + Amelia): MVP cannot ship without the instrument that proves MVP worked. The `Core/PipelineState.swift` + `telemetry` table laid down in Epic 1 already carry every counter column needed; this epic adds the read-side rollup verb. v1.1 enriches it with rolling aggregates / per-meeting drilldowns; MVP needs at minimum: total meetings captured, applied/suggestions ratio + false-positive rate (when AI flag on), `quote_validation_drop_count` aggregate, summarization cost over the dogfood window.
3. **Trust-calibration acceptance criteria for `auricle status <id>` and `auricle logs <id>`** (Mary's J1.5 fix): named ACs ensure trust calibration doesn't get lost as "ambient infrastructure someone else owns." `auricle status <id>` MUST surface `grounding_method`, total items, drop count, and a copy-pasteable `log show` invocation per Decision 3.7. `auricle logs <id> --stage summarize` lands here (or v1.1 — to be decided per dogfood need; if MVP-needed for trust calibration, lifts here).

User has full configuration control via SettingsView (Cmd-, macOS Settings scene, auto-save on field commit); can run `auricle doctor` to diagnose system readiness (permissions + Gatekeeper trust + vault path) with conversational narrated remediation hints; CLI parity for every workflow with stable binding contract per NFR-I7 (`config get/set`, `doctor`, `status`, `list`, full `run` with `--from`/`--to`/`--only`/`--force`/`--reattribute`/`--publish-anyway`, structured `--json` schemas, exit codes). FR60's permission detection-on-launch surface lives here too (resolves Winston's hidden-coupling concern by collapsing detection-logic + Doctor-surface into one epic).

**Standalone value:** The MVP cohesive milestone is reached — auricle works on a real captured meeting through the GUI happy path AND via CLI parallel surface; configuration knobs are user-adjustable; system-readiness check is one command away; the wedge-validation hypothesis (≥40% applied jargon corrections / ≥40% AI accept rate / <20% FP) is *measurable* via `auricle stats`. Distribution mechanism is in place — auricle installs cleanly on a fresh Mac via `scripts/setup-trust.sh`.

**FRs covered:** FR12 (CLI parity completeness), FR58 (full SettingsView UI), FR60 (permission detection-on-launch + Doctor surfacing of missing-permissions remediation)

**NFRs primarily addressed:** NFR-M6 (config takes effect on next pipeline invocation), NFR-I7 (CLI binding contract finalized), NFR-S2 (self-managed code-signing certificate trust), NFR-C4 ($0 fixed cost — no Apple Developer Program).

**Architectural commitments primarily addressed:** AR-DIST-1 through AR-DIST-4 (moved from Epic 1), AR-PIPE-6 (full MVP CLI verb surface), AR-PIPE-8 (CLI conventions), AR-FAIL-6 (Doctor verb integration), AR-SUM-6 (trust-calibration surfaces — `auricle status <id>` + `log show` discovery path), AR-AI-9 (wedge-validation measurement via `auricle stats` minimal MVP impl).

**UX-DRs primarily addressed:** UX-DR46 (DoctorView conversational narrated check format), UX-DR47 (SettingsView), UX-DR48 (auto-save on field commit; secrets shown as `••••••••`), UX-DR67, UX-DR68 (CLI design tokens + structured error JSON).

---

### Epic 10: v1.1 Operability & Power-User Features (Re-Prioritization Queue)

> **Honest framing (per John's review):** This epic is a *parking lot* for v1.1 features. It is NOT prioritized — it is a queue that will be re-ranked after ~30 days of MVP dogfood, when the user has empirical signal on which 2-3 of these features actually matter to their real workflow. Treating it as a pre-prioritized epic would be planning theater. After dogfood, this epic SHOULD be split into "Epic 10: <the 2-3 that earned their way>" and "Epic 11+ (deferred indefinitely): <the rest>." Don't pretend the prioritization conversation has happened when it hasn't. (Amelia's call: renaming doesn't change what gets built — keep one epic but flag the framing.)

Power-user / operability features that earn their way after MVP dogfood — each independently shippable, none load-bearing for MVP. Bundle includes: menubar item with quick start/stop and click-to-open-window (FR8); VAD pre-flight halt with `--force` override (FR9, FR10); `auricle pending` listing + Dock badge for stale-pending items (FR15, FR16); CLI attribution fallback `--emit-snippets`/`--speakers` (FR27); per-meeting retention overrides via `auricle retain --indefinite|--days N|--release` and Settings UI (FR49, FR50); long-context drift detection on ≥60min transcripts (FR34); Sparkle EdDSA-signed appcast self-update (FR65); concrete `ClaudeTranscriptionReviewer` impl with `transcription_review.enabled` flag and same dogfood-then-enable activation gate as diarization review (FR76); local-LLM `OllamaSummarizer` and/or `MLXSummarizer` (FR33); `auricle stats` enrichments (rolling aggregates, per-meeting drilldowns, kill-criteria flagging — minimal MVP `auricle stats` is in Epic 9).

**Standalone value:** Each v1.1 feature ships independently after dogfood validation; the MVP keeps working without any of them.

**FRs covered:** FR8, FR9, FR10, FR15, FR16, FR27, FR33, FR34, FR49, FR50, FR65, FR76 (concrete impl)

**NFRs primarily addressed:** NFR-S9 (Sparkle EdDSA verification), NFR-C2 (v1.1 cost reduction via prompt optimization), NFR-C3 (local-LLM $0 path), NFR-I8 (Ollama / MLX runtime configurable).

**Architectural commitments primarily addressed:** AR-AI-7 Phase 2/3 (diarization review enabled by default; transcription review concrete impl), Decision 3.8 (long-context drift), Decision 3.9 (local-LLM strategy contract), AR-PIPE-6 v1.1 verb additions.

---

### Out of Scope (FR67–FR72, v2+ Vision)

Reserved for future major versions; not addressed by any epic in this breakdown:
- FR67 Auto-detect meeting in progress
- FR68 Cross-meeting voice-print embeddings via pyannote sidecar
- FR69 Meeting-type-specific summarization templates
- FR70 Series-overview auto-aggregation for recurring meetings
- FR71 Chain-of-summarize fallback for ≥90min transcripts
- FR72 Apple SpeechAnalyzer fallback ASR path on macOS 26+

---

## Epic 1: Foundation — Pipeline State + Atomic-Write Backbone

Project bootstraps; build/test/CI work; SQLite state machine + cache-dir handoff + atomic-write primitive + telemetry infrastructure ready for stages to plug in. Wedge-validation telemetry counter columns wired into `Core/PipelineState` from day one (Amelia's "Story 1 blocker"). After this epic, a developer can iterate on auricle code with confidence that the pipeline backbone, helper primitives, and enforcement layers are in place.

### Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)

As the maintainer (in builder mode),
I want the auricle repository scaffolded with the hybrid SwiftPM library + Xcode app project structure declared in `Package.swift`,
So that every subsequent story can land in a target with explicit build-system-enforced module boundaries.

**Acceptance Criteria:**

**Given** an empty repository directory
**When** I run `swift package init --type library --name AuricleKit` and then add the SwiftPM target list per AR-INIT-5
**Then** `Package.swift` declares all 25 SwiftPM library targets (`Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`, `Capture`, `TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`, `Transcribe`, `Diarize`, `Attribute`, `Summarize`, `ClaudeSummarizer`, `ClaudeAIReviewers`, `ReviewDiarization`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`, `VaultGlossary`, `Persist`, `Verify`, `Notifications`) plus matching `<Target>Tests` test targets and `TestSupport`
**And** external SPM dependencies are declared (WhisperKit, GRDB.swift, swift-argument-parser, TOMLKit; Sparkle deferred for v1.1 with a comment)
**And** `swift build` succeeds with no source files in any target (empty target compilation passes)
**And** `swift test` succeeds against every test target (empty test suites pass)

**Given** Story 1.1 has set up `Package.swift`
**When** I create `App/Auricle.xcodeproj` with two executable targets (`AuricleApp` SwiftUI macOS App + `auricle-cli` Command Line Tool) both depending on the SwiftPM library
**Then** `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build` succeeds for an empty `@main App { var body: some Scene { WindowGroup { Text("auricle") } } }` shell
**And** `xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli build` succeeds for an empty CLI binary
**And** Hardened Runtime is ON, App Sandbox is OFF, deployment target is macOS 14, architecture is arm64-only
**And** `Info.plist` carries `LSUIElement=NO`, `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `NSUserNotificationsUsageDescription` strings in user voice per UX-DR44
**And** `Auricle.entitlements` includes `com.apple.security.device.audio-input` and notification entitlements; no `com.apple.security.app-sandbox`
**And** `CFBundleURLTypes` registers the `auricle://` URL scheme

**Given** the Xcode project builds
**When** I open `App/Auricle/Info.plist`
**Then** the Bundle Identifier is `com.auricle.app` (stable forever per NFR-S2 TCC permission persistence)

**Given** the project structure is in place
**When** I commit and push to the repository
**Then** the directory layout matches AR-INIT-5 exactly (`Sources/<Target>/`, `Tests/<Target>Tests/`, `App/Auricle.xcodeproj/`, `App/Auricle/`, `App/auricle-cli/`, `scripts/`, `assets/`, `_bmad-output/`)
**And** `.gitignore` excludes `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata/`, `Package.resolved` (committed but listed for clarity)

---

### Story 1.2: Core Primitives — AtomicWriter, IDs, CanonicalTranscript, Dialects, Config

As the single user,
I want the `Core` target to provide the single-implementation primitives every other target depends on,
So that no downstream story reinvents file I/O, ID generation, transcript canonicalization, JSON dialects, or config loading.

**Acceptance Criteria:**

**Given** a freshly built `Core` target
**When** I call `AtomicWriter.write(_ data: Data, to path: URL)`
**Then** the implementation uses `temp file → fsync → rename` semantics per NFR-R1 + FR36
**And** `Tests/CoreTests/AtomicWriterTests.swift` verifies: a successful write produces the target file with correct contents; a write that's killed before the rename leaves the temp file but never produces a partial target file; a re-run overwrites atomically
**And** a CI lint rule fails the build if `Data.write(to:)`, `String.write(to:atomically:encoding:)`, or `FileManager.createFile(...)` appears anywhere outside `AtomicWriter.swift` itself (per AR-PAT-4)

**Given** the `Core` target
**When** I call `MeetingID(ulid: String)` or `MeetingID.generate()`
**Then** ULIDs are 26-char Crockford base32 strings (timestamp-prefixed for sort order); `MeetingID` wraps the string in a strongly-typed `struct`; type system rejects accidental `String` substitution (per AR-PAT-7)
**And** `MeetingIDResolver` accepts `current` (active capture), `last` (most recent created_at), full ULID, or ULID prefix ≥6 chars; ambiguous prefix returns multiple matches; invalid input returns nil
**And** `Tests/CoreTests/MeetingIDResolverTests.swift` covers all four input forms, including ambiguous-prefix and prefix-too-short failure modes

**Given** the `Core` target
**When** I serialize a `CanonicalTranscript` value to JSON and deserialize it back
**Then** the round-trip produces byte-identical text per AR-SUM-4
**And** `CanonicalTranscript` enforces NFC Unicode normalization, LF line endings, no leading/trailing whitespace per line, and `<Speaker_N>: ` prefix at utterance start
**And** character offsets are UTF-8 byte offsets into the NFC-normalized representation (auricle's internal convention; no API contract depends on it per AR-SUM-4)
**And** `Tests/CoreTests/CanonicalTranscriptContractTests.swift` is the canonical build-time invariant test for AR-SUM-4 (extended with cross-strategy assertions in Epic 3)
**And** as built, `CanonicalTranscript` did not land in this story: the story's token-budget split gate deferred it, and it landed in Story 3.1 (`Sources/Core/CanonicalTranscript.swift`)

**Given** the `Core` target
**When** I declare a `Codable` type for a cache-dir artifact (snake_case dialect)
**Then** `Codable+Dialects.swift` provides a `SnakeCaseCodingKey` helper or a documented pattern for declaring `enum CodingKeys: String, CodingKey` with snake_case raw values per AR-PAT-2
**And** CLI output types (camelCase dialect) use Swift default property names — no `CodingKeys` required
**And** every JSON-shaped contract type in the codebase has a round-trip test (encode → decode → equality) per AR-PAT-2 enforcement

**Given** the `Core` target
**When** I read or write the user's TOML config at `~/.auricle/config.toml`
**Then** `Core/Config.swift` provides typed accessors for every config key per FR58 (vault path, meetings_subdir, retention grace window, summarization engine choice, model identifier, effort budget, log verbosity, `diarization_review.enabled`, `diarization_review.model`, `attribution.heuristic_self_preselect`, `attribution.show_coverage_strip`, `attribution.snippet_duration_seconds`, `attribution.max_suggestions`, `attribution.recurring_meeting_threshold`, `self.wikilink`)
**And** tilde expansion + symlink resolution happens once at config load; the canonical absolute path is what's stored
**And** secrets (Anthropic API key, Google OAuth refresh token) are NEVER read from or written to this file (Keychain-only per NFR-S1)
**And** config changes take effect on next pipeline invocation without app restart (NFR-M6) — verified by a test that mutates config and observes the next read
**And** as built, `Config` did not land in this story either: it landed in the Epic 3 follow-through (`Sources/Core/Config.swift`) and reads `vault_path`, `meetings_subdir` and the Google Calendar client keys only. Story 9.1 owns the remaining FR58 keys and symlink normalization

**Given** the `Core` target
**When** I declare a typed Swift error
**Then** error types are `enum`s conforming to `Error` per AR-PAT-7; one enum per error domain (`CaptureError`, `TranscribeError`, `SummarizerError`, `PersistError`, `VerifierError`); cases carry associated values for context
**And** `NSError` bridging only happens at Apple-framework callback boundaries with immediate translation to a typed Swift error before propagating

---

### Story 1.3: Log Facade with Sensitivity Tagging and Redaction

As the single user,
I want a single `Log` facade that wraps `os_log` and enforces sensitivity tagging at every call site,
So that no log emission ever leaks a secret, transcript content, attendee email, or Anthropic response body — and inspection via `log show --predicate 'subsystem == "com.auricle.app"'` is the canonical operational surface.

**Acceptance Criteria:**

**Given** the `Core` target
**When** I declare `private let log = Log(category: "transcribe")` at the top of any file
**Then** the facade is the only sanctioned logging interface (per AR-PAT-3); `os_log(...)` direct calls outside `Log.swift` itself are rejected by a custom `swiftlint` rule
**And** `print(...)` outside CLI bare-output paths is also rejected by a custom `swiftlint` rule

**Given** I'm logging structured fields
**When** I call `log.info("transcribe completed", duration: .publicSafe(durationMs), audioPath: .sensitive(path))`
**Then** the facade routes `publicSafe` fields through `%{public}@` and `sensitive` fields through `%{private}@` per NFR-S7
**And** **defaulting to `publicSafe` is a code-review reject** (call site must explicitly tag every field); defaulting to `sensitive` is permissible

**Given** I'm logging at any level
**When** the message is `debug`
**Then** the call is stripped in release builds via compile-time flag
**And** `info` is the default for state transitions (paired with `stage_events` rows in Epic 1 Story 1.6)
**And** `warn` is reserved for potential issues surfaced to user (e.g., quote-validation drops, calendar enrichment failure-but-publish-anyway)
**And** `error` is paired with a state transition into `*_failed`

**Given** an Anthropic API call returns a response body
**When** the response is logged
**Then** the response body itself is **never** passed to the `Log` facade — only redacted metadata (status code, token counts, cost) is permitted; verified by `Tests/CoreTests/LogRedactionTests.swift` against a fixture response

**Given** the project conventions
**When** any test or sample code emits a log line
**Then** the subsystem is always `com.auricle.app` (single value, locked per AR-PAT-3); the category matches the stage or module name per AR-PAT-3

---

### Story 1.4: SQLite Schema, StateStore, and GRDB Migrations (with Full Telemetry Counter Columns)

As the single user,
I want a single SQLite database at `~/Library/Application Support/com.auricle.app/auricle.sqlite3` with the five canonical tables and **all wedge-validation telemetry counter columns** wired in from migration #1,
So that every subsequent epic can read/write state without ever needing a schema migration to add a column that should have been there from day one.

**Acceptance Criteria:**

**Given** the `Package.swift` GRDB dependency floor (`from: "6.29.0"`, predating GRDB 7.0.0 which requires Xcode 16+/Swift 6 compiler — already satisfied by this project's Xcode 26.4.1 pin)
**When** this story begins
**Then** confirm GRDB 7.x builds cleanly against this package's `swift-tools-version: 5.10` target before writing migration #1
**And** if the build is clean, bump the floor to `from: "7.0.0"` — its default-IMMEDIATE-writes behavior is a better match for this story's WAL/cross-process assumptions (per architecture.md's GRDB/WAL/concurrency table) than 6.x's configurable default
**And** if the build is not clean, stay on `from: "6.29.0"` and record why in this story's Dev Agent Record

**Given** the `State` target
**When** I call `StateStore.production().database()` for the first time on a fresh machine
**Then** the database is created at `~/Library/Application Support/com.auricle.app/auricle.sqlite3` per AR-DATA-1
**And** WAL mode is enabled in migration #1 (sticky in file header — subsequent opens inherit per AR-DATA-2)
**And** `PRAGMA foreign_keys = ON` per connection
**And** all five tables exist exactly per AR-DATA-1 SQL: `schema_version`, `meetings`, `stage_events`, `retention_timers`, `telemetry`
**And** the `meetings_updated_at` AFTER UPDATE trigger is registered

**Given** the `meetings` table is created
**When** I inspect the schema
**Then** the partial index `idx_meetings_state ON meetings(state) WHERE state NOT IN ('verified','retention_expired','discarded')` exists per AR-DATA-1

**Given** the `telemetry` table is created
**When** I inspect the schema
**Then** every wedge-validation + trust-calibration counter column exists per AR-DATA-1 + Decision 4.5 + Decision 5.7: `time_to_attribution_ready_seconds`, `time_to_vault_note_seconds`, `transcription_wer_estimate`, `quote_validation_drop_count`, `attribution_completion_path`, `summarization_path`, `summarization_model`, `summarization_effort_budget`, `cost_usd`, `summarization_prompt_set_hash`, `diarization_suggestions_count`, `diarization_suggestions_applied_count`, `diarization_suggestions_rejected_count`, `diarization_review_cost_usd`, `diarization_review_model`, `transcription_suggestions_count`, `transcription_suggestions_applied_count`, `transcription_suggestions_rejected_count`, `transcription_review_cost_usd`, `transcription_review_model`, `audio_retention_status_at_snapshot`
**And** the `transcription_*` columns are declared but sparse (no MVP writer per Decision 5.5 Phase 3); their existence is the schema-stable contract
**And** the schema was meant to need no later column-adding migration — Amelia's Story 1 blocker. As built, migration #1 omitted `summarization_prompt_set_hash`, and migration #4 (Story 3.7) added it together with `grounding_method`

**Given** the `State` target
**When** the GUI process opens the database
**Then** `DatabasePoolFactory` returns a GRDB `DatabasePool` (concurrent reads with own writes) per AR-DATA-2
**And** when a subprocess opens the database, the factory returns a `DatabaseQueue` (single writer) per AR-DATA-2
**And** `Configuration.busyMode = .timeout(5.0)` is set on every opener
**And** the GUI runs `PRAGMA wal_checkpoint(TRUNCATE)` on app quit; subprocesses issue no explicit checkpoint
**And** the clause was first written as a checkpoint on every state transition, and NFR-R10 was reworded (Epic 1 retro, 2026-09-19) to a checkpoint on quit plus SQLite's automatic checkpoint, since SQLite checkpoints the WAL by itself once it passes its page threshold and the practical risk is unbounded WAL growth, not data loss. As built, nothing in `Sources/` or `App/` runs `wal_checkpoint`: the quit-time call is Story 6.9's

**Given** the `State` target
**When** I import GRDB
**Then** `Meeting`, `StageEvent`, `RetentionTimer`, `Telemetry` types conform to `FetchableRecord` + `MutablePersistableRecord` GRDB protocols
**And** `StateStore` is the public API for every state read/write (per AR-PAT-4 helper-discipline); direct `db.read { ... }` outside `StateStore` is a code-review reject
**And** every access goes through typed methods like `StateStore.fetchMeeting(id:)`, `StateStore.fetchPending()`

**Given** migration #1 has applied
**When** I call `Tests/StateTests/MigrationTests.swift`'s round-trip test
**Then** the migration applies cleanly to an empty DB; `PRAGMA journal_mode` returns `wal`; every column from AR-DATA-1 exists with the correct type and constraints
**And** `Tests/StateTests/ConcurrencyTests.swift` exercises WAL + cross-process write contention with the busy-timeout setting

---

### Story 1.5: Orchestrator + StageRunner + CrashRecovery + RetentionScheduler Scaffold

As the single user,
I want the `Orchestrator` target to wrap every stage execution in the canonical two-transaction pattern, surface stale-active-state synthesis, and recover cleanly on next launch,
So that no stage code path bypasses telemetry, no subprocess crash leaves the chip lying about an in-flight stage, and crash recovery is automatic on relaunch.

**Acceptance Criteria:**

**Given** the `Orchestrator` target
**When** any stage runs
**Then** stage code calls `try await stageRunner.run(stage: .X, meetingId: id) { db in ... return .completed(metadata: ...) }` per AR-PAT-4
**And** `StageRunner.run` writes Txn A (`stage_events.started` + `meetings.state = '<active>'`) before invoking the stage closure, and Txn B (`stage_events.completed|failed` + `meetings.state = '<target>'`) after, per AR-PIPE-3
**And** direct `db.write { ... }` on `meetings` or `stage_events` outside `StageRunner` / `Verifier` / `StateStore` is a code-review reject (per AR-PAT-4)

**Given** an active subprocess crashes between Txn A and Txn B
**When** I run a state machine query `SELECT id FROM meetings WHERE state IN ('transcribing','reviewing_diarization','attributing','summarizing','persisting','published')` on next launch
**Then** the active "_ing" state is the canonical reconciliation signal per AR-PIPE-3
**And** `Orchestrator/CrashRecovery.swift` re-dispatches the stuck stage (idempotent re-run per NFR-R5), except for states whose stage runs in-process (`attributing`, `persisting`, `published`), which it logs without dispatching
**And** orphan `started` rows in `stage_events` from the crashed run are intentionally retained as forensic audit trail

**Given** the Orchestrator's periodic stale-detection sweep runs (every 10s GUI foreground, 60s backgrounded)
**When** a meeting's `meetings.updated_at` is older than the per-stage wall-clock budget per AR-FAIL-2 (`transcribing` 2× NFR-P3, `reviewing_diarization` 90s fixed, `summarizing` 2× NFR-P5, `persisting` 60s fixed, `published` 30s)
**Then** `StageRunner.synthesizeFailure(meetingID:reason:)` is called per AR-FAIL-2
**And** for `reviewing_diarization` stale specifically, the synthesized transition is the **benign-timeout passthrough** to `awaiting_attribution` (empty stub `diarization_suggestions.json` written, `stage_events.failed` row with `error_class='ai_reviewer_timeout'`) — NOT a `*_failed` transition (per Decision 4.2)
**And** for other active states the synthesized transition is to the corresponding `*_failed` state with `error_class='stale_active_state'`
**And** as built, this story ships the sweep's mechanism (`StageRunner.sweepStaleActiveStates`, called directly with an injected clock) and no timer loop; the 10s and 60s driver moved to Story 6.9, together with the launch-time `CrashRecovery.reconcile()` call and the `RetentionScheduler` start (Epic 1 retro SR-4)

**Given** the `Orchestrator` target
**When** the app launches
**Then** `RetentionScheduler` is started as a periodic background task per FR46
**And** it polls `retention_timers WHERE status = 'pending' AND fires_at <= now()` and processes due retentions (full audio cleanup wires in Epic 8; this story ships only the periodic scaffold + interface)

**Given** the Orchestrator API
**When** any caller dispatches a stage
**Then** `SubprocessDispatcher` spawns subprocess stages via `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")` invoking `__internal-stage <stage> <id> --worker-protocol-version 1` per AR-PIPE-7
**And** in-process stages are called directly through the orchestrator's narrow API
**And** `Tests/OrchestratorTests/StageRunnerTests.swift` verifies the two-transaction pattern under both success and failure paths
**And** `Tests/OrchestratorTests/CrashRecoveryTests.swift` simulates the "subprocess crashes between Txn A and Txn B" scenario and asserts crash recovery reconciles correctly

---

### Story 1.6: Telemetry Recorder, StageEventLogger, and StageMetadata

As the single user,
I want telemetry collection to flow through narrow helper APIs (`Telemetry.record(...)`, `StageEventLogger.record(...)`) with typed `StageMetadata` payloads,
So that every stage's structured metadata is captured at deterministic boundaries without scattered SQL writes, and `auricle stats` (Epic 9) can read the same counter columns from day one.

**Acceptance Criteria:**

**Given** the `Telemetry` target
**When** any stage execution completes
**Then** `StageEventLogger.record(event:)` is called via `StageRunner` (no caller writes `stage_events` directly per AR-PAT-4)
**And** the event payload is a `Codable` `StageMetadata` enum case per AR-PAT-2 + Decision 4.5: `case capture(CaptureMeta)`, `case transcribe(TranscribeMeta)`, `case reviewDiarization(ReviewDiarizationMeta)`, `case attribute(AttributeMeta)`, `case summarize(SummarizeMeta)`, `case persist(PersistMeta)`, `case notify(NotifyMeta)`
**And** the per-stage `MetaContent` types use snake_case JSON dialect (matching the SQLite `stage_events.metadata_json` storage convention per AR-PAT-2)

**Given** the `Telemetry` target
**When** any stage completes and contributes telemetry rollup data
**Then** `TelemetryRecorder.record(meetingID:patch:)` performs an UPSERT on the `telemetry` table per AR-DATA-4 write-authority matrix
**And** the **writer-partitioning rule** is enforced: subprocess writers update count/cost/model columns; GUI Attribute writes applied/rejected columns; no column has two writers (per AR-AI-5)
**And** UPSERT pattern is `INSERT INTO telemetry(meeting_id, ...) VALUES (?, ...) ON CONFLICT(meeting_id) DO UPDATE SET <only-this-writer's-columns>`

**Given** any test or stage writes telemetry
**When** I run `Tests/TelemetryTests/StageMetadataRoundTripTests.swift`
**Then** every `StageMetadata` case round-trips losslessly through JSON serialization
**And** the `metadata_schema_version` column on `stage_events` is set on every insert (per Decision 4.5)

**Given** the project lint rules
**When** any source file emits a SQL `INSERT INTO stage_events` or `INSERT INTO telemetry`
**Then** the build is rejected by a custom swiftlint rule (per AR-PAT-4) — only `Telemetry/StageEventLogger.swift` and `Telemetry/TelemetryRecorder.swift` may issue these statements

---

### Story 1.7: CLI Executable Scaffold (`auricle` Binary with Bare-Status + Hidden `__internal-stage`)

As the single user,
I want the `auricle-cli` executable to exist with the swift-argument-parser top-level structure, the bare-invocation status default, and the hidden `__internal-stage` worker subcommand pattern locked in,
So that subsequent epics can add verb implementations without restructuring the CLI surface, and the GUI can spawn subprocess workers from day one.

**Acceptance Criteria:**

**Given** the `auricle-cli` target
**When** `swift build` produces the binary
**Then** the top-level type is an `AsyncParsableCommand` declaring all MVP subcommands as stubs (per AR-PIPE-6): `record`, `stop`, `discard`, `run`, `attribute`, `keep`, `list`, `status`, `config get|set`, `doctor`
**And** every stub subcommand exists as its own file under `App/auricle-cli/Verbs/<VerbName>.swift` and prints "not yet implemented" with exit code 2
**And** the `BareInvocation` default subcommand prints status per Decision 1.5 spec (or "not yet implemented" stub if upstream stages aren't wired) and exits 0

**Given** the CLI scaffold
**When** I invoke `auricle help` or `auricle --help` or `auricle <verb> --help`
**Then** swift-argument-parser's standard help output appears with verb descriptions matching the binding contract per Decision 1.5

**Given** the GUI needs to spawn a subprocess
**When** it invokes `auricle-cli __internal-stage <stage> <id> --worker-protocol-version 1`
**Then** the `InternalStageWorker` subcommand exists at `App/auricle-cli/Verbs/InternalStageWorker.swift` per AR-PIPE-7
**And** `CommandConfiguration` has `shouldDisplay: false` (excluded from `auricle help` output and shell-completion scripts)
**And** the subcommand validates `--worker-protocol-version` matches the current expected version; mismatch exits 2 with structured error
**And** the subcommand is **NOT part of the NFR-I7 binding contract** — it may be renamed/restructured across releases without major-version bump (per AR-PIPE-7)

**Given** the CLI's output conventions
**When** any verb runs to completion (success or failure)
**Then** exit codes follow Decision 1.5: 0 success, 1 user error, 2 state error, 3 not found
**And** default human stdout is plain text with ANSI color only when stdout is a TTY (auto-detected, safely falls back when piped)
**And** default human stderr is one sentence ending with a concrete next action per UX-DR52
**And** `--json` is opt-in (never auto-detected); when used, both stdout (data) and stderr (errors) become JSON; every JSON response carries a top-level `"schemaVersion": <int>` field per Decision 1.5

**Given** the `auricle` binary is built into the `.app` bundle
**When** I inspect `Auricle.app/Contents/MacOS/`
**Then** both `Auricle` (GUI) and `auricle-cli` (CLI) binaries exist in the bundle per AR-DIST-3
**And** the bundle layout matches the architecture's `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")` lookup

---

### Story 1.8: Lint, Format, and CI Enforcement Layer

As the single user,
I want `.swiftformat`, `.swiftlint.yml`, and `.github/workflows/ci.yml` to enforce all 10 helper-bypass primitives (per AR-PAT-4), naming conventions (per AR-PAT-1), JSON dialect rules (per AR-PAT-2), and contract round-trip tests at build time,
So that conformance to the architectural patterns is mechanical, not memorial.

**Acceptance Criteria:**

**Given** the project root
**When** I commit `.swiftformat` and `.swiftlint.yml`
**Then** swiftformat enforces standard Swift API Design Guidelines naming + layout per AR-PAT-1
**And** swiftlint custom rules detect helper-bypass patterns per AR-PAT-4: direct `Data.write(to:)` outside `AtomicWriter.swift`; direct `os_log(` outside `Log.swift`; direct `JSONDecoder().decode(... transcript ...)` outside the canonicalization layer; direct SQL `INSERT INTO stage_events` / `INSERT INTO telemetry` outside the dedicated logger types; direct strategy-instantiation outside composition roots (`AuricleApp.swift`, `auricle-cli/main.swift`, `Tests/TestSupport/TestComposition.swift`)
**And** swiftlint detects missing `accessibilityLabel` on interactive SwiftUI controls per UX-DR65

**Given** `.github/workflows/ci.yml`
**When** a PR opens
**Then** the workflow runs `mise install` (pinned toolchain per AR-INIT-6), `swift build` (verify SwiftPM library compiles), `swift test` (run all library tests including contract tests, snapshot tests, the canonicalization invariant test from Story 1.2), `tuist generate --no-open`, `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build` and `-scheme auricle-cli build` (verify executables compile), `swiftformat --lint` and `swiftlint` (fail on naming, layout, helper-bypass violations)
**And** the workflow fails if `App/Auricle.xcodeproj` is tracked by git (per AR-INIT-4) — a committed generated project is a regression
**And** the workflow fails if `tuist generate` leaves a non-empty `git status` outside the gitignored project — the manifest and the working tree must agree
**And** every job runs in a clean environment; no caching of build artifacts that could mask determinism issues

**Given** the lint discipline
**When** any contract type adds a `Codable` conformance
**Then** a round-trip test (encode → decode → equality) is required per AR-PAT-2; missing tests are a code-review reject (human enforcement, not automated)

**Given** any PR makes a markdown change to a vault-output renderer (Epic 2)
**When** CI runs
**Then** snapshot tests on the rendered markdown verify markdown discipline (no `# ` headers, no headers beyond `### `, no emoji, no horizontal rules outside frontmatter, no tables) per AR-PAT-9 — this CI gate is enabled in Epic 2 but the runner infrastructure ships here in Story 1.8

**Given** Story 1.8 ships
**When** all subsequent stories add their CI gates
**Then** they extend `ci.yml` rather than creating new workflows

---

**Epic 1 summary:**
- **8 stories** sized for single dev-agent completion each
- **All FRs covered:** FR11 (Story 1.5 — crash isolation), FR12 binding scaffold (Story 1.7), FR14 (Story 1.5 — idempotent re-run via two-transaction pattern), FR59 (Story 1.2 — config persistence; as built, `Config` landed after Epic 1 and covers three keys, see Story 1.2's As-built notes), FR61 (Story 1.3 — Log facade), FR62 (Story 1.5 — CrashRecovery), FR66 (Story 1.4 — telemetry SQLite)
- **All architectural commitments addressed:** AR-INIT-1–5 (Story 1.1), AR-PIPE-1–5 (Stories 1.4, 1.5), AR-PIPE-6 scaffold + AR-PIPE-7 + AR-PIPE-8 (Story 1.7), AR-DATA-1–5 (Story 1.4), AR-FAIL-1 + AR-FAIL-2 (Story 1.5), AR-PAT-1–10 (Story 1.8 + woven throughout)
- **Story 1 blocker (Amelia), partly resolved:** the wedge-validation telemetry counter columns are wired into the `telemetry` table in Story 1.4, except `summarization_prompt_set_hash`, which migration #4 (Story 3.7) added along with `grounding_method`
- **No future-story dependencies:** every story is independently completable in sequence; later stories build on earlier ones but no story in this epic requires a future story to function

---

## Epic 2: Vault-Native Note Persistence

Given a synthetic summary JSON, auricle writes a correctly-formatted Obsidian note in the vault — atomic, stable filename, versioned frontmatter schema, never edits existing files. The vault contract is held end-to-end against synthetic summary input; an Obsidian-native note appears at the configured vault path with stable filename and schema-valid frontmatter.

### Story 2.1: FrontmatterRenderer — Data to Markdown with All Schema Variants

As the single user,
I want `Persist/FrontmatterRenderer.swift` to render a `MeetingForFrontmatter` value into a complete vault note (frontmatter + sections + transcript) following the Decision 2.2 schema and AR-PAT-9 markdown discipline,
So that every vault note has stable structure, schema-valid frontmatter, and consistent markdown across all variants (standard / publish-anyway / calendar-failed / re-published / combinations).

**Acceptance Criteria:**

**Given** a `MeetingForFrontmatter` value containing meeting metadata (title, date, attendees as wikilinks, schema version, summary text, action items, decisions, transcript segments)
**When** I call `FrontmatterRenderer.render(meeting:)`
**Then** the output is markdown with: YAML frontmatter under `---` fences carrying exactly the Decision 2.2 schema (title, date, tags, attendees as `[[wikilinks]]`, `auricle:` block with `meeting_id` + `schema_version: 1`); body containing one-paragraph summary, `## Action Items` section with bullets each followed by `> source quote` blockquote, `## Decisions` section with same structure, collapsed `## Transcript` section at the bottom (per FR37)
**And** speakers in summary text are rendered as `[[wikilinks]]` resolvable to existing or to-be-created people-notes (FR38)
**And** frontmatter `attendees` array uses YAML list of `"[[Wikilink]]"` strings (per Decision 2.2)
**And** the `auricle:` block contains only identity/lineage fields (`meeting_id`, `schema_version`, optional `supersedes`) per cross-cutting concern #11 — never operational fields like retention timer state, timing telemetry, or model identifiers
**And** tags array contains `auricle/meeting` baseline; conditional flag tags appear per Decision 2.2 variants (`auricle/needs-attribution`, `auricle/needs-calendar-enrichment`)
**And** this story renders only those two flag tags — `auricle/needs-summary` belongs to the `published_partial` variant, which lands with Story 4.7

**Given** the standard variant (calendar enriched + attribution complete)
**When** I render the meeting
**Then** tags array is `[auricle/meeting]` only; attendees contain real names as `[[wikilinks]]`; speakers in body text are real `[[wikilinks]]`

**Given** the publish-anyway variant (attribution incomplete)
**When** I render the meeting with `Speaker_N` placeholders
**Then** tags array contains `auricle/meeting` AND `auricle/needs-attribution`; speakers in body text and attendees array render as `[[Speaker_1]]`, `[[Speaker_2]]`, etc. (placeholder wikilinks per Decision 2.2)

**Given** the calendar-enrichment-failed variant
**When** I render the meeting
**Then** tags include `auricle/needs-calendar-enrichment`; `title` is the generic form `"Meeting at <ISO8601 local time>"`; `attendees` array is `[]` empty list

**Given** the re-published variant
**When** I render the meeting via the re-publish path
**Then** the `auricle:` block includes a `supersedes: "<original-filename>.md"` field (just the filename, no path — Obsidian resolves wikilink-style per AR-DATA-7)
**And** no special tag is added beyond the standard variant's tags

**Given** any variant
**When** I render the meeting
**Then** markdown discipline holds per AR-PAT-9: section headers use `## ` only (never `# ` — filename owns document title); never beyond `### `; verbatim quotes use `> ` blockquote prefix with single space after `>`; no emoji in functional copy (UX-DR63); no horizontal rules outside frontmatter; no tables; UTF-8 with LF line endings; single trailing newline at end of file
**And** `Tests/PersistTests/FrontmatterRendererTests.swift` runs snapshot tests covering every Decision 2.2 variant + the combination case (publish-anyway + calendar-failed simultaneously)
**And** the renderer's input shape is `MeetingForFrontmatter` — a narrow type that **intentionally excludes** operational fields (cache paths, pipeline timings, cost data, retention timer state, model identifiers, telemetry counters) per cross-cutting concern #11

---

### Story 2.2: FilenameResolver — Slug Priority Chain, Normalization, and Edge Cases

As the single user,
I want `Persist/FilenameResolver.swift` to compute deterministic filenames per AR-DATA-8 with a slug priority chain that gracefully degrades through fallbacks for edge cases (CJK titles, all-emoji titles, missing calendar context),
So that filenames are stable, predictable, and never collide with each other on the same Mac.

**Acceptance Criteria:**

**Given** a `MeetingForFilename` value (capture_started_at + optional calendar event title + optional named attendees + optional self.wikilink)
**When** I call `FilenameResolver.resolve(meeting:)`
**Then** the output is `<YYYY-MM-DD>-<slug>.md` per AR-DATA-8
**And** date is based on `capture_started_at` in the user's local timezone at capture time (NOT UTC — only local-time concession in the system per AR-DATA-8)
**And** the slug is derived via priority chain (try each, fall through if it produces empty/unusable slug): (1) calendar event title; (2) `with-<attendee-1>[-and-<attendee-2>]` for named attendees after removing self-attribution (1:1 with Ben → `with-ben`), each name normalized and capped at 25 characters before joining; one or two names give this slug, zero or more than two fall through; (3) `meeting-at-<HHMM>` generic fallback with 24h local time, 4 digits no separator, which is never empty and so ends the chain

**Given** a calendar event title with accented characters (e.g., `"Café résumé"`)
**When** the slug is computed
**Then** NFKD decomposition strips accents; result is `cafe-resume`; slug source 1 succeeds (per AR-DATA-8 normalization steps)

**Given** a calendar event title with dash punctuation or a non-ASCII space (e.g., `"Q3–Q4 Planning"` with an en dash, or `"a"` + U+00A0 + `"b"`)
**When** the slug is computed
**Then** every Unicode dash (Pd), space separator (Zs, Zl, Zp) and U+2212 becomes a separator before any stripping, so the words on either side stay apart; results are `q3-q4-planning` and `a-b`

**Given** a calendar event title with letters that have no NFKD decomposition (e.g., `"Große Runde"` or `"Æther Œuvre"`)
**When** the slug is computed
**Then** a fixed transliteration table (not `CFStringTransform` or ICU, whose output varies by OS version) maps them to ASCII before NFKD; results are `grosse-runde` and `aether-oeuvre`

**Given** a calendar event title with non-ASCII characters that decompose to nothing (e.g., `"北京会议"` CJK or `"🎉🎉🎉"` all-emoji)
**When** the slug is computed
**Then** NFKD + non-ASCII strip yields empty; resolver falls through to slug source 2 (per AR-DATA-8 fall-through rule)

**Given** a calendar event title with mixed ASCII + emoji (e.g., `"🎉 Launch!"`)
**When** the slug is computed
**Then** NFKD + non-ASCII strip yields `launch`; slug source 1 succeeds

**Given** an extremely long calendar title (e.g., `"This is an extremely long meeting title that exceeds the slug length cap"`)
**When** the slug is computed
**Then** the result is truncated at the last hyphen boundary at or before 60 chars (avoids mid-word cuts); if no hyphen found within 60 chars, hard-cut at 60 (per AR-DATA-8 length cap)

**Given** a same-Mac filename collision (date + identical normalized slug already exists at the resolved path)
**When** I write the new file
**Then** an ordinal counter is appended before `.md` deterministically: `<date>-<slug>-2.md`, `<date>-<slug>-3.md`, etc. (always picks the next available ordinal, never random) per AR-DATA-8
**And** the same-day-collision suffix uses **single hyphen + ordinal** (different axis from re-publish suffix's double-hyphen + date — per AR-DATA-7)

**Given** the test suite
**When** I run `Tests/PersistTests/FilenameResolverTests.swift`
**Then** every edge case from the AR-DATA-8 slug-edge-case table is covered: accented title, CJK title, all-emoji title, mixed emoji+ASCII title, no-calendar+attendees, no-calendar+no-attribution, length-cap truncation, same-Mac collision ordinal counter
**And** all output filenames match the expected values from the example table

---

### Story 2.3: VaultWriter — Atomic Write, Path Resolution, Collision Handling

As the single user,
I want `Persist/VaultWriter.swift` to wrap `Core/AtomicWriter` with vault-path validation, `meetings_subdir` auto-creation, and same-Mac collision detection at write time,
So that every vault write is atomic (NFR-R1), the vault path is validated before publish (per AR-DATA-9), and collisions never produce overwrites.

**Acceptance Criteria:**

**Given** the `Persist` target
**When** I call `VaultWriter.write(_ markdown: String, to relativePath: String)`
**Then** the implementation composes on top of `Core/AtomicWriter` (NEVER bypasses it) per AR-PAT-4 helper-discipline
**And** `vault_path/meetings_subdir/<filename>.md` is the resolved absolute path
**And** the write is atomic via `temp file → fsync → rename` — process-kill at any point leaves the vault consistent (NFR-R1)

**Given** the user's `vault_path` config value
**When** the vault path doesn't exist or isn't writable on launch
**Then** `auricle doctor` (Epic 9) reports it; the CLI surfaces a clear error message with the resolved path and failure reason; **auricle does NOT auto-create the vault** (per AR-DATA-9 — creating someone's vault by accident is a worse failure than refusing to publish)

**Given** the user's `meetings_subdir` config value
**When** the subdirectory doesn't exist as a directory under `vault_path`
**Then** auricle auto-creates it on first publish (auricle owns this subdirectory; auto-creation is safe per AR-DATA-9)
**And** permissions inherit from `vault_path`
**And** if `meetings_subdir` exists as a file rather than directory, the write fails fast with a clear error
**And** if `meetings_subdir` exists as a directory but is not writable, the write fails fast with a clear error

**Given** the resolved filename from Story 2.2
**When** a same-Mac collision is detected at write time (file already exists at the target path AND this is NOT a re-publish path)
**Then** `VaultWriter` consults `FilenameResolver` to apply the deterministic ordinal counter (`-2`, `-3`, etc. per AR-DATA-8)
**And** the new filename is the one returned by the resolver, written atomically; the original file is untouched

**Given** the persist stage's NFR-P8 budget (≤500ms for ≤50KB markdown)
**When** I run `Tests/PersistTests/VaultWriterTests.swift` performance assertion
**Then** the atomic-write completes in ≤500ms for a 50KB markdown payload on the reference hardware
**And** other tests cover: vault-path-missing failure path, subdir-as-file failure path, subdir-as-non-writable-directory failure path, successful auto-create, collision counter, atomic-write under simulated process-kill

**Given** any caller in the codebase
**When** they need to write to the vault
**Then** they MUST call into `VaultWriter` (per AR-PAT-4); direct writes anywhere under `vault_path/meetings_subdir/` are detected by a custom swiftlint rule and the build is rejected
**And** `VaultWriter` itself never opens an existing vault file for write (NFR-R2 + DP4 + FR36) — verified by lint rule and by a unit test that asserts the open mode

---

### Story 2.4: Persist Stage Entry Point — Compose Renderer + Writer + Re-publish Semantics

As the single user,
I want `Persist/PersistStage.swift` to compose `FrontmatterRenderer` + `FilenameResolver` + `VaultWriter` into the canonical `auricle persist <id>` stage entry point, including re-publish semantics with deterministic suffix generation per AR-DATA-7,
So that the stage produces exactly one new vault note per execution, never edits existing files, and re-publication writes a sibling file with `auricle.supersedes` linkage.

**Acceptance Criteria:**

**Given** a meeting in the `persisting` → `published` transition
**When** `PersistStage.run(meetingId:)` executes
**Then** the stage reads `summary.json` from cache-dir, fetches the `Meeting` row from SQLite via `StateStore`, constructs a `MeetingForFrontmatter` value, calls `FrontmatterRenderer.render(meeting:)` → markdown, calls `FilenameResolver.resolve(meeting:)` → filename, calls `VaultWriter.write(markdown, to: filename)`, and updates `meetings.vault_note_path` to the canonical absolute path
**And** the stage transitions `meetings.state` from `persisting` → `published` via `StageRunner` (Txn A on entry, Txn B on completion) per AR-PIPE-3
**And** a `stage_events` row is written with `stage='persist'`, `event='completed'`, `metadata_json` containing `{"vault_note_path": "...", "frontmatter_schema_version": 1}` per Decision 4.5

**Given** a meeting passing `auricle run <id> --reattribute` (or any other re-publish path)
**When** `PersistStage.run(meetingId:...)` executes
**Then** the stage is not told whether this is a re-publish; it derives that from the stored note: a run is a re-publish exactly when `meetings.vault_note_path` is set and the file still exists at that path
**And** if the stored note does not exist (never published, or the user deleted it), the stage falls back to a fresh-publish path (no rerun suffix, standard filename per Decision 2.4)
**And** before that fallback, when `meetings.vault_note_path` is recorded but names a file that no longer exists (the user renamed or moved the note in Obsidian), the stage looks for the meeting's note by identity: it scans the configured meetings folder recursively for `.md` files, reads only each file's frontmatter (the first 8 KB), and treats a file whose `auricle.meeting_id` equals the meeting's as the stored note, so the re-run supersedes it by its new filename
**And** files that are unreadable, not UTF-8, not auricle notes, or rejected by `FrontmatterReader` are skipped; when several files match (an original and its re-runs) the one no other match lists in `auricle.supersedes` is used, then the most recently modified; the scan stops after 5000 files and logs a warning; only when nothing matches is the run a fresh publish; a meeting with no recorded `meetings.vault_note_path` is a fresh publish from the start and never scans
**And** a re-run is written into the configured meetings folder, with `vault_path` validated and `meetings_subdir` resolved exactly as a fresh publish does, even when the stored or found note is in another folder; a stored path that names an existing file still counts as the predecessor wherever it lives, and `auricle.supersedes` stays the predecessor's filename only
**And** if the stored note exists and differs from what this run renders, the stage constructs a re-run filename per AR-DATA-7: `<original-filename-without-ext>--rerun-<YYYY-MM-DD>.md` using user's local timezone date
**And** for multiple re-runs on the same calendar day, the counter is appended: `--rerun-<YYYY-MM-DD>-2.md`, `--rerun-<YYYY-MM-DD>-3.md`
**And** the re-run note's frontmatter includes `auricle.supersedes: "<original-filename>.md"` (just the filename, no path)
**And** `meetings.vault_note_path` is updated to point at the re-run note (latest publish becomes canonical for `auricle status` lookups)
**And** the original vault note is **never modified** by auricle (DP4 + FR36 + NFR-R2 — verified by file-mtime invariance test)

**Given** a meeting that has been published more than once
**Then** every historical publish path is reconstructible from the `stage_events` rows where `stage='persist'` and `event='completed'` for that meeting (forensic audit trail; not first-class queryable per AR-DATA-7)

**Given** the persist stage runs idempotently per NFR-R5
**When** I re-run the persist stage on content unchanged since its last publish, including a re-run after a crash or a failed `meetings.vault_note_path` update that left the note on disk
**Then** the vault is left unchanged: no file is written, no ordinal-suffixed or re-run duplicate appears, and `meetings.vault_note_path` still names the same note
**And** Txn B commits cleanly without errors
**And** output identical to a file already in the vault is reused, never duplicated: a stored note whose bytes equal this run's rendering is kept as it stands (a stored re-run is compared against a rendering that carries its own `auricle.supersedes`); a stored note that differs (new summary, re-attribution, or a hand edit in Obsidian) gets a `--rerun-` sibling, and a re-run candidate that already holds the same bytes is reused instead of taking the next counter; a fresh publish whose target filename already holds the same bytes returns that path instead of the next ordinal
**And** the stage never opens an existing vault file for writing; the rendering is deterministic, so identical inputs give identical bytes

---

### Story 2.5: Frontmatter Schema Versioning + Migration-Aware Reader

As the single user,
I want `auricle.schema_version` to be required and stable forever per Decision 2.2 + AR-DATA-6 + NFR-I4, and a migration-aware reader for the `--reattribute` path that fail-fasts on unknown versions,
So that future readers can correctly interpret older notes (FR41 `auricle:` block contract) and forward-incompatible reads (note from a future auricle version on an older binary) are caught with a clear error.

**Acceptance Criteria:**

**Given** any vault note rendered by `FrontmatterRenderer` (Story 2.1) per FR41
**When** I parse its frontmatter
**Then** the `auricle.schema_version: 1` field is present and required (per Decision 2.2 + NFR-I4 — the field name itself never changes; this is the bootstrap that enables future readers)

**Given** the `Persist` target
**When** `auricle run <id> --reattribute` runs and the persist stage needs to read the existing frontmatter to know which speakers were already named
**Then** the migration-aware reader inspects `auricle.schema_version` first per Decision 2.2
**And** dispatches to a version-specific parser (only v1 in MVP)
**And** if the version is older than any ever-shipped value, fail-fast with a clear error pointing to the earliest auricle version capable of reading that note
**And** if the version is newer than the current binary supports (forward-incompatible read), fail-fast with a clear error indicating the user's auricle versions are out of sync across personally-owned Macs

**Given** a v1 frontmatter being read
**When** the v1 parser encounters an unknown field under `auricle:` (e.g., a future additive field)
**Then** the field is silently ignored (additive changes within a major version; consumers ignore unknown fields per Postel's law per Decision 2.2)
**And** the parser does NOT bump schema_version on read

**Given** `Tests/PersistTests/FrontmatterReaderTests.swift`
**When** I run the test suite
**Then** test fixtures cover: valid v1 frontmatter; v1 frontmatter with unknown additive fields (must parse cleanly); pretend-v0 frontmatter (must fail-fast with version-too-old error); pretend-v999 frontmatter (must fail-fast with version-too-new error); missing `auricle.schema_version` (must fail-fast with "not an auricle note" error)

---

**Epic 2 summary:**
- **5 stories** sized for single dev-agent completion
- **All FRs covered:** FR26 (Story 2.4 — auricle never re-edits), FR35 (Story 2.4), FR36 (Story 2.3 — atomic write), FR37 (Story 2.1), FR38 (Story 2.1), FR39 (Story 2.1), FR40 (Story 2.2), FR41 (Story 2.1)
- **NFRs primarily verified:** NFR-R1 (Story 2.3), NFR-R2 (Story 2.3 + 2.4), NFR-R7 persist-side hard gate (consumed downstream by Epic 3), NFR-P8 (Story 2.3), NFR-S4 (Story 2.3), NFR-I3 (frontmatter compatible with Obsidian URL scheme), NFR-I4 (Story 2.5)
- **All architectural commitments addressed:** AR-DATA-6 (Stories 2.1, 2.5; the `auricle/needs-summary` tag is Story 4.7), AR-DATA-7 (Story 2.4 re-publish; the re-publish notification text is Story 4.9), AR-DATA-8 (Story 2.2), AR-DATA-9 (Story 2.3 vault path validation), AR-PAT-9 (Story 2.1 markdown discipline)
- **No future-story dependencies:** every story is independently completable in sequence

---

## Epic 3: Quote-Grounded Summarization Engine

Given a `CanonicalTranscript` + glossary + calendar event, auricle produces a validated `SummaryWithGrounding` with quote-grounded action items + decisions, dropping items that fail validation. Calendar enrichment + vault-glossary builder ship here as inputs. Includes the Decision 3.6 smoke-test (one-time go/no-go default selection) **and** an explicit eval harness (frozen transcripts + regression tests per Mary's review).

### Story 3.1: SummarizerInterface — Protocol + Normalized SummaryWithGrounding Output

As the single user,
I want `SummarizerInterface` to declare the `SummarizerStrategy` protocol and the normalized `SummaryWithGrounding` output shape that all concrete strategies (Citations, substring, future local-LLM) produce identically,
So that the renderer downstream is grounding-method-agnostic and substituting one strategy for another genuinely produces equivalent behavior (LSP per AR-PAT-7).

**Acceptance Criteria:**

**Given** the `SummarizerInterface` target (protocol-only)
**When** I declare `SummarizerStrategy`
**Then** the protocol exposes exactly: `func summarize(transcript: CanonicalTranscript, glossary: Glossary, config: SummarizerConfig) async throws -> SummaryWithGrounding` per AR-SUM-1
**And** the protocol does NOT expose any method that takes a `Meeting` value (interface-segregation per AR-PAT-7 — strategies don't peek at unrelated fields)

**Given** the `SummaryWithGrounding` value type
**When** I inspect its structure
**Then** it carries: `schemaVersion: Int = 1`, `summary: String` (one-paragraph narrative), `actionItems: [GroundedItem]`, `decisions: [GroundedItem]`, `groundingMethod: GroundingMethod`, `cost: SummarizerCost` per AR-SUM-1
**And** `GroundedItem` has `text: String` + `grounding: GroundingPointer` (always the normalized shape regardless of which strategy produced it)
**And** `GroundingPointer` has `transcriptStart: Int` + `transcriptEnd: Int` (UTF-8 byte offsets into the canonical transcript per Decision 3.4 — auricle's own unit, not an echo of an API convention) + `sourceMethod: GroundingMethod` (telemetry only, NOT a control flag for downstream code)
**And** `GroundingMethod` enum is `.citations` or `.substring`
**And** there is **no separate "raw response" field** in any contract type — strategies translate from their own raw API output to the normalized shape inside their own implementation per AR-SUM-1

**Given** the `SummarizerError` typed error enum
**When** any strategy throws
**Then** the typed errors that drive Decision 3.3 fallback are: `.citationsUnavailable`, `.malformedResponse`, `.rateLimited`, `.featureToggleDisabled`
**And** errors that should NOT trigger fallback (network timeouts, auth errors, quota/billing errors) have their own non-fallback-eligible cases
**And** every case carries an `isFallbackEligible: Bool` computed property used by `SummarizerOrchestrator` per Decision 3.3

**Given** the `SummarizerConfig` value type
**When** I inspect its structure
**Then** it carries: model identifier (default `claude-opus-5` per NFR-I6), effort level (`low`/`medium`/`high`/`xhigh`/`max` — named levels only; the current API has no numeric-budget override), Anthropic API key reference (read at call time from Keychain — never carried in the value), prompt-caching enabled flag, remaining-cost-budget hint (passed to fallback strategy by orchestrator per Decision 3.3)

**Given** the `SummarizerInterface` target
**When** any test or composition root depends on it
**Then** the target is protocol-only — no concrete implementations live here; concrete strategies live in `ClaudeSummarizer` and (v1.1+) future local-LLM targets per AR-PAT-5

---

### Story 3.2: SummarizationPromptBuilder — File-Backed Prompt Set + Glossary Injection + Drift Snapshot Tests

As the single user,
I want `Summarize/SummarizationPromptBuilder.swift` to **compose** the prompt from markdown files on disk rather than assembling it from Swift string literals — a shipped default set in-repo plus an optional user override directory — with snapshot tests over the shipped set,
So that I can change how my notes are summarized by editing a file instead of editing Swift and rebuilding, while the equivalence guarantee between the two strategies survives where it means something.

**Acceptance Criteria:**

**Given** the `Summarize` target
**When** I call `SummarizationPromptBuilder.build(transcript:, glossary:, attendees:, mode: .citations | .substring, promptDir:)`
**Then** the builder generates: a stable system prompt declaring the rules per Decision 3.5 (every action item assigned to a specific person; every item supported by a verbatim quote; omit items without verbatim grounding; use glossary spellings; output one-paragraph summary then arrays); a glossary block in `[[wikilink]]` form (matches vault rendering, reduces post-processing); attendee context formatting; the transcript itself
**And** the **shared portions** (system prompt, glossary, attendee context) are byte-identical between the two modes — **structurally, because both modes read the same `system.md`**, not because a test compares two code paths
**And** the **mode-specific portions** differ only in: Citations mode adds *"Use Anthropic Citations to ground each item"*; substring mode adds *"Each item must include a `source_transcript_quote` field reproducing the exact transcript text, character-for-character including punctuation. Do not normalize, expand contractions, or remove disfluencies."*

**Given** the prompt-caching strategy per AR-SUM-5
**When** the prompt is constructed
**Then** the system prompt + glossary + attendee context all use Anthropic `cache_control` blocks (cached for the session)
**And** the transcript is NEVER cached (unique per meeting)
**And** the `cache_control` markers are placed between glossary and transcript so glossary caches but the transcript is fresh per call

**Given** the glossary value
**When** the builder injects it
**Then** the glossary appears as a structured block: *"Glossary (terms from your vault, prefer these spellings):"* followed by categorized lists (`People`, `Projects`, `Concepts`) per Decision 3.5
**And** glossary terms are wrapped in `[[wikilink]]` form even in the prompt
**And** glossary token counts are bounded (~200 tokens typical when scoped per FR56; Story 3.12 enforces scoping)

**Given** the two-tier prompt set
**When** the builder resolves which files to read
**Then** the **shipped default set** lives in-repo and is bundled with the build: `Prompts/summarize/system.md`, `citations.md`, `substring.md`
**And** the **user override set** lives at `~/.auricle/prompts/summarize/` per FR59, resolved from `summarization.prompt_dir` (FR58), and is used file-by-file when present
**And** `auricle summarize <id> --prompt-dir <path>` overrides both for a single run — this is the prompt-iteration loop, and it needs no rebuild
**And** the override directory is **never** read by the test suite

**Given** the build-time snapshot tests
**When** I run `Tests/SummarizeTests/PromptBuilderSnapshotTests.swift`
**Then** snapshots in `Tests/SummarizeTests/Snapshots/prompts/` capture both modes' composed output against a canned `(transcript, glossary, attendees)` fixture, **using the shipped default set only**
**And** the test asserts the composed output matches the snapshot, catching unintended changes to the shipped prompts
**And** the snapshots are regenerated only when an explicit prompt change is made (not auto-overwritten in CI)
**And** the test does **not** attempt to assert byte-identity between the two modes' shared portions — that property is now structural (one file, read twice) rather than a thing two code paths could violate
**And** a golden-file test is never pointed at the user override directory: a test over a file the user edits fails on every edit, which is friction on the loop the test exists to guard

**Given** prompt provenance (Decision 3.2 / Decision 3.7)
**When** the builder finishes composing
**Then** it computes a SHA-256 over the resolved prompt files and returns it alongside the prompt
**And** the hash is written to `telemetry.summarization_prompt_set_hash` by the summarize stage (Story 3.7) and surfaced by `auricle status <id>`
**And** `auricle doctor` (Epic 9) warns when `summarization.prompt_dir` points at a directory that is not under version control — a hash whose bytes were never kept is worse than no hash, because it looks like an answer

---

### Story 3.3: AnthropicHTTPClient + KeychainAPIKey + Retry/Backoff

As the single user,
I want a single `ClaudeSummarizer/AnthropicHTTPClient.swift` that wraps `URLSession` with retry/backoff per NFR-R9, response-body redaction at the boundary, and `KeychainAPIKey` for secret access,
So that all Anthropic API consumers (`ClaudeCitationsSummarizer`, `ClaudeSubstringSummarizer`, `ClaudeDiarizationReviewer`, future `ClaudeTranscriptionReviewer`) share one HTTP layer with consistent failure semantics.

**Acceptance Criteria:**

**Given** the `ClaudeSummarizer` target
**When** any caller invokes `AnthropicHTTPClient.send(_ request: AnthropicRequest)`
**Then** the client constructs an HTTPS request to the Anthropic Messages API with TLS 1.2+ certificate validation per NFR-S5
**And** the API key is read from Keychain at call time via `KeychainAPIKey` (never cached in memory beyond the request lifetime, never read from disk or env vars per NFR-S1)
**And** on 429 / 5xx / network timeout, the client retries with exponential backoff `1s → 2s → 4s → 8s → 16s` up to a configurable total budget (default 5 minutes per NFR-R9)
**And** typed `SummarizerError` is thrown for terminal failures (`.rateLimited`, `.malformedResponse`, `.citationsUnavailable`, etc. per Decision 3.3)
**And** auth errors and quota/billing errors are NOT retried (they require user action — surface immediately)

**Given** any HTTP response
**When** the client logs anything about the response
**Then** **only redacted metadata** is passed to the `Log` facade: status code, token counts (input/output/thinking), cost USD, model identifier — NOT the response body itself per NFR-S7 + Story 1.3
**And** API keys, OAuth tokens, and Anthropic response bodies are never passed to the `Log` facade in any form (scrubbed at this client layer)

**Given** the `KeychainAPIKey` helper
**When** I call `KeychainAPIKey.read()` or `.write(_ key: String)`
**Then** the value is stored as `kSecClassGenericPassword` per NFR-S1
**And** the service identifier is stable: `com.auricle.app.anthropic-api-key`
**And** if the key is missing, `KeychainAPIKey.read()` throws a typed `KeychainError.notFound` — surfaced to the user via `auricle doctor` (Epic 9) and to the J0 banner (UX-DR55) when AI review needs the key

**Given** the user agency requirement on retries (Sally's UX from Decision 4.2)
**When** a retry is in flight via SIGINT-aware path
**Then** the client honors `Task.cancellation` — when canceled mid-retry, the in-flight HTTP request is canceled and the next backoff sleep aborts; the outer `auricle run <id>` exits with code 130 per UX-DR53

**Given** the test suite
**When** I run `Tests/ClaudeSummarizerTests/` against a stubbed Anthropic responder
**Then** tests cover: successful request → typed response; 429 → retry with backoff → eventual success; persistent 5xx → terminal `summarization_failed` with `SummarizerError.rateLimited`; auth error → no retry, immediate throw; cancellation mid-retry; redaction (no response body in logs)

---

### Story 3.4: ClaudeSubstringSummarizer + SubstringGroundingValidator

As the single user,
I want `ClaudeSummarizer/ClaudeSubstringSummarizer.swift` to implement the `SummarizerStrategy` protocol via free-form quote string + literal substring match validation,
So that the substring path serves as both the v1.1+ local-LLM path's contract (FR33) and the automatic fallback path when Citations is unavailable (FR32 + Decision 3.3).

**Acceptance Criteria:**

**Given** the `ClaudeSubstringSummarizer` value
**When** I call `summarize(transcript:, glossary:, config:)`
**Then** the implementation calls `messages.create` on `claude-opus-5` (default per NFR-I6) via `AnthropicHTTPClient` from Story 3.3 with the prompt from `SummarizationPromptBuilder.build(..., mode: .substring)` from Story 3.2
**And** the response JSON shape requested includes `summary`, `action_items[]` (each with `text` + `source_transcript_quote: String`), `decisions[]` (same shape)
**And** each returned `source_transcript_quote` is mapped to a `GroundingPointer { transcriptStart, transcriptEnd, sourceMethod: .substring }` by `SubstringGroundingValidator.validate(quote:in:)`

**Given** `SubstringGroundingValidator`
**When** I call `validate(quote: String, in: CanonicalTranscript)`
**Then** the validator performs literal substring search in the canonical NFC-normalized transcript per AR-SUM-4
**And** if the quote is not found verbatim, the item is **dropped** with the reason logged at `warn` level and `telemetry.quote_validation_drop_count` incremented per NFR-R7
**And** if the quote is found, `transcriptStart` / `transcriptEnd` are UTF-8 byte offsets into the NFC-normalized representation (per Decision 3.4 — the same character space the Citations strategy's block-index mapping resolves into)

**Given** the strategy returns
**When** the orchestrator inspects the result
**Then** every `GroundedItem.grounding.sourceMethod == .substring`
**And** the `cost: SummarizerCost` reflects actual Anthropic-reported tokens + cost; for future local-LLM impls the cost is `0` per Decision 5.6 telemetry contract

**Given** the test suite
**When** I run `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift` against stubbed Anthropic responses
**Then** tests cover: clean response with all quotes substring-valid → all items survive; response with mixed valid/invalid quotes → invalid items dropped, valid items survive, drop count logged; response with structurally malformed JSON → `SummarizerError.malformedResponse` thrown; response with empty array → empty `GroundedItem[]` returned (not an error)

---

### Story 3.5: ClaudeCitationsSummarizer + CitationGroundingValidator + Canonicalization Invariant Tests

As the single user,
I want `ClaudeSummarizer/ClaudeCitationsSummarizer.swift` to implement the `SummarizerStrategy` protocol per AR-SUM-1 + AR-SUM-2 + AR-SUM-4 via Anthropic's Citations API with build-time canonicalization invariant tests,
So that Citations grounding exists as a tested strategy for FR29 (the Decision 3.6 outcome, locked in Story 3.8, made substring the MVP default instead); FR30 grounding-validation hard gate via `CitationGroundingValidator`; FR31 default Anthropic Claude API summarizer; FR32 single primary call with optional fallback (per Decision 3.3 + Story 3.6); NFR-R7 quote-grounding hard gate enforcement; the dual-strategy approach is genuinely robust — not silently divergent on offset semantics.

**Acceptance Criteria:**

**Given** the `ClaudeCitationsSummarizer` value
**When** I call `summarize(transcript:, glossary:, config:)`
**Then** the implementation calls `messages.create` on `claude-opus-5` with the transcript provided as a Document with `citations: { enabled: true }` per Decision 3.2
**And** the prompt is from `SummarizationPromptBuilder.build(..., mode: .citations)` from Story 3.2
**And** the transcript is submitted as a **custom content document** (`source.type == "content"`), one content block per utterance, using the same segmentation `CanonicalTranscript` carries
**And** the structured JSON is requested **by prompt instruction, not `output_config.format`** — the Messages API returns 400 for citations plus `output_config.format` (*"Citations cannot be enabled when output format is set"*), while the prompt-instruction route returns both in one call
**And** the response includes Anthropic-constructed `content_block_location` objects with `start_block_index` / `end_block_index` (zero-indexed, exclusive end)
**And** each block index is mapped to that utterance's `[start, end)` character range in the canonical transcript, producing a `GroundingPointer { transcriptStart, transcriptEnd, sourceMethod: .citations }` via `CitationGroundingValidator.validate(citation:in:)`

**Given** `CitationGroundingValidator`
**When** I call `validate(citation: CitationBlockLocation, in: CanonicalTranscript)`
**Then** the validator sanity-checks bounds: `start_block_index >= 0`, `end_block_index <= transcript.utteranceCount`, `start_block_index < end_block_index`
**And** a block index out of range is a malformed response, not a clamp — auricle segmented the document, so an out-of-range index means the response does not describe what was sent
**And** well-formed Citations responses always pass — a block index is valid by construction when the response describes the document auricle sent; unlike a character offset, there is no encoding convention that could make a well-formed response unmappable
**And** if Anthropic returns a malformed Citations response (empty array when items are present, out-of-bounds offsets, structurally bad payload), the validator throws `SummarizerError.malformedResponse` (triggers fallback per Decision 3.3)
**And** if Anthropic returns no Citations data when Citations was requested, throws `SummarizerError.citationsUnavailable` (triggers fallback)

**Given** the canonicalization invariant test (`Tests/CoreTests/CanonicalTranscriptContractTests.swift` from Story 1.2 — extended here)
**When** I run the test suite
**Then** the invariants hold per Decision 3.4: same `CanonicalTranscript` value serialized to JSON and re-deserialized produces byte-identical text; the API-submission representation matches the on-disk representation; the substring validator's offset interpretation matches the Citations validator's offset interpretation
**And** **build fails if these invariants are violated**

**Given** the cross-mode fixture test (`Tests/SummarizeTests/CrossModeFixtureTests.swift`)
**When** I run the test suite
**Then** golden transcript fixtures with hand-curated expected items run through BOTH grounding strategies (Citations and substring) with stubbed LLM responses producing equivalent content via different shapes
**And** the test asserts byte-identical renderer output (downstream of grounding-method-agnostic rendering)
**And** **build fails if the two strategies' renderer outputs diverge** per Decision 3.4

**Given** Anthropic's API spec
**When** the implementation runs
**Then** UTF-8 byte offset is the canonical encoding (verified at implementation time per Decision 3.4 — if Anthropic uses a different convention like UTF-16 code units, codepoints, or graphemes, the canonical representation includes a translation step in `CanonicalTranscript`)
**And** the verify-at-implementation step is documented as a per-stage `verify` item per Decision 4.5

---

### Story 3.6: SummarizerOrchestrator — Primary/Fallback Wiring

As the single user,
I want `Summarize/SummarizerOrchestrator.swift` (a Swift `actor`) to mediate between primary and fallback strategies per Decision 3.3, NOT in-strategy retry,
So that strategies stay single-responsibility (SOLID-I per AR-PAT-7) and never know about each other, and the fallback decision lives in one place.

**Acceptance Criteria:**

**Given** the `Summarize` target
**When** I instantiate `SummarizerOrchestrator(primary: ClaudeCitationsSummarizer, fallback: ClaudeSubstringSummarizer)`
**Then** the orchestrator is a Swift `actor` per AR-PAT-6
**And** strategies are dependency-injected from the composition root (`AuricleApp.swift` or `auricle-cli/main.swift`) per AR-PAT-5; never instantiated inside the orchestrator

**Given** an orchestrator call
**When** primary strategy succeeds
**Then** the orchestrator returns the primary's `SummaryWithGrounding` and records `telemetry.grounding_method = .citations` per Decision 4.5

**Given** an orchestrator call
**When** primary throws a fallback-eligible error (`SummarizerError.citationsUnavailable`, `.malformedResponse`, `.rateLimited`, `.featureToggleDisabled`)
**Then** the orchestrator records `telemetry.fallback_triggered` with the original error class
**And** invokes the fallback strategy with a remaining-cost-budget hint (NFR-C1 cost ceiling applies across primary + fallback per Decision 3.3)
**And** records `telemetry.grounding_method = .substring` if fallback succeeds

**Given** an orchestrator call
**When** primary throws a non-fallback-eligible error (network timeout, auth error, quota/billing error)
**Then** the orchestrator re-throws without invoking fallback (network timeouts handled by Decision 4.2 retry policy at HTTP layer; auth/quota surface to user)

**Given** fallback is invoked
**When** fallback also fails
**Then** the orchestrator throws `SummarizerError` and the meeting transitions to `summarization_failed` per Decision 4.1 (transient failure category, queues for resume per `auricle run <id>`)
**And** fallback is bounded to **one attempt** per Decision 3.3 (no chain-of-fallbacks)

**As built:** the composition root (`auricle-cli`) instantiates `SummarizerOrchestrator(primary: ClaudeSubstringSummarizer())` with no fallback, per the Decision 3.6 outcome. The primary-plus-fallback behavior above stays implemented and is tested against stub strategies; the criteria that name `ClaudeCitationsSummarizer` as primary describe that tested arrangement, not the shipped one.

**Given** the test suite
**When** I run `Tests/SummarizeTests/SummarizerOrchestratorTests.swift` against stub strategies
**Then** tests cover: primary-succeeds (no fallback invocation, correct telemetry); primary-throws-fallback-eligible-fallback-succeeds (correct telemetry: `grounding_method=.substring`, `fallback_triggered=true`); primary-throws-fallback-eligible-fallback-fails (terminal `summarization_failed`); primary-throws-non-fallback-eligible (re-thrown without fallback invocation)

---

### Story 3.7: Summarize Stage Entry Point + Cache-Dir Handoff

As the single user,
I want `Summarize/SummarizeStage.swift` to be the subprocess entry point for the summarize stage, composing the orchestrator + glossary builder + calendar source + writing `summary.json` to cache-dir per AR-PIPE-4,
So that the stage runs as a subprocess (per AR-PIPE-1 — heavy isolation needed for network call hangs) and integrates with the state machine.

**Acceptance Criteria:**

**Given** the `Summarize` target
**When** `auricle-cli __internal-stage summarize <id> --worker-protocol-version 1` is invoked
**Then** the subprocess loads `transcript.json` (immutable per AR-PIPE-4 cache-dir handoff), reads `attribution.json`, fetches `calendar.json` (Story 3.11 — or the unenriched fallback), builds the glossary (Story 3.12), invokes `SummarizerOrchestrator.summarize(...)` from Story 3.6, validates groundings, writes `summary.json` atomically via `Core/CacheArtifactWriter` per AR-PAT-4
**And** `summary.json` carries `schema_version: 1` per AR-PIPE-4

**Given** the stage execution
**When** the orchestrator returns a `SummaryWithGrounding`
**Then** `telemetry` is updated via UPSERT per the write-authority matrix from AR-DATA-4: `summarization_path = "claude_api"`, `summarization_model = "claude-opus-5"`, `summarization_effort_budget = "medium"` (or whatever was actually used), `cost_usd`, `quote_validation_drop_count`, `grounding_method` per Decision 4.5
**And** a `stage_events` row is written with `stage='summarize'`, `event='completed'`, `metadata_json` containing `{model_id, effort_budget, input_tokens, output_tokens, thinking_tokens, cost_usd, quote_validation_drop_count, grounding_method}`

**Given** the stage execution
**When** orchestrator throws `summarization_failed` (transient)
**Then** the subprocess exits with the appropriate exit code per Decision 1.5 (state error = 2)
**And** `meetings.state` transitions to `summarization_failed` per Decision 4.1 (queues for resume)
**And** the `auricle run <id>` retry path can resume from `summarization_failed` without re-running upstream stages (transcribe / diarize artifacts in cache-dir are immutable per AR-PIPE-4)

**Given** the canonicalization invariant from Story 3.5
**When** the `CanonicalTranscript` is loaded from `transcript.json`
**Then** the same canonical representation is used for: API submission, substring validation, renderer extraction (`transcript[start..<end]`) — verified by Story 3.5's contract test

**Given** the stage runs idempotently per NFR-R5
**When** I re-run a successfully-completed summarize stage
**Then** the second run overwrites `summary.json` atomically via temp+rename
**And** the LLM call is non-deterministic (modulo API behavior) but the renderer extraction is deterministic given a fixed `summary.json` per Decision 4.5 idempotency framing

---

### Story 3.8: Decision 3.6 Smoke-Test Execution + Decision-Rule Lock-In

As the single user,
I want the smoke-test protocol per Decision 3.6 to execute as the FIRST hour of Story 3.x's implementation work, picking the MVP default validator (Citations or substring) before dogfood begins — **with the comparison axis parameterised rather than hard-coded to "strategy"**,
So that the default-validator choice is made empirically against real captured meetings, and the same rig later answers *"is prompt B better than prompt A on my meetings?"* without being rewritten.

**Acceptance Criteria:**

**Given** the smoke-test fixture set
**When** I assemble inputs per Decision 3.6
**Then** ≥5 of the user's existing meeting recordings are transcribed via WhisperKit (placed under `tests/fixtures/smoke-test-transcripts/` or a path-referenced env var per NFR-M5)
**And** the mix includes ≥1 1:1 (≤3 attendees) AND ≥1 multi-party (≥4 attendees)
**And** the remaining 3+ are any mix

**Given** the smoke-test runs
**When** I execute `tests/scripts/run-smoke-test.sh` (or equivalent)
**Then** each transcript runs through `ClaudeCitationsSummarizer` AND `ClaudeSubstringSummarizer` in parallel via the same `SummarizationPromptBuilder` from Story 3.2
**And** outputs are scored on: drop rate (each strategy's `quote_validation_drop_count`); recall (items present in the user's memory of the meeting that survived to rendered output); precision (false-keeps — items the validator accepted that don't represent real commitments); cost per call including extended-thinking tokens; qualitative "did the grounded quote read sensibly when rendered as `> source quote`?"

**Given** the default-flip rule per Mary's amendment in Decision 3.6
**When** I evaluate the smoke-test results
**Then** Citations is locked as MVP default IF Citations matches or beats substring on every transcript
**And** the default flips to substring IF substring catches anything Citations missed (any false-drop, any recall miss) on any transcript in the smoke-test set (trust-asymmetry: cost of one missed commitment in dogfood >> cost of running with a slightly-less-capable validator that doesn't drop real items)

**Given** the smoke-test outcome
**When** the default is picked
**Then** the composition root (`AuricleApp.swift` and `auricle-cli/main.swift`) wires `SummarizerOrchestrator(primary:, fallback:)` accordingly: if Citations wins, primary is `ClaudeCitationsSummarizer` and fallback is `ClaudeSubstringSummarizer`; if substring wins, primary is `ClaudeSubstringSummarizer` and there's no fallback strategy (or fallback is omitted entirely — to be decided based on the specific failure mode that flipped the default)
**And** smoke-test results are recorded at `Tests/fixtures/strategy-comparison-results.md`: which transcripts were used, the metric scores per transcript, and the rationale for the default-validator choice
**And** **both strategy implementations ship at MVP regardless of outcome** — substring is required for FR33's v1.1+ local-LLM path (per Decision 3.6)

**Given** a future maintainer
**When** Anthropic ships new Citations behavior or prompt design evolves
**Then** the smoke-test set can be re-run via the same script with the same fixtures; the outcome documentation pattern allows comparing across runs

---

### Story 3.9: Pipeline Regression Harness — Frozen Transcripts + Stubbed Responses

As the single user,
I want `Tests/SummarizeTests/Fixtures/eval/` with frozen transcripts + expected-quote-grounding assertions running on every PR via CI,
So that regressions in the **validator, mapping, and renderer** are caught by automation before Epic 4 layers on real audio.

**Scope note — this harness does not measure prompt quality, and must not be extended to.** Its acceptance criteria specify *stubbed* Anthropic responses: the same fixture returns the same bytes regardless of what the prompt says, so a prompt change cannot move it. That determinism is the point and is what keeps it CI-safe per NFR-M5 and budget hygiene. Prompt comparison belongs to Story 3.8's rig, whose axis is parameterised for exactly that.

**Acceptance Criteria:**

**Given** the eval-harness fixture set
**When** I assemble the fixtures
**Then** `Tests/SummarizeTests/Fixtures/eval/` contains ≥5 frozen transcripts (overlapping with the Decision 3.6 smoke-test set is fine) with hand-curated expected outputs: expected action items + decisions with their quote-grounding pointers
**And** each fixture has an explicit pass-rate target (e.g., "≥80% of expected action items must survive grounding validation; ≤1 false-keep per fixture")

**Given** the eval harness runs
**When** I run `swift test --filter SummarizeEvalHarness`
**Then** for each fixture, the harness invokes the configured MVP-default summarizer strategy (locked in Story 3.8) with stubbed Anthropic responses (deterministic — same fixture → same response shape, NOT live API calls in CI per NFR-M5 + budget hygiene)
**And** the harness asserts: each expected item's text is present in the rendered output; each expected item's grounding pointer survives validation; the drop rate is below the per-fixture threshold; the precision (false-keeps) is below the per-fixture threshold

**Given** the eval harness CI integration
**When** any PR touching `Sources/Summarize/` or `Sources/ClaudeSummarizer/` opens
**Then** the eval harness runs in `ci.yml` per Story 1.8
**And** failure of any per-fixture threshold blocks the PR
**And** intentional updates to the threshold or expected outputs require an explicit rationale in the PR description (not a bare snapshot regeneration)

**Given** the user is calibrating their trust in the validator (J1.5)
**When** they inspect the eval-harness output
**Then** the harness emits a per-fixture summary line: *"Fixture <name>: kept N items (M expected) · dropped K · false-keeps F · grounding_method=citations"* — readable, auditable, copy-pasteable

**Given** a future maintainer adds a new captured-meeting fixture
**When** they place it in `Tests/SummarizeTests/Fixtures/eval/<name>/` with `transcript.json` + `expected.json`
**Then** the harness picks it up automatically (no test-file generation per fixture); the per-fixture threshold defaults to the project-wide default but can be overridden in `expected.json`

---

### Story 3.10: GoogleCalendarSource + OAuth PKCE + Keychain Refresh-Token + EventMatcher

As the single user,
I want `GoogleCalendarSource/GoogleCalendarSource.swift` to implement the `CalendarInterface` protocol with Google OAuth 2.0 PKCE flow, refresh-token storage in Keychain, and an `EventMatcher` that finds the active calendar event at a given capture time,
So that calendar enrichment works for FR51, FR52 — meeting title, attendees, and event metadata flow into the resulting note's frontmatter.

**Acceptance Criteria:**

**Given** the `CalendarInterface` target (declared in Story 1.1)
**When** I declare `CalendarSource` protocol
**Then** the protocol exposes: `func authorize() async throws`, `func fetchActiveEvent(at: Date) async throws -> CalendarEvent?`, `func upcomingEvents(in window: TimeInterval) async throws -> [CalendarEvent]` per AR-PAT-7

**Given** the `GoogleCalendarSource` target
**When** I call `authorize()` for the first time
**Then** the flow uses OAuth 2.0 device-code or installed-application flow with PKCE per NFR-S6
**And** the refresh token is stored in Keychain via `kSecClassGenericPassword` with service `com.auricle.app.google-oauth-refresh-token` per NFR-S1
**And** the OAuth scope is the minimum required: `https://www.googleapis.com/auth/calendar.readonly` (read-only access to user's primary calendar) per NFR-S6

**Given** an authorized session
**When** I call `fetchActiveEvent(at: capture_started_at)`
**Then** `EventMatcher` queries Google Calendar API v3 (`primary` calendar) per NFR-I5 for events whose `start.dateTime <= capture_started_at <= end.dateTime`
**And** if multiple matches, the matcher returns the most-specific (smallest duration) match
**And** the returned `CalendarEvent` carries: title, attendees (email + display name; emails stripped before any prompt assembly per NFR-Pr4), event ID (formatted as `google:<event_id>` per AR-DATA-1 namespacing), start/end times

**Given** the access token has expired
**When** I make any API call
**Then** the source automatically refreshes via the refresh token in Keychain
**And** if the refresh fails (revoked token, network unreachable), the source throws a typed `CalendarError.authorizationExpired` or `.unreachable` (consumed by Story 3.11 graceful degradation)

**Given** the calendar source is invoked off the hot path (per NFR-Pr1 — calendar enrichment is a sub-step of summarize)
**When** the API is unreachable
**Then** the failure is surfaced as a typed error; behavior continues per Story 3.11 graceful degradation
**And** all transmitted data over TLS 1.2+ per NFR-S5; no insecure-fallback path

**Given** the test suite
**When** I run `Tests/GoogleCalendarSourceTests/` against a stubbed Google Calendar responder
**Then** tests cover: successful authorization + token storage; successful active-event match; multiple-match disambiguation (smallest duration wins); access-token expiry → automatic refresh; refresh failure → typed error; offline → typed error

---

### Story 3.11: Calendar Enrichment Graceful Degradation

As the single user,
I want calendar enrichment failures to degrade gracefully per FR54 — meeting captures still complete, the note publishes with a generic title and `auricle/needs-calendar-enrichment` tag,
So that calendar API outages, OAuth expiry, or unmatched events never block a vault note from being written.

**Acceptance Criteria:**

**Given** the `Summarize` stage from Story 3.7
**When** the stage attempts calendar enrichment (calls `GoogleCalendarSource.fetchActiveEvent(at: capture_started_at)`)
**Then** if the calendar source returns an event, `calendar.json` is written to cache-dir per AR-PIPE-4, and the event metadata is injected into the prompt (Story 3.2) and frontmatter (Story 2.1)
**And** if the calendar source throws OR returns nil (no matching event), the stage proceeds with no calendar context — `calendar.json` is written with a `degraded: true` flag

**Given** calendar enrichment failed
**When** the persist stage (Epic 2) renders the note
**Then** the frontmatter title becomes the generic form `"Meeting at <ISO8601 local time>"` per AR-DATA-6 calendar-failed variant
**And** the `attendees` array is empty `[]`
**And** the `tags` array includes `auricle/meeting` AND `auricle/needs-calendar-enrichment` per AR-DATA-6

**Given** calendar enrichment is degraded
**When** the user later wants to fix the meeting note
**Then** they edit the frontmatter manually in Obsidian and remove the `auricle/needs-calendar-enrichment` tag — auricle never re-edits the note (FR26)

**Given** the test suite
**When** I run `Tests/SummarizeTests/CalendarDegradationTests.swift`
**Then** tests cover: calendar reachable + match found → standard variant; calendar reachable + no match → degraded variant with generic title; calendar unreachable (network error) → degraded variant; OAuth expired and refresh fails → degraded variant; the degraded variant produces a vault note that still parses correctly through the FrontmatterRenderer reader from Story 2.5

---

### Story 3.12: VaultGlossaryBuilder + GlossaryInjector + JargonCorrectionStrategy

As the single user,
I want `VaultGlossary/VaultGlossaryBuilder.swift` to extract a glossary of terms from my Obsidian vault by enumerating wikilink targets (FR55), `GlossaryInjector` to scope the glossary to the current meeting's attendees and topics (FR56), and a `JargonCorrectionStrategy` wrapping this path as the Phase 1 sibling of `AIReviewerStrategy` (per AR-AI-1),
So that the glossary is injected as context into the summarization prompt for term correction (FR57), the wedge-validation hypothesis ("≥40% of meetings show ≥1 applied jargon correction over 30-day rolling window") becomes measurable, and the AI-correction product category's MVP slot is filled.

**Acceptance Criteria:**

**Given** the `VaultGlossary` target
**When** I call `VaultGlossaryBuilder.build()`
**Then** the builder scans the user's vault (`vault_path`) for `[[wikilink]]`-target page names per FR55
**And** the result is a categorized glossary: `{people: [...], projects: [...], concepts: [...]}` (categorization is heuristic — files in `vault/People/` are people, etc.; users with non-standard vault layouts get a single uncategorized list)
**And** the glossary is cached at `~/Library/Caches/com.auricle.app/glossary-cache.json` per AR-INIT-5 (referenced as `Sources/VaultGlossary/GlossaryCache.swift`)

**Given** the cache is stale
**When** the builder is invoked
**Then** stale-cache detection uses vault-directory mtime comparison; the cache is rebuilt only when the vault has changed since last cache write
**And** the rebuild is bounded to seconds for typical vault sizes (≤10K markdown files); test fixture asserts performance under typical-vault-size synthetic input

**Given** the `Summarize` target's `GlossaryInjector`
**When** I call `GlossaryInjector.scope(_ glossary: Glossary, forMeeting: MeetingForFrontmatter)`
**Then** scoping reduces the glossary to terms relevant to the current meeting's attendees and topics per FR56
**And** the transcript-mention test is **fuzzy, not exact** — an exact-match rule drops precisely the terms the feature exists to correct, because a term the ASR mangled (`meshcore` → "mesh core") has no exact mention to match; the implementation may use a fuzzy/phonetic match, or keep People and Projects unconditionally and scope only Concepts
**And** a test fixture asserts this directly: a glossary term whose transcript appearance is misspelled **survives** scoping
**And** the scoped glossary token count is bounded ~200 tokens typical (vs. unscoped vault-wide ~5000+ tokens) per Decision 3.5

**Given** the `Summarize` stage from Story 3.7
**When** glossary injection happens
**Then** the scoped glossary is passed to `SummarizationPromptBuilder.build(transcript:, glossary:, attendees:, mode:)` from Story 3.2 in `[[wikilink]]` form
**And** the glossary is logged to `glossary.json` in cache-dir per AR-PIPE-4 (debugging surface)

**Given** the `AIReviewerInterface` target's sibling-protocol declarations from AR-AI-1
**When** I declare `JargonCorrectionStrategy`
**Then** the protocol exposes: `func correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection]` per Decision 5.1
**And** the MVP concrete impl wraps the existing `GlossaryInjector` flow — the correction is "inline within the summarize call's existing prompt" (no separate API call) per Decision 5.6 default-tier cost ceiling
**And** corrections are observable post-hoc in cache-dir from the difference between `summary.json` and `transcript.json` (no separate `jargon_suggestions.json` file in MVP; the wedge-validation measurement reads these files post-hoc per AR-AI-9)

**Given** AR-AI-9 wedge-validation measurement
**When** I run a periodic measurement script (manual or via `auricle stats` Story 9.x)
**Then** the script computes: count of meetings in the last 30 days where the summary text contains a glossary-resolved term (substitution observable as a difference between summary-side terms and raw transcript terms) ÷ total meetings
**And** the wedge-validation criterion is `≥40%` per PRD §Business Success
**And** **no new telemetry column is needed** — the ingredients are already in `summary.json` + `transcript.json` + `glossary.json` per AR-AI-9

**Given** the test suite
**When** I run `Tests/VaultGlossaryTests/`
**Then** tests cover: vault scan against synthetic vault fixture; cache invalidation on mtime change; scoping reduces token count; uncategorized fallback for non-standard vaults; performance assertion under 10K-file vault

---

**Epic 3 summary:**
- **12 stories** sized for single dev-agent completion
- **All FRs covered:** FR28 (Story 3.1 — output shape), FR29 (Stories 3.4 + 3.5 — both grounding methods), FR30 (Stories 3.4 + 3.5 — validation), FR31 (Stories 3.4 + 3.5), FR32 (Story 3.6 — orchestrator-mediated fallback), FR51 (Story 3.10), FR52 (Story 3.10), FR54 (Story 3.11), FR55 (Story 3.12), FR56 (Story 3.12), FR57 (Story 3.12)
- **NFRs primarily verified:** NFR-P5 (Story 3.7), NFR-R7 (Stories 3.4 + 3.5 — quote-grounding hard gate), NFR-R9 (Story 3.3), NFR-S1 (Stories 3.3, 3.10 — Keychain), NFR-S5 (Stories 3.3, 3.10), NFR-S6 (Story 3.10), NFR-S7 (Story 3.3 — log redaction), NFR-S8 (woven), NFR-Pr1 (Story 3.7), NFR-Pr4 (Story 3.10 — emails stripped), NFR-Pr5 (documented in privacy story when Settings UI lands in Epic 9), NFR-I5 (Story 3.10), NFR-I6 (Stories 3.3, 3.4, 3.5 — model + effort budget configurable), NFR-C1 default tier (validated empirically in Stories 3.8 + 3.9)
- **Architectural commitments addressed:** AR-SUM-1 through AR-SUM-6 (Stories 3.1–3.9), AR-AI-1 partial (`JargonCorrectionStrategy` sibling — Story 3.12; full AIReviewer family in Epic 4), AR-AI-9 (Story 3.12 — wedge-validation measurement)
- **Mary's eval-harness ask satisfied:** Story 3.9 ships continuous regression eval beyond Decision 3.6's one-time smoke-test
- **Story 3.6 sequencing note:** Story 3.8 (smoke-test execution) is sequenced AFTER Stories 3.1–3.6 (interface + both strategies + orchestrator) but BEFORE Story 3.7 (stage entry point) — the orchestrator's wiring depends on the smoke-test outcome
- **No future-story dependencies:** every story is independently completable in sequence within the epic

---

## Epic 4: Pipeline Validation Milestone (CLI End-to-End)

> Renamed per John's review — this is a *Pipeline Validation* checkpoint for the maintainer-as-builder, not a user-shippable milestone for the maintainer-as-meeting-haver. **This is a gate, not a ship.** The cohesive-MVP commitment lives at Epic 9.

User (in builder mode) has a meeting audio file on disk → registers it with the hidden `auricle __internal-import <audio-file>` (Story 4.8), which prints a meeting id → runs `auricle run <id> --publish-anyway` from terminal → gets a complete Obsidian note. Validates Claude summarization quality on real transcripts, validates WhisperKit diarization quality, validates the AI-correction wedge thesis, validates the entire pipeline before any GUI investment.

### Story 4.1: WhisperKit Transcribe Stage

As the maintainer (in builder mode),
I want `Transcribe/TranscribeStage.swift` and `WhisperKitTranscriber/WhisperKitTranscriber.swift` to convert `audio.wav` into a `CanonicalTranscript` written to `transcript.json` in cache-dir,
So that the rest of the pipeline can consume canonical transcript text without ever needing to load audio or invoke the model again.

**Acceptance Criteria:**

**Given** the `WhisperKitTranscriber` target depending on `TranscriberInterface`
**When** I declare `WhisperKitTranscriber` conforming to `TranscriberStrategy`
**Then** the protocol exposes: `func transcribe(audio: URL, config: TranscriberConfig) async throws -> CanonicalTranscript` per AR-PAT-7 + AR-AI-1 strategy family pattern
**And** the concrete impl loads Whisper-large-v3-turbo (default per FR17) on ANE via WhisperKit
**And** model load happens once per subprocess invocation; subsequent transcribe calls within the same subprocess reuse the loaded model

**Given** the `Transcribe` target
**When** `auricle-cli __internal-stage transcribe <id> --worker-protocol-version 1` is invoked
**Then** the subprocess loads `audio.wav` from cache-dir, calls `WhisperKitTranscriber.transcribe(...)`, writes the result to `transcript.json` via `Core/CacheArtifactWriter` per AR-PAT-4
**And** `transcript.json` is **immutable** post-write (per AR-PIPE-4 cache-immutability invariant — Decision 5.3)
**And** the transcript is English-only per FR19 (no language detection in MVP — model defaults to English)
**And** transcription completes entirely on-device with no network round-trip per FR20

**Given** NFR-P3 budget (≤30s for 30-min audio file on M5 Max with ANE)
**When** I run `Tests/TranscribeTests/PerformanceTests.swift` with a 30-min reference WAV
**Then** the transcribe stage completes in ≤30s
**And** `Tests/WhisperKitTranscriberTests/` covers: model load + transcribe against a small reference WAV; idempotent re-run produces byte-identical `transcript.json`; subprocess restart after OOM (1 retry per Decision 4.2)

**Given** the canonical transcript invariant from Story 1.2
**When** the transcript is written
**Then** the text is NFC-normalized Unicode, LF line endings, no leading/trailing whitespace per line, speaker labels prefixed `<Speaker_N>: ` at utterance start per AR-SUM-4
**And** the file carries `schema_version: 1` per AR-PIPE-4
**And** each utterance's `[start, end)` range includes its own leading `<Speaker_N>: ` prefix, so a range slice reads `Speaker_1: text`; the summarize stage strips that one prefix when it renders an utterance under its speaker label, and a range that omits the prefix is rendered unchanged

**Given** the stage execution
**When** transcription succeeds
**Then** a `stage_events` row is written via `StageEventLogger.record(...)` (Story 1.6) with `stage='transcribe'`, `event='completed'`, `metadata_json` containing `{model_id: "whisper-large-v3-turbo", audio_duration_s, transcript_chars}` per Decision 4.5
**And** `telemetry.transcription_wer_estimate` may be NULL (filled in v1.1 by post-summarize divergence calc) — the column is reserved per Story 1.4
**And** this row is the single `completed` row for the combined transcribe and diarize subprocess; Story 4.2 adds a `diarize` object to its `metadata_json`

**Given** WhisperKit transcription failure (OOM, model load failure)
**When** the stage retries per Decision 4.2 (1 retry after fresh subprocess restart)
**Then** retry exhaustion transitions to `transcription_failed` (permanent per AR-FAIL-1); `auricle run <id> --force` is the override path

---

### Story 4.2: Diarize Stage + Snippet Extraction

As the maintainer (in builder mode),
I want `Diarize/DiarizeStage.swift` and `WhisperKitDiarizer/WhisperKitDiarizer.swift` to produce speaker-segmented diarization output (`Speaker_1`, `Speaker_2`, …) plus per-speaker representative WAV snippets used by the Attribution sheet (Epic 7),
So that the diarization JSON is canonical and the snippet files are pre-computed before any GUI work.

**Acceptance Criteria:**

**Given** the `WhisperKitDiarizer` target depending on `DiarizerInterface`
**When** I declare `WhisperKitDiarizer` conforming to `DiarizerStrategy`
**Then** the protocol exposes: `func diarize(transcript: CanonicalTranscript, audio: URL, config: DiarizerConfig) async throws -> DiarizationArtifact` per AR-PAT-7
**And** before writing the concrete impl, the PRD's Open Resolutions empirical test (WhisperKit-built-in vs SpeakerKit, per the widened resolution) runs first and decides the engine — default to WhisperKit's built-in diarization per FR18 if the test doesn't clearly favor SpeakerKit or if SpeakerKit turns out to need non-Swift runtime support
**And** cross-meeting voice-print matching (FR68) stays v2+ regardless of which engine wins this test — that's a separate capability from single-meeting diarization quality, not a reason to exclude SpeakerKit
**And** the diarization runs in the same subprocess as transcribe (per Decision 1.1 — they share WhisperKit model state; if SpeakerKit is adopted, confirm it can share the same process/model-load lifecycle before locking this AC)

**Given** the `Diarize` target
**When** the stage runs after `Transcribe`
**Then** the subprocess invokes `WhisperKitDiarizer.diarize(...)`, writes the result to `diarization.json` via `Core/CacheArtifactWriter` per AR-PAT-4
**And** `diarization.json` carries `schema_version: 1` and per-segment voice-profile metadata (used by Epic 7's variance warning per UX-DR36)
**And** `diarization.json` is **immutable** post-write (per AR-PIPE-4 cache-immutability invariant — Decision 5.3)

**Given** snippet extraction
**When** the stage processes diarization segments
**Then** `Sources/Diarize/SnippetExtractor.swift` writes per-speaker representative clips to `snippets/speaker_N.wav` (5–10s each, configurable via `attribution.snippet_duration_seconds`, default 8s) per AR-PIPE-4
**And** the extractor ALSO writes `snippets/speaker_N.envelope` (Float32 array, ~200 amplitude samples) for `WaveformView` pre-render per UX-DR15
**And** snippet files are 0600-permissioned per NFR-S3

**Given** NFR-P4 budget (≤30s for 30-min audio file)
**When** I run `Tests/DiarizeTests/PerformanceTests.swift`
**Then** the diarize stage completes in ≤30s on the reference hardware (sharing model state with transcribe per Decision 1.1)
**And** `Tests/WhisperKitDiarizerTests/` covers: diarization output shape; snippet files exist with correct duration; envelope files have ~200 samples; idempotent re-run produces byte-identical artifacts

**Given** the stage execution
**When** diarization succeeds
**Then** no separate `stage_events` row is written: `PipelineStage` has no `diarize` case, and the combined subprocess runs under the `transcribe` stage per Decision 1.1 and the architecture's "no separate diarize stage" rule
**And** the diarize step's `{model_id, segment_count, speaker_count, snippet_count}` is added to the same `stage='transcribe'`, `event='completed'` row's `metadata_json` under a `diarize` key (snake_case per the `stage_events` dialect)
**And** the composition root merges the two metadata blocks, because `Transcribe` and `Diarize` do not import each other
**And** `PipelineStage` stays at nine cases and `__internal-stage diarize` stays invalid

---

### Story 4.3: ReviewDiarization Stage + State Machine Entry

As the maintainer (in builder mode),
I want `ReviewDiarization/ReviewDiarizationStage.swift` to be the dedicated subprocess entry point for the `reviewing_diarization` state that runs AFTER WhisperKit subprocess terminates (per AR-AI-3),
So that the AI reviewer subprocess starts only after WhisperKit's ~2-4GB working set is freed, and the flag-default-off path passes through in <100ms with an empty stub.

**Acceptance Criteria:**

**Given** the `ReviewDiarization` target
**When** the orchestrator dispatches the stage
**Then** the subprocess is spawned via `auricle-cli __internal-stage review-diarization <id> --worker-protocol-version 1` per AR-AI-3 + AR-PIPE-7
**And** the spawn happens AFTER the WhisperKit subprocess (transcribe + diarize) has terminated (Story 1.5's `SubprocessDispatcher` enforces sequencing)
**And** the meeting state transitions `transcribing → reviewing_diarization` upon dispatch per AR-PIPE-2 + Decision 1.2

**Given** `diarization_review.enabled = false` (MVP default per Path C)
**When** the `ReviewDiarization` stage runs
**Then** the stage short-circuits in <100ms with an empty stub `diarization_suggestions.json` (no Claude call) per FR74 + AR-AI-2
**And** the `stage_events` row carries `metadata_json` of `{model_id: "flag_off", cost_usd: 0, suggestions_count: 0, review_skipped: true}` per Decision 4.5
**And** `telemetry` UPSERT writes `diarization_suggestions_count = 0`, `diarization_review_cost_usd = 0`, `diarization_review_model = "flag_off"` per AR-AI-5 partition rule (subprocess writes count/cost/model)
**And** the meeting state transitions `reviewing_diarization → awaiting_attribution` per AR-PIPE-2

**Given** `diarization_review.enabled = true` (Phase 2 v1.1 — flag flip after smoke-test)
**When** the stage runs
**Then** Story 4.5's `ClaudeDiarizationReviewer` is invoked; the result is written to `diarization_suggestions.json` per AR-AI-4 cache-immutability invariant
**And** the wall-clock stale-detection budget is **90s fixed** per AR-FAIL-2 + Decision 5.3
**And** if the reviewer hits the 90s budget OR the Anthropic call fails, the stage writes an empty stub artifact and transitions to `awaiting_attribution` (benign-timeout passthrough — NOT a `*_failed` transition per Decision 4.2)
**And** the `stage_events.failed` row in the timeout case carries `error_class='ai_reviewer_timeout'`

**Given** the test suite
**When** I run `Tests/ReviewDiarizationTests/`
**Then** tests cover: flag-off short-circuit completes in <100ms with empty stub; flag-on path invokes the reviewer (mocked); timeout passes through to `awaiting_attribution` with empty stub (not `*_failed`); subprocess lifecycle integrates with `StageRunner` two-transaction pattern from Story 1.5

---

### Story 4.4: AIReviewerInterface Protocol Family + Null TranscriptionReviewerStrategy

As the maintainer (in builder mode),
I want `AIReviewerInterface` to declare the `AIReviewerStrategy` base protocol plus three sibling concrete protocols (`DiarizationReviewerStrategy`, `TranscriptionReviewerStrategy`, `JargonCorrectionStrategy`) per AR-AI-1,
So that all architectural slots for the AI-correction product category are in place at MVP — the Phase 2 (diarization), Phase 3 (transcription), and Phase 4 (unified) activations are config flips, not refactors.

**Acceptance Criteria:**

**Given** the `AIReviewerInterface` target (protocol-only)
**When** I declare the base protocol
**Then** `AIReviewerStrategy` exposes: `associatedtype Input: Codable`, `associatedtype Output: Codable & Suggestion`, `func review(input: Input, config: AIReviewerConfig) async throws -> AIReviewerResult<Output>` per AR-AI-1 + Decision 5.1
**And** `Suggestion` protocol exposes: `var suggestionId: String { get }` (stable id for telemetry + per-suggestion Apply tracking), `var reasoning: String { get }` (human-readable explanation rendered in `AIHintChip`)
**And** `AIReviewerResult<O: Suggestion>` carries: `schemaVersion`, `suggestions: [O]`, `cost: AIReviewerCost`, `reviewedSegmentCount: Int` (populates the trust-calibration footer "Reviewed N segments, flagged M")

**Given** the three sibling concrete protocols
**When** I declare them
**Then** `DiarizationReviewerStrategy` has `Input = (CanonicalTranscript, DiarizationArtifact)`, `Output = DiarizationSuggestion` (with `kind: .underSegmentation | .overSegmentation`, `segmentId`, `proposedSplits[]`); cache artifact `diarization_suggestions.json` per Decision 5.1
**And** `TranscriptionReviewerStrategy` has `Input = (CanonicalTranscript, AudioFingerprint)`, `Output = TranscriptionSuggestion` (with `charRange`, `proposedReplacement`); cache artifact `transcription_suggestions.json` is declared as a schema but NOT WRITTEN in MVP per Decision 5.5 Phase 3
**And** `JargonCorrectionStrategy` already ships from Story 3.12 in `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` as `correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection]`; this story keeps that signature and makes `JargonCorrection` conform to `Suggestion` (it already carries `suggestionId` and `reasoning`)
**And** it does not force the glossary path through `AIReviewerStrategy.review(input:config:)`, because that shape serves reviewers that call a model and FR73 does not require it

**Given** `GlossaryJargonCorrector` (`Sources/Summarize/GlossaryJargonCorrector.swift`, from Story 3.12)
**When** Story 4.4 lands
**Then** it is unchanged
**And** the existing behavior (FR55–FR57) is unchanged

**Given** the null `TranscriptionReviewerStrategy` declaration
**When** the build completes
**Then** `transcription_suggestions.json` schema exists (declared in `Sources/AIReviewerInterface/TranscriptionSuggestion.swift`) but no concrete impl ships at MVP per AR-AI-1 Phase 3
**And** the schema includes `schemaVersion: 1` so v1.1's concrete impl (FR76, Epic 10) doesn't require a schema migration

**Given** the test suite
**When** I run `Tests/AIReviewerInterfaceTests/`
**Then** `Tests/AIReviewerInterfaceTests/SuggestionSchemaRoundTripTests.swift` round-trips every suggestion type through JSON serialization
**And** `Tests/AIReviewerInterfaceTests/ImmutabilityContractTests.swift` asserts no reviewer code path opens `transcript.json` or `diarization.json` for write per AR-AI-4 (build fails on violation)

---

### Story 4.5: ClaudeDiarizationReviewer Concrete Impl Behind Flag

As the maintainer (in builder mode),
I want `ClaudeAIReviewers/ClaudeDiarizationReviewer.swift` to be the MVP concrete impl of `DiarizationReviewerStrategy` per Decision 5.2 (Haiku-default, flag-controlled),
So that Path C Phase 1 ships its slot (flag-default-off in MVP, flag-on in Phase 2 v1.1 after smoke-test) and the cost ceiling tier behavior is validated empirically.

**Acceptance Criteria:**

**Given** the `ClaudeAIReviewers` target depending on `AIReviewerInterface` + `ClaudeSummarizer` (shares `AnthropicHTTPClient` + `KeychainAPIKey` per AR-AI-2)
**When** I declare `ClaudeDiarizationReviewer`
**Then** the concrete strategy uses `claude-haiku-4-5` by default (configurable via `diarization_review.model` per FR58)
**And** the prompt skeleton is structured to ask Claude to flag segments where: (a) acoustic similarity hints two speakers labeled as one (under-segmentation) → propose splits; (b) acoustic similarity hints one speaker labeled as two (over-segmentation) → propose merge
**And** this story adds the `ClaudeSummarizer` dependency to the `ClaudeAIReviewers` target in `Package.swift`, which the architecture's dependency graph already lists (the shared `AnthropicHTTPClient` and `KeychainAPIKey` live in `ClaudeSummarizer`)

**Given** prompt caching per AR-AI-2 + Decision 5.6
**When** the prompt is constructed
**Then** the system prompt + diarization-review instructions use Anthropic `cache_control` blocks
**And** the per-meeting transcript+diarization is the variable portion (NOT cached)
**And** estimated cost is ~$0.02–0.05 per 30-min meeting per Decision 5.6 (vs. ~$0.40–0.50 for Opus summarize)

**Given** the reviewer is invoked from Story 4.3's `ReviewDiarization` stage
**When** flag is on
**Then** the response JSON shape is structured with one suggestion per flagged segment, each carrying a stable `suggestionId` (so per-suggestion Apply telemetry survives sheet reopens per Decision 5.1)
**And** the response is one-shot (NOT streaming — per Amelia's MVP scoping; Haiku response for ~80 segments is ~3s, render when complete; streaming UI is Phase 2+ refinement)

**Given** NFR-C1 v1.1+ tier ceiling (≤$0.60 per 30-min meeting when `diarization_review.enabled = true`)
**When** Story 4.10's live gate runs the fixture set with flag on
**Then** aggregate per-meeting cost across `summarize` (Opus) + `reviewing_diarization` (Haiku) is ≤$0.60 per Decision 5.6
**And** if exceeded, the live gate fails with a clear "cost ceiling exceeded" error

**Given** future local-LLM impl per Decision 5.6 telemetry contract
**When** a v1.1+ local-LLM diarization reviewer ships
**Then** the telemetry contract is `cost_usd: 0` + `model_id: "local:<name>"` — locked in MVP schema (Story 1.4's `telemetry.diarization_review_cost_usd` + `diarization_review_model` columns) so v1.1+ swap is a config change, not a schema migration per AR-AI-2

**Given** the test suite
**When** I run `Tests/ClaudeAIReviewersTests/`
**Then** `Tests/ClaudeAIReviewersTests/ClaudeDiarizationReviewerTests.swift` covers: prompt construction with cache_control markers; response parsing into `DiarizationSuggestion[]` with stable `suggestionId`; cost telemetry written correctly; subprocess timeout (90s budget) handled by Story 4.3
**And** `Tests/ClaudeAIReviewersTests/PromptCachingContractTests.swift` asserts cache_control marker placement (system prompt + instructions cached; per-meeting transcript+diarization NOT cached)

---

### Story 4.6: AttributionViewModel in Attribute/ + Attribution Batch CLI

As the maintainer (in builder mode),
I want `AttributionViewModel` to live in the `Attribute` target (NOT in the GUI target), and `Attribute/AttributionStage.swift` to support batch CLI mode via `--speakers "1=Ben,2=Sara,..."` + `--publish-anyway`,
So that the **type system is the parity contract** between Epic 4's CLI batch attribution and Epic 7's GUI sheet — eliminating Sally's CLI/GUI divergence concern per Amelia's mitigation.

**Acceptance Criteria:**

**Given** the `Attribute` target (NOT `App/Auricle/MainWindow/`), which both `auricle-cli` and `AuricleApp` link
**When** I declare `AttributionViewModel` as an `@Observable` Swift type
**Then** the view model owns: `attribution.json` state (speakers map + segment_overrides[] + segment_splits[] per AR-AI-6), the `diarization_suggestions.json` reading (when present), the autocomplete priority order (calendar → vault wikilinks → previously-labeled per FR23), the heuristic "this is me" pre-select logic (longest-cumulative-speaking row), the recurring-meeting auto-prefill (≥3 prior labelings per UX-DR33)
**And** the view model is consumed identically by Story 4.6's CLI batch attribution AND Epic 7's `AttributionSheet` GUI per Amelia's parity-contract resolution
**And** the view model exposes a debounced atomic-write (500ms via `Task.debounce`) routed through `Core/AtomicWriter` per AR-AI-6

**Given** the view model decodes `DiarizationArtifact` and `DiarizationSuggestion`
**When** I inspect `Package.swift`
**Then** `Attribute` depends on `DiarizerInterface` and `AIReviewerInterface` (both depend on `Core`, which is why the view model cannot live in `Core`)
**And** calendar attendees and vault wikilink targets come from the `Core` types `CalendarArtifact` and `Glossary`
**And** the "previously labeled" names arrive through an injected protocol defined in `Attribute`, so the view model has no `State` or vault dependency of its own
**And** the story's Design Notes name the store behind "previously labeled" (FR23 item 3), which no artifact records today

**Given** the `Attribute/AttributionStage.swift`
**When** `auricle attribute <id> --speakers "1=Ben,2=Jordan Whitfield,3=Priya"` is invoked (CLI batch mode)
**Then** the stage parses the speaker mapping, resolves each name against the vault (matching wikilink targets, falling back to creating new wikilinks for unknown names), validates the mapping (no duplicates, every Speaker_N referenced in `diarization.json` is mappable or explicitly unmapped), and writes `attribution.json` via `AttributionViewModel`'s atomic-write path per AR-AI-6
**And** the stage transitions `meetings.state` from `awaiting_attribution → attributing → summarizing` per AR-PIPE-2
**And** `--speakers` ships here as the batch path; FR27 stays [v1.1] as the documented fallback surface, which adds `--emit-snippets` (Story 10.4), and a pre-1.0 addition is not an NFR-I7 contract break
**And** `auricle attribute <id> --batch` with no `--speakers` applies the meeting's existing `attribution.json` speakers map if one exists; otherwise it exits 1 with "no speaker mapping; run with --interactive or pass --speakers" per Decision 1.5
**And** until Epic 7 ships the sheet, `auricle attribute <id>` with no flags behaves as `--batch`

**Given** `auricle run <id> --publish-anyway`
**When** the user wants to skip attribution entirely (FR25 CLI path)
**Then** the stage writes `attribution.json` with all `Speaker_N` placeholder names, `segment_overrides[]` and `segment_splits[]` empty per AR-AI-6
**And** `meetings.state` advances to `summarizing`
**And** the eventual published note carries `auricle/needs-attribution` tag per AR-DATA-6 publish-anyway variant

**Given** the test suite
**When** I run `Tests/AttributeTests/`
**Then** `Tests/AttributeTests/AttributionViewModelTests.swift` covers: speaker mapping write + read; segment_overrides write; segment_splits write; debounced atomic-write; cancellation preservation (incremental writes survive interrupted attribution per UX-DR58)
**And** `Tests/AttributeTests/RendererPureFunctionTests.swift` exercises the renderer per Decision 5.4: `(diarization, overrides, splits) → RenderedTranscript` — pure function, idempotent, golden-fixture tested across every combination of `(no overrides, overrides only, splits only, both)` × `(all speakers attributed, partial, none)` × `(splits referencing valid segment ids, dangling split with no matching diarization segment — must be ignored not crash)`
**And** `Tests/AttributeTests/AttributionStageTests.swift` covers the CLI batch + publish-anyway paths

**Given** Sally's CLI/GUI divergence concern from party-mode review
**When** Epic 7's `AttributionSheet` lands later
**Then** the sheet imports `AttributionViewModel` from `Attribute` and uses it directly — no separate sheet-only view model exists
**And** the rename mechanics, autocomplete priority, segment_overrides/segment_splits semantics are **identical** between CLI and GUI by construction (LSP per AR-PAT-7)
**And** applying `segment_overrides` and `segment_splits` to the transcript the summarize stage reads is out of scope here, because both arrays are empty on every Epic 4 path; Story 7.11 owns it

---

### Story 4.7: `auricle run` Verb Skeleton + `__internal-stage` Worker Dispatch

As the maintainer (in builder mode),
I want `App/auricle-cli/Verbs/RunVerb.swift` to implement the full `auricle run <id> [--from <stage>] [--to <stage>] [--only <stage>] [--force] [--reattribute] [--publish-anyway]` verb per AR-PIPE-6 + Decision 1.5,
So that the entire Epic 4 pipeline is invocable from one user-facing CLI verb (not from the hidden `__internal-stage` worker — that's the GUI's subprocess-dispatch path).

**Acceptance Criteria:**

**Given** the `RunVerb` swift-argument-parser type
**When** I run `auricle run <id>` with no flags
**Then** the verb runs forward from the meeting's current state through subsequent stages (resume semantics — also handles transient failures `summarization_failed`, `persist_failed` per Decision 1.5)
**And** the verb spawns subprocess stages via `SubprocessDispatcher.spawn(...)` from Story 1.5 (which invokes `auricle-cli __internal-stage <stage> <id> --worker-protocol-version 1` per AR-PIPE-7)
**And** does NOT auto-verify on success — verification requires explicit user act (notification click, GUI confirm, or `auricle keep <id>` per Decision 4.3) — `meetings.verified_at` remains NULL after `auricle run`

**Given** orthogonal stage control flags
**When** I invoke `auricle run <id> --from transcribe --to summarize` or `--only summarize`
**Then** the verb runs only the specified subset of stages per Decision 1.5
**And** flag conflicts (`--from <stage>` + `--only <stage>` mutually exclusive; `--publish-anyway` + `--from attribute` / `--only attribute` mutually exclusive) are rejected at parse time with exit code 1 + clear error message per Decision 1.5

**Given** `--force` flag
**When** the meeting is in a permanent `*_failed` state (`capture_failed`, `transcription_failed`)
**Then** `--force` re-runs all stages (idempotent per NFR-R5) per Decision 1.5
**And** `--force` implies `--reattribute` (compatible; `--force` wins on precedence)

**Given** `--reattribute` flag
**When** the meeting has been published before
**Then** the verb runs `--from attribute` semantically (ergonomic alias)
**And** the existing armed retention timer is preserved (re-attribution is content fix, not re-verification per Decision 4.3)

**Given** `--publish-anyway` flag
**When** invoked on a meeting in `awaiting_attribution`
**Then** the verb skips attribution and publishes with `Speaker_N` placeholder names + `auricle/needs-attribution` tag per FR25
**And** if summarize then fails, the meeting transitions to `published_partial` per Decision 4.1 (carries `auricle/needs-attribution` AND `auricle/needs-summary` tags)

**Given** a meeting in `published_partial` (published with `Speaker_N` placeholders, and summarize produced no usable output)
**When** persist renders the note
**Then** `FrontmatterRenderer` accepts a `needsSummary` input (a `needsSummary` field on `MeetingForFrontmatter`, beside `needsAttribution` and `needsCalendarEnrichment`) that adds the `auricle/needs-summary` tag
**And** the tags array is `auricle/meeting`, `auricle/needs-attribution`, `auricle/needs-summary` for the `--publish-anyway` + failed-summarize case
**And** the note omits the `## Action Items` and `## Decisions` sections entirely — not empty headings

**Given** `auricle run <id> --publish-anyway` and a summarize failure after the calendar step (the summarizer call fails, or its output cannot be mapped into the artifact)
**When** the `summarize` worker handles the failure
**Then** it writes a stub `summary.json` through `CacheArtifactWriter`, so persist has an input for the `published_partial` note: `summary` empty, `action_items` and `decisions` empty, `needs_summary: true`
**And** every other field is built as on the success path, because the stage holds each one before the summarizer call: `transcript_segments` and `needs_attribution` from `transcript.json` and `attribution.json`; `title`, `calendar_event_title`, `attendees`, `self_wikilink` and `needs_calendar_enrichment` from the calendar step and the capture start
**And** no field is missing from the stub, and without a calendar match `attendees` is empty and `title` is the generic `Meeting at <capture time> <zone>` title, exactly as on the success path
**And** the stage writes the stub, not a helper the run verb calls: the stage already holds those fields, and AR-PIPE-1 keeps `summarize` code in its subprocess, out of the CLI process
**And** the stage learns of `--publish-anyway` from an optional `--publish-anyway` option on `InternalStageArguments` (beside `--vault-path`), which `SubprocessDispatcher` passes when `RunVerb` received the flag
**And** the stage then completes into `persisting`, so persist runs under its usual active state, and records the failure's `error_class` in that event's `metadata_json`
**And** a failure without `--publish-anyway`, a failure before the calendar step (unreadable transcript or attribution, missing capture start, segment extraction, prompt set) and a cancelled run write no stub and leave the meeting in `summarization_failed` as today, so a normal failure never leaves a stub behind for persist to publish later

**Given** a `summary.json` written by the stub path, or by any earlier stage version
**When** `PersistStage` reads it
**Then** `SummaryArtifact` has a `needsSummary` flag beside `needsAttribution` and `needsCalendarEnrichment`, encoded as `needs_summary` and decoded as `false` when the key is absent, so a `summary.json` that predates the flag still decodes
**And** `PersistStage` maps the flag to the `needsSummary` input of `MeetingForFrontmatter` from the criterion above, and otherwise reads the artifact exactly as before: a missing `summary.json` still fails as `summaryArtifactUnreadable`
**And** persist completes the meeting into `published_partial` instead of `published` when `needsSummary` is true, which needs `published_partial` added to persist's allowed targets in `PipelineTransitions` (today `published` and `persist_failed`)

**Given** the run verb reaches the persist stage after summarize
**When** persist runs in-process (AR-PIPE-1; not through `__internal-stage`)
**Then** the verb calls `PersistStage.run` with the meeting's cache directory (which holds `summary.json`) and the `vault_path` and `meetings_subdir` values from `Core/Config` (`Sources/Core/Config.swift`; set in `~/.auricle/config.toml`)
**And** the verb passes no caller-supplied re-publish flag — persist derives a re-publish from whether the meeting's stored note (`meetings.vault_note_path`) still exists on disk, and writes a fresh publish when it does not
**And** a resume from `persist_failed` re-runs the persist stage only, not the stages before it

**Given** user agency on retries (UX-DR53 + Decision 4.2)
**When** a retry is in flight in a foreground TTY
**Then** SIGINT (Ctrl-C) cancels the in-flight HTTP request, transitions to `summarization_failed` immediately, exits 130 (standard for SIGINT) per Decision 4.2

**Given** every stage `auricle run` drives
**When** I run the worker-coverage test
**Then** `InternalStageWorker` has a case for each subprocess stage: `transcribe` (Stories 4.1 and 4.2), `review-diarization` (Story 4.3) and `summarize` (Story 3.7)
**And** `auricle run` runs `attribute`, `persist` and `notify` in-process per AR-PIPE-1
**And** the test enumerates the stages the verb drives, so a stage with neither a worker case nor an in-process path fails the build

**Given** persist has published the note
**When** the run continues
**Then** the verb runs the notify stage in-process with the CLI composition root's `Notifier` (Story 4.9), not as a subprocess, and the meeting reaches `awaiting_verification`

**Given** the CLI dispatches workers
**When** `RunVerb` builds its `SubprocessDispatcher`
**Then** it passes `resolveExecutablePath` returning the running `auricle-cli`'s own executable URL, because the default resolver is written for the GUI bundle and its behavior from an unbundled CLI is unverified
**And** a test asserts the CLI-built dispatcher's `makeProcess` executable exists and is the current binary

**Given** the test suite
**When** I run integration tests against the binary
**Then** `Tests/CLITests/RunVerbTests.swift` covers: bare `auricle run <id>` resume; `--from`/`--to`/`--only` permutations; `--force` against permanent fail-state; `--reattribute` preserves retention timer; `--publish-anyway` produces `auricle/needs-attribution` tag; flag conflicts rejected at parse time; SIGINT cancels and exits 130; a completed run leaves a note published at the configured vault path; `--reattribute` on a published meeting produces a `--rerun-` sibling whose frontmatter carries `auricle.supersedes`
**And** `Tests/PersistTests/FrontmatterRendererTests.swift` includes a snapshot test for the `published_partial` variant: `auricle/needs-summary` and `auricle/needs-attribution` tags both present, no Action Items or Decisions sections
**And** `Tests/SummarizeTests/SummarizeStageTests.swift` covers the stub on the `--publish-anyway` failure path only: a failed summarizer call writes a `summary.json` with `needs_summary: true`, empty summary, action items and decisions, and the segments, title and attendees the success path would build, and completes into `persisting`; a failure without the flag, a failure before the calendar step and a cancelled run write no stub and end in `summarization_failed`
**And** `Tests/OrchestratorTests/SubprocessDispatcherTests.swift` covers the `--publish-anyway` option reaching the `summarize` worker's argument vector, and its absence when `RunVerb` did not receive the flag
**And** `Tests/PersistTests/PersistStageTests.swift` covers the stub: persist publishes a note with `auricle/needs-summary`, no Action Items or Decisions sections, and completes into `published_partial`; a missing `summary.json` still fails as `summaryArtifactUnreadable`
**And** a `Tests/CoreTests/` test decodes a `summary.json` without the `needs_summary` key as `needsSummary == false` and round-trips the key when present

---

### Story 4.8: Builder-Mode Audio Import (`auricle __internal-import`)

As the maintainer (in builder mode),
I want a hidden `auricle __internal-import <audio-file>` verb that registers an existing recording as a `captured` meeting,
So that Epic 4's pipeline runs on real recordings before Epic 5's capture exists, and Story 4.10's live gate has a supported entry point.

**Acceptance Criteria:**

**Given** a readable audio file (WAV, or any format AVFoundation reads, such as m4a)
**When** I run `auricle __internal-import <audio-file> [--started-at <ISO 8601>] [--title <text>]`
**Then** the audio is converted to the Decision 1.4 format (PCM 16-bit, 16 kHz, mono WAV) and written to `~/Library/Caches/com.auricle.app/<meeting-id>/audio.wav` through `AtomicWriter` at mode 0600 per NFR-S3
**And** a `meetings` row is inserted through `StateStore` with `state='captured'`, `audio_cache_path`, `duration_seconds`, `capture_started_at` (`--started-at` if given, else the source file's creation date), `capture_ended_at` (start plus duration) and `title` (if given)
**And** one `stage_events` row is written through `StageEventLogger` with `stage='capture'`, `event='completed'` and `metadata_json` of `{imported: true, source_format, audio_duration_s}`
**And** stdout carries the new meeting id and nothing else, so `id=$(auricle __internal-import call.m4a)` works
**And** the source path is never logged at a public log level

**Given** an unreadable, empty or zero-length audio file, or a malformed `--started-at`
**When** the verb runs
**Then** it exits 1 with an actionable message, inserts no row, and leaves no cache directory behind (audio is finalized before the row is written)

**Given** the hidden-verb contract
**When** I run `auricle help` or generate shell completions
**Then** the verb is absent (`shouldDisplay: false`) and is exempt from the NFR-I7 binding contract, like `__internal-stage`
**And** promoting it to a public `import` verb is a separate PRD decision and is not part of this story

**Given** the AGENTS.md rule that logic lives in `Sources/`
**When** I inspect the implementation
**Then** conversion and registration live in `Sources/Capture/AudioImporter.swift`, and `App/auricle-cli/Verbs/ImportVerb.swift` is a thin wrapper

**Given** the test suite
**When** I run `Tests/CaptureTests/AudioImporterTests.swift`
**Then** tests cover: a 16 kHz mono WAV passes through; a 48 kHz stereo input is converted to 16 kHz mono; file mode 0600; row fields and the `capture` event; `--started-at` and file-date fallback; unreadable input leaves no row and no directory; two imports of one file produce two ids
**And** test audio is generated in the test, not checked in

---

### Story 4.9: Basic Notification Stub + Obsidian URL Open

As the maintainer (in builder mode),
I want the absolute minimum notification + Obsidian URL-open path so that Epic 4's CLI dogfood ends with the note path and its Obsidian URL printed to the terminal, and the `published → awaiting_verification` transition has an owner,
So that the exit gate (Story 4.10) can validate the *full* loop — but the full Verifier+timer wiring lands in Epic 8.

**Acceptance Criteria:**

**Given** the `Notifications` target
**When** I declare the `Notifier` protocol (`func fire(meetingID:, title:, vaultPath:) async`)
**Then** two conformers exist
**And** `UserNotificationNotifier` posts a `UNNotificationRequest` through an injectable notification center per FR42, with body *"auricle: meeting ready — <title>"* (e.g., *"auricle: meeting ready — Tuesday sync with Ben"*) and a `userInfo` payload of `{meeting_id, schema_version, payload_version}` per AR-FAIL-5
**And** `StdoutNotifier` prints the vault note path and the `obsidian://open?vault=...&file=...` URL to stdout, one per line

**Given** one composition root per binary (`architecture.md`, DIP)
**When** the CLI and the GUI are wired
**Then** `auricle-cli` wires `StdoutNotifier` and `AuricleApp` wires `UserNotificationNotifier` (the notification delegate must live in the app process per Decision 1.1)
**And** Epic 4 posts no system notification from the CLI; whether a bundled `auricle-cli` can post one is not settled here and is left to the GUI dispatch in Epic 6

**Given** the notify stage runs after persist (in-process under `auricle run`, per Story 4.7)
**When** the notifier returns or fails (notify failure is non-blocking per NFR-R8)
**Then** the meeting transitions `published → awaiting_verification` in the same run

**Given** notification permission has been granted
**When** the user clicks the notification
**Then** `App/Auricle/NotificationDelegate.swift`'s click handler calls `NSWorkspace.shared.open(URL(string: "obsidian://open?vault=...&file=..."))` per FR43
**And** the URL is constructed from `meetings.vault_note_path` (looked up via `meeting_id` from payload)

**Given** Epic 8 has not yet shipped
**When** the click happens
**Then** the verification + retention-timer arming side of the click is **stubbed** in this story — the click opens Obsidian only; `Verifier.markVerified(...)` is NOT called
**And** the meeting state stays at `awaiting_verification` (visible in `auricle list` from Epic 9 Story; in Epic 4 the state is observable only via direct SQLite inspection)
**And** Story 4.9 is explicitly tagged as an **incomplete-but-shippable stub for FR42/FR43**: `UserNotificationNotifier` is unit-tested only and is not exercised end-to-end until the GUI dispatches in Epic 6; the full verification path (FR44 + retention arming) lands in Epic 8

**Given** a persist stage that completes as a re-publish (a `--rerun-<YYYY-MM-DD>[-N]` sibling was written per AR-DATA-7)
**When** `UserNotificationNotifier` posts the notification
**Then** the body distinguishes the re-publish: *"auricle: re-published Tuesday Sync with Ben (rerun 2026-05-15)"* per AR-DATA-7, with the rerun date taken from the sibling's `--rerun-` suffix
**And** a persist that fell back to a fresh publish (the original note was deleted, so no `--rerun-` sibling exists) uses the standard *"meeting ready"* body
**And** the `userInfo` payload keeps the same shape as the standard notification

**Given** `UserNotificationNotifier` and notification permission has been revoked
**When** the notify stage runs
**Then** `Notifier.fire(...)` logs at `warn` level and proceeds; the meeting still transitions to `awaiting_verification` per NFR-R8
**And** the user can manually verify via `auricle keep <id>` (Epic 8 Story); in Epic 4 there's no manual-verify path yet — meeting just sits in `awaiting_verification`

**Given** the test suite
**When** I run `Tests/NotificationsTests/NotifierStubTests.swift`
**Then** tests cover: `UNNotificationRequest` constructed with correct payload format; `URL(string: "obsidian://open?vault=...&file=...")` constructed correctly; re-publish → body reads *"auricle: re-published <title> (rerun <YYYY-MM-DD>)"* while fresh publish and fresh-publish fallback → standard *"meeting ready"* body; notification permission revoked → graceful degradation; `StdoutNotifier` prints the path and URL; the notify stage moves `published → awaiting_verification` whether the notifier succeeds or fails

---

### Story 4.10: Exit-Criteria Gate (CI Pipeline Test + Live Run)

As the maintainer (in builder mode),
I want Epic 4's exit criteria in two parts — a CI pipeline test and a manual live run — that together validate Epic 4 is **a real gate, not "and then we kept going"** per John's review,
So that scope creep doesn't dilute the Pipeline Validation milestone, CI guards the plumbing on every PR, and the CLI dogfood claim is measured on real recordings.

**Acceptance Criteria:**

**Given** Part A, the CI pipeline test
**When** I run `swift test`
**Then** `Tests/IntegrationTests/PipelineEndToEndTests.swift` runs the stages through the library entry points (not the binary) with a stub `TranscriberStrategy`, a stub `DiarizerStrategy`, stubbed Anthropic responses, a temp vault and a temp state database
**And** the story adds an `IntegrationTests` test target to `Package.swift` that passes `--explicit-target-dependency-import-check error`
**And** it uses one small checked-in reference WAV (NFR-M5, at most 1 MB, synthetic or public-domain) so the audio path is exercised
**And** for each fixture it asserts: import through `AudioImporter` (Story 4.8); state reaches `awaiting_verification`; a vault note exists at the `FilenameResolver` path (Story 2.2) with schema-valid frontmatter; every action item and decision is followed by a `> source quote` that survives literal substring match against the transcript; `meetings.verified_at` is NULL (verification is human action per Decision 4.3)
**And** it runs on every PR through the existing `swift` job, with no path filter
**And** it does not run WhisperKit (model download, no ANE on hosted runners); WhisperKit correctness belongs to Stories 4.1 and 4.2

**Given** Part B, the live run
**When** the maintainer runs `Tests/scripts/run-epic4-exit-criteria.sh` against `$AURICLE_EXIT_FIXTURES`
**Then** the directory holds at least 5 recordings (at least two with 4 or more attendees; a 1:1 is deferred beyond Epic 4, see `deferred-work.md`) plus each recording's expected speaker mapping and expected item list
**And** for each recording the script runs `auricle __internal-import`, then `auricle run <id> --publish-anyway` (or `--speakers` per the mapping), and asserts exit 0, a vault note at the expected path with schema-valid frontmatter, and grounded quotes as in Part A
**And** it asserts `meetings.verified_at` is NULL by reading the `meetings` table with `sqlite3`, because `auricle status <id>` is a stub until Story 9.6
**And** across the set at least 80% of expected action items and decisions survive grounding, or the script fails with "Epic 4 exit criteria not met: <metric> = <value>"
**And** an expected item counts as surviving when the note carries that item, whether matched by quote overlap or by item text; the scorer also reports false keeps, so a recall gain bought with noise is visible in the same output
**And** per-meeting cost, summed from the `telemetry` table, is at most $0.50 with `diarization_review.enabled = false` and at most $0.60 with it `true`, per NFR-C1 read as a per-meeting ceiling
**And** it uses real WhisperKit and live Anthropic calls

**Given** the recordings are private and the repository is public
**When** results are recorded
**Then** recordings are never checked in and the fixture path comes from the environment variable
**And** `Tests/fixtures/epic4-exit-results.md` records aggregates only: pass rate, total cost, per-fixture counts under opaque labels (`fixture-1` …), no transcript text and no titles
**And** the AMI meeting audio (CC BY 4.0) behind the Epic 3 fixtures is an allowed public source for repeatable runs
**And** changing the fixture set needs a rationale in the PR description

**Given** Story 4.10 passes
**When** the maintainer reads the output
**Then** each per-fixture line reads: *"fixture-N: vault note written · grounding_method=substring · kept N items (M expected) · drop count K · cost $X"*
**And** the last line reads: *"Epic 4 exit criteria met: pass rate Y%, total cost $Z over <N> fixtures"*
**And** Epic 4 exits when `Tests/fixtures/epic4-exit-results.md` records that line and Part A is green

---

### Story 4.11: Offline Recall Bench — Frozen Transcripts, Real Claude Call, Automatic Score

As the maintainer,
I want a bench that runs frozen reference transcripts through a real Claude call and scores item recall automatically,
So that a prompt change can be measured in minutes for cents, instead of through a full WhisperKit pipeline run that takes hours of setup and cannot attribute a change to the prompt.

**Acceptance Criteria:**

**Given** the three existing harnesses
**When** I look for one that can measure a prompt change
**Then** none can: `SummarizeEvalHarness` stubs the Anthropic response so the request is never read, `StrategyComparisonRunner` makes real calls but leaves recall and precision to hand-scoring, and `Tests/regression/ami/run.sh` scores automatically but transcribes audio first
**And** this story joins them rather than adding a fourth: it reuses `StrategyComparisonRunner`, its existing `substring:<absolute prompt dir>` arm grammar, and the scoring logic of `Tests/regression/ami/score.py`
**And** it invokes `score.py` rather than reimplementing its scorer in Swift, so that Story 4.12's change to the matching rule lands in one place and the bench and the regression suite cannot drift apart; the Swift side owns fixture loading, arm wiring and the score translation, which is what `swift test` covers

**Given** the bench verb
**When** I run it over the fixture set
**Then** it loads `transcript.json` and `expected.json` from each directory named by `Tests/regression/ami/manifest.json` (four under `Tests/SummarizeTests/Fixtures/eval/`, one under `Tests/regression/ami/reference/`)
**And** it calls the real summarizer once per arm per transcript, renders the note through the shipped mapper and renderer, and scores the rendered note
**And** it never loads WhisperKit, never reads audio, never writes a vault note outside a temporary directory and never touches the state database
**And** it prints recall and false keeps per arm per meeting, plus the set total, in the same shape `score.py report` prints

**Given** the AGENTS.md pitfall that `App/`-only logic has no test coverage
**When** the bench is implemented
**Then** its logic lands in a `Sources/` module with a thin CLI wrapper, so `swift test` covers the fixture loader, the arm wiring and the scoring translation
**And** the paid call itself is not exercised by `swift test`

**Given** a run of the full fixture set with one arm
**When** it completes
**Then** it takes under two minutes and costs under $0.30, measured from the telemetry the run reports

---

### Story 4.12: Score the Item, Count the False Keeps

As the maintainer,
I want recall to credit an expected item that the note carries under a different quote, and precision to be counted alongside it,
So that the Epic 4 number measures whether the item survived — which is what `epics.md` Story 4.10 asks — instead of whether the model happened to quote the same sentence a human curator did, and so that a recall gain bought with fabricated items cannot pass unobserved.

**Acceptance Criteria:**

**Given** `Tests/regression/ami/score.py` as it stands
**When** an expected item is matched
**Then** the only test is word overlap of at least 0.5 between the expected quote and a note block quote, so a correct item quoted from a different passage of the same discussion scores zero
**And** nothing counts a kept item that matches no expected item, so precision is unmeasured across the whole gate

**Given** the amended scorer
**When** it scores a note
**Then** an expected item counts as recalled if its quote overlaps a note block quote at or above the existing threshold, **or** its `text` matches a kept item's text at or above a stated item-text threshold
**And** the item-text threshold is recorded in `thresholds.json` alongside the others, with its calibration written in the commit message
**And** `false_keeps` is reported per meeting and for the set: kept items matching no expected item by either test
**And** `score.py report` prints both, and a false-keep count worse than the recorded baseline is a breach like any other threshold

**Given** the 2026-09-21 Part B run at revision `74a3d80`
**When** its notes are re-scored under the amended scorer
**Then** the seven kept items that matched no expected quote are classified: false keep, or right item quoted from the wrong passage
**And** the classification and the re-scored recall are recorded in `Tests/fixtures/epic4-exit-results.md` as a re-score of that run, distinct from a new run
**And** if the notes from that run are gone, one Story 4.11 bench run regenerates them

**Given** the re-scored number is higher than 42.1%
**When** it is recorded
**Then** the record states plainly that a scoring correction cannot close the gap on its own: 15 items were kept against 19 expected, so perfect alignment caps at 78.9%, below the 80% floor
**And** `Tests/scripts/run-epic4-exit-criteria.sh` uses the same two-test rule, so the exit script and the regression suite stop disagreeing

---

### Story 4.13: Prompt Recall Pass

As the maintainer,
I want the summarization prompt iterated against the bench until item recall clears 80% without a worse false-keep count,
So that Epic 4's exit gate is met by the summarizer actually surfacing what the meeting settled, rather than by moving the floor to meet the summarizer.

**Acceptance Criteria:**

**Given** the measured behaviour
**When** the prompt is examined against it
**Then** four findings name the starting arms: output volume is flat at 4-5 items against expected counts of 3, 8, 1, 4 and 3; `system.md` rule 5 instructs "Prefer precision over coverage... A short list, or an empty array, is a correct answer" while no gate measures precision; rule 2 excludes "targets or requirements handed to the group from outside" and "ideas that are floated or debated," which describes three of ES2002b's four expected decisions; and the model tends to quote the opening of a passage rather than its decisive line

**Given** each arm
**When** it is run on the bench
**Then** it is a prompt directory, compared against the shipped set as the control arm in the same run
**And** every arm's recall, false-keep count and cost are recorded in a results file under `Tests/fixtures/`, one row per arm, with the prompt directory's diff from the control summarised in the row

**Given** rule 2's conflict with the ES2002b labels
**When** it is resolved
**Then** the resolution goes one way or the other explicitly: the rule narrows to admit a target the group adopts as its own working frame, **or** those expected items leave the fixture with the rationale written into that fixture's `expected.json` `notes` field
**And** the choice is not left implicit in a prompt reword

**Given** the stopping condition
**When** an arm reaches at least 80% item recall with a false-keep count no worse than the Story 4.12 baseline
**Then** that arm's prompt directory replaces `Sources/Summarize/Prompts/summarize/`, `Tests/regression/ami/thresholds.json` raises `min_item_recall` to guard the new baseline, and the story is done
**And** the telemetry `summarization_prompt_set_hash` changes, so the improvement is attributable in `history.jsonl`

**Given** arms stop improving below 80%
**When** the story ends
**Then** it ends at the maintainer decision gate rather than at a prompt change nobody measured: at 65% to 79% the maintainer chooses between a multi-pass amendment (PM and Architect, reopening FR32, FR71 and Decision 5.6) and moving Story 4.10's floor to the achieved number with the rationale written into `epics.md`; below 65% it escalates
**And** FR32 ("a single primary Claude call per meeting; chain-of-summarize is explicitly deferred to v2+") stands until such an amendment lands, so no arm in this story makes more than one primary call

**Given** the story ran and disproved the premise its decision gate was written on (`spec-4-13-prompt-recall-pass.md`, 2026-09-21)
**When** the gate above is exercised
**Then** the multi-pass option is struck: the same prompt scores 84% on reference transcripts and 74% on the pipeline's own WhisperKit output of the same audio, so a second summarization pass cannot recover text that was never transcribed
**And** the transcription shortfall is resolved by Story 4.14, not by an ASR swap: the missing text was whole 30-second windows that WhisperKit's first-token log-probability gate ended empty while the app's disabled temperature fallback refused to retry them (`sprint-change-proposal-2026-09-21.md`); unsetting the gate restores 12 points of reference content and drops no window, and the full pipeline under the fix scores 74% on diarized text with WER 0.20 to 0.25
**And** the 80% floor stands (maintainer, 2026-09-21): it is reachable on clean text, the residual after the fix is summarizer under-production on ES2002b and ES2004a, and Story 4.15 owns it with a stop condition of 16 of 19 on a recorded full-pipeline run or an explicit fixture ruling
**And** the Parakeet-TDT path is conditional, not designed: it starts only if a recorded full-pipeline run under Story 4.14 shows expected-item quotes absent from the transcript rather than present and unextracted

### Story 4.14: Retention — Unset the First-Token Gate, Measure Dropped Text

As the maintainer,
I want the transcribe stage to keep every window WhisperKit can decode and the regression suite to report how much reference text has no transcript at all,
So that a decoding gate cannot remove a fifth of a meeting without a number changing.

**Given** `WhisperKitTranscriber.decodeOptions`
**When** the transcribe stage runs
**Then** `firstTokenLogProbThreshold` is `nil` and `temperatureFallbackCount` stays 0, and the decoding-options test pins both

**Given** `score.py meeting` over a scored meeting
**When** it reports
**Then** it adds the reference content words that fall in a run of 25 or more with no hypothesis text, as a count and a fraction, and `report` prints the fraction per meeting and enforces `max_dropped_reference_fraction` from `thresholds.json`

**Given** the fix and the promoted prompt
**When** Story 4.10 Part B is rerun with `AURICLE_AMI_RECORD=1` three times
**Then** `history.jsonl` carries three complete full-pipeline runs under the promoted prompt, `report` gates item recall, false keeps and dropped fraction on the median of the newest three complete runs under the current revision and prints older runs for context only, and `min_item_recall` is raised from that median with one item of slack

**Given** the summarizer samples at the API default temperature, which `claude-opus-5` does not let a request change, and three runs of byte-identical input scored 10, 10 and 14 of 19
**When** any recall number is recorded or gated
**Then** a single run is a draw, never a result: the gate is the median of three (maintainer, 2026-09-21), and the bar stays 16 of 19

### Story 4.15: Summarizer Under-Production on ES2002b and ES2004a

As the maintainer,
I want to know why the summarizer emits nothing for ES2004a from any transcript and fewer items from a fuller un-diarized transcript,
So that the next prompt change targets a reproduced defect rather than the whole set.

**Given** the 2026-09-21 bench runs over the cached and the fixed transcripts
**When** their kept items are diffed per meeting
**Then** the story records what the summarizer stops emitting when the input grows

**Given** ES2004a's reference transcript
**When** it is summarized with the promoted prompt
**Then** the story records which rule each of the three expected items falls under and whether the model proposes and discards them or never proposes them

**Given** the bench's fixture loader
**When** a WhisperKit-transcript arm is added
**Then** the arm can carry the diarized speaker labels from `attribution.json`, so the bench can test whether per-speaker labels are a recall lever; the summarize stage as shipped passes the `Speaker_1`-only `transcript.json` to the summarizer, so this arm measures a possible pipeline change, not the pipeline as shipped

**Given** the full pipeline and the offline bench over byte-identical `Speaker_1`-only transcripts under the same prompt set
**When** they score 14 of 19 and 10 of 19
**Then** the story names the summarizer input that differs between `SummarizeStage.summarize` and the bench runner before any prompt arm is run

**Given** arms run one finding at a time, each claim of movement resting on the median of three bench runs
**When** the median of three recorded full-pipeline runs under one revision reaches 16 of 19, or the maintainer rules that ES2004a's items leave the fixture with the rationale in its `expected.json` notes
**Then** the story stops and Epic 4 exits through Story 4.10

---

**Epic 4 summary:**
- **15 stories** sized for single dev-agent completion: 4.1 to 4.10 as planned, 4.11 to 4.15 added for recall remediation
- **Story sequencing matters:** 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8 → 4.9 → 4.10 (4.9 cannot land before 4.1–4.8; 4.10 is the explicit gate)
- **Recall remediation (added 2026-09-20, `sprint-change-proposal-2026-09-20.md`):** 4.11 → 4.12 → 4.13 land after 4.10's first Part B run and before its rerun. They exist because Part B measured 42.1% item recall against 4.10's 80% floor. 4.13 ended at a maintainer decision gate that `sprint-change-proposal-2026-09-21.md` resolved: 4.14 removes the WhisperKit decoding gate that was dropping whole windows and adds a retention metric; 4.15 owns the summarizer residual. Multi-pass extraction is not among the options while FR32 stands.
- **All FRs covered:** FR17 (Story 4.1), FR18 (Story 4.2), FR19 (Story 4.1), FR20 (Story 4.1), FR23 data-side (Story 4.6), FR25 CLI publish-anyway (Stories 4.6 + 4.7), FR27 mechanism (Story 4.6 — the `--speakers` batch path; the documented fallback surface stays [v1.1], Story 10.4), FR42 stub (Story 4.9 — full path in Epic 8), FR43 stub (Story 4.9 — full path in Epic 8), FR73 (Story 4.4), FR74 (Stories 4.3 + 4.5)
- **NFRs primarily verified:** NFR-P3 (Story 4.1 perf test), NFR-P4 (Story 4.2 perf test), NFR-P10 peak memory (Stories 4.1 + 4.2 — WhisperKit subprocess constraint), NFR-Pr1 transcribe local (Story 4.1), NFR-Pr4 first-name speakers + email scrubbing (consumed in Story 4.6 + Epic 3 Story 3.10), NFR-C1 v1.1+ tier (Story 4.5 + Story 4.10 live-run validation), NFR-I8 local-LLM v1.1+ slot (Story 4.4 + Story 4.5 telemetry contract)
- **All architectural commitments addressed:** AR-AI-1 (Story 4.4), AR-AI-2 (Story 4.5), AR-AI-3 (Story 4.3), AR-AI-4 (Stories 4.1 + 4.2 immutability + Story 4.6 segment_splits), AR-AI-5 (Story 4.6 + Story 4.3 telemetry partitioning), AR-AI-6 (Story 4.6 attribution.json schema), AR-AI-7 Path C MVP slot-laying (Story 4.4), AR-AI-8 kill criteria foundation (Story 4.4 telemetry contract), AR-AI-9 wedge-validation foundation (already in Epic 3 Story 3.12), AR-PIPE-6 primary CLI surface (Story 4.7), AR-PIPE-7 hidden subcommand (woven across Stories 4.1, 4.2, 4.3), AR-PIPE-8 CLI conventions (Story 4.7), AR-PIPE-1 in-process persist wiring (Story 4.7), AR-DATA-6 `auricle/needs-summary` tag (Story 4.7), AR-DATA-7 re-publish notification text (Story 4.9)
- **Explicit exit-criteria gate (John + Amelia):** Story 4.10 is the named gate, not a fiction; the ≥80% quote-grounding pass-rate and the NFR-C1 cost ceiling are measured by the live run, and the CI pipeline test guards the plumbing on every PR
- **Type-system parity contract (Sally + Amelia):** Story 4.6 places `AttributionViewModel` in `Attribute/` — Epic 7's GUI sheet imports the same type; FR23/FR25 splits across epics carry no divergence risk
- **No future-story dependencies within the epic:** every story is independently completable in sequence

---

## Epic 5: System-Audio Capture & First-Run Onboarding (J0)

Fresh Mac → user grants permissions through a 4-step onboarding gauntlet → starts a recording → auricle captures meeting audio (system audio from a Core Audio global process tap, mixed with the microphone from AVAudioEngine, into PCM 16-bit 16kHz mono WAV in the cache-dir) → user stops it → the pipeline runs to `awaiting_attribution`. The RecordingIndicator atomic component is the visible privacy contract surface. Mid-capture revocation handling lives here. Pipeline now has auricle-captured audio, not only pre-existing recordings, flowing into Epic 4's transcribe stage.

**Capture runs in the GUI process only in this epic.** The `auricle record` and `auricle stop` verbs stay stubs until Story 9.5, which must choose how `stop` reaches the recording process (Decision 1.1). The TCC grants belong to the app bundle (`com.auricle.app`), not to `auricle-cli`.

### Story 5.1: PermissionChecker + TCC Categories + Deep-Link URLs

As the single user,
I want `Permissions/PermissionChecker.swift` to be the single helper that all callers go through to query or request permission state (System Audio Recording, Microphone, Notifications, Calendar OAuth) per AR-PAT-4 + AR-FAIL-6,
So that the capture stage, onboarding, Doctor (Epic 9), and the notification path consume one consistent API.

**Acceptance Criteria:**

**Given** the `Permissions` target
**When** I declare `PermissionChecker`
**Then** the public API exposes: `func check(_ category: TCCCategory) async -> PermissionStatus`, `func request(_ category: TCCCategory) async -> PermissionStatus`, `func refresh()`, `func remediationDeepLink(for: TCCCategory) -> URL?`
**And** `TCCCategory` has cases `.systemAudioCapture`, `.microphone`, `.notifications`, `.calendarOAuth` per AR-FAIL-6 (Decision 4.4)
**And** `PermissionStatus` has cases `.granted`, `.denied`, `.notDetermined`, `.unknown`
**And** `.systemAudioCapture` always reports `.unknown` from `check`, because macOS has no public API to read the process-tap grant; `request(.systemAudioCapture)` reports `.unknown` without prompting, because `Permissions` cannot call the tap code in `Capture` (`Capture` depends on `Permissions`); Story 5.8 triggers that prompt through `Capture`
**And** checks are memoized for the lifetime of the process; `refresh()` invalidates the memo (called on `NSWorkspace.shared.notificationCenter` settings-change notifications per AR-PAT-PermissionDetection)

**Given** any caller in the codebase
**When** it queries or requests permission state
**Then** it goes through `PermissionChecker` per AR-PAT-4; a custom swiftlint rule rejects `AVCaptureDevice.authorizationStatus(for:)`, `AVCaptureDevice.requestAccess(for:)`, `UNUserNotificationCenter` `notificationSettings()` / `requestAuthorization(options:)`, `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` outside `PermissionChecker.swift`, with a passing and a failing fixture under `scripts/lint-fixtures`
**And** the existing direct calls in `App/Auricle/NotificationDelegate.swift` move behind `PermissionChecker`, and `Sources/Notifications` gains a dependency on `Permissions` if it needs a status

**Given** a denied permission needs remediation
**When** I call `remediationDeepLink(for:)`
**Then** each TCC category returns a System Settings URL that the story verifies opens the right pane on the maintainer's macOS, and the verified URLs are written into Decision 4.4 in `architecture.md`
**And** the candidates to verify first are `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture` and `…?Privacy_Microphone`; the notifications pane is found by the same check
**And** `.calendarOAuth` returns nil (the remediation is the Google OAuth re-auth flow from Story 3.10)

**Given** `App/Auricle/Info.plist`
**When** the story lands
**Then** it contains `NSAudioCaptureUsageDescription` with *"auricle records your meeting audio so it can transcribe what's said."* as a literal key in the file, not an `INFOPLIST_KEY_` build setting (a missing key denies capture silently, with all-zero buffers and no error)
**And** `NSScreenCaptureUsageDescription` is removed, because auricle no longer uses screen capture
**And** the usage strings match Decision 4.4 exactly, including the trailing period
**And** the story records whether macOS ever shows `NSUserNotificationsUsageDescription`, and removes the key if it does not
**And** `scripts/check.sh app` fails when the built `AuricleApp.app` has no `NSAudioCaptureUsageDescription` (checked with `plutil`)

**Given** the test suite
**When** I run `Tests/PermissionsTests/`
**Then** tests cover: memoized status per category; `refresh()` invalidates the memo; `.systemAudioCapture` reports `.unknown`; deep links match Decision 4.4
**And** stages that consume `PermissionChecker` use a test double per AR-PAT-7

---

### Story 5.2: Process-Tap + AVAudioEngine Capture Session + AudioMixer

As the single user,
I want `Capture/CaptureSession.swift` to capture all system audio through a Core Audio global process tap (FR4) and the microphone through AVAudioEngine (FR5), mixed into one mono 16kHz PCM stream by `Capture/AudioMixer.swift`,
So that the captured audio is Whisper-native and covers any meeting platform (Zoom, Meet, Teams, Discord, browser audio) without bot integration.

**Acceptance Criteria:**

**Given** the `Capture` target
**When** I instantiate `CaptureSession(meetingID:)`
**Then** system audio comes from a `SystemAudioSource` protocol whose one implementation builds `CATapDescription(monoGlobalTapButExcludeProcesses:)` excluding auricle's own process, wraps it in a private aggregate device, and reads it with an IOProc (Decision 1.4)
**And** the microphone comes from an `AVAudioEngine` input node
**And** `AudioMixer` resamples both to 16kHz with `AVAudioConverter`, mixes to mono and emits 16-bit signed PCM
**And** the tap is passive: it does not mute (`muteBehavior` unmuted) and adds no perceivable latency to the meeting app per NFR-P13
**And** the deployment target in `App/Project.swift` and `Package.swift` rises to macOS 14.4, the process-tap floor
**And** `Capture` exposes `SystemAudioPermissionProbe.prompt()`, which runs the tap for 1 second and discards the audio, so the system shows the System Audio Recording prompt; Story 5.8 calls it

**Given** the system-audio tap delivers exact-zero buffers for 30 consecutive seconds
**When** the watchdog notices
**Then** it tears down and rebuilds the tap, the aggregate device and the IOProc, at most once per 30 seconds
**And** it counts rebuilds and exact-zero seconds for the capture metadata (Story 5.4)
**And** it never fails the capture: exact zeros also mean "nothing is playing" or "permission missing", and the three cannot be told apart

**Given** the system-audio IOProc stops calling back entirely for 5 seconds (the aggregate device's output device was removed or changed)
**When** the watchdog notices
**Then** it rebuilds the tap the same way, counted in the same rebuild count: a dead IOProc delivers no buffers at all, so the exact-zero check alone can never see it

**Given** Microphone permission is denied at session start
**When** I call `CaptureSession.start()`
**Then** the session records system audio only and reports `micIncluded == false`

**Given** capture is running
**When** `CaptureSession.stop()` is called
**Then** the session flushes both sources, finalizes the WAV (Story 5.3), and returns the path of the completed `audio.wav`
**And** the session is single-use; a new recording gets a new instance

**Given** the test suite
**When** I run `Tests/CaptureTests/`
**Then** tests cover: `AudioMixer` resamples and mixes synthetic input (44.1kHz mic + 48kHz system → 16kHz mono); the watchdog rebuild rule against a fake `SystemAudioSource`; mic-denied records system audio only; start/stop lifecycle is idempotent
**And** tests against a fake `SystemAudioSource` also cover a mid-stream format change, a source that stops delivering callbacks, and a slow writer that must not block the source callback
**And** the story is done on automated tests alone; nothing in it asks the maintainer for live testing, because no ergonomic way to trigger a capture exists until Story 5.6. Live behavior on real meeting apps is checked in Story 5.6

---

### Story 5.3: WAVWriter — Streaming PCM 16-bit 16kHz Mono WAV

As the single user,
I want `Capture/WAVWriter.swift` to stream the mixed PCM to `audio.wav` in the meeting's cache directory as PCM 16-bit 16kHz mono WAV (Decision 1.4),
So that the file is Whisper-native, byte-sliceable for `SnippetExtractor`, 0600, and recoverable after a crash.

**Acceptance Criteria:**

**Given** the `Capture` target
**When** `CaptureSession` creates a `WAVWriter`
**Then** the path is `CacheArtifactWriter.cacheDirectory(for:)` joined with `AudioImporter.audioFileName`, and the directory is 0700
**And** the file is created 0600 at open time per NFR-S3, before any sample is written
**And** the writer uses a `FileHandle` and the WAV header code that `AudioImporter` already has, not `AVAudioFile`; this is the one recorded exemption from `AtomicWriter` (Decision 1.4), because a 115 MB stream that must survive partially cannot be written atomically

**Given** the writer finalizes
**When** `finalize()` runs
**Then** it patches the RIFF and data chunk sizes from the bytes written
**And** `AVAudioFile` reads the result with the expected frame count, 16kHz, 1 channel

**Given** a file whose header was never patched (crash or power loss)
**When** `WAVWriter.repairHeader(at:)` runs
**Then** it rewrites the RIFF and data chunk sizes from the file size, and reports the recovered duration
**And** Story 5.4's recovery path calls it

**Given** the disk fills or a write fails
**When** the writer fails
**Then** it throws `CaptureError.diskFull` or `.streamInterrupted(reason:)` and leaves the partial file on disk

**Given** the test suite
**When** I run `Tests/CaptureTests/WAVWriterTests.swift`
**Then** tests cover: header correctness; 0600 file and 0700 directory; `repairHeader` on a truncated file; the partial file survives a thrown write

---

### Story 5.4: Capture Stage + State-Machine Integration + Crash Recovery + Mid-Capture Revocation

As the single user,
I want `Capture/CaptureStage.swift` to own the `recording → captured` transition, recover an interrupted recording, and hand the meeting to the pipeline,
So that capture state is canonical in SQLite and partial audio is never lost.

**Acceptance Criteria:**

**Given** a start request from the GUI (Story 5.6 now, Story 6.2 later)
**When** `CaptureStage.start()` runs
**Then** it calls a new `StateStore.beginCapture`, which in one transaction INSERTs the `meetings` row in `recording` with `capture_started_at`, `audio_cache_path` and `capture_time_zone`, and writes `stage_events.started`
**And** capture does not go through `StageRunner.run`, which wraps one closure over an existing row; capture is two user-driven calls that can be hours apart
**And** `PipelineTransitions` gains `(.capture, .recording) → [.captured, .captureFailed]`
**And** no permission blocks a start: a denied microphone records system audio only, and System Audio status cannot be read, so every start creates a row

**Given** `meetings.capture_started_at` is stored as a UTC instant
**When** capture starts
**Then** the same transaction stores the IANA zone identifier (`TimeZone.current.identifier`) in a new nullable `meetings.capture_time_zone` column, added by a migration in this story (AR-DATA-5)
**And** the column stays NULL for rows no capture wrote, including Story 4.8's imported meetings
**And** persist and summarize format the note date, the filename date, the `meeting-at-<HHMM>` slug and the generic title in that zone, falling back to the current zone when the column is NULL or names an unknown identifier
**And** a re-publish dates its `--rerun-<date>` suffix in the current zone, not the capture zone, so `PersistStage.TimeSource` carries two zones or the re-run date is formatted separately

**Given** the user stops the recording
**When** `CaptureStage.stop()` runs
**Then** a new `StateStore.finishCapture` writes `capture_ended_at`, `duration_seconds`, `state = 'captured'` and `stage_events.completed` in one transaction (Txn B per AR-PIPE-3)
**And** the `stage_events.completed` metadata carries `mic_included`, `exact_zero_seconds` and `tap_rebuilds`
**And** the GUI then runs `PipelineRunner` in-process with `RunOptions(to: .reviewDiarization)`, so the meeting stops at `awaiting_attribution`; the GUI composition root owns this wiring

**Given** the app launches and a `recording` row has no live session
**When** crash recovery runs
**Then** if the WAV has audio bytes, `WAVWriter.repairHeader` fixes it and the row moves to `captured` with `stage_events` reason `recovered_after_interruption`
**And** if it has none, the row moves to `capture_failed` with reason `interrupted`
**And** Decision 1.2's crash-recovery list includes `recording`

**Given** a permission revocation the OS reports while capturing (an AVAudioEngine or Core Audio error)
**When** the capture stage catches it
**Then** it finalizes the partial WAV, moves to `capture_failed` with reason `permission_revoked_midstream`, and fires a notification through a new `Notifier.fireCaptureFailed(meetingID:reason:)`: *"Recording stopped — a permission was revoked. The partial audio is saved."*
**And** if notifications are denied, it logs at `warn` instead (NFR-R8)
**And** `meetings.audio_cache_path` still points at the partial WAV (DP3)
**And** a System Audio Recording revocation the OS does not report shows up only as exact zeros, which the Story 5.2 metadata records

**Given** transient stream errors
**When** fewer than 3 happen on one source within 30s (Decision 4.2), each source counted on its own
**Then** the stage restarts that source inline with one `stage_events.retried` row per attempt
**And** the third system-audio fault within 30s does not fail the capture: it degrades to microphone-only and retries system audio with a 5s / 15s / 30s / 60s backoff (then every 60s), one `retried` row per attempt, restoring it when a rebuild succeeds; the `completed` metadata records the loss (`system_audio_lost_at`, `system_audio_restored_at`, `system_audio_loss_count`)
**And** losing system audio with no microphone in the mix fails the capture as `all_sources_lost`
**And** the third microphone fault within 30s moves the meeting to `capture_failed` as `transient_stream_errors`, or as `all_sources_lost` when system audio is already lost

**Given** the test suite
**When** I run `Tests/CaptureTests/CaptureStageTests.swift`
**Then** tests cover: start/stop transitions and transactions; crash recovery for both branches; reported revocation saves audio, notifies, and fails; transient restart threshold; idempotent stop (NFR-R5); the zone column, its NULL migration, and fallback; the re-run date uses the current zone
**And** the story records idle CPU with auricle open and not recording, sampled over 60 seconds, against NFR-P11 (≤1%)

---

### Story 5.5: RecordingIndicator Atomic Component (Privacy Contract Surface)

As the single user,
I want a `RecordingIndicator` per UX-DR9 that signals "auricle is recording" without ambiguity,
So that my promise to myself about consent is visible.

**Acceptance Criteria:**

**Given** the new `AppUI` SwiftPM target (GUI view models and SwiftUI components, so `swift test` covers them)
**When** I declare `RecordingIndicator`
**Then** its appearance comes from a pure mapping `RecordingIndicatorAppearance(isRecording:reduceMotion:)` → symbol, tint, label, pulse
**And** active: `record.circle.fill`, `Color(.systemRed)`, label "Recording", pulse 1.0 → 0.7 → 1.0 alpha over 1.4s ease-in-out; with Reduce Motion, no pulse (NFR-A5)
**And** idle: `record.circle`, secondary tint, label "Not recording"
**And** the text label always renders next to the symbol, and `accessibilityLabel` is set (NFR-A1, NFR-A3)

**Given** capture is active
**When** the app window is open
**Then** the indicator shows in the existing window's toolbar; Story 6.2 moves it into the main-window header
**And** the Dock and menubar surfaces are out of scope (v1.1)

**Given** the test suite
**When** I run `Tests/AppUITests/RecordingIndicatorTests.swift`
**Then** tests cover the appearance mapping in every state and a non-empty accessibility label in every state
**And** the story records a manual screenshot check in Light, Dark, and Increased Contrast; no snapshot-testing dependency is added

---

### Story 5.6: Throwaway Debug Record Trigger (Epic 6 Deletes It)

As the maintainer (in builder mode),
I want a debug-only Record / Stop trigger,
So that capture can be exercised end-to-end before Epic 6's main window exists. **FR1 and FR2 are satisfied by Story 6.2's Record button; this story exercises the same `CaptureStage.start` / `.stop` paths.**

**Acceptance Criteria:**

**Given** a Debug build of the app
**When** it launches
**Then** a `Debug > Start Recording / Stop Recording` menu item and `Cmd-Shift-R` toggle capture, wrapped in `#if DEBUG` so neither exists in Release

**Given** capture is not running
**When** the trigger fires
**Then** it calls `CaptureStage.start()` and the Story 5.5 indicator enters the active state
**And** if the microphone is denied, it says the recording will contain system audio only, with the Story 5.1 deep link

**Given** capture is running
**When** the trigger fires
**Then** it calls `CaptureStage.stop()`, the meeting reaches `captured`, and the pipeline runs to `awaiting_attribution` (Story 5.4)

**Given** Epic 6 Story 6.2 lands
**Then** it deletes this trigger, as its own acceptance criteria say

**Given** Epic 5 in isolation
**When** I dogfood it
**Then** I can: launch a Debug build → onboard (Stories 5.7–5.10) → `Cmd-Shift-R` → talk over a meeting → `Cmd-Shift-R` → find `audio.wav` in the cache directory → `auricle attribute <id> --speakers …` and `auricle run <id>` finish the note from the terminal

**Given** the maintainer records real meetings with the trigger as part of normal work
**When** those recordings exist
**Then** they are the live check of the process-tap backend: no separate test session is scheduled
**And** the story spec records, per meeting, the platform (Teams, Meet in Chrome, Zoom), whether the far side is audible, and the capture metadata Story 5.4 writes (`mic_included`, `exact_zero_seconds`, `tap_rebuilds`), read from `stage_events` rather than observed by hand
**And** it records whether an ad-hoc rebuild of the app re-prompted for System Audio Recording
**And** if a real meeting's far side is missing, that becomes a correct-course decision on the ScreenCaptureKit fallback in the capture research report

---

### Story 5.7: OnboardingCoordinator + Welcome / Vault / Obsidian / API Key / Expectation Flow

As the single user,
I want an `OnboardingCoordinator` to drive the J0 onboarding narrative (welcome → permission steps → configure → quiet success) per UX-DR41,
So that Day-1 trust is the gate to Day-30.

**Acceptance Criteria:**

**Given** the `AppUI` target
**When** I declare `OnboardingCoordinator`
**Then** it is a state machine over the steps Welcome → Microphone → System Audio → Notifications → Configure → Done, with the three permission steps supplied by Story 5.8 through a step protocol
**And** SwiftUI views for each step live in `App/Auricle/Onboarding/`; all logic lives in `AppUI`

**Given** the app launches
**When** no onboarding-completed marker exists in the app's Application Support directory
**Then** onboarding runs in the existing window, whether or not `~/.auricle/config.toml` exists (the maintainer already has one)
**And** once onboarding completes, the marker is written and later launches skip it; Settings (Story 9.1) and Doctor (Story 9.2) can re-run any step

**Given** the Welcome step
**When** it renders
**Then** it reads *"Let's get auricle set up — 4 quick steps"* and names them (Mic, System Audio, Notifications, Configure) without firing any TCC prompt

**Given** the Configure step
**When** it renders
**Then** it has four sub-steps:
- vault path picker: defaults to the configured `vault_path` or `~/checkouts/SecondBrain` (AR-DATA-9); validates per Story 2.3; never creates the vault
- Obsidian check: opens `obsidian://open?vault=<vault name>`; success means the URL opened; no test note is written; if Obsidian is not installed, it says *"Install Obsidian to use auricle's vault output"* and does not block
- Anthropic API key: stored with `KeychainAPIKey.write(...)` (Story 3.3); skippable, and summarization is unavailable until it is set (UX-DR41)
- first-meeting expectations: *"Start a recording before your meeting and stop it after. auricle transcribes it on this Mac, then waits for you to name the speakers."*
**And** Story 5.9's `self.wikilink` sub-step sits after the vault picker
**And** calendar connection is not an onboarding step in this epic; it stays with Story 3.10's flow and Settings (Story 9.1)

**Given** onboarding completes
**When** Done renders
**Then** values are written through `ConfigWriter` (Story 5.10) to `~/.auricle/config.toml` per FR59
**And** the window shows a quiet "You're set up" state; the empty meeting list (UX-DR43) belongs to Story 6.3 and the post-onboarding doctor run belongs to Story 9.2

**Given** the test suite
**When** I run `Tests/AppUITests/OnboardingCoordinatorTests.swift`
**Then** tests cover: marker absent → onboarding runs; marker present → skipped; every step transition; the vault picker validation; Obsidian missing does not block; the API key skip path

---

### Story 5.8: J0 Permission Steps (Microphone, System Audio, Notifications)

As the single user,
I want the three permission steps of the J0 gauntlet, each with a *why* line and graceful denied states, per UX-DR41,
So that the TCC flow on Day 1 builds trust.

**Acceptance Criteria:**

**Given** the Microphone step
**When** the user clicks "Grant Microphone access"
**Then** `PermissionChecker.request(.microphone)` shows the system prompt with the `NSMicrophoneUsageDescription` string
**And** granted → next step
**And** denied → *"auricle needs microphone access to capture your voice. You can grant it in System Settings."* with `[Open Settings]` (Story 5.1 deep link), `[Skip]` (recordings will have system audio only, Story 5.2), `[Try Again]` (shown only while status is `.notDetermined`)

**Given** the System Audio step
**When** the user clicks "Allow System Audio Recording"
**Then** `SystemAudioPermissionProbe.prompt()` (Story 5.2) runs a 1-second capture so the system prompt appears with the `NSAudioCaptureUsageDescription` string, and `AppUI` depends on `Capture` for it
**And** because the grant cannot be read back, the step then shows *"If you chose Allow, you're done. If not, you can turn on System Audio Recording for auricle in System Settings."* with `[Open Settings]` and `[Continue]`
**And** the step notes that without it, recordings contain only your microphone

**Given** the Notifications step
**When** the user clicks "Allow notifications"
**Then** `PermissionChecker.request(.notifications)` runs
**And** denied → *"You can still use auricle — summary-ready notifications will be silent. You'll see ready meetings in the main window."* and the step advances (NFR-R8)

**Given** Microphone is denied and System Audio was not allowed
**When** the user tries to record
**Then** the recording still starts (System Audio status is unknowable), and Story 5.2's metadata records whether any audio arrived

**Given** the test suite
**When** I run `Tests/AppUITests/PermissionStepsTests.swift`
**Then** tests cover each step's request path against a `PermissionChecker` double; `[Open Settings]` uses the right deep link; `[Skip]` advances; `[Try Again]` shows only for `.notDetermined`; the System Audio step never claims the grant succeeded

---

### Story 5.9: self.wikilink Setup During Onboarding

As the single user,
I want `self.wikilink` set during onboarding per UX-DR42,
So that Epic 7's "This is me" affordance has a target from the first meeting.

**Acceptance Criteria:**

**Given** Story 5.7's Configure step
**When** the `self.wikilink` sub-step renders
**Then** it pre-fills `[[<NSFullUserName()>]]`, lets the user edit it, and suggests matching wikilink targets from the chosen vault
**And** the confirmed value is written to `self.wikilink` through `ConfigWriter` (Story 5.10)

**Given** a configured `self.wikilink` and a calendar-derived self identity (`CalendarEnrichment`)
**When** a later stage needs the user's wikilink
**Then** the configured value wins and the calendar value is the fallback

**Given** the test suite
**When** I run `Tests/AppUITests/SelfWikilinkStepTests.swift`
**Then** tests cover: the default from the account name; a user override round-trips through `Config.selfWikilink`; vault suggestions against a synthetic vault fixture
**And** the "Set me first…" state for a missing value is Epic 7's to test

---

### Story 5.10: ConfigWriter + `self.wikilink` Key

As the single user,
I want a `ConfigWriter` in `Core` that edits single keys in `~/.auricle/config.toml`,
So that onboarding and Settings can write config without discarding the keys and comments I edit by hand (FR59).

**Acceptance Criteria:**

**Given** the `Core` target
**When** I call `ConfigWriter.set(_ key: String, to value: …)`
**Then** it changes only that key, keeps every other key and comment, and writes through `AtomicWriter`
**And** it creates the file when absent, and never writes a secret (the API key stays in Keychain, NFR-S1)

**Given** `Config`
**When** the story lands
**Then** `Config` reads a `self.wikilink` key as `selfWikilink: String?`

**Given** the CLI
**When** I run `auricle config set <key> <value>`
**Then** it calls `ConfigWriter`, replacing its stub

**Given** the test suite
**When** I run `Tests/CoreTests/ConfigWriterTests.swift`
**Then** tests cover: one key changed with comments and unknown keys preserved; file created when absent; `self.wikilink` round-trips

---

**Epic 5 summary:**
- **10 stories.** Build order, in waves; stories within a wave can run in parallel:
  - Wave 1: 5.1, 5.3, 5.10, 5.5 (no dependencies). Land 5.5 early: it adds the `AppUI` target to `Package.swift`, which 5.7 needs.
  - Wave 2: 5.2 (needs 5.1, 5.3) and 5.7 (needs 5.10 and the `AppUI` target)
  - Wave 3: 5.4 (needs 5.2), 5.8 (needs 5.1, 5.2's `SystemAudioPermissionProbe`, 5.7) and 5.9 (needs 5.7, 5.10)
  - Wave 4: 5.6 (needs 5.4, 5.5), the end-to-end dogfood run
  - Critical path: 5.1 or 5.3 → 5.2 → 5.4 → 5.6. Every story before 5.6 is done on automated tests. The live check of the capture backend happens in 5.6, through the maintainer's normal meetings, because 5.6 is the first story with an ergonomic way to start a recording. Stories 5.2 and 5.4 carry the risk that a real meeting app behaves differently from the fakes.
  - Shared files: `Package.swift` (5.1, 5.2, 5.4, 5.5), `Info.plist` and `scripts/check.sh` (5.1 only), `StateStore` and `PipelineTransitions` (5.4 only).
- **FRs covered:** FR1 and FR2 (5.4 + 5.6; the main-window button is Story 6.2), FR3 (5.5), FR4 (5.2), FR5 (5.2), FR6 (5.1 + 5.8), FR58 initial scaffold (5.7 + 5.9 + 5.10), FR60 mid-capture revocation (5.4)
- **NFRs verified:** NFR-P11 (5.4, measured), NFR-P13 (5.2), NFR-S3 (5.3), NFR-Pr3 (5.3), NFR-Pr7 (5.2; OS-level capture sends nothing to the meeting), NFR-A1 to A6 (5.5, 5.7, 5.8)
- **Architecture:** AR-FAIL-6 (5.1, 5.4, 5.8), Decision 1.4 capture backend and the `WAVWriter` exemption (5.2, 5.3), Decision 1.2 recovery of `recording` (5.4)
- **UX-DRs:** UX-DR9 (5.5), UX-DR41 (5.7 + 5.8), UX-DR42 (5.9), UX-DR44 (5.1), UX-DR45 (5.1). UX-DR43 is Story 6.3's.
- **Forward references, all to later epics:** Story 6.2 deletes 5.6 and moves the indicator; Story 6.3 owns the empty list; Story 9.2 runs doctor after onboarding; Story 9.5 implements `auricle record` / `stop`; Epic 7 owns "Set me first…"
- **Research behind the capture decisions:** `_bmad-output/planning-artifacts/research/technical-scstream-vs-core-audio-process-taps-2026-09-22/research.md`

---

## Epic 6: Single-Window GUI Shell & State Visibility (J6)

User opens auricle, sees the single main window with meeting list, can see per-meeting state at a glance, expand a row inline to see operations console, retry transient failures inline, see retention countdowns + 30-day cost widget + upcoming calendar events strip. Failure-visibility surfaces (Decision 4.6) all wired here.

### Story 6.1: DesignTokens + StateChip Atomic + State-Chip Palette

As the single user,
I want `Sources/Core/UI/DesignTokens.swift` (semantic colors + motion + spacing — no hardcoded values elsewhere) and the `StateChip` atomic component with all 8 variants per UX-DR6 + UX-DR10,
So that every state-rendering surface in the app consumes one token table and one chip atom — color is never the sole conveyor (NFR-A3) by construction.

**Acceptance Criteria:**

**Given** the `Core/UI` directory
**When** I create `DesignTokens.swift`
**Then** the file declares the 9 auricle-specific semantic tokens per UX-DR6: `tokens.recording`, `tokens.statusActive`, `tokens.statusSuccess`, `tokens.statusAwaiting`, `tokens.statusRetryable`, `tokens.statusPermanent`, `tokens.statusBenign`, `tokens.varianceWarning`, `tokens.attributedSpeakerTint`
**And** every token is derived from Apple semantic colors (e.g., `Color(.systemRed)`) — auto-adapting Dark / Light / Increased-Contrast per NFR-A6 + UX-DR64
**And** the spacing constants (`spacing.micro = 4pt`, `spacing.small = 8pt`, `spacing.medium = 16pt`, `spacing.large = 24pt`, `spacing.xlarge = 32pt`) are declared per UX-DR7
**And** tokens are exposed via SwiftUI environment (`@Environment(\.designTokens)`) per UX-DR6

**Given** `StateChip` atomic component
**When** I render it for any meeting state
**Then** the chip variant maps to the canonical state name → `FailureCategory` per AR-FAIL-1 + UX-DR10: recording → red filled `record.circle.fill` "Recording"; transcribing/summarizing/persisting/published → blue `arrow.triangle.2.circlepath` "Transcribing"/etc; verified/retention_expired → green `checkmark.circle.fill` "Verified"/"Audio deleted"; awaiting_attribution/awaiting_verification → yellow `hand.point.up.left.fill` "Awaiting your input"/"Awaiting your review"; *_failed transient → orange `arrow.clockwise.circle` "Retry needed"; *_failed permanent → red outlined `exclamationmark.triangle.fill` "Failed"; silent/discarded → gray `circle.dashed`/`trash` "Silent"/"Discarded"; published_partial → yellow + secondary tint `hand.point.up.left` + `exclamationmark` "Published, needs review"
**And** every chip carries color + glyph + label per NFR-A3 + UX-DR10
**And** `accessibilityLabel` per variant matches the user-facing label string

**Given** any code in the project
**When** it specifies a color
**Then** it MUST go through `DesignTokens` per UX-DR65 — hardcoded `Color(red:green:blue:)` or named hex values anywhere in the codebase are detected by a custom swiftlint rule (extending Story 1.8) and the build is rejected
**And** font sizes use Apple text styles only (`.body`, `.headline`, etc.) per NFR-A4 + UX-DR7 — `.font(.system(size: <int>))` outside `DesignTokens` is also lint-rejected

**Given** the test suite
**When** I run `Tests/CoreTests/StateChipMappingTests.swift`
**Then** snapshot tests verify every canonical state name maps to the correct color token + glyph + label per UX-DR66
**And** snapshots cover both Dark and Light modes + Increased Contrast on/off + Dynamic Type compact/default/accessibility-extra-large per UX-DR66

---

### Story 6.2: MainWindowView Shell + Header + Record Button + Sheet Presenter (Deletes Story 5.6 Debug Trigger)

As the single user,
I want `App/Auricle/MainWindow/MainWindowView.swift` to be the single workflow window per UX-DR1 (Principle 8) — header with Record button + `RecordingIndicator` from Story 5.5 + settings/help affordances; sheet presenter for the Attribution sheet (Epic 7); composition slots for `UpcomingEventStripView`, `OnLaunchBannerView`, `MeetingListView`, `RollingCostFooterView`,
So that the app has a real Record button (not the throwaway debug trigger from Story 5.6, which this story deletes per Winston's review).

**Acceptance Criteria:**

**Given** `MainWindowView` is the top-level container
**When** the user launches auricle
**Then** the window appears with header (Record button + `RecordingIndicator` + ⚙ settings + ? help) at top, then optional `UpcomingEventStripView` (Story 6.7), then optional `OnLaunchBannerView` (Story 6.6), then `MeetingListView` (Story 6.3) filling the body, then `RollingCostFooterView` (Story 6.8) at bottom per UX-DR22
**And** the window is resizable; default size 800×600; minimum ~700×500; size is persisted via `@SceneStorage` per UX-DR4
**And** `@State attributingMeetingID: MeetingID?` is bound to `.sheet(item: $attributingMeetingID) { AttributionSheet(meetingID: $0) }` per UX-DR1 + UX-DR22 — the sheet rises from this window when set; never auto-foreground

**Given** the Record button in the header
**When** the user clicks it (capture not running)
**Then** the action calls `CaptureStage.start(meetingID: MeetingID.generate())` from Story 5.4 — same path the debug trigger exercised
**And** the `RecordingIndicator` from Story 5.5 transitions to the active state (visible in the title bar at minimum per FR3)

**Given** the Record button when capture IS running
**When** the user clicks the button
**Then** the button transforms to `Stop` (or shows a Stop affordance per HIG)
**And** clicking calls `CaptureStage.stop(meetingID:)` from Story 5.4

**Given** Epic 5 Story 5.6's debug trigger
**When** Story 6.2 lands
**Then** the `#if DEBUG` menu item / `Cmd-Shift-R` hotkey from Story 5.6 is **deleted** as part of Story 6.2's implementation per Winston's review
**And** the deletion is verified by a CI grep check (no `#if DEBUG` block referencing `Debug Record` or equivalent appears in the codebase after Story 6.2)
**And** the `RecordingIndicator` moves from the window toolbar (Story 5.5) into this header

**Given** auricle launches cold
**When** the user clicks the Dock icon
**Then** the main window appears interactive within ≤1.5s per NFR-P12

**Given** the test suite
**When** I run `Tests/AppTests/MainWindowViewTests.swift` (snapshot + behavior)
**Then** snapshot tests verify the layout in Dark/Light, multiple text sizes, Reduce Motion on/off
**And** behavior tests verify: Record button click triggers `CaptureStage.start`; sheet presenter binds correctly to `attributingMeetingID`; window-resize persists via `@SceneStorage`

---

### Story 6.3: MeetingListView + MeetingRowView (LazyVStack + Sort Priority + Filter Chips)

As the single user,
I want `App/Auricle/MainWindow/MeetingListView.swift` and `MeetingRowView.swift` to render the meeting list with the row-expand inline IA per UX-DR2, the sort priority from Decision 4.6 (also UX-DR3), and bottom filter chips for verified/discarded visibility,
So that every meeting is legible at a glance and the user can drill into any row's operations console without leaving the main window.

**Acceptance Criteria:**

**Given** `MeetingListView`
**When** I render it
**Then** the view is a `LazyVStack` of `MeetingRowView` cells, observing the `meetings` table via `GRDB.ValueObservation` (in-process per AR-DATA-3) AND a file-watch on `db.sqlite3-wal` via `DispatchSource.makeFileSystemObjectSource` for cross-process changes (subprocess writes from Stories 1.5/4.x)
**And** sort priority per UX-DR3: `recording > awaiting_attribution > awaiting_verification > *_failed (transient before permanent) > transcribing | reviewing_diarization | summarizing | persisting > published > verified > retention_expired > silent | discarded`, then by `capture_started_at desc`

**Given** `MeetingRowView` in collapsed state
**When** I render it
**Then** the row shows: `StateChip` (Story 6.1), meeting title, duration (e.g., "32m"), state-annotation text (e.g., "Audio in 6 days" via `CountdownAnnotation` from Story 6.5; "Recording"; "Retry needed ↻"), chevron `▾` per UX-DR23
**And** clicking the chevron toggles `@State expanded: Bool` (local to the row per UX-DR39 — never put writes in row views)

**Given** `MeetingRowView` in expanded state
**When** the row is expanded
**Then** the inline `OperationsConsoleView` (Story 6.4) renders below the collapsed row content per UX-DR2 + UX-DR23
**And** scroll-jank from variable row heights is acceptable at auricle's data scale (≤100 meetings, working set 5–15 per UX spec Step 9)

**Given** the bottom filter chips
**When** the meeting list renders
**Then** below the list a row of toggle chips appears: `[Show verified · Show discarded]` per UX-DR3
**And** defaults: verified ON; discarded OFF
**And** toggle state persists via `@State`

**Given** the empty state (no meetings, fresh install per UX-DR43)
**When** the meeting list is empty
**Then** the centered text *"Click ⏺ Record to capture your first meeting"* renders in place of the list per UX-DR62

**Given** the test suite
**When** I run `Tests/AppTests/MeetingListViewTests.swift`
**Then** sort-priority test asserts the canonical order across all state combinations
**And** snapshot tests cover: empty list state; single-meeting list; multi-meeting list with mixed states (recording + awaiting_attribution + awaiting_verification + summarization_failed + verified); collapsed and expanded row states

---

### Story 6.4: OperationsConsoleView (Row-Expand Inline Operations)

As the single user,
I want `App/Auricle/MainWindow/OperationsConsoleView.swift` to render the row-expand inline operations per UX-DR2 + UX-DR24: pipeline timeline (Story 6.5), contextual action buttons (Retry / Discard / Open attribution / Keep audio indefinitely), retention countdown via `CountdownAnnotation` (Story 6.5), copy-pasteable `log show` line,
So that every meeting state's actions are one click away in the same window — no popover, no separate panel, no eye/cursor jump.

**Acceptance Criteria:**

**Given** a meeting in any non-terminal state
**When** the user expands its row
**Then** `OperationsConsoleView` renders inside the row showing: meeting metadata line (e.g., "Captured 3 min ago · 5 speakers detected"), `PipelineTimelineView` from Story 6.5 (per-stage glyph for capture / transcribe / review-diarization / attribute / summarize / persist), contextual action buttons (varies by state), `CountdownAnnotation` for retention status (when applicable per FR48), copy-pasteable `log show --predicate 'subsystem == "com.auricle.app" && eventMessage CONTAINS "<meeting-id>"'` line per UX-DR24

**Given** a meeting in `awaiting_attribution`
**When** I view the operations console
**Then** the primary action is `[Open attribution]` `.borderedProminent` per UX-DR57 button hierarchy — clicking sets `attributingMeetingID = <id>` on `MainWindowView`, raising the Attribution sheet (Epic 7)
**And** secondary action is `[Discard]` `.bordered` (Story 6.10)

**Given** a meeting in any transient `*_failed` state (`summarization_failed`, `persist_failed`)
**When** I view the operations console
**Then** the primary action is `[Retry now]` per UX-DR54 — clicking dispatches `auricle run <id>` equivalent via the orchestrator (Story 1.5)
**And** during active retry the row shows inline progress per Decision 4.2: *"Retry 3 of 5 — next attempt in 4s [Stop trying]"* per UX-DR53
**And** clicking `[Stop trying]` cancels the in-flight HTTP request and transitions to `summarization_failed` immediately per UX-DR53

**Given** a meeting in `awaiting_verification` (Epic 8 lands the verification trigger; this story renders the state)
**When** I view the operations console
**Then** the primary action is `[Verify]` (manual verify path per UX-DR51 — full implementation in Epic 8 Story 8.4)
**And** secondary `[Open in Obsidian]` (opens via `obsidian://` URL scheme per FR43)

**Given** a meeting with armed retention timer (per Epic 8 Story 8.5)
**When** I view the operations console
**Then** `[Keep audio indefinitely]` appears as a tertiary text-link per UX-DR57 (full retention override path is v1.1 Epic 10 Story 10.5; the GUI affordance scaffold appears here)

**Given** the contextual actions
**When** the user clicks any action
**Then** it follows the single-inline-confirmation pattern per UX-DR56 — no modal cascade; button transforms in-place to `[Confirm: <action> ›]` for destructive actions; second click commits; click-elsewhere or Esc cancels

**Given** the test suite
**When** I run `Tests/AppTests/OperationsConsoleViewTests.swift`
**Then** snapshot tests verify the console layout for every meeting state; behavior tests verify: action buttons map to correct orchestrator calls; inline progress during retry; copy-pasteable `log show` line is correct

---

### Story 6.5: PipelineTimelineView + CountdownAnnotation Atomic Components

As the single user,
I want `Sources/Core/UI/PipelineTimelineView.swift` (per UX-DR20) and `Sources/Core/UI/CountdownAnnotation.swift` (per UX-DR17) as atomic components consumed by `OperationsConsoleView` and other row-expand surfaces,
So that the per-stage progress visualization and the retention countdown both behave consistently across surfaces and are independently testable.

**Acceptance Criteria:**

**Given** `PipelineTimelineView`
**When** I render it for a meeting at any state
**Then** the view shows per-stage glyphs in order: `capture → transcribe → diarize → review-diarization → attribute → summarize → persist` per UX-DR20
**And** per-stage state mapping: pending = gray outlined glyph; active = blue filled glyph (or animating per UX-DR8 — Reduce-Motion-aware per NFR-A5); completed = green filled `checkmark.circle.fill`; failed = red `exclamationmark.triangle.fill`; skipped = gray `circle.dashed`
**And** stage labels read aloud by VoiceOver — current stage is announced per UX-DR20 + NFR-A1

**Given** `CountdownAnnotation`
**When** I render it for a meeting with armed retention timer
**Then** the view shows plain-text countdown like *"Audio deletes in 5 days"* per UX-DR17
**And** if retention is `'indefinite'`, text is *"Audio kept (indefinite)"*
**And** if `meetings.audio_cache_path` no longer exists on disk (post-retention-expiry), text is *"Audio deleted"*
**And** the text reads as a natural sentence to VoiceOver per NFR-A1

**Given** the `CountdownAnnotation` view
**When** the time-to-deletion is < 24h
**Then** the text shifts to hours (e.g., "Audio deletes in 6 hours") for granularity

**Given** the test suite
**When** I run `Tests/CoreTests/PipelineTimelineViewTests.swift` and `Tests/CoreTests/CountdownAnnotationTests.swift`
**Then** snapshot tests cover all per-stage states + Reduce Motion on/off + Dark/Light per UX-DR66
**And** countdown text variants tested: counting (>24h), counting (<24h hours), indefinite, expired

---

### Story 6.6: OnLaunchBannerView (Failure-Visibility + Attribution-Queue Dual Role)

As the single user,
I want `App/Auricle/MainWindow/OnLaunchBannerView.swift` per UX-DR25 to serve **both** as the failure-visibility on-launch banner (when `awaiting_verification` > 24h or any `*_failed` exists per AR-FAIL-7) AND as the multi-meeting attribution-queue banner ("⏳ N meetings awaiting your attribution — Attribute next ›") per FR77,
So that no captured meeting silently expires (Decision 4.6 "no silent losses" contract) and multi-meeting concurrency is handled via banner + sheet queue per UX-DR1.

**Acceptance Criteria:**

**Given** the banner observes `meetings` table state
**When** any of these conditions hold
**Then** the banner appears non-modally above the meeting list per AR-FAIL-7 + UX-DR25:
- ≥1 meeting in `awaiting_verification` older than 24h: *"3 meetings are waiting for you to confirm them — last one from Tuesday."*
- ≥2 meetings in `awaiting_attribution`: *"⏳ 2 meetings awaiting your attribution — Attribute next ›"* per FR77
- ≥1 meeting in any `*_failed` state: *"1 meeting needs your help"* (or specific count)

**Given** multiple banner conditions hold simultaneously
**When** the banner renders
**Then** the banner shows the most-urgent message (priority: `*_failed` > `awaiting_attribution` queue > `awaiting_verification` stale)
**And** clicking the banner action (e.g., "Attribute next ›") opens the next queued sheet per FR77 sheet-queue + UX-DR1

**Given** the banner has a click target
**When** the user clicks it
**Then** the main window scrolls to the relevant meeting(s) and they are visually highlighted (e.g., subtle `tokens.statusAwaiting` tint background flash for 600ms gated by Reduce Motion)
**And** for the attribution-queue banner, clicking sets `attributingMeetingID = <FIFO-by-capture-stop-timestamp>` on `MainWindowView` per FR77

**Given** no banner conditions hold
**When** the banner observes empty state
**Then** the banner does NOT render per UX-DR62 (no empty-state placeholder — banner just disappears)

**Given** the test suite
**When** I run `Tests/AppTests/OnLaunchBannerViewTests.swift`
**Then** snapshot tests cover: failed-only banner; awaiting-attribution-queue banner; awaiting-verification-stale banner; combined (most-urgent wins); no-banner empty state
**And** behavior tests verify: banner click triggers correct action (sheet rise / scroll-and-highlight); banner observes state changes via GRDB ValueObservation + WAL file-watch

---

### Story 6.7: UpcomingEventStripView (Calendar-Driven Upcoming Events)

As the single user,
I want `App/Auricle/MainWindow/UpcomingEventStripView.swift` per UX-DR26 to render upcoming calendar meetings (e.g., "⌚ Upcoming · Pacific quarterly review · in 14 min ›") in the main window header area,
So that the "click Record" decision is primed by recognition rather than recall — J0/J1 priming.

**Acceptance Criteria:**

**Given** the strip observes the calendar enrichment cache (the same `GoogleCalendarSource` from Epic 3 Story 3.10)
**When** there is at least one calendar event in the next ~2 hours
**Then** the strip renders: clock glyph + "Upcoming" label + event title + relative time (e.g., "in 14 min") + chevron `›` per UX-DR26
**And** the chevron action (click) opens a transient popover or simply scrolls focus to the relevant calendar context (no destination required for MVP — observability primes the user, not navigation)

**Given** there is no upcoming event in the next ~2h
**When** the strip is asked to render
**Then** the strip simply does NOT render (no empty-state placeholder per UX-DR26 + UX-DR62)

**Given** Calendar enrichment is offline / unauthorized
**When** the strip is asked to render
**Then** the strip does NOT render (graceful degradation — `UpcomingEventStripView` reads from a cache, not a live network call; if cache is empty due to offline state, behavior is the same as no upcoming events)

**Given** the test suite
**When** I run `Tests/AppTests/UpcomingEventStripViewTests.swift`
**Then** snapshot tests cover: no-event state (empty render); single-event state; multiple-events state (only the next one displayed); accessibility label includes the time formatting

---

### Story 6.8: RollingCostFooterView (30-Day Cost Widget Reading Epic 1 Telemetry)

As the single user,
I want `App/Auricle/MainWindow/RollingCostFooterView.swift` per UX-DR27 + AR-FAIL-7 to render the rolling 30-day cost widget — aggregate API cost broken down by stage (`summarize`, `reviewing_diarization`),
So that Opus drift, model-swap surprises, and runaway summary-retry costs are visible before the next billing cycle (Mary's catch from party-mode review).

**Acceptance Criteria:**

**Given** the footer observes `telemetry` joined to `meetings` filtered by `meetings.created_at > datetime('now', '-30 days')`
**When** I render the footer
**Then** it issues two GRDB queries per UX-DR27: `SELECT SUM(cost_usd) FROM telemetry t JOIN meetings m ON t.meeting_id=m.id WHERE m.created_at > datetime('now','-30 days')` for summarize spend; `SELECT SUM(diarization_review_cost_usd), summarization_model || '|' || diarization_review_model AS combo FROM telemetry t JOIN meetings m ON t.meeting_id=m.id WHERE m.created_at > datetime('now','-30 days') GROUP BY combo` for reviewer column with model-swap visibility
**And** refresh happens via `GRDB.ValueObservation` on `meetings.updated_at` per AR-DATA-3 + UX-DR27 (this is the legitimate in-process ValueObservation use — GUI-process-local read-only telemetry)

**Given** both sums are NULL or zero
**When** the footer renders
**Then** text reads *"$0.00 spent in last 30 days"* per UX-DR27 (NOT hidden — silence is a signal)

**Given** at least one meeting has cost telemetry
**When** the footer renders
**Then** text reads *"Last 30d: $X.XX (summarize) · $Y.YY (review)"* with the two stage breakdowns visible

**Given** more than one distinct `combo` value appears in the window (model swap detected)
**When** the footer renders
**Then** it surfaces the most recent two with a "→" delimiter: *"Last 30d: $14.20 — opus-4-7+haiku-4-5 → opus-5-0+haiku-4-5"* per UX-DR27

**Given** the test suite
**When** I run `Tests/AppTests/RollingCostFooterViewTests.swift`
**Then** tests cover: empty-state ($0.00 text — not hidden); single-model state; model-swap state with arrow; ValueObservation triggers refresh on telemetry write; query returns correct sum across 30-day window

---

### Story 6.9: App Lifecycle (Stays Alive on Window Close + Cmd-Q Graceful Exit)

As the single user,
I want `App/Auricle/AppDelegate.swift` (an `NSApplicationDelegate` adapter for SwiftUI) per UX-DR2 + FR63 + FR64 to handle: app stays alive on main-window close (capture continues; attribution resumes on next window open); Cmd-Q gracefully stops any active capture and persists in-flight state,
So that the lifecycle mental model "background, not invisible" per UX spec Step 4 holds — and accidental window-close never loses an in-flight meeting.

**Acceptance Criteria:**

**Given** the app is running with capture in progress
**When** the user closes the main window (red close button)
**Then** the app stays alive — Dock icon remains; capture continues; `RecordingIndicator` is still visible (in v1.1 via menubar status; in MVP via Dock badge once Story 10.x lands; for MVP at least the recording continues uninterrupted) per FR63 + UX-DR Recording Indicator
**And** when the user clicks the Dock icon, the main window reopens with the in-flight meeting visible at the top of the meeting list

**Given** the app is running
**When** the user invokes Cmd-Q (or `auricle` quits via Apple menu → Quit)
**Then** `applicationShouldTerminate(_:)` runs the graceful exit sequence: stop any active capture (calls `CaptureStage.stop(meetingID:)` for the in-flight meeting); SQLite WAL checkpoint per AR-DATA-2; persist any in-flight `attribution.json` debounced writes per UX-DR58; flush logs
**And** the in-flight meeting state is persisted to SQLite before the process exits (verified by relaunching auricle and observing the meeting in the expected state)
**And** the quit-time checkpoint is the only WAL checkpoint the app issues itself; between quits SQLite's automatic checkpoint applies (NFR-R10 as reworded)

**Given** the app launches after a graceful Cmd-Q with an in-flight meeting
**When** `Orchestrator/CrashRecovery.swift` runs (Story 1.5)
**Then** the meeting's persisted state determines recovery — for example, if it was `transcribing` at quit time, the orchestrator re-dispatches the transcribe stage idempotently per AR-PIPE-3

**Given** the app launches, after a graceful quit or not
**When** `AppDelegate` finishes launching
**Then** it runs `CrashRecovery.reconcile()` once and starts `RetentionScheduler` per FR46
**And** the stale-detection sweep starts with the app and runs every 10s while the app is foreground and every 60s while it is backgrounded (AR-FAIL-2)
**And** the sweep loop and the reconcile and scheduler wiring live in `Sources/Orchestrator`, so `swift test` reaches them; `AppDelegate` only starts them

**Given** a meeting sits in an active `_ing` state and both `reconcile()` and the sweep examine it
**When** each decides whether the meeting is stuck
**Then** both use one stuck test: the meeting's age (`now - meetings.updated_at`) against the state's budget (AR-FAIL-2), plus a liveness check that no worker still holds the meeting
**And** a meeting that is younger than its budget, or whose worker is alive, is left alone by both: `reconcile()` does not re-dispatch it and the sweep does not fail it, so a worker that outlived its GUI is never raced by a second one

**Given** a `transcribing` meeting
**When** the sweep computes its budget
**Then** the budget scales with the audio's length at 2× NFR-P3's rate, which is 2s of budget per minute of audio and 60s for a 30-minute file, instead of a fixed 60s that a longer recording would outrun while healthy
**And** the other states keep their fixed budgets from AR-FAIL-2

**Given** the app is in the Dock with no main window open
**When** any stage produces a notification (Epic 8)
**Then** the notification fires regardless of window state per FR42 (per UX-DR49 — no auto-foregrounding)

**Given** the test suite
**When** I run `Tests/AppTests/AppLifecycleTests.swift`
**Then** tests cover: window close while capture active → capture continues + Dock icon remains; Cmd-Q during capture → graceful stop + state persists; relaunch after Cmd-Q with in-flight state → CrashRecovery picks up correctly; launch runs `reconcile()` and starts `RetentionScheduler`; the sweep cadence is 10s foreground and 60s backgrounded; `reconcile()` and the sweep give one verdict on the same meeting, and neither touches one that is under budget or has a live worker; the `transcribing` budget grows with audio length; notification fires when window is closed

---

### Story 6.10: Manually Discard from Main Window (FR7 GUI Affordance)

As the single user,
I want a "Discard" affordance in `OperationsConsoleView` (Story 6.4) per FR7 + UX-DR56 single-inline-confirmation,
So that I can manually delete a captured-but-unprocessed meeting (e.g., the silent-meeting J3 case in MVP — captured 2hr of mostly silence by accident) without leaving residue in the cache or vault.

**Acceptance Criteria:**

**Given** a meeting in any pre-publish state (`captured`, `transcribing`, `awaiting_attribution`, `summarizing`, `persisting`)
**When** the user clicks `[Discard]` in the operations console
**Then** the button transforms in-place to `[Confirm: Discard ›]` with explanatory micro-copy per UX-DR56: *"Removes cached audio + state. Vault notes (if any) are NOT touched."*
**And** second click commits; click-elsewhere or Esc cancels per UX-DR56

**Given** the user confirms the discard
**When** the action commits
**Then** the meeting's cache directory at `~/Library/Caches/com.auricle.app/<meeting-id>/` is deleted per AR-DATA-2 file-lifecycle rule (cache-dir cleanup is performed explicitly by the caller before the SQL row delete)
**And** `meetings.state` is set to `discarded` (terminal, benign — per AR-FAIL-1 / Decision 4.1)
**And** `auricle discard <id>` CLI verb (Story 4.7's `RunVerb` family) executes the same action via the same code path (via a shared `DiscardAction` helper or equivalent — single-source-of-truth per AR-PAT-4)

**Given** a meeting in `published` or later (`awaiting_verification`, `verified`)
**When** the user views the operations console
**Then** the `[Discard]` affordance is not shown (or is disabled with explanatory tooltip *"Vault note exists; delete in Obsidian first if you want to discard the meeting"*) — auricle never deletes vault notes per DP4 + AR-DATA-2

**Given** a meeting is being discarded
**When** the action runs
**Then** the row immediately animates out of the meeting list (Reduce-Motion-aware fade per UX-DR60) — no toast, no checkmark per UX-DR61

**Given** the test suite
**When** I run `Tests/AppTests/DiscardActionTests.swift`
**Then** tests cover: pre-publish state → discard removes cache-dir + sets state to `discarded`; published state → discard affordance not available; CLI parity (`auricle discard <id>` and GUI affordance call the same code path)

---

**Epic 6 summary:**
- **10 stories** sized for single dev-agent completion
- **All FRs covered:** FR7 (Story 6.10), FR13 (Stories 6.3, 6.4), FR48 (Story 6.5), FR53 (Story 6.7), FR63 (Story 6.9), FR64 (Story 6.9)
- **NFRs primarily verified:** NFR-P12 (Story 6.2), NFR-A1-A6 (every view), NFR-I3 (Story 6.4), NFR-Pr2 (Story 6.8)
- **All architectural commitments addressed:** AR-FAIL-1 (Story 6.1), AR-FAIL-2 (Story 6.4), AR-FAIL-7 (Stories 6.4 + 6.6 + 6.8)
- **All UX-DRs primarily addressed:** UX-DR1-8, UX-DR10, UX-DR17, UX-DR20, UX-DR22-27, UX-DR52-54, UX-DR56-58, UX-DR60-66
- **Story 5.6 debug-trigger deletion explicitly handled in Story 6.2** per Winston's review
- **No future-story dependencies:** sequencing 6.1 (tokens + atom) → 6.5 (atoms) → 6.2 (shell) → 6.3 (list) → 6.4 (console) → 6.6/6.7/6.8 (parallel composite views) → 6.9/6.10 (lifecycle + discard polish)

---

## Epic 7: Attribution Sheet & AI-Hint UX (J1, J2, J1.7, J9)

When a meeting reaches `awaiting_attribution`, user opens the Attribution sheet (rises from main window — never a separate window per UX-DR1), names speakers via calendar-marked autocomplete + "this is me" pre-select + recurring-meeting auto-prefill, reviews AI-suggested diarization corrections inline (per-paragraph 🤖 chips with Apply/Reject — flag-gated per Path C), or escapes via Publish unattributed. Three rename mechanics. Sheet queue for multi-meeting concurrency. Trust-calibration footer + Cmd-Z UndoManager + persistent revert. Same `AttributionViewModel` from Epic 4 Story 4.6 (lives in `Core/`) — type system is the parity contract.

### Story 7.1: AttributionSheet Shell + Sheet Presentation + Sheet Queue Integration

As the single user,
I want `App/Auricle/MainWindow/AttributionSheet.swift` to be the sheet content per UX-DR28 — presented via `.sheet(item: $attributingMeetingID)` from `MainWindowView`, replacing former separate-window architecture (per UX spec amendments to architecture project structure),
So that attribution is a sheet attached to the main window — never auto-foregrounded; multi-meeting concurrency uses sheet queue + banner counter from Story 6.6.

**Acceptance Criteria:**

**Given** a meeting transitions to `awaiting_attribution`
**When** the user clicks the row OR the banner action ("Attribute next ›") OR the notification (Epic 8 wires the click handler)
**Then** `attributingMeetingID = <id>` is set on `MainWindowView`; `.sheet(item:)` raises the Attribution sheet per UX-DR28
**And** the sheet is **never auto-foregrounded** — only set via explicit user action per UX-DR1 + UX-DR49
**And** sheet size is approximately 600×700, content-fit, non-resizable per UX-DR4 + UX-DR28

**Given** ≥2 meetings simultaneously in `awaiting_attribution`
**When** the user is operating the sheet
**Then** only one sheet is open at a time (sheet queue per FR77 + UX-DR1)
**And** the banner from Story 6.6 displays the pending count: *"⏳ 3 meetings awaiting your attribution — Attribute next ›"*
**And** completing/dismissing/save-for-later'ing the active sheet causes the next queued meeting's sheet to rise (FIFO by `capture-stop` timestamp per FR77)

**Given** the sheet's hierarchy per UX-DR28 + Step 10 Round-2 refinement
**When** the sheet renders
**Then** the layout from top to bottom is: title bar (meeting title + duration + "captured Xs ago"); calendar coverage strip (Story 7.6); speaker rows (the dominant middle / visual center of gravity — Story 7.3); subtle disclosure "▸ Review transcript paragraph-by-paragraph (N with hints)" collapsed by default (Story 7.10 — flag-gated content inside); trust-calibration footer (Story 7.12 — flag-gated); asymmetric bottom-button hierarchy (Story 7.9)

**Given** the sheet is dismissed via `[Save for later]` / Esc / Cmd-W
**When** the user dismisses the sheet
**Then** partial attribution state is preserved via incremental atomic-write to `attribution.json` per UX-DR58 + UX-DR39 — debounced 500ms via `Task.debounce` per Decision 5.4 + AR-AI-6
**And** the meeting stays at `awaiting_attribution` per Decision 4.1
**And** the dismiss handler `await`s the in-flight write Task (per Decision 5.4 cancellation preservation) before SwiftUI tears down the view

**Given** the test suite
**When** I run `Tests/AppTests/AttributionSheetTests.swift`
**Then** snapshot tests cover the sheet layout in: standard variant, AI-flag-on variant, AI-flag-off variant (transcript pane shown but suggestions empty), Dark/Light, Reduce Motion on/off
**And** behavior tests verify: sheet rises from main window via `.sheet(item:)` only; never auto-foregrounds; FIFO sheet queue when multiple awaiting; dismiss preserves partial state

---

### Story 7.2: AttributionViewModel @Observable Wiring + Incremental Atomic-Write Debouncing

As the single user,
I want the GUI binding layer for the `AttributionViewModel` from Epic 4 Story 4.6 (which lives in `Attribute/`) — the `@Observable` lifecycle, the file-watch on `diarization_suggestions.json`, the SQLite ValueObservation for state transitions per AR-AI-5,
So that the same view-model that drives Epic 4's CLI batch attribution drives Epic 7's GUI sheet — the type system is the parity contract.

**Acceptance Criteria:**

**Given** `AttributionSheet` from Story 7.1
**When** the sheet's view model is initialized
**Then** the sheet imports `AttributionViewModel` from `Attribute` (NOT a separate sheet-only view model) per Story 4.6 parity contract
**And** the view model is bound to the sheet via SwiftUI `@Observable` macro per UX-DR39

**Given** the sheet is opened
**When** the view model `init` runs
**Then** it executes the check-then-watch sequence from AR-AI-5: (a) read `meetings.state` via `StateStore` — if it's `awaiting_attribution` or beyond, the suggestions file is guaranteed to exist (or be the empty-stub when flag-off); read `diarization_suggestions.json` directly via `Core/CacheArtifactWriter`'s read-side counterpart; (b) if the meeting is still `reviewing_diarization`, render the sheet with a "🤖 analyzing…" indicator at the top of the (collapsed) transcript pane and start watching

**Given** the file-watch on cache-dir
**When** `diarization_suggestions.json` may not exist yet
**Then** Watcher A: `DispatchSource.makeFileSystemObjectSource` on the parent cache-dir for `.create`/`.delete` events AND on the file itself for `.write` once it appears, with 100ms debounce per AR-AI-5 + Decision 2.1
**And** Watcher B: `GRDB.ValueObservation` on `meetings WHERE id = ?` (in-process, GUI-only — combined with `DispatchSource` on `db.sqlite3-wal` for cross-process change detection per AR-DATA-3)
**And** Watcher A re-renders the suggestions content; Watcher B updates the sheet's "🤖 analyzing…" → "ready" affordance per AR-AI-5

**Given** the race-loss fallback per AR-AI-5
**When** Watcher A misses the `.create` event (DispatchSource race when file is created near sheet-open)
**Then** Watcher B catches state advance to `awaiting_attribution` and triggers a one-shot "read the file directly" path that bypasses the file watcher
**And** belt + suspenders: state advance is the canonical signal; file watch is the latency optimizer per AR-AI-5

**Given** the view model
**When** any user mutation occurs (rename speaker, reassign segment, apply AI split)
**Then** the mutation flows through the `AttributionViewModel`'s methods (NOT direct row-view writes per UX-DR39)
**And** the debounced atomic-write Task runs 500ms after the latest mutation: `Task { try await Task.sleep(for: .milliseconds(500)); let draft = await viewModel.snapshot(); try AtomicWriter.write(draft, to: cacheURL) }` per Decision 5.4 — cancellation-safe pattern per UX-DR39

**Given** the test suite
**When** I run `Tests/AppTests/AttributionViewModelGUIBindingTests.swift`
**Then** tests cover: file watch picks up suggestions file creation; SQLite ValueObservation triggers state-advance UI update; race-loss fallback path (delete + recreate the file rapidly); debounced write fires once after rapid mutations; `await`ed dismiss flushes pending write

---

### Story 7.3: SpeakerRow Composite + Autocomplete Priority Order

As the single user,
I want `App/Auricle/MainWindow/SpeakerRow.swift` per UX-DR29 — composes `SnippetPlayer` (Story 7.4), `WaveformView` (Story 7.4), `ThisIsMeButton` (Story 7.5), autocomplete `TextField` with priority order per UX-DR33,
So that the speaker rows are the dominant middle of the sheet (visual center of gravity per UX-DR28 hierarchy refinement).

**Acceptance Criteria:**

**Given** `SpeakerRow` is rendered for a detected `Speaker_N`
**When** the row appears
**Then** the layout shows: snippet player (▶/⏸ button + waveform + duration text), `ThisIsMeButton`, autocomplete `TextField` for typing/selecting a name, status indicator (✓ when attributed, undo affordance when heuristic-pre-filled, optional `AIHintChip` for over-segmentation case per UX-DR12), per UX-DR29 + the sheet anatomy diagram from UX spec Step 10

**Given** the autocomplete priority order per FR23 + UX-DR33
**When** the user types into the autocomplete
**Then** suggestions appear in this order:
1. **Calendar attendees** of the current meeting (visually marked via `CalendarAttendeeBadge` from Story 7.6 — `person.crop.circle.badge.checkmark` glyph + accent tint per UX-DR8 + UX-DR13)
2. **Existing vault wikilink targets** (from `VaultGlossaryBuilder` from Epic 3 Story 3.12 — read-only access through the glossary cache)
3. **Previously-labeled speakers** (with frequency/recency tie-breakers — read-only access through SQLite `meetings` joined to past `attribution.json` content)

**Given** the user accepts a suggestion
**When** Enter is pressed (or click)
**Then** the field collapses to a chip (`[[Name]]` formatted), row tints subtle green via `tokens.attributedSpeakerTint` per UX-DR6, ✓ appears at right per UX-DR29 + UX spec Step 10 feedback table
**And** the speaker mapping is written to `attribution.json` `speakers[Speaker_N] = "[[Name]]"` via the view model (Story 7.2) — debounced atomic write
**And** all paragraphs labeled with that Speaker_N update to render with `[[Name]]` (default global rename mechanic per UX-DR32)

**Given** the user types a name not yet in any priority tier (a new wikilink target)
**When** the user accepts the typed text via Enter
**Then** the field accepts the value as a new `[[wikilink]]` (Obsidian creates new notes from unresolved wikilinks on click per UX spec Step 7)
**And** no error is shown — free typing is permitted per UX spec Step 7 failure-modes table

**Given** the test suite
**When** I run `Tests/AppTests/SpeakerRowTests.swift`
**Then** tests cover: autocomplete priority order (calendar > vault > previously-labeled with mocks for each tier); accepting suggestion writes correct `attribution.json`; new wikilink free typing; chip-collapse + green tint + ✓ visual feedback; row tint via `tokens.attributedSpeakerTint`

---

### Story 7.4: SnippetPlayer + WaveformView Atomics

As the single user,
I want `Sources/Core/UI/SnippetPlayer.swift` per UX-DR14 and `Sources/Core/UI/WaveformView.swift` per UX-DR15 as atomic components consumed by `SpeakerRow` (Story 7.3),
So that per-speaker representative audio playback is fast (≤200ms cold per NFR-P7), keyboard-accessible (Spacebar plays focused snippet per NFR-A2), and the waveform animates from a pre-computed envelope (no live FFT cost).

**Acceptance Criteria:**

**Given** `SnippetPlayer`
**When** I render it for a `Speaker_N`
**Then** the visual is `▶` (idle) or `⏸` + animated waveform progress (playing) per UX-DR14
**And** clicking the button (or Spacebar with focus per NFR-A2) plays the corresponding `snippets/speaker_N.wav` from cache-dir via a pre-loaded `AVAudioPCMBuffer` per UX-DR14
**And** the buffer is **warmed on sheet appear** (~5MB total for 7 speakers per UX spec Step 7 implementation notes) — NOT lazy-loaded on first click
**And** cold first-play latency is ≤200ms per NFR-P7

**Given** the snippet duration is configurable
**When** snippets are extracted in Epic 4 Story 4.2
**Then** the duration matches `attribution.snippet_duration_seconds` from config (default 8 per UX-DR47)

**Given** `WaveformView`
**When** I render it for a `Speaker_N`
**Then** the visual is the pre-computed amplitude envelope from `snippets/speaker_N.envelope` (Float32 array, ~200 samples per UX-DR15) read from cache-dir
**And** static rendering is the default; during playback the view animates progress (e.g., a fill/highlight scrolling left-to-right) per UX-DR15
**And** the envelope is decorative; `accessibilityLabel` reads "Audio waveform, N seconds" per UX-DR15

**Given** snippet playback fails (file unreadable, codec error)
**When** the user clicks ▶
**Then** an inline row error appears per UX spec Step 7 failure-modes: *"Couldn't play snippet — file at `~/Library/Caches/.../speaker_3.wav` is unreadable."*
**And** attribution still proceeds via typing (failure is non-blocking)

**Given** the test suite
**When** I run `Tests/CoreTests/SnippetPlayerTests.swift` and `Tests/CoreTests/WaveformViewTests.swift`
**Then** tests cover: cold-play latency benchmark (≤200ms); Spacebar plays focused snippet; concurrent plays halt prior playback; envelope renders correctly; playback failure shows inline error; Reduce Motion disables waveform animation per NFR-A5

---

### Story 7.5: ThisIsMeButton + Heuristic Pre-Select

As the single user,
I want `Sources/Core/UI/ThisIsMeButton.swift` per UX-DR21 — `.bordered` style with idle / active / disabled ("Set me first…") states, plus the heuristic that pre-selects the longest-cumulative-speaking row as `self.wikilink` on sheet open per UX-DR42,
So that the most frequent single label gets a dedicated affordance and a recurring meeting where I'm the dominant speaker requires zero clicks to attribute "me."

**Acceptance Criteria:**

**Given** `ThisIsMeButton`
**When** I render it on a `SpeakerRow`
**Then** states per UX-DR21: idle (button reads "This is me"), active (button reads "Me ✓" with green tint, row's autocomplete is auto-filled with `self.wikilink` from config per FR58), disabled (button reads "Set me first…" linking to Settings — only when `self.wikilink` is unconfigured per UX-DR42)
**And** clicking the button toggles the active state — clicking again removes the "me" attribution from the row
**And** the button is keyboard-accessible: Cmd-M applies "This is me" to the focused row per UX-DR37

**Given** `self.wikilink` is configured AND the heuristic flag `attribution.heuristic_self_preselect = true` (default per UX-DR47)
**When** the sheet opens
**Then** the longest-cumulative-speaking row (per `diarization.json` segment durations summed per Speaker_N) is auto-pre-filled with `self.wikilink` per UX-DR21 + UX spec Step 7
**And** the row shows a subtle "(you)" tag and an inline `[undo]` affordance per UX-DR21
**And** clicking `[undo]` clears the auto-fill; the user can then click `[This is me]` on the correct row

**Given** the first-run case (zero speakers attributed, focus on a row with `[This is me]` button)
**When** the user is figuring out the affordance
**Then** the button shows a subtle attention-pulse (color-state cycling, no motion) per UX-DR21 — gated by Reduce Motion (NFR-A5: under Reduce Motion, no pulse, only color-state shift) per UX-DR9 motion principle

**Given** the heuristic pre-selects the wrong row (rare on 1:1s; more common on multi-party where the user isn't the dominant speaker)
**When** the user clicks `[undo]` on the heuristic-pre-filled row
**Then** the row's auto-fill is cleared; subsequent `[This is me]` click on a different row works normally

**Given** the test suite
**When** I run `Tests/AppTests/ThisIsMeButtonTests.swift`
**Then** tests cover: three states render correctly; heuristic pre-select picks longest-cumulative-speaker; `[undo]` clears pre-fill; Cmd-M applies on focused row; first-run attention pulse with Reduce Motion variant; "Set me first…" disabled state links to Settings

---

### Story 7.6: CalendarAttendeeBadge + CoverageStrip

As the single user,
I want `Sources/Core/UI/CalendarAttendeeBadge.swift` per UX-DR13 + `App/Auricle/MainWindow/CoverageStrip.swift` per UX-DR19 + UX-DR35 — the calendar coverage diagnostic at the top of the Attribution sheet,
So that calendar attendees are visible as gap-awareness signal (matched / unmatched / candidate) and the bottom progress line shows coverage status.

**Acceptance Criteria:**

**Given** `CalendarAttendeeBadge`
**When** I render it for a calendar attendee
**Then** states per UX-DR13: matched (green check ✓ on the badge — attendee matched to a labeled speaker row), unmatched (`•unmatched` annotation — attendee never matched, diarization missed them or they didn't speak), candidate (default badge — attendee not yet matched but still candidate)
**And** `accessibilityLabel`: "From this meeting's calendar invite. Status: matched/unmatched/candidate."

**Given** `CoverageStrip`
**When** I render it at the top of the `AttributionSheet`
**Then** the strip shows per UX-DR19 + UX-DR35: row of `CalendarAttendeeBadge` chips for every calendar attendee
**And** at the bottom of the strip, a progress line: *"3 of 4 speakers attributed · 1 calendar attendee not matched."* per UX-DR35

**Given** calendar enrichment failed (per Epic 3 Story 3.11)
**When** the strip renders
**Then** the strip text is *"No calendar context — fix in Obsidian after"* per UX spec Step 7 failure modes + UX-DR19 "no calendar context" state
**And** autocomplete falls back per UX-DR33 (vault wikilinks → previously-labeled tiers); the `auricle/needs-calendar-enrichment` tag is included in the published note per FR54

**Given** the test suite
**When** I run `Tests/AppTests/CoverageStripTests.swift`
**Then** snapshot tests cover: all-matched state; partial state (mix of matched/candidate/unmatched); all-unmatched state; no-calendar state
**And** behavior tests verify: badge state updates as user attributes speakers (matched count increments); strip re-renders on `attribution.json` change

---

### Story 7.7: VarianceWarningGlyph (Acoustic Over-Segmentation Hint)

As the single user,
I want `Sources/Core/UI/VarianceWarningGlyph.swift` per UX-DR11 — the acoustic diarization uncertainty hint (`⚠ may be 2 voices`) shown on rows where `diarization.json` indicates high intra-segment voice-profile variance,
So that the trust-asymmetry failure mode (under-segmentation: a single missed split becomes a wrong commitment in the vault) is hedged at MVP without manual merge/split UI (which is v1.1).

**Acceptance Criteria:**

**Given** `VarianceWarningGlyph`
**When** I render it for a `SpeakerRow`
**Then** states per UX-DR11: present (yellow `exclamationmark.triangle.fill` SF Symbol per UX-DR8 + tokens.varianceWarning from UX-DR6) or absent
**And** tooltip + descriptive `accessibilityLabel`: "may be 2 voices" per UX-DR11

**Given** `diarization.json` segment metadata indicates high intra-segment voice-profile variance for a Speaker_N
**When** the corresponding `SpeakerRow` renders
**Then** `VarianceWarningGlyph` appears on the row per UX-DR36
**And** the glyph is **non-blocking** — it does NOT gate `[Continue]` per UX-DR36 (the user can play the snippet and judge for themselves; manual merge is v1.1)

**Given** the user observes the warning
**When** they want to investigate
**Then** they play the snippet via `SnippetPlayer` (Story 7.4) to judge whether the row is genuinely one voice or two
**And** in MVP if it's actually two voices, the user can manually assign the same name to multiple rows (renderer collapses to a single attendee in the note per UX spec Step 7 failure modes) OR use Publish unattributed as the time-pressed escape

**Given** the test suite
**When** I run `Tests/CoreTests/VarianceWarningGlyphTests.swift` (or `Tests/AppTests/`)
**Then** tests cover: glyph renders correctly with yellow color + triangle shape; absence renders nothing; tooltip + accessibility label populated; high-variance fixture in `diarization.json` triggers the glyph on the relevant row

---

### Story 7.8: Recurring-Meeting Auto-Prefill (J9 Trust-Compounding)

As the single user,
I want recurring meeting auto-prefill per FR23 + UX-DR33 + Sally's J9 trust-compounding concern — when ≥3 prior labelings of the same calendar attendees exist (`attribution.recurring_meeting_threshold` default 3 per UX-DR47), speaker rows are pre-filled via the previously-labeled tier on sheet open,
So that the **trust-compounding moment** (auricle "remembered Nina from last Tuesday") earns its way as a 1-keystroke completion (Cmd-Enter) for the J9 happy path — Day-30 retention is won here.

**Acceptance Criteria:**

**Given** the user's meeting history in SQLite
**When** the Attribution sheet for a meeting opens
**Then** the view-model checks: among prior `verified` meetings, are there ≥3 meetings with the same calendar event title AND/OR same set of attendees AND each speaker labeled the same way? Use `attribution.recurring_meeting_threshold` from config (default 3) per UX-DR33 + UX-DR47
**And** if yes, auto-prefill each Speaker_N → previously-labeled `[[wikilink]]` mapping in `attribution.json` per UX-DR33

**Given** auto-prefill applies
**When** the user opens the sheet
**Then** all (or most) speaker rows show their `[[Wikilink]]` already attributed with green tint + ✓ per UX-DR29
**And** the user can override individual rows manually (the prefill is a default, not a lock)
**And** the J9 happy path completes in **1 keystroke** (Cmd-Enter to Continue) per UX spec Step 7 success criteria

**Given** the threshold isn't met (e.g., this is the 2nd time this meeting series has been captured)
**When** the sheet opens
**Then** the previously-labeled tier still appears in the autocomplete (Story 7.3) but rows are not auto-pre-filled — the user types/selects manually

**Given** the user explicitly named acceptance criterion (per Sally's review)
**When** I run J9-specific tests
**Then** `Tests/AppTests/RecurringMeetingAutoPrefillTests.swift` asserts: given 3 prior labelings of the same calendar attendees, when the same meeting recurs, then the speaker rows pre-fill via previously-labeled tier with no user input required → 1-keystroke Cmd-Enter completion produces a `published` meeting
**And** other tests cover: threshold of 2 (auto-prefill doesn't fire); threshold customization via `attribution.recurring_meeting_threshold`; partial match (some attendees labeled before, others new)

---

### Story 7.9: Asymmetric Bottom-Button Hierarchy + Keyboard Flow

As the single user,
I want the asymmetric bottom-button hierarchy per UX-DR34 (Sally's Step 10 Round-2 refinement): `[Continue]` primary `.borderedProminent`, `[Save for later]` secondary `.bordered`, "Publish unattributed (⌘⇧↩)" tertiary text-link smaller off to the side, plus the full keyboard flow per UX-DR37 (Tab / Spacebar / Cmd-M / Cmd-Z / Cmd-Enter / Cmd-Shift-Enter / Cmd-W / Esc),
So that there is at most one primary action per surface (UX-DR57) and the time-pressed escape (Publish unattributed) is the named-but-demoted path.

**Acceptance Criteria:**

**Given** the bottom button bar
**When** the sheet renders
**Then** the layout per UX-DR34 + UX-DR57: `[Continue]` `.borderedProminent` (right-side primary action — enabled only when ≥1 speaker attributed); `[Save for later]` `.bordered` (right-side secondary); `Publish unattributed (⌘⇧↩)` plain text + accent color, smaller, positioned at the LEFT side of the bar (visually demoted)
**And** at most one primary `.borderedProminent` button per surface per UX-DR57

**Given** `[Continue]` is clicked (or Cmd-Enter pressed when ≥1 speaker attributed)
**When** the action commits
**Then** attributed speakers render as `[[wikilinks]]` in the published note; remaining unattributed speakers render as `Speaker_N`; tag includes `auricle/needs-attribution` only if any are still `Speaker_N` per UX-DR34 + UX spec Step 7
**And** the sheet dismisses with the confident-dismissal motion per UX-DR60 (`withAnimation(.easeOut(duration: 0.15))` slide-out, gated by Reduce Motion → fade-only fallback)
**And** the pipeline resumes (state advances `attributing → summarizing`)

**Given** `Publish unattributed` is clicked (or Cmd-Shift-Enter pressed)
**When** the action runs
**Then** the link transforms in-place to inline confirmation: *"Publishing now with `Speaker_N` placeholders. Tagged `auricle/needs-attribution` to fix later in Obsidian."* per UX-DR56 + UX spec Step 7
**And** second click commits; click-elsewhere or Esc cancels per UX-DR56
**And** all speakers render as `Speaker_N`; tag includes `auricle/needs-attribution` per FR25

**Given** `[Save for later]` is clicked (or Cmd-W / Esc pressed)
**When** the sheet dismisses
**Then** the meeting stays at `awaiting_attribution`; partial state preserved via incremental atomic-write per UX-DR58 + Story 7.2

**Given** the keyboard flow per UX-DR37
**When** I navigate the sheet
**Then** Tab moves focus between rows / transcript paragraphs / bottom buttons; Spacebar plays/pauses focused snippet OR focused transcript paragraph; ↓/↑ in autocomplete navigate suggestions; Enter accepts selected suggestion; Cmd-M applies "This is me" to focused row; Cmd-Z undoes last attribution change (Story 7.13); Cmd-Enter Continue (when ≥1 attributed); Cmd-Shift-Enter Publish unattributed; Cmd-W / Esc Save for later
**And** mouse-free completion is verified per NFR-A2 — `Tests/AppTests/AttributionSheetKeyboardTests.swift` runs the full 6-keystroke 2-speaker flow with mouse disabled

---

### Story 7.10: [Flag-Gated] AttributionTranscriptPane + TranscriptParagraph + ParagraphPlayButton

As the single user,
I want `App/Auricle/MainWindow/AttributionTranscriptPane.swift` per UX-DR30 — the disclosure-collapsed transcript pane (collapsed by default per UX-DR28 hierarchy refinement) containing `TranscriptParagraph` rows per UX-DR31 + `ParagraphPlayButton` atomic per UX-DR16,
So that the per-paragraph reassign mechanic (UX-DR32 #2) and AI hint surface (Story 7.11 — flag-gated) live below the speaker rows without competing for visual primacy when the user doesn't need them.

> **[flag-gated]** This story ships in MVP with `diarization_review.enabled = false` default per Path C. The transcript-pane disclosure renders, but the AI-hint surface inside (Story 7.11) and the trust-calibration footer (Story 7.12) are dark when the flag is off — Phase 2 v1.1 activates them via config flip.

**Acceptance Criteria:**

**Given** the disclosure
**When** the sheet renders
**Then** below the speaker rows, a divider line + collapsed disclosure: *"▸ Review transcript paragraph-by-paragraph (N with hints)"* per UX-DR28 hierarchy + UX-DR30
**And** the count "(N with hints)" reflects the number of paragraphs flagged by AI review (when `diarization_review.enabled = true`); when flag is off, the count reads 0 (or the disclosure label simplifies to "Review transcript paragraph-by-paragraph")
**And** clicking the disclosure expands the transcript pane below

**Given** the transcript pane is expanded
**When** I view the contents
**Then** a `LazyVStack` of `TranscriptParagraph` rows renders — one per `diarization.json` segment per UX-DR30 + UX-DR31
**And** each `TranscriptParagraph` shows: speaker label (with reassign dropdown per UX-DR32 #2), timestamp (e.g., "0:42"), `ParagraphPlayButton` (▶ Play), the verbatim transcript text for that segment
**And** local `@State` for AI hint expanded per UX-DR31 (Story 7.11 enriches when flag on)

**Given** `ParagraphPlayButton`
**When** I click it (or Spacebar with focus)
**Then** audio plays from the corresponding segment offset using a **shared `AVAudioFile` + seek** (NOT pre-loaded PCMBuffers per UX-DR16 — would blow NFR-P9 memory budget)
**And** single file handle; `framePosition` per play; cold seek <20ms on SSD; meets NFR-P7 ≤200ms
**And** other paragraph playback halts when a new ▶ is clicked

**Given** the per-paragraph reassign dropdown (UX-DR32 #2)
**When** the user clicks the dropdown next to a paragraph's speaker label
**Then** options: existing speaker mappings (rename to a different speaker), [+ new] (free-typed wikilink)
**And** selection records a `segment_override` in `attribution.json` per AR-AI-6 (`{segment_id, speaker, applied_from: 'manual'}`)

**Given** the test suite
**When** I run `Tests/AppTests/AttributionTranscriptPaneTests.swift`
**Then** tests cover: disclosure collapsed by default; expand/collapse animation Reduce-Motion-aware per UX-DR60; per-paragraph play via shared `AVAudioFile`; reassign dropdown writes correct `segment_override`; flag-off renders the pane but no AI-hint chips appear

---

### Story 7.11: [Flag-Gated] AIHintChip Per-Paragraph + Apply/Reject Controls + Reasoning Expansion

As the single user,
I want `Sources/Core/UI/AIHintChip.swift` per UX-DR12 — the 🤖 chip with collapsed (chip only) / expanded (reasoning + Apply/Reject controls) / auto-collapsed (when accept rate < 40% per Decision 5.7) states, rendered per-paragraph in the transcript pane,
So that AI-suggested diarization corrections (FR75) are inspectable by the user — reasoning is **always visible when expanded**, never hidden behind a tooltip per UX spec Step 7 (the user can audit on every interaction).

> **[flag-gated]** Ships in MVP behind `diarization_review.enabled = false` default per Path C. Code is built but suggestions never populate when flag is off; flipping the flag in Phase 2 v1.1 activates without code changes.

**Acceptance Criteria:**

**Given** `AIHintChip`
**When** I render it on a `TranscriptParagraph` for a flagged segment
**Then** states per UX-DR12: collapsed (🤖 chip only with brief inline label like "may be 3 speakers"); expanded (reasoning text + per-suggestion [Apply] / [Reject] buttons + [Apply all] / [Reject suggestions] batch actions); auto-collapsed (when accept rate < 40% over recent meetings, all expanded reasoning collapses by default per UX-DR12 + Decision 5.7)
**And** `accessibilityLabel` per UX-DR12: collapsed-state label summarizes hint count + kind ("AI hint: may be 2 voices"); expanded-state full reasoning text + Apply/Reject buttons are screen-reader navigable
**And** color is never the sole conveyor — chip carries 🤖 glyph + label per NFR-A3 + UX-DR12

**Given** the user clicks the 🤖 chip
**When** the chip expands
**Then** the inline panel shows the AI's reasoning paragraph (e.g., "question-answer-acknowledgment pattern. Proposed split:" per UX spec Step 10 anatomy diagram)
**And** below the reasoning, per-segment options like *"[Speaker_2?] 'who will take the action item...' [✓]"* with [Apply] buttons per row
**And** batch [Apply all] / [Reject suggestions] buttons at the bottom of the panel

**Given** the user clicks [Apply] on an individual proposed split
**When** the action commits
**Then** a `segment_split` entry is added to `attribution.json` per AR-AI-6 (`{original_segment_id, applied_from: 'ai_suggestion', suggestion_id, splits: [...]}`)
**And** the renderer (Decision 5.4 pure function) recomputes the `RenderedTranscript` to show the split in the transcript pane
**And** the row's `appliedFrom` indicator updates to `.aiSuggestion(suggestionId:)`

**Given** the user clicks [Reject] (or [Reject suggestions])
**When** the action commits
**Then** the suggestion is dismissed; no `segment_split` entry written; the suggestion is hidden for the duration of the sheet (re-opening the sheet may re-show it depending on `diarization_suggestions.json` re-read timing — telemetry counts `diarization_suggestions_rejected_count` per AR-AI-5)

**Given** the auto-collapse trigger per Decision 5.7
**When** rolling 4-week aggregate `applied_count / suggestions_count < 0.40` AND `suggestions_count > 0`
**Then** all 🤖 chips render collapsed by default; user can still expand individually
**And** when `suggestions_count == 0` (silent AI), accept_rate is `nil` and auto-collapse does NOT trigger per Decision 5.7

**Given** the test suite
**When** I run `Tests/AppTests/AIHintChipTests.swift`
**Then** tests cover: collapsed-state render; expanded-state render with reasoning + per-segment Apply; [Apply] writes correct `segment_split`; [Reject] hides chip without writing split; auto-collapse triggered when accept rate < 40%; auto-collapse NOT triggered when suggestions_count == 0; flag-off path renders the transcript pane but no chips

**Given** non-empty `segment_overrides` or `segment_splits` in `attribution.json`
**When** the summarize stage runs
**Then** it reads the Decision 5.4 `RenderedTranscript`, not the raw speaker labels in `transcript.json`
**And** `diarization.json` segment ids map to utterance indices through `DiarizationArtifact` (Story 4.2)
**And** Story 4.6 leaves this to this story because both arrays are empty on every Epic 4 path

---

### Story 7.12: [Flag-Gated] TrustCalibrationFooter

As the single user,
I want `Sources/Core/UI/TrustCalibrationFooter.swift` per UX-DR18 + UX-DR28 + Decision 5.7 — subtle ambient line in the Attribution sheet showing "🤖 Reviewed N segments, flagged M · Accept rate: X/Y this week" reading from `telemetry.diarization_suggestions_*` columns,
So that the trust-calibration data is visible (J1.5 from Mary's review) without competing with the speaker-attribution core.

> **[flag-gated]** Ships in MVP. Hidden when AI flag is off OR no telemetry data exists. Phase 2 v1.1 makes it routinely visible.

**Acceptance Criteria:**

**Given** the footer in `AttributionSheet`
**When** the sheet renders with `diarization_review.enabled = true` AND telemetry has rolling 4-week data
**Then** the footer shows: *"🤖 Reviewed N segments, flagged M · Accept rate: X/Y this week"* per UX-DR18 + UX spec Step 10 hierarchy
**And** the footer is subtle (footnote-style text per UX-DR7) — ambient, not foregrounded

**Given** `suggestions_count == 0` for the rolling window (silent AI, no flagged segments)
**When** the footer renders
**Then** the footer reads *"🤖 Reviewed N segments, flagged 0"* per UX-DR18 + Decision 5.7 explicit-absence-replaces-silent-absence
**And** does NOT read "Accept rate: —/—" (silence is calibration data, not a quality signal)

**Given** `diarization_review.enabled = false` (MVP default)
**When** the sheet renders
**Then** the footer is **hidden** entirely per UX-DR18 (empty state — no placeholder)

**Given** the footer queries
**When** the view-model fetches data
**Then** the query joins `telemetry` with `meetings` filtered by recent window: `SELECT SUM(diarization_suggestions_count), SUM(diarization_suggestions_applied_count), SUM(diarization_suggestions_rejected_count) FROM telemetry t JOIN meetings m ON t.meeting_id=m.id WHERE m.created_at > datetime('now','-7 days')`
**And** rolling refresh via `GRDB.ValueObservation` per AR-AI-5 (telemetry write-authority per Decision 4.5)

**Given** the test suite
**When** I run `Tests/AppTests/TrustCalibrationFooterTests.swift`
**Then** tests cover: visible state with data; explicit-absence "flagged 0" state; hidden state when flag off; query correctness against test fixtures

---

### Story 7.13: Cmd-Z UndoManager + Persistent "Revert This Split" Affordance

As the single user,
I want SwiftUI `UndoManager`-backed Cmd-Z within the sheet session per UX-DR59 + Decision 5.7 + Mary's Round-2 amendment, plus a persistent "Revert this split" affordance on previously-applied AI splits across sheet reopens,
So that every Apply action is reversible — the AI is a hint, not autonomous; every correction passes through the user's eyes per UX spec Step 10.

**Acceptance Criteria:**

**Given** the sheet is open
**When** I make an attribution change (rename speaker, reassign segment, apply AI split)
**Then** the change is registered with the SwiftUI `UndoManager` for the duration of the sheet per UX-DR59
**And** Cmd-Z undoes the most recent action (rename, reassign, applied AI split) per UX-DR37 + UX-DR59
**And** Cmd-Shift-Z redoes (standard macOS pattern)
**And** the undo stack clears when the sheet dismisses (session-scoped per UX-DR59)

**Given** an AI split was applied in a prior session and the sheet is reopened
**When** the transcript pane renders the previously-split paragraph
**Then** an inline "Revert this split" affordance appears next to the split per UX-DR59 + Decision 5.7 + Mary's amendment
**And** clicking "Revert this split" removes the corresponding `segment_split` entry from `attribution.json` per AR-AI-6
**And** the renderer recomputes the `RenderedTranscript` to show the original (unsplit) paragraph

**Given** the test suite
**When** I run `Tests/AppTests/UndoRedoTests.swift`
**Then** tests cover: Cmd-Z undoes most recent rename / reassign / Apply; Cmd-Shift-Z redoes; undo stack clears on sheet dismiss; "Revert this split" persists across sheet reopens (via `attribution.json` content); Revert removes the `segment_split` entry correctly

---

**Epic 7 summary:**
- **13 stories** sized for single dev-agent completion
- **All FRs covered:** FR21 (Story 7.1 — Attribution sheet attached to main window), FR22 (Story 7.4 — snippet playback), FR23 (Stories 7.3 + 7.8 — autocomplete priority + recurring auto-prefill), FR24 (Story 7.5 — "this is me"), FR25 (Story 7.9 — Publish unattributed GUI affordance), FR75 (Stories 7.10 + 7.11 + 7.12 — AI-hint UX in sheet), FR77 (Story 7.1 — sheet queue)
- **NFRs primarily verified:** NFR-P6 ≤2s sheet load (Story 7.1), NFR-P7 ≤200ms snippet playback (Story 7.4), NFR-P9 ≤200MB sheet memory / ~98MB target (Story 7.10 — shared `AVAudioFile` + seek pattern), NFR-A1-A6 (every story's accessibility test)
- **All architectural commitments addressed:** AR-AI-3 (Story 7.2 — subprocess→GUI handoff race-free contract), AR-AI-4 (Story 7.10 — cache-immutability invariant via pure-function renderer), AR-AI-5 (Story 7.2 — sheet-open watcher + telemetry write-authority partitioning), AR-AI-6 (Stories 7.10 + 7.11 — `attribution.json` schema usage with `segment_overrides` + `segment_splits`), AR-AI-7 Path C activation visibility (Stories 7.10–7.12 flag-gated), AR-AI-8 (Story 7.11 — kill criteria foundation via `applied_count/rejected_count` writes; Story 7.12 — trust-calibration footer surfacing)
- **All UX-DRs primarily addressed:** UX-DR12-16, UX-DR18-19, UX-DR21, UX-DR28-40, UX-DR55, UX-DR59
- **Sally's Epic 7.5 carve-out concern resolved:** AI-hint stories (7.10, 7.11, 7.12) are tagged `[flag-gated]` so reviewers identify what activates only on Phase 2 flip — Amelia's "flag-gating already isolates" call wins for solo-dev context
- **Sally's "second meeting" / J9 trust-compounding:** Story 7.8 has explicit AC for the 1-keystroke Cmd-Enter completion on recurring meetings
- **Type-system parity contract:** Story 7.2 imports `AttributionViewModel` from `Attribute/` (Story 4.6) — CLI batch + GUI sheet share the same view-model; FR23/FR25 splits across Epic 4/7 carry zero divergence risk
- **No future-story dependencies within the epic:** sequencing 7.1 (shell) → 7.2 (view-model GUI binding) → 7.4-7.7 (atomic components) → 7.3 (SpeakerRow composes atoms) → 7.5 (heuristic) → 7.6 (coverage strip) → 7.8 (recurring prefill) → 7.9 (bottom buttons + keyboard) → 7.10-7.12 (flag-gated transcript + AI hint + trust footer) → 7.13 (undo + revert)

---

## Epic 8: Verification, Retention & Notifications (J5)

User gets the summary-ready macOS notification, single click both opens the note in Obsidian and arms the 7-day audio retention timer; manual verify covers users who opened directly from Obsidian; 7d/14d reminders fire before deletion. The audio-safety contract (NFR-R3 zero unverified-audio-deletions) is held end-to-end.

### Story 8.1: Notifier + UNUserNotificationCenter Integration + Category Registrar

As the single user,
I want `Notifications/Notifier.swift` to be the single helper for posting `UNNotificationRequest`s + `Notifications/NotificationCategoryRegistrar.swift` to register categories on app launch,
So that every notification (summary-ready, capture-failed, mid-capture-revocation) flows through one helper with consistent payload format per AR-FAIL-5.

**Acceptance Criteria:**

**Given** the `Notifications` target
**When** I declare `Notifier`
**Then** the public API exposes: `func fire(meetingID:, title:, body:, category: NotificationCategory)` per AR-PAT-4 helper-discipline
**And** the helper constructs a `UNNotificationRequest` with `userInfo` payload per AR-FAIL-5: `{meeting_id, schema_version, payload_version}` (snake_case per AR-PAT-2 notification dialect)

**Given** `NotificationCategoryRegistrar`
**When** the app launches
**Then** the registrar registers `UNNotificationCategory` instances for: `.summaryReady` (no inline actions in MVP — click body opens; v1.1 adds inline Verify/Discard actions per AR-PAT-1 NotificationActionIdentifiers); `.captureFailed`; `.midCaptureRevocation`

**Given** the `Notifier`
**When** any caller posts a notification
**Then** the caller MUST go through `Notifier.fire(...)` per AR-PAT-4 — direct `UNUserNotificationCenter.current().add(...)` outside `Notifier.swift` is a code-review reject

**Given** Notification permission has been revoked
**When** `Notifier.fire(...)` is called
**Then** the error is logged at `warn` level per Story 1.3; the call returns successfully (graceful degradation per NFR-R8)
**And** the meeting state still advances appropriately — notification failure is non-blocking per Decision 4.2

**Given** the test suite
**When** I run `Tests/NotificationsTests/NotifierTests.swift`
**Then** tests cover: payload format matches AR-FAIL-5 binding contract; category registration on launch; permission-revoked graceful degradation

---

### Story 8.2: NotificationDelegate + Click Handler + Payload Versioning

As the single user,
I want `App/Auricle/NotificationDelegate.swift` to be the `UNUserNotificationCenterDelegate` adapter that handles notification clicks per AR-FAIL-5 + UX-DR49 + UX-DR50 — extracts the meeting ID from `userInfo`, opens Obsidian via `obsidian://open` URL scheme, calls `Verifier.markVerified(...)` (Story 8.3),
So that the notification click is the single load-bearing wiring path tying FR42 → FR43 → FR44 together.

**Acceptance Criteria:**

**Given** `NotificationDelegate`
**When** the user clicks a notification
**Then** the delegate's `userNotificationCenter(_:didReceive:withCompletionHandler:)` runs per AR-FAIL-5
**And** extracts `meeting_id`, `schema_version`, `payload_version` from `UNNotificationRequest.content.userInfo`

**Given** an unknown `payload_version` from a future binary (e.g., user upgrades auricle and clicks a notification fired by the prior version)
**When** the click handler runs
**Then** the handler **tolerates** the unknown payload version by falling back to "lookup meeting by ID, present in main window" per AR-FAIL-5 — does NOT crash or fail
**And** `UNUserNotificationCenter`'s pending-notifications database surviving `.app` replacement is **verified at implementation time** across Sparkle upgrades (per AR-FAIL-5 verify item)

**Given** the click handler successfully extracted `meeting_id`
**When** the handler runs
**Then** it does TWO things per FR42→FR43→FR44 + UX-DR50:
1. `NSWorkspace.shared.open(URL(string: "obsidian://open?vault=...&file=..."))` — open the note in Obsidian (URL constructed from `meetings.vault_note_path`)
2. `Task { await verifier.markVerified(meetingId: ...) }` — arm the retention timer (Story 8.3)
**And** **both writes happen regardless of whether Obsidian launches successfully** per AR-FAIL-5 (handles "Obsidian not installed" / "vault moved" gracefully — the click is the verification act per FR44; the open is a courtesy)

**Given** the test suite
**When** I run `Tests/AppTests/NotificationDelegateTests.swift`
**Then** tests cover: standard payload → both effects fire (Obsidian URL + verifier call); unknown `payload_version` → lookup-by-ID fallback path; Obsidian URL scheme construction correctness; verifier called with correct meeting ID

---

### Story 8.3: Verifier Actor (Idempotent COALESCE SQL + UNIQUE Constraint Backstop)

As the single user,
I want `Verify/Verifier.swift` to be a Swift `actor` that markVerified all callers (notification click, GUI confirm, `auricle keep <id>` CLI) converge on per AR-FAIL-4 + AR-PAT-4,
So that the audio-safety contract (NFR-R3 zero unverified-audio-deletions) is held by both Swift type-system actor isolation AND SQL idempotency.

**Acceptance Criteria:**

**Given** the `Verify` target
**When** I declare `Verifier`
**Then** the type is a Swift `actor` per AR-FAIL-4 + AR-PAT-6
**And** the public API exposes: `func markVerified(meetingId: MeetingID) async throws`

**Given** the implementation per AR-FAIL-4
**When** `markVerified(...)` runs
**Then** the SQL is idempotent via `COALESCE`: `UPDATE meetings SET verified_at = COALESCE(verified_at, ?) WHERE id = ?` — second call is a no-op if `verified_at` is already set
**And** if the call IS the one that flipped `verified_at` (i.e., the row's previous `verified_at` was NULL), then INSERT into `retention_timers` (`meeting_id`, `armed_at`, `fires_at = armed_at + retention_window`)
**And** if the row's `verified_at` was already set (replay), skip the INSERT
**And** `UNIQUE(meeting_id)` constraint on `retention_timers` is the belt + suspenders backstop — duplicate INSERT throws and is silently caught (we already armed)

**Given** the test suite
**When** I run `Tests/VerifyTests/VerifierConcurrencyTests.swift`
**Then** tests cover: idempotency under cross-process race (two callers race; only one INSERT into `retention_timers`; second is silently caught); idempotency on replay (clicking the same notification twice does nothing the second time); meeting-not-found throws typed `VerifierError.meetingNotFound`; Swift actor serialization holds (no concurrent mutation race within one process)

---

### Story 8.4: ManualVerifyHandler + GUI Confirm Button + `auricle keep <id>` CLI Verb

As the single user,
I want `Verify/ManualVerifyHandler.swift` per UX-DR51 — invoked by `App/Auricle/MainWindow/OperationsConsoleView`'s `[Verify]` button (Story 6.4) AND by `auricle keep <id>` CLI verb (Story 4.7's verb list),
So that users who opened the note from Obsidian directly (skipping the notification click) can still arm the retention timer.

**Acceptance Criteria:**

**Given** `ManualVerifyHandler`
**When** any caller invokes manual verification
**Then** the handler calls `verifier.markVerified(meetingId:)` from Story 8.3 — the same code path as the notification click handler
**And** `auricle keep <id>` CLI verb (`App/auricle-cli/Verbs/KeepVerb.swift` from Decision 1.5) calls `ManualVerifyHandler` per Decision 4.3

**Given** the GUI `[Verify]` button in `OperationsConsoleView` (Story 6.4)
**When** the user clicks it
**Then** the handler is invoked; the meeting transitions `awaiting_verification → verified`; the row's StateChip flips green; the retention countdown appears via `CountdownAnnotation` (Story 6.5)

**Given** the test suite
**When** I run `Tests/VerifyTests/ManualVerifyHandlerTests.swift`
**Then** tests cover: GUI confirm path; CLI `auricle keep <id>` path; both paths share the single `Verifier.markVerified(...)` code; idempotency holds (duplicate clicks are no-ops)

---

### Story 8.5: RetentionScheduler Periodic Background Job + Retention Timer Arming

As the single user,
I want `Orchestrator/RetentionScheduler.swift` (the scaffold from Story 1.5) to be implemented per FR46 — periodic background job polling `retention_timers WHERE status = 'pending' AND fires_at <= now()` and processing due retentions,
So that captured audio is held until the user clicks the verification notification, then a configurable 7-day grace timer (FR46) fires audio cleanup.

**Acceptance Criteria:**

**Given** `RetentionScheduler`
**When** the GUI is foreground
**Then** the scheduler polls every 10 minutes (or some sensible cadence) for due timers per FR46
**And** when backgrounded (window closed but app alive), polls every hour
**And** when the app launches, runs an immediate poll to catch any deferred fires

**Given** a retention timer is due (`fires_at <= now()`)
**When** the scheduler processes it
**Then** the action runs: delete the meeting's cache directory at `~/Library/Caches/com.auricle.app/<meeting-id>/` (not via SQL CASCADE — explicit filesystem cleanup per AR-DATA-2 file-lifecycle rule)
**And** mark the `retention_timers.status = 'fired'`
**And** transition `meetings.state = 'retention_expired'`
**And** the meeting row stays in SQLite as forensic record; only the audio file is deleted

**Given** a retention timer is due and `status = 'pending'`
**When** the scheduler picks it up
**Then** it claims the row before it calls the handler, with one conditional write that moves `status` from `'pending'` to `'fired'` and matches only a row that is still `'pending'` (the `'fired'` mark in the criterion above is this claim, not a second write after the action)
**And** a pass whose claim matches no row (another pass claimed it first, or the user has since set it to `'overridden'`) skips the timer and does not call the handler
**And** if the handler fails, the scheduler moves the row back to `'pending'`, the audio is retained, and the next pass picks the timer up again
**And** the scheduler uses only the `status` values Decision 2.1 defines for `retention_timers` (`'pending'|'fired'|'overridden'`)

**Given** the conservative-by-default principle per NFR-R3
**When** any error occurs during retention processing (filesystem error, SQL error)
**Then** the audio is **retained**, NOT deleted — log at `error` level and surface for user investigation per UX spec Step 4 emotional principles
**And** zero unverified-audio-deletion events tolerated per NFR-R3

**Given** the test suite
**When** I run `Tests/OrchestratorTests/RetentionSchedulerTests.swift`
**Then** tests cover: due-timer fires correct deletion + state transition; not-yet-due timer is skipped; foreground vs backgrounded polling cadences; error during deletion → audio retained, error logged; fresh-launch immediate poll catches deferred fires; a second pass over a claimed timer does not call the handler; a failing handler leaves the row `'pending'`

---

### Story 8.6: 7d / 14d Retention Reminder Notifications

As the single user,
I want auricle to re-prompt me at 7 days post-verification (escalate at 14 days) per FR47 to confirm or extend retention before deletion,
So that audio doesn't silently disappear on me — the conservative retention default biases toward "delete sooner" per NFR-Pr6, but the user is given a chance to override.

**Acceptance Criteria:**

**Given** a retention timer was armed N days ago (where N matches the configured grace window, default 7)
**When** `RetentionScheduler` polls and `fires_at` is within reminder windows
**Then** at 7d post-verification: fire a notification *"Audio for <meeting title> deletes in N days. [Keep] / [Confirm deletion]"* (inline notification actions are v1.1 per Decision 4.2; MVP shows the body and the user opens the main window to act on it)
**And** at 14d post-verification (escalation): fire a more prominent notification with similar messaging
**And** `retention_timers.last_reminded_at` is updated per AR-DATA-1 schema

**Given** the user clicks the reminder notification
**When** the click handler runs
**Then** the main window opens, the relevant meeting row is highlighted, and the operations console shows `[Keep audio indefinitely]` (Story 6.4) and `[Confirm deletion]` actions

**Given** the user takes no action and the timer fires
**When** `RetentionScheduler` processes the due timer (Story 8.5)
**Then** audio is deleted as scheduled; final notification fires *"Audio for <meeting title> deleted (per your retention settings)"*

**Given** the test suite
**When** I run `Tests/NotificationsTests/RetentionReminderTests.swift`
**Then** tests cover: 7d reminder fires once at 7d post-verification; 14d reminder fires once at 14d (NOT a duplicate of 7d); `last_reminded_at` updates correctly; user keep-audio-indefinitely action stops further reminders; final deletion notification fires when timer expires

---

### Story 8.7: Audio Cache Cleanup on Retention Expiry

As the single user,
I want the cache-dir cleanup to run cleanly when a retention timer expires per AR-DATA-2 file-lifecycle rule — file deletion is performed explicitly by the caller before the SQL state transition, never relies on cascade,
So that the cache-dir doesn't leak orphan directories and `meetings.audio_cache_path` continues to reference a forensic record (per AR-DATA-1 field semantics — the column persists even after the file is deleted).

**Acceptance Criteria:**

**Given** a retention timer has expired and `RetentionScheduler` (Story 8.5) is processing it
**When** the cleanup runs
**Then** the meeting's cache directory at `~/Library/Caches/com.auricle.app/<meeting-id>/` is recursively removed via `FileManager.default.removeItem(at:)`
**And** if any file in the directory is unreadable / locked / etc., the cleanup logs the error at `warn` level and continues — does NOT abort the state transition

**Given** the cleanup completed (or partially completed)
**When** the SQL transitions
**Then** `retention_timers.status = 'fired'`, `meetings.state = 'retention_expired'`
**And** `meetings.audio_cache_path` column is **NOT cleared** per AR-DATA-1 — the path persists as a forensic record even though the file is gone

**Given** the user's `meetings.audio_cache_path` still references the (now-deleted) location
**When** the user runs `auricle status <id>`
**Then** the status output reflects "Audio deleted" via `CountdownAnnotation` semantic state per UX-DR17

**Given** the test suite
**When** I run `Tests/OrchestratorTests/RetentionCleanupTests.swift`
**Then** tests cover: directory removed on expiry; partial-failure case (some files unreadable) → cleanup completes what it can + logs + state transitions; `audio_cache_path` column NOT cleared; `auricle status` reflects "Audio deleted" post-cleanup

---

**Epic 8 summary:**
- **7 stories** sized for single dev-agent completion
- **All FRs covered:** FR42 full path (Story 8.1 — Notifier; Story 4.9 was the Epic 4 stub), FR43 full path (Story 8.2 — Obsidian URL open in click handler; Story 4.9 was the Epic 4 stub), FR44 (Story 8.2 + 8.3 — click as verification trigger via Verifier actor), FR45 (Story 8.5 — hold audio indefinitely until verification click), FR46 (Story 8.5 — 7-day grace timer post-click), FR47 (Story 8.6 — 7d/14d reminders)
- **NFRs primarily verified:** NFR-R3 zero unverified-audio-deletion (Story 8.5 — conservative-by-default), NFR-R8 Notification permission revoked → graceful degradation (Story 8.1), NFR-Pr6 conservative retention defaults (Story 8.5)
- **All architectural commitments addressed:** AR-FAIL-4 (Story 8.3 — Verifier actor with idempotent SQL), AR-FAIL-5 (Story 8.2 — notification payload format binding contract), AR-PAT-4 (Story 8.3 — Verifier helper-discipline primitive)
- **All UX-DRs primarily addressed:** UX-DR49 (Story 8.1 — notification → user-initiated engagement), UX-DR50 (Story 8.2 — notification = verification single click both effects), UX-DR51 (Story 8.4 — manual Verify path)
- **No future-story dependencies within the epic:** sequencing 8.1 (Notifier) → 8.2 (NotificationDelegate) → 8.3 (Verifier) → 8.4 (ManualVerifyHandler — depends on 8.3) → 8.5 (RetentionScheduler — depends on 8.3) → 8.6 (reminders — depends on 8.5) → 8.7 (cleanup — depends on 8.5)

---

## Epic 9: Settings, Doctor, Distribution & MVP-Gate Wedge Surface

The MVP gate. Distribution moved here from Epic 1 (Winston). Minimal `auricle stats` (wedge-validation surface) promoted from Epic 10 to MVP (Mary + Amelia). Trust-calibration ACs explicitly named (Mary's J1.5 fix). FR60 hidden coupling resolved (detection-on-launch + Doctor surfacing both here per Winston).

### Story 9.1: SettingsView (Full macOS Settings Scene)

As the single user,
I want `App/Auricle/Settings/SettingsView.swift` per UX-DR47 + Principle 8 carve-out (separate window via macOS Settings scene Cmd-,) — Apple `Form` + `Section` + `LabeledContent` scaffold with all FR58 config knobs auto-saving on field commit,
So that I have full configuration control without leaving the main workflow.

**Acceptance Criteria:**

**Given** the app launches
**When** the user invokes Cmd-,
**Then** the macOS Settings scene appears as a system-driven separate window per UX-DR4 + UX-DR47
**And** the Settings scene contains sections per UX-DR47 + FR58: General (vault path, meetings_subdir, default retention grace window, log verbosity), Summarization (engine choice — Claude / local; model identifier; effort budget; Anthropic API key in Keychain), Calendar (Google OAuth account; re-auth button), Attribution (`self.wikilink`, `attribution.heuristic_self_preselect`, `attribution.show_coverage_strip`, `attribution.snippet_duration_seconds`, `attribution.max_suggestions`, `attribution.recurring_meeting_threshold`), AI Correction (`diarization_review.enabled`, `diarization_review.model`)

**Given** any field is edited
**When** the user moves focus away (commit)
**Then** auto-save fires per UX-DR48 — config writes to `~/.auricle/config.toml` immediately
**And** changes take effect on next pipeline invocation per NFR-M6 — no app restart required

**Given** the API key field
**When** rendered
**Then** the Anthropic API key shows as `••••••••` with `[Update]` button per UX-DR48
**And** clicking `[Update]` reveals an input field; new value is written to Keychain via `KeychainAPIKey.write(...)` from Story 3.3
**And** the Keychain Access app remains the canonical reveal path (auricle does not display the secret value in-app)

**Given** the OAuth re-auth button
**When** clicked
**Then** it opens the system browser → returns; no in-app credential typing for OAuth flows per UX-DR48
**And** new refresh token is stored in Keychain via `GoogleOAuthFlow` from Epic 3 Story 3.10

**Given** field validation
**When** the user enters an invalid value (e.g., non-existent vault path)
**Then** an inline error appears beside the field as `.caption` text in `.systemRed` per UX-DR48
**And** no save buttons exist — auto-save fires only when the value is valid

**Given** the test suite
**When** I run `Tests/AppTests/SettingsViewTests.swift`
**Then** snapshot tests verify the form layout for each section in Dark/Light + Increased Contrast; behavior tests verify auto-save on commit; field validation; OAuth re-auth flow integration

---

### Story 9.2: DoctorView + DoctorVerb (Permissions + Gatekeeper Trust + Vault Path Checks)

As the single user,
I want `App/Auricle/DoctorWindow/DoctorView.swift` per UX-DR46 + Principle 8 carve-out (separate window, user-initiated via Help menu) AND `App/auricle-cli/Verbs/DoctorVerb.swift` per Decision 1.5 — the same checks rendered in two surfaces with conversational narrated remediation hints,
So that system-readiness is one command (or one menu click) away with clear remediation paths.

**Acceptance Criteria:**

**Given** `auricle doctor` from CLI OR Help menu → Doctor in GUI
**When** invoked
**Then** the checks run per AR-FAIL-6 + AR-DIST-2:
1. Microphone permission (`PermissionChecker.check(.microphone)` from Story 5.1) → ✓ granted / ✗ not granted with deep link
2. System Audio Recording (`.systemAudioCapture`) → always `?` (macOS has no public check) + an explanation and deep link
3. Notifications permission (`.notifications`) → ✓/✗ + deep link
4. Gatekeeper trust for the auricle code-signing CA (`GatekeeperTrust.swift` from `Permissions` target — runs `spctl --assess --verbose <bundle-path>` per AR-DIST-2) → ✓/✗ + remediation `scripts/setup-trust.sh` invocation
5. Vault path exists + writable (`VaultWriter` validation from Story 2.3) → ✓/✗ + remediation
6. Anthropic API key configured (Keychain check) → ✓/✗ + "Set in Settings" link
7. Pending count: "N meetings awaiting your verification (oldest: M days)"

**Given** the GUI DoctorView per UX-DR46
**When** rendered
**Then** the format is conversational narrated (NOT red/green checklist): each check is a list item with status glyph (`[OK]` plain default; `✓` with TTY) + label + remediation `Link` element when deep-link
**And** the summary at the bottom states "M of N checks passed. K issues to resolve. P meetings awaiting your verification."

**Given** the CLI DoctorVerb per Decision 1.5
**When** invoked
**Then** the output format matches the architecture's Doctor UX example: per-check `[1 of N] <Check name> ✓ granted` or `✗ not granted` with indented remediation lines pointing to System Settings deep link or `auricle config set` invocation
**And** exit code is 0 if all pass; 2 if any fail per Decision 1.5; System Audio Recording reads `?` and never fails the run
**And** the app runs the checks once, silently, right after Story 5.7's onboarding completes, and the Story 6.6 banner shows only failures

**Given** the test suite
**When** I run `Tests/AppTests/DoctorViewTests.swift` and `Tests/CLITests/DoctorVerbTests.swift`
**Then** tests cover: each check fires correctly with mocked status; remediation links/text are correct; summary aggregates correctly; CLI exit codes correct

---

### Story 9.3: Self-Managed Code-Signing CA + Per-Mac spctl Trust Setup + Bundle Layout

As the single user,
I want the distribution mechanism per AR-DIST-1 + AR-DIST-2 + AR-DIST-3 + NFR-S2 to be set up: self-managed Code-Signing CA + leaf cert; `scripts/setup-trust.sh` (idempotent); Bundle layout (auricle-cli co-bundled in `.app`),
So that auricle installs on a fresh Mac with one-time trust setup (~5 min) and subsequent rebuilds + Sparkle updates flow without re-trust.

**Acceptance Criteria:**

**Given** the originating Mac
**When** I create the personal Code-Signing CA + per-tool leaf cert per AR-DIST-1
**Then** `scripts/create-signing-ca.sh` (idempotent, per AR-PAT-11) generates both artifacts with no GUI step: "Auricle Root CA" (root, self-signed, `basicConstraints=critical,CA:TRUE`, `keyUsage=critical,keyCertSign`, via `openssl req -x509`) and the "Auricle Code Signing" leaf (`openssl x509 -req` signed by the CA, `extendedKeyUsage=codeSigning`), each imported to the login keychain via `security import`
**And** the script is re-runnable: a second invocation detects the existing identity via `security find-identity -v -p codesigning` and exits 0 without creating a duplicate
**And** the leaf is named as `CODE_SIGN_IDENTITY` in `config/Release.xcconfig`, not selected in a signing pane
**And** the CA `.cer` (public certificate, no private key) is checked into the repo at `assets/auricle-root-ca.cer`
**And** the private keys for both CA and leaf live ONLY in the originating Mac's login Keychain — never exported (only that Mac can sign new builds)

**Given** `scripts/setup-trust.sh`
**When** I inspect the script per AR-DIST-2
**Then** the script is idempotent: imports CA cert as trusted root in System.keychain via `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`; computes SHA-256 fingerprint of the CA cert via `openssl x509 -fingerprint -sha256`; registers Gatekeeper assessment policy via `sudo spctl --add --type execute --label 'auricle-root-ca' --requirement 'anchor H"$CA_HASH"'`
**And** the script exits 0 on success with verification message "Trust setup complete. Verify with: spctl --assess --verbose /Applications/Auricle.app"
**And** running the script a second time on the same Mac is a no-op (idempotent)

**Given** `config/Release.xcconfig`
**When** I inspect it per AR-DIST-3 + AR-INIT-3
**Then** `CODE_SIGN_IDENTITY = Auricle Code Signing`, `CODE_SIGN_STYLE = Manual`, `ENABLE_HARDENED_RUNTIME = YES`, and no `com.apple.security.app-sandbox` key appears in `App/Auricle/Auricle.entitlements`
**And** `codesign -dv --entitlements - <bundle>` on the built product confirms all three, so the assertion is against the signed artifact rather than against project settings
**And** no notarization step in the release script

**Given** the `.app` bundle layout per AR-DIST-3
**When** I inspect `Auricle.app/Contents/MacOS/`
**Then** both `Auricle` (GUI binary) and `auricle-cli` (CLI binary, for subprocess dispatch from GUI) are present
**And** the GUI spawns CLI via `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")` per AR-DIST-3
**And** the CLI binary is also installable on `$PATH` via separate copy (e.g., `~/.local/bin/auricle`) for terminal use

**Given** the test suite
**When** I run `Tests/IntegrationTests/DistributionTests.sh` (a shell test, not Swift)
**Then** the test verifies: `scripts/setup-trust.sh` is idempotent; `spctl --assess` succeeds against a freshly-built `.app` after trust setup; `Bundle.main.url(forAuxiliaryExecutable:)` resolves correctly in a built `.app`

---

### Story 9.4: Release Build Script + Signed `.app` / `.dmg` Output

As the single user,
I want `scripts/build-release.sh` per AR-DIST-3 + NFR-M7 — the canonical release script that produces a signed `.app` (or `.dmg`) ready for GitHub Releases,
So that releases are reproducible (same git SHA + same toolchain → identical signed `.app` per NFR-M7) and the release process is one command.

**Acceptance Criteria:**

**Given** the script
**When** I inspect it
**Then** the script runs: `mise install`; `tuist generate --no-open` (the project is generated, not committed, per AR-INIT-1); `xcodebuild archive` for the GUI scheme; `codesign` with the leaf cert chained to "Auricle Root CA" (per AR-DIST-3); package as `.dmg` (or `.app` zip) per AR-DIST-3
**And** the script does NOT run notarization (`xcrun notarytool submit`) per AR-DIST-3 — auricle uses self-managed trust, not Apple notarization
**And** v1.1 extends the script to generate the Sparkle appcast XML with EdDSA signature per FR65 (deferred — out of MVP scope)

**Given** the script runs
**When** the build completes
**Then** the output artifact is at `build/Auricle-<version>.dmg` (or similar) — ready to drop into a GitHub Release
**And** the artifact is signed (verified via `codesign --verify --verbose <bundle-path>`)
**And** running the script twice with the same git SHA + same Xcode version + same `mise.toml`-pinned Tuist version produces byte-identical `.app` contents (verified by `find Auricle.app -type f -exec sha256sum {} \;`) per NFR-M7 — the pinned Tuist version is part of the reproducibility contract per AR-INIT-6, because it determines the generated project

**Given** the bundle identifier and signing identity remain stable across rebuilds and Sparkle updates
**When** Sparkle ships in v1.1
**Then** existing TCC permission grants persist (Microphone, System Audio Recording, Notifications) per NFR-S2

**Given** the test suite
**When** I run a release script test (manual or CI-skipped due to signing requirements)
**Then** the test verifies: artifact appears at expected path; `codesign --verify` succeeds; reproducibility check passes

---

### Story 9.5: Full CLI Verb Surface Completeness (Binding Contract per NFR-I7)

As the single user,
I want all 10 MVP CLI verbs from Decision 1.5 fully implemented per AR-PIPE-6 + AR-PIPE-8 with stable JSON schemas, exit codes, and error format per NFR-I7,
So that the CLI parallel surface is genuinely complete at the MVP gate — every workflow has both GUI affordance and CLI verb (UX-DR67).

**Acceptance Criteria:**

**Given** the binding contract per Decision 1.5 + NFR-I7
**When** I run `auricle help`
**Then** the help output enumerates exactly 10 MVP verbs: `record`, `stop`, `discard`, `run`, `attribute`, `keep`, `list`, `status`, `config`, `doctor` (with `config` having nested `get|set` subcommands)
**And** the bare `auricle` (no subcommand) returns status, not help, per Decision 1.5

**Given** each verb's full implementation
**When** invoked
**Then** the verb behaviors match Decision 1.5 specifications exactly:
- `record [<id>]`: starts capture in the running app (capture runs in the GUI process and holds the TCC grants; Epic 5); ID optional (generates ULID if absent); `--replace` overrides existing audio. This story records how the CLI reaches the app without XPC (Decision 1.1), for example a request row the app polls, and reconciles `--replace` with `audio_cache_path` being immutable after INSERT
- `stop`: reaches the recording app the same way; idempotent
- `discard <id>`: deletes cached audio + meeting state (Story 6.10's `DiscardAction` shared with GUI)
- `run <id> [--force] [--from <stage>] [--to <stage>] [--only <stage>] [--reattribute] [--publish-anyway]`: full run verb per Story 4.7
- `attribute <id> [--batch]`: interactive default per Decision 1.5; with `--batch`: applies last-known mapping or exits 1 per Story 4.6
- `keep <id>`: manual verification per Story 8.4
- `list [--all] [--json]`: lists meetings on this Mac (default: non-terminal)
- `status <id> [--json]`: meeting state + artifact paths + retention status + copy-pasteable `log show` invocation per Story 9.6 (J1.5)
- `config get [<key>]`, `config set <key> <value>`: read/write config
- `doctor`: from Story 9.2

**Given** the JSON schemas per AR-PIPE-8 + Decision 1.5
**When** any inspection verb is invoked with `--json`
**Then** the response carries top-level `"schemaVersion": <int>` per Decision 1.5
**And** schemas for `list`, `status`, `config get`, `--json` errors are documented inline (in code comments + Tests fixtures)

**Given** error handling
**When** any verb encounters a user error / state error / not-found
**Then** exit codes match Decision 1.5: 0 success, 1 user error, 2 state error, 3 not found
**And** default human stderr is one sentence ending with concrete next action per UX-DR52
**And** `--json` mode emits structured error JSON per UX-DR68: `{schemaVersion, error: {summary, meetingId, state, cause, fix, see}}`
**And** the structured form is also written to `os_log` for every error regardless of CLI mode

**Given** flag conflicts per Decision 1.5
**When** the user invokes mutually-exclusive flags
**Then** parse-time rejection with exit code 1 and clear error: `--from <stage>` + `--only <stage>` mutually exclusive; `--publish-anyway` + `--from attribute` / `--only attribute` mutually exclusive; etc.

**Given** the test suite
**When** I run `Tests/CLITests/`
**Then** comprehensive verb coverage per Decision 1.5 binding contract; JSON schema round-trip tests per AR-PAT-2; error format tests; flag-conflict rejection tests

---

### Story 9.6: Trust-Calibration Surfaces (`auricle status <id>` + `log show` Discovery Path)

As the single user,
I want `auricle status <id>` to expose the J1.5 trust-calibration surfaces per Decision 3.7 + Mary's review — `grounding_method`, total items, drop count, and a copy-pasteable `log show` invocation that surfaces per-item grounding details (item text + grounding pointer + transcript span text),
So that I can know **how often** the validator is right (not just that it's right on average) — trust calibration is calibrated, not binary.

**Acceptance Criteria:**

**Given** `auricle status <id>`
**When** invoked for a published meeting
**Then** the output includes per Decision 3.7 + UX-DR67:
- Meeting title, state, capture/publish/verification timestamps
- Vault note path
- Retention status (e.g., "Audio deletes in 5 days" via `CountdownAnnotation` semantic)
- **Grounding method** (`citations` or `substring`) per Decision 3.7
- **Total items** rendered (action items + decisions counts)
- **Drop count** (`quote_validation_drop_count` from telemetry)
- **Copy-pasteable `log show` invocation** that surfaces per-item grounding details: e.g., `log show --predicate 'subsystem == "com.auricle.app" && eventMessage CONTAINS "<meeting-id>" && category == "summarize"' --info`

**Given** the user copies and runs the `log show` invocation
**When** the logs are inspected
**Then** per-item grounding details are visible: item text + grounding pointer (transcript byte range) + transcript span text + `grounding_method` per Decision 3.7
**And** the structured logging from Story 1.3's `Log` facade emits these at `info` level when each item is validated/dropped

**Given** `--json` mode (per Decision 1.5)
**When** invoked
**Then** the structured response includes the same trust-calibration fields under a `groundingDetails` object: `{groundingMethod, totalItems, dropCount, evalCommand}`

**Given** the test suite
**When** I run `Tests/CLITests/StatusVerbTrustCalibrationTests.swift`
**Then** tests cover: published meeting → trust-calibration fields populated correctly; `log show` invocation copy-pasteable + correct subsystem/predicate; JSON mode includes `groundingDetails`; pre-publish meetings → grounding fields are NULL (consistent state)

---

### Story 9.7: Minimal `auricle stats` MVP Impl (Wedge-Validation Surface)

As the single user,
I want a minimal `auricle stats` MVP impl per AR-AI-9 + Mary + Amelia from party-mode review — reads `Core/PipelineState` + `telemetry` counter columns laid down in Epic 1 Story 1.4 to produce: total meetings captured (last 30 days); applied/suggestions ratio + false-positive rate (when AI flag on); `quote_validation_drop_count` aggregate; summarization cost over the dogfood window,
So that **MVP can ship with the instrument that proves MVP worked** — wedge-validation hypothesis (≥40% applied corrections, <20% FP, 4-rolling-week window) is *measurable* at MVP gate.

**Acceptance Criteria:**

**Given** the verb is invoked
**When** I run `auricle stats` (no args, default behavior)
**Then** the output includes per AR-AI-9 + AR-AI-8:
- Total meetings captured (last 30 days; configurable window)
- **AI-correction wedge metric**: applied jargon corrections detected post-hoc from `summary.json` vs `transcript.json` vs `glossary.json` (no new telemetry column needed per AR-AI-9) — % of meetings with ≥1 applied jargon correction over rolling 30 days; flag if <40% (PRD §Business Success criterion)
- **Diarization review metrics** (when `diarization_review.enabled = true` AND telemetry has data): `applied_count / suggestions_count` over rolling 4 weeks; false-positive rate (`false_positive_count` is v1.1 forward-instrumentation per AR-AI-8 — MVP reports this as `n/a — instrumented in v1.1`)
- **Quote-grounding hard-gate metric**: total `quote_validation_drop_count` over the window; per-strategy breakdown
- **Summarization cost**: total spend over the window; per-stage breakdown (summarize / reviewing_diarization)

**Given** the wedge-validation kill-criterion thresholds per Decision 5.7
**When** the rolling metrics are computed
**Then** `auricle stats` flags per metric: `applied/suggestions < 40%` over 4 weeks → flag; `false_positive_count / applied_count > 0.20` → flag (`n/a — v1.1`); jargon-correction rate < 40% over 30 days → flag (wedge unvalidated)
**And** divide-by-zero handling per Decision 5.7: when `suggestions_count == 0`, accept_rate is `nil` (NOT 0% / 100%); kill criterion shows `insufficientSignal` (NOT pass); explicit absence per UX-DR18

**Given** `--json` mode
**When** invoked
**Then** the structured response carries all metrics + flags under a stable JSON schema with `schemaVersion: 1`

**Given** the test suite
**When** I run `Tests/CLITests/StatsVerbTests.swift`
**Then** tests cover: empty database → `$0.00 / no meetings yet` graceful empty state; populated database → correct aggregates; jargon-correction rate computation correctness (post-hoc from cache-dir artifacts); kill-criterion flagging; divide-by-zero handling; `--json` schema validation

**Given** v1.1 enrichments per Epic 10
**When** future stories add rolling aggregates / per-meeting drilldowns / `false_positive_count` instrumentation
**Then** the MVP `auricle stats` schema is preserved (additive — new fields can be added without breaking MVP-tier readers per AR-PAT-2 versioning)

---

**Epic 9 summary:**
- **7 stories** sized for single dev-agent completion
- **All FRs covered:** FR12 CLI parity completeness (Story 9.5), FR58 full SettingsView (Story 9.1), FR60 detection-on-launch + Doctor surfacing (Story 9.2 — resolves Winston's hidden-coupling concern)
- **NFRs primarily verified:** NFR-M6 config takes effect on next pipeline invocation (Story 9.1), NFR-I7 CLI binding contract finalized (Story 9.5), NFR-S2 self-managed code-signing (Story 9.3), NFR-C4 $0 fixed cost (Story 9.3), NFR-M7 reproducible builds (Story 9.4)
- **All architectural commitments addressed:** AR-DIST-1 through AR-DIST-4 (Stories 9.3 + 9.4 — moved from Epic 1 per Winston), AR-PIPE-6 full MVP CLI verb surface (Story 9.5), AR-PIPE-8 CLI conventions (Story 9.5), AR-FAIL-6 Doctor verb integration (Story 9.2), AR-SUM-6 trust-calibration surfaces (Story 9.6 — Mary's J1.5 named ACs), AR-AI-9 wedge-validation measurement (Story 9.7 — minimal `auricle stats` MVP impl per Mary + Amelia)
- **All UX-DRs primarily addressed:** UX-DR46 DoctorView conversational format (Story 9.2), UX-DR47 SettingsView (Story 9.1), UX-DR48 auto-save + secrets masking (Story 9.1), UX-DR67 CLI design tokens (Story 9.5), UX-DR68 CLI structured error JSON (Story 9.5)
- **Mary's J1.5 trust-calibration concern resolved in Story 9.6:** named ACs for `auricle status <id>` + `log show` discovery path
- **Mary + Amelia's wedge-validation MVP promotion resolved in Story 9.7:** minimal `auricle stats` ships at MVP, not v1.1
- **No future-story dependencies within the epic:** sequencing 9.1 (Settings — independent) + 9.2 (Doctor) + 9.3 (Distribution) + 9.4 (release script) + 9.5 (CLI completeness) + 9.6 (status trust calibration) + 9.7 (`auricle stats`) — most can run in parallel since they live in different surfaces

---

## Epic 10: v1.1 Operability & Power-User Features (Re-Prioritization Queue)

> **Honest framing per John's review:** This epic is a *parking lot* for v1.1 features. It is NOT prioritized — it is a queue that will be re-ranked after ~30 days of MVP dogfood. Treating it as a pre-prioritized epic would be planning theater. Each story below is independently shippable; sequencing is by post-dogfood empirical signal, not by pre-dogfood guess.

### Story 10.1: Menubar Item (FR8)

As the single user,
I want a menubar item per FR8 + UX spec Step 4 — quick start/stop, click-to-open-window, status dot reflecting worst state across all meetings,
So that capture controls and status visibility don't require the main window being open.

**Acceptance Criteria:**

**Given** the v1.1 release
**When** the app launches
**Then** an `NSStatusItem` appears in the macOS menubar with: small status dot (color reflects worst meeting state — yellow for any `awaiting_*`, red for any `*_failed`); menu items for Start Recording / Stop Recording; Open Window; quick pending count (when applicable)

**Given** the click affordance
**When** the user clicks the menubar item
**Then** the menu drops down with the items above; clicking "Open Window" focuses (or opens) the main window

**Given** the test suite
**When** I run `Tests/AppTests/MenubarItemTests.swift`
**Then** tests cover: status dot color reflects worst state correctly; menu actions invoke correct handlers; pending count matches `auricle list`'s default filter

---

### Story 10.2: VAD Pre-Flight Halt + `--force` Override (FR9, FR10)

As the single user,
I want auricle to pre-flight a captured audio file with VAD per FR9 — halting the pipeline if speech-content is below `vad.threshold_seconds` (default 120) — and `--force` to override per FR10,
So that the silent-meeting J3 case (forgot to stop recording, captured 2hr of silence by accident) doesn't produce a thin/empty vault note.

**Acceptance Criteria:**

**Given** capture completes
**When** the next stage runs
**Then** the VAD pre-flight stage runs first per FR9 — measures total speech duration in `audio.wav`
**And** if speech < threshold (default 120s configurable via `vad.threshold_seconds`), pipeline halts; meeting transitions to `silent` (benign-terminal per AR-FAIL-1)
**And** `auricle pending` (Story 10.3) shows `silent — pipeline halted`

**Given** the user wants to bypass VAD halt
**When** they invoke `auricle process <id> --force` OR click "Force process" in the GUI row-expand
**Then** the VAD halt is bypassed; pipeline proceeds normally

**Given** the test suite
**When** I run VAD tests
**Then** tests cover: silent fixture → halt; speech-content > threshold → proceed; `--force` override; configurable threshold

---

### Story 10.3: `auricle pending` Listing + Dock Badge (FR15, FR16)

As the single user,
I want `auricle pending` per FR15 — list only non-terminal meetings — and a Dock badge per FR16 showing stale-pending count,
So that operability scales as meeting volume grows; nothing silently expires.

**Acceptance Criteria:**

**Given** the CLI verb
**When** I run `auricle pending`
**Then** output is a subset of `auricle list`'s default — non-terminal-only meetings (excludes `verified`, `retention_expired`, `discarded`)
**And** `--json` mode supported

**Given** Dock badge per FR16
**When** stale-pending count > 0 (meetings awaiting verification beyond a threshold, default 7d)
**Then** the Dock badge shows the numeric count
**And** clicking the Dock icon focuses the main window with the stale meetings highlighted

**Given** the test suite
**When** I run pending + Dock badge tests
**Then** tests cover: pending output correctness; `--json` schema; Dock badge updates on state transitions

---

### Story 10.4: CLI Attribution Fallback `--emit-snippets` + `--speakers` (FR27)

As the single user,
I want `auricle attribute <id> --emit-snippets` and the documented FR27 surface for `auricle attribute <id> --speakers "1=Ben,2=Sara,..."` (the batch path itself ships in Epic 4 Story 4.6) — the CLI fallback path for J4 when the GUI sheet is unavailable,
So that the broken-UI degenerate case has a documented recovery surface.

**Acceptance Criteria:**

**Given** `--emit-snippets`
**When** invoked
**Then** writes per-speaker WAV snippets to cache (already produced in Epic 4 Story 4.2 — this verb just exposes them for inspection); exits 0 with the cache path
**And** the user can QuickLook the snippet WAVs in Finder

**Given** `--speakers "1=Ben,2=Jordan Whitfield,3=Priya"`
**When** invoked
**Then** behaves as Epic 4 Story 4.6 built it (parses the mapping, resolves names against the vault, validates, writes `attribution.json`, resumes the pipeline); this story adds no new parsing
**And** mutually exclusive with `--emit-snippets` per Decision 1.5

**Given** the test suite
**When** I run CLI attribution fallback tests
**Then** tests cover: snippet emission path; speaker mapping path; vault resolution; mapping validation; mutual-exclusion enforcement

---

### Story 10.5: Per-Meeting Retention Overrides (`auricle retain` + Settings) (FR49, FR50)

As the single user,
I want per-meeting retention overrides per FR49 + FR50 — `auricle retain <id> --indefinite|--days N|--release` CLI verb + Settings UI for a per-meeting custom retention window,
So that important meetings (J5 retention housekeeping) can be kept long-term without manual cache hacking.

**Acceptance Criteria:**

**Given** `auricle retain <id> --indefinite`
**When** invoked on a verified meeting
**Then** sets `meetings.retention_policy = 'indefinite'` per AR-DATA-1; `RetentionScheduler` (Story 8.5) skips this meeting; CountdownAnnotation reads "Audio kept (indefinite)" per UX-DR17
**And** `--days N` sets `'custom:N'`; `--release` reverts to NULL (uses global config grace window) per Decision 1.5

**Given** the GUI affordance per Story 6.4 `[Keep audio indefinitely]` button
**When** clicked
**Then** invokes the same `auricle retain --indefinite` code path

**Given** flag mutual exclusion
**When** the user invokes conflicting flags
**Then** parse-time rejection per Decision 1.5

**Given** the test suite
**When** I run retention override tests
**Then** tests cover: indefinite + custom + release paths; CLI / GUI parity; RetentionScheduler skips overridden meetings

---

### Story 10.6: Long-Context Drift Detection (FR34)

As the single user,
I want long-context drift detection on transcripts ≥60 minutes per FR34 — token count + summary content density flag for suspiciously thin summaries,
So that the known failure mode (Claude producing thin summaries on long meetings) is caught at v1.1 without manual inspection.

**Acceptance Criteria:**

**Given** a summarize stage on a transcript ≥60 minutes
**When** the stage completes
**Then** computes `summary_density = (summary_word_count + sum(action_item_word_counts) + sum(decision_word_counts)) / transcript_word_count` per Decision 3.8
**And** computes baseline density from telemetry rollups across past meetings of similar duration
**And** if density is < N standard deviations below baseline AND transcript word count ≥ 60-minute threshold (~7500 words), flag with `auricle/needs-review` frontmatter tag and `warn`-level log entry

**Given** the empirically-tuned threshold N
**When** v1.1 builds the threshold from dogfood data
**Then** the threshold is documented as an Open Resolution; a Settings knob (`drift_detection.std_devs_threshold`) allows user override

**Given** the test suite
**When** I run drift detection tests
**Then** tests cover: dense summary on long transcript → no flag; thin summary on long transcript → `auricle/needs-review` tag + warn log; threshold configurable

---

### Story 10.7: Sparkle EdDSA-Signed Appcast Self-Update (FR65)

As the single user,
I want auricle to self-update via Sparkle per FR65 + AR-DIST-3 + NFR-S9 — EdDSA-signed appcasts published from GitHub Releases,
So that v1.1+ updates flow seamlessly without per-Mac re-trust setup (the existing `spctl` policy from Epic 9 Story 9.3 accepts new builds).

**Acceptance Criteria:**

**Given** Sparkle SPM dependency added in Epic 1 Story 1.1 (deferred at MVP)
**When** v1.1 ships
**Then** the GUI app integrates Sparkle; appcast XML is generated from the release script (Story 9.4's v1.1 extension); appcast is published from GitHub Releases per FR65

**Given** an update is available
**When** the user clicks "Check for Updates…" (or auto-check fires)
**Then** Sparkle downloads + verifies EdDSA signature per NFR-S9; updates with invalid signatures are rejected
**And** the downloaded `.app` is signed with the self-managed code-signing certificate (per NFR-S2) and accepted by Gatekeeper via the existing `spctl` trust policy
**And** TCC permission grants persist (stable bundle ID + signing identity per AR-DIST-4)

**Given** the test suite
**When** I run Sparkle integration tests
**Then** tests cover: EdDSA signature verification; bad signature rejection; appcast XML format correctness

---

### Story 10.8: ClaudeTranscriptionReviewer Concrete Impl (FR76)

As the single user,
I want `ClaudeAIReviewers/ClaudeTranscriptionReviewer.swift` per FR76 + Decision 5.5 Phase 3 — concrete impl of the `TranscriptionReviewerStrategy` protocol declared in Epic 4 Story 4.4 — Haiku-default, surfacing word/phrase-level transcription corrections (homophones, proper nouns, technical terms grounded in vault glossary) in the transcript pane behind `transcription_review.enabled` flag (default false),
So that Phase 3 of the AI-correction product category ships its concrete impl with the same dogfood-then-enable activation gate as diarization review.

**Acceptance Criteria:**

**Given** the v1.x release
**When** the implementation lands
**Then** `ClaudeTranscriptionReviewer` conforms to `TranscriptionReviewerStrategy` from Story 4.4
**And** uses `claude-haiku-4-5` by default; configurable via `transcription_review.model`
**And** `transcription_review.enabled` flag default false per Decision 5.5

**Given** flag flipped on
**When** the reviewer runs
**Then** writes `transcription_suggestions.json` to cache-dir per the schema declared in Story 4.4
**And** Epic 7's `AttributionTranscriptPane` (Story 7.10) renders word/phrase-level corrections behind the flag (matching the AI-hint UX pattern from Story 7.11)

**Given** the activation gate per Decision 5.5
**When** the v1.x dogfood-then-enable phase runs
**Then** the same smoke-test protocol from Decision 5.6 applies (`applied/suggestions ≥ 40%` AND FP rate `<20%` over 4 weeks)

---

### Story 10.9: Local-LLM Summarization (FR33)

As the single user,
I want a local-LLM `OllamaSummarizer` and/or `MLXSummarizer` per FR33 + Decision 3.9 + NFR-I8 implementing `SummarizerStrategy` with `groundingMethod: .substring`,
So that the summarization stage can run at $0/meeting per NFR-C3 once local models hit the quality bar.

**Acceptance Criteria:**

**Given** the v1.1+ release
**When** the impl lands
**Then** `OllamaSummarizer` (HTTP client to local Ollama endpoint) AND/OR `MLXSummarizer` (in-process MLX inference) conform to `SummarizerStrategy`
**And** uses the same `SummarizationPromptBuilder` (Epic 3 Story 3.2) for prompt generation (snapshot tests prevent drift per AR-SUM-1)
**And** uses `SubstringGroundingValidator` (no Citations API on local LLMs per Decision 3.9)
**And** cost is $0 (NFR-C3) — telemetry contract `cost_usd: 0` + `model_id: "local:<name>"` per Decision 5.6

**Given** latency target
**When** local LLM runs
**Then** comparable to or better than Claude path (otherwise no v1.1 promotion per Decision 3.9)

**Given** the v1.1 build phase
**When** local LLMs are evaluated
**Then** if quality bar is met, the strategy ships and becomes a config option (`summarization.engine = ollama | mlx | claude`) per NFR-I8

---

### Story 10.10: `auricle stats` Enrichments (Rolling Aggregates + Drilldowns + Kill-Criteria Flagging)

As the single user,
I want `auricle stats` v1.1+ enrichments — rolling aggregates over multiple windows (7d / 30d / 90d), per-meeting drilldowns, kill-criteria flagging visible per Decision 5.7,
So that the wedge-validation hypothesis can be evaluated continuously, not just at the MVP gate moment from Story 9.7.

**Acceptance Criteria:**

**Given** the v1.1 release
**When** I run `auricle stats --window 7d|30d|90d`
**Then** rolling aggregates report all metrics from Story 9.7 over the specified window
**And** `auricle stats <id>` (per-meeting drilldown) shows per-item grounding details, AI suggestion counts (applied/rejected), cost breakdown

**Given** kill-criteria flagging per Decision 5.7
**When** the rolling aggregate trips a threshold
**Then** the flag is visibly surfaced in `auricle stats` output (e.g., *"⚠ Diarization review accept rate has fallen below 40% over 4 weeks — review prompt design or disable flag"*)
**And** when `false_positive_count` instrumentation lands (forward-instrumentation per AR-AI-8), FP-rate flagging activates

**Given** v1.1+ closed-loop trust calibration (Architecture Validation §Gap Disposition #11)
**When** vault-edit detection ships (capture vault file hash on persist; background diff job reads + diffs vs original) per AR-AI-8
**Then** `auricle stats` reports `false_positive_count / applied_count` over 4 weeks; flags if > 0.20

---

**Epic 10 summary:**
- **10 stories** sized for single dev-agent completion
- **All FRs covered:** FR8 (Story 10.1), FR9 (Story 10.2), FR10 (Story 10.2), FR15 (Story 10.3), FR16 (Story 10.3), FR27 (Story 10.4), FR33 (Story 10.9), FR34 (Story 10.6), FR49 (Story 10.5), FR50 (Story 10.5), FR65 (Story 10.7), FR76 concrete impl (Story 10.8)
- **NFRs primarily verified:** NFR-S9 Sparkle EdDSA verification (Story 10.7), NFR-C2 v1.1 cost reduction via prompt optimization (folded into post-dogfood prompt iteration), NFR-C3 local-LLM $0 path (Story 10.9), NFR-I8 Ollama / MLX runtime configurable (Story 10.9)
- **All architectural commitments addressed:** AR-AI-7 Phase 2/3 (Story 10.8), Decision 3.8 (Story 10.6), Decision 3.9 (Story 10.9), AR-PIPE-6 v1.1 verb additions (Stories 10.3 + 10.4 + 10.5)
- **Re-prioritization queue framing per John's review:** stories are NOT pre-prioritized; sequencing is post-dogfood empirical signal
- **Stories within Epic 10 are independently shippable:** none depend on others within the epic; each can ship as its own release after dogfood justifies it
