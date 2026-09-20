---
title: 'Story 4.4: AIReviewerInterface Protocol Family + Null TranscriptionReviewerStrategy'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'dispatch'
baseline_commit: '7b26bba02dadbc3f2386d92dd5fa46081934f1b8'
review_loop_iteration: 0
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `AIReviewerInterface` holds only `JargonCorrectionStrategy`, so Stories 4.3 and 4.5 have no base protocol, result type, suggestion schema or immutability guard to build on.

**Approach:** Add the `AIReviewerStrategy` base protocol, `Suggestion`, `AIReviewerResult`, `AIReviewerCost` and `AIReviewerConfig`. Add the diarization and transcription sibling protocols with their suggestion schemas, make `JargonCorrection` a `Suggestion`, and add a test that fails when reviewer or stage code writes `transcript.json` or `diarization.json`.

## Boundaries & Constraints

**Always:**
- Cache-artifact types use explicit snake_case `CodingKeys` (AR-PAT-2). `AIReviewerResult` and `TranscriptionSuggestion` schemas carry `schemaVersion` with value 1.
- `AIReviewerStrategy.Input` and `.Output` are `Codable & Sendable`. Tuples are not `Codable`, so each sibling's input is a named struct holding the two values the epic lists.
- `DiarizationArtifact` does not exist until Story 4.2. `DiarizationReviewInput` is generic over the diarization type, and `DiarizationReviewerStrategy` declares `associatedtype Diarization: Codable & Sendable`. Story 4.2 or 4.5 binds it.
- `JargonCorrectionStrategy`, `GlossaryJargonCorrector` and their behavior stay unchanged. `JargonCorrection` only gains `Suggestion` conformance.
- `AudioFingerprint` is a minimal schema-only struct: `schema_version`, `audio_sha256`, `duration_seconds`.

**Never:**
- No concrete reviewer, no `transcription_suggestions.json` writer, no `DiarizationArtifact`, no `ReviewDiarization` or `ClaudeAIReviewers` changes (Stories 4.2, 4.3, 4.5, Epic 10).
- No forcing of the glossary path through `review(input:config:)`.
- No new package dependency.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Suggestion round trip | Any suggestion type, result wrapper, cost or fingerprint encoded then decoded | Equal value; JSON keys are the declared snake_case set | Decode of a missing key throws |
| Immutable artifact write | A non-owner source file passes `transcript.json` or `diarization.json` (literal or constant) to a write call | `ImmutabilityContractTests` fails and names the file | N/A |
| Owner or read-only use | `Sources/Transcribe` writes `transcript.json`; `Sources/Summarize` reads it | Test passes | N/A |
| Detector self-check | Synthetic violating source text | Detector reports a violation | N/A |

</frozen-after-approval>

## Code Map

- `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` -- holds `ByteRange`, `JargonCorrection` (already has `suggestionId`, `reasoning`); add the `Suggestion` conformance beside it.
- `Sources/Core/CanonicalTranscript.swift` -- `Codable, Sendable` input value for both new siblings.
- `Sources/TranscriberInterface/TranscriberConfig.swift` -- config style to mirror (`Sendable, Equatable`, defaulted init).
- `Tests/AIReviewerInterfaceTests/JargonCorrectionTests.swift` -- test style; Swift Testing.
- `Sources/Transcribe/TranscribeStage.swift` -- the only current writer of `transcript.json`; the detector must allow it.
- `Sources/Summarize/SummarizeStage.swift` -- reads `transcript.json` and writes `summary.json` through `CacheArtifactWriter`; must not be flagged.
- `Package.swift` -- target already depends on `Core`; the test target needs no new dependency.
- `_bmad-output/planning-artifacts/architecture.md` (Decision 5.1, 5.3, `segment_splits` example) -- source of the shapes.

## Tasks & Acceptance

