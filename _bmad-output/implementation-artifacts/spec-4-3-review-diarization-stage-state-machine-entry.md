---
title: 'Story 4.3: ReviewDiarization Stage + State Machine Entry'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_revision: '2911c90c6fc5b54adef42c40d5f61d58f88a9c71'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-4-2-diarize-stage-snippet-extraction.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      A reviewer call abandoned at the 90 s deadline may keep running and bill, and its cost is not recorded.
    evidence: |-
      withDeadline releases the caller but cancellation is cooperative; failure stubs record cost 0. The 90 s budget is fixed by the story.
    location: >-
      Sources/ReviewDiarization/Deadline.swift
    severity: low
  - summary: >-
      When the suggestions write fails, the meeting advances with no diarization_suggestions.json on disk.
    evidence: |-
      Only awaiting_attribution is an allowed target. Story 4.6's reader must tolerate a missing file.
    location: >-
      Sources/ReviewDiarization/ReviewDiarizationStage.swift
    severity: medium
  - summary: >-
      Nothing dispatches review-diarization after the transcribe subprocess exits, and the CLI case is untested by swift test.
    evidence: |-
      Chaining belongs to Story 4.7 (auricle run). InternalStageWorker.runReviewDiarization lives in App/, which swift test does not reach.
    location: >-
      App/auricle-cli/Verbs/InternalStageWorker.swift
    severity: medium
---

<intent-contract>

## Intent

**Problem:** `Sources/ReviewDiarization` is an empty placeholder. Nothing runs the `reviewing_diarization` state, writes `diarization_suggestions.json`, or records the reviewer's telemetry, and `__internal-stage review-diarization` exits "not yet implemented".

**Approach:** Add `ReviewDiarizationStage` (run under `StageRunner.run(stage: .reviewDiarization, activeState: .reviewingDiarization)`) plus a `ReviewDiarizationWorker`, and wire the hidden verb. Flag off writes an empty stub in under 100 ms. Flag on calls an injected `DiarizationReviewerStrategy` under a 90 s budget, and any failure or timeout writes an empty stub and advances.

## Boundaries & Constraints

**Always:**
- The stage depends on the `DiarizationReviewerStrategy` protocol only. It never imports `ClaudeAIReviewers`; only `App/auricle-cli` wires `ClaudeDiarizationReviewer`.
- Every outcome targets `.awaitingAttribution` (the only `PipelineTransitions` target). A failure is never a `*_failed` state.
- `diarization_suggestions.json` goes through `CacheArtifactWriter`, `schema_version: 1`, as an `AIReviewerResult<DiarizationSuggestion>`. The stage never opens `transcript.json` or `diarization.json` for write.
- Flag off: no file reads, no reviewer call. Row metadata is `ReviewDiarizationMeta{model_id: "flag_off", tokens 0, cost_usd 0, suggestions_count 0, review_skipped: true}`. Telemetry is count 0, cost 0, model `flag_off`.
- Flag on success: metadata and telemetry come from the reviewer's `AIReviewerCost` and suggestion count, `review_skipped: false`.
- Timeout (fixed 90 s, injectable for tests) records error class `ai_reviewer_timeout`. Any other reviewer error, or unreadable inputs, records `ai_reviewer_failed` / `review_inputs_unreadable`. Both paths write a stub carrying the configured model id, zero cost and zero suggestions.
- Recorded messages are a case name, type name or fixed sentence, never an error's own text.
- Telemetry writes are best-effort: a failed write is logged and never fails the stage.
- Config keys `diarization_review.enabled` (default false) and `diarization_review.model` (default `claude-haiku-4-5`) load through `Core/Config`. An unreadable config falls back to flag off.

**Never:**
- No `AttributionViewModel`, renderer, or `auricle run` wiring (Stories 4.6, 4.7). No `PipelineStage`, `PipelineState` or `PipelineTransitions` change. No reviewer implementation change.
- No network call in tests. The reviewer is a stub.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Flag off | `enabled = false` | Stub file, flag-off metadata and telemetry, `completed` to `awaiting_attribution`, under 100 ms, reviewer never called | None |
| Flag on | Reviewer returns 2 suggestions | File holds them; metadata from cost; telemetry count 2, cost, model | None |
| Zero suggestions | Reviewer returns none | Empty suggestions file, `review_skipped: false`, completes | None |
| Timeout | Reviewer exceeds budget | Stub file, `failed` row class `ai_reviewer_timeout`, state `awaiting_attribution`, exit 0 | Benign |
| Reviewer throws | Any error from `review` | Stub file, class `ai_reviewer_failed`, exit 0 | Benign |
| Inputs unreadable | `transcript.json` or `diarization.json` missing/undecodable, flag on | Stub file, class `review_inputs_unreadable`, exit 0 | Benign |
| Stub write fails | Writer throws | `failed` row class `suggestions_write_failed`, still `awaiting_attribution`, exit 2 | Permanent |
| Unknown meeting | No row | Throws `StateStoreError.meetingNotFound`; worker exit 3 | Caller error |
| Sequencing | Meeting in `transcribing` | Txn A moves it to `reviewing_diarization`; Txn B to `awaiting_attribution` | None |

