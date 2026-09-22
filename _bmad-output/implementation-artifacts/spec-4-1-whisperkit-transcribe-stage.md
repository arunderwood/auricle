---
title: 'Story 4.1: WhisperKit Transcribe Stage'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: 'd2da1e366f8418d5e4db714b6ecd21bcb868ca85'
review_loop_iteration: 1
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      How diarized speaker labels reach an immutable `transcript.json` is undecided.
    evidence: |-
      `TranscriberStrategy.transcribe(audio:config:)` takes no diarization input, so this story writes every utterance as `Speaker_1`. Story 4.2's `diarize(transcript:audio:config:)` takes the transcript as input, and `segment_overrides` and `segment_splits` reference `diarization.json` segments with no mapping to utterance indices.
    severity: high
  - summary: >-
      A signal-killed last transcribe attempt records no failure row.
    evidence: |-
      No Txn B runs when the worker dies by signal. The 60s stale sweep later sets `transcription_failed` with class `stale_active_state`. Story 4.7's supervisor decides whether to record retry exhaustion sooner.
    severity: medium
  - summary: >-
      First-run model provisioning has no owner outside the transcribe worker.
    evidence: |-
      The worker downloads a missing model before the stage starts. Onboarding (Epic 5) or `doctor` (Epic 9) should own that step so a background dispatch never starts a large download unannounced.
    severity: medium
  - summary: >-
      The store's completeness checks are heuristics that a partial download can pass.
    evidence: |-
      `WhisperKitModelStore.isComplete` treats a non-empty `.mlmodelc` directory as present and a lone `tokenizer.json` as a tokenizer. Hub snapshots write files one at a time, so an interrupted download can leave `coremldata.bin` without `weights/weight.bin`, or a tokenizer without `tokenizer_config.json`. The store then reports the model as provisioned, no re-download starts, and every run fails as `modelLoadFailed` or falls back to fetching the tokenizer during load. A file-level check or a completion marker would settle it, but neither can be written safely without the real model layout.
    location: >-
      Sources/WhisperKitTranscriber/WhisperKitModelStore.swift (isComplete, hasTokenizer)
    severity: medium (unverified)
  - summary: >-
      `provision` has never run, and its result folder is checked against a hard-coded folder name.
    evidence: |-
      `provision` ignores the folder `WhisperKit.download` returns and requires `resolve` to find the model at `<root>/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo`. If the remote folder name differs, every first run downloads about 1.5 GB and then fails as `transcribe_model_unavailable`. One env-gated run of `provision`, ending in `isProvisioned == true`, settles it.
    location: >-
      Sources/WhisperKitTranscriber/WhisperKitModelStore.swift (provision, variants)
    severity: high (unverified)
  - summary: >-
      `provision` takes no lock, has no deadline and checks no free disk space.
    evidence: |-
      Two workers for different meetings can both find the model missing and download into one root at once. A stalled network hangs the worker before any state row exists, so no stale sweep or user signal fires. Neither case is reachable today because only one worker runs at a time and no GUI dispatches the stage.
    location: >-
      App/auricle-cli/Verbs/InternalStageWorker.swift (provisionModelIfMissing)
    severity: medium
  - summary: >-
      `TranscribeRetryPolicy` has no runtime caller.
    evidence: |-
      Only its own tests reference it. The worker exits 75 for a retryable failure, but nothing relaunches the worker until Story 4.7's `auricle run` supervises it. Until then the "one retry after a fresh subprocess" behavior exists only under test.
    location: >-
      Sources/Transcribe/TranscribeRetryPolicy.swift
    severity: medium
  - summary: >-
      A finished or slow transcription can be failed by the 60s stale sweep.
    evidence: |-
      The stage completes into `transcribing`, and the sweep keys on `meetings.state` and `updated_at` only. If the next stage does not start within 60s, or a cold Core ML compile of the model runs past 60s under a live worker, the sweep writes `transcription_failed`. Story 3.7 recorded the same shape for `summarizing`. Real dispatch in Story 4.7 and one live run settle it.
    location: >-
      Sources/Orchestrator/StageRunner.swift (sweepStaleActiveStates, staleDetectionBudgetSeconds)
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** `TranscriberInterface`, `Transcribe` and `WhisperKitTranscriber` are empty placeholder targets, so nothing turns `audio.wav` into the `transcript.json` the summarize stage reads, and no real transcript has ever fixed the utterance-range convention.

**Approach:** Add the `TranscriberStrategy` protocol, a WhisperKit-backed actor that loads the model once and transcribes offline, and a `TranscribeStage` that runs inside `StageRunner`, writes an immutable, deterministic `transcript.json`, and records `TranscribeMeta`. Wire it into the hidden `__internal-stage transcribe` worker and give it the one-retry-after-fresh-subprocess policy.

## Boundaries & Constraints

