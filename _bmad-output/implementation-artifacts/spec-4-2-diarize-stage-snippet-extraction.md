---
title: 'Story 4.2: Diarize Stage + Snippet Extraction'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'dispatch'
baseline_revision: '7b26bba02dadbc3f2386d92dd5fa46081934f1b8'
baseline_commit: '7b26bba02dadbc3f2386d92dd5fa46081934f1b8'
review_loop_iteration: 0
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-4-1-whisperkit-transcribe-stage.md',
]
warnings: [oversized]
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `DiarizerInterface`, `Diarize` and `WhisperKitDiarizer` are placeholders. Nothing writes `diarization.json` or the per-speaker snippets the Attribution sheet plays, and the transcribe `completed` row has no `diarize` block.

**Approach:** Add `DiarizerStrategy`, a SpeakerKit-backed strategy, and a `DiarizeStage` that writes an immutable `diarization.json` plus `snippets/speaker_N.wav` and `.envelope`. The transcribe stage runs it as an injected step inside the same subprocess and merges its metadata under `diarize`.

## Decisions (human-approved)

- **Engine: SpeakerKit** (`PyannoteConfig`, pyannote, Swift, same package). WhisperKit 1.1.0 has no diarizer in its own target, so there is nothing to compare. The AC's empirical test is deferred to Story 4.10 Part B. A later swap is one new target behind `DiarizerStrategy`.
- **Utterance link: sidecar timing.** The transcriber also returns per-utterance seconds. Each diarization segment stores the `utterance_index` range it overlaps. `transcript.json` is unchanged and stays `Speaker_1`-only. The `diarize` signature gains a `utteranceTimings` argument beyond the epic text.

## Boundaries & Constraints