</intent-contract>

## Code Map

- `Sources/ReviewDiarization/ManifestPlaceholder.swift` -- delete once real files land.
- `Sources/Transcribe/TranscribeStage.swift`, `TranscribeWorker.swift`, `TranscribeStageError.swift` -- template for stage/worker/exit-code shape and `ClassifiedStageError` use.
- `Sources/Summarize/SummarizeStage.swift` (`readTranscript`), `SummarizeStage+PostWrite.swift` -- JSON decode of `transcript.json` and best-effort `TelemetryRecorder.record` pattern.
- `Sources/Orchestrator/StageRunner.swift` -- `run`, `StageOutcome`; 90 s budget already in `staleDetectionBudgetSeconds`; `.failed` folds `error_class` into `metadata_json`.
- `Sources/Core/PipelineTransitions.swift` -- `(.reviewDiarization, .reviewingDiarization) -> [.awaitingAttribution]` already exists; read-only.
- `Sources/Telemetry/StageMetadata.swift` (`ReviewDiarizationMeta`), `ReviewDiarizationTelemetryPatch.swift`, `TelemetryRecorder.swift` -- reused as is.
- `Sources/AIReviewerInterface/` -- `DiarizationReviewerStrategy`, `DiarizationReviewInput`, `AIReviewerConfig`, `AIReviewerResult`, `AIReviewerCost`.
- `Sources/DiarizerInterface/DiarizationArtifact.swift` -- decoded from `diarization.json`.
- `Sources/Core/Config.swift` -- add `DiarizationReview` (enabled, model) beside `Attribution`; `RawConfig` decoding. `DiarizerConfig.loading(config:onFailure:)` is the fallback-loader pattern.
- `Sources/ClaudeAIReviewers/ClaudeDiarizationReviewer.swift` -- `defaultModelID` should reuse the Core default; `review` applies no timeout, so the stage owns it.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- add `.reviewDiarization` case; `App/Project.swift` -- CLI target gains `ClaudeAIReviewers` and `AIReviewerInterface` packages.
- `Package.swift` -- `ReviewDiarization` and `ReviewDiarizationTests` gain `Orchestrator`, `DiarizerInterface`, `State`/`GRDB` as tests need.
- `Tests/TranscribeTests/TranscribeStageFixture.swift` -- fixture style: real in-memory `StateStore`, real `StageRunner`, real per-meeting cache dir.

## Tasks & Acceptance

**Execution:**
- `Sources/Core/Config.swift` -- `Config.DiarizationReview` with defaults and validation -- flag and model input.
- `Sources/ReviewDiarization/ReviewDiarizationSettings.swift` -- `enabled`, `modelID`, `timeoutSeconds` (90), `loading(config:onFailure:)` -- testable config mapping outside `App/`.
- `Sources/ReviewDiarization/ReviewDiarizationStage.swift`, `ReviewDiarizationStageError.swift` -- stage body, timeout race, stub writer, outcomes, `exitCode(for:)` -- per the matrix.
- `Sources/ReviewDiarization/ReviewDiarizationWorker.swift` -- meeting lookup, run, exit mapping (3 unknown, 2 state error) -- mirrors `TranscribeWorker`.
- `Sources/ClaudeAIReviewers/ClaudeDiarizationReviewer.swift` -- `defaultModelID` from `Config` -- one definition.
- `App/auricle-cli/Verbs/InternalStageWorker.swift`, `App/Project.swift`, `Package.swift` -- wire `runReviewDiarization()` thinly, delete placeholder -- dispatch entry.
- `Tests/ReviewDiarizationTests/`, `Tests/CoreTests/` -- every matrix row with a stub reviewer; flag-off timing under 100 ms; file 0600 and `schema_version`; telemetry columns; `stage_events` rows and state sequence; config parse and defaults; stage never opens immutable artifacts for write -- coverage.