**Always:**
- The transcript is built by one Core builder: NFC text, LF, no leading or trailing whitespace per line, `Speaker_N: ` prefix per utterance, UTF-8 byte offsets, each `[start, end)` range includes its own prefix and excludes the joining newline.
- `transcript.json` goes through `CacheArtifactWriter` with `schema_version: 1`, and identical input gives byte-identical bytes.
- English only: `language: "en"`, no language detection, `skipSpecialTokens: true`, temperature fallback disabled so a re-run cannot diverge.
- Transcription never touches the network: `download: false`, model and tokenizer resolved from a local folder. Downloading is a separate `provision` step.
- The stage never throws for a transcription failure. It returns `.failed(targetState: .transcriptionFailed, …)`. Only a case name, type name or fixed sentence reaches `error_class` or `error_message`, never a path or transcript text.
- Completes into `.transcribing` (no state sits between transcribe, diarize and review). Model load happens once per process.

**Never:**
- No diarization, snippets or speaker assignment (Story 4.2). Every utterance carries the single label `Speaker_1`.
- No `silent` detection or VAD, no `--force` handling, no `auricle run` wiring (Stories 4.7, Epic 10).
- No live model download in tests or CI. Live-model tests are env-gated and skip by default.
- `Transcribe` must not import `Diarize`, `WhisperKit*` or any concrete strategy.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | `audio.wav` present, stub or real transcriber returns segments | `transcript.json` written; events `started`,`completed`; state `transcribing`; `TranscribeMeta` has `model_id`, whole-second `audio_duration_s`, `transcript_chars` | No error expected |
| Zero segments | Transcriber returns no text | Empty transcript written, `transcript_chars` 0, completes | None: silence detection is not this story |
| Special tokens / blank segments | Segment text holds `<\|…\|>` tokens, CRLF, edge whitespace, or is blank | Tokens removed, text canonicalized, blank segments dropped | None |
| Audio missing or unreadable | No `audio.wav`, or `AVAudioFile` cannot open it | `.failed(.transcriptionFailed)`, class `audio_missing` / `audio_unreadable`, exit 2, no transcript | Permanent, no retry |
| Model missing | `TranscriberError.modelUnavailable` | `.failed`, class `transcribe_model_unavailable`, exit 75 | Retryable class |
| Model load / decode failure | `TranscriberError.modelLoadFailed` / `.transcriptionFailed` | `.failed`, classes `transcribe_model_load_failed` / `transcribe_failed`, exit 75 | Retryable class |
| Unknown error | Any other thrown error | `.failed`, class `transcribe_unexpected_error`, message is the type name only, exit 2 | Permanent |
| Transcript write fails | `CacheArtifactWriter` throws | `.failed`, class `transcript_write_failed`, exit 2 | Permanent |
| Retry: retryable then success | Attempt 1 signal-killed or exit 75, attempt 2 exit 0 | Two attempts, final `.succeeded` | None |
| Retry: exhausted | Both attempts fail retryably | Exactly two attempts, final `.exhausted` | Caller records failure; a signal-killed last attempt is left to the stale sweep |
| Retry: permanent | Attempt 1 exit 2 | One attempt, final `.failed`, no retry | None |
| Unknown meeting | No row for the id | Throws `StateStoreError.meetingNotFound` before anything is recorded | Same as summarize |

</intent-contract>

## Code Map

- `Sources/Summarize/SummarizeStage.swift` -- the stage pattern to mirror: `StageRunner.run` closure, `.failed` folding, `encodeMetadataJSON` encodes the meta struct directly with `.sortedKeys`, `exitCode(for:)`.
- `Sources/Summarize/SummarizeStageError.swift` -- payload-free error enum with `errorClass` strings; copy the shape.
- `Sources/Telemetry/StageMetadata.swift` -- `TranscribeMeta(modelID, audioDurationSeconds, transcriptChars)` already exists.
- `Sources/Core/CanonicalTranscript.swift`, `Sources/Core/CacheArtifactWriter.swift` -- the value type and writer. The writer serializes with `JSONSerialization` and no `.sortedKeys`, so key order is not stable across processes.
- `Sources/Core/Errors.swift` -- holds an unused placeholder `TranscribeError`.
- `Sources/Orchestrator/StageRunner.swift` -- Txn A / Txn B wrapper; `transcribing` stale budget is 60s; `StageOutcome`.
- `Sources/Orchestrator/SubprocessDispatcher.swift` -- spawns `__internal-stage <stage> <id> --worker-protocol-version 1`; the retry policy's attempt closure is what 4.7 backs with it.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- `runSummarize()` is the wiring template; `default:` currently returns not-yet-implemented for `.transcribe`.
- `Package.swift`, `App/Project.swift` -- `Transcribe` lacks an `Orchestrator` dependency; Tuist already links every product.
- `Sources/{TranscriberInterface,Transcribe,WhisperKitTranscriber}/ManifestPlaceholder.swift` -- delete when real code lands.
- `AGENTS.md` (Known pitfalls) -- logic that lives only in `App/` has no `swift test` coverage, so the worker's branching goes in `Sources/Transcribe` and `App/` only wires it.
- `/private/tmp/claude-501/-Users-andrewunderwood-checkouts-auricle--claude-worktrees-determined-sanderson-c34702/d6306056-8508-4dfd-83a1-8e5ef1259b87/scratchpad/story-4-1-first-derivation.patch` -- if present, the first derivation of this spec, reviewed and passing; see the Spec Change Log for what to keep and what to change.
- `Tests/SummarizeTests/SummarizeStageFixture.swift` -- fixture pattern: in-memory `StateStore.forTesting`, real cache dir per meeting id, `cleanUp()`.
- WhisperKit 1.1.0 (`argmaxinc/WhisperKit` product `WhisperKit`): `WhisperKit(WhisperKitConfig(model:downloadBase:modelFolder:tokenizerFolder:computeOptions:verbose:load:download:))`, `transcribe(audioPath:decodeOptions:)` returns `[TranscriptionResult]` with `segments[].text`. The class is not `Sendable`, so confine it to an actor. Variant folder for the default model is `openai_whisper-large-v3-v20240930_turbo`. The tokenizer is fetched from `openai/whisper-large-v3` unless `tokenizer.json` is found under `tokenizerFolder`.

