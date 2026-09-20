---
title: 'Story 4.5: ClaudeDiarizationReviewer Concrete Impl Behind Flag'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_commit: '6c5d61ad86c4647c811d73dcc5c501599cd972bc'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `DiarizationReviewerStrategy` has no concrete implementation, so Story 4.3's flag-on path has no reviewer to call. `ClaudeAIReviewers` is an empty placeholder target with no edge to the shared Anthropic client.

**Approach:** Add `ClaudeDiarizationReviewer` to `ClaudeAIReviewers`. It sends one non-streaming Messages API call through `AnthropicHTTPClient` and parses the answer into `DiarizationSuggestion`s with deterministic ids. `Package.swift` gains the `ClaudeSummarizer` dependency.

## Boundaries & Constraints

**Always:**
- The model comes from `AIReviewerConfig.modelID`. The default constant is `claude-haiku-4-5`; the caller (Story 4.3) resolves `diarization_review.model`.
- The system block and the review-instructions block carry `cache_control: ephemeral`. The per-meeting transcript and diarization block is last and has none.
- `suggestionId` is derived from `segment_id` and `kind`, so it is the same across reruns and sheet reopens. The model never chooses ids.
- Log only counts and ids. Transcript text and model output never reach `Log`.
- Cost comes from `AnthropicResponse` and maps to `AIReviewerCost` with `modelID` from the response.
- `reviewedSegmentCount` is the number of diarization segments sent.

**Never:**
- No streaming. No write to `transcript.json`, `diarization.json` or `diarization_suggestions.json` (Story 4.3 owns the write).
- No timeout handling (Story 4.3 owns the 90s budget). No `ReviewDiarization` changes. No config-file reading.
- No suggestion for an unknown `segment_id`, an unknown `kind`, or an over-segmentation carrying splits. The reviewer drops those and keeps the rest.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Flags found | Valid JSON with two suggestions | Two `DiarizationSuggestion`s, ids `sug_<segment>_<kind>`, cost and segment count set | No error |
| Nothing flagged | `{"suggestions": []}` | Empty suggestions; cost still recorded | No error |
| Fenced JSON | Answer wrapped in a code fence | Parsed as if unfenced | No error |
| Bad entry | Unknown `segment_id`, unknown `kind`, or splits on an over-segmentation | That entry is dropped; others kept | Drop is logged by index only |
| Duplicate flag | Two entries for the same segment and kind | First kept | Duplicate dropped |
| Undecodable answer | No text block, or not the expected JSON | Throws `SummarizerError.malformedResponse` | Caller treats it as a benign passthrough |
| Transport failure | Non-2xx, missing key, timeout | `AnthropicHTTPClient` error propagates | No catch here |

</intent-contract>

## Code Map

