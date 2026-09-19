# Epic 4 Context: Pipeline Validation Milestone (CLI End-to-End)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Given a meeting audio file already on disk, the maintainer runs `auricle run <id> --publish-anyway` (or batch attribution via `--speakers "1=Ben,..."`) and gets a complete Obsidian note: on-device WhisperKit transcription and diarization, an optional AI diarization-review stage, CLI attribution, then Epic 3's summarize and Epic 2's persist. This is a gate, not a ship. It exists to validate, on real audio and before any GUI investment, that Claude summarization holds up on real transcripts, that diarization quality is good enough for attribution, that the AI-correction wedge thesis is measurable, and that the whole pipeline composes. It also lays every architectural slot the AI-correction roadmap needs so later phases are config flips, not refactors.

## Stories

- Story 4.1: WhisperKit Transcribe Stage
- Story 4.2: Diarize Stage + Snippet Extraction
- Story 4.3: ReviewDiarization Stage + State Machine Entry
- Story 4.4: AIReviewerInterface Protocol Family + Null TranscriptionReviewerStrategy
- Story 4.5: ClaudeDiarizationReviewer Concrete Impl Behind Flag
- Story 4.6: AttributionViewModel in Core/ + Attribution Batch CLI
- Story 4.7: `auricle run` Verb Skeleton + `__internal-stage` Worker Dispatch
- Story 4.8: Basic Notification Stub + Obsidian URL Open
- Story 4.9: Exit-Criteria Smoke Test

## Requirements & Constraints

- Exit gate: against at least five of the maintainer's own meeting recordings, `auricle run` exits 0, writes a schema-valid vault note, and renders every action item and decision with a `> source quote` blockquote that survives literal substring match. At least 80% of expected items must survive grounding (adjustable to the Epic 3 baseline). `auricle status` must show `verified_at: null` afterwards: verification is a human act, never automatic on `auricle run`.
- Epic 3's comparison and eval fixtures are public meetings and film scenes, not the maintainer's recordings. Validating the wedge on his own audio is deferred to this epic. Fixture updates need a stated rationale in the PR, not silent regeneration.
- Cost: at most $0.50 per 30-minute meeting on the default tier, at most $0.60 with diarization review on. The ceiling is per meeting, enforced by recording and warning (`cost_ceiling_exceeded`) against auricle's own rate table, not by a hard stop. The exit test asserts it in aggregate over the fixtures.
- Performance and privacy: transcribe and diarize each finish in 30s or less for 30 minutes of audio. Peak memory is 4 GB or less on 60 minutes. Transcription is fully on-device with no network round-trip, and English-only with no language detection.
- Cross-meeting voice-print matching stays v2+ whichever diarization engine wins. The concrete transcription-review impl is not claimed here (Epic 10 owns it); Epic 4 ships only its protocol and schema.
- Diarization review is default-off in MVP. Off, the stage short-circuits in under 100ms with an empty stub artifact and telemetry `{model_id: "flag_off", cost_usd: 0, suggestions_count: 0, review_skipped: true}`. The flag flips in v1.1 only after a smoke test on at least five real meetings (applied/suggested at least 40% over four weeks, false-positive rate under 20%). A suggestion count of zero is "insufficient signal", never a pass.
- Failure semantics: transcribe gets one retry after a fresh subprocess restart, then becomes permanent `transcription_failed`, and `--force` is the override. Reviewer timeout (90s fixed) or an Anthropic failure is a benign passthrough: write an empty stub, go to `awaiting_attribution`, log `error_class='ai_reviewer_timeout'`. It is never a `*_failed` state.
- `--publish-anyway` publishes with `Speaker_N` placeholder names and the needs-attribution tag. If summarize then fails, the meeting becomes `published_partial` carrying both needs-attribution and needs-summary tags. SIGINT cancels an in-flight retry, marks `summarization_failed`, and exits 130.

## Technical Decisions

