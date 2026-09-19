---
title: 'Story 3.9: Pipeline Regression Harness -- Frozen Transcripts + Stubbed Responses'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: 'bba0180dede975336000dc5447395b980107bfce'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      Tie the eval harness's default-wiring arm to the real composition root once Story 3.8 locks the default.
    evidence: |-
      `EvalDefaultWiring` in `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift` hard-codes Citations primary and substring fallback, mirroring the provisional wiring in `App/auricle-cli/Verbs/InternalStageWorker.swift:76-81`. `App/` has no test target, so nothing checks the two agree. When Story 3.8 flips the primary, the harness keeps running Citations-primary and no test fails. Both strategies still run on every fixture (Citations through the orchestrator, substring standalone), so no coverage is lost; only the "default wiring" label goes stale.
    location: >-
      Tests/SummarizeTests/SummarizeEvalHarnessTests.swift (EvalDefaultWiring)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Six frozen transcripts with hand-curated `expected.json` already exist (PR #32) but nothing runs them. A regression in the grounding validators, the grounding-to-artifact mapping, or the note renderer would ship silently until Epic 4 puts real audio through the pipeline.

**Approach:** Add a fixture-driven Swift Testing suite, `SummarizeEvalHarness`, in `Tests/SummarizeTests/`. It runs the real strategies against stubbed Anthropic responses built only from each fixture, maps and renders the result with the real mapper and `FrontmatterRenderer`, scores it against `expected.json`, and prints one summary line per fixture. It measures the validator, mapping and renderer, never prompt quality.

## Boundaries & Constraints

**Always:**
- Stub at the HTTP layer (`URLProtocol` on the `AnthropicHTTPClient` session), so the real `ClaudeCitationsSummarizer`, `ClaudeSubstringSummarizer`, both validators, `SummarizerOrchestrator`, `SummaryArtifactMapper` and `FrontmatterRenderer` all run.
- A stub is a pure function of the fixture (`transcript.json` + `expected.json`). It ignores the request body, so a prompt change cannot move any result.
- Two arms per fixture. (1) Default wiring: `SummarizerOrchestrator(primary: Citations, fallback: Substring)`, mirroring the provisional wiring in `InternalStageWorker.swift`; the wiring lives in one named place so Story 3.8's lock-in changes one spot. (2) Substring standalone.
- The substring stub adds one ungrounded decoy item per section (`action_items`, `decisions`) whose quote is a sentence the harness first proves is absent from the transcript. The Citations stub emits exactly the expected items, each cited to its owner utterance block (`end_block_index` exclusive).
- Targets come from `expected.json` `targets`. Each key is optional; project defaults are `min_recall` 0.8, `max_false_keeps` 1, `max_drop_rate` 0.2. `targets` itself is optional too.
- Scoring is a pure function with its own tests, including inputs that must fail.
- A fixture directory with `transcript.json` + `expected.json` is picked up by both this suite and `EvalFixtureContractTests` with no per-fixture code.
- Real logic stays test-side; no `Sources/` change.

**Never:**
- No live API call, no network, no assertion on request contents or prompt text.
- Don't edit any existing fixture transcript or `expected.json`.
- Don't change strategy, validator, mapper or renderer behaviour.
- Don't decide Story 3.8's default or touch the composition roots.
- Don't add a CI workflow file or a path filter. `scripts/check.sh swift` already runs every test on every PR.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Default wiring, fixture with items | Citations stub emits each expected item cited at its owner utterance | All items kept, no fallback, `grounding_method=citations`; rendered note has each item text and a `> ` line containing its quote | Failure lists the failed check |
| Substring arm | Stub emits expected items plus one decoy per section | Decoys dropped; reported drop count equals decoy count; each expected pointer slices to text containing its quote | Decoy kept fails regardless of `max_false_keeps` |
| Fixture with no expected items | `office-space-interview` | Citations: zero items, no throw. Substring: decoys only, all dropped. Kept 0, false-keeps 0 | No error |
| Expected item missing from kept | Scorer given a summary without it | Recall below `min_recall` fails, naming the item's section and index | Failure recorded |
| Pointer at wrong text | Kept item's slice lacks the expected quote | Not counted as survived | Failure recorded |
| Kept item matches nothing expected | Extra grounded item | Counts as a false-keep; over `max_false_keeps` fails | Failure recorded |
| Item text absent from the note | Note lacks an expected item's text or its `> ` quote line | Failure recorded | Failure recorded |
| Targets absent or partial | `targets` missing, or only some keys | Missing keys use project defaults | No error |
| Summary line | Any run | `Fixture <name>: kept N items (M expected) · dropped K · false-keeps F · grounding_method=<method>` printed once per arm run | No error |

</intent-contract>

## Code Map

- `Tests/SummarizeTests/EvalFixtureContractTests.swift` -- holds private copies of the fixture model (`ExpectedItem`, `ExpectedTargets`, `ExpectedFixture`) and `EvalFixtures` loader. Its `targets` is required, which contradicts the optional-targets AC. Moves to the shared file below.
- `Tests/SummarizeTests/Fixtures/eval/*/{transcript,expected}.json` -- six read-only fixtures; all quotes are ASCII, and each quote's first occurrence is at its stated offset. `expected.json` keys: `schema_version`, `source`, `speakers`, `action_items`, `decisions` (`text`, `quote`, `transcript_start`, `transcript_end`), `targets`, `notes`. Also `NOTICE.md`; every fixture must be listed there.
- `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift:17-100` and `Tests/SummarizeTests/CrossModeFixtureTests.swift:16-90` -- the file-local `URLProtocol` stub, per-test unique endpoint and `AnthropicHTTPClient(session:endpoint:apiKeyProvider:sleep:)` pattern to copy. `CrossModeFixtureTests.swift:110-165` shows both envelope shapes.
- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift:121-170,297-330` -- decoder contract: first text block holds the JSON answer (`summary`, `action_items[{text, source_block_index}]`, `decisions[...]`); then one citation-bearing block per item (`citations[0].start_block_index`/`end_block_index`), actions first. Zero items skips the citation check.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift:94-135` -- answer shape `action_items[{text, source_transcript_quote}]`; an unmatched quote is dropped and counted in `quoteValidationDropCount`.
- `Sources/ClaudeSummarizer/SubstringGroundingValidator.swift`, `CitationGroundingValidator.swift` -- literal case-sensitive first-match; block index to utterance byte range.
- `Sources/Summarize/SummarizerOrchestrator.swift` -- `Outcome{summary, fallbackTriggered, primaryError}`.
- `Sources/Summarize/SummaryArtifactMapper.swift`, `TranscriptSlicer.swift` -- internal (`@testable import Summarize`): `transcriptSegments(of:transcriptBytes:speakers:)` and `artifact(title:grounded:transcriptSegments:needsAttribution:transcriptBytes:)`.
- `Sources/Persist/PersistStage.swift:178-198` -- private `frontmatterMeeting` maps `SummaryArtifact` to `MeetingForFrontmatter` field by field; the harness adapter mirrors it. `Sources/Persist/FrontmatterRenderer.swift:87-113` renders items as `- text\n  > quote`. `MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!` is the constant other tests use.
- `App/auricle-cli/Verbs/InternalStageWorker.swift:76-81` -- the provisional Citations-primary, substring-fallback wiring to mirror.
- `Package.swift:144-148` -- `SummarizeTests` deps lack `Persist`; `--explicit-target-dependency-import-check error` needs it declared. `Persist` deps (`Core`, `State`, `Telemetry`, `Orchestrator`, Yams) create no cycle.
- `.swiftlint.yml` -- `composition_root_strategy_bypass` already excludes all of `Tests/SummarizeTests/`; `file_length` warns at 500.
- `scripts/check.sh:47-58` (`phase_swift`) -- runs the full `swift test`; unchanged.
- `_bmad-output/planning-artifacts/epics.md:1646-1680` -- Story 3.9 ACs.

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add `Persist` to `SummarizeTests` dependencies -- the harness imports the real renderer.
- `Tests/SummarizeTests/EvalFixtures.swift` -- new shared internal model and loader (`EvalFixture`, item, `EvalTargets` with optional keys and `effective` defaults incl. `max_drop_rate`, `EvalFixtures.names/load`) -- one schema for the contract tests and the harness.
- `Tests/SummarizeTests/EvalFixtureContractTests.swift` -- drop the private copies, use the shared model, check the effective targets are in range -- the optional-targets AC.
- `Tests/SummarizeTests/EvalStubResponses.swift` -- `URLProtocol` stub, `AnthropicHTTPClient` factory, and pure envelope builders (Citations from expected items; substring from expected items plus decoys) -- deterministic stubs.
- `Tests/SummarizeTests/EvalScoring.swift` -- pure `EvalScorer` (recall, unexpected-drop rate, false-keeps, decoy-kept, note checks) returning `EvalScore` with `failures` and `summaryLine` -- assertions and the audit line.
- `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift` -- suite `SummarizeEvalHarness`: fixture-count guard (>= 5), default-wiring test and substring-arm test, each `arguments: EvalFixtures.names`; runs, maps, renders, scores, prints the line, expects no failures -- the harness itself.
- `Tests/SummarizeTests/SummarizeEvalHarnessScoringTests.swift` -- one test per scoring matrix row using hand-built summaries and notes, incl. the failing ones -- proves the harness can fail.
- `Tests/SummarizeTests/Fixtures/eval/README.md` -- how to add a fixture, the targets and defaults, that the harness does not measure prompts, and that any change to a target or expected item needs a stated rationale in the PR description -- the rationale AC.
- `.github/pull_request_template.md` -- one prompt asking for the rationale when eval targets or expected outputs change -- makes the rule visible when a PR opens.

**Acceptance Criteria:**
- Given the fixtures, when `swift test --filter SummarizeEvalHarness` runs, then each fixture passes both arms and one summary line per arm run is printed in the specified format.
- Given a deliberately broken validator (grounding any quote, or mapping the wrong block), when the filtered suite runs, then it fails; the change is reverted afterwards.
- Given a new directory under `Fixtures/eval/` with only `transcript.json`, `expected.json` and a `NOTICE.md` entry, when the suite runs, then both the harness and the contract tests cover it with default targets and no Swift edit.
- Given the full gate, when `scripts/check.sh lint` and `scripts/check.sh swift` run, then both pass.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 37 findings — high 0, medium 7, low 28, false 2, maybe-false 0
- findings:
  - `[low]` `[patch]` (Blind Hunter) Per-fixture `targets` never bind in the pipeline arms, because the tests also demand every expected item — real and doc-level only: the stubbed arms are deliberately stricter than the scorer's tolerance; patched by a README sentence saying so.
  - `[medium]` `[patch]` (Blind Hunter) `match` accepts a pointer whose slice merely contains the quote — real: Citations mapping `utterances[endBlockIndex]` instead of `[endBlockIndex - 1]` still passed; patched: the pointer must lie inside the owner utterance of the expected span, with two scorer tests; the mutation now fails the suite.
  - `[medium]` `[patch]` (Blind Hunter) A misspelt `targets` key silently takes the default — real: `EvalTargets` ignores unknown keys; patched: a per-fixture contract test on the raw JSON keys and declared values, plus a `max_false_keeps: 0` decode test.
  - `[low]` `[reject]` (Blind Hunter) No Citations negative control or fallback case in the default-wiring arm — `CitationGroundingValidatorTests` and `SummarizerOrchestratorTests` already cover both; a new arm adds complexity.
  - `[low]` `[reject]` (Blind Hunter) `speakers: nil` skips the attributed rendering path — attribution only changes transcript segment labels, covered by `SummaryArtifactMapperTests` and `AttributionSpeakersTests`; item quotes are unaffected.
  - `[low]` `[defer]` (Blind Hunter) Two hand-mirrored copies can drift — the wiring half is deferred with the Verification Gap row; the `frontmatterMeeting` twin half is rejected: `PersistStageTests` cover the real mapping and exposing it needs new production surface the spec forbids.
  - `[low]` `[reject]` (Blind Hunter) `scoreRun` reports at the helper's line and one defect yields several failures — cosmetic; each failure's comment names the fixture and the check.
  - `[low]` `[reject]` (Blind Hunter) The audit line is a bare `print`, not `Log` or an attachment — the `Log` claim does not apply (it is the app's logger, and the lint rule targets `os_log`/`Logger`); the 12 lines printed whole and unmixed in every run.
  - `[low]` `[reject]` (Blind Hunter) `atLeastFiveFixturesExist` is duplicated — cosmetic; each guard sits with its own suite.
  - `[low]` `[reject]` (Blind Hunter) Stub registration leaks if the second stub's builder throws — the leak is one small body in a process whose test already failed.
  - `[low]` `[reject]` (Blind Hunter) A third file-local `URLProtocol` stub — file-local is the established convention; sharing means refactoring other test targets.
  - `[low]` `[reject]` (Blind Hunter) The epsilon and exact-boundary paths are untested — IEEE division is correctly rounded, so exact ratios equal their decimal literals with or without the epsilon; no harm is reachable.
  - `[low]` `[reject]` (Blind Hunter) The PR template replaces the whole PR body and the rationale rule is unenforced — the template is one optional line; a CI gate on PR text is more machinery than one maintainer needs.
  - `[low]` `[reject]` (Blind Hunter) Note parsing is stricter than the README's "No Swift changes" claim — `FrontmatterRenderer` writes item text verbatim, and fixture item texts are single-line prose.
  - `[low]` `[reject]` (Blind Hunter) The scorer depends on `EvalSection`/`EvalDecoy` defined in the stub file — file placement only; both files are in one test target.
  - `[medium]` `[patch]` (Edge Case Hunter) Pointer stretched over neighbouring utterances still counts as survived — same root as the second Blind Hunter row; fixed by the owner-utterance containment check.
  - `[low]` `[reject]` (Edge Case Hunter) Two expected items in one section with identical text get checked against the first bullet's quote — no fixture has duplicate texts; the fix adds positional matching for an input nobody writes.
  - `[low]` `[reject]` (Edge Case Hunter) A multi-line note quote passes on its first line — unreachable now: the containment patch keeps a survivor's quote inside one single-line utterance.
  - `[medium]` `[patch]` (Edge Case Hunter) A misspelt or unknown `targets` key silently defaults — same root as the third Blind Hunter row; fixed by the raw-JSON contract test.
  - `[low]` `[reject]` (Edge Case Hunter) `frontmatterMeeting` can drift from `PersistStage` — same as the twin half of the Blind Hunter mirror row.
  - `[low]` `[reject]` (Edge Case Hunter) `defer` runs after both stubs exist, so a throw leaks one — same as the Blind Hunter stub-lifetime row.
  - `[low]` `[reject]` (Edge Case Hunter) Claim: "one summary line per fixture" but 12 lines print — the epic's line format carries `grounding_method`, so two lines per fixture are distinct and both fit; the wording sits inside the read-only intent contract.
  - `[medium]` `[patch]` (Edge Case Hunter) Claim: a wrong-block mapping fails the suite — true only when the slice lacks the quote; an owner-plus-next pointer passed; same root as the second Blind Hunter row and fixed by it.
  - `[medium]` `[patch]` (Verification Gap) The `max_false_keeps` key is never read through JSON and a misspelling defaults silently — same root as the third Blind Hunter row; fixed by the raw-JSON contract test and the decode test.
  - `[low]` `[defer]` (Verification Gap) `EvalDefaultWiring` mirrors `InternalStageWorker` and no test ties them — deferred: closing it means moving the wiring into `Sources/` after Story 3.8 locks the default; no coverage is lost meanwhile.
  - `[low]` `[patch]` (Verification Gap) README says `min_recall` items must reach "into the note", but recall counts grounding survivors and the note check is separate — patched: row reworded to "must survive grounding".
  - `[low]` `[defer]` (Intent Alignment) The configured MVP default is a test-local pairing, not read from configuration — same root as the deferred wiring row; no configuration source exists until Story 3.8.
  - `[low]` `[reject]` (Intent Alignment) Rendered output goes through a test-side twin of `PersistStage`'s mapping — same as the twin half of the mirror row.
  - `[low]` `[reject]` (Intent Alignment) `SummarizeStage.run`, the `summary.json` round trip, `PersistStage.run` and attribution are not exercised — the AC names validator, mapping and renderer; the stage entry points have `SummarizeStageTests` and `PersistStageTests`.
  - `[low]` `[reject]` (Intent Alignment) No `ci.yml` change, and "blocks the PR" depends on branch protection — `scripts/check.sh swift` runs the harness on every PR (12 lines seen in the full run); required checks are a repository setting outside this diff. Recorded as a residual risk.
  - `[low]` `[reject]` (Intent Alignment) The PR rationale is a convention, not a gate — same as the Blind Hunter template row.
  - `[medium]` `[patch]` (Intent Alignment) Survival means the slice contains the quote, so an over-wide pointer counts — same root as the second Blind Hunter row; fixed by it.
  - `[low]` `[reject]` (Intent Alignment) The Citations stub never emits a miscited item, so only substring faces adversarial input — same as the Blind Hunter negative-control row.
  - `[low]` `[reject]` (Intent Alignment) The summary line is a `print` — same as the Blind Hunter audit-line row.
  - `[false]` `[reject]` (Intent Alignment) The acceptance proofs (broken-validator run, gate output) are not in the diff — they are process checks by nature; the scorer tests carry the must-fail inputs, and both mutation runs were repeated in this pass.
  - `[low]` `[reject]` (Intent Alignment) `atLeastFiveFixturesExist` exists in two suites — same as the Blind Hunter duplicate-guard row.
  - `[false]` `[reject]` (Intent Alignment) Second reading, Decision 3.9, has no footprint — Decision 3.9 is a v1.1 local-LLM contract that "complete" cannot apply to; the branch, sprint key and epic all name Story 3.9, so there is one reading.

## Design Notes

The Citations stub cites the whole owner utterance, so its pointer covers `Speaker_N: <quote>`. Survival therefore means "the pointer's slice contains the expected quote", which holds for both methods and does not depend on which occurrence a substring match finds.

The scorer counts `reported_drops - decoys_emitted` (floored at 0) against `total_expected` as the drop rate. Decoy drops are the validator working, not a regression, and Citations never drops.

False-keep means a kept item whose text and pointer match no expected item. A kept decoy is a hard failure on top of that, because a tolerance of `max_false_keeps: 1` must not absorb the harness's own invented item.

## Verification

**Commands:**
- `swift test --explicit-target-dependency-import-check error --filter SummarizeEvalHarness` -- expected: every test passes; 12 summary lines print (6 fixtures, 2 arms).
- `scripts/check.sh lint` and `scripts/check.sh swift` -- expected: pass.

**Manual checks:**
- Temporarily make `SubstringGroundingValidator.validate` return a pointer for any quote, run the filtered suite, expect failures naming the kept decoys; revert and confirm `git diff` shows no `Sources/` change.

## Auto Run Result

**Summary of implemented change:** Story 3.9's pipeline regression harness. The six frozen fixtures from PR #32 now run on every test run as suite `SummarizeEvalHarness`. Each fixture goes through two arms: the default wiring (`SummarizerOrchestrator` with Citations primary and substring fallback) and the substring strategy alone. Stubbed Anthropic responses are built from `expected.json` and served at the HTTP layer, so the real strategies, validators, orchestrator, `SummaryArtifactMapper` and `FrontmatterRenderer` all run. A pure scorer checks recall, false-keeps, unexpected drops, kept decoys and the rendered note against per-fixture targets, and one summary line per arm run is printed. The substring stub adds one ungrounded decoy per section that the validator must drop. `targets` in `expected.json` became optional key by key, with project defaults 0.8 / 1 / 0.2 (`max_drop_rate` is new).

**Files changed:**
- `Package.swift` -- `Persist` added to the `SummarizeTests` dependencies for the real renderer.
- `Tests/SummarizeTests/EvalFixtures.swift` -- shared fixture model, optional targets with defaults, loader.
- `Tests/SummarizeTests/EvalFixtureContractTests.swift` -- uses the shared model; adds a raw-JSON check that `targets` keys are known and their declared values are the effective ones.
- `Tests/SummarizeTests/EvalStubResponses.swift` -- `URLProtocol` stub, Citations and substring response builders, decoys.
- `Tests/SummarizeTests/EvalScoring.swift` -- pure scorer and summary line.
- `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift` -- the fixture-driven suite (guard, default-wiring arm, substring arm).
- `Tests/SummarizeTests/SummarizeEvalHarnessScoringTests.swift` -- 24 scorer tests including the must-fail inputs.
- `Tests/SummarizeTests/Fixtures/eval/README.md`, `.github/pull_request_template.md` -- how to add a fixture, the targets, and the rationale rule for changing them.

**Review findings breakdown:** 37 findings across 4 layers -- 0 high, 7 medium, 28 low, 2 false. Full per-finding detail is in `## Review Triage Log`.
- **Patched (3 entries: 2 medium, 1 low):** the scorer now requires a survivor's pointer to lie inside the utterance that holds the expected span (an owner-plus-next-utterance pointer used to pass; found by three layers); a contract test rejects unknown `targets` keys and checks declared values (found by three layers); README wording fixed.
- **Deferred (1):** tie `EvalDefaultWiring` to the real composition root once Story 3.8 locks the default (low; recorded in `deferred`).
- **Rejected (33):** each with its reason in the log. Main groups: stage-level and attribution coverage belongs to other suites; the `PersistStage` mapping twin needs new production surface the spec forbids; stub-lifetime, print-versus-attachment, duplicate-guard and boundary-epsilon points are cosmetic or unreachable; two findings were false.
- **Follow-up review recommendation:** `true`. Two medium entries were patched. The named unverified risk: the "no owner utterance found" branch of the scorer's `match` has no test of its own.

**Verification performed:**
- `swift test --explicit-target-dependency-import-check error --filter SummarizeEvalHarness` -- 26 tests pass, 12 summary lines in the specified format.
- `scripts/check.sh lint` and `scripts/check.sh swift` (379 tests) -- pass, before and after the patch round. The 12 summary lines also appear in the full `swift test` output that CI runs.
- Mutation checks, each reverted afterwards with `Sources/` unchanged: a substring validator that accepts any quote fails the substring arm on every fixture, naming the kept decoys; a Citations mapping that ends one utterance late fails the default-wiring arm on the fixtures with items (checked after the patch round).
- Matrix Test Audit: all nine matrix rows are covered by tests that ran and passed in the filtered run.
- `scripts/check.sh app` was not run: no `App/` or Tuist input changed.

**Residual risks:**
- `EvalDefaultWiring` and the test-side `frontmatterMeeting` copy mirror code outside `swift test`'s reach and can drift silently.
- The Citations stub never emits a miscited item, so only the substring arm meets adversarial input inside the harness.
- The repository has no required status checks, so a red harness run does not by itself block a merge.
- The branch is `claude/bmad-build-auto-3-9-ebbcd1`; project policy asks for a semantic `type/short-kebab-description` name, so rename it before any push.
