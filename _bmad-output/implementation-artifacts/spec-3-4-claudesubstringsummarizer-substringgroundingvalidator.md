---
title: 'ClaudeSubstringSummarizer + SubstringGroundingValidator'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: 'd0fb9a7508eeaeea1c2d60a1c6975d504895b144'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-1-summarizerinterface-protocol-normalized-summarywithgrounding-output.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-2-summarizationpromptbuilder-file-backed-prompt-set-glossary-injection-drift-snapshot-tests.md',
  '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-anthropichttpclient-keychainapikey-retry-backoff.md',
]
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** `ClaudeSummarizer` has the HTTP transport (Story 3.3) and `Summarize` has the shared prompt builder (Story 3.2), but nothing yet implements `SummarizerStrategy` — no strategy exists to call Claude and turn a response into a grounded summary. The substring path is both the MVP fallback (Decision 3.3) and the v1.1+ local-LLM contract (FR33), so it must exist before the orchestrator (Story 3.6) has anything to fall back to.

**Approach:** Add `ClaudeSubstringSummarizer` (implements `SummarizerStrategy` via `AnthropicHTTPClient` + `SummarizationPromptBuilder.build(..., mode: .substring)`) and `SubstringGroundingValidator` (literal substring search producing UTF-8-byte-offset `GroundingPointer`s) to `Sources/ClaudeSummarizer/`.

## Boundaries & Constraints