**Always:**
- `diarization.json` goes through `CacheArtifactWriter`, `schema_version: 1`, byte-identical on re-run. Segment ids are `seg_<n>` by start time. Speakers are `Speaker_<n>` in order of first appearance.
- Each segment carries `voice_profile.overlap_ratio` (share of the segment overlapped by another speaker's segment), the UX-DR36 variance signal.
- Snippets: per speaker, the longest segment, clip length `attribution.snippet_duration_seconds` (default 8, clamped 5-10, shorter only when the speaker has less audio), 16 kHz mono Int16 WAV via `AtomicWriter`, 0600. `.envelope` is 200 little-endian Float32 peak amplitudes, 0600.
- No `stage_events` row and no new `PipelineStage` case. The step returns `DiarizeMeta {model_id, segment_count, speaker_count, snippet_count}`, and the transcribe stage encodes it under `diarize` in its own `completed` row.
- `Transcribe` and `Diarize` never import each other. Only `App/auricle-cli` wires both.
- Diarization never touches the network. Model download is a separate provision step.
- Failure never throws out of the stage: it folds into `.failed(targetState: .transcriptionFailed, errorClass:, errorMessage:)` with a case name or fixed sentence only.

**Never:**
- No `reviewing_diarization` work, `AttributionViewModel`, renderer, or `auricle run` wiring (Stories 4.3, 4.6, 4.7).
- No change to `transcript.json` content or its Story 4.1 tests' expectations.
- No live model download in CI. Live tests are env-gated.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | Stub diarizer returns 2 speakers | `diarization.json`, `snippets/speaker_1.wav/.envelope`, `speaker_2.*`; `completed` row has `diarize` object | None |
| No timings | Transcriber returns no utterance timings | Segments written with no `utterance_index`; completes | None |
| Zero segments | Diarizer returns none | Empty segments, zero snippets, `speaker_count` 0, completes | None |
| Short speaker | Speaker total audio under 5s | Snippet is the available audio | None |
| Snippet duration | Config 3 or 20 | Clamped to 5 or 10 | None |
| Model missing / load / run failure | `DiarizerError.modelUnavailable/.modelLoadFailed/.diarizationFailed` | `.failed`, classes `diarize_model_unavailable/_model_load_failed/_failed`, exit 75 | Retryable |
| Artifact write fails | Writer throws | `.failed`, class `diarization_write_failed`, exit 2 | Permanent |
| Snippet write fails | Extractor throws | `.failed`, class `snippet_write_failed`, exit 2 | Permanent |
| Unknown error | Other thrown error | `.failed`, class `diarize_unexpected_error`, type name only, exit 2 | Permanent |
| Re-run | Same input twice | Byte-identical `diarization.json`, `.wav`, `.envelope` | None |
| No diarization step injected | Transcribe stage without a step | Row has no `diarize` key, as in Story 4.1 | None |

</frozen-after-approval>

## Code Map

- `Sources/Transcribe/TranscribeStage.swift` -- add the optional step after the transcript write; extend `TranscribeStageError`/`retryableErrorClasses` with the `diarize_*` classes. `encodeMetadataJSON` is where `diarize` merges.
- `Sources/Transcribe/TranscribeWorker.swift` -- pass the step through.
- `Sources/Telemetry/StageMetadata.swift` -- `TranscribeMeta` gains optional `diarize: DiarizeMeta?` (`encodeIfPresent`, key `diarize`); add `DiarizeMeta` with explicit snake_case `CodingKeys`.
- `Sources/TranscriberInterface/` -- add `TimedTranscript` and a `transcribeTimed` requirement whose default extension returns empty timings, so existing stubs still conform.
- `Sources/WhisperKitTranscriber/WhisperKitTranscriber.swift` -- implement `transcribeTimed` from segment start/end; keep timings aligned with the utterances `CanonicalTranscriptBuilder` keeps (it drops blanks; extend the builder to report kept indices).
- `Sources/Core/` -- add `UtteranceTiming` (index, start/end seconds). Add `Config.attribution.snippetDurationSeconds` in `Config.swift` (TOML key `attribution.snippet_duration_seconds`; invalid value throws `ConfigError.invalidValue`).
- `Sources/DiarizerInterface/`, `Sources/Diarize/`, `Sources/WhisperKitDiarizer/` -- replace the three `ManifestPlaceholder.swift` files.
- `.build/checkouts/WhisperKit/Sources/SpeakerKit/` -- `SpeakerKit(PyannoteConfig(...))`, `diarize(audioArray:)` takes 16 kHz mono Float, returns `DiarizationResult.segments` (`speaker.speakerId`, `startTime`, `endTime`). `SpeakerKit` is a class, not Sendable: confine it to an actor.
- `Package.swift` -- `WhisperKitDiarizer` gains `.product(name: "SpeakerKit", package: "WhisperKit")`; `Diarize`/`Transcribe` and test targets gain what they import.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- `runTranscribe()` builds the diarization step (closure over `DiarizeStage` + `WhisperKitDiarizer`) and provisions the diarizer model when absent. Keep it a thin wrapper.
- `Sources/Core/AtomicWriter.swift`, `CacheArtifactWriter.swift`, `Log.swift` -- the only allowed write and log paths (AGENTS.md).

## Tasks & Acceptance

**Execution:**
- [x] `Sources/Core/UtteranceTiming.swift`, `CanonicalTranscriptBuilder.swift`, `Config.swift` -- timing type, kept-index reporting, snippet-duration config -- shared inputs.
- [x] `Sources/TranscriberInterface/`, `Sources/WhisperKitTranscriber/WhisperKitTranscriber.swift` -- `TimedTranscript`, `transcribeTimed` -- gives diarize its timings.
- [x] `Sources/DiarizerInterface/` -- `DiarizerStrategy` (`diarize(transcript:utteranceTimings:audio:config:)`), `DiarizerConfig`, `DiarizerError` (payload-free cases `modelUnavailable`, `modelLoadFailed`, `audioUnreadable`, `diarizationFailed`), `DiarizationArtifact` (segments: id, speaker_label, start_seconds, end_seconds, utterance_index range, voice_profile) -- the AR-PAT-7 contract.
- [x] `Sources/Telemetry/StageMetadata.swift` -- `DiarizeMeta`, optional `TranscribeMeta.diarize`.
- [x] `Sources/Diarize/DiarizeStage.swift`, `DiarizeStageError.swift`, `SnippetExtractor.swift` -- artifact write, snippet and envelope files, `DiarizeMeta` -- per the matrix.
- [x] `Sources/WhisperKitDiarizer/WhisperKitDiarizer.swift` (+ model store) -- actor over SpeakerKit, offline, model loaded once, failures mapped to `DiarizerError`; a `provision` path is the only download.
- [x] `Sources/Transcribe/` -- inject and run the step, merge metadata, classes and exit codes.
- [x] `App/auricle-cli/Verbs/InternalStageWorker.swift`, `Package.swift` -- wiring.
- [x] `Tests/DiarizeTests/`, `Tests/WhisperKitDiarizerTests/`, `Tests/TranscribeTests/`, `Tests/CoreTests/` -- every matrix row against stubs and a generated WAV: output shape, snippet length and 0600, 200 envelope samples, byte-identical re-run, merged `diarize` metadata, no-step row unchanged. `Tests/DiarizeTests/PerformanceTests.swift` env-gated on a 30-minute WAV plus model. Env-gated live SpeakerKit test.

**Acceptance Criteria:**
- Given `WhisperKitDiarizer` as a `DiarizerStrategy`, when it runs twice in one process, then it loads the model once.
- Given a transcribe run with a diarization step, when it completes, then one `transcribe`/`completed` row carries `model_id`, `audio_duration_s`, `transcript_chars` and a `diarize` object, and no other `stage_events` row exists.
- Given `PipelineStage`, then it still has nine cases, and `__internal-stage diarize` stays invalid.
- Given two runs over the same audio, then `diarization.json` and every snippet file are byte-identical.
- Given `swift build` for `Transcribe`, then it imports no `Diarize` and `Diarize` imports no `Transcribe`.

## Implementation Notes

- Shared `ClassifiedStageError` and `DiarizeErrorClass` live in `Core` so `Transcribe` can record and classify a diarize failure without importing `Diarize`.
- `MonoAudioLoader` and `DiarizationArtifactBuilder` live in `DiarizerInterface`, so any engine gets the same artifact shape.
- SpeakerKit runs with `useExclusiveReconciliation: false` so overlap survives for `overlap_ratio`. Determinism under that setting is unverified.
- Nothing ran against a real SpeakerKit model: the live test, the 30-minute budget test and `provision` are unverified. See `deferred-work.md`.

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| Stale snippets survive a re-run | medium | patch | `SnippetExtractor` never clears `snippets/`; a re-run with fewer speakers leaves files that disagree with `snippet_count`. |
| NaN sample traps in `Int16(sample)` | medium | patch | Conversion traps on non-finite input. |
| Snippet dir default permissions | low | patch | Dir holds raw audio; files were already 0600. |
| Sub-0.5 ms segment rounds to zero length | low | patch | Filter ran before rounding. |
| No test of which audio a clip holds | medium | patch | Every snippet test asserts length or header only. |
| Config mapping in `App/` untested | medium | patch | AGENTS.md pitfall; moved to `Sources/`. |
| Default 8 defined twice | low | patch | Direct correction. |
| Misleading "never fails a transcript" comment | low | patch | Failures do fail the stage, as the spec requires. |
| Diarize failure fails the whole transcribe stage | medium | defer | Matches the approved matrix; a retry re-runs transcription. Recorded as a design question. |
| Partial download passes `SpeakerKitModelStore` check | medium (unverified) | defer | Same heuristic as 4.1's deferred item; needs the real model layout. |
| Resampler tail dropped in `MonoAudioLoader` | maybe-false | defer | Needs a 44.1 kHz round-trip test to settle. |
| `.multiple` segments dropped, `overlap_ratio` may undercount | maybe-false | defer | Needs a live SpeakerKit run to see what `useExclusiveReconciliation: false` emits. |
| Model reuse and load dedup untested by default | medium | defer | Needs a loader seam or a real model. |
| Same-speaker overlapping segments duplicate clip audio | low | rejected | Fix adds merging logic; unlikely in everyday use. |
| Non-finite `startSeconds`, cancellation mapping, `DiarizerInterface` not interface-only | low | rejected | Internal callers only, or cosmetic. |

## Design Notes

`overlap_ratio` is the variance proxy because SpeakerKit exposes per-speaker centroid embeddings, not per-segment ones. True intra-segment embedding variance would need SpeakerKit internals and is out of scope.

## Verification

**Commands:**
- `make check` -- expected: all gates pass
