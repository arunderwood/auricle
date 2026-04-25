---
stepsCompleted: [1, 2]
inputDocuments: []
session_topic: 'auricle — local-first meeting notetaker: captures system audio from meetings joined on this computer (Zoom/Meet/etc.), transcribes locally, enriches with calendar metadata, persists summarized notes to Obsidian vault (~/checkouts/SecondBrain). No bot/agent joins the meeting.'
session_goals: 'All of: (a) broad idea generation, (b) MVP scoping, (c) de-risking hard problems and edge cases, (d) naming/positioning/UX exploration'
selected_approach: 'progressive-flow'
techniques_used: ['Mind Mapping', 'Morphological Analysis', 'Reverse Brainstorming', 'Resource Constraints']
ideas_generated: []
context_file: ''
---

# Brainstorming Session Results

**Facilitator:** arunderwood
**Date:** 2026-04-23

## Session Overview

**Topic:** auricle — a local-first meeting notetaker. Captures system audio from meetings joined on this computer (Zoom, Google Meet, etc.), transcribes locally, enriches with calendar metadata, persists summarized notes to Obsidian vault at `~/checkouts/SecondBrain`. Explicit constraint: **no agent/bot joins the meeting** — capture happens silently on the host machine.

**Goals:** All of —
- (a) broad idea generation to discover what auricle *could* be
- (b) MVP scoping — separate must-have from nice-to-have
- (c) de-risking — surface hard problems and edge cases early
- (d) naming, positioning, UX exploration

### Session Setup

Scope is tight and intentional: **one user, one machine, many meetings**. Audio source is system audio (loopback + mic), not a meeting-platform integration. This rules out bot-based services (Otter, Fireflies, Fathom) and pushes toward OS-level audio capture + local ML.

## Technique Selection

**Approach:** Progressive Technique Flow
**Journey Design:** Systematic development from broad exploration → structured decision grid → de-risking → MVP scoping.

**Progressive Techniques:**

- **Phase 1 — Exploration:** Mind Mapping — fan out from central concept across product dimensions (capture, transcription, enrichment, summarization, persistence, UX, meta). Target: 60–80 branches.
- **Phase 2 — Pattern Recognition:** Morphological Analysis — convert mind map into a decision-axis grid (capture method × transcription engine × trigger × summarization × storage × privacy × UX).
- **Phase 3 — Development:** Reverse Brainstorming — "how could this fail spectacularly?" to surface audio, privacy, transcription, and storage edge cases.
- **Phase 4 — Action Planning:** Resource Constraints — weekend-MVP and evening-MVP pressure tests; forces a 1-line pitch and naming pass.

**Journey Rationale:** auricle is a concrete technical product with discrete design choices. Mind Mapping respects that structure while pushing for breadth; Morphological makes tradeoffs legible; Reverse Brainstorming is the natural shape for local-first privacy-sensitive software; Resource Constraints closes the loop with opinionated MVP cuts.

## Phase 1 — Mind Mapping Results

### Elevator pitch (crystallized during session)

**"auricle transcribes, summarizes, and persists."**

### Locked-in decisions (collapsed dimensions)

1. **English-only** transcription
2. **No record-consent prompt** (single-user tool)
3. **Audio is ephemeral** — auto-deleted after summary verified in vault
4. **Summary-first, transcript-as-backup.** Action items + decisions are first-class structured objects. Output is a memory layer; downstream analytics is SecondBrain's job, not auricle's.
5. **macOS-only via ScreenCaptureKit** for system audio capture (no BlackHole / aggregate-device setup)
6. **Post-hoc pipeline** (not a streaming service)

### Open axes (carried into Phase 2)

- **A. Summarization engine** — local-only vs local+cloud-opt-in. Resolution requires empirical benchmarking on real meeting transcripts.
- **B. Meeting-type templates** — defer to post-MVP. MVP uses one universal template.
- **C. Vault note shape** — *one-note-per-meeting* vs *one-note-per-series* (recurring meetings). Resolution via community research (Building a Second Brain / Obsidian / mind-mapping communities).

### Deferred research

- Auto-detect "meeting in progress" via running Zoom/Meet processes (post-MVP)

### Top-level branches mapped (~100 nodes total)

Capture · Transcription · ★ Vault-Aware Correction · ★ Speaker Attribution · Enrichment · Summarization · ★ Structured Output Schema · ★ SecondBrain Interop · Persistence · UX/Triggers · Privacy & Trust · Pipeline/Runtime

## Phase 2 — Morphological Analysis Results

12 design axes enumerated. Decisions taken in-session:

| # | Axis | Locked choice | Notes |
|---|---|---|---|
| 1 | Transcription engine | **WhisperKit (Whisper-large-v3-turbo)** | Swift-native, ANE-accelerated; alt: Parakeet-TDT via MLX if WER limits summary quality |
| 2 | Vault-aware correction | **Post-transcribe LLM correction with vault-derived glossary, folded into summary call** | Glossary built from wikilink targets in vault; meeting-scoped variant (filter by attendees/topics) is sharper |
| 3 | Diarization | **WhisperKit built-in** | Alt: pyannote 3.1 (Python sidecar) if cross-meeting voice-print matching becomes priority — currently treated as post-MVP |
| 4 | Speaker-attribution UX | **OPEN** | Blocking / non-blocking / hybrid — to resolve in Phase 4 |
| 5 | Summarization engine | **Local LLM OR Claude (API/Bedrock)** | No OpenAI. Empirical benchmark resolves this |
| 6 | Summarization pipeline shape | **OPEN** (likely chain-of-summarize) | Each stage swappable per Axis 8 constraint |
| 7 | Vault note shape | **OPEN** — needs community research | Excluded: spawned action-item sub-notes |
| 8 | Trigger / process UX | **Menubar app, decoupled architecture** | Pipeline stages independently invokable so UI surface can pivot |
| 9 | Calendar source | **Google Calendar API (direct OAuth)** | |
| 10 | Audio retention | **Delete N days after user-verified summary** | Configurable grace window |
| 11 | Output validation | **Hybrid** | Structured fields schema-validated, prose freeform |
| 12 | Process boundary | **OPEN** | Single-shot CLI / daemon / Mac app with embedded daemon / launchd agent |

### Latency budget validated

End-to-end pipeline (M5 Max, 30 min meeting): **~1–2 min realistic, up to ~5 min worst case**. Confirmed acceptable. Transcription is not the bottleneck — Claude summarization call is the slow stage. Local-LLM summarization would push 60-min meeting to 3–7 min end-to-end.

### Verify-before-implementing flags

- Parakeet-TDT current MLX maturity (alternate ASR path)
- WhisperKit diarization current quality + whether it exposes embeddings
- Apple SpeechAnalyzer evaluation quality (fallback only)

### Final lock-ins (resolved during session)

| # | Axis | Final choice |
|---|---|---|
| 4 | Speaker-attribution UX | **Blocking with native auricle UI panel.** Audio snippets per detected speaker + autocomplete from vault wikilinks + calendar attendees + previously-labeled speakers. User labels before summarization runs. |
| 6 | Summarization pipeline shape | **Single constrained-JSON Claude call → render to markdown** for MVP. Chain-of-summarize is the post-MVP escape hatch if quality drifts on long transcripts. |
| 7 | Vault note shape | **One-note-per-meeting** for MVP. Series-overview auto-aggregation deferred. |
| 12 | Process boundary | **Menubar app orchestrates; heavy stages run as `auricle <stage>` CLI subprocesses.** Stages independently invokable; crash-isolated; testable from terminal. |
| VP | Cross-meeting voice-print matching | **Post-MVP.** WhisperKit diarization for v1; pyannote+embeddings is the upgrade path. |
| ★ | Verification trigger (Axis 10 wiring) | **Two-stage:** (1) attribution complete unlocks summarization; (2) click on macOS notification (which opens note in Obsidian) starts audio-retention timer. Audio deleted N days after click. Re-prompt at 7d, escalate at 14d. CLI: `auricle pending`. |

### Final pipeline shape

```
capture → transcribe → diarize → ATTRIBUTE (native UI, blocking) → summarize → persist → notify
                                                                                         ↓
                                                                         click → open note → start audio-retention timer
```

### Architectural principles that emerged

- **Stages are decoupled CLI subcommands.** Menubar app is a UI + dispatcher, not a monolith.
- **Frontmatter contract is canonical.** Speakers as `[[wikilinks]]`, no confidence flags, no in-vault tag noise — engagement happens upfront in auricle's native UI.
- **Audio is the only recovery layer.** Two-stage verification protects against silent summary failures.
- **Vault is downstream consumer.** auricle outputs structured, queryable data; SecondBrain processes layer analytics on top.

## Phase 3 — Reverse Brainstorming Results

33 failure modes generated, 10 marked stomach-dropper (🔥). Resolved into mitigations below. Mitigations grouped by interacting theme.

### Theme A — Audio-quality fooling the pipeline

