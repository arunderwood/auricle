---
title: 'ClaudeCitationsSummarizer + CitationGroundingValidator + Canonicalization Invariant Tests'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: '9b5639115eec6eeec4bc6183f316352285f9b3aa'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-1-summarizerinterface-protocol-normalized-summarywithgrounding-output.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-2-summarizationpromptbuilder-file-backed-prompt-set-glossary-injection-drift-snapshot-tests.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-anthropichttpclient-keychainapikey-retry-backoff.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-4-claudesubstringsummarizer-substringgroundingvalidator.md',
]
warnings: ['oversized']
deferred:
  - summary: >-
      Four near-identical private URLProtocol stub classes now exist across
      ClaudeSummarizerTests and SummarizeTests, with no shared TestSupport
      helper to reduce the duplication.
    evidence: |-
      AnthropicHTTPClientTests.swift, ClaudeSubstringSummarizerTests.swift,
      ClaudeCitationsSummarizerTests.swift, and CrossModeFixtureTests.swift
      each declare their own file-local register/unregister/startLoading
      URLProtocol stub. The per-file convention was already a deliberate
      choice from Story 3.4's own spec; consolidating it now would touch the
      two pre-existing files too, a cross-cutting test-infrastructure change
      outside any single story's scope.
    location: >-
      Tests/ClaudeSummarizerTests/, Tests/SummarizeTests/
    severity: low
---

<intent-contract>

## Intent

**Problem:** `ClaudeSubstringSummarizer` (Story 3.4) is the fallback/local-LLM path, but Citations is the MVP default (Decision 3.6) — nothing yet calls Anthropic's Citations API, and Decision 3.4's build-time canonicalization invariant (guarding against the two strategies silently disagreeing about what a character offset means) has no test at all.

**Approach:** Add `ClaudeCitationsSummarizer` + `CitationGroundingValidator` to `Sources/ClaudeSummarizer/`, extend `Sources/Summarize/Prompts/summarize/citations.md` with the empirically load-bearing `source_block_index` item-JSON-shape instruction (architecture.md Decision 3.2 — without it Anthropic returns zero real citations), and add the two build-time contract tests Decision 3.4 requires: `Tests/CoreTests/CanonicalTranscriptContractTests.swift` and `Tests/SummarizeTests/CrossModeFixtureTests.swift`.

## Boundaries & Constraints