**Execution:**
- [x] `Sources/AIReviewerInterface/Suggestion.swift`, `AIReviewerCost.swift`, `AIReviewerConfig.swift`, `AIReviewerResult.swift`, `AIReviewerStrategy.swift` -- base protocols and value types; `AIReviewerCost` holds `input_tokens`, `output_tokens`, `cost_usd`, `model_id`; `AIReviewerConfig` holds `modelID`.
- [x] `Sources/AIReviewerInterface/DiarizationSuggestion.swift`, `DiarizationReviewerStrategy.swift` -- `DiarizationSuggestion` (`kind` under/over-segmentation, `segment_id`, `proposed_splits[]` of `{start, end, speaker_label}`) and the generic-input sibling protocol.
- [x] `Sources/AIReviewerInterface/TranscriptionSuggestion.swift`, `AudioFingerprint.swift`, `TranscriptionReviewerStrategy.swift` -- schema, input struct and protocol, with no implementation.
- [x] `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` -- `extension JargonCorrection: Suggestion {}`.
- [x] `Tests/AIReviewerInterfaceTests/SuggestionSchemaRoundTripTests.swift` -- round trip every type and assert key sets.
- [x] `Tests/AIReviewerInterfaceTests/ImmutabilityContractTests.swift` -- scan `Sources/` and `App/` for write calls whose argument names an immutable artifact; owners `Sources/Transcribe` and `Sources/Diarize` are exempt; include a detector self-check.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` -- leave unchanged (AGENTS.md: spec frontmatter is the ground truth).

**Acceptance Criteria:**
- Given the target, when it builds, then a type can conform to `AIReviewerStrategy` and `DiarizationReviewerStrategy` and a mock can return an `AIReviewerResult`.
- Given `JargonCorrection`, when used as `any Suggestion`, then `suggestionId` and `reasoning` read through the protocol.
- Given the repo, when `swift test` runs, then `ImmutabilityContractTests` passes and a synthetic violation fails the detector.

## Implementation Notes

- `ProposedSplit` sits at top level: SwiftLint allows one nesting level and its `CodingKeys` would be the second.
- `AIReviewerStrategy.Output` also requires `Equatable`, so `AIReviewerResult` is `Equatable`.
- `AIReviewerResult` carries `schema_version`; `TranscriptionSuggestion` entries do not, because the wrapper is the file schema.
- The detector treats `moveItem`, `copyItem` and `replaceItemAt` as writes, since each can replace an immutable artifact.
- `make check` passed.

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Evidence |
|---------|---------|----------|
| `TranscriptionSuggestion` doc claims a `schema_version` it lacks | low, patched | The wrapper carries it; the comment now says so. |
| `forUpdating` alone starts the call span at the wrong paren | medium, patched | Leftmost regex match began at `forUpdating`; now `FileHandle(forUpdating` and `FileHandle(forWriting`. |
| Move, copy and replace APIs not detected | medium, patched | Added to the write-call pattern with a test. |
| Magic file-count sanity check | low, patched | Replaced with a known-file check. |
| `charRange` unit unclear | low, patched | Comment states UTF-8 byte offsets. |
| Decode ignores newer `schema_version`, and no value validation (NaN, ranges, duplicate ids, counts) | false | Schema-only story; no reader exists yet, and the spec sets no validation rule. |
| Unknown `kind` fails the whole decode | false | Only auricle's own reviewer writes the file. |
| Scan misses cross-file constants, comments and strings, brace-in-string | false | Textual scan is documented in Design Notes; a fix adds a parser for no reachable case. |
| `owners[name] ?? ""` disables the check | false | Names come from the `owners` keys, so the lookup cannot miss. |
| No typed reviewer error | false | `AIReviewerError` is not in the story's acceptance criteria. |

## Design Notes

The immutability detector is textual and per call site: it reads the text of each write call up to its closing parenthesis. It cannot follow a URL built on one line and written on another. Lint at code review covers that gap, as the architecture states.

## Verification

**Commands:**
- `swift build && swift test --filter AIReviewerInterfaceTests` -- expected: pass
- `make check` -- expected: exit 0