| Failure | Mitigation | Posture |
|---|---|---|
| #4 Mostly-silent audio → hallucinated summary | **Pre-flight VAD as halting gate**, not a prompt. <2 min speech detected in 30-min file → pipeline halts, no note in vault, no notification. Meeting appears in `auricle pending` as `silent`. Manual override via `auricle process <id> --force`. | Blocking — empty meetings don't interrupt the user |
| #7 Whisper hallucinates over silence | VAD-bounded chunking (already chosen for performance reasons in Axis 1) | Already locked |
| #2 Bluetooth captures only one half | Deprioritized; not a frequent path for this user | Accepted MVP risk |

### Theme B — Summarization fidelity

| Failure | Mitigation | Posture |
|---|---|---|
| #18 Hallucinated action items / decisions | **Quote-grounded extraction:** prompt Claude to include verbatim `source_transcript_quote` for every action item and decision. Validation step greps for the quote in transcript; missing-quote items are dropped. | Blocking — quote-grounding pattern |
| #20 Long-context drift on 60-min transcripts | MVP guard: log token count + summary content density; flag suspiciously thin summaries for 60-min meetings. Chain-of-summarize (Axis 6 escape hatch) is the post-MVP fix path. | MVP guard; post-MVP escape |

### Theme C — Vault integrity

| Failure | Mitigation | Posture |
|---|---|---|
| #23 Obsidian write conflict on shared file | **Atomic-write contract:** auricle only creates new files, never edits. Write to temp file, `fsync`, atomic rename. Never compete with Obsidian on the same file. | Blocking — atomic-write contract |

### Theme D — Audio retention safety

| Failure | Mitigation | Posture |
|---|---|---|
| #28 Audio deleted before user notices wrong summary | **7-day grace window after click-to-verify** (locked from Axis 10). `auricle keep <meeting-id>` flag for explicit retention beyond grace. | Blocking — explicit-keep escape hatch |
| #33 Notification dismissed reflexively → timer never starts | Treat as correct behavior (never auto-deleting unverified audio is the safer mode). Surface visibility: menubar badge if pending items > N days old. | Accepted with surface visibility |

### Theme E — Attribution correctness/availability

| Failure | Mitigation | Posture |
|---|---|---|
| #31 Attribution UI bug → all meetings stuck | **Two-path fallback, available everywhere:** (1) Flag-based CLI: `auricle attribute --emit-snippets` writes audio snippets to cache dir for QuickLook playback; `auricle attribute --speakers "1=Ben,2=Sara"` resolves to vault wikilinks and resumes pipeline. (2) **"Publish anyway" / skip in BOTH UI and CLI** (`--skip`): publishes with raw `Speaker_N` labels and `#auricle/needs-attribution` in frontmatter; user fixes in Obsidian later. | Blocking — both paths in MVP |
| #32 Sara vs Sarah autocomplete mistake | **Calendar-attendee-marked autocomplete.** Priority: calendar attendees first (visual marker), vault wikilinks second. When typed prefix matches a single calendar attendee, it bubbles to the top. Recency/frequency break ties for non-calendar matches. | Blocking — calendar-first autocomplete |

### MVP scope additions surfaced by Phase 3

- Pre-flight VAD halting gate
- Quote-grounded extraction prompt pattern (action items + decisions cite verbatim transcript quote)
- Atomic-write contract for vault interactions
- `auricle attribute --emit-snippets` + `--speakers` flag-based CLI fallback
- "Publish anyway" available in both menubar UI and `--skip` CLI flag
- `#auricle/needs-attribution` frontmatter flag (normal-use, not emergency-only)
- Calendar-attendee-priority autocomplete
- Menubar badge for stale pending items

### Accepted MVP risks

- ScreenCaptureKit API churn (living project)
- Bluetooth-only-half capture (rare path)
- Notification dismissed → audio retention timer never starts (correct behavior; surface via badge)
- Cost surprises, supply-chain, low-battery, Google API quota — addressed reactively if/when they fire

## Phase 4 — Resource Constraints / MVP Scoping Results

### Scoping posture

**(B) Cohesive milestone**, not walking-skeleton accretion. CLI-only walking skeleton wouldn't motivate dogfooding. The MVP gate is when capture + diarization + native attribution + good summaries land together.

### Form-factor revision (locked late in Phase 4)

| | Was | Now |
|---|---|---|
| MVP primary surface | Menubar popover | **Standard Mac windowed app with main window + Dock icon** |
| Reason | (initial assumption) | Attribution UI needs sustained attention, audio playback, autocomplete, possible merge/split controls — popover is the wrong form factor |
| Window close behavior | (n/a) | App stays alive on window close; capture continues; attribution resumes on next open |
| Menubar integration | MVP | **v1.1 additive** — quick status, quick start/stop, click → open main window |
| Stale-pending badge | Menubar icon | Dock badge (native macOS) |

