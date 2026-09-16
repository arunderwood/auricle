---
stepsCompleted: ['step-01-init', 'step-02-discovery', 'step-02b-vision', 'step-02c-executive-summary', 'step-03-success', 'step-04-journeys', 'step-05-domain-skipped', 'step-06-innovation', 'step-07-project-type', 'step-08-scoping', 'step-09-functional', 'step-10-nonfunctional', 'step-11-polish', 'step-12-complete']
completedAt: 2026-04-26
inputDocuments:
  - _bmad-output/brainstorming/brainstorming-session-2026-04-23-1644.md
documentCounts:
  briefCount: 0
  researchCount: 0
  brainstormingCount: 1
  projectDocsCount: 0
workflowType: 'prd'
projectName: 'auricle'
classification:
  projectType: desktop_app
  domain: general
  complexity: low
  projectContext: greenfield
---

# Product Requirements Document - auricle

**Author:** arunderwood
**Date:** 2026-04-26

## Executive Summary

auricle is a local-first macOS application that turns your meetings into structured notes in your Obsidian vault — without ever joining the meeting. It captures system audio via ScreenCaptureKit on the host machine, transcribes locally with WhisperKit (Whisper-large-v3-turbo, ANE-accelerated), runs a brief blocking speaker-attribution pass in a native UI, summarizes with quote-grounded extraction, and writes the result atomically as a single Obsidian note with structured frontmatter. The captured audio is ephemeral — deleted on a 7-day grace timer that begins only after the user clicks the "summary ready" notification and opens the note in Obsidian.

The target user is a single individual on a single Mac who attends many meetings and already keeps a personal knowledge vault. The problem being solved is the meeting-notes tax — the cognitive split between participating fully and capturing what matters — and the unsatisfying tradeoff between bot-based SaaS notetakers (which require account integrations, intrude on the meeting, and exfiltrate audio to a vendor) and manual note-taking (which competes with attention). auricle eliminates both by capturing silently at the OS layer and processing locally.

### What Makes This Special

auricle is defined by a stack of opinionated constraints that, together, are not occupied by any existing product:

- **No bot in the meeting.** Capture is OS-level loopback, invisible to other participants, and meeting-platform-agnostic. Works with anything that plays audio through the system — Zoom, Google Meet, Teams, Discord, FaceTime, a recorded video. Removes the entire category of "should I add a bot to this call?" friction.
- **Local-first by construction.** Transcription, diarization, vault-glossary correction, and persistence all run on-device. Summarization is the only stage that may make a remote call (Claude), and a local-LLM path is in the post-MVP escape hatch.
- **Vault-native, not export.** auricle writes directly to Obsidian with atomic-write semantics (temp file → fsync → rename — never edits existing files), speakers as `[[wikilinks]]`, calendar metadata in frontmatter, and a stable schema that downstream BASB/SecondBrain workflows can rely on.
- **Quote-grounded extraction.** Every action item and decision must cite a verbatim transcript quote, validated by grep against the source transcript. Items missing a valid quote are dropped. Hallucinated commitments are eliminated by construction, not by prompting.
- **Two-stage audio retention.** Audio is held until the user clicks the macOS notification (which opens the note in Obsidian); a 7-day grace window then begins. Audio is never auto-deleted before user verification — a "publish anyway" + `#auricle/needs-attribution` frontmatter flag handles the case where attribution can't be completed inline.
- **Single-user, single-machine.** No accounts, no multi-tenancy, no sharing model, no compliance regime. The tool belongs to one person, and that simplification is load-bearing for the architecture.
- **AI-assisted correction as a product category, not a feature.** Jargon correction (vault-glossary, MVP), diarization correction (MVP, flag default-off), and transcription correction (v1.1) ship under one `AIReviewerStrategy` family with a phased Path C activation flow. This is the explicit differentiator versus the user's pre-existing workflow (Pixel Recorder → manual Claude → Obsidian) — auricle's AI does the correction work that the user previously did by hand, grounded in the same calendar and vault context.

The core insight is timing: Apple Silicon + ANE makes Whisper-large-v3-turbo fast enough for ~1–2 minute end-to-end processing of a 30-minute meeting; ScreenCaptureKit (macOS 13+) made system-audio loopback first-class, removing the BlackHole/aggregate-device hack era; and Claude (and increasingly capable local LLMs) produce structured, quote-grounded summaries reliably. The intersection of those three did not exist cleanly two years ago — and that intersection is the design space auricle occupies.

**Pitch tagline:** *Be in the meeting. Not in your notes.*
**Three-verb tagline:** *auricle transcribes, summarizes, and persists.*

## Design Principles

These four principles emerged from the brainstorming session and govern trade-offs that are not fully captured by individual FRs or NFRs. When in doubt during design, architecture, or implementation, these win.

1. **Stages are decoupled CLI subcommands; the Mac app is a UI + dispatcher, not a monolith.** Every pipeline stage runs as an independently-invocable `auricle <stage> <id>` subprocess. This is what makes crash isolation, terminal debugging, idempotent re-runs, and the CLI failure-recovery surface possible. If a future feature requires fusing two stages into a single in-process call for performance, the architectural cost is real and the trade must be deliberate.
2. **The frontmatter contract is canonical.** Speakers in summary text are `[[wikilinks]]`, attendees are `[[wikilinks]]`, and the `auricle:` block carries pipeline metadata. There are no confidence flags exposed in the vault (engagement happens upfront in the native attribution UI, not via downstream filters). There is no `auricle/*` tag noise beyond the few intentional flags (`needs-attribution`, `needs-calendar-enrichment`). Vault consumers downstream of auricle (BASB workflows, future analytics) depend on this schema being stable; breaking changes are major-version events with documented migrations.
3. **Audio is the only recovery layer.** The summary is the artifact the user trusts; the transcript is a backup; the audio is the recovery substrate beneath both. Audio is therefore retained until verification (never auto-deleted before the user has at least seen the summary) and the retention timer is conservative by default. Any change that risks losing audio before verification is rejected.
4. **The vault is a downstream consumer with a contract.** auricle outputs structured, queryable data; SecondBrain workflows and other vault tooling layer their own analytics on top. auricle does not perform analytics, does not synthesize across meetings, does not edit existing vault files. This separation of concerns is load-bearing — it prevents auricle from becoming a personal-knowledge-management product (which would absorb unbounded scope) and keeps it focused on being the best possible meeting-capture pipeline.

A fifth, implicit principle that surfaced repeatedly in the brainstorm: **engagement happens upfront, not downstream.** When the user has to make a judgment call (attribution, "publish anyway", retention override), the moment to ask is when context is fresh and the audio is still available — in auricle's UI, immediately after the meeting. Pushing those decisions into the vault for later cleanup is a failure mode, not a feature. This is why attribution is blocking, not optional.

## Project Classification

- **Project Type:** Desktop application — native macOS windowed app (SwiftUI / AppKit) with a Dock icon, orchestrating decoupled CLI subcommands (`auricle record`, `auricle process`, `auricle attribute`, `auricle pending`, etc.) so that pipeline stages are independently invocable, crash-isolated, and testable from the terminal. A v1.1 menubar extra adds quick start/stop and a click-to-open-window affordance.
- **Domain:** General-purpose personal productivity / knowledge-management tooling. No regulated-industry concerns (no PHI, no PCI, no FERPA, no HIPAA). Domain complexity is **low**; technical complexity (local ML pipeline, system-audio capture, diarization, vault integrity) is meaningfully higher and is treated as the primary engineering risk in the PRD.
- **Complexity (domain):** Low — standard software practices, no compliance burden, no certification pathway.
- **Project Context:** Greenfield — no existing codebase, no existing project documentation. The brainstorming session (2026-04-23) is the only upstream artifact, and it locked in scope, naming, design axes, and the MVP cut list.

## Success Criteria

### User Success

The single user experiences auricle as the disappearance of a tax. The "aha!" moment is the first end-to-end run: a meeting ends, the user clicks stop, ~1–2 minutes later a macOS notification fires, the user clicks it, Obsidian opens to a new note containing — in this order — meeting metadata as frontmatter, attendees as `[[wikilinks]]`, a clean summary, action items each carrying a verbatim transcript quote, decisions each carrying a verbatim transcript quote, and a foldable transcript at the bottom. The user reads the action items, edits one, accepts the rest, and closes the note. They never opened the recording. The audio is silently scheduled for deletion 7 days from that click.

The "done" state for any single meeting:
- Note exists in vault at `~/checkouts/SecondBrain/<location>` with stable filename
- Frontmatter is schema-valid (passes the auricle schema check)
- Speakers in summary text are rendered as `[[wikilinks]]` resolvable to existing people-notes (or new wikilinks pointing to to-be-created people-notes)
- Every action item and every decision contains a `source_transcript_quote` that survives a literal substring match against the transcript
- Audio retention timer is armed (or, if never clicked, audio is still preserved with stale-pending visibility)

The success-feeling is *trust*: the user stops mentally double-checking auricle's output and starts treating it as the canonical record. By month two of MVP use, the user defaults to auricle's notes when looking up "what did we decide about X" rather than scrolling Slack or searching email.

### Business Success

This is a personal tool, not a commercial product. "Business success" is reframed as **whether auricle earns its place in the user's daily workflow**:

- **Adoption:** ≥80% of voice meetings (excluding ad-hoc 5-min calls) captured by auricle within 30 days of MVP completion. Measured by counting `auricle process` invocations vs. calendar events tagged as meetings.
- **Cost ceiling:** Variable cost per meeting (Claude API on the summarization stage, when the cloud path is selected) ≤ \$0.10 per 30-min meeting at MVP, ≤ \$0.05 at v1.1. Local-LLM path (post-MVP) targets \$0.
- **Replacement:** auricle becomes the only meeting-notes mechanism in use within 60 days. No parallel manual notetaking, no parallel SaaS notetaker subscription. Measured by attestation, not telemetry.
- **AI-correction wedge validation:** The AI-assisted correction category (jargon at MVP; diarization at Phase 2 / v1.1; transcription at Phase 3 / v1.x) demonstrably contributes value the user could not get from the pre-auricle Pixel Recorder → manual Claude → Obsidian workflow. **MVP measurement:** ≥40% of meetings show at least one applied jargon correction (vault-glossary-resolved term substitution, observable as a difference between summary-side terms and raw transcript), tracked over a 30-day rolling window. **Phase 2 measurement (v1.1+):** the diarization-review Phase 2 activation criteria (applied/suggestions ≥40% over 4 weeks AND false-positive rate <20%, per Open Resolutions) double as wedge-validation for that sibling. **Failure case:** if the MVP jargon-correction observable is <20% of meetings over the first 60 days, OR if Phase 2 activation never trips after iteration, the AI-correction wedge claim is unvalidated and the Innovation §7 framing plus the post-MVP roadmap need explicit reconsideration.
- **Vault graph density:** Meeting notes become a measurably linked surface — by 90 days, ≥50% of meeting notes are referenced by at least one other vault note (project notes, daily notes, person notes), measured via Obsidian backlink count.
- **Community signal (stretch):** If open-sourced, the project earns ≥1 outside contributor and ≥10 GitHub stars within 6 months of public release. Not a goal; a directional indicator that the design space has resonance.

### Technical Success

The technical bar is set by the brainstorm's de-risking work and is non-negotiable in MVP:

- **End-to-end latency:** 30-minute meeting → notification fired in P50 ≤ 2 min, P95 ≤ 5 min on M5 Max. 60-minute meeting → P95 ≤ 10 min. Stage-level SLOs: capture stop → transcription complete ≤ 30s for 30-min audio (WhisperKit on ANE); transcription complete → summary written ≤ 60s P50 (Claude path).
- **Quote-grounding contract:** 100% of `action_items[*].source_transcript_quote` and `decisions[*].source_transcript_quote` survive a literal substring match against the source transcript. Items failing the check are dropped before the note is written. Zero hallucinated commitments reach the vault.
- **Atomic-write contract:** auricle never opens an existing vault file for write. All persistence is `temp file → fsync → atomic rename`. Zero recorded vault-corruption events across the MVP dogfood period.
- **Audio safety:** Zero recorded incidents of audio being deleted before the user clicks the verification notification. Retention timer arms only on click; "stale pending" surface (Dock badge in v1.1) ensures unverified audio is visible, not lost.
- **Attribution recoverability:** If the native attribution UI fails for any reason, the user can complete attribution via `auricle attribute --emit-snippets` + `auricle attribute --speakers "1=Ben,2=Sara"` from a terminal (v1.1) or publish-anyway with `#auricle/needs-attribution` and fix in Obsidian later (MVP). No meeting becomes permanently stuck in attribution.
- **Crash isolation:** A failure in any single stage (capture, transcribe, diarize, attribute, summarize, persist) does not corrupt artifacts from other stages. Each stage is a separate `auricle <stage>` process invocation with cache-dir handoff. Re-running a failed stage is idempotent.
- **VAD halting (v1.1):** Meetings with <2 minutes of detected speech in a 30-minute file halt the pipeline before summarization; no note is written, no notification fires, the meeting appears as `silent` in `auricle pending`. Manual override via `--force`.