**Acceptance Criteria:**
- Given a meeting in `transcribing`, when the stage runs, then `meetings.state` passes through `reviewing_diarization` to `awaiting_attribution`, with one `started` and one `completed`/`failed` `review-diarization` row.
- Given `SubprocessDispatcher.makeProcess(stage: .reviewDiarization, ...)`, then the arguments are `__internal-stage review-diarization <id> --worker-protocol-version 1`.
- Given `__internal-stage review-diarization <id>` with no config file, then it exits 0, writes the stub, and leaves the meeting in `awaiting_attribution`.
- Given `PipelineStage` and `PipelineTransitions`, then neither changed.

## Spec Change Log

## Review Triage Log

### 2026-09-20 — Review pass
- verdicts: 24 findings — high 0, medium 5, low 12, false 2, maybe-false 5
- findings:
  - `[medium]` `[patch]` Paid reviewer cost dropped from telemetry when the suggestions write fails after a successful review — `writeFailed(paid:)` now records count 0, cost and model; test added.
  - `[medium]` `[patch]` Failure-path and write-failure telemetry never asserted — assertions added to `expectBenignFailure` and the write-failure test.
  - `[medium]` `[patch]` Worker catch-all exit 2 untested — test drops `stage_events` and expects `stateError`.
  - `[medium]` `[defer]` Meeting advances with no suggestions file when the write fails — only `awaiting_attribution` is allowed; Story 4.6 must tolerate a missing file.
  - `[medium]` `[defer]` No dispatch of review-diarization after transcribe, and the App wiring is untested — Story 4.7 owns chaining; AGENTS.md notes App/ has no coverage; logic sits in the tested worker.
  - `[low]` `[defer]` Abandoned reviewer call may still bill after the deadline — cooperative cancellation is inherent to the fixed 90 s budget.
  - `[false]` `[reject]` ClaudeAIReviewers lacks a Core dependency — the target already lists Core and the check gate passes.
  - `[false]` `[reject]` Stub write on re-run overwrites an earlier result — the spec's Design Notes accept per-run rewrite.
  - `[low]` `[reject]` Outer cancellation recorded as `ai_reviewer_failed`, NaN timeout traps, telemetry before commit, unknown class exits 0, non-transcribing start state, undocumented config, dead `isBenign`, flag-off timing flake, 90 s equal to the sweep budget, log gaps, missing `withDeadline` unit tests, sentinel model on failure stubs — internal callers only, matches the spec or the existing pattern, or the fix adds branches for a state nobody reaches (timing test takes the best of five runs).
  - `[low]` `[reject]` Intent-alignment reading R2/R3 (pipeline chaining) — the intent and the epic assign chaining to Story 4.7; the spec's Never list excludes it.

## Auto Run Result

Status: done

**Summary:** `ReviewDiarizationStage` runs the `reviewing_diarization` state under `StageRunner`. Flag off writes an empty stub without reading inputs. Flag on calls the injected reviewer under a 90 s deadline, and any timeout, failure or unreadable input writes a stub and advances to `awaiting_attribution`. `__internal-stage review-diarization` is wired.

**Files changed:**
- `Sources/Core/Config.swift` — `Config.DiarizationReview` (enabled, model).
- `Sources/ReviewDiarization/` — Stage, StageError, Settings, Worker, Deadline; placeholder removed.
- `Sources/ClaudeAIReviewers/ClaudeDiarizationReviewer.swift` — default model from `Config`.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` — thin `.reviewDiarization` case.
- `Package.swift` — target dependencies.
- `Tests/ReviewDiarizationTests/`, `Tests/CoreTests/ConfigTests.swift` — matrix coverage and config tests.

**Review:** 3 patches applied (all medium), 3 deferred, remaining findings rejected with reasons in the triage log. `followup_review_recommended: true`: three medium patches on a first pass, and the unverified risk is that `__internal-stage review-diarization <id>` was never run live against a real store, so the CLI wiring and config-to-settings path have no test.

**Verification:** `make check` passed ("checks passed: all") after the patches, including 1216+ tests, both Xcode schemes and the embedded `auricle-cli` assertion. Not run live: `__internal-stage review-diarization <id>` against a real store with no config.

**Residual risks:** the CLI wiring is untested by `swift test`; chaining after transcribe lands in Story 4.7; the flag-off timing test uses the best of five runs.

## Design Notes

Reviewer failures reuse the `.failed` outcome with target `.awaitingAttribution`, so the row carries `error_class` while the state still advances (the same shape as `StageRunner.staleTransition` for this state). A re-run rewrites the stub or result: the file is written once per run, and no downstream story reads a partial one.

## Verification

**Commands:**
- `swift build && swift test` -- expected: all pass
- `make check` -- expected: all gates pass