- **Diarization engine is undecided, and an empirical test decides it before any concrete diarizer is written.** WhisperKit's built-in diarization is compared against SpeakerKit (same package, pyannote-based, reported as native Swift, not yet verified) on at least five real meetings. Default to the built-in if the test does not clearly favor SpeakerKit, or if SpeakerKit needs non-Swift runtime support. If SpeakerKit wins, confirm it shares the transcribe subprocess's model-load lifecycle before locking that acceptance criterion. A second engine is just another Swift target behind `DiarizerStrategy`, so the story's notes should say what a later swap costs. Record the outcome; do not assume the old "no pyannote in MVP" position.
- **Subprocess boundaries.** Transcribe and diarize run in one subprocess (they share WhisperKit model state; one `transcribing` state). `review-diarization` is its own subprocess, spawned only after that one terminates, so the ~2-4 GB working set is freed before any network call. Dispatch is the hidden `auricle-cli __internal-stage <stage> <id> --worker-protocol-version 1`.
- **Cache immutability.** `transcript.json` and `diarization.json` are immutable after write. AI proposals live in `diarization_suggestions.json` (written once). User corrections live only in `attribution.json` (`speakers`, `segment_overrides`, `segment_splits`, additive schema). A pure renderer composes `(diarization, overrides, splits) → RenderedTranscript`, and a build-time test fails if any reviewer path opens an immutable artifact for write. All writes go through `CacheArtifactWriter`/`AtomicWriter`, 0600, with `schema_version`.
- **Transcript contract (Story 4.1 owns it).** NFC, LF, `<Speaker_N>: ` prefix on each utterance. Each utterance's range includes its own prefix, and the summarize stage strips exactly one prefix when rendering under a speaker label, so labels do not print twice.
- **`AttributionViewModel` lives in `Core/`**, not the GUI target. CLI batch attribution and Epic 7's sheet consume the same `@Observable` type, so the type system is the parity contract. It owns autocomplete order (calendar, then vault wikilinks, then previously labeled), the "this is me" pre-select (longest cumulative speaking), recurring-meeting auto-prefill (three or more prior labelings), and a 500ms debounced atomic write.
- **AI-invocation scope.** The ruling that calls the Anthropic Messages API directly is scoped to the summarize stage only and does not bind reviewer stages. Story 4.5 as written reuses the shared `AnthropicHTTPClient` and `KeychainAPIKey`. A managed-session or vault-reading approach for correction-family stages was opened, not decided, and is not part of this epic. Any reviewer call must pin its model explicitly (`claude-haiku-4-5` default, configurable via `diarization_review.model`).
- **Reviewer call shape.** One-shot, not streaming. System prompt and review instructions carry `cache_control`. The per-meeting transcript plus diarization is never cached. Each suggestion has a stable `suggestionId` so per-suggestion apply tracking survives sheet reopens. Target cost is about $0.02-0.05 per 30-minute meeting.
- **Flag-default-off is for unproven AI features.** It fits diarization review. Restrictions on the maintainer's own editing surfaces need a much higher bar, and the record is preferred over a switch.
- **Reviewer telemetry.** The subprocess writes `diarization_suggestions_count`, `diarization_review_cost_usd` and `diarization_review_model` to `telemetry`, plus a `stage_events` row via `StageEventLogger`. A future local model reports `cost_usd: 0` and `model_id: "local:<name>"`, so no schema migration is needed.
- **AIReviewerStrategy family.** The base protocol has associated `Input`/`Output: Suggestion`, and `review` returns a result carrying suggestions, cost and `reviewedSegmentCount`. The three siblings are diarization, transcription (schema only, never written in MVP, `schemaVersion: 1`) and jargon correction. The jargon-correction protocol and glossary injector already exist from Epic 3, so Story 4.4 conforms them by adapter, with no behavior change.
- **Config.** User-editable settings (`diarization_review.enabled`, `diarization_review.model`, `attribution.snippet_duration_seconds`, default 8s) live in `~/.auricle/config.toml` via `Core/Config`. SQLite stays in Application Support and per-meeting artifacts in Caches.

## UX & Interaction Patterns

- No GUI ships here. This epic precomputes what Epic 7's Attribution sheet consumes: per-speaker snippet WAVs (5-10s), Float32 `.envelope` files (~200 samples) for waveform pre-render, and per-segment voice-profile metadata for the variance warning.
- `reviewedSegmentCount` feeds the trust-calibration footer ("Reviewed N segments, flagged M").
- The notification body reads "auricle: meeting ready — <title>", and its click opens the note through an `obsidian://` URL built from the stored note path. Notification permission revoked means log a warning and continue.
- The exit test prints a per-fixture line (note path, grounding method, kept vs expected items, drop count, cost) and an aggregate pass line.

## Cross-Story Dependencies

- Sequence is 4.1 through 4.9. 4.8 cannot land before 4.1-4.7, and 4.9 is the explicit gate.
- 4.2 shares 4.1's subprocess, so the engine decision and its lifecycle check gate both stories.
- 4.3's flag-on path calls 4.5's reviewer (mocked in 4.3's tests). 4.5 needs 4.4's protocols and Epic 3's HTTP client and key handling.
- 4.6 reads 4.2's `diarization.json` and 4.3/4.5's suggestions file. 4.7 wires 4.1-4.6 into one verb, and its `--publish-anyway` behavior depends on 4.6.
- 4.9 runs Epic 3's summarize (substring is the shipped default; the grounding-method field in its output should reflect that) and Epic 2's persist. It uses stubbed Anthropic responses in CI, with a separate manual live script.
- The wedge measurement reads 0 without a vault path reaching dispatched workers. That is now built, but the Google Calendar source has no sign-in until Epic 9, so enrichment stays degraded during this epic's runs. `AuricleApp` has no summarize path yet, so this epic is CLI-only.
- 4.8 is a deliberate stub. Epic 8 owns verification, retention-timer arming and manual keep. Epic 7 consumes `AttributionViewModel` and the snippet artifacts, and Epic 10 owns the concrete transcription reviewer.