**Always:**
- `ClaudeCitationsSummarizer` is a `struct: SummarizerStrategy`, DI-constructed identically to `ClaudeSubstringSummarizer` (`init(httpClient: AnthropicHTTPClient = AnthropicHTTPClient())`), calling `SummarizationPromptBuilder.build(..., mode: .citations)` with `attendees: []`, `promptDir: nil` (same fixed-signature reasoning as Story 3.4).
- Request body: same `system`/glossary/attendee-context block assembly as `ClaudeSubstringSummarizer.buildRequestBody` (shared `cache_control` placement rule), but the transcript is submitted as a **document content block**, not a plain text block: `{"type": "document", "source": {"type": "content", "content": [one {"type":"text","text":...} block per transcript.utterances, sliced by that utterance's UTF-8 byte [start,end)]}, "title": <a fixed documented stand-in string, e.g. "Meeting transcript" — no AC fixes this value>, "citations": {"enabled": true}}`. Expose the per-utterance slicing as an internal (non-`private`) static function on `ClaudeCitationsSummarizer` (e.g. `contentBlockTexts(for:)`) — the canonicalization contract test calls this directly via `@testable import` so it exercises the real segmentation code, not a re-derived copy.
- `citations.md` must instruct the model to include a `source_block_index` field per item, appended after the existing locked sentence (keep "Use Anthropic Citations to ground each item." verbatim as a prefix; append, don't replace) — architecture.md Decision 3.2 measured this field's presence as load-bearing (replicated 5x): without it the model writes citation-shaped prose with zero real citations attached. Update `Tests/SummarizeTests/Snapshots/prompts/citations.txt` and both hard-coded literals in `Tests/SummarizeTests/PromptBuilderSnapshotTests.swift` (the `citationsAddendum` constant and the `.hasSuffix(...)` assertion) to match the new full file content.
- Decode `response.content` as an ordered array of raw blocks (`[[String: Any]]`, `type: "text"` filter, same style as Story 3.4). Concatenate every block's `text` to decode the JSON answer (`{summary, action_items: [{text, source_block_index}], decisions: [...]}` — same wrapper shape as substring's, `source_block_index` decoded but never used for grounding, per Decision 3.2: "a cross-check, never the grounding"). Separately collect, in block order, every block whose `citations` array is non-empty, taking that block's first citation object — this is the **positional** association architecture.md documents ("the cited response block *is* the item's text value").
- Let `itemCount = actionItems.count + decisions.count`. If `itemCount == 0`, return empty arrays, no error. Else: if zero citation-bearing blocks were found, throw `SummarizerError.citationsUnavailable` ("no Citations data when Citations was requested"). Else if the citation-bearing-block count != `itemCount`, throw `SummarizerError.malformedResponse` ("empty array when items are present" manifests as a per-item count mismatch, not a per-item drop — Citations has no soft-drop path). Else zip `actionItems + decisions` 1:1 (declaration order) against the collected citations in order; for each pair, parse `start_block_index`/`end_block_index` (`Int`) from the citation dict into a `CitationBlockLocation` (missing/mistyped → `.malformedResponse`, "structurally bad payload") and call `CitationGroundingValidator.validate(citation:in:)`, which itself throws `.malformedResponse` on out-of-range bounds. A thrown error here aborts the whole call (no partial output) — Citations is all-or-nothing per call, unlike substring's per-item drop-and-continue; a fresh call is what `SummarizerOrchestrator` (Story 3.6) retries via fallback.
- `CitationGroundingValidator.validate(citation: CitationBlockLocation, in: CanonicalTranscript) throws -> GroundingPointer` (throws, non-optional return — deliberately asymmetric with `SubstringGroundingValidator`'s nil-returning shape, since "not found" isn't expressible for a bounds-checked index the same way it is for a substring search). Bounds: `startBlockIndex >= 0`, `endBlockIndex <= transcript.utteranceCount`, `startBlockIndex < endBlockIndex`; on success, `GroundingPointer(transcriptStart: transcript.utterances[startBlockIndex].start, transcriptEnd: transcript.utterances[endBlockIndex - 1].end, sourceMethod: .citations)` — no UTF-8 conversion needed here, since `Utterance.start/end` are already the same UTF-8-byte-offset convention `GroundingPointer` uses. Declare `CitationBlockLocation` (`startBlockIndex`, `endBlockIndex`, both `Int`) in this same file.
- On success, assemble `SummaryWithGrounding` identically to Story 3.4 (`schemaVersion: 1`, `groundingMethod: .citations`, `cost` from `response.usage`/`.thinkingTokens`/`.costUSD`).
- `Package.swift`: add `"ClaudeSummarizer"` to `CoreTests`'s and `SummarizeTests`'s dependency lists — test-only edges, empirically verified acyclic and sufficient (transitively unlocks `SummarizerInterface` too; no separate edge needed for it). No other target's dependency list changes.
- `.swiftlint.yml`'s `composition_root_strategy_bypass` `excluded` list: add `".*/Tests/SummarizeTests/.*\\.swift$"` (same directory-scoped-per-test-target precedent Story 3.4 used for `Tests/ClaudeSummarizerTests/`) — `CrossModeFixtureTests.swift` must construct `ClaudeCitationsSummarizer`/`ClaudeSubstringSummarizer` directly. `CoreTests` needs no such exclusion: it only calls `SubstringGroundingValidator`/`CitationGroundingValidator`, neither of which matches the rule's `Claude[A-Z]\w*` pattern.
- Log a diagnostic (no content fields) before rethrowing on a JSON-decode failure, matching `ClaudeSubstringSummarizer`'s own established pattern. Never log `cited_text` or any other citation-dict field carrying transcript content.

**Never:**
- Don't request structured JSON via `output_config.format` — Anthropic returns 400 when combined with `citations.enabled: true` (measured, Decision 3.2).
- Don't validate the model's own `source_block_index` against the real citation's block index, and don't guard `transcript.utterances.isEmpty` in the document builder — no AC requires either; same "documented gap, not a defect" posture Story 3.4 established for analogous unrequested checks.
- Don't validate the response citation's `document_index` (always `0` for this single-document request) — out of scope, no AC references it.
- Don't build `SummarizerOrchestrator` or fallback-dispatch logic (Story 3.6's scope).
- Don't implement `CanonicalTranscript`'s NFC/LF/speaker-label normalization itself (that's the transcribe stage's job, not yet built) — the contract tests below assert internal consistency of already-well-formed values, not that a real transcript happens to be normalized.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| All items cited | Stub 200, one real citation per item, in-bounds indices | Every item returned, `sourceMethod == .citations`, correct offsets | No error |
| No citations at all | Stub 200, items present, zero blocks carry `citations` | — | `SummarizerError.citationsUnavailable` |
| Partial/mismatched citation count | Stub 200, citation-bearing-block count != item count | — | `SummarizerError.malformedResponse` |
| Out-of-range block index | Stub 200, one citation's `end_block_index > transcript.utteranceCount` | — | `SummarizerError.malformedResponse` |
| Structurally malformed JSON | Stub 200, text isn't valid JSON / missing fields | — | `SummarizerError.malformedResponse` |
| Empty arrays | Stub 200, `action_items: []`, `decisions: []` | Empty arrays | No error |
| Citation index round-trip | `CitationGroundingValidator.validate`, valid single-utterance range | `GroundingPointer` matching that utterance's `[start, end)` | No error |
| Cross-validator agreement | Same utterance, `SubstringGroundingValidator.validate(quote: utteranceText)` vs `CitationGroundingValidator.validate(citation: thatUtteranceIndex)` | Identical `GroundingPointer` | No error |

