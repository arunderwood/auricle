---
title: 'SummarizerInterface — Protocol + Normalized SummaryWithGrounding Output'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: '0fd483c339c416589fd404391fba5fd4ddc2e9f8'
review_loop_iteration: 0
followup_review_recommended: true
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md', '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md']
warnings: ['oversized']
deferred:
  - summary: >-
      Sources/Core/Errors.swift's top-of-file comment and PersistError's doc
      comment both still claim Persist "is still a placeholder with no real
      implementation," which has been false since Epic 2 shipped
      PersistStage.swift, FrontmatterRenderer.swift, VaultWriter.swift, etc.
    evidence: |-
      Verified: Sources/Persist/ contains real, shipped implementation files
      (not ManifestPlaceholder.swift), confirmed via `ls Sources/Persist/`.
      The false claim predates this story — the pre-diff baseline already
      read "SummarizerInterface, Persist" in the same sentence, so this
      story's edit (which only removed SummarizerInterface from the list)
      did not introduce or touch the Persist inaccuracy. Found by the Blind
      Hunter review layer during Story 3.1's review pass.
    location: >-
      Sources/Core/Errors.swift:8-11,28-31
    severity: low
---

<intent-contract>

## Intent

**Problem:** `SummarizerInterface` (protocol-only target, depends only on `Core`) is still `ManifestPlaceholder.swift`. Nothing declares `SummarizerStrategy` or the normalized `SummaryWithGrounding` shape Epic 3's Citations/substring/future-local-LLM strategies must all produce identically (LSP per AR-PAT-7), so no concrete strategy or the orchestrator can be built yet.

**Approach:** Declare `SummarizerStrategy` and its full output/error/config contract in `Sources/SummarizerInterface/`, exactly per epics.md Story 3.1's ACs and architecture.md Decision 3.1's snippet + file tree. Two of the protocol's parameter types (`CanonicalTranscript`, `Glossary`) don't exist anywhere yet — Story 1.2 explicitly deferred `CanonicalTranscript` "as its own follow-up story" whose "first real consumer is Epic 3" (`deferred-work.md`), and `Glossary`'s only documented shape lives in Story 3.12's AC. Since both types must be nameable from `SummarizerInterface` (which depends only on `Core`) and from `VaultGlossary` (which also depends only on `Core`), they can only live in `Core` — this is forced by the fixed `Package.swift` dependency graph, not a design choice. This story adds minimal, structurally-complete shapes for both in `Core`; their real construction logic (transcript segmentation/normalization, vault scanning/categorization) stays out of scope for Stories 3.5 and 3.12 respectively.