**Always:**
- `ClaudeSubstringSummarizer` is a `struct: SummarizerStrategy`, DI-constructed: `init(httpClient: AnthropicHTTPClient = AnthropicHTTPClient())` — same defaulted-constructor-injection shape as `AnthropicHTTPClient` itself.
- `summarize(transcript:glossary:config:)` calls `SummarizationPromptBuilder.build(transcript: transcript, glossary: glossary, attendees: [], mode: .substring, promptDir: nil)`. `attendees: []` and `promptDir: nil` always: neither channel exists on the fixed `SummarizerStrategy` signature or on `SummarizerConfig` today — real attendee data (Story 3.10/3.11) and `--prompt-dir`/`summarization.prompt_dir` resolution (Story 3.7, per spec-3-2's own boundary) are threaded in by the stage entry point, not by a strategy.
- **New `Package.swift` edge: `ClaudeSummarizer` depends on `Summarize`** (add `"Summarize"` to the `ClaudeSummarizer` target's dependencies, and to `ClaudeSummarizerTests`'s). This is required, not optional: epics.md's own AC ties `summarize()`'s implementation directly to `SummarizationPromptBuilder.build(...)`, the protocol signature has no slot for a caller to inject a pre-built prompt instead, and Decision 3.2 requires both strategies to call the *same* builder (not reimplement prompt composition) so they can never drift. Verified no cycle results: `Summarize`'s own dependencies (`Core`, `State`, `Telemetry`, `SummarizerInterface`, `CalendarInterface`, `VaultGlossary`) do not import `ClaudeSummarizer`, and `Package.swift` already shows `ClaudeSummarizer` diverging from architecture.md's literal "`ClaudeSummarizer → Core, SummarizerInterface`" graph line by also depending on `VaultGlossary` — that line is already stale, not a hard constraint this story would be first to break.
- Request body (`AnthropicRequest.body`, built via `JSONSerialization` matching `AnthropicResponse.parse`'s own style): `model: config.modelIdentifier`, a fixed `max_tokens` (pick one constant, e.g. `4096`, documented inline as a stand-in — no AC or architecture doc fixes this number, same "hard-coded until a real config story lands" posture as Story 3.3's rate table), `system` as an array with one block carrying `prompt.system.text` (`cache_control: {"type": "ephemeral"}` since `system` is always `cacheable: true`), and a single user message whose `content` is an array of blocks in this order: `prompt.glossary.text` (only when non-empty), `prompt.attendeeContext.text` (only when non-empty), `prompt.transcript.text` (always, never `cache_control`). Put `cache_control` on the *last* non-empty block before the transcript (glossary or attendee context, whichever is later) — Anthropic's cache breakpoint marks a prefix boundary, so marking every cacheable block individually is redundant per Decision 3.5's caching table.
- No `citations` field anywhere in the request — this is the non-Citations path per Decision 3.2 ("same prompt skeleton, no Citations enabled").
- Extract the model's answer from `AnthropicResponse.content` (opaque re-serialized JSON array of content blocks): parse as `[[String: Any]]`, concatenate the `text` field of every `"type": "text"` block, then `JSONDecoder`-decode that string's UTF-8 bytes into a private `Decodable` shape mirroring `{summary, action_items: [{text, source_transcript_quote}], decisions: [...]}` (snake_case `CodingKeys`, matching `source_transcript_quote`). Any failure at any step (no text block, invalid JSON, missing/mistyped fields) throws `SummarizerError.malformedResponse` — this is what makes the "structurally malformed JSON" test case work. An empty `action_items`/`decisions` array decodes and maps to `[]`, not an error.
- For each decoded item, call `SubstringGroundingValidator.validate(quote: item.sourceTranscriptQuote, in: transcript)`. A non-nil result becomes `GroundedItem(text: item.text, grounding: pointer)`. A `nil` result drops the item: log one `warn` line per drop naming only the section (`actionItem`/`decision`) and its index — never the quote or item text itself (matches `AnthropicHTTPClient`'s never-log-content precedent; a transcript excerpt is user content, not safe telemetry). After processing both arrays, log one `info` line with the total drop count under the field name `quoteValidationDropCount`.
- Build the returned `SummaryWithGrounding` with `schemaVersion: 1`, `groundingMethod: .substring`, and `cost: SummarizerCost(inputTokens: response.usage.inputTokens, outputTokens: response.usage.outputTokens, thinkingTokens: response.thinkingTokens, costUSD: response.costUSD)` — real Anthropic-reported figures (the "cost is `0`" clause in epics.md's AC applies only to a future local-LLM strategy reusing this validator, not to this Claude-calling strategy).
- `SubstringGroundingValidator` is a stateless `public enum` namespace (same shape as `SummarizationPromptBuilder`): `public static func validate(quote: String, in transcript: CanonicalTranscript) -> GroundingPointer?`. Use `transcript.text.range(of: quote)` (literal, case-sensitive; no `.caseInsensitive`/`.diacriticInsensitive` options) — if found, convert both bounds to UTF-8 byte offsets via `transcript.text.utf8.distance(from:to:)` on each bound's `samePosition(in: transcript.text.utf8)` (always non-nil: grapheme-cluster boundaries are always valid UTF-8 boundaries) and return `GroundingPointer(transcriptStart:, transcriptEnd:, sourceMethod: .substring)`; otherwise return `nil`. Don't throw from this function — the caller decides whether "not found" means "drop" (this story) or something else (a future caller).
- When a quote occurs more than once in the transcript, `range(of:)`'s first match wins — there is no signal in the model's response to disambiguate, and Citations has no equivalent ambiguity to match against.

**Never:**
- Don't implement `CanonicalTranscript`'s NFC/LF normalization enforcement here — that's Story 3.5's scope (extends `CanonicalTranscriptContractTests`). This validator does a literal search against `transcript.text` as given; Swift's default string comparison already being Unicode-canonical-equivalence-aware happens to line up with the eventual NFC invariant, but this story doesn't implement or test that invariant itself.
- Don't add a `Telemetry` dependency to `ClaudeSummarizer`, and don't write to `telemetry.quote_validation_drop_count` directly — `ClaudeSummarizer` has no `Telemetry` edge in `Package.swift` today and this story doesn't add one. The `warn`/`info` log lines above are the only artifact this layer can produce; wiring them into the `telemetry` table is the summarize stage's job (Story 3.7, which does depend on `Telemetry`).
- Don't build `ClaudeCitationsSummarizer`, `CitationGroundingValidator`, or the canonicalization invariant tests — Story 3.5's scope.
- Don't build `SummarizerOrchestrator` or any fallback-dispatch logic — Story 3.6's scope.
- Don't map `SummarizerConfig.effortLevel` to any Anthropic wire parameter (e.g. an invented `thinking`/effort-budget field) — no architecture decision or AC fixes this mapping yet; leave it unused, same documented-gap posture as Story 3.3's rate table.
- Don't translate a thrown `SummarizationPromptBuilderError` into a `SummarizerError` — it represents a packaging defect (missing/corrupt bundled resource), not a fallback-eligible runtime condition, so it propagates untranslated.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| All quotes valid | Stub 200, all `source_transcript_quote`s appear verbatim in transcript | All items returned as `GroundedItem`s, `sourceMethod: .substring` | No error |
| Mixed valid/invalid quotes | Stub 200, some quotes don't appear verbatim | Invalid items dropped (each logged at `warn`), valid items survive, aggregate drop count logged | No error |
| Structurally malformed JSON | Stub 200, text block isn't valid JSON / missing required fields | — | `SummarizerError.malformedResponse` |
| Empty arrays | Stub 200, `action_items: []`, `decisions: []` | `actionItems == []`, `decisions == []` | No error |
| Quote found | `validate(quote:in:)`, quote present once | `GroundingPointer` with correct UTF-8 byte offsets (verified against a transcript containing multi-byte Unicode before the quote) | No error |
| Quote absent | `validate(quote:in:)`, quote not a substring | `nil` | No error (caller logs/drops) |

</intent-contract>

## Code Map

- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift` -- new -- the strategy: request construction, response decoding, per-item validation/dropping, `SummaryWithGrounding` assembly.
- `Sources/ClaudeSummarizer/SubstringGroundingValidator.swift` -- new -- stateless `validate(quote:in:) -> GroundingPointer?`.
- `Package.swift:99` (`ClaudeSummarizer` target) -- modify -- add `"Summarize"` to `dependencies`.
- `Package.swift:149` (`ClaudeSummarizerTests` target) -- modify -- add `"Summarize"` to `dependencies` (tests assert request content against real `SummarizationPromptBuilder.build(...)` output, not a re-derived string).
- `Sources/ClaudeSummarizer/AnthropicHTTPClient.swift` -- existing, read-only -- `send(_:) async throws -> AnthropicResponse`, `AnthropicRequest`, `AnthropicResponse.content`/`.usage`/`.thinkingTokens`/`.costUSD` shape (Story 3.3).
- `Sources/Summarize/SummarizationPromptBuilder.swift` -- existing, read-only -- `build(transcript:glossary:attendees:mode:promptDir:) throws -> SummarizationPrompt`, `SummarizationMode.substring`, `PromptBlock.{text,cacheable}` (Story 3.2).
- `Sources/SummarizerInterface/{SummarizerStrategy,SummaryWithGrounding,GroundedItem,GroundingPointer,GroundingMethod,SummarizerConfig,SummarizerError}.swift` -- existing, read-only -- the fixed protocol/output/error contract (Story 3.1); `GroundingPointer.transcriptStart/End` are UTF-8 byte offsets by convention.
- `Sources/Core/CanonicalTranscript.swift`, `Sources/Core/Glossary.swift` -- existing, read-only -- `transcript.text` (UTF-8-byte-offset convention already documented on `Utterance`), `Glossary`'s four categories.
- `Tests/ClaudeSummarizerTests/AnthropicHTTPClientTests.swift` -- existing, read-only -- its `StubURLProtocol` is `private` to that file; do not extract it. Add a separate, file-local stub (single canned response per test; no need to duplicate its retry/backoff/attempt-tracking machinery, already covered by Story 3.3's own tests) in the new test file(s).
- `_bmad-output/planning-artifacts/epics.md:1463-1490` -- authoritative ACs for this story.
- `_bmad-output/planning-artifacts/architecture.md:1380-1386` (Decision 3.2, substring half) -- request/validation shape.
- `_bmad-output/planning-artifacts/architecture.md:1454-1496` (Decision 3.5) -- prompt skeleton, cache-breakpoint placement.
- `_bmad-output/planning-artifacts/architecture.md:2560-2612` -- module dependency graph + "critical edges that do not exist" (see Design Notes for why this story adds one edge not listed there).

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- modify -- add `"Summarize"` to `ClaudeSummarizer` and `ClaudeSummarizerTests` dependency lists.
- `Sources/ClaudeSummarizer/SubstringGroundingValidator.swift` -- new -- implement per Boundaries.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift` -- new -- implement per Boundaries.
- `Tests/ClaudeSummarizerTests/SubstringGroundingValidatorTests.swift` -- new -- found (including a multi-byte-Unicode-prefix case proving byte offsets, not character counts), not-found, first-match-wins-on-duplicate cases.
- `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift` -- new -- one test per I/O-matrix row above, against a stubbed `URLProtocol`; at least one test asserts the sent request's `system`/content blocks match `SummarizationPromptBuilder.build(...)`'s real output for the same fixture (not a hand-duplicated string) and that a `cache_control` marker is present on exactly the intended block.

**Acceptance Criteria:**
- Given a stubbed 200 response with all quotes present verbatim in the transcript, when `summarize()` runs, then every action item and decision is returned with `grounding.sourceMethod == .substring` and correct byte offsets.
- Given a stubbed 200 response with some quotes absent from the transcript, when `summarize()` runs, then only the invalid items are dropped, each drop is logged at `warn` with no quote/item text in the log fields, and one aggregate `info` log line reports the total drop count.
- Given a stubbed 200 response whose text block isn't valid JSON (or is missing `action_items`/`decisions`), when `summarize()` runs, then it throws `SummarizerError.malformedResponse`.
- Given a stubbed 200 response with `action_items: []` and `decisions: []`, when `summarize()` runs, then it returns empty arrays with no error.
- Given `swift build --explicit-target-dependency-import-check error`, then it compiles with exactly one new cross-target edge (`ClaudeSummarizer → Summarize`) and no others.

## Spec Change Log

## Review Triage Log

### 2026-09-17 — Review pass
- verdicts: 22 findings — high 0, medium 6, low 7, false 9, maybe-false 0
- findings:
  - `[low]` `[reject]` (Blind Hunter) `buildRequestBody` decides `cache_control` placement from `prompt.*.text.isEmpty` rather than reading `PromptBlock.cacheable` — reject: `cacheable` is a static per-block-role constant (glossary/attendeeContext always `true`, transcript always `false`) that already agrees exactly with the emptiness gate for every block this builder produces today; no divergence exists, and reading `.cacheable` would only guard a hypothetical future change to the builder's own contract.
  - `[false]` `[reject]` (Blind Hunter) The aggregate `log.info` drop-count line fires unconditionally, even when the count is zero — reject: the spec's Boundaries text reads verbatim "After processing both arrays, log one `info` line with the total drop count," with no conditional language; the code implements exactly this literal requirement.
  - `[medium]` `[patch]` (Blind Hunter) `decodeModelAnswer`'s three failure paths are swallowed via `try?` with no log call before throwing `SummarizerError.malformedResponse`, unlike every HTTP-layer failure path in `AnthropicHTTPClient` (Story 3.3), which logs before throwing — patch: wrapped the `decodeModelAnswer` call in `summarize()` in a do/catch that logs `"substring model answer failed to decode"` (no content fields) before rethrowing.
  - `[medium]` `[patch]` (Blind Hunter) No test exercises `buildRequestBody` with both `glossary` and `attendeeContext` empty — the exact configuration four of this file's five functional tests actually send — patch: added `requestBodyHasOnlyTheTranscriptBlockWhenGlossaryAndAttendeeContextAreEmpty`, asserting `contentBlocks.count == 1` and no `cache_control` for that configuration.
  - `[false]` `[reject]` (Blind Hunter) The attendee-context-is-last-cacheable-block branch of `buildRequestBody` is untested and effectively unreachable — reject: this story's own call site hardcodes `attendees: []`, so the branch is provably dead code within this story's scope; exercising it belongs to whichever future story (3.10/3.11) first passes non-empty attendee data, per the spec's own Code Map note.
  - `[low]` `[reject]` (Blind Hunter) No test covers `validate(quote: "", in:)` — reject: verified empirically that `"...".range(of: "")` returns `nil` in Swift, so an empty quote is already dropped (correct "not found" semantics) rather than spuriously matching at offset 0; a coverage nice-to-have for a low-probability model response, not a defect.
  - `[low]` `[reject]` (Blind Hunter) Malformed-JSON coverage tests a missing key but not a wrong-typed one — reject: both fall through the identical generic `try?`/`JSONDecoder` catch-all already exercised by `textBlockMissingRequiredFieldsThrowsMalformedResponse`; a wrong-typed-field test would cover the same code path a second time.
  - `[medium]` `[patch]` (Blind Hunter) No test asserts the `warn`/`info` drop-log lines actually exclude quote/item text — the same never-log-content property Story 3.3 tests for `AnthropicHTTPClient.redactedLogFields` — patch: extracted `ClaudeSubstringSummarizer.dropLogFields(section:index:)` and `.dropCountLogFields(_:)` (mirroring `redactedLogFields`'s shape — the parameters structurally exclude quote/item text) and added tests asserting each dict's keys are exactly the expected non-content fields.
  - `[low]` `[patch]` (Blind Hunter) The new `.swiftlint.yml` exclusion's comment narrates its own discovery ("Story 3.4 is the first strategy story to add real tests that... surfacing that this exclusion set never covered test targets") instead of stating the constraint — the diff-narration pattern this project's comment conventions ban by name — patch: reworded the comment to state why the exclusion is scoped per test target and what a future concrete-strategy test target must do, without narrating this story's own discovery.
  - `[false]` `[reject]` (Blind Hunter) The `.swiftlint.yml` exclusion is scoped to the whole `Tests/ClaudeSummarizerTests/` directory rather than the two new files — reject: the rule's regex matches only five specific concrete-strategy name prefixes, and this test target's own dependencies (`ClaudeSummarizer`, `TestSupport`, `Summarize`) cannot expose any type outside `ClaudeSummarizer`'s own prefix; any future match in this directory would be that same type's own test suite constructing itself, the identical non-bypass case this exclusion already covers.
  - `[false]` `[reject]` (Blind Hunter) `Package.swift` adds a `ClaudeSummarizer → Summarize` edge without updating `architecture.md`'s stale dependency-graph line — reject: the intent-contract's own Boundaries text states this line "is already stale... not a hard constraint this story would be first to break" and requires only that no dependency cycle results, which was verified; a deliberate, already-argued scope decision, not an oversight.
  - `[false]` `[reject]` (Blind Hunter) Only the two-block (glossary + transcript) request shape is tested, never a three-block (glossary + attendee + transcript) shape — reject: same root cause as the attendee-context-branch finding above — a three-block request is unreachable while `attendees: []` is hardcoded in this file.
  - `[low]` `[reject]` (Edge Case Hunter) `buildRequestBody` appends the transcript content block unconditionally, with no guard for `prompt.transcript.text.isEmpty` — reject: an all-empty transcript is an atypical input for this call, and `AnthropicHTTPClient`'s existing outcome-mapping (Story 3.3) already turns any resulting 4xx into a handled, non-crashing error; an explicit guard would add branching complexity for an edge case unlikely to be met in practice.
  - `[false]` `[reject]` (Edge Case Hunter) `SummarizerConfig.promptCachingEnabled` is never read; `cache_control` is applied unconditionally regardless of its value — reject: architecture.md Decision 3.5's caching table specifies system/glossary/attendee context are "Yes — always cached" with no gating mechanism described anywhere in the cited planning artifacts; the diff's unconditional behavior matches the decision this story implements, and no cited authority ties `promptCachingEnabled` to this wire behavior.
  - `[low]` `[reject]` (Edge Case Hunter) `response.stopReason == "max_tokens"` (answer truncation) is never inspected, so truncation reads the same as a genuinely malformed answer — reject: both cases already resolve to the spec-mandated `SummarizerError.malformedResponse` via the existing catch-all; distinguishing them would only improve diagnostics for an atypical case, not fix incorrect behavior.
  - `[low]` `[reject]` (Edge Case Hunter) The test-only `SubstringStubURLProtocol.bodyData(from:)` helper's `guard read > 0 else { break }` treats a stream I/O error the same as clean EOF — reject: test-support code only, exercised by an in-memory ephemeral `URLSession` stream that will not produce a genuine I/O error in practice; the loop already breaks safely either way.
  - `[medium]` `[patch]` (Verification Gap) Dropped-item log fields are never checked for the content they must exclude — pre-verified evidence filed by the layer; same defect as the Blind Hunter logging finding above — patch: covered by the `dropLogFields`/`dropCountLogFields` extraction and tests described above.
  - `[medium]` `[patch]` (Verification Gap) Empty-glossary/attendee request shape is exercised by most tests but never checked — pre-verified evidence filed by the layer; same defect as the Blind Hunter empty-block finding above — patch: covered by `requestBodyHasOnlyTheTranscriptBlockWhenGlossaryAndAttendeeContextAreEmpty` described above.
  - `[false]` `[reject]` (Intent Alignment) Cache-placement generality: the algorithm's attendee-context branch exists but every test call hardcodes `attendees: []`, so it's never exercised — reject: same root cause as the Blind Hunter attendee-branch finding above.
  - `[medium]` `[patch]` (Intent Alignment) Logging: the intent's drop-logging expectations are satisfied at the source-code surface only, with no test asserting emitted content — reject/patch: same defect as the Blind Hunter/Verification-Gap logging findings above; covered by the same fix.
  - `[false]` `[reject]` (Intent Alignment) `.swiftlint.yml` is modified even though the Code Map never names it as a file this story touches — reject: the spec's own Verification section requires `swiftlint lint --strict` to report 0 violations, and the new tests directly construct `ClaudeSubstringSummarizer(...)`, which the pre-existing `composition_root_strategy_bypass` rule would otherwise flag; the intent-contract never excludes touching this file, so the change was necessary and introduces no incorrect behavior.
  - `[false]` `[reject]` (Intent Alignment) `SummarizerConfig.promptCachingEnabled` is defined and tested elsewhere but never referenced by the new code — reject: same root cause as the Edge Case Hunter `promptCachingEnabled` finding above.

## Design Notes

**Why `ClaudeSummarizer` gains a `Summarize` dependency instead of duplicating prompt composition:** epics.md's AC for this story reads "the implementation calls `messages.create` ... with the prompt from `SummarizationPromptBuilder.build(...)`" — i.e. `ClaudeSubstringSummarizer.summarize()` itself must call that builder. `SummarizerStrategy.summarize(transcript:glossary:config:)`'s signature (fixed by the already-`done` Story 3.1) has no parameter through which a caller could hand it a pre-built prompt instead, and Decision 3.2 explicitly requires both Claude strategies to share one builder so their prompts "can never drift apart" — reimplementing prompt text inside `ClaudeSummarizer` would defeat the reason Story 3.2 exists. architecture.md's literal module-dependency-graph line for `ClaudeSummarizer` ("`→ Core, SummarizerInterface`") doesn't list this edge, but that same line is already stale against the real `Package.swift` (which adds `VaultGlossary`), and no dependency cycle results (`Summarize` and everything it depends on stays clear of `ClaudeSummarizer`).

**UTF-8 byte offset conversion, concretely:**
```swift
guard let range = transcript.text.range(of: quote) else { return nil }
let utf8 = transcript.text.utf8
let start = utf8.distance(from: utf8.startIndex, to: range.lowerBound.samePosition(in: utf8)!)
let end = utf8.distance(from: utf8.startIndex, to: range.upperBound.samePosition(in: utf8)!)
```

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build, the one new `ClaudeSummarizer → Summarize` edge and no others.
- `swift test --filter ClaudeSummarizerTests` -- expected: all new tests pass.
- `swift test` -- expected: full suite passes, no regression.
- `swiftformat --lint .` && `swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations.

## Auto Run Result

**Summary of implemented change:** Added `ClaudeSubstringSummarizer` (implements `SummarizerStrategy` by calling `AnthropicHTTPClient` with a request built from `SummarizationPromptBuilder.build(..., mode: .substring)`, decoding the model's JSON answer, and grounding each item via `SubstringGroundingValidator`) and `SubstringGroundingValidator` (stateless literal-substring search producing UTF-8-byte-offset `GroundingPointer`s) to `Sources/ClaudeSummarizer/`. This resumed run picked up a healthy, already-implemented and already-verified change (baseline `d0fb9a7`) at the review step after a prior run crashed on an unrelated API-authentication error before review completed, ran the four-layer parallel review, and applied the patch-routed findings directly (no live step-03 subagent remained to re-engage after the crash).

**Files changed:**
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift` -- new -- the strategy: request construction, response decoding, per-item grounding/dropping, `SummaryWithGrounding` assembly; patched during review to log a diagnostic on decode failure and to expose `dropLogFields`/`dropCountLogFields` as separately testable, content-excluding field builders.
- `Sources/ClaudeSummarizer/SubstringGroundingValidator.swift` -- new -- stateless `validate(quote:in:) -> GroundingPointer?`.
- `Package.swift` -- modified -- added `"Summarize"` to the `ClaudeSummarizer` and `ClaudeSummarizerTests` target dependency lists.
- `.swiftlint.yml` -- modified -- added a `composition_root_strategy_bypass` exclusion for `Tests/ClaudeSummarizerTests/`, needed because the new tests construct `ClaudeSubstringSummarizer` directly; comment reworded during review to state the constraint rather than narrate its own discovery.
- `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift` -- new -- one test per I/O-matrix row, a request-shape test against the real `SummarizationPromptBuilder` output, plus two tests added during review (empty-glossary/attendee request shape, and the extracted log-field builders).
- `Tests/ClaudeSummarizerTests/SubstringGroundingValidatorTests.swift` -- new -- found, not-found, multi-byte-Unicode-offset, and first-match-wins-on-duplicate cases.

**Review findings breakdown:** 22 findings across 4 parallel layers (Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment) grouped into 16 root-cause entries — 0 high, 6 medium, 7 low (by individual finding verdict), 9 false. No `intent_gap` or `bad_spec` routes were needed. Full per-finding detail is in `## Review Triage Log` above.
- **Patched (4 entries, all applied and reverified):** (1) `decodeModelAnswer` failures now log a diagnostic before throwing. (2) Added a test for the empty-glossary/empty-attendee request shape (the configuration 4 of 5 functional tests actually send but never had its wire shape checked). (3) Extracted `dropLogFields`/`dropCountLogFields` as separately-testable field builders and added tests proving they carry only the expected non-content keys, closing the untested "never log quote/item text" privacy invariant. (4) Reworded the `.swiftlint.yml` exclusion comment to state its constraint instead of narrating this story's own discovery.
- **Deferred:** none.
- **Rejected (12 entries):** cache_control keyed off `.text.isEmpty` instead of `.cacheable` (no current divergence, only a hypothetical future one); unconditional aggregate drop-count log line (spec mandates this literally); the attendee-context cache branch and the three-block request shape untested (provably unreachable while `attendees: []` is hardcoded in this story); empty-quote validation untested (already-correct, low-probability case); malformed-JSON wrong-typed-field case untested (same catch-all as the already-tested missing-field case); unconditional transcript content block with no empty-transcript guard (atypical input, already handled as a non-crashing error downstream); `SummarizerConfig.promptCachingEnabled` unused (architecture.md Decision 3.5 mandates unconditional caching with no gating mechanism); `stopReason == "max_tokens"` truncation not distinguished from malformed content (already resolves to the spec-mandated error); test-only stream-read helper treating an I/O error like EOF (untestable in practice, test-support code only); the swiftlint exclusion's directory-wide scope (regex + import graph already bound its blast radius to the same non-bypass case); `.swiftlint.yml` being touched outside the Code Map's named files (necessary to satisfy the spec's own Verification section, no functional defect); `architecture.md`'s graph line not updated (the intent-contract itself already argues this is acceptable).

**Follow-up review recommendation:** `true`. Three medium-severity entries were patched on this first pass (decode-failure logging, empty-glossary/attendee request-shape coverage, and the drop-log content-exclusion coverage). The specific unverified risk: the new regression tests (`requestBodyHasOnlyTheTranscriptBlockWhenGlossaryAndAttendeeContextAreEmpty`, `dropLogFieldsContainsOnlySectionAndIndex`, `dropCountLogFieldsContainsOnlyTheAggregateCount`) were confirmed to pass but have not themselves been reviewed by a fresh pass for whether they actually pin down the intended failure modes (e.g., whether `dropLogFields`'s structural key-count check would survive a future edit that renames rather than adds a field) — a follow-up pass should re-examine those three tests specifically.

**Verification performed:**
- `swift build --explicit-target-dependency-import-check error` -- clean build, exactly the one new `ClaudeSummarizer → Summarize` edge.
- `swift test --filter ClaudeSummarizerTests` -- 35/35 passed (31 pre-existing + 4 added during review).
- `swift test` -- full suite, 249/249 passed, no regressions.
- `mise exec -- swiftformat --lint .` -- 0/128 files require formatting.
- `mise exec -- swiftlint lint --strict --config .swiftlint.yml .` -- 0 violations, 0 serious, 127 files.

**Residual risks:** The three new review-added tests are themselves unreviewed (see follow-up recommendation above). `SummarizerConfig.promptCachingEnabled` remains unwired to any code path in the codebase; if a future story needs to make caching conditional, this is the point where that decision was last deliberately left unmade. The `.swiftlint.yml` `composition_root_strategy_bypass` exclusion pattern (one directory-scoped entry per concrete-strategy test target) is expected to repeat for the other four concrete-strategy test targets as their own stories add direct-construction tests.

**Finalization outcome (resolved):** `git commit` was first attempted twice with all seven reviewed-diff files staged (`.swiftlint.yml`, `Package.swift`, both new `Sources/ClaudeSummarizer/` files, both new `Tests/ClaudeSummarizerTests/` files, and this spec file); both attempts failed identically after swiftformat/swiftlint pre-commit hooks passed cleanly, with `error: 1Password: failed to fill whole buffer` / `fatal: failed to write commit object` — interactive SSH-commit-signing requiring Touch ID/passcode approval with no human present to provide it. Per this run's own ground rules, signing was not bypassed and the commit was not retried further at the time. The operator returned, approved the pending 1Password signing prompt, and the same commit succeeded. Working tree verified clean afterward; no code changed from the verified state above.