### Measurable Outcomes

Per-meeting metrics auricle records to local telemetry (no remote reporting):
- `time_to_notification_seconds` — capture stop → notification fired
- `transcription_wer_estimate` — bootstrapped from transcript-vs-corrected-summary divergence
- `quote_validation_drop_count` — number of action items / decisions dropped for failing the grep check
- `attribution_completion_path` — `inline_ui` | `cli_speakers_flag` | `publish_anyway`
- `ai_corrections_applied` — count of AI corrections applied to this meeting's artifacts, broken down by sibling (`jargon`, `diarization`, `transcription`)
- `summarization_path` — `claude_api` | `local_llm` (post-MVP)
- `cost_usd` — Claude API spend (zero for local path)
- `audio_retention_status_at_30d` — `deleted_after_grace` | `kept_explicit` | `unverified_held`

Aggregate health metrics reviewed weekly during MVP dogfood:
- % of meetings where `publish_anyway` was used (target: ≤10%; high values mean attribution UX is broken)
- % of meetings where the user edited any action item in the vault within 24h (proxy for summarization quality; target: ≤30% edits indicates good extraction)
- Median `time_to_notification_seconds` (latency drift)
- Total weekly Claude spend (cost trajectory)

## Product Scope

### MVP - Minimum Viable Product

The MVP gate is a single cohesive milestone — not a walking skeleton — defined by the brainstorm's Phase 4 cut list. Ship-to-self when **all** of the following work end-to-end on a real captured meeting:

- ScreenCaptureKit system-audio capture with manual start/stop (no auto-detection)
- WhisperKit transcription using Whisper-large-v3-turbo (ANE-accelerated)
- WhisperKit built-in diarization (no pyannote; no cross-meeting voice-print matching)
- Native Mac windowed app with attribution UI: per-speaker audio snippets (QuickLook-style playback) + autocomplete sourced from (1) calendar attendees marked first, (2) vault wikilink targets, (3) previously-labeled speakers. "Publish anyway" button with `#auricle/needs-attribution` frontmatter flag.
- Claude summarization with quote-grounded extraction (single constrained-JSON call → render to markdown)
- One-note-per-meeting persistence with stable frontmatter contract and atomic-write semantics
- macOS user notification on summary ready; click → opens note in Obsidian → arms 7-day audio-retention timer
- Configurable retention grace window (default 7 days, 14-day escalation reminder)
- Decoupled CLI subcommand architecture: `auricle record`, `auricle stop`, `auricle process <id>`, `auricle attribute <id>` — Mac app dispatches to these subprocesses
- Google Calendar integration via OAuth: meeting title, attendees, time window injected into note frontmatter
- Vault-glossary builder: extracts wikilink targets from the vault (optionally scoped by meeting attendees) and injects as glossary into the Claude prompt for term correction
- LSUIElement=NO, Dock icon present, app stays alive on window-close (capture continues; attribution resumes on next open)

**Empirically resolved during MVP build (not gates, but resolutions):**
- Vault note shape detail — light community research (BASB / Obsidian) informs the frontmatter contract before lock
- Summarization engine choice — benchmark Claude vs. local Ollama/MLX on 10–20 captured real meetings; pick winner on quote-grounding accuracy + action-item recall

### Growth Features (Post-MVP)

These are explicitly cut from MVP but pre-designed and lined up next as **v1.1**:

- Menubar item (quick status, quick start/stop, click-to-open-window) — additive, not replacement
- VAD pre-flight halting gate — `<2 min speech in 30-min audio` halts pipeline, surfaces meeting as `silent` in pending list
- `auricle pending` CLI surface listing in-flight / silent / unverified meetings + Dock badge for stale items >N days old
- `auricle attribute --emit-snippets` + `auricle attribute --speakers "1=Ben,2=Sara"` CLI fallback path for when the native UI fails
- Long-context drift detection (token count + summary content density flag for suspiciously thin summaries on 60+ min meetings)
- `auricle keep <meeting-id>` — explicit retention override beyond grace
- Per-meeting configurable retention windows
- Local-LLM summarization path (Ollama/MLX) if the empirical benchmark favors it

### Vision (Future)

Reserved for **v2+**, after the tool has been used in real workflow for ≥3 months:

- Auto-detect "meeting in progress" by watching for running Zoom/Meet/Teams/etc. processes (research deferred — needs investigation of what's actually detectable without entitlements)
- Cross-meeting voice-print matching via pyannote 3.1 sidecar (Python subprocess, embeddings persisted; "this is the same person as the unlabeled speaker in your 2026-03-12 meeting")
- Meeting-type templates (1:1 / standup / external pitch / interview / brainstorm) replacing the single universal template
- Series-overview auto-aggregation (recurring meetings get a series-roll-up note alongside per-meeting notes)
- Chain-of-summarize fallback for very long transcripts (≥90 min) if single-call drift becomes a real problem
- Apple SpeechAnalyzer evaluation as a fallback ASR path (macOS 26+)

**Explicitly rejected (kept out of all scope tiers):**
- Bot-based meeting integration (violates the foundational "no bot in the meeting" constraint)
- Multi-user / team-shared notes (violates the single-user constraint that simplifies the entire architecture)
- iOS / iPadOS / web app (single-Mac constraint — separate product if ever built)
- OpenAI as a summarization vendor (locked out by user decision)
- A SaaS / hosted version (violates local-first foundational constraint)

## User Journeys

auricle has exactly one human user. "Multiple personas" is the wrong frame — the right frame is **multiple modes of the same person's interaction with the system**, each producing a distinct sequence of touchpoints and revealing distinct requirements. The four journeys below cover the behavioral surface area.

### Persona: the single user

- **Situation:** Independent engineer / maker. Attends 10–25 meetings per week across Zoom, Google Meet, occasional Discord and FaceTime calls. Maintains a personal Obsidian vault at `~/checkouts/SecondBrain` that he treats as a working memory layer — daily notes, project notes, person notes, idea inbox.
- **Pre-auricle reality:** Splits attention between participating and typing notes. Misses commitments. Some meetings end with no notes at all because the next thing on the calendar starts immediately. SaaS notetakers (Otter, Fireflies, Fathom) were ruled out: they require a bot to join the call, which is socially awkward, requires attendee consent, and exfiltrates audio to a vendor. Manual capture into Obsidian after the fact suffers from recall decay and inconsistent structure.
- **What he wants:** To stop thinking about notes. Show up to the meeting, have the conversation, walk away with a faithful, structured, vault-native record of what was said, decided, and committed to.
- **Obstacle:** The local-ML-on-Apple-Silicon and OS-audio-loopback capabilities to make this work without bots/SaaS only became viable in the last ~24 months and no shipping product yet occupies the intersection.
- **Solution:** auricle.

---

### Journey 1: The happy path — first end-to-end meeting

**Opening scene.** Tuesday morning. The user has a 30-minute Zoom with a collaborator. Five minutes before the meeting starts, he opens auricle (Dock icon, main window appears), confirms the calendar shows the upcoming event in the sidebar, and that's the entire pre-meeting interaction. He could also have done nothing — auricle's window can stay closed, and recording can be started from the menubar in v1.1, or via `auricle record` from a terminal at any time.

**Rising action.** The meeting starts. The user clicks the prominent **Record** button in the auricle main window. A small recording indicator appears (a pulsing red dot in the title bar of the auricle window; in v1.1, also in the menubar). The user puts auricle out of his mind. He participates in the meeting normally — speaks, listens, takes no manual notes. Other participants have no indication that anything is being recorded; auricle is invisible to Zoom and to them.

**Climax.** The meeting ends. The user clicks **Stop**. The auricle window now shows the meeting in a "Processing" state with a small progress indicator (transcribing → diarizing → ready for attribution). Roughly 30–60 seconds later, an **Attribution** sheet rises over the main window (modal, attached — not a separate window): a list of detected speakers (`Speaker_1`, `Speaker_2`, `Speaker_3`), each with a 5–10 second representative audio snippet (play button, QuickLook-style), and an autocomplete input for each. The user clicks the play button on `Speaker_1`, hears his collaborator's voice, types "Be" — the autocomplete shows `Ben` (calendar-attendee-marked, top of list, visually distinct from generic vault wikilinks below), the user presses Tab. He repeats for `Speaker_2`, which is himself; he selects his own wikilink, also calendar-marked. There were only two speakers. He clicks **Continue**. The summarization stage runs. ~30–60 more seconds. A macOS notification appears in the top-right: **"auricle: meeting ready — Tuesday sync with Ben."**

**Resolution.** The user clicks the notification. Obsidian launches (or focuses, if already running) and opens the new note. The note is at `~/checkouts/SecondBrain/Meetings/2026-04-28-tuesday-sync-with-ben.md` (or whatever the locked-in path convention is). The frontmatter contains the meeting time, duration, attendees as wikilinks, source path to the audio file, and a `auricle:` block with pipeline metadata. The body shows: a one-paragraph summary, an `## Action Items` section with three bullets each carrying a `> source quote`, a `## Decisions` section with one bullet and quote, and a collapsed `## Transcript` section at the bottom. The user skims, edits one action item's wording, and closes the file. In the auricle main window, the meeting now shows as ✓ Verified, with "Audio deletes in 7 days" as a small annotation. The user closes the auricle window. The app stays alive in the Dock.

**This journey reveals requirements for:**
- Recording controls (start, stop, recording-state visibility) in the main window
- Calendar-driven upcoming-event sidebar
- ScreenCaptureKit capture pipeline (system audio + own mic) into a cache directory
- Pipeline state surface (Processing / Awaiting Attribution / Awaiting Verification / Verified)
- Attribution UI: per-speaker snippet playback, calendar-marked autocomplete, "this is me" self-attribution flow
- Summarization stage with quote-grounded JSON output
- Markdown rendering with stable structure (frontmatter → summary → action items → decisions → transcript)
- Vault path convention (configurable, with sensible default)
- macOS notification with click → URL-scheme open of the note in Obsidian
- Click-to-verify wiring: notification click both opens the note **and** arms the audio retention timer

---

### Journey 2: Attribution friction — "publish anyway"

**Opening scene.** Friday afternoon, end of the week. The user just finished a 50-minute mostly-listening meeting with eight participants — a project kickoff with a vendor team he's never worked with. He has 8 minutes until his next call. He clicks Stop in auricle.

**Rising action.** The Attribution sheet rises over the main window. There are seven detected speakers (one person spoke too briefly to be diarized as their own cluster). The user recognizes his own voice and one collaborator. The other five voices are people he just met today — he'd be guessing at names, and the autocomplete is showing six calendar attendees but he can't reliably map snippet-to-name without significant playback effort. He doesn't have the time.

**Climax.** The user clicks the **"Publish anyway"** button at the bottom of the Attribution view. A small confirmation appears: *"This meeting will be published with `Speaker_N` labels and tagged `#auricle/needs-attribution` in frontmatter. You can fix it in Obsidian later, or re-run attribution from this window."* The user clicks Confirm. Summarization runs. ~60 seconds later, the notification appears.

**Resolution.** The user clicks the notification. Obsidian opens the note. Speakers in the summary text are rendered as `Speaker_1`, `Speaker_2`, etc. (no wikilinks). The frontmatter contains `tags: [auricle/needs-attribution]`. The action items still have quote-grounding; the decisions are still there. The note is usable for end-of-day recall even though the speakers aren't named. The user doesn't fix attribution today — but a week later, when he's revisiting the project, he opens the note, recognizes a quote, edits `Speaker_3` to `[[Priya]]` everywhere in the file, and removes the `#auricle/needs-attribution` tag manually. The note is now permanently fixed.

**This journey reveals requirements for:**
- "Publish anyway" affordance prominently placed in the Attribution UI, with explanatory micro-copy
- Confirmation step (one click, not a modal — speed matters here)
- Frontmatter contract that includes a tags array supporting `auricle/needs-attribution`
- Render path that handles `Speaker_N` placeholder labels without breaking the markdown structure
- Vault freedom: auricle never re-edits the note, so the user's manual fix in Obsidian is permanent and uncontested

---

### Journey 3: The silent meeting — pipeline halts cleanly (v1.1)

**Opening scene.** The user started recording before joining a Zoom call, then realized he was on the wrong meeting URL and the actual meeting got rescheduled. He forgot the recording was running. Two hours later, he notices the auricle recording indicator and clicks Stop.

**Rising action.** The cache now contains a 2-hour audio file consisting of system silence punctuated by occasional notification sounds, his keyboard, and 30 seconds of background music from a YouTube video he played at one point.

**Climax (v1.1).** auricle's pre-flight VAD halting gate detects <2 minutes of speech in the file. The pipeline halts before transcription. No note is written. No notification fires. In the auricle main window, the meeting appears in the **Pending** list with status `silent — pipeline halted`. The `auricle pending` CLI shows the same.

**Resolution.** The user sees the silent status, recognizes what happened, clicks **Discard** on that meeting in the auricle window. The cached audio is deleted. No vault note was ever created — there's nothing to clean up in Obsidian. Optionally, if he believed there was real content the VAD missed, he could click **Force process** (or run `auricle process <id> --force`), which bypasses the gate.

**MVP fallback (no VAD yet).** Without the v1.1 VAD gate, this scenario produces a transcribed file that's mostly noise, a summarization run that yields an empty or thin summary, and a note in the vault that the user has to manually delete. This is the motivation for VAD as a v1.1 priority — the worst MVP case is a vault note he has to delete manually, which is annoying but not catastrophic, and the brainstorm explicitly accepted this MVP risk.

**This journey reveals requirements for:**
- (v1.1) VAD pre-flight halting gate with configurable threshold (default: <2 min speech in any duration of audio)
- (v1.1) `Pending` state surface in the main window AND `auricle pending` CLI subcommand
- (v1.1) `Discard` action on a pending meeting (deletes cached audio, removes from pending list)
- (v1.1) `Force process` override
- (MVP) Manual-discard path: user can find the cached meeting in the main window, click Discard, and the audio is removed even before publication

---

### Journey 4: Power-user CLI recovery — attribution UI is broken

**Opening scene.** The user is on macOS Sonoma. A new auricle release introduces a regression in the Attribution view — the snippet playback button doesn't respond to clicks. He has a meeting that finished an hour ago waiting for attribution. He files a bug, but he wants to publish the note now.

**Rising action.** The user opens a terminal and runs `auricle pending`. The output lists the stuck meeting with its ID. He runs `auricle attribute <id> --emit-snippets`, which writes seven WAV snippets to `~/Library/Caches/auricle/<id>/snippets/`. He QuickLooks each one in Finder, recognizes voices, and writes down the mapping mentally.

**Climax.** The user runs `auricle attribute <id> --speakers "1=Ben,2=Jordan,3=Priya,4=Marcus,5=Diana,6=Kenji,7=Sara"`. The CLI resolves each name against the vault (matching wikilink targets, falling back to creating new wikilinks for unknown names), validates the mapping, and resumes the pipeline. Summarization runs. The notification fires ~60 seconds later.

**Resolution.** The user clicks the notification, opens the note in Obsidian. Everything is correctly attributed — the broken UI never blocked him. He continues using the released CLI path until a fix ships.

**This journey reveals requirements for:**
- (v1.1) `auricle pending` CLI subcommand that lists in-flight, awaiting-attribution, awaiting-verification, and stale-pending meetings with their IDs
- (v1.1) `auricle attribute <id> --emit-snippets` flag that writes per-speaker WAV snippets to cache and exits
- (v1.1) `auricle attribute <id> --speakers "1=Name1,2=Name2,..."` flag that accepts a manual mapping, resolves names against the vault, and resumes the pipeline
- (MVP) The decoupled architecture itself — every stage being a separate CLI subprocess invocation is what makes this fallback path *possible* without rebuilding anything

---

### Journey 5: Retention housekeeping — keeping audio for a meeting that matters

**Opening scene.** Three months in, the user has used auricle through a contentious project meeting. The summary captured the decisions correctly, but he wants to keep the audio long-term as a reference — there's institutional value in being able to re-transcribe if the summary ever gets disputed. The default retention timer would delete it 7 days after he clicked the verification notification.

**Rising action.** The user sees the meeting in the auricle main window with "Audio deletes in 5 days" annotation. He right-clicks (or in v1.1, runs `auricle keep <meeting-id>`). A menu appears with **Keep audio indefinitely** and **Set custom retention…** options.

**Climax.** The user clicks **Keep audio indefinitely**. The retention timer is cleared. The annotation now reads "Audio kept (indefinite)". The meeting frontmatter in Obsidian gets a new field: `auricle.audio_retention: indefinite`.

**Resolution.** The audio remains on disk. Six months later, when the dispute actually surfaces, the user runs `auricle process <id> --reattribute` (a hypothetical CLI verb worth designing), and the audio is still there. Worst case, it's there for him to play back manually.

**This journey reveals requirements for:**
- (MVP) Per-meeting audio-retention status surface in the main window
- (v1.1) `auricle keep <meeting-id>` CLI command + main-window UI affordance for indefinite retention
- (v1.1) `Set custom retention…` UI for per-meeting override
- (v1.1) Frontmatter field `auricle.audio_retention` reflecting the chosen retention policy

### Journey Requirements Summary

Capabilities that fall out of these five journeys, grouped by surface area:

- **Capture surface:** Record/Stop controls, recording-state indicator, calendar-driven upcoming-event sidebar, ScreenCaptureKit system-audio + mic capture into cache, manual-discard path
- **Pipeline surface:** Processing/Awaiting-Attribution/Awaiting-Verification/Verified/Pending state machine, idempotent stage re-runs, decoupled CLI subcommands per stage, (v1.1) `auricle pending` listing
- **Attribution surface:** Per-speaker snippet playback, calendar-marked autocomplete with priority order (calendar attendees → vault wikilinks → previously-labeled), self-attribution flow, "Publish anyway" with `#auricle/needs-attribution` tag and `Speaker_N` placeholder rendering, (v1.1) `--emit-snippets` + `--speakers` CLI fallback
- **Summarization surface:** Constrained-JSON Claude call with quote-grounded action items + decisions, grep validation that drops missing-quote items, vault-glossary injection
- **Persistence surface:** Atomic-write contract, stable frontmatter schema (attendees, calendar metadata, audio path, retention policy, tags), one-note-per-meeting at convention-defined path, never-edit-existing-note rule
- **Notification surface:** macOS user notification on summary ready, click-to-open-in-Obsidian via URL scheme, click-arms-retention-timer wiring
- **Retention surface:** Default 7-day grace post-click, escalation reminder at 14 days, (v1.1) `auricle keep` for indefinite/custom retention, per-meeting frontmatter reflection of chosen policy
- **Lifecycle surface:** App stays alive on window close, capture continues in background, attribution resumes on next window open, (v1.1) menubar quick-status / quick start-stop / open-window

## Innovation & Novel Patterns

### Detected Innovation Areas

auricle's novelty is not in any single component — Whisper, ScreenCaptureKit, Obsidian, and Claude all exist independently and well-documented. The novelty is in **the specific combination and the constraints it makes possible**:

1. **Bot-free meeting intelligence.** Every commercial meeting-notes product (Otter, Fireflies, Fathom, Granola, Tactiq, Read.AI, Avoma) is bot-based — they require an account on the meeting platform and a participant slot. auricle's OS-level capture eliminates the bot category entirely, which in turn eliminates: account-integration friction, attendee-consent prompts, vendor audio exfiltration, and the social awkwardness of a labeled bot in the call. This is an architectural innovation, not a feature; the design space below the bot-line is essentially unoccupied as a shipping product.
2. **Local-first transcription pipeline as a default.** WhisperKit on Apple Silicon is the technical enabler. The market norm is server-side transcription (lower friction for vendors, easier model upgrades). auricle inverts this: transcription, diarization, and glossary correction all run on-device, and only summarization may make a remote call (Claude). This is unusual enough that the architecture itself is the differentiator.
3. **Quote-grounded extraction as an MVP contract.** Most LLM-summarization products treat hallucinated commitments as a quality-improvement problem to be solved with better prompting. auricle treats it as a contract: every action item and decision must cite a verbatim transcript quote that survives a literal grep against the source. Items failing the check are dropped before the note is written. This is a design-by-construction approach that, applied to meeting summarization, eliminates an entire class of failure mode.
4. **Vault-native output, not export.** Tools that output to Obsidian usually do so via export (a button, an integration, a plugin). auricle's persistence layer *is* the vault — atomic-write contract, stable frontmatter schema, speakers as wikilinks, never edits existing notes. The vault is a first-class consumer with a guaranteed contract, not an integration target.
5. **Two-stage audio retention coupled to verification.** Most recording tools either keep audio forever (privacy creep) or auto-delete on a timer (data loss when the user is busy). auricle ties retention to the user's *verification action* (clicking the macOS notification, which opens the note in Obsidian). The 7-day grace timer arms only on click. Audio is never auto-deleted before the user has at least seen the summary. This is a small UX pattern but the right one for a privacy-conscious local tool — and not implemented in any competing product.
6. **Decoupled CLI subcommand architecture as the failure-recovery story.** The Mac app dispatches to `auricle <stage>` subprocesses. This isn't just clean architecture — it's the failure-recovery surface. When the native attribution UI breaks, the user can run `auricle attribute --emit-snippets` and `--speakers "1=Ben,2=Sara"` from a terminal. Stages are crash-isolated and idempotent. No commercial competitor exposes this surface because their product isn't decoupled this way.
7. **AI-assisted correction as a product category — the differentiator vs the user's current workflow.** The user's pre-auricle workflow (Google Pixel Recorder → manual Claude → Obsidian) already produced transcripts and a kind of summary; what was missing was AI doing the *correction* work — fixing diarization mis-segmentation, fixing transcription homophones and proper nouns, applying vault-glossary terms — grounded in the same context (calendar attendees, vault wikilinks) the user has on hand. auricle elevates correction to a first-class product category with three siblings (jargon, diarization, transcription) sharing one `AIReviewerStrategy` family, shipped via a Path C activation flow that lays all architectural slots in MVP and enables features behind flags after dogfood validation. This category framing was confirmed by the user on 2026-05-01 during UX workflow (Step 10) and was not surfaced explicitly in the original PRD; it is the load-bearing reason auricle is meaningfully better than "Pixel Recorder + Claude" rather than just a different shape of the same thing.

### Market Context & Competitive Landscape

The meeting-notes market segments by capture method:

- **Bot-based SaaS notetakers (the dominant category):** Otter.ai, Fireflies, Fathom, Granola, Tactiq, Read.AI, Avoma, Sembly, Krisp Notes. All require either (a) a meeting-platform integration and a participant bot, or (b) a calendar OAuth that auto-joins meetings. All exfiltrate audio to vendor cloud. All charge subscription fees. All struggle with the "is this bot welcome?" problem.
- **Manual / native meeting recording (Zoom built-in, Google Meet built-in):** Captures audio + cloud transcription, but no structured output, no vault integration, no action-item extraction. Locked to one meeting platform.
- **Local-first transcription tools (MacWhisper, Aiko, Hello Transcribe):** Excellent transcription, but they're file-in-text-out — no calendar enrichment, no diarization-to-attribution UX, no summarization, no vault integration, and most expect you to point them at a recording you already made.
- **Personal-knowledge-vault integrations (Obsidian community plugins, Tana, Logseq plugins):** Various meeting-template plugins, but none capture audio or run a transcription pipeline. They're write-side integrations, not capture-side.

auricle is the union of categories 3 and 4 with the "no bot" architectural constraint of category 1 removed. **No shipping product currently occupies this intersection** — verified by the brainstorming session's research and by the absence of obvious search hits for "local-first ScreenCaptureKit Whisper Obsidian meeting." If a product appears here in the next 6–12 months, it would validate the design-space thesis; meanwhile, the gap is the opportunity.

### Validation Approach

- **Quote-grounding contract:** Validated by deterministic grep, not by judgment. Every shipped action item and decision either survived the literal substring check or was dropped. This is testable in a unit test against a corpus of (transcript, summary) pairs.
- **End-to-end latency claim (≤ 2 min P50, 30-min meeting on M5 Max):** Validated by instrumenting the pipeline with stage-level timing telemetry from the first real captured meeting. The brainstorm already produced a directional estimate; the MVP confirms it on real hardware with real audio.
- **Summarization quality (Claude vs. local LLM):** Resolved empirically during the MVP build phase by running both engines on 10–20 captured real meetings and scoring by quote-grounding pass-rate and action-item recall. The benchmark is the decision mechanism.
- **Adoption / replacement claim:** Validated by self-attestation at 30, 60, 90 days. The signal is whether the user defaults to auricle's notes when looking up "what did we decide about X" rather than scrolling Slack — a behavioral signal, not a survey.

### Risk Mitigation

- **WhisperKit diarization quality risk.** Mitigation: native attribution UI with audio snippets means diarization can be merely *adequate* rather than excellent — the user is in the loop. If quality is genuinely poor, the post-MVP fallback is pyannote 3.1 in a Python sidecar (already scoped in v2+). Fallback path is designed; not a blocker.
- **WhisperKit transcription quality risk on long meetings.** Mitigation: Whisper-large-v3-turbo is the highest-quality on-device option currently shipping. If WER on real meetings is unacceptable, the alternate ASR path is Parakeet-TDT via MLX (flagged as "verify-before-implementing" in the brainstorm). If both are inadequate, the macOS 26+ Apple SpeechAnalyzer path is a fallback. Three independent paths; the risk is contained.
- **ScreenCaptureKit API churn.** Apple-controlled API surface that has changed shape twice since macOS 13. Accepted MVP risk per brainstorm; mitigation is staying current with macOS releases and treating the capture stage as the most likely site of breakage on each OS update.
- **Claude API cost / availability.** Mitigation: per-meeting cost ceiling tracked in telemetry; local-LLM path (Ollama/MLX) is in the post-MVP escape hatch and is the long-term hedge. Auricle's architecture treats the summarization stage as swappable.
- **Long-context drift on 60+ min meetings.** Mitigation: MVP guard is a token-count + summary-density flag for suspiciously thin summaries on long meetings (v1.1). Post-MVP fix path is chain-of-summarize (Axis 6 escape hatch in the brainstorm). The risk is bounded and the fix path is designed.
- **Innovation-validation risk (does the architectural bet pay off?).** Mitigation: the user *is* the customer. There's no need to validate market fit in the abstract — adoption-by-self at the 30/60/90 day marks is the validation, and if the tool isn't earning its place in the user's workflow, that's a signal to either pivot or shelve. No external commitments are at stake.

## Desktop App Specific Requirements

### Project-Type Overview

auricle is a native macOS application — not Electron, not Catalyst, not cross-platform. The architecture is a SwiftUI / AppKit windowed app with a Dock icon, plus an `auricle` CLI binary that ships in the same `.app` bundle (typically at `Auricle.app/Contents/MacOS/auricle`, optionally symlinked into `~/.local/bin` or `/usr/local/bin` by an installer step). The Mac app is the orchestrator and primary UI; the CLI is the failure-recovery surface, the testing surface, and the scripting surface. Both call into the same underlying Swift modules (capture, transcribe, diarize, summarize, persist) — there is no language boundary, no IPC protocol to maintain, no parallel implementations. The only IPC is OS-level process spawning: the Mac app launches `auricle <stage> <id>` subprocesses for crash-isolated stage execution.

### Platform Support

- **Target OS:** macOS 14 (Sonoma) and later. ScreenCaptureKit's stable system-audio-loopback API requires macOS 13+, but several QoL APIs (notably refined permission prompting, cleaner `SCStream` handling) landed in 14. Pinning to 14 simplifies the support matrix.
- **Architecture:** Apple Silicon only (arm64). WhisperKit's ANE-acceleration story doesn't generalize cleanly to Intel Macs, and the brainstorm's latency budget assumes ANE. Intel support is not a goal.
- **Hardware floor:** M1 or later. M5 Max is the brainstorm's reference hardware for the latency targets (≤2 min P50 for 30-min meeting). M1/M2 will be slower but acceptable; M3/M4/M5 hit the documented SLOs.
- **Cross-platform:** Explicitly out of scope. iOS/iPadOS/Linux/Windows are not in any roadmap tier. The single-platform constraint is load-bearing — it lets every architectural decision lean on Apple-stack APIs (ScreenCaptureKit, MLX/Core ML, Notification Center, NSUserActivity, Calendar.framework, etc.) without abstraction layers.
- **Distribution form factor:** Standard `.app` bundle distributed as a `.dmg` (or directly via `.app` zip) — initially via GitHub Releases. App Store distribution is **not** on the roadmap because the entitlements model conflicts with `auricle`'s system-audio capture requirements (see "System Integration" below).

### System Integration

auricle is a deeply system-integrated app. The integration surface is large and worth enumerating:

- **ScreenCaptureKit** — System-audio capture (loopback). Requires the `Screen Recording` permission (TCC). The user grants this once on first capture attempt; auricle handles the permission-denied flow with a clear in-app explanation that points to System Settings → Privacy & Security → Screen Recording. Microphone capture (the user's own voice) requires the `Microphone` permission (separate TCC entry).
- **Notification Center** — `UNUserNotificationCenter` for the "summary ready" notification. Requires Notification permission (granted on first request). Notification carries a meeting-ID payload; click handler routes through `UNUserNotificationCenterDelegate` to (a) open the note in Obsidian via URL scheme and (b) arm the audio retention timer.
- **Obsidian URL scheme** — `obsidian://open?vault=SecondBrain&file=Meetings/2026-04-28-...`. auricle opens the note via `NSWorkspace.shared.open(url:)`. No Obsidian plugin is required; the URL scheme has been stable for years.
- **Calendar integration** — Google Calendar via OAuth 2.0 device-code flow, tokens stored in Keychain. The brainstorm explicitly locked Google Calendar (not EventKit/Calendar.app) because the user's primary calendar is Google Workspace. EventKit support is a possible future addition for users on Apple Calendar, but not MVP.
- **Keychain** — `kSecClassGenericPassword` items for the Google OAuth refresh token and (when the Claude path is selected) the Anthropic API key. The user enters the API key once via Settings; it is never persisted in plaintext on disk.
- **Dock** — Standard Dock icon. App stays alive when the main window is closed (capture continues in background). Dock badge reserved for v1.1 stale-pending count.
- **Menubar (v1.1)** — `NSStatusItem` with quick actions: Start Recording / Stop Recording / Open Window / show pending count. Click-to-open-window is the primary affordance.
- **launchd** — Not used in MVP. Capture lifecycle is tied to the running app process; on app quit, capture stops. A v1.1 question is whether to add a `LaunchAgent` so capture can survive app crashes — likely not, because the user wants intentional control.
- **Filesystem** — Cache directory at `~/Library/Caches/com.auricle.app/` for in-flight audio, transcripts, and stage artifacts. Application Support at `~/Library/Application Support/com.auricle.app/` for the local SQLite database tracking meeting state, retention timers, and config. Vault path (configurable, default `~/checkouts/SecondBrain`) for output notes.
- **QuickLook** — In-app audio snippet playback during attribution uses `QLPreviewPanel` or an embedded `AVPlayerView`. WAV snippets are written to cache during the attribution stage.
- **Spotlight / Quick Look (output side)** — Notes are markdown files in the user's vault, so they are already indexed by Spotlight and previewable in QuickLook automatically. No special integration needed.
- **TCC permissions summary:** Screen Recording, Microphone, Notifications. Calendar permission is **not** required — Google Calendar is hit via HTTPS API, not via EventKit.

### Update Strategy

- **MVP:** Build locally and / or distribute via GitHub Releases. Each release ships a `.app` (or `.dmg`) signed with the self-managed code-signing leaf cert (per NFR-S2). The user replaces the app bundle in `/Applications`. No in-app update prompting in MVP. First install on any new personally-owned Mac requires a one-time `scripts/setup-trust.sh` run (~5 min) that registers the personal CA + leaf-cert hash with `spctl` so that all current and future signed builds are accepted by Gatekeeper without further intervention.
- **v1.1:** Sparkle (the canonical macOS auto-update framework). EdDSA-signed appcasts published from GitHub Releases. In-app "Check for Updates…" menu item. Optional automatic-check toggle (default off — the user retains control). Sparkle's update flow handles the entire download / verify / replace / relaunch sequence; downloaded updates are accepted by Gatekeeper because the `.app` is signed with the same leaf cert already trusted via `spctl` policy on each user Mac.
- **Code signing:** Self-managed code-signing certificate — a personal Code Signing CA (root, self-signed) + per-tool leaf cert ("Auricle Code Signing"). Hardened runtime enabled. Trust is established via `sudo security add-trusted-cert` (system keychain) + `sudo spctl --add --requirement 'anchor H"<ca-hash>"'` on each user Mac at first install. This replaces the Apple Developer ID + notarization path because (a) auricle is single-user / personally-owned-Macs only by design, and (b) notarization solves a problem (cross-organization trust) that auricle's distribution model does not have. Apple Developer ID + notarization is the documented alternative if cross-user distribution ever becomes a requirement (see architecture's Distribution Model for the migration path).
- **Versioning:** Semantic versioning. Major bumps for frontmatter-schema changes (because vault-side downstream consumers depend on the schema). Minor for new features. Patch for bug fixes. Frontmatter schema version is itself recorded in every note's frontmatter (`auricle.schema_version: 1`) so that future readers can handle migration.

### Offline Capabilities

auricle's offline story is unusually strong because of the local-first architecture. Offline behavior by stage:

| Stage | Online required? | Notes |
|---|---|---|
| Capture (ScreenCaptureKit) | No | Pure local OS API |
| Transcribe (WhisperKit) | No | Model weights (~1.5 GB for Whisper-large-v3-turbo) bundled or downloaded once on first run; pure on-device inference thereafter |
| Diarize (WhisperKit built-in) | No | Same model bundle as transcription |
| Vault-glossary build | No | Reads vault files directly |
| Attribution UI | No | All snippet playback and autocomplete are local |
| Summarize (Claude path) | **Yes** | Anthropic API call; queued and retried with backoff if offline |
| Summarize (local LLM path, post-MVP) | No | Ollama or MLX-based local inference |
| Persist (vault write) | No | Local filesystem |
| Notify | No | Local Notification Center |
| Calendar enrichment | **Yes** | Google Calendar API; falls back to attendees-unknown if offline |

**Offline UX:** When offline, the pipeline runs all on-device stages, then queues the summarization call. The meeting appears in the auricle main window with status `awaiting summarization (offline)`. When connectivity returns, the queue drains automatically. The user is never blocked from capturing more meetings while offline — the pipeline backs up gracefully.

**Calendar offline behavior:** If the Google Calendar API is unreachable at the moment a meeting is being captured, auricle still captures audio. Calendar enrichment is retried before summarization; if still unreachable, the note publishes with title `Meeting at <timestamp>` and empty attendees, and a `#auricle/needs-calendar-enrichment` tag for later backfill.

### Implementation Considerations

- **Sandboxing:** **Not sandboxed.** App Sandbox conflicts with both ScreenCaptureKit's audio-capture entitlement model (in some configurations) and direct vault filesystem writes outside `~/Library/Containers/`. Hardened runtime is on; sandboxing is off. This is the standard tradeoff for utility apps that need broad system access. App Store distribution would require sandboxing — and is therefore explicitly off the roadmap.
- **Entitlements:** `com.apple.security.device.audio-input` (microphone), notification entitlements, and any future entitlements required by ScreenCaptureKit's evolving API. No `com.apple.security.app-sandbox`.
- **Build / packaging:** Swift Package Manager for source dependencies (WhisperKit, swift-argument-parser for the CLI, GRDB for SQLite, Sparkle for v1.1). Xcode project for the app target; CLI target as a secondary executable in the same project. Universal binary not needed (Apple Silicon only). Release builds are signed with the self-managed code-signing leaf cert (per NFR-S2); no notarization step (per NFR-C4 / Update Strategy). Per-Mac trust setup is a one-shot `scripts/setup-trust.sh` invocation, not a build-pipeline step.
- **Telemetry:** Local-only by default (per the brainstorm's lock on "no remote reporting"). A SQLite table records per-meeting metrics for the user's own dashboard surface. Future: opt-in anonymized aggregate telemetry to a self-hosted endpoint, only if and when the project goes public — not MVP.
- **Crash reporting:** macOS's built-in `ReportCrash` handles writing crash logs to `~/Library/Logs/DiagnosticReports/`. No third-party crash reporter (Crashlytics, Sentry, etc.) in MVP — the user is the developer; he can read the logs.
- **Logging:** `os_log` / unified logging system. Subsystem `com.auricle.app`. Categories per stage (`capture`, `transcribe`, `diarize`, `attribute`, `summarize`, `persist`). Surfaced via `log show --predicate 'subsystem == "com.auricle.app"'`. CLI subcommands also log to stderr at appropriate levels for terminal use.
- **Testing surface:** Each pipeline stage's CLI invocation is the integration-test surface. Unit tests in Swift cover schema validation, quote-grounding grep validation, vault-glossary extraction, and frontmatter rendering. End-to-end smoke test: a small reference WAV file with known content, a dry-run summarization, and a vault-write to a temp directory.
- **Skipped sections (per CSV):** `web_seo` and `mobile_features` are not applicable to this product type and are explicitly out of scope.

## Project Scoping & Phased Development

The MVP / Growth / Vision feature breakdown is already enumerated above in [Product Scope](#product-scope). This section adds the **strategic rationale** behind the MVP boundary, the **resource model** that constrains it, and the **risk-mitigation strategy** that justifies the cuts — without re-listing the features.

### MVP Strategy & Philosophy

**MVP approach: cohesive-milestone, not walking-skeleton.** Per the brainstorm's Phase 4 lock-in: *"CLI-only walking skeleton wouldn't motivate dogfooding. The MVP gate is when capture + diarization + native attribution + good summaries land together."* This is the product-validation philosophy — auricle does not exist as a useful product until **all** of the MVP features land together. There is no half-built version that earns user trust. The intermediate states (capture-only, transcribe-only, summarize-only) are useful as engineering checkpoints but not as user-facing milestones.

The fastest path to validated learning is therefore not "ship a thin slice and iterate" — it's **ship the full MVP cohesively, then dogfood for 30 days against the success criteria** (≥80% meeting capture rate, replacement of all parallel notetaking, vault-graph density). Every learning loop after the MVP gate is a real-data loop.

**MVP question answers:**

- *What's the minimum that would make the user say "this is useful"?* → A first end-to-end run where a real meeting becomes a structured Obsidian note with attributed speakers and quote-grounded action items, in <2 minutes of post-meeting wait. Anything less than this fails the trust-building phase.
- *What's the fastest path to validated learning?* → Risk-front-loaded build order (already locked in the brainstorm): pipeline plumbing first (validates Claude summarization quality on real transcripts before any UI is built), then capture (validates the ScreenCaptureKit story), then attribution UI (validates the differentiating UX), then app shell, notifications, calendar, vault-glossary. The first three steps de-risk every architectural assumption that could kill the project.
- *What if the MVP fails?* → If the dogfood period reveals Claude summarization quality is inadequate (low quote-grounding pass-rate, poor action-item recall), the local-LLM benchmark already in scope is the resolution mechanism. If WhisperKit transcription is inadequate, the Parakeet-TDT alternate ASR path is the next step. If WhisperKit diarization is inadequate, the pyannote sidecar is the v2 escape hatch. Each known failure mode has a designed response.

### Resource Requirements

- **Team:** One engineer (the user). Evenings and weekends. The brainstorm explicitly tested both "weekend MVP" and "evening MVP" pressure scenarios in Phase 4 — both produced the same opinionated cut list.
- **Skill stack required:** Swift / SwiftUI / AppKit (primary), Swift Package Manager, Xcode build/sign/notarize toolchain, basic familiarity with WhisperKit's API surface, Anthropic SDK or HTTP client, Google Calendar OAuth flow, Obsidian markdown / frontmatter conventions, atomic-write filesystem patterns. All within the user's existing skill range or one-evening-of-reading away.
- **Hardware:** M1 minimum (the user has M5 Max, well above the floor). No external infrastructure required — no servers, no databases, no CDN, no telemetry endpoints.
- **External dependencies (paid):** Anthropic API account with usage-based billing (~\$0.10 per 30-min meeting at MVP cost ceiling). Google Cloud project for Calendar OAuth client (free at this volume). Total recurring cost: ~\$10/month at typical meeting load. **No fixed-cost dependencies** — Apple Developer Program subscription is intentionally avoided (see NFR-C4 + NFR-S2 + architecture's Distribution Model); the project uses a self-managed code-signing CA + per-Mac `spctl` trust policy instead.
- **Estimated effort:** 6–10 evening-equivalents to MVP, per the brainstorm's risk-front-loaded build order — 8 numbered build steps, each scoped to roughly one focused session, with the attribution UI being the most likely to slip and warrant two sessions. This is an estimate, not a commitment, and the cohesive-milestone philosophy means the gate is when it works, not when the calendar says it should.

### MVP Boundary Rationale (why these specific cuts)

Each cut from MVP → v1.1 / v2+ has a deliberate rationale:

| Cut from MVP | Rationale |
|---|---|
| **Menubar item** → v1.1 | Native Mac windowed app is required for the attribution UX (audio playback, autocomplete, sustained attention). Menubar popover would force the wrong form factor. Once the windowed app exists, the menubar item is additive convenience, not core. |
| **VAD pre-flight halting gate** → v1.1 | The worst MVP case (silent meeting → empty note in vault) is annoying but not catastrophic. User can manually delete the note. Building the VAD plumbing right (configurable threshold, halting state in the pending list, `--force` override) is a meaningful chunk of work that doesn't earn its way into MVP. |
| **`auricle pending` CLI + Dock badge** → v1.1 | The MVP user can see in-flight meetings in the main window. The CLI surface and the stale-pending Dock badge are operability features that matter once meeting volume scales — not on day one. |
| **CLI attribution fallback (`--emit-snippets` / `--speakers`)** → v1.1 | The MVP "publish anyway" + `#auricle/needs-attribution` flow handles the worst case (UI broken, can't attribute). The CLI fallback is for a more degenerate case (need to attribute via terminal because the app won't open) which is unlikely on day one. |
| **Cross-meeting voice-print matching** → v2+ | Requires pyannote 3.1 in a Python sidecar — an entire new language runtime in the bundle. Big lift, single user, post-MVP can survive without it (per-meeting attribution via WhisperKit diarization is acceptable for v1). |
| **Auto-detect "meeting in progress"** → v2+ | Research deferred — needs investigation of what process-watching is actually possible on macOS without unusual entitlements. Manual record/stop is acceptable in MVP. |
| **Meeting-type templates** → v2+ | Universal template is sufficient for first 3 months. Templates earn their way in only after the user has captured enough meetings to feel which categorical splits actually matter. |
| **Local-LLM summarization path** → v1.1 (conditionally) | Resolved by empirical benchmark during MVP build phase. If Claude clearly wins on quote-grounding accuracy, local-LLM may not ship until v2. If local LLMs prove competitive, this jumps to v1.1 as the cost-elimination win. |

### Risk Mitigation Strategy

**Technical risks:** Already enumerated in [Innovation & Novel Patterns → Risk Mitigation](#innovation--novel-patterns) above. Summary: each known technical risk has a designed fallback path already scoped, so no single technical failure is project-ending.

**Market risks (reframed for a single-user tool):** The "market" is the user himself. The risk is *the tool fails to earn its place in the user's daily workflow* despite working technically. Mitigation: the success criteria explicitly tie validation to behavioral change (replacement of parallel notetaking, ≥80% capture rate, default-recall behavior at month two). If those signals fail at the 30-day mark, the MVP is honest about it — there's no pressure to declare success against a sunk-cost commitment.

**Resource risks:**

- *What if available time drops below estimate?* The MVP scope is non-negotiable as a coherent milestone — extending the timeline is the correct response, not removing features. The cohesive-milestone philosophy explicitly rejects "ship something thinner sooner."
- *What if a core dependency breaks (WhisperKit, ScreenCaptureKit API churn, Anthropic API change)?* Each is independently swappable per the decoupled architecture. WhisperKit could be replaced with Parakeet or Apple SpeechAnalyzer at the transcribe stage; Anthropic could be replaced with a local LLM at the summarize stage; ScreenCaptureKit is the most coupled (no real alternative for system-audio loopback on macOS) and the most accepted risk.
- *What if the user gets bored or distracted before MVP completes?* The risk-front-loaded build order is the answer: stage 1 (`auricle process <audio-file>` CLI) delivers a working transcription + summarization pipeline you can play with on existing recordings before any UI is built. Each stage produces a shippable improvement to the user's workflow even if the project pauses there.

## Functional Requirements

These functional requirements are **the capability contract** for auricle. UX design, architecture, and epic breakdown all derive from this list. Anything not enumerated here will not be built. Each FR is tagged with its scope tier: **[MVP]**, **[v1.1]**, or **[v2+]** — corresponding to the tiers locked in [Product Scope](#product-scope).

### Capture

- **FR1 [MVP]:** The user can start audio capture for a meeting via a prominent control in the auricle main window.
- **FR2 [MVP]:** The user can stop audio capture via the same control, ending the recording and triggering the post-capture pipeline.
- **FR3 [MVP]:** The user can see a visible recording-state indicator while capture is active (in the main window title bar, at minimum).
- **FR4 [MVP]:** auricle can capture system audio (loopback from any application playing audio: Zoom, Google Meet, Teams, Discord, FaceTime, browser audio, video playback) without requiring integration with the meeting platform.
- **FR5 [MVP]:** auricle can simultaneously capture the user's microphone audio and mix it with system audio for a complete two-sided recording.
- **FR6 [MVP]:** auricle can request and handle macOS Screen Recording and Microphone permissions, with clear in-app explanation if permission is denied.
- **FR7 [MVP]:** The user can manually discard a captured-but-unprocessed meeting from the main window, removing the cached audio.
- **FR8 [v1.1]:** The user can start and stop capture from a menubar item without opening the main window.
- **FR9 [v1.1]:** auricle can pre-flight a captured audio file with VAD and halt the pipeline if speech-content is below a configurable threshold (default: <2 minutes of speech in any-duration audio), surfacing the meeting as `silent` instead of producing an empty note.
- **FR10 [v1.1]:** The user can override a VAD halt and force-process a meeting via UI affordance and CLI flag (`auricle process <id> --force`).

### Pipeline Orchestration & State

- **FR11 [MVP]:** auricle can execute the meeting pipeline in distinct, crash-isolated stages: capture → transcribe → diarize → attribute → summarize → persist → notify.
- **FR12 [MVP]:** Each pipeline stage can be invoked independently as an `auricle <stage> <id>` CLI subcommand, producing identical artifacts to in-app execution.
- **FR13 [MVP]:** The user can see a per-meeting state in the main window indicating which stage is in progress, awaiting user action, or complete (`Recording`, `Processing`, `Awaiting Attribution`, `Awaiting Verification`, `Verified`).
- **FR14 [MVP]:** The user can re-run a failed stage idempotently without corrupting artifacts from earlier stages.
- **FR15 [v1.1]:** The user can list all in-flight, silent, awaiting-attribution, awaiting-verification, and stale-pending meetings via `auricle pending`.
- **FR16 [v1.1]:** auricle can display a Dock badge count of stale-pending items (meetings awaiting verification beyond N days).

### Transcription & Diarization

- **FR17 [MVP]:** auricle can transcribe captured audio to text on-device using WhisperKit with the Whisper-large-v3-turbo model.
- **FR18 [MVP]:** auricle can perform speaker diarization on captured audio using WhisperKit's built-in diarization, producing speaker-segmented transcript output (`Speaker_1`, `Speaker_2`, …).
- **FR19 [MVP]:** auricle can transcribe English-language audio (other languages are explicitly out of scope).
- **FR20 [MVP]:** auricle can complete transcription on the user's local machine without any network round-trip.

### Attribution

- **FR21 [MVP]:** The user can review detected speakers in a native Attribution sheet attached to the main window (modal, not a separate window — per the single-workflow-window principle) after diarization completes, with the pipeline blocked on his input before summarization runs.
- **FR22 [MVP]:** The user can play a short representative audio snippet (5–10 seconds) for each detected speaker via an in-UI playback control.
- **FR23 [MVP]:** The user can assign a name to each detected speaker via an autocomplete input that prioritizes (1) calendar attendees of the current meeting (visually marked), (2) existing vault wikilink targets, (3) previously-labeled speakers, with frequency/recency tie-breakers.
- **FR24 [MVP]:** The user can mark himself as a specific speaker without typing — a "this is me" affordance.
- **FR25 [MVP]:** The user can publish a meeting without completing attribution via a "Publish anyway" action; the resulting note uses `Speaker_N` placeholder labels and is tagged `#auricle/needs-attribution` in frontmatter.
- **FR26 [MVP]:** The user can manually fix attribution in Obsidian after the fact (auricle never re-edits the note, so manual fixes are permanent and uncontested).
- **FR27 [v1.1]:** The user can complete attribution via CLI when the native UI is unavailable: `auricle attribute <id> --emit-snippets` writes WAV snippets to the cache directory; `auricle attribute <id> --speakers "1=Ben,2=Sara,..."` accepts a manual mapping and resumes the pipeline.
- **FR77 [MVP]:** When ≥2 meetings are simultaneously in `Awaiting Attribution`, auricle serializes the Attribution sheet — only one sheet is open at a time. The main window displays a banner counter ("3 meetings waiting for attribution") with a click target that opens the next queued sheet; completing, dismissing, or saving-for-later the active sheet causes the next queued meeting's sheet to rise. Sheet ordering is FIFO by capture-stop timestamp.

### Summarization

Summarization is the **primary AI consumer** of the corrected pipeline output: the attributed transcript (after diarization, optional AI diarization-review per §AI-Assisted Correction, and human attribution), the calendar-enriched attendee context, and the vault-glossary terms (FR55–FR57). FR28–FR32 below define what the summarizer produces and how it is grounded; the corrections that feed into it are governed by §AI-Assisted Correction.

- **FR28 [MVP]:** auricle can summarize an attributed transcript into a structured output containing: a one-paragraph summary, an array of action items, an array of decisions.
- **FR29 [MVP]:** Each action item and each decision in the structured output is grounded in the source transcript via a verifiable pointer — either character-range offsets returned by Anthropic's Citations API (the default Claude path) or a verbatim quote string (the local-LLM path FR33 v1.1+, and the automatic fallback path when Citations is unavailable). The rendered vault note displays the cited transcript text as a `> source quote` blockquote regardless of which mechanism produced the grounding.
- **FR30 [MVP]:** auricle can validate every grounding pointer against the source transcript: for Citations-based grounding, by confirming the cited character range exists within the canonical transcript representation that was submitted to the API; for substring-based grounding, by literal substring match against the same canonical transcript. Items failing validation are dropped before the note is written. The two validation paths produce identical normalized output (`{transcriptStart, transcriptEnd}`) so the renderer is grounding-method-agnostic.
- **FR31 [MVP]:** auricle can summarize via the Anthropic Claude API as the default summarization engine.
- **FR32 [MVP]:** auricle uses a single primary Claude call per meeting (chain-of-summarize is explicitly deferred to v2+). On Citations API errors, malformed responses, or empty citation arrays, the orchestrator may automatically dispatch a single fallback call using the substring-grounding strategy; total per-meeting cost remains bounded by NFR-C1 across all calls.
- **FR33 [v1.1+]:** auricle can summarize via a local LLM path (Ollama or MLX) as an alternative to Claude, selected by configuration.
- **FR34 [v1.1]:** auricle can detect long-context drift on transcripts ≥60 minutes (token count + summary content density) and flag suspiciously thin summaries for user attention.

### AI-Assisted Correction

AI-assisted correction is a **product category** at auricle, not a single feature, and is the architectural and product differentiator versus the user's pre-existing workflow (Pixel Recorder → manual Claude → Obsidian). The category has three siblings sharing one `AIReviewerStrategy` family (`Sources/AIReviewer/`):

| Sibling | Status | FR origin |
|---|---|---|
| **Jargon / vault-glossary correction** | Phase 1 (MVP), enabled | FR55–FR57 |
| **Diarization correction** | Phase 1 (MVP), flag default-off | FR73–FR75 |
| **Transcription correction** | Phase 3 (v1.1), declared / no MVP impl | FR76 |
| **Unified AI correction surface** | Phase 4 (v1.1+), future | not yet specified |

**Path C activation flow.** All architectural slots ship in MVP — strategy interfaces, cache artifacts (`diarization_suggestions.json` written; `transcription_suggestions.json` schema declared), the `reviewing_diarization` pipeline state, and `attribution.json` schema additions (`segment_overrides`, `segment_splits`). The diarization-review feature is gated on `diarization_review.enabled` (default `false`); when off, the stage passes through in <100ms with an empty stub artifact and no Claude call. After ~30-day MVP dogfood, the smoke-test protocol (see Open Resolutions) gates Phase 2 activation: flip the flag on, evaluate Haiku precision/recall against pre-committed criteria, ship as v1.1-stable when applied/suggestions ≥40% over 4 weeks AND false-positive rate <20%. Phase 3 (v1.1) implements `ClaudeTranscriptionReviewer` against the already-declared interfaces, gated on `transcription_review.enabled`. Phase 4 (v1.1+) optionally fuses all three into a single Claude call. Schema additions are additive; the `reviewing_diarization` no-op pattern generalizes to future stages — adding a sibling never breaks earlier readers (per Decision 1.3 cache-handoff contract).

- **FR73 [MVP]:** auricle ships an `AIReviewerStrategy` family with concrete `ClaudeDiarizationReviewer` (Haiku-default), declared `TranscriptionReviewerStrategy` (no impl), and `JargonCorrectionStrategy` wrapping the existing glossary path (FR55–FR57). The pipeline includes a `reviewing_diarization` stage between diarization and attribution; `attribution.json` exposes `segment_overrides` and `segment_splits` schema fields for AI-applied corrections.
- **FR74 [MVP]:** auricle reads a `diarization_review.enabled` configuration flag (default `false`). When `true`, `ClaudeDiarizationReviewer` runs on every meeting and writes per-segment speaker corrections plus proposed splits to `diarization_suggestions.json`. When `false`, the stage writes an empty stub artifact in <100ms with no Claude call. The flag is per-config (FR58); flipping it requires no rebuild.
- **FR75 [MVP]:** When diarization-review suggestions exist, the user can review them inline in the Attribution sheet via per-paragraph `🤖` chips that expand to show reasoning and Apply/Reject controls. Applied suggestions write to `attribution.json` `segment_overrides`/`segment_splits` and are reversible via SwiftUI `UndoManager` for the duration of the sheet, with a "Revert this split" affordance available across sheet reopens for previously-applied AI splits. The Attribution sheet renders a trust-calibration footer showing recent accept rate (e.g., "Reviewed 47 segments, flagged 4 · Accept rate: 8/11 this week").
- **FR76 [v1.1]:** auricle declares `TranscriptionReviewerStrategy` and a `transcription_suggestions.json` cache schema in MVP without implementation. v1.1 adds `ClaudeTranscriptionReviewer` (Haiku-default), surfacing word/phrase-level transcription corrections (homophones, proper nouns, technical terms grounded in the vault glossary) in the transcript pane behind a `transcription_review.enabled` flag (default `false`). The same dogfood-then-enable activation gate applies (smoke-test protocol mirroring diarization-review's).

### Persistence & Vault Integrity

- **FR35 [MVP]:** auricle can write each meeting as exactly one new markdown file to the user's Obsidian vault at a configurable path (default: `~/checkouts/SecondBrain/Meetings/`).
- **FR36 [MVP]:** auricle never opens an existing vault file for write; all persistence is `temp file → fsync → atomic rename`.
- **FR37 [MVP]:** auricle can render meeting notes with a stable structure: frontmatter block, one-paragraph summary, action items section (each with quote), decisions section (each with quote), collapsed transcript section.
- **FR38 [MVP]:** auricle can render speakers in summary text as Obsidian `[[wikilinks]]`, resolvable to existing or to-be-created people-notes in the vault.
- **FR39 [MVP]:** auricle can populate frontmatter with: meeting time, duration, attendees (as wikilinks), source audio path, calendar event ID (when available), tags array, schema version, retention policy, and per-stage timing telemetry.
- **FR40 [MVP]:** auricle can use a stable, predictable filename convention based on date and meeting title (e.g., `2026-04-28-tuesday-sync-with-ben.md`), avoiding collisions.
- **FR41 [MVP]:** auricle can record its own pipeline metadata in an `auricle:` block in the frontmatter without polluting the vault's tag namespace beyond `auricle/*` tags.

### Notification & Verification

- **FR42 [MVP]:** auricle can fire a macOS user notification when a meeting summary has been written to the vault, with the meeting title visible in the notification.
- **FR43 [MVP]:** The user can click the notification to open the resulting note in Obsidian via URL scheme.
- **FR44 [MVP]:** auricle can detect the notification click and use it as the verification trigger that arms the audio retention timer (the click is a meaningful event, not a passive open).

### Audio Retention & Lifecycle

- **FR45 [MVP]:** auricle can hold captured audio indefinitely until the user clicks the verification notification.
- **FR46 [MVP]:** auricle can begin a configurable grace timer (default 7 days) after the verification click, after which the captured audio is deleted from cache.
- **FR47 [MVP]:** auricle can re-prompt the user at 7 days post-verification (escalate at 14 days) to confirm or extend retention before deletion.
- **FR48 [MVP]:** The user can see per-meeting audio retention status (e.g., "Audio deletes in 5 days", "Audio kept (indefinite)", "Audio deleted") in the main window.
- **FR49 [v1.1]:** The user can override audio retention for a specific meeting (indefinite or custom window) via the main window UI and via `auricle keep <meeting-id>` CLI.
- **FR50 [v1.1]:** The user can configure per-meeting retention windows that override the default.

### Calendar Enrichment

- **FR51 [MVP]:** auricle can authenticate against Google Calendar via OAuth 2.0, storing tokens in the macOS Keychain.
- **FR52 [MVP]:** auricle can fetch the calendar event matching the time window of a captured meeting and inject title, attendees, and event metadata into the resulting note's frontmatter.
- **FR53 [MVP]:** auricle can display upcoming calendar meetings in a sidebar or surface in the main window, providing context for upcoming captures.
- **FR54 [MVP]:** auricle can degrade gracefully when calendar enrichment is unreachable (offline, API error, no matching event), publishing the note with a generic title and `#auricle/needs-calendar-enrichment` tag.

### Vault-Glossary Correction

- **FR55 [MVP]:** auricle can extract a glossary of terms from the user's Obsidian vault by enumerating wikilink targets (page names) across vault files.
- **FR56 [MVP]:** auricle can scope the glossary to terms relevant to the current meeting's attendees and topics, when sufficient context is available.
- **FR57 [MVP]:** auricle can inject the (scoped) glossary as context into the summarization prompt for term-correction during summary generation.

### Configuration & Permissions

- **FR58 [MVP]:** The user can configure: vault path, vault subdirectory for meeting notes, default audio retention grace window, summarization engine choice (Claude / local), Anthropic API key, Google OAuth account, log verbosity.
- **FR59 [MVP]:** auricle can persist configuration in `~/Library/Application Support/com.auricle.app/` as a structured file (TOML or JSON), separate from secrets which live in Keychain.
- **FR60 [MVP]:** auricle can detect missing required permissions (Screen Recording, Microphone, Notifications) on launch and surface a clear remediation path to the user.

### Operations & Failure Recovery

- **FR61 [MVP]:** Each pipeline stage can produce structured logs to the macOS unified logging system under subsystem `com.auricle.app`, with per-stage categories.
- **FR62 [MVP]:** auricle can survive a crash of any individual stage subprocess without losing artifacts from already-completed stages — the next pipeline run picks up from the last successful stage.
- **FR63 [MVP]:** auricle continues running after the main window is closed, allowing in-flight captures and pipelines to complete without user intervention.
- **FR64 [MVP]:** The user can quit the auricle app entirely via standard Cmd-Q, which gracefully stops any active capture and persists in-flight state.
- **FR65 [v1.1]:** auricle can self-update via Sparkle, fetching EdDSA-signed appcast updates from the project's release feed with user confirmation. The downloaded `.app` bundle is signed with the self-managed code-signing certificate (per NFR-S2) and is accepted by Gatekeeper on each user Mac via the existing `spctl` trust policy established at first install.
- **FR66 [MVP]:** auricle can locally store per-meeting telemetry (time-to-notification, quote-validation drops, attribution path, summarization cost, retention status) in a SQLite database at `~/Library/Application Support/com.auricle.app/`, accessible to the user but not transmitted off-device.

### Future / Vision (v2+)

The following are not in MVP or v1.1 scope but are listed for capability-contract completeness so they are not "discovered" later:

- **FR67 [v2+]:** auricle can automatically detect when a meeting begins by observing running meeting-app processes (Zoom, Meet, Teams, etc.) and prompt or auto-start capture.
- **FR68 [v2+]:** auricle can persist speaker voice-print embeddings (via pyannote 3.1 sidecar) and match unlabeled speakers across meetings to the same identity.
- **FR69 [v2+]:** auricle can apply meeting-type-specific summarization templates (1:1, standup, external pitch, interview, brainstorm) selected automatically from calendar metadata or manually by the user.
- **FR70 [v2+]:** auricle can produce a "series-overview" auto-aggregated note for recurring meetings, alongside per-meeting notes.
- **FR71 [v2+]:** auricle can use chain-of-summarize fallback for very long transcripts (≥90 min) when single-call drift is detected.
- **FR72 [v2+]:** auricle can use Apple SpeechAnalyzer as a fallback ASR path on macOS 26+.

**Capability contract acknowledgment:** This list is binding. Any feature not enumerated here will not be built. Additions require explicit PRD revision.

## Non-Functional Requirements

NFRs document **how well** auricle must perform — quality attributes, not capabilities. Categories below are filtered to those that materially affect this product. Categories explicitly skipped: **Scalability** (single user, single machine; "scale" doesn't apply in the conventional sense — see Reliability for related durability concerns), **Internationalization** (English-only is a locked decision), **Multi-tenancy / RBAC** (single-user product). Each NFR is testable.

### Performance

Performance is a primary user-facing claim — the product premise depends on the pipeline being fast enough to feel reactive after a meeting ends.

- **NFR-P1 [MVP]:** End-to-end pipeline (capture stop → notification fired) completes in **P50 ≤ 2 minutes, P95 ≤ 5 minutes** for a 30-minute single-track meeting on M5 Max hardware (Apple Silicon, ANE-enabled).
- **NFR-P2 [MVP]:** End-to-end pipeline completes in **P95 ≤ 10 minutes** for a 60-minute meeting on the same reference hardware.
- **NFR-P3 [MVP]:** Transcription stage (audio → raw transcript) completes in **≤ 30 seconds** for a 30-minute audio file using WhisperKit with Whisper-large-v3-turbo on ANE.
- **NFR-P4 [MVP]:** Diarization stage completes in **≤ 30 seconds** for a 30-minute audio file (run as part of or immediately after transcription, sharing model state).
- **NFR-P5 [MVP]:** Summarization stage (Claude path) completes in **P50 ≤ 60 seconds, P95 ≤ 180 seconds** for a 30-minute transcript at ≤4k tokens.
- **NFR-P6 [MVP]:** Attribution UI loads detected speakers and is interactive within **≤ 2 seconds** of the diarization stage completing.
- **NFR-P7 [MVP]:** Audio snippet playback in the attribution UI starts within **≤ 200 ms** of click (perceptually instant).
- **NFR-P8 [MVP]:** Vault write (atomic temp + rename) completes in **≤ 500 ms** for a meeting note up to 50 KB markdown.
- **NFR-P9 [MVP]:** auricle's idle memory footprint when no recording or processing is active is **≤ 200 MB**.
- **NFR-P10 [MVP]:** auricle's peak memory footprint during transcription on a 60-minute audio file is **≤ 4 GB** (driven by WhisperKit model load + audio buffers).
- **NFR-P11 [MVP]:** auricle's idle CPU usage when no recording or processing is active is **≤ 1% CPU on Apple Silicon** (baseline appkit overhead, no polling loops).
- **NFR-P12 [MVP]:** Cold start of the auricle app (Dock click → main window interactive) completes in **≤ 1.5 seconds** on M-series Mac with warm filesystem cache.
- **NFR-P13 [MVP]:** During active capture, auricle adds no perceivable system audio latency to whatever meeting application the user is in (passive loopback only — does not insert in the audio chain).

### Reliability & Data Integrity

The vault is the user's long-lived working memory. Reliability of vault writes and audio safety are non-negotiable.

- **NFR-R1 [MVP]:** Vault writes are atomic: temp file → fsync(2) → rename(2). If the process is killed at any point, the vault is left in a consistent state (either the new file exists complete, or it does not exist at all). **Zero partial-write events** are tolerated across MVP dogfood.
- **NFR-R2 [MVP]:** auricle never opens an existing vault file for write. Any apparent need to "update" a meeting note is satisfied by the user editing in Obsidian; auricle treats the vault as append-only-from-its-side.
- **NFR-R3 [MVP]:** Captured audio is held until the user clicks the verification notification. **Zero unverified-audio-deletion events** are tolerated. Default behavior on any retention-system error is to retain audio, not delete.
- **NFR-R4 [MVP]:** Each pipeline stage is crash-isolated as a separate `auricle <stage>` subprocess invocation. A crash in any single stage does not corrupt artifacts from earlier completed stages.
- **NFR-R5 [MVP]:** Each pipeline stage is idempotent — re-running it produces the same output deterministically (modulo the LLM call, which is non-deterministic by nature; same prompt + same model version is "deterministic enough" for re-run semantics).
- **NFR-R6 [MVP]:** auricle persists in-flight pipeline state (which stage is current, which artifacts exist on disk) in a SQLite database, and recovers cleanly from app crashes by re-reading state on next launch.
- **NFR-R7 [MVP]:** Quote-grounding validation is a hard gate: 100% of action items and decisions in published notes have a `source_transcript_quote` that survives a literal substring match against the transcript. Items failing the check are dropped silently before persistence (logged at info level for inspection).
- **NFR-R8 [MVP]:** auricle handles the macOS Notification permission being revoked at any time without crashing — pipeline still completes, notification simply fails to deliver, meeting moves to "awaiting verification" state visible in the main window.
- **NFR-R9 [MVP]:** auricle handles the Anthropic API being unreachable (offline, rate limit, server error) by retrying with exponential backoff up to a configurable timeout (default 5 minutes); on persistent failure, the meeting is marked `summarization_failed` in pending state, not lost.
- **NFR-R10 [MVP]:** auricle's local SQLite state file is checkpointed on every state transition; corruption recovery is by replay from on-disk artifacts (transcripts, summaries, notes) rather than from backup.

### Security

Security model is shaped by the single-user, single-machine, local-first architecture. The threats are different from a SaaS product.

- **NFR-S1 [MVP]:** All secrets (Anthropic API key, Google OAuth refresh token) are stored in the macOS Keychain (`kSecClassGenericPassword`), never in plaintext on disk, never in environment variables, never in config files.
- **NFR-S2 [MVP]:** auricle binaries are signed with a self-managed code-signing certificate (personal CA + per-tool leaf cert) and trusted on each user Mac via a one-time `spctl` assessment-policy registration. Hardened runtime is enabled. Notarization is not used (Apple notarization requires a paid Developer ID, intentionally avoided per NFR-C4); the `spctl` trust policy provides equivalent local Gatekeeper acceptance for the user's personally-owned Macs. Bundle identifier (`com.auricle.app`) and signing identity remain stable across rebuilds and Sparkle updates so that TCC permission grants persist. See architecture's Distribution Model for the full mechanism and the documented Apple Developer ID alternative.
- **NFR-S3 [MVP]:** Cached audio files (`~/Library/Caches/com.auricle.app/<meeting-id>/audio.wav`) are written with 0600 permissions (user-only read/write).
- **NFR-S4 [MVP]:** Vault notes inherit standard vault file permissions (no special write modes); auricle does not chmod existing files.
- **NFR-S5 [MVP]:** Anthropic API requests are made over TLS 1.2+ with certificate validation; no insecure-fallback path exists.
- **NFR-S6 [MVP]:** Google OAuth uses the device-code flow (or installed-application flow) with PKCE; refresh tokens are scoped to the minimum required Calendar API surface (read-only access to user's primary calendar).
- **NFR-S7 [MVP]:** auricle does not log secrets or API responses containing secrets to the unified logging system. Log redaction is enforced at the structured-logging layer.
- **NFR-S8 [MVP]:** auricle does not transmit transcripts, summaries, or audio anywhere except (a) the Anthropic API for the summarization stage when configured, and (b) the user's local vault filesystem. **No telemetry endpoint exists in MVP.**
- **NFR-S9 [v1.1]:** Sparkle update verification uses EdDSA signature validation; updates with invalid signatures are rejected.

### Privacy

Privacy is distinct from security — it's about the user's commitments to themselves and to meeting participants whose voices are being captured.

- **NFR-Pr1 [MVP]:** No audio, transcript, summary, or vault content is transmitted off the user's machine except as explicitly required by a configured stage (Claude API for summarization, Google Calendar API for enrichment). All other stages are strictly local.
- **NFR-Pr2 [MVP]:** No anonymous usage telemetry, error reporting, or analytics is transmitted to any third party (auricle developer, Anthropic, Google, Apple beyond standard macOS crash reporting). Local SQLite telemetry is for the user's own dashboards only.
- **NFR-Pr3 [MVP]:** Captured audio, transcripts, and intermediate artifacts are scoped to user-owned directories (`~/Library/Caches/com.auricle.app/`, vault path) and never written to system-wide locations.
- **NFR-Pr4 [MVP]:** When the Claude summarization path is used, the API call payload contains the transcript text and the vault glossary terms only. Audio is **never** transmitted; speaker labels in the transcript are first-name-only by convention; calendar email addresses are stripped before payload assembly.
- **NFR-Pr5 [MVP]:** Anthropic's data-usage policy applies to the summarization API call. Users are responsible for understanding it; auricle documents the data flow clearly in the README and Settings UI to support informed consent.
- **NFR-Pr6 [MVP]:** Audio retention defaults are conservative (held until verified, then 7-day grace). The user can shorten or extend retention, but the default is biased toward "delete sooner" rather than "keep forever."
- **NFR-Pr7 [MVP]:** auricle gives no indication to other meeting participants that capture is occurring (this is a design feature: capture is OS-level, invisible). The user is responsible for legal/ethical recording-consent obligations in their jurisdiction; auricle is single-user tooling and does not enforce consent behavior.

### Integration & Compatibility

- **NFR-I1 [MVP]:** auricle requires macOS 14 (Sonoma) or later. macOS 15+ is the active development target.
- **NFR-I2 [MVP]:** auricle requires Apple Silicon (arm64). Intel Mac support is not provided.
- **NFR-I3 [MVP]:** auricle is compatible with the current major release of Obsidian (1.x) via the `obsidian://open` URL scheme. No Obsidian plugin is required, and no specific Obsidian config is assumed beyond a writable vault.
- **NFR-I4 [MVP]:** auricle's frontmatter schema is documented and versioned (`auricle.schema_version` field in every note). Breaking changes to the schema increment the major version and ship with a documented migration path for existing notes.
- **NFR-I5 [MVP]:** auricle integrates with Google Calendar API v3 read-only. Calendar API failures (rate limits, auth expiry) degrade gracefully — meeting captures still complete with `#auricle/needs-calendar-enrichment` tag.
- **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and extended-thinking effort budget are both configurable; default at MVP is `claude-opus-4-7` with extended thinking enabled at a moderate default effort budget. Both knobs are tunable via config (per FR58) without code changes — users may dial effort down to reduce cost / latency, dial up for higher-quality summarization on important meetings, or switch to a smaller model variant entirely (e.g., latest Claude Sonnet or Haiku) for cost-sensitive workloads. Updating the default model or effort budget in a release is a release-note bump, not a frontmatter-schema change. The exact moderate-default effort budget value is empirically tuned during the summarization spike (see Open Resolutions).
- **NFR-I7 [MVP]:** auricle's CLI subcommands have stable, documented argument signatures. Renaming or removing a CLI flag is a breaking change requiring a major version bump.
- **NFR-I8 [v1.1+]:** auricle's local LLM path supports Ollama (HTTP API) and/or MLX (in-process). Specific runtime is configurable; switching is a config-only change, not a reinstall.

### Accessibility

Single-user product, but the user is the user — accessibility matters for him personally and for any future open-source contributors.

- **NFR-A1 [MVP]:** Main window UI supports VoiceOver navigation. All interactive controls have descriptive accessibility labels.
- **NFR-A2 [MVP]:** All interactive controls in the attribution UI are keyboard-navigable. Tab order matches visual reading order. Speaker snippets can be played via keyboard (e.g., Spacebar after focus).
- **NFR-A3 [MVP]:** Color is never the sole conveyor of meaning. Recording-state indicator uses both color (red) and shape/animation (pulsing dot). Calendar-attendee priority in autocomplete is indicated by visible label, not just color.
- **NFR-A4 [MVP]:** Text in the main window respects the system text-size setting (Dynamic Type analogue on macOS where applicable).
- **NFR-A5 [MVP]:** auricle respects the system Reduce Motion setting; animations (recording-pulse, transitions) are simplified or disabled when this is on.
- **NFR-A6 [MVP]:** auricle works with the system Dark Mode and Light Mode settings without user configuration.

### Maintainability & Operability

The project is built and maintained by a single engineer. Maintainability NFRs are explicit because they're load-bearing for the project's long-term viability.

- **NFR-M1 [MVP]:** auricle is implemented in Swift / SwiftUI / AppKit only — no Python sidecars, no Node bridges, no Electron, no JavaScript runtimes, in MVP. (The pyannote sidecar in v2+ is a deliberate exception with explicit motivation.)
- **NFR-M2 [MVP]:** Pipeline stages are isolated as separate `auricle <stage>` subprocess invocations to support crash isolation, terminal-debugging, and re-running individual stages without re-running the rest of the pipeline.
- **NFR-M3 [MVP]:** Each pipeline stage produces structured logs to the unified logging system under subsystem `com.auricle.app` with a category matching the stage name (`com.auricle.app/capture`, `/transcribe`, etc.). Logs are inspectable via `log show --predicate 'subsystem == "com.auricle.app"'`.
- **NFR-M4 [MVP]:** auricle has unit tests for: schema validation, frontmatter rendering, quote-grounding grep validation, vault-glossary extraction, filename collision avoidance, retention timer arithmetic.
- **NFR-M5 [MVP]:** auricle has at least one end-to-end smoke test using a checked-in reference WAV file, a stub summarization (no real Anthropic call), and a vault-write to a temp directory. CI-runnable.
- **NFR-M6 [MVP]:** Configuration changes (vault path, retention, summarization engine) take effect on next pipeline invocation, without requiring app restart.
- **NFR-M7 [MVP]:** auricle release builds are reproducible: same git SHA + same toolchain → identical notarized `.app`. Release script is checked in.
- **NFR-M8 [MVP]:** All non-trivial design decisions in the codebase are anchored to specific PRD or brainstorm sections via brief code comments where the *why* is non-obvious — not as a documentation discipline, but as a navigational one for the maintainer (one person, intermittent attention).

### Cost

For a personal tool, ongoing cost is a real constraint and worth pinning.

- **NFR-C1 [MVP]:** Per-meeting variable cost (Claude API spend across all stages — summarization plus optional AI correction) ceilings by configuration tier: **≤ \$0.50** default (jargon correction inline in the Opus summarize call, no diarization review), **≤ \$0.60** when `diarization_review.enabled = true` (adds a Haiku review call before summarize), **targeted ≤ \$0.70** in v1.x when `transcription_review.enabled = true` is also on (adds a second Haiku review call), **\$0** on the local-LLM path (FR33). All ceilings assume a 30-minute meeting with attendee context and vault glossary, the default model selection (`claude-opus-4-7` for summarize with moderate extended-thinking effort budget per NFR-I6, Haiku-default for correction reviewers), and prompt caching enabled for the system prompt and stable glossary terms. The default-tier ceiling reflects Opus-tier reasoning cost (intentionally chosen for higher-quality grounding per NFR-I6) and is empirically validated in the summarization spike (see Open Resolutions). Cost-control knobs available to the user via configuration: (a) leave `diarization_review.enabled = false` (the MVP default) and stay at the \$0.50 default-tier ceiling; (b) reduce extended-thinking effort budget toward zero (lowest effort approaches a no-thinking baseline of approximately ~\$0.15/meeting); (c) switch summarization model to a smaller variant (Sonnet, Haiku) at the cost-vs-quality trade-off; (d) v1.1+ switch to local-LLM path (FR33) for \$0/meeting.
- **NFR-C2 [v1.1]:** Per-meeting variable cost reduces to ≤ **\$0.05** for a 30-minute meeting via prompt optimization (caching system instructions, scoping glossary tighter).
- **NFR-C3 [v1.1+]:** Per-meeting cost reduces to **\$0** when local-LLM summarization path is configured.
- **NFR-C4 [MVP]:** Total fixed cost: \$0. Distribution uses a self-managed code-signing certificate (personal CA + per-tool leaf cert), trusted on each user Mac via `spctl` assessment policy — no Apple Developer Program subscription required. Apple Developer Program (\$99/year) is documented as an optional alternative if pre-built binaries ever need to be distributed to other people without per-recipient trust setup. No subscription dependencies, no SaaS components. See architecture's Distribution Model for the trust-policy mechanism and migration path.

## Open Resolutions (Verify Before Implementing)

Items that the brainstorming session flagged for empirical resolution during the build phase rather than committing in the PRD. These are not blockers — each has an in-scope path forward — but they need to be settled with real-world data before the corresponding code locks in.

### Verify-before-implementing flags

- **Parakeet-TDT current MLX maturity.** Alternate ASR path if WhisperKit's quality is insufficient. Resolution: spike Parakeet-TDT on 2–3 captured meetings; compare WER and latency against WhisperKit; pick winner. Action: build-time spike before the transcription stage locks.
- **WhisperKit diarization current quality + whether it exposes embeddings.** Diarization quality directly affects the attribution UX. If diarization is poor, the UI's snippet-playback affordance compensates partially, but persistent under-segmentation hurts. Embeddings exposure matters for v2+ cross-meeting voice-print matching. Resolution: empirical test on 5+ real captured meetings during early MVP build.
- **Apple SpeechAnalyzer evaluation quality (fallback only; macOS 26+).** Tertiary fallback ASR. Resolution: not needed until macOS 26 is the development target and only if both WhisperKit and Parakeet prove inadequate.
- **Hidden user journeys surfaced during architecture work — to be formalized in PRD revision before MVP build.** The original PRD names 5 user journeys (happy path, attribution friction, silent meeting, power-user CLI recovery, retention housekeeping); the architecture roundtable surfaced three additional journeys that are real but uncovered:
  - **J0 — First-launch / permission gauntlet.** The TCC dialog dance (Screen Recording, Microphone, Notifications) on Day 1 of a fresh Mac install. Distinct from J1 happy path because permissions don't exist yet. Architecture handles via `auricle doctor` conversational onboarding (Decision 4.4) and Info.plist usage descriptions in user voice; should be documented as a discrete journey for completeness.
  - **J6 — Anthropic API credits exhausted mid-summarize.** Permanent-from-app's-view but user-actionable-in-reality (user tops up, then resumes). Architecture handles via `summarization_failed` transient state + `auricle run <id>` resume; PRD should name this journey explicitly so the resume mechanism has a documented user-facing narrative.
  - **J8 — macOS sleep-wake mid-capture.** The laptop sleeps during a long meeting; ScreenCaptureKit may produce stream interruptions that the existing `capture` retry policy (3 fails in 30s threshold) might misclassify as permanent failure. Resolution: empirical test during MVP build to confirm whether sleep events trigger the retry threshold; if yes, add sleep-aware classification to capture's failure handling.
  - Resolution: PRD revision pass before the implementation-readiness check; document each as a journey with the same structure as J1–J5.

- **Citations vs substring grounding — RESOLVED architecturally; smoke-test deferred to summarize-stage build story.** Originally framed as a 1-evening spike before locking the summarize-stage architecture. Resolved through a four-agent architecture roundtable to: commit the architecture to a dual-strategy `GroundingValidator` (Citations primary on `claude-opus-4-7`; substring fallback for the v1.1+ local-LLM path under FR33 AND for automatic recovery on Citations API failures), with the choice of default validator confirmed by a smoke-test inside the summarize-stage implementation story rather than as a prerequisite to architecture. Citations API confirmed supported on `claude-opus-4-7`. Architectural commitment is locked in step-04 Group 3; the smoke-test protocol is documented in PRD §Open Resolutions (this section, item below). FR29 / FR30 / FR32 amended to reflect the dual-strategy approach.

- **Summarize-stage smoke-test protocol (Story N hour 1; runs before dogfood, not before architecture).** The first hour of the summarize-stage implementation story exercises both grounding strategies on a fixed corpus and either confirms the Citations default or flips to substring. Required inputs: ≥5 of the user's existing meeting recordings, transcribed via WhisperKit, including ≥1 1:1 (≤3 attendees) and ≥1 multi-party (≥4 attendees). For each transcript, run `ClaudeCitationsSummarizer` and `ClaudeSubstringSummarizer` in parallel through the same prompt skeleton (per shared `SummarizationPromptBuilder`). Score each output by: (a) drop rate (items where grounding validation failed), (b) recall against the user's memory of the meeting, (c) precision (false-keeps), (d) cost per call including extended-thinking output tokens, (e) qualitative "did the grounded quote make sense" assessment. **Default flips to substring if substring catches anything Citations missed in the smoke-test set** (Mary's amendment: trust asymmetry — recovery cost from a single missed commitment in dogfood >> prevention cost). If Citations wins, lock as default and proceed to dogfood with telemetry tracking `grounding_method` per meeting. Regardless of outcome, both strategy implementations ship at MVP (substring is required for FR33's v1.1+ local-LLM path).

- **Diarization-review smoke-test protocol (Phase 2 activation gate; runs after ~30-day MVP dogfood, not before MVP gate).** All architectural slots for diarization review ship in MVP per FR73–FR75; the feature is gated on `diarization_review.enabled = false` by default. After roughly 30 days of MVP dogfood, flip the flag on for a smoke-test window and evaluate `ClaudeDiarizationReviewer` (Haiku-default) on real captured meetings. Required inputs: ≥5 of the user's existing meeting recordings, including ≥1 1:1 (≤3 attendees) and ≥2 multi-party (≥4 attendees). For each, capture per-segment suggestion count, applied count, rejected count, and the user's qualitative assessment of false positives (suggestions that proposed a wrong split or wrong speaker reassignment). **Phase 2 activation criteria (both must hold over a 4-week window):** (a) `applied_count / suggestions_count ≥ 40%` (suggestions are useful enough to apply), AND (b) false-positive rate `< 20%` (suggestions don't waste enough attention to undermine trust). If both criteria hold, declare diarization-review v1.0-stable, ship `diarization_review.enabled = true` as the new default in v1.1. If either fails, iterate on prompt and thresholds with pre-committed kill criteria from Mary's Step 10 round-2 amendment; if iteration also fails after one additional 4-week window, retire the feature flag and revert to architectural-slots-only. Telemetry columns `diarization_suggestions_count`, `_applied_count`, `_rejected_count`, `_cost_usd`, `_model` (per Decision 4.5) are the primary measurement surface; trust-calibration footer (FR75) surfaces accept-rate to the user during the test window. The same protocol template applies to transcription-review activation in v1.1 (FR76).

- **Trust calibration requirement (J1.5 — surfaced by architecture roundtable).** PRD's J1 happy path success criterion is "the user defaults to auricle's notes by month 2." This requires the user to know *how often* the grounding validator is right, not just that it's right on average. Implications: (1) `grounding_method` telemetry per meeting is load-bearing for J1, not nice-to-have; (2) per-meeting grounding details (which transcript spans, which validator, drop count) must be inspectable on demand via `auricle status <id>` and `auricle logs <id>` (v1.1) — the user building trust = the user being able to *audit* without ceremony; (3) DP2 (no confidence flags in vault frontmatter) is preserved by surfacing audit data via the CLI inspection surface, not in the vault note. The architecture's Decision 4.5 telemetry collection already captures `grounding_method`; the inspection surface is documented in step-04 Group 3 (Summarization Contracts). Resolution: implement during summarize-stage build; verify before MVP gate.

### Empirical decisions deferred to build phase

- **Summarization engine: Claude vs. local LLM.** Resolution mechanism: benchmark both on 10–20 captured real meetings during MVP build, scoring on (a) quote-grounding pass-rate, (b) action-item recall versus a manually-extracted ground truth, (c) cost, (d) latency. Pick winner. Local LLM may jump to v1.1 default if it wins; otherwise it stays in v2+ as a cost-elimination escape hatch.
- **Vault note shape detail.** Light community research (Building a Second Brain practitioners, Obsidian power-users, mind-mapping community) informs the frontmatter contract before it locks. Specific open questions: filename convention details (full meeting title vs. truncated; date prefix format), location convention (`Meetings/` vs. `Inbox/Meetings/`), how to express attendees in frontmatter (one wikilink per line vs. comma-separated array vs. YAML list of wikilinks). Resolution: 30 minutes of community-pattern research before writing the persistence stage.
- **Long-context drift threshold for summarization.** Empirical: capture 3–5 meetings of 60+ minutes during MVP dogfood; measure summary content density; pick a numeric threshold for v1.1's drift-detection guard. Until measured, no threshold exists and no flag fires.

### Decisions explicitly made in the PRD that may need re-resolution if assumptions break

- **macOS 14 floor.** Could be raised to macOS 15 if a needed ScreenCaptureKit or notification API only ships in 15.
- **English-only.** Locked decision; multi-language support would require model-bundle changes and prompt-localization work; not in any scope tier.
- **Default Claude model and extended-thinking effort budget.** Default at MVP is `claude-opus-4-7` with extended thinking enabled at a moderate effort budget (per NFR-I6). The exact moderate-default budget value is empirically tuned during the summarization spike (see "Anthropic Citations API vs. free-form quote + grep validation" in Verify-before-implementing flags), measured against drop rate, recall, latency, and per-meeting cost. New Opus / Sonnet / Haiku releases should be evaluated for the cost/quality trade-off before becoming the new default; the model identifier and effort budget are configurable per-user (FR58, NFR-I6) so individual tuning does not require a release.
- **Default audio retention grace.** 7 days post-verification. Could be tuned based on actual usage patterns observed in MVP dogfood (e.g., if the user routinely revisits notes at week-3, the default grace might extend to 14 days).