</intent-contract>

## Code Map

- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift` -- new -- the strategy: document-block request construction, citation-bearing-block extraction, positional item/citation zipping, `SummaryWithGrounding` assembly.
- `Sources/ClaudeSummarizer/CitationGroundingValidator.swift` -- new -- `CitationBlockLocation` + `validate(citation:in:) throws -> GroundingPointer`.
- `Sources/Summarize/Prompts/summarize/citations.md` -- modify -- append the `source_block_index` instruction after the existing locked sentence.
- `Tests/SummarizeTests/Snapshots/prompts/citations.txt` -- modify -- match the new `citations.md` content.
- `Tests/SummarizeTests/PromptBuilderSnapshotTests.swift:113,173` -- modify -- update the two hard-coded `"Use Anthropic Citations to ground each item."` literals to the new full addendum text.
- `Package.swift:124` (`CoreTests`), `:144` (`SummarizeTests`) -- modify -- add `"ClaudeSummarizer"` to both dependency lists (verified acyclic and sufficient by direct experiment: `swift build --explicit-target-dependency-import-check error --target CoreTests` compiled clean with `import ClaudeSummarizer` + `import SummarizerInterface` both present, no separate `SummarizerInterface` edge required).
- `.swiftlint.yml` -- modify -- add `Tests/SummarizeTests/` to `composition_root_strategy_bypass`'s `excluded` list (see Boundaries).
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift`, `SubstringGroundingValidator.swift` -- existing, read-only -- the sibling strategy's shape/conventions to mirror (DI init, `buildRequestBody` cache-control placement, decode-then-log-then-throw pattern, drop-field-builder style).
- `Sources/ClaudeSummarizer/AnthropicHTTPClient.swift` -- existing, read-only -- `send(_:)`, `AnthropicRequest`, `AnthropicResponse.content/.usage/.thinkingTokens/.costUSD`.
- `Sources/Summarize/SummarizationPromptBuilder.swift` -- existing, read-only -- `build(mode: .citations)`.
- `Sources/SummarizerInterface/{SummarizerStrategy,SummaryWithGrounding,GroundedItem,GroundingPointer,GroundingMethod,SummarizerError}.swift` -- existing, read-only -- fixed contract; `GroundingPointer`'s offsets and `CanonicalTranscript.Utterance.start/end` share one UTF-8-byte-offset convention (no translation needed between them).
- `Sources/Core/CanonicalTranscript.swift` -- existing, read-only -- `Utterance.speakerLabel/start/end`, `utteranceCount`.
- `Tests/CoreTests/CanonicalTranscriptTests.swift` -- existing, read-only -- the Story 3.1 round-trip test this story's new contract-test file extends conceptually (separate file, per epics.md's explicit path).
- `_bmad-output/planning-artifacts/architecture.md:1362-1386` (Decision 3.2, Citations half) -- request/validation shape, the `source_block_index` empirical finding.
- `_bmad-output/planning-artifacts/architecture.md:1427-1452` (Decision 3.4) -- the three canonicalization-invariant properties and the cross-mode fixture test.
- `_bmad-output/planning-artifacts/epics.md:1494-1533` -- authoritative ACs for this story.
- `_bmad-output/planning-artifacts/research/technical-claude-code-agent-sdk-session-capability-2026-09-16/evidence/citation_item_association_result.json` -- read-only -- real API response shapes proving the positional block-splitting mechanics (arm A: 0 citations without the field; arm B: 4/4 correct with it).

## Tasks & Acceptance