- `Sources/ClaudeAIReviewers/ManifestPlaceholder.swift` -- delete once the real source exists.
- `Sources/ClaudeSummarizer/AnthropicHTTPClient.swift` -- reuse `AnthropicHTTPClient`, `AnthropicRequest`, `AnthropicResponse` (`usage`, `costUSD`, `model`, opaque `content`); it maps `claude-haiku-4-5` rates.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift` -- pattern to mirror: `JSONSerialization` request body, `cacheControl` computed property, text-block join, private `Decodable` answer, log fields built from counts only.
- `Sources/AIReviewerInterface/{DiarizationReviewerStrategy,DiarizationSuggestion,AIReviewerResult,AIReviewerCost,AIReviewerConfig}.swift` -- protocol and value types to conform to.
- `Sources/DiarizerInterface/DiarizationArtifact.swift` -- `DiarizedSegment` (`seg_<n>` ids, `utteranceIndex` range into transcript utterances).
- `Sources/Core/CanonicalTranscript.swift` -- utterance ranges are UTF-8 byte offsets into `text`, covering the `<Speaker_N>: ` prefix.
- `Sources/SummarizerInterface/SummarizerError.swift` -- `malformedResponse` and friends.
- `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift` -- `URLProtocol` stub pattern keyed by unique endpoint URL.
- `Package.swift` -- `ClaudeAIReviewers` gains `ClaudeSummarizer` and `SummarizerInterface`; `ClaudeAIReviewersTests` gains `Core`, `AIReviewerInterface`, `DiarizerInterface`, `ClaudeSummarizer`, `SummarizerInterface`.

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add the target and test-target dependencies listed in the Code Map -- explicit-import check fails on undeclared edges.
- `Sources/ClaudeAIReviewers/DiarizationReviewPrompt.swift` -- system text, instructions text, and a builder that renders each segment (id, label, start-end seconds, overlap ratio, utterance text) -- keeps prompt text apart from transport.
- `Sources/ClaudeAIReviewers/ClaudeDiarizationReviewer.swift` -- conforms to `DiarizationReviewerStrategy`; builds the request body, sends, decodes, validates entries, builds the result -- the concrete strategy.
- `Sources/ClaudeAIReviewers/ManifestPlaceholder.swift` -- delete.
- `Tests/ClaudeAIReviewersTests/ClaudeDiarizationReviewerTests.swift` -- cover the I/O matrix, id stability, cost mapping, default and overridden model in the request body.
- `Tests/ClaudeAIReviewersTests/PromptCachingContractTests.swift` -- assert marker placement: system and instructions blocks cached; the last (transcript) block has none and no other block after a cached one carries a marker.

**Acceptance Criteria:**
- Given a stubbed 200 response with two flagged segments, when `review` runs, then it returns two suggestions with stable ids, `reviewedSegmentCount` equal to the segment count, and cost matching the response usage.
- Given any request, when the body is inspected, then `model` equals `config.modelID`, `stream` is absent, and the transcript block has no `cache_control`.
- Given `swift build` with `--explicit-target-dependency-import-check error`, when it runs, then it passes.

## Spec Change Log

## Review Triage Log

### 2026-09-20 — Review pass
- verdicts: 34 findings — high 0, medium 2, low 6, false 3, maybe-false 1 (remaining rows are rejects noted below)
- findings:
  - `[medium]` `[patch]` Split content unvalidated (label not in use, start>=end, outside segment, under-segmentation with no splits) — added `splitsAreUsable`; tests `unusableSplits`, updated `badEntries`/`duplicate`.
  - `[medium]` `[patch]` No prompt-renderer tests for nil/out-of-range/multibyte slices — added `DiarizationReviewPromptTests`.
  - `[low]` `[patch]` `undecodable` asserted error type only — now `.malformedResponse`; added missing-`suggestions`-key case.
  - `[low]` `[patch]` Quadratic UTF-8 copy per segment — hoisted into `renderMeetingData`.
  - `[low]` `[patch]` `overlap` undefined in prompt — defined in instructions.
  - `[low]` `[reject]` Cost lost when decode fails — `AnthropicHTTPClient` already logs spend; spec matrix mandates a throw.
  - `[false]` `[reject]` Truncation undetected — `AnthropicHTTPClient` throws `responseTruncated` on `max_tokens`. Large `max_tokens` shortfall is the caller's benign passthrough.
  - `[maybe-false]` `[reject]` Caching below Haiku minimum prefix is a no-op — would be low; the spec mandates the markers and they are harmless. Settle by reading `cache_read_input_tokens` in Story 4.10's live run.
  - `[low]` `[reject]` Prompt injection via transcript, fence with CRLF/prose, null `suggestions`, multi-text-block join, empty model ID, empty segments, oversized transcript, temperature, decode-log detail, empty reasoning, duplicate input ids, dual-kind on one segment, invalid-range warn — the input is the maintainer's own audio, output is validated against known ids, and each fix adds guards for an unlikely case.
  - `[false]` `[reject]` "Coupling to the summarizer" — the epic and readiness-gap proposal mandate the `ClaudeSummarizer` edge.
  - `[false]` `[reject]` "Flag absent / telemetry not written / 90s budget" — epic-4-context assigns flag, telemetry rows and timeout to Story 4.3; the intent contract excludes `ReviewDiarization` changes.
  - `[low]` `[reject]` Remaining test gaps (headers, retry count on 401, cost on decode failure, both kinds on one segment) — covered by `AnthropicHTTPClientTests` or unlikely.
  - `[false]` `[reject]` Log-claim and placeholder-deletion notes — no defect found; intent-alignment reading A matches the diff.

## Design Notes

Ids: `sug_<segment_id>_<under|over>`. The model returns only `segment_id`, `kind`, `reasoning`, `proposed_splits`. Deterministic ids keep per-suggestion Apply tracking valid when a review reruns.

The request body has the shape: `system` = one cached text block; `messages[0].content` = `[instructions (cached), meeting data (uncached)]`.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error && swift test --filter ClaudeAIReviewersTests` -- expected: pass
- `make check-lint` -- expected: pass

## Auto Run Result

Status: done

- **Change:** `ClaudeDiarizationReviewer` and `DiarizationReviewPrompt` in `ClaudeAIReviewers`; `Package.swift` gains `ClaudeSummarizer`, `SummarizerInterface`, `DiarizerInterface`; `.swiftlint.yml` exempts the reviewer's test directory from `composition_root_strategy_bypass`.
- **Files:** `Sources/ClaudeAIReviewers/{ClaudeDiarizationReviewer,DiarizationReviewPrompt}.swift`, `Tests/ClaudeAIReviewersTests/{ClaudeDiarizationReviewerTests,PromptCachingContractTests,DiarizationReviewPromptTests,ReviewerStubSupport}.swift`, placeholder deleted.
- **Review:** 5 patches applied (2 medium, 3 low), 0 deferred, rest rejected with reasons in the triage log.
- **Follow-up review recommended:** false.
- **Verification:** `swift build --explicit-target-dependency-import-check error`, full `swift test` (1179 tests) and `make check-lint` pass. `make check-app` and the Xcode schemes were not run.
- **Residual risks:** prompt answer quality is untested against a live model; the caching markers may fall under Haiku's minimum cacheable prefix. Story 4.10's live run settles both. No caller constructs the reviewer until Story 4.3.