**Always:**
- `SummarizerStrategy.summarize(transcript:glossary:config:)` is exactly `(CanonicalTranscript, Glossary, SummarizerConfig) async throws -> SummaryWithGrounding` — no `Meeting` parameter (AR-PAT-7 interface segregation).
- Every Codable type here that round-trips through a cache-dir artifact (`SummaryWithGrounding`, `GroundedItem`, `GroundingPointer`, `SummarizerCost`, `CanonicalTranscript`, `Glossary`) declares explicit snake_case `CodingKeys` (AR-PAT-2 cache-artifact dialect) and gets an encode/decode round-trip test, matching `Core/Codable+Dialects.swift`'s documented convention.
- `GroundingPointer.transcriptStart`/`transcriptEnd` are UTF-8 byte offsets into the canonical transcript (auricle's own convention per the 2026-09-16 revision to Decision 3.4 — not an echo of any Anthropic offset unit); `sourceMethod` is telemetry-only, never a downstream control flag.
- `SummarizerError.isFallbackEligible` is `true` only for `.citationsUnavailable`, `.malformedResponse`, `.rateLimited`, `.featureToggleDisabled`, and `false` for every other case.
- `CanonicalTranscript` and `Glossary` are declared in `Sources/Core/` (per architecture.md's file tree, which already places `CanonicalTranscript.swift` there); `SummarizerStrategy` + its output/error/config types are declared in `Sources/SummarizerInterface/`.
- Remove the placeholder `SummarizerError` from `Sources/Core/Errors.swift` and its mention in that file's top-of-file comment — that file's own comment says the bundling is only "for now," while `SummarizerInterface` "is still a placeholder with no real implementation to split alongside"; this story is that real implementation.
- All new types crossing `summarize()`'s async boundary conform to `Sendable` (Swift 6.3 strict concurrency; Decision 3.3's orchestrator is an `actor` holding a `SummarizerStrategy` existential).

**Never:**
- No "raw response" field anywhere in these types — strategies translate internally (Story 3.3+ scope).
- No concrete strategy, HTTP client, Keychain access, prompt builder, or glossary-building/vault-scanning logic in this story. `SummarizerInterface` stays protocol-only; its only dependency stays `Core` (no `Package.swift` changes — the target/test-target edges already exist).
- Don't implement `CanonicalTranscript`'s NFC/LF normalization enforcement, its build-time contract test suite, or utterance segmentation — that's Story 3.5's explicit scope (extends `Tests/CoreTests/CanonicalTranscriptContractTests.swift`). This story only defines the value type's shape.
- Don't implement `Glossary`'s vault scan, People/Projects/Concepts categorization heuristic, or fuzzy scoping — Story 3.12's scope. This story only defines the shared value type's shape (`{people, projects, concepts, uncategorized}` per Story 3.12's own AC).
- Don't give `SummarizerConfig` an API-key field — the AC's "API key reference" language is documenting that Keychain is read at call time (Story 3.3's `KeychainAPIKey.read()`), never carried in this value.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Citations unavailable | `SummarizerError.citationsUnavailable` | `isFallbackEligible == true` | orchestrator (Story 3.6) invokes fallback |
| Malformed response | `.malformedResponse` | `isFallbackEligible == true` | orchestrator invokes fallback |
| Rate limited | `.rateLimited` | `isFallbackEligible == true` | orchestrator invokes fallback |
| Feature toggle disabled | `.featureToggleDisabled` | `isFallbackEligible == true` | orchestrator invokes fallback |
| Network timeout | `.networkTimeout` | `isFallbackEligible == false` | re-thrown, no fallback |
| Auth failure | `.authenticationFailed` | `isFallbackEligible == false` | re-thrown, no fallback |
| Quota exceeded | `.quotaExceeded` | `isFallbackEligible == false` | re-thrown, no fallback |

</intent-contract>

## Code Map

- `Sources/Core/Errors.swift:1-13,30-37` -- existing. Delete the `SummarizerError` enum (lines 30-37) and drop `SummarizerInterface` from the top comment's "still a placeholder" target list; `CaptureError`/`TranscribeError`/`PersistError`/`VerifierError` stay untouched.
- `Sources/Core/Codable+Dialects.swift` -- existing, read-only. `CacheArtifactDialectExample`/`CLIOutputDialectExample` are the two dialects; every new Codable type here follows the snake_case (cache-artifact) side.
- `Sources/Core/PipelineState.swift` -- existing, read-only. Style reference for a `String, Sendable, Codable, CaseIterable` raw-value enum (`GroundingMethod`, `EffortLevel` follow this shape).
- `Tests/CoreTests/DialectsTests.swift` -- existing, read-only. Round-trip + key-presence test pattern to replicate for `CanonicalTranscript`/`Glossary`.
- `_bmad-output/planning-artifacts/architecture.md:1314-1358` -- Decision 3.1's `SummarizerStrategy`/`SummaryWithGrounding`/`GroundedItem`/`GroundingPointer`/`GroundingMethod` Swift snippet (authoritative shape).
- `_bmad-output/planning-artifacts/architecture.md:2321-2328` -- SummarizerInterface's target file tree: `SummarizerStrategy.swift`, `SummaryWithGrounding.swift`, `GroundedItem.swift`, `GroundingPointer.swift`, `GroundingMethod.swift`, `SummarizerConfig.swift`, `SummarizerError.swift` (`SummarizerCost` bundles into `SummaryWithGrounding.swift` per AR-PAT-1's coupled-secondary-type allowance — not separately listed).
- `_bmad-output/planning-artifacts/architecture.md:2265` -- `CanonicalTranscript.swift` is listed under `Sources/Core/`.
- `_bmad-output/planning-artifacts/epics.md:1340-1373` -- Story 3.1's full ACs (exact protocol signature, exact field lists, exact error cases).
- `_bmad-output/planning-artifacts/epics.md:1759-1763` -- Story 3.12 AC: `Glossary` shape is `{people: [...], projects: [...], concepts: [...]}` plus an "uncategorized" fallback for non-standard vaults.
- `_bmad-output/implementation-artifacts/deferred-work.md:13-15` -- `CanonicalTranscript` was deferred out of Story 1.2; "first real consumer is Epic 3."
- `Sources/Persist/SummaryArtifact.swift` -- existing, read-only, **not modified**. Epic 2's independent, already-flattened read-side contract for the same `summary.json` (quotes already resolved to strings, plus non-summarization fields like `title`/`attendees`). Forward note for Story 3.7: bridging `SummaryWithGrounding`'s `GroundingPointer` into `SummaryArtifact`'s rendered `quote: String` is that story's job, not this one's.
- `Package.swift:64,79,109,117` -- existing, read-only. `SummarizerInterface` target/test-target already depend only on `Core`/`TestSupport`; no manifest changes needed.

## Tasks & Acceptance

**Execution:**
- `Sources/Core/CanonicalTranscript.swift` -- new -- `public struct CanonicalTranscript: Codable, Sendable, Equatable { public let text: String; public struct Utterance: Codable, Sendable, Equatable { let speakerLabel: String; let start: Int; let end: Int }; public let utterances: [Utterance]; public var utteranceCount: Int { utterances.count } }`, snake_case `CodingKeys` (`speaker_label`) -- minimal shape the protocol signature and Story 3.5's block-index mapping need; normalization/segmentation logic deferred to Story 3.5.
- `Sources/Core/Glossary.swift` -- new -- `public struct Glossary: Codable, Sendable, Equatable { public let people: [String]; public let projects: [String]; public let concepts: [String]; public let uncategorized: [String] }` with a memberwise `init` defaulting each list to `[]`, snake_case `CodingKeys` -- shape matches Story 3.12's AC; vault-scan/categorization logic deferred to that story.
- `Sources/Core/Errors.swift` -- modify -- remove `SummarizerError`, trim the top comment's target list.
- `Sources/SummarizerInterface/SummarizerStrategy.swift` -- new -- `public protocol SummarizerStrategy: Sendable { func summarize(transcript: CanonicalTranscript, glossary: Glossary, config: SummarizerConfig) async throws -> SummaryWithGrounding }`.
- `Sources/SummarizerInterface/SummaryWithGrounding.swift` -- new -- `public struct SummaryWithGrounding: Codable, Sendable, Equatable { schemaVersion: Int; summary: String; actionItems: [GroundedItem]; decisions: [GroundedItem]; groundingMethod: GroundingMethod; cost: SummarizerCost }` + coupled `public struct SummarizerCost: Codable, Sendable, Equatable { inputTokens: Int; outputTokens: Int; thinkingTokens: Int; costUSD: Double }`, both with snake_case `CodingKeys`.
- `Sources/SummarizerInterface/GroundedItem.swift` -- new -- `public struct GroundedItem: Codable, Sendable, Equatable { text: String; grounding: GroundingPointer }`, snake_case `CodingKeys`.
- `Sources/SummarizerInterface/GroundingPointer.swift` -- new -- `public struct GroundingPointer: Codable, Sendable, Equatable { transcriptStart: Int; transcriptEnd: Int; sourceMethod: GroundingMethod }`, snake_case `CodingKeys`.
- `Sources/SummarizerInterface/GroundingMethod.swift` -- new -- `public enum GroundingMethod: String, Sendable, Codable, CaseIterable { case citations, substring }`.
- `Sources/SummarizerInterface/SummarizerConfig.swift` -- new -- `public struct SummarizerConfig: Sendable, Equatable { modelIdentifier: String; effortLevel: EffortLevel; promptCachingEnabled: Bool; remainingCostBudgetUSD: Double? }` with `init` defaults `modelIdentifier: "claude-opus-5"`, `effortLevel: .medium`, `promptCachingEnabled: true`, `remainingCostBudgetUSD: nil` (per NFR-I6 + epic-3-context.md's locked default), no `CodingKeys` (not JSON-serialized) + coupled `public enum EffortLevel: String, Sendable, Codable, CaseIterable { case low, medium, high, xhigh, max }`.
- `Sources/SummarizerInterface/SummarizerError.swift` -- new -- `public enum SummarizerError: Error, Sendable { case citationsUnavailable, malformedResponse, rateLimited, featureToggleDisabled, networkTimeout, authenticationFailed, quotaExceeded; public var isFallbackEligible: Bool { ... } }` per the I/O matrix above.
- `Sources/SummarizerInterface/ManifestPlaceholder.swift` -- delete -- superseded by real content.
- `Tests/CoreTests/CanonicalTranscriptTests.swift` -- new -- round-trip encode/decode, snake_case key assertion, `utteranceCount` reflects `utterances.count`.
- `Tests/CoreTests/GlossaryTests.swift` -- new -- round-trip encode/decode, snake_case key assertion, default-empty-lists init.
- `Tests/SummarizerInterfaceTests/SummaryWithGroundingTests.swift` -- new -- round-trip + snake_case key assertions for `SummaryWithGrounding`, `GroundedItem`, `GroundingPointer`, `SummarizerCost` (nested).
- `Tests/SummarizerInterfaceTests/SummarizerErrorTests.swift` -- new -- one `@Test` asserting `isFallbackEligible` for all 7 cases per the I/O matrix.
- `Tests/SummarizerInterfaceTests/SummarizerConfigTests.swift` -- new -- default `init()` yields `modelIdentifier == "claude-opus-5"`, `effortLevel == .medium`.

**Acceptance Criteria:**
- Given the `SummarizerInterface` target, when `swift build --explicit-target-dependency-import-check error` runs, then it compiles with `Core` as the only cross-target import and no `Package.swift` changes were needed.
- Given `SummaryWithGrounding`/`GroundedItem`/`GroundingPointer`/`SummarizerCost`/`CanonicalTranscript`/`Glossary`, when each is encoded via `JSONEncoder` and re-decoded, then the result equals the original and the JSON contains only snake_case keys (no camelCase key present).
- Given `SummarizerError`, when `isFallbackEligible` is read for each of the 7 cases, then it matches the I/O matrix exactly.
- Given `Sources/Core/Errors.swift` after this change, when inspected, then it no longer declares `SummarizerError` and its top comment no longer names `SummarizerInterface`.
- Given the full suite, when `swift test` runs, then all existing tests still pass alongside the new ones (no regression from the `Errors.swift` edit).

## Spec Change Log

## Review Triage Log

### 2026-09-17 — Review pass
- verdicts: 18 findings — high 0, medium 4, low 6, false 8, maybe-false 0
- findings:
  - `[low]` `[defer]` (Blind Hunter) `Core/Errors.swift`'s top comment and `PersistError`'s doc comment still say `Persist` "is still a placeholder with no real implementation" — false, `Sources/Persist/` has shipped `PersistStage.swift` etc. since Epic 2. Pre-existing: this wording predates this story (verified against the pre-diff baseline, which already read "SummarizerInterface, Persist" in the same false claim) — this diff only removed `SummarizerInterface` from the list and didn't introduce or touch the `Persist` inaccuracy.
  - `[false]` `[reject]` (Blind Hunter) Code Map cites architecture.md's Decision 3.1 snippet as "authoritative shape" even though that snippet's own inline comment says "character offset," superseded by Decision 3.4's UTF-8-byte-offset revision. Checked: the spec's own "Always" section states the correct UTF-8-byte-offset convention explicitly and separately, and the shipped `GroundingPointer` doc comment states it too — a reader of the whole spec (not one isolated citation) gets the current, correct unit; the implementation itself is correct.
  - `[low]` `[patch]` (Blind Hunter) `CanonicalTranscript`/`Glossary`'s `CodingKeys` are identity mappings with nothing explaining why they're kept rather than omitted, inviting a future "cleanup" that would silently break the AR-PAT-2 dialect guarantee. Fixed: added a comment on each `CodingKeys` block explaining the dialect-declaration rationale.
  - `[low]` `[patch]` (Blind Hunter) `SummarizerError`'s three new cases (`networkTimeout`, `authenticationFailed`, `quotaExceeded`) had no doc comments, unlike the four original cases. Fixed: added a one-line doc comment to each.
  - `[false]` `[reject]` (Blind Hunter) Round-trip tests only encode-then-decode the same value, so a `CodingKeys` rename would allegedly still pass. Checked: every round-trip test also asserts `json.contains(...)` on the exact snake_case key string (and `!json.contains(...)` on the camelCase spelling where one exists) — a renamed key would fail those substring assertions independently of the round-trip itself.
  - `[low]` `[patch]` (Blind Hunter) `SummarizerConfigTests` only exercised the default initializer; the memberwise init and `Equatable` were untested. Fixed: added a test constructing `SummarizerConfig` with all four fields non-default, asserting the fields and both an equal and an unequal comparison.
  - `[medium]` `[patch]` (Blind Hunter) `CanonicalTranscript.Utterance.start`/`end` carried no doc comment on their unit, unlike `GroundingPointer`'s explicitly-documented UTF-8 byte offsets — a real risk given Decision 3.4 frames offset-unit ambiguity as this group's single most load-bearing risk. Fixed: added matching doc comments stating the UTF-8-byte-offset convention.
  - `[false]` `[reject]` (Blind Hunter) Claimed nothing pins down that a near-miss type name (e.g. `CanonicalTranscriptWrapper`) still trips the rule. Checked directly with `swiftlint lint` against a `CanonicalTranscriptWrapper.self` probe: it still violates, both before and after the later regex fix below — the exemption was never over-broad in that direction.
  - `[low]` `[reject]` (Blind Hunter) Spec's own AC promises "no regression from the `Errors.swift` edit" via `swift test`, but the Verification section only lists filtered commands. Per this workflow's own rule, a finding whose fix is to edit this build's spec is rejected outright; separately, the unfiltered `swift test` was in fact run independently during step-03 Verify (198/198, then 199/199 after patches) and during this review pass, so the claim is already satisfied in practice.
  - `[false]` `[reject]` (Edge Case Hunter) `CanonicalTranscript.Utterance`'s initializer lacks a bounds precondition (`start >= 0 && end >= start`). Checked: no code anywhere constructs an out-of-range `Utterance` today (only valid test fixtures exist), and a `precondition` trap would not even guard the realistic threat (a corrupted on-disk decode) since `Codable` synthesis assigns decoded fields directly, bypassing the custom `init` entirely. Real bounds validation belongs to Story 3.5's block-index mapping logic, which can surface a typed, catchable error — consistent with this codebase's typed-error convention (AR-PAT-7) instead of a crash trap.
  - `[false]` `[reject]` (Edge Case Hunter) `GroundingPointer`'s initializer lacks the same bounds precondition. Checked: epics.md Story 3.5's AC explicitly assigns bounds-checking to `CitationGroundingValidator.validate(...)` (throwing `SummarizerError.malformedResponse`), a dedicated validator type that doesn't exist yet — adding a precondition here would preempt and duplicate that story's own typed-error-based design with a process-crashing trap instead.
  - `[medium]` `[patch]` (Edge Case Hunter, same root cause as Verification Gap Reviewer's finding below) `transcript_decode_bypass`'s regex exemption required `CanonicalTranscript` immediately after `decode(` with no whitespace, so a legitimately-formatted multi-line decode call still false-positived. Fixed below.
  - `[medium]` `[patch]` (Verification Gap Reviewer, arrives pre-verified) Same regex-whitespace defect, reproduced directly via `swiftlint lint` against a multi-line probe. Fixed: added `\s*` tolerance — but my own re-verification of that first fix found it was still broken (the wildcard could backtrack past `\s*` and match "Transcript" as a substring of "CanonicalTranscript" itself, re-admitting the false positive). Replaced with a possessive `\s*+`, which cannot give characters back to backtracking; re-verified against four probes (multi-line and single-line `CanonicalTranscript.self`, array-form `[CanonicalTranscript].self`, and near-miss `CanonicalTranscriptWrapper.self`/`TranscriptPayload.self`) plus the repo's own `scripts/verify-custom-lint-rules.sh` fixture self-check (13/13 markers still fire). VG's own noted residual — that `scripts/verify-custom-lint-rules.sh` has no syntax to assert a line must *not* violate a rule, so this exemption still has no automated regression guard — is a pre-existing limitation of that script's design (not introduced by this story) and is left as-is; the correctness fix above closes the actual false-positive.
  - `[low]` `[patch]` (Intent Alignment Auditor) The `.swiftlint.yml` comment claimed decoding into `CanonicalTranscript.self` "IS the canonicalization layer," overstating what the bare-struct type currently enforces (nothing yet). Fixed: reworded to say the exemption is because it's the correct decode *target*, not because decoding alone normalizes, and named Story 3.5 as still owning enforcement.
  - `[medium]` `[patch]` (Intent Alignment Auditor) `epic-3-context.md`'s Cross-Story Dependencies bullet credited Story 1.2 with introducing a `CanonicalTranscript` contract test — false, Story 1.2 deferred the type entirely per `deferred-work.md`. Same failure pattern already flagged once for `epic-1-context.md` in `deferred-work.md`'s own log (a future story's investigation could be misled by a stale cached-context claim). Fixed: corrected the bullet to credit this story's round-trip test instead.
  - `[false]` `[reject]` (Intent Alignment Auditor) Raised `SummarizerConfig`'s omitted API-key field as "an equally defensible" alternative reading (a non-secret reference field). Checked against Story 3.3's own AC: `KeychainAPIKey.read()` takes zero parameters — there is no reference value for such a field to carry, so the omission is the only reading consistent with the already-specified Keychain API, not an arbitrary pick between equally valid options.
  - `[false]` `[reject]` (Intent Alignment Auditor) Noted the diff bundles epic-level narrative (`epic-3-context.md`) that this diff's own tests don't exercise. The auditor's own text calls this "consistent with this repo's established per-story convention, not fabricated" — not a claimed defect.
  - `[false]` `[reject]` (Intent Alignment Auditor) Noted test coverage skews toward config/error semantics rather than the bare protocol. The auditor's own text calls this "expected, since protocols aren't independently testable without a conforming type" — not a claimed defect.

## Design Notes

**Why `CanonicalTranscript`/`Glossary` land here, in `Core`, instead of waiting for Stories 3.5/3.12:** the protocol signature epics.md's AC fixes (`func summarize(transcript: CanonicalTranscript, glossary: Glossary, ...)`) requires both names to resolve at compile time. `deferred-work.md` already flags `CanonicalTranscript` as deferred "to its own follow-up story" whose "first real consumer is Epic 3" — this story is that consumer. Both types must be visible to `SummarizerInterface` (`→ Core` only) and to their eventual real producers (`VaultGlossary → Core` only per `Package.swift`); `Core` is the only target both sides already depend on, so this isn't a design choice being made here, it's the one placement the existing dependency graph permits. Keeping each type's *shape* minimal (no normalization/segmentation logic, no vault-scan logic) keeps this story inside its own stated scope while unblocking every later Epic 3 story that needs the names to exist.

**Why `SummarizerError` moves out of `Core/Errors.swift`:** that file's own comment says five domains are bundled there only because their owning targets are "still a placeholder with no real implementation to split alongside" (AR-PAT-1's coupled-file allowance is explicitly temporary). `SummarizerInterface` stops being a placeholder in this story, so its error type moves to live beside the protocol it's thrown from — matching architecture.md's file tree, which places `SummarizerError.swift` inside `SummarizerInterface/`, not `Core/`. No other file references the old location (verified via repo-wide grep), so the move is a clean cut, not a compatibility-preserving deprecation.

**`Sendable` on `SummarizerStrategy` and every value type:** Decision 3.3's `SummarizerOrchestrator` is a Swift `actor` holding `primary`/`fallback` as `SummarizerStrategy` existentials and passing these value types across its isolation boundary. Swift 6.3's strict concurrency mode requires `Sendable` for that to compile without an `@unchecked` escape hatch — this story adds the conformance now so Story 3.6 doesn't inherit a retrofit.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build, no new cross-target edges beyond the existing `SummarizerInterface → Core`.
- `swift test --filter CoreTests` -- expected: existing Core tests plus new `CanonicalTranscriptTests`/`GlossaryTests` pass.
- `swift test --filter SummarizerInterfaceTests` -- expected: new tests pass (first real tests in this target).
- `swiftformat --lint .` && `swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations.

## Auto Run Result

**Summary:** Implemented `SummarizerInterface`'s `SummarizerStrategy` protocol and its full normalized-output/config/error contract (`SummaryWithGrounding`, `GroundedItem`, `GroundingPointer`, `GroundingMethod`, `SummarizerCost`, `SummarizerConfig`, `SummarizerError`), exactly per epics.md Story 3.1's ACs and architecture.md Decision 3.1. Two prerequisite value types the protocol signature requires but that didn't exist anywhere yet — `CanonicalTranscript` (deferred out of Story 1.2 per `deferred-work.md`, first real consumer is this story) and `Glossary` (shape fixed by Story 3.12's own AC) — were added to `Core` in minimal form, since both must be visible to `SummarizerInterface` and to their eventual real producer targets, which only depend on `Core`. The placeholder `SummarizerError` that had been bundled in `Core/Errors.swift` since Story 1.2/1.3 was moved to live beside the protocol it's thrown from, matching architecture.md's file tree. A review pass across four independent layers found 18 findings; 7 were patched, 1 deferred, 10 rejected — detail below.

**Files changed:**
- `Sources/Core/CanonicalTranscript.swift` -- new. Minimal `CanonicalTranscript` + `Utterance` value type (text, utterances, UTF-8 byte-offset `start`/`end`), snake_case `CodingKeys`.
- `Sources/Core/Glossary.swift` -- new. `{people, projects, concepts, uncategorized}`, snake_case `CodingKeys`.
- `Sources/Core/Errors.swift` -- modified. Removed the placeholder `SummarizerError`; trimmed the top comment's bundled-domain list from five to four.
- `Sources/SummarizerInterface/SummarizerStrategy.swift` -- new. The protocol: `summarize(transcript:glossary:config:) async throws -> SummaryWithGrounding`.
- `Sources/SummarizerInterface/SummaryWithGrounding.swift` -- new. The normalized output shape plus coupled `SummarizerCost`.
- `Sources/SummarizerInterface/GroundedItem.swift`, `GroundingPointer.swift`, `GroundingMethod.swift` -- new. The grounding-pointer contract.
- `Sources/SummarizerInterface/SummarizerConfig.swift` -- new. Config value plus coupled `EffortLevel` enum; no API-key field by design.
- `Sources/SummarizerInterface/SummarizerError.swift` -- new. 7-case typed error with `isFallbackEligible`.
- `Sources/SummarizerInterface/ManifestPlaceholder.swift` -- deleted, superseded.
- `Tests/CoreTests/CanonicalTranscriptTests.swift`, `GlossaryTests.swift` -- new. Round-trip + snake_case-key tests.
- `Tests/SummarizerInterfaceTests/SummaryWithGroundingTests.swift`, `SummarizerErrorTests.swift`, `SummarizerConfigTests.swift` -- new. Round-trip, fallback-eligibility matrix, and memberwise-init/`Equatable` coverage.
- `.swiftlint.yml` -- modified. `transcript_decode_bypass`'s regex now exempts `CanonicalTranscript.self`/`[CanonicalTranscript].self` via a possessive `\s*+` (a plain `\s*` was tried first and found, on my own re-verification, to still false-positive via backtracking into "Transcript" as a substring of "CanonicalTranscript"); its comment no longer overstates what the bare type currently enforces.
- `_bmad-output/implementation-artifacts/epic-3-context.md` -- modified. Corrected a Cross-Story-Dependencies bullet that wrongly credited Story 1.2 with a `CanonicalTranscript` contract test it never built.

**Review findings breakdown (one pass, four parallel layers — Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor; 18 findings total):**
- **Patched (7 entries — 3 medium, 4 low, all applied and re-verified):** `CanonicalTranscript`/`Glossary`'s identity-mapping `CodingKeys` left unexplained; `SummarizerError`'s three new cases lacking doc comments; `SummarizerConfig`'s memberwise init/`Equatable` untested; `CanonicalTranscript.Utterance`'s offsets undocumented; the `transcript_decode_bypass` regex's whitespace-intolerance false-positive (found independently by two layers, and only fully fixed after my own re-verification caught the first fix's residual bug); the swiftlint comment overstating what `CanonicalTranscript` enforces; `epic-3-context.md`'s false Story-1.2 attribution.
- **Deferred (1, low):** `Core/Errors.swift`'s stale "Persist is still a placeholder" claim — pre-existing (predates this story), recorded in frontmatter `deferred`.
- **Rejected (10):** architecture.md citation labeled "authoritative" despite one stale inline comment (the spec's own Always section and the shipped code already carry the correct, current unit); round-trip tests claimed insufficient to catch a `CodingKeys` rename (they independently assert on the exact JSON key strings); a near-miss type name claimed able to slip past the lint exemption (verified it still can't); a spec AC/Verification-section mismatch (rejected per this workflow's own rule against fixing findings by editing the spec; also already independently satisfied); missing bounds-validation preconditions on `Utterance`/`GroundingPointer` initializers (unreachable today, and the codebase's own design assigns that validation to Story 3.4/3.5's typed-error validators, not a precondition trap); `SummarizerConfig`'s omitted API-key field called "equally defensible" either way (refuted by Story 3.3's own zero-argument `KeychainAPIKey.read()`); two Intent Alignment Auditor observations that were self-described as consistent with convention / expected, not defects.

**Follow-up review recommendation: `true`.** Three of this pass's patched entries were `medium` severity (at or above the two-or-more-medium threshold). Specific unverified risk: the `transcript_decode_bypass` regex fix was verified manually against five hand-built probes plus the existing fixture script during this pass, but no permanent regression test was added to `scripts/lint-fixtures/CustomLintRuleFixtures.swift` proving the multi-line exemption keeps working after a future edit to this regex or a swiftlint upgrade — `scripts/verify-custom-lint-rules.sh` also has no marker syntax to assert a line must *not* violate a rule, so this exemption category could regress silently. A follow-up pass could reasonably add that regression coverage (likely as its own small piece of tooling work, since it needs a new marker convention, not a one-line fixture addition).

**Verification performed:** `swift build --explicit-target-dependency-import-check error` clean, no new cross-target edges. `swift test` (full suite, unfiltered): 199/199 pass (was 198/198 before the patch pass's added test). `swiftformat --lint .`: 0/120 files need formatting. `swiftlint lint --strict --config .swiftlint.yml .`: 0 violations across 119 files. `scripts/verify-custom-lint-rules.sh`: 13/13 markers still fire correctly. The `transcript_decode_bypass` fix was independently probed against multi-line and single-line `CanonicalTranscript.self`, array-form `[CanonicalTranscript].self` (all must pass clean — confirmed), and `CanonicalTranscriptWrapper.self`/`TranscriptPayload.self` (both single- and multi-line; must still violate — confirmed). All commands re-run by the orchestrating agent after the patch pass, not just trusted from the implementation subagent's report — including catching and re-fixing a residual bug in that subagent's first attempt at the regex fix.

**Residual risks:** the named follow-up-review risk above (no permanent regression test for the lint-exemption's multi-line correctness). Everything else rejected above is judged unreachable, already-correct, or explicitly out of this story's scope per the intent itself (typed-error validation ownership sits with Stories 3.4/3.5, not this story's bare value types).