**Execution:**
- `Sources/Summarize/Prompts/summarize/citations.md`, `Tests/SummarizeTests/Snapshots/prompts/citations.txt`, `Tests/SummarizeTests/PromptBuilderSnapshotTests.swift` -- modify -- add the `source_block_index` instruction and its three matching literal updates.
- `Package.swift` -- modify -- add `"ClaudeSummarizer"` to `CoreTests` and `SummarizeTests`.
- `.swiftlint.yml` -- modify -- add `Tests/SummarizeTests/` to `composition_root_strategy_bypass`'s `excluded` list.
- `Sources/ClaudeSummarizer/CitationGroundingValidator.swift` -- new -- implement per Boundaries.
- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift` -- new -- implement per Boundaries.
- `Tests/ClaudeSummarizerTests/CitationGroundingValidatorTests.swift` -- new -- valid range, `start < 0`, `end > utteranceCount`, `start >= end`, multi-utterance span.
- `Tests/ClaudeSummarizerTests/ClaudeCitationsSummarizerTests.swift` -- new -- one test per I/O-matrix row against a stubbed `URLProtocol` (file-local stub, not shared with `ClaudeSubstringSummarizerTests`'s private one); at least one test asserts the sent request's document content block matches `transcript.utterances` 1:1.
- `Tests/CoreTests/CanonicalTranscriptContractTests.swift` -- new -- Decision 3.4's three properties: (a) round-trip byte-identical text; (b) `ClaudeCitationsSummarizer.contentBlockTexts(for:)` (via `@testable import ClaudeSummarizer`) matches each utterance's own `[start,end)` slice exactly; (c) `SubstringGroundingValidator.validate(quote:)` and `CitationGroundingValidator.validate(citation:)` produce an identical `GroundingPointer` for the same underlying utterance.
- `Tests/SummarizeTests/CrossModeFixtureTests.swift` -- new -- one golden transcript run through both strategies (stubbed responses producing equivalent items via each mode's own shape), asserting byte-identical rendered output (`"\(item.text)\n> \(transcript.text[start..<end])"` per item, grounding-method-agnostic).

**Acceptance Criteria:**
- Given a stubbed 200 with a real citation on every item, when `summarize()` runs, every item returns `grounding.sourceMethod == .citations` with byte offsets matching the cited utterance's own `[start, end)`.
- Given a stubbed 200 with zero citations anywhere in the response, when `summarize()` runs, it throws `SummarizerError.citationsUnavailable`.
- Given a stubbed 200 with an out-of-range or mismatched-count citation, when `summarize()` runs, it throws `SummarizerError.malformedResponse`.
- Given `swift build --explicit-target-dependency-import-check error`, it compiles with exactly the two new test-only edges (`CoreTests → ClaudeSummarizer`, `SummarizeTests → ClaudeSummarizer`) and no production-target edges.
- Given the full test suite, `CanonicalTranscriptContractTests` and `CrossModeFixtureTests` both pass, proving the two grounding strategies agree on character-offset semantics for equivalent input.

## Spec Change Log

## Review Triage Log

### 2026-09-17 — Review pass
- verdicts: 23 findings — high 0, medium 4, low 10, false 9, maybe-false 0
- findings:
  - `[medium]` `[patch]` (Blind Hunter) `groundedSummary` and its callees (`citationBlockLocation`, `CitationGroundingValidator.validate`) throw `citationsUnavailable`/`malformedResponse` with zero log trace, unlike `ClaudeSubstringSummarizer`'s decode-failure path and `AnthropicHTTPClient`'s established log-before-throw pattern — patch: add a `log.warn` call (no content fields) immediately before each throw in `groundedSummary`.
  - `[medium]` `[patch]` (Blind Hunter) No test exercises the request shape when `glossary` and `attendeeContext` are both empty — the exact gap Story 3.4's own review found and patched for the sibling `ClaudeSubstringSummarizerTests` — patch: add `requestBodyHasOnlyTheDocumentBlockWhenGlossaryAndAttendeeContextAreEmpty` asserting one content block, no `cache_control`.
  - `[false]` `[reject]` (Blind Hunter) `canonicalTranscriptJSONRoundTripProducesByteIdenticalText` only checks `.text` bytes, not full `Equatable`, so a corrupted utterance-offset round-trip could go undetected — reject: `Tests/CoreTests/CanonicalTranscriptTests.swift`'s pre-existing, untouched `canonicalTranscriptRoundTripsAndUsesSnakeCaseKeys` already asserts full `decoded == value` including utterances and still runs in the same suite; the new test's narrower `.text`-only scope matches Decision 3.4(a)'s own wording exactly, it doesn't replace or weaken the existing coverage.
  - `[low]` `[patch]` (Blind Hunter) `citationCountMismatchThrowsMalformedResponse` only covers the under-supply direction (fewer citation-bearing blocks than items) — patch: add one case for the over-supply direction.
  - `[low]` `[patch]` (Blind Hunter) `citationBearingBlockCitations`'s `.first`-per-block selection is untested against a block carrying more than one citation object — patch: add one test with two citations on one block, asserting the resulting `GroundingPointer` matches the first entry specifically.
  - `[low]` `[defer]` (Blind Hunter) Four near-identical private `URLProtocol` stub classes now exist across `AnthropicHTTPClientTests.swift`, `ClaudeSubstringSummarizerTests.swift`, `ClaudeCitationsSummarizerTests.swift`, and `CrossModeFixtureTests.swift`, with no shared `TestSupport` helper — defer: the file-local-stub-per-test-file convention was already an explicit, deliberate choice from Story 3.4's own spec ("no need to duplicate... machinery already covered"), continued here for consistency; consolidating it would touch the two pre-existing files too, a cross-cutting test-infrastructure change outside this story's scope.
  - `[false]` `[reject]` (Blind Hunter) The new `.swiftlint.yml` exclusion covers all of `Tests/SummarizeTests/` rather than just `CrossModeFixtureTests.swift` — reject: identical reasoning to the already-accepted `Tests/ClaudeSummarizerTests/` exclusion (Story 3.4's own review rejected the same finding there) — `SummarizeTests`'s dependencies (`Summarize`, `TestSupport`, `ClaudeSummarizer`) expose no type matching the rule's regex outside `ClaudeSummarizer`'s own prefix, so any future match in this directory is the identical non-bypass case.
  - `[low]` `[reject]` (Blind Hunter) No test covers a payload where one item is individually missing `source_block_index` — reject: falls through the identical generic `try?`/`JSONDecoder` catch-all already exercised by `modelAnswerMissingRequiredFieldsThrowsMalformedResponse`, the same root cause as Story 3.4's own rejected analogous finding.
  - `[low]` `[reject]` (Blind Hunter) No `CitationGroundingValidatorTests` case uses a zero-utterance transcript — reject: exercises the identical `endBlockIndex <= transcript.utteranceCount` guard branch already covered by `endBlockIndexPastUtteranceCountThrowsMalformedResponse`; utteranceCount being 0 vs. 2 doesn't change which branch fires.
  - `[low]` `[reject]` (Blind Hunter) `contentBlockTexts(for:)`'s `?? ""` silently substitutes an empty string when a byte slice isn't valid UTF-8 (e.g. a boundary splitting a multi-byte scalar), untested — reject: mirrors `SubstringGroundingValidator`'s own already-accepted unguarded assumption that a boundary "always valid UTF-8 when it sits on a scalar boundary"; `contentBlockTexts` uses `map`, not `compactMap`, so index alignment with `transcript.utterances` is preserved even in this degenerate case — the blast radius is one empty content block, not a misaligned document.
  - `[medium]` `[patch]` (Edge Case Hunter) `contentBlockTexts(for:)` slices `bytes[utterance.start ..< utterance.end]` with no bounds validation — a `CanonicalTranscript` with an invalid utterance range (negative, past the transcript's byte count, or `start > end`) traps the process instead of degrading gracefully — patch: add a bounds guard before slicing that substitutes `""` for that one utterance, same non-crashing posture the existing UTF-8 fallback already uses, no signature change.
  - `[low]` `[reject]` (Edge Case Hunter) Same `?? ""` fallback as the Blind Hunter finding above, framed as a missing UTF-8-boundary guard — reject: same evidence (grouped root cause).
  - `[false]` `[reject]` (Edge Case Hunter) An empty `transcript.utterances` would send a document block with an empty `content` array — reject: verified no crash or silently-wrong result occurs; `AnthropicHTTPClient`'s existing status-code mapping already turns any resulting non-2xx into a handled `SummarizerError`, the identical "atypical input, already handled downstream" posture Story 3.4's own review established and accepted for the analogous empty-transcript-text case.
  - `[low]` `[reject]` (Edge Case Hunter) No guard rejects a response block whose `citations` array has more than one entry; extras are silently discarded — reject: mirrors `SubstringGroundingValidator`'s own already-accepted "first match wins, no signal to disambiguate" precedent; never observed in the empirical evidence, and the proposed guard would add new error-handling behavior no AC specifies, not a direct correction.
  - `[false]` `[reject]` (Edge Case Hunter) A citation's positional block index could disagree with the item's own decoded `source_block_index`, silently grounding to the wrong span — reject: verified `citationBlockLocation`/`groundedItems` never read `item.sourceBlockIndex` at all; the `GroundingPointer` is computed exclusively from the real citation object's own indices, so this disagreement cannot corrupt the grounding output — exactly the "cross-check, never the grounding" property Decision 3.2 documents.
  - `[low]` `[patch]` (Edge Case Hunter) `partialOverrideFallsBackToBundledForTheMissingFile`'s `hasSuffix` assertion now checks only the newly-appended second sentence, no longer implicitly verifying the original locked first sentence survived in a two-sentence file — patch: add a `.contains("Use Anthropic Citations to ground each item.")` assertion alongside the existing `hasSuffix` check.
  - `[low]` `[patch]` (Verification Gap) Same root cause as the Blind Hunter `.first`-selection finding above — pre-verified: grepped every test-constructed `citations` array in the repo, all have exactly one entry — patch: covered by the same multi-citation-block test described above.
  - `[medium]` `[patch]` (Verification Gap) Every test's citation-bearing blocks carry `"text": ""`, never the substantial non-empty text the real Anthropic API sends on those blocks (per `citation_item_association_result.json`'s arm_b evidence) — pre-verified: `decodeModelAnswer`'s concatenation already handles this correctly by construction, but a future regression excluding citation-bearing blocks from concatenation would ship broken against the real API with the suite green — patch: add one test whose envelope splits the JSON answer across ≥3 blocks with non-empty text on a citation-bearing block, asserting `summarize()` still decodes and grounds correctly.
  - `[false]` `[reject]` (Intent Alignment) The epic name "Quote-Grounded" implies semantic-fidelity checking between claim and cited text, but `CitationGroundingValidator` only checks bounds/index validity — reject: epics.md's own AC explicitly scopes the validator to bounds-checking ("well-formed Citations responses always pass... there is no encoding convention that could make a well-formed response unmappable"); semantic fidelity is guaranteed by Anthropic's Citations mechanism itself, not something this story's validator is specified to verify.
  - `[false]` `[reject]` (Intent Alignment) "Canonicalization Invariant Tests" suggests testing a normalization procedure, but no normalizer exists and the tests check cross-validator offset agreement instead — reject: architecture.md Decision 3.4 defines "canonicalization invariant" precisely as the three properties this diff tests; the auditor's alternate reading isn't supported by the controlling architecture document, which this context-free auditor was deliberately not given.
  - `[false]` `[reject]` (Intent Alignment) The diff's footprint (`.swiftlint.yml`, `Package.swift`, `citations.md`, `PromptBuilderSnapshotTests.swift`) extends beyond the three named artifacts — reject: each touched file is a necessary, individually-justified dependency of building/testing the three named artifacts (documented in Design Notes), not unrelated scope creep.
  - `[false]` `[reject]` (Intent Alignment) Concrete design choices trace to the embedded spec and architecture docs rather than being derivable from the one-line intent title — reject: this describes the workflow's own intended operation (step-01/02 load epic/architecture context beyond the bare invocation title by design), not a defect.
  - `[false]` `[reject]` (Intent Alignment) No test exercises the real Anthropic API; all tests use local stubs — reject: live-API validation is explicitly Story 3.8's scope per `epic-3-context.md`'s own stories list, already named as a residual risk in this story's own implementation report.

## Design Notes

**Why `citations.md` changes despite Story 3.2 locking its wording verbatim:** Story 3.2's AC quoted architecture.md Decision 3.5's system-prompt skeleton, which that same section labels "illustrative; final wording during build." Decision 3.2's later, more specific empirical measurement (replicated 5x, zero variance) found the one-sentence addendum insufficient to make Citations work at all — this story is the first consumer of that file for real, so extending it (appending, not replacing, the original sentence) satisfies both: Story 3.2's exact wording still appears verbatim, and Citations actually grounds items.

**Why the positional zip, not a text-match:** the empirical evidence shows citation-bearing blocks appear in the response in exactly the same left-to-right order the JSON schema declares (`action_items` fully emitted before `decisions`, items in array order within each) — matching a citation-bearing block to its item by position is simpler and more robust than string-matching block text against decoded item text (which would need JSON-escape-aware comparison).

**Why `CoreTests` depends on `ClaudeSummarizer`:** epics.md pins the canonicalization contract test's path at `Tests/CoreTests/CanonicalTranscriptContractTests.swift` specifically — Decision 3.4 calls this "the single most important architectural detail of Group 3," deliberately pinning the cross-strategy invariant at `CanonicalTranscript`'s own test level so no future edit to either validator or to `CanonicalTranscript` itself can drift without tripping this suite. Verified empirically acyclic (see Code Map).

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build, exactly the two new test-only edges.
- `swift test --filter ClaudeSummarizerTests` -- expected: all new + existing tests pass.
- `swift test --filter CoreTests` -- expected: `CanonicalTranscriptContractTests` passes alongside existing Core tests.
- `swift test --filter SummarizeTests` -- expected: `CrossModeFixtureTests` and the updated snapshot tests pass.
- `swift test` -- expected: full suite passes, no regression.
- `swiftformat --lint .` && `swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations (no new `.swiftlint.yml` exclusion needed for `CoreTests`; `CrossModeFixtureTests.swift` constructs `ClaudeCitationsSummarizer`/`ClaudeSubstringSummarizer` directly, so add `Tests/SummarizeTests/.*\.swift$` to `composition_root_strategy_bypass`'s `excluded` list, same directory-scoped-per-test-target precedent Story 3.4 used).

## Auto Run Result

**Summary of implemented change:** Added `ClaudeCitationsSummarizer` (implements `SummarizerStrategy` by submitting the transcript as an Anthropic Citations document — one content block per utterance — decoding the model's JSON answer, and positionally zipping citation-bearing response blocks against `action_items`/`decisions` in declaration order) and `CitationGroundingValidator` (bounds-checked block-index-to-utterance-range mapping, throwing `SummarizerError` instead of returning `nil`) to `Sources/ClaudeSummarizer/`. Extended `citations.md` with the empirically load-bearing `source_block_index` per-item JSON-shape instruction (architecture.md Decision 3.2), updating the two dependent snapshot/literal tests to match. Added Decision 3.4's two build-time contract tests: `Tests/CoreTests/CanonicalTranscriptContractTests.swift` (round-trip byte-identity, segmentation-matches-utterances, substring/citation validator agreement) and `Tests/SummarizeTests/CrossModeFixtureTests.swift` (byte-identical rendered output across both grounding strategies for equivalent content). Added two test-only `Package.swift` edges (`CoreTests`/`SummarizeTests` → `ClaudeSummarizer`, verified acyclic by direct experiment before writing the spec) and one `.swiftlint.yml` composition-root exclusion for the new test target that constructs concrete strategies directly.

**Files changed:**
- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift` -- new -- the strategy: document-block request construction, citation-bearing-block extraction, positional item/citation zipping, `SummaryWithGrounding` assembly; patched during review to log a diagnostic before each of its three throw sites and to bounds-guard `contentBlockTexts(for:)` against a malformed `CanonicalTranscript` utterance range (degrades to `""` instead of trapping).
- `Sources/ClaudeSummarizer/CitationGroundingValidator.swift` -- new -- `CitationBlockLocation` + `validate(citation:in:) throws -> GroundingPointer`.
- `Sources/Summarize/Prompts/summarize/citations.md`, `Tests/SummarizeTests/Snapshots/prompts/citations.txt`, `Tests/SummarizeTests/PromptBuilderSnapshotTests.swift` -- modified -- appended the `source_block_index` instruction and updated the two dependent literal assertions; patched during review to also assert the original locked sentence still appears under a `promptDir` override, not just the new suffix.
- `Package.swift` -- modified -- added `"ClaudeSummarizer"` to `CoreTests` and `SummarizeTests` dependency lists.
- `.swiftlint.yml` -- modified -- added `Tests/SummarizeTests/` to `composition_root_strategy_bypass`'s exclusion list.
- `Tests/ClaudeSummarizerTests/CitationGroundingValidatorTests.swift` -- new -- valid range, negative start, end past utterance count, start>=end, multi-utterance span.
- `Tests/ClaudeSummarizerTests/ClaudeCitationsSummarizerTests.swift` -- new -- one test per I/O-matrix row plus the request-shape assertion; patched during review to add the empty-glossary request-shape test, the over-supply citation-count-mismatch case, a multi-citation-per-block test, and a realistic multi-block (non-empty citation-bearing-block text) decode test.
- `Tests/CoreTests/CanonicalTranscriptContractTests.swift` -- new -- Decision 3.4's three invariant properties; patched during review to add the out-of-bounds-utterance-range test covering the new bounds guard.
- `Tests/SummarizeTests/CrossModeFixtureTests.swift` -- new -- byte-identical cross-strategy rendering for equivalent content.

**Review findings breakdown:** 23 findings across 4 parallel layers (Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment) — 0 high, 4 medium, 10 low, 9 false, 0 maybe-false. No `intent_gap` or `bad_spec` routes were needed. Full per-finding detail is in `## Review Triage Log` above.
- **Patched (8 findings across 7 entries, all applied and reverified):** (1) `groundedSummary`/`citationBlockLocation` now log a diagnostic before each throw. (2) Added the empty-glossary/empty-attendee request-shape test. (3) Added the over-supply direction of the citation-count-mismatch test. (4) Added a multi-citation-per-block test proving `.first` selection specifically (grouped Blind Hunter + Verification Gap findings, same root cause). (5) Added a bounds guard in `contentBlockTexts(for:)` preventing an array-slice trap on a malformed utterance range, plus a covering test. (6) Restored the dropped `.contains` assertion for the original locked `citations.md` sentence in the `promptDir`-override test. (7) Added a realistic multi-block decode test with non-empty text on citation-bearing blocks, matching the real Anthropic API shape from the empirical evidence file.
- **Deferred (1 entry):** the four now-near-identical file-local `URLProtocol` test stubs (across `AnthropicHTTPClientTests`, `ClaudeSubstringSummarizerTests`, `ClaudeCitationsSummarizerTests`, `CrossModeFixtureTests`) have no shared `TestSupport` helper — continuation of an already-deliberate Story 3.4 convention; consolidating it touches files outside this story.
- **Rejected (14 findings):** the narrower round-trip test's scope matches Decision 3.4(a)'s own wording and doesn't weaken the still-present Story 3.1 full-equality test; the directory-wide `.swiftlint.yml` exclusion mirrors an already-accepted identical precedent; two findings duplicate an already-exercised generic `JSONDecoder` catch-all or bounds-check branch; the unguarded UTF-8-boundary assumption mirrors `SubstringGroundingValidator`'s own already-accepted convention; an empty-utterances document body degrades gracefully through `AnthropicHTTPClient`'s existing status-code mapping (verified, not just asserted); a hard guard against multi-citation blocks would add unrequested behavior beyond the already-precedented "first wins" convention; a `source_block_index`-vs-citation cross-check is provably moot since the field is never read for grounding; and five Intent Alignment divergences were all resolved by the controlling architecture/epic documents that context-free auditor wasn't given.
- **Follow-up review recommendation:** `true`. Four medium-severity entries were patched on this first pass (two of them behavior changes in production code — the log-before-throw additions and the `contentBlockTexts` bounds guard — not just test additions). The specific unverified risk: the bounds-guard fix and its one covering test, plus the multi-block/multi-citation tests, were confirmed to pass but were applied and verified by a different agent invocation than the one that wrote the original implementation (a process deviation from the intended "same subagent, re-engaged" continuity — a fresh general-purpose agent was launched instead of continuing the original one by id). A follow-up pass should re-examine the `contentBlockTexts` bounds guard and the two production log-call additions specifically for consistency with the rest of the file's conventions.

**Verification performed:**
- `swift build --explicit-target-dependency-import-check error` -- clean build, exactly the two new test-only edges, both before and after the patch round.
- `swift test --filter ClaudeSummarizerTests` -- 52/52 passed (48 pre-patch + 4 added during review).
- `swift test --filter CoreTests` -- 56/56 passed (55 pre-patch + 1 added during review).
- `swift test --filter SummarizeTests` -- 16/16 passed (2 literal-assertion updates, no count change).
- `swift test` (full suite) -- 271/271 passed, no regressions (266 pre-patch + 5 net new).
- `mise exec -- swiftformat --lint .` -- 0/134 files require formatting (two violations introduced by the patch round — a plain-`//` comment needing `///`, and a redundant `throws` on a non-throwing test function — found and fixed independently during this verification pass).
- `mise exec -- swiftlint lint --strict --config .swiftlint.yml .` -- 0 violations, 0 serious, 133 files.
- `scripts/verify-custom-lint-rules.sh` -- 13/13 fixture markers still fire.
- Matrix Test Audit: all 8 I/O-matrix rows confirmed covered by a test that ran and passed, both before and after the patch round.

**Residual risks:** Live-API validation of the Citations mechanics (document-block segmentation, `source_block_index` prompt instruction, positional citation-to-item association) remains unverified against the real Anthropic API — only Story 3.8's smoke test will exercise that, per epic-3-context.md's own sequencing. The four-file `URLProtocol` stub duplication is now logged in `deferred`. The process deviation noted in the follow-up-review paragraph above (patch round applied by a freshly-launched agent rather than the original implementation subagent, re-engaged by id) means the two production-code changes from this round have had one fewer layer of continuity-informed self-review than the rest of the diff, though they were independently verified against the diff and against the full test/lint suite by this orchestrating run.

**Finalization outcome:** pending -- see below.
