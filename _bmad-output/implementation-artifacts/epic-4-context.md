# Epic 4 Context: Pipeline Validation Milestone (CLI End-to-End)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Validate the entire meeting pipeline — transcribe, diarize, attribute, summarize, persist, notify — end to end from the terminal before any GUI investment. The maintainer (in builder mode) registers an existing recording, runs one CLI verb, and gets a complete Obsidian note. This is a gate, not a ship: it proves WhisperKit transcription and diarization quality, the AI-correction architecture (diarization review behind a flag), and the quote-grounded summarization pipeline on real recordings, with a measured exit bar rather than an assumption that things work.

## Stories

- Story 4.1: WhisperKit Transcribe Stage
- Story 4.2: Diarize Stage + Snippet Extraction
- Story 4.3: ReviewDiarization Stage + State Machine Entry
- Story 4.4: AIReviewerInterface Protocol Family + Null TranscriptionReviewerStrategy
- Story 4.5: ClaudeDiarizationReviewer Concrete Impl Behind Flag
- Story 4.6: AttributionViewModel in Attribute/ + Attribution Batch CLI
- Story 4.7: `auricle run` Verb Skeleton + `__internal-stage` Worker Dispatch
- Story 4.8: Builder-Mode Audio Import (`auricle __internal-import`)
- Story 4.9: Basic Notification Stub + Obsidian URL Open
- Story 4.10: Exit-Criteria Gate (CI Pipeline Test + Live Run)
- Story 4.11: Offline Recall Bench — Frozen Transcripts, Real Claude Call, Automatic Score
- Story 4.12: Score the Item, Count the False Keeps
- Story 4.13: Prompt Recall Pass
- Story 4.14: Retention — Unset the First-Token Gate, Measure Dropped Text
- Story 4.15: Summarizer Under-Production on ES2002b and ES2004a

## Requirements & Constraints

- Transcription runs fully on-device (WhisperKit, Whisper-large-v3-turbo, ANE), no network round-trip, English-only in MVP; diarization is WhisperKit's built-in speaker segmentation producing `Speaker_1`, `Speaker_2`, ... labels.
- Transcribe and diarize each complete in ≤30s for a 30-minute file (one shared subprocess, one model load); peak memory during transcription stays ≤4GB.
- Cache artifacts (`transcript.json`, `diarization.json`) are write-once and immutable; corrections layer on top, never in place.
- Attribution supports a CLI batch path (`--speakers "1=Ben,..."`) and a `--publish-anyway` path that publishes with `Speaker_N` placeholders and a `needs-attribution` tag; autocomplete priority is calendar attendees, then vault wikilinks, then previously-labeled speakers.
- Notification and click-to-verify ship as an intentionally incomplete stub: `StdoutNotifier` prints the note path and Obsidian URL; full verification + retention-timer arming is Epic 8's job.
- Diarization review ships all its architectural slots at MVP but stays flag-default-off; per-meeting cost stays ≤$0.50 with the flag off, ≤$0.60 with it on (Haiku review + Opus summarize).
- The CLI argument surface (verbs, flags, JSON schemas) is a binding, versioned contract — renaming or removing is breaking; additions are not.
- Every stage is idempotent; a revoked notification permission degrades gracefully without blocking the pipeline; audio and cache files are 0600.
- The exit bar (Story 4.10) is measured: ≥80% of expected action items/decisions must survive quote-grounding across a real-recording fixture set, with false keeps tracked alongside recall so a recall gain bought with noise is visible. Real recordings are never committed; only aggregate results and opaque per-fixture labels are.
- Only one primary Claude summarization call per meeting is allowed (no chain-of-summarize/multi-pass), even to chase recall.

## Technical Decisions

- Subprocess boundary: transcribe+diarize share one subprocess (freed once its ~2-4GB working set is no longer needed); summarize is its own subprocess; `reviewing_diarization` spawns only after the WhisperKit subprocess exits. `attribute`, `persist`, `notify` run in-process under `auricle run`.
- State machine: `transcribing → reviewing_diarization → awaiting_attribution → attributing → summarizing → persisting → published → awaiting_verification`, via a two-transaction (start/complete) write pattern so a crash mid-stage is unambiguous and resumable. `published_partial` is the distinct terminal state for `--publish-anyway` + failed-summarize, carrying both `needs-attribution` and `needs-summary` tags.
- `reviewing_diarization` passes through in <100ms with an empty stub when its flag is off; a 90s timeout or error is a benign passthrough to `awaiting_attribution`, not a failure.
- `AIReviewerStrategy` is a protocol family (`DiarizationReviewerStrategy`, `TranscriptionReviewerStrategy`, `JargonCorrectionStrategy`) sharing one output shape, prompt-caching pattern, and cost/telemetry contract, so later phases are config flips, not refactors. Only the diarization reviewer gets a concrete (Haiku-default) implementation here.
- Telemetry columns are partitioned by writer to avoid UPSERT conflicts: the reviewer subprocess writes count/cost/model, the GUI attribution flow writes applied/rejected. No column has two writers.
- `AttributionViewModel` lives in the `Attribute` library target, not a GUI target, so the CLI batch path and the future GUI sheet consume the identical type — the parity contract preventing CLI/GUI divergence. Its transcript renderer is a pure function over `(diarization, overrides, splits) → RenderedTranscript`.
- Failure states fall into four categories (transient, permanent, user-actionable, benign-terminal) with category-driven, not per-stage, retry/surfacing behavior.
- Recall scoring credits an expected item whose *text* matches a kept item even under a different quote, and reports false keeps as a co-equal metric. The WhisperKit decoding gate (`firstTokenLogProbThreshold`) must stay unset so whole 30s windows aren't silently dropped; a dropped-reference-text fraction is measured and threshold-enforced.

## UX & Interaction Patterns

Attribution is a sheet on the single main window, never a separate per-meeting window — a rule that predates Epic 4's CLI-only surface but shapes `AttributionViewModel` so the future GUI sheet can adopt it unchanged. Diarization-review suggestions render as inline chips with a trust-calibration footer ("Reviewed N segments, flagged M"); zero suggestions must read as explicit "no signal," not "0%," since silence isn't distrust.

## Cross-Story Dependencies

- Strict build order 4.1 → ... → 4.9 → 4.10; 4.9 cannot land before 4.1-4.8, and 4.10 is the explicit exit gate.
- Recall remediation (4.11 → 4.12 → 4.13) runs after 4.10's first live-run measurement (42.1% recall against an 80% floor) and before 4.10 is rerun. 4.13 ends at a maintainer decision gate resolved by 4.14 (remove the WhisperKit decoding gate dropping whole windows; add a dropped-text metric) and 4.15 (diagnose summarizer under-production on two fixtures); both feed a 4.10 rerun.
- Story 4.6's `AttributionViewModel` and renderer are imported unchanged by Epic 7's GUI Attribution sheet; applying `segment_overrides`/`segment_splits` to the transcript the summarizer reads is out of scope here and belongs to a later Epic 7 story.
- Epic 8 owns the full verification + retention-timer wiring that Story 4.9 stubs; Epic 6 owns GUI subprocess dispatch and bundled system-notification posting.
- Epic 5's capture stage doesn't exist yet — Story 4.8's `__internal-import` verb substitutes a recording already on disk.