## Tasks & Acceptance

**Execution:**
- `Sources/Core/CacheArtifactWriter.swift` -- serialize with `.sortedKeys` -- byte-identical re-runs need a stable key order.
- `Sources/Core/CanonicalTranscriptBuilder.swift` -- build a `CanonicalTranscript` from `(speakerLabel, text)` pairs per the Always rules; drop blank utterances -- the one place the AR-SUM-4 invariant is enforced.
- `Sources/Core/Errors.swift` -- remove the unused `TranscribeError` and fix the header comment -- the real domain error now lives in `TranscriberInterface`.
- `Package.swift` -- `Transcribe` gains `Orchestrator`; test targets gain the dependencies they import.
- `Sources/TranscriberInterface/TranscriberStrategy.swift`, `TranscriberError.swift` -- `TranscriberStrategy` (`func transcribe(audio: URL, config: TranscriberConfig) async throws -> CanonicalTranscript`), `TranscriberConfig(modelID:modelFolder:)` defaulting to `whisper-large-v3-turbo`, `TranscriberError` cases `modelUnavailable`, `modelLoadFailed`, `audioUnreadable`, `transcriptionFailed`; delete the placeholder.
- `Sources/WhisperKitTranscriber/WhisperKitTranscriber.swift`, `WhisperKitModelStore.swift` -- actor conforming to `TranscriberStrategy`: lazy single model load on the ANE, offline, decode options per Always, segments to canonical utterances labelled `Speaker_1`, WhisperKit failures mapped to `TranscriberError`. Model store: resolves the local folder and rejects an incomplete one, and `provision` is the only download path. Delete the placeholder.
- `Sources/Transcribe/TranscribeStage.swift`, `TranscribeStageError.swift` -- `TranscribeStage.run(meetingID:stateStore:stageRunner:transcriber:config:)` and `exitCode(for:)` (0 completed, 75 retryable failure, 2 otherwise) per the matrix. Delete the placeholder.
- `Sources/Transcribe/TranscribeRetryPolicy.swift` -- one retry after a fresh attempt on a crash-style signal termination or exit 75; `SIGINT` and `SIGTERM` are user or parent cancellation and are never retried; attempts injected as a closure -- Decision 4.2, testable without a process.
- `Sources/Transcribe/TranscribeWorker.swift` -- the worker's logic, so it is reachable by `swift test`: `TranscribeWorker.run(meetingID:stateStore:stageRunner:transcriber:config:ensureModel:)` returns an `Exit` value (`code: Int32`, `message: String?` holding a fixed sentence or a type name only). It looks the meeting up first and returns code 3 without calling `ensureModel` when there is no row; otherwise it awaits `ensureModel`, runs `TranscribeStage`, and returns `TranscribeStage.exitCode`; a state-store failure while recording returns code 2. `ensureModel` is an injected closure, so `Transcribe` still names no concrete strategy.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- `runTranscribe()` stays a thin wrapper: parse the id (exit 1 when malformed), open the store (exit 2 on failure), build `WhisperKitModelStore`, `WhisperKitTranscriber` and an `ensureModel` closure that provisions the model only when it is absent and writes one stderr line, call `TranscribeWorker.run`, print the `Exit` message to stderr, and exit with its code.
- `Tests/CoreTests/CanonicalTranscriptBuilderTests.swift`, `CacheArtifactWriterTests.swift` -- builder invariants and byte-stable writes.
- `Sources/WhisperKitTranscriber/WhisperKitTranscriber.swift` -- build the `WhisperKitConfig` in an internal `static func kitConfig(for:)` -- so a default test can assert that transcription cannot reach the network.
- `Tests/TranscribeTests/` -- stage matrix rows against a stub transcriber and a generated WAV; retry policy rows, including `SIGINT` and `SIGTERM` as non-retryable; `TranscribeWorker` rows against stubs (exit 3 with `ensureModel` never called for an unknown meeting, `ensureModel` awaited before the stage's first transaction, exit 0, exit 75 for a retryable failure, exit 2 for a permanent one and for a state-store failure); `PerformanceTests.swift` env-gated on a 30-minute WAV plus model folder.
- `Tests/WhisperKitTranscriberTests/` -- segment-to-canonical mapping, model-folder validation and `kitConfig(for:)` (`download == false`, `modelFolder` and `tokenizerFolder` set from the resolved model, encoder and decoder on the Neural Engine) without a model; env-gated live test for model load, transcribe, byte-identical re-run and model reuse.

**Acceptance Criteria:**
- Given `WhisperKitTranscriber`, when it is used as a `TranscriberStrategy`, then it loads the default model once per process and reuses it for later calls.
- Given `audio.wav` in the meeting's cache directory, when the stage runs, then `transcript.json` holds `schema_version: 1`, NFC/LF text and `Speaker_1: ` utterances whose ranges include the prefix, and the summarize mapper's label strip yields text without it.
- Given the same audio transcribed twice, when both transcripts are written, then the two `transcript.json` files are byte-identical.
- Given a successful run, then a `completed` event carries `{model_id: "whisper-large-v3-turbo", audio_duration_s, transcript_chars}` and no network call happens.
- Given retryable failures on two attempts, then the policy stops after exactly two attempts. A last attempt that exits 75 leaves the meeting in `transcription_failed`, and a last attempt killed by a signal leaves it for the stale sweep.
- Given the built `auricle-cli`, when `__internal-stage transcribe <well-formed id with no meeting row> --worker-protocol-version 1` runs, then it exits 3 and downloads nothing. `TranscribeWorker`'s tests pin the same ordering and the exit-code mapping under `swift test`.
- Given the reference 30-minute WAV and model on the reference machine, when the performance test runs, then it completes in 30s or less. It skips, and is reported as unverified, where either is missing.

## Spec Change Log

### 2026-09-18 — Review pass 1 (bad_spec)

- **Triggering finding:** `InternalStageWorker.runTranscribe` held real branching in `App/` (meeting lookup before provisioning, provisioning before the stage, exit-code plumbing) that no `swift test` reaches. Deleting `case .transcribe`, dropping the `if exitCode != 0` guard or moving provisioning above the meeting lookup left every test green. `AGENTS.md` names this as a known pitfall.
- **Amended:** a `Sources/Transcribe/TranscribeWorker.swift` task now owns that logic behind an injected `ensureModel` closure, and the `App/` task is a thin wrapper. The `kitConfig(for:)` task and test and the `SIGINT` and `SIGTERM` retry rule were added because the same review found them and the loopback re-derives all code. The signal wording of the retry acceptance criterion was tightened to match the matrix. `<intent-contract>` is unchanged.
- **Known-bad state avoided:** worker ordering and exit-code mapping pinned only by a manual CLI run.
- **KEEP:**
  - Everything in the first derivation outside the worker task. Re-applying that patch and changing only the worker task and the three additions above is the intended path.
  - `CanonicalTranscriptBuilder` semantics: NFC, every line-break form to LF, per-line trim, blank lines removed, blank utterances dropped, no trailing newline.
  - `.sortedKeys` in `CacheArtifactWriter` and its two tests.
  - The unused `TranscribeError` removed from `Core/Errors.swift`.
  - `TranscriberError` with no payload on any case, and `TranscriberConfig.defaultModelID == "whisper-large-v3-turbo"`.
  - `WhisperKitTranscriber` as an actor sharing one model load, with `decodeOptions` as in the first derivation (English forced, temperature 0, fallback off, `skipSpecialTokens`).
  - `WhisperKitModelStore` in the Hub layout under `~/Library/Application Support/com.auricle.app/models/whisperkit`, with `resolve` read-only and `provision` the only download path.
  - `TranscribeStage`, `TranscribeStageError` and their class strings, exit codes 0, 75 and 2, and metadata encoded as `TranscribeMeta` directly with sorted keys.
  - The `.swiftlint.yml` composition-root exemptions for `Tests/WhisperKitTranscriberTests/` and `Tests/TranscribeTests/PerformanceTests.swift`.
  - The `Package.swift` dependency edits and `Tests/SummarizeTests/BuiltTranscriptMappingTests.swift`.

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 44 findings — high 0, medium 15, low 19, false 7, maybe-false 3
- findings:
  - `[medium]` `[defer]` Blind 1: the retry policy has no runtime caller — only its tests reference it; Story 4.7's `auricle run` owns supervision; deferred as its own item.
  - `[medium]` `[defer]` Blind 2: a completed transcribe can be failed by the 60s stale sweep — `transcribing` is budgeted and the sweep ignores the `completed` row; the budget and sweep are existing design; deferred with the cold-load case.
  - `[low]` `[reject]` Blind 3: cancellation is recorded as a permanent failure — nothing in this code path cancels a task, and a signal kills the process without a Swift cancellation; the fix adds branches for a case no caller can reach.
  - `[low]` `[reject]` Blind 4: the actor is reentrant at `transcribe`, so two calls could overlap — the doc comment states the one-at-a-time caller contract, the worker makes one call, and a guard would be speculative.
  - `[medium]` `[defer]` Blind 5: model errors are too coarse and a truncated model passes `isComplete` — the truncated-weights part is the completeness item; the coarse-retry part costs one fast extra attempt and is not worth fixing.
  - `[low]` `[reject]` Blind 6: zero-length audio is not handled — capture does not exist yet, and the worst outcome is one wasted retry or an empty transcript, which the matrix accepts.
  - `[low]` `[reject]` Blind 7: model provenance is not pinned or recorded — no bad outcome shown; pinning revisions adds a maintenance burden with nothing to test it against.
  - `[low]` `[reject]` Blind 8: the performance and memory gates cannot be reported as met in CI — the story's own criterion is an env-gated test, and no NFR-P10 test is required of this story; the run reports the gate as unverified.
  - `[false]` `[reject]` Blind 9: `.sortedKeys` changes every cache artifact — the full suite of 831 tests passes, all consumers decode with `JSONDecoder`, and JSON object key order carries no meaning.
  - `[low]` `[reject]` Blind 10: a stale `transcript.json` survives a failed re-run — architecture says a re-run overwrites the artifact; deleting an existing transcript on failure would destroy the immutable file.
  - `[low]` `[reject]` Blind 11: failed rows drop metadata and `transcript_chars` counts characters — the matrix records only `error_class` on failure, and the unit of a character count is the natural reading of the field name.
  - `[medium]` `[defer]` Blind 12: `provision` is barely tested and has no safeguards — grouped with the provisioning items; no lock, deadline or disk check is needed until something can run two workers.
  - `[low]` `[reject]` Blind 13: the worker checks the meeting twice — the second catch only covers a race between the two reads; cosmetic.
  - `[low]` `[reject]` Blind 14: token removal can leave a double space inside a line — the contract forbids only edge whitespace, and timestamp tokens sit at segment edges.
  - `[medium]` `[defer]` Edge 1: a non-empty `.mlmodelc` passes completeness after a partial download — real for an interrupted download; a safe fix needs the real model layout, so it is deferred as unverified.
  - `[maybe-false]` `[defer]` Edge 2: `tokenizer.json` alone passes the tokenizer check — whether WhisperKit then needs `tokenizer_config.json` cannot be settled without a live load; grouped with Edge 1.
  - `[low]` `[reject]` Edge 3: concurrent `transcribe` calls run two decodes on one WhisperKit — same root cause as Blind 4.
  - `[low]` `[reject]` Edge 4: a pending load for another folder can be overwritten — same root cause as Blind 4; no caller loads two folders.
  - `[low]` `[reject]` Edge 5: `CancellationError` becomes a retryable failure — same root cause as Blind 3.
  - `[medium]` `[bad_spec]` Edge 6: `SIGINT` and `SIGTERM` count as retryable crashes, so a user cancel relaunches the worker — real for any caller that runs the worker as a foreground child; folded into the amendment as a retry-policy rule and test.
  - `[low]` `[reject]` Edge 7: no entry-state guard, so a re-run rewinds a later state — `StageRunner` performs no entry check for any stage; that is existing design, and re-runs are the documented recovery path.
  - `[false]` `[reject]` Edge 8: audio should come from `meetings.audio_cache_path` — the story's criterion and AR-PIPE-4 fix the location at `<cache dir>/audio.wav`.
  - `[low]` `[reject]` Edge 9: a zero-frame WAV reaches the transcriber — same root cause as Blind 6.
  - `[medium]` `[defer]` Edge 10: a slow first Core ML load can outlast the 60s budget under a live worker — grouped with Blind 2; the sweep budget is existing design.
  - `[medium]` `[defer]` Edge 11: the sweep fails a meeting waiting in `transcribing` for the next stage — same root cause as Blind 2.
  - `[low]` `[reject]` Edge 12: a failed completion record leaves a valid transcript and exit 2 — needs a state-store failure after 30s of work; the worker reports it and a re-run overwrites the file.
  - `[medium]` `[defer]` Edge 13: two workers can provision into one root at once — grouped with Blind 12; unreachable until something runs two workers.
  - `[medium]` `[defer]` Edge 14: a stalled download hangs the worker before any state row exists — grouped with Blind 12.
  - `[maybe-false]` `[defer]` Edge 15: the download folder may differ from the hard-coded variant folder — the research gave the same folder name, but only a live `provision` settles it; recorded with high severity, unverified.
  - `[low]` `[reject]` Edge 16: the builder does not validate the speaker label — every caller passes the constant `Speaker_1`.
  - `[low]` `[reject]` Edge 17: zero-width characters are not treated as whitespace — Whisper does not emit them in practice, and the fix adds a branch.
  - `[false]` `[reject]` Edge 18: docs still name `TranscribeError` — the architecture's own file tree lists `TranscriberError` under `TranscriberInterface`, and AR-PAT-7's list is generic.
  - `[low]` `[reject]` Edge 19: the last-failure criterion is false for a signal-killed last attempt — already recorded as a deferred item and stated in the matrix; the criterion wording was tightened as part of the amendment.
  - `[medium]` `[defer]` Edge 20: the retry policy has no caller — same root cause as Blind 1.
  - `[false]` `[reject]` Edge 21: the stage overwrites an "immutable" transcript — architecture says a re-run overwrites the artifact; immutability protects it from AI corrections.
  - `[medium]` `[bad_spec]` Verification gap 1: the no-network `WhisperKitConfig` is checked by no default test — flipping `download` to true leaves every default test green; folded into the amendment as `kitConfig(for:)` plus a test.
  - `[medium]` `[bad_spec]` Verification gap 2: `runTranscribe` wiring has no automated test — the trigger for this loopback; the worker's logic moves into `Sources/Transcribe` behind an injected `ensureModel`.
  - `[maybe-false]` `[defer]` Verification gap 3: the `provision` success path is unverified — needs a network and about 1.5 GB; grouped with Edge 15.
  - `[false]` `[reject]` Intent 1: the transcriber success path has no default test — a real model is required and the spec discloses the env-gated live test; the testable part is Verification gap 1.
  - `[low]` `[reject]` Intent 2: the 30-second and 4 GB gates are unverified — same root cause as Blind 8.
  - `[medium]` `[bad_spec]` Intent 3: no test at the CLI-binary surface — same root cause as Verification gap 2.
  - `[medium]` `[defer]` Intent 4: the retry policy has no runtime caller — same root cause as Blind 1.
  - `[false]` `[reject]` Intent 5: "no network" is split across the worker and the stage — deliberate; transcription never downloads and provisioning is a separate step, already a deferred item.
  - `[false]` `[reject]` Intent 6: changes beyond the story's own surface (`.sortedKeys`, lint exemptions, epic context, the `TranscribeError` removal) — each is needed by an acceptance criterion or the build; none is a defect.

### 2026-09-19 — Review pass
- verdicts: 41 findings — high 0, medium 7, low 27, false 5, maybe-false 2
- findings:
  - `[low]` `[reject]` Blind 1: the actor does not serialize transcriptions — carried Blind 4 of the first pass; no caller overlaps two calls.
  - `[low]` `[reject]` Blind 2: cancellation becomes a retryable failure — carried Blind 3 of the first pass; nothing cancels a task in this path.
  - `[false]` `[reject]` Blind 3: the store accepts a tokenizer beside the model that `kitConfig` never points WhisperKit at — WhisperKit 1.1.0 searches `[modelFolder, hub tokenizer folder]` as additional paths (`WhisperKit.swift:476`), so a tokenizer beside the model is found; the `tokenizer.json`-only part is carried Edge 2 of the first pass.
  - `[low]` `[reject]` Blind 4: the download diagnostic is content-free and `provision` is not injectable — the type-name-only rule is deliberate, and the unverified `provision` path is already deferred.
  - `[low]` `[patch]` Blind 5: `TranscriberStrategy`'s doc says an implementation cannot break the transcript contract, but `CanonicalTranscript.init` is public — reworded to state the expectation and that the protocol does not enforce it.
  - `[low]` `[patch]` Blind 6: the NFC assertions are vacuous, since Swift `String ==` is canonical equivalence — the stage, builder and live tests now compare `unicodeScalars`.
  - `[low]` `[reject]` Blind 7: byte-stability tests do not pin nested key order — `.sortedKeys` is applied recursively by Foundation, and the top-level test plus the identical-bytes tests cover the behavior.
  - `[low]` `[reject]` Blind 8: no test runs the stage twice on one meeting — `recordStageTransition` performs an unconditional state update with no transition validation, so a re-entry after `transcription_failed` works; no defect shown.
  - `[low]` `[reject]` Blind 9: zero-length audio and bracketed annotations are unhandled — the zero-length part is carried Blind 6 of the first pass; stripping annotations is a product choice the story does not make.
  - `[low]` `[reject]` Blind 10: peak memory and timing are not measured — carried Blind 8 of the first pass.
  - `[low]` `[reject]` Blind 11: `model_id` can misreport and `transcript_chars` counts characters — carried Blind 11 of the first pass; the id is the configured model by design.
  - `[low]` `[reject]` Blind 12: exit 2 conflates unlike outcomes and one class literal is outside the enum — Decision 1.5 defines 2 as the state error, and `SummarizeStage` uses the same literal pattern.
  - `[medium]` `[patch]` Blind 13: only `SIGINT` and `SIGTERM` are non-retryable, so `SIGHUP` and `SIGQUIT` relaunch a cancelled worker — both added to the cancellation set with tests; retrying `SIGKILL` is Decision 4.2's out-of-memory case and stays.
  - `[low]` `[reject]` Blind 14: artifact file names are duplicated across stages — each stage keeps a private constant today; a shared name is a refactor with no defect.
  - `[low]` `[reject]` Blind 15: tests duplicate the silent-WAV helper and env names — cosmetic.
  - `[low]` `[reject]` Blind 16: nothing documents provisioning or the env vars, and `provisionModelIfMissing` sits in `App/` — the env vars are in the tests' doc comments and the spec; provisioning ownership is a deferred item.
  - `[low]` `[reject]` Blind 17: `epic-4-context.md` will go stale — it is a generated file that says how to regenerate it, and the story spec is the status source.
  - `[medium]` `[defer]` Edge 1: a non-empty `.mlmodelc` passes completeness after a partial download — carried Edge 1 of the first pass.
  - `[maybe-false]` `[defer]` Edge 2: `tokenizer.json` alone passes the tokenizer check — carried Edge 2 of the first pass.
  - `[low]` `[reject]` Edge 3: concurrent `transcribe` calls overlap at the await — carried Blind 4 of the first pass.
  - `[low]` `[reject]` Edge 4: a pending load for another folder can be overwritten — carried Blind 4 of the first pass.
  - `[low]` `[reject]` Edge 5: `CancellationError` becomes a retryable failure — carried Blind 3 of the first pass.
  - `[low]` `[reject]` Edge 6: the retry loop starts a second attempt after the parent task is cancelled — the policy has no caller and is `rethrows`, so a cancellation check would change its signature; the caller's attempt closure is where cancellation belongs.
  - `[low]` `[reject]` Edge 7: a zero-frame WAV reaches the transcriber — carried Blind 6 of the first pass.
  - `[medium]` `[defer]` Edge 8: the stale budget can outlast a slow or idle `transcribing` meeting — carried Blind 2 of the first pass.
  - `[medium]` `[defer]` Edge 9: two workers can provision into one root at once — carried Edge 13 of the first pass.
  - `[low]` `[reject]` Edge 10: the builder does not validate the speaker label — carried Edge 16 of the first pass.
  - `[low]` `[reject]` Edge 11: zero-width characters are not treated as whitespace — carried Edge 17 of the first pass.
  - `[low]` `[reject]` Edge 12: the stage overwrites an existing transcript with no precondition — carried Edge 21 of the first pass; architecture says a re-run overwrites the artifact.
  - `[false]` `[reject]` Edge 13: a signal kill during `ensureModel` leaves the meeting outside the sweep — the state stays `captured`, the normal pre-transcribe state that a later dispatch picks up; nothing is stuck.
  - `[medium]` `[patch]` Edge 14: only `SIGINT` and `SIGTERM` count as cancellation — same root cause as Blind 13, fixed with it.
  - `[low]` `[reject]` Edge 15: a failed download writes a second stderr line — no consumer parses stderr for a line count.
  - `[medium]` `[patch]` Verification gap 1: no default test reaches the real `load` failure mapping — added `aModelThatCannotBeLoadedFailsAsLoadFailedAndLeavesNoPendingLoad` with stub bundles; WhisperKit loads models before the tokenizer, so no network is reached; reuse and shared load stay covered only by the env-gated live test.
  - `[low]` `[reject]` Verification gap 2: `runTranscribe`'s remaining branches (the exit-code translation and the `ensureModel` wiring) have no automated check — the wrapper is about 15 lines, a CLI-level test needs the built binary that `swift test` cannot reach, and the exit-3 path was run against the built binary.
  - `[low]` `[reject]` Intent 1: the subprocess is not tested end to end — same root cause as Verification gap 2.
  - `[false]` `[reject]` Intent 2: the real model load and transcribe run only in a skipped live test — carried Intent 1 of the first pass; the spec discloses the env-gated test, and the testable part is covered by the config and load-failure tests.
  - `[low]` `[reject]` Intent 3: the 30-minute budget test is skipped — carried Blind 8 of the first pass.
  - `[false]` `[reject]` Intent 4: the byte-identical re-run is proven with stubs only — the stub tests pin the writer, and the live test covers the real model; disclosed.
  - `[medium]` `[defer]` Intent 5: the retry policy is tested only against scripted terminations and has no caller — carried Blind 1 of the first pass, already deferred.
  - `[maybe-false]` `[defer]` Intent 6: `provision` is tested only for an unknown model id — carried Verification gap 3 of the first pass, already deferred.
  - `[false]` `[reject]` Intent 7: every utterance is `Speaker_1` — the spec's `Never` list and the first deferred item state it.

## Design Notes

`TranscriberStrategy` has no diarization input, so a transcript from this story can carry one placeholder speaker only. How real diarized labels reach an immutable `transcript.json` is Story 4.2's decision, and it is logged as deferred work rather than guessed here.

Temperature fallback is disabled because Whisper's fallback samples at a raised temperature, which would break the byte-identical re-run the acceptance criteria require. Real audio may show repetition loops that fallback would have recovered, so Story 4.9's evidence decides whether to revisit it. Revisited 2026-09-21: the fallback stays off, and the first-token gate goes with it (Story 4.14, `sprint-change-proposal-2026-09-21.md`).

The worker provisions a missing model before `StageRunner.run` opens Txn A, so a first-run download cannot consume the 60s `transcribing` stale budget. Transcription still runs with `download: false`. Onboarding or `doctor` should own provisioning later.

A signal-killed last attempt writes no Txn B. The 60s stale sweep turns that into `transcription_failed`, and Story 4.7 decides whether to record the exhaustion sooner.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error && swift test --explicit-target-dependency-import-check error` -- expected: all pass; live-model and performance tests skip.
- `make check-lint` -- expected: swiftformat, swiftlint and the custom-rule self-check pass.
- `cd App && tuist generate --no-open && cd .. && xcodebuild -workspace App/Auricle.xcworkspace -scheme auricle-cli -destination "platform=macOS" build` -- expected: succeeds.

**Manual checks (if no CLI):**
- With `AURICLE_WHISPERKIT_MODEL_FOLDER` and a reference WAV set, the env-gated tests run and pass. They were not run in this session without a local model.

## Auto Run Result

Status: done

### Summary

Story 4.1 turns `audio.wav` into an immutable, deterministic `transcript.json` through a WhisperKit-backed `TranscriberStrategy`. `TranscribeStage` runs inside `StageRunner`, records `TranscribeMeta`, and completes into `transcribing`. `TranscribeWorker` owns the worker's ordering and exit codes (0, 3, 75, 2), and `TranscribeRetryPolicy` implements the one retry after a fresh subprocess. Every utterance carries the single label `Speaker_1`, and utterance ranges include their own `Speaker_N: ` prefix. The real model path has never run: the machine has no local model.

### Files changed

- `Sources/Core/CanonicalTranscriptBuilder.swift` -- the one place the transcript invariants are enforced.
- `Sources/Core/CacheArtifactWriter.swift` -- `.sortedKeys`, so identical input gives identical bytes.
- `Sources/Core/Errors.swift` -- unused `TranscribeError` removed.
- `Sources/TranscriberInterface/` -- `TranscriberStrategy`, `TranscriberConfig`, `TranscriberError`.
- `Sources/WhisperKitTranscriber/` -- `WhisperKitTranscriber` actor (shared model load, offline, English only) and `WhisperKitModelStore` (local layout, completeness check, the only download path).
- `Sources/Transcribe/` -- `TranscribeStage`, `TranscribeStageError`, `TranscribeWorker`, `TranscribeRetryPolicy`.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- thin `__internal-stage transcribe` wrapper.
- `Package.swift`, `.swiftlint.yml` -- dependency edits and two test-location composition-root exemptions.
- `Tests/` -- builder, writer, stage, worker, retry policy, model store, config, segment mapping and load-failure tests, plus the summarize-mapper check on built transcripts and two env-gated live tests.
- `_bmad-output/implementation-artifacts/epic-4-context.md` -- the compiled Epic 4 context.

### Review findings

- **Pass 1:** 44 findings. One entry routed `bad_spec`: the worker's branching lived in `App/`, where `swift test` does not reach. The code was reverted and re-derived with that logic in `Sources/Transcribe/TranscribeWorker.swift`. The re-derivation also absorbed two patch-level findings: `kitConfig(for:)` with a test, and `SIGINT`/`SIGTERM` as non-retryable.
- **Pass 2:** 41 findings. Four patches applied: a doc claim in `TranscriberStrategy` reworded (low), vacuous NFC assertions replaced with scalar comparisons (low), `SIGHUP` and `SIGQUIT` added to the cancellation signals (medium), and a test of the real load-failure mapping (medium). Patched by verdict: medium 2, low 2.
- **Deferred (5 new, all in the spec's `deferred` list):**
  - Partial downloads can pass the store's completeness check.
  - `provision` has never run and its result folder name is unverified (high, unverified).
  - `provision` takes no lock, deadline or disk check.
  - `TranscribeRetryPolicy` has no runtime caller until Story 4.7.
  - The 60s stale sweep can fail a finished or slow transcription.
- **Rejected, by reason** (per-finding rows are in the Review Triage Log):
  - No caller can reach the case: cancellation becoming a retryable failure, actor reentrancy and pending-load overwrite, an out-of-range speaker label, zero-width characters, a cancelled parent task before the second attempt, and a second stderr line after a failed download.
  - Existing design or architecture: the stage overwriting an existing transcript, no entry-state check in `StageRunner`, exit 2 covering unlike outcomes, and a shared file-name constant.
  - The story's own scope excludes them: zero-length audio, bracketed annotations, and peak-memory or timing measurement beyond the env-gated test.
  - Refuted: `.sortedKeys` affecting other artifacts (831-test suite green), audio path from `meetings.audio_cache_path` (AR-PIPE-4 fixes the path), docs naming `TranscribeError`, a tokenizer beside the model going unfound (WhisperKit searches the model folder), a signal kill during `ensureModel` leaving a stuck state (the meeting stays in `captured`), and repeated re-entry into the stage (no transition validation exists).
  - Cosmetic or disclosed: duplicated test helpers, the double meeting lookup, stale-prone `epic-4-context.md`, and the live model and 30-minute budget tests skipping by default.
  - `runTranscribe`'s remaining branches have no automated check: the wrapper is about 15 lines and a CLI-level test needs the built binary. The exit-3 and malformed-id paths were run against the built binary.
- **Follow-up review recommended:** true. Two medium entries were patched (retry signal set, load-failure test) and were not re-reviewed after the patch. The unverified risk is the live WhisperKit path: model load, transcription output, model reuse, byte-identical re-run, the 30s budget and `provision`.

### Verification performed

- `swift build --explicit-target-dependency-import-check error` and `swift test --explicit-target-dependency-import-check error`: 848 tests pass. The two env-gated live tests (`aLoadedModelIsReusedAndARerunIsByteIdentical`, `thirtyMinutesOfAudioTranscribesWithinTheBudget`) skip.
- `make check-lint`: passes.
- `tuist generate --no-open` and `xcodebuild -scheme auricle-cli`: build succeeds.
- Built `auricle-cli __internal-stage transcribe <well-formed id, no meeting>`: exit 3, no models directory created. A malformed id exits 1. These runs read the maintainer's real state database and only fetched.
- Every I/O matrix row is covered by a test that ran and passed.

### Residual risks

- Nothing has run against a real WhisperKit model. The 30-second budget, model reuse, the byte-identical re-run on real audio and `provision` are unverified. To run the live tests, set `AURICLE_WHISPERKIT_MODEL_FOLDER`, `AURICLE_REFERENCE_WAV` and `AURICLE_REFERENCE_WAV_30MIN`.
- The first-run model download is triggered silently by the worker with one stderr line.
- Every utterance is `Speaker_1` until Story 4.2 decides how diarized labels reach the immutable transcript (deferred, high).
- Temperature fallback is off for byte-identical re-runs. Real audio may show repetition loops that fallback would have recovered.