Decoupled-architecture principle (Axis 12) unchanged: pipeline stages remain CLI subcommands; Mac app is the windowed orchestrator.

### MVP v1 cut list

**In MVP v1:**
- ScreenCaptureKit capture (manual start/stop)
- WhisperKit transcription (Whisper-large-v3-turbo)
- WhisperKit diarization
- Native attribution UI in Mac windowed app (audio snippets + calendar-first autocomplete + "publish anyway")
- Claude summarization with quote-grounded extraction
- One-note-per-meeting with stable frontmatter + atomic-write
- macOS notification + click-to-verify wiring
- Audio retention timer (7-day grace, configurable)
- Mac windowed app + decoupled CLI subcommands
- Google Calendar enrichment (attendees + title)
- Vault glossary (wikilink-derived) injected into Claude prompt

**Cut to v1.1:**
- Menubar item (quick status, quick start/stop, click-to-open-window)
- VAD pre-flight halting gate
- `auricle pending` CLI surface + stale-pending Dock badge
- `auricle attribute --emit-snippets` + `--speakers` CLI fallback
- Long-context drift detection
- `auricle keep` retention override
- Per-meeting configurable retention

**Cut to v2+:**
- Auto-detect meeting in progress (research deferred)
- Cross-meeting voice-print matching (pyannote sidecar)
- Meeting-type templates
- Series-overview auto-aggregation
- Local LLM summarization path
- Chain-of-summarize fallback

**Empirically resolved during MVP build:**
- Vault note shape detail (community research informs frontmatter contract)
- Summarization engine: local vs Claude (benchmark Claude vs local Ollama/MLX on 10–20 captured real meetings; pick winner on quote-grounding accuracy + action-item recall)

### Build order (risk-front-loaded within MVP v1)

1. **Pipeline plumbing** — `auricle process <audio-file>` CLI: WhisperKit transcribe → Claude summarize → frontmatter contract → atomic vault write. Validates riskiest core empirically.
2. **Capture** — ScreenCaptureKit + `auricle record/stop` CLI. Audio lands in cache; pipeline picks it up.
3. **Diarization + native attribution UI** — WhisperKit diarization → attribution panel with calendar-first autocomplete + "publish anyway." UX-heaviest piece; the differentiator.
4. **Mac windowed app shell** — wraps capture controls + attribution into the actual product surface. WindowGroup primary, LSUIElement=NO, Dock icon.
5. **Notifications + click-to-verify + retention timer** — closes the audio-lifecycle loop.
6. **Google Calendar integration** — attendees, titles, glossary scoping.
7. **Vault-glossary builder** — wikilink extraction → Claude prompt context.
8. **First real meeting captured end-to-end** — the MVP gate.

### Naming + positioning (final)

- **Name:** **auricle** (locked — the outer ear, what catches sound)
- **Three-verb tagline:** *auricle transcribes, summarizes, and persists.*
- **Pitch tagline (locked):** **"Be in the meeting. Not in your notes."**
- **One-line description:**
  > *auricle is a local-first macOS app that quietly captures your meeting audio, transcribes and summarizes it, and writes the result to your Obsidian vault. No bots join your meetings. No SaaS. Your audio, your machine, your notes.*

---

## Session Close-Out

### Outcomes

- ~100 product ideas mapped (Phase 1)
- 12 design axes resolved with rationale (Phase 2; 1 with empirical resolution path)
- 33 failure modes surfaced, 10 stomach-droppers mitigated (Phase 3)
- MVP cut list with v1.1 / v2 deferrals + risk-front-loaded build order (Phase 4)
- Name confirmed; tagline locked

### Verify-before-implementing flags (carry into build)

- Parakeet-TDT current MLX maturity (alternate ASR path)
- WhisperKit diarization current quality + whether it exposes embeddings
- Apple SpeechAnalyzer evaluation quality (fallback only; macOS 26+)

### Empirical decisions deferred to build phase

- Summarization engine: Claude vs local LLM benchmark on real meetings
- Vault note shape detail: community research (BASB / Obsidian users) informs frontmatter contract before locking
- Long-context drift threshold: measure on real 60-min meeting transcripts; chain-of-summarize fallback if needed

### Suggested next artifacts

1. **PRD** — translate this brainstorm into a written product requirements doc (the BMM `bmad-create-prd` skill, if you install BMM)
2. **Architecture sketch** — Mac windowed app + CLI subcommands shape; LSUIElement, file paths, frontmatter contract
3. **Stage-1 spike** — actually start coding the `auricle process <audio-file>` CLI; resolves the biggest empirical risk first






