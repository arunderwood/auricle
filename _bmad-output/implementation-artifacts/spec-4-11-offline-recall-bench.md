---
title: 'Story 4.11: Offline Recall Bench — Frozen Transcripts, Real Claude Call, Automatic Score'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_revision: '8e4d8e31114530e2cd9f63870f308f698982f419'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
warnings: ['oversized']
deferred:
  - summary: >-
      An item rendered with an empty quote scores as grounded, because score.py tests
      `"" in hypothesis`, which is always true.
    evidence: |-
      `note_quotes` yields "" for a bullet whose only quote line is a bare `  >`, and
      `FrontmatterRenderer.renderBlockquote("")` emits exactly that. `kept_items` and
      `false_keeps` both count the bullet; `ungrounded_quotes` never does. This is the
      one failure mode ungrounded_quotes exists to catch. Pre-existing in the block
      Story 4.11 moved verbatim, so `score.py meeting` has always behaved this way.
    location: >-
      Tests/regression/ami/score.py:100
    severity: medium
  - summary: >-
      The bench's "did this run measure anything" predicate lives only in App/, where
      no test target compiles it.
    evidence: |-
      `RecallBenchVerb.run()` decides the exit code with `result.rows.allSatisfy { $0.failureReason != nil }`.
      Changing it to `contains(where:)` inverts the hand-run script's success signal and
      every test in Tests/RecallBenchTests still passes. StrategyComparisonVerb carries the
      identical untested rule, so the real fix lifts the predicate into Sources/RecallBench
      for both verbs, which is wider than this story.
    location: >-
      App/auricle-cli/Verbs/RecallBenchVerb.swift:79
    severity: medium
  - summary: >-
      EvalScorer in SummarizeTests scores recall and false keeps under a different rule
      from score.py, so Story 4.12's rule change will leave it behind.
    evidence: |-
      `Tests/SummarizeTests/EvalScoring.swift` computes recall and falseKeeps over rendered
      notes against the same `expected.json` files, using exact item-text equality plus
      pointer containment, where score.py uses word overlap of at least 0.5. Story 4.11's
      one-place constraint is about the bench and the regression suite; unifying the third
      consumer is a wider change than this story, and the intent names SummarizeEvalHarness
      only for stubbing its responses.
    location: >-
      Tests/SummarizeTests/EvalScoring.swift
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Epic 4 Part B measured 42.1% item recall against an 80% floor, so the gap closes by iterating the summarization prompt — and no harness in the repo can tell whether a prompt change helped. `SummarizeEvalHarness` stubs the Anthropic response so the request is never read, `StrategyComparisonRunner` makes real calls but leaves recall to hand-scoring, and `Tests/regression/ami/run.sh` scores automatically but transcribes audio through WhisperKit first.

**Approach:** Join the three existing pieces into one loop rather than adding a fourth harness: frozen reference transcripts named by `Tests/regression/ami/manifest.json`, `StrategyComparisonRunner` for the real per-arm Claude call, the shipped artifact mapper and frontmatter renderer for the note, and `Tests/regression/ami/score.py` for the score. `score.py` grows a `note` subcommand that scores a note file with no state database, extracted from the block `meeting` already runs, so one scorer serves both. A new `RecallBench` library module owns fixture loading, arm wiring, note rendering and score translation; a thin hidden CLI verb wires the paid strategies.

## Boundaries & Constraints

**Always:**
- The recall/false-keep matching rule lives only in `score.py`. Swift invokes it as a subprocess and decodes its JSON. Story 4.12 rewrites that rule in one place.
- `score.py meeting` and `score.py note` share one extracted note-scoring function, so the bench and the regression suite cannot drift.
- Bench logic lands in `Sources/RecallBench/`; `App/auricle-cli/` holds only argument parsing and strategy construction (AGENTS.md: `App/`-only logic has no `swift test` coverage).
- The note is built by `SummaryArtifactMapper` and `FrontmatterRenderer` — the shipped path — never by a bench-local renderer.
- All bench file writes go through `Core.AtomicWriter` and land under a caller-supplied working directory.
- The subprocess runner is injectable, so `swift test` covers the score translation without Python and without a paid call.
- `Summarize` must not gain a `Persist` dependency: `SummaryArtifact` lives in `Core` precisely because neither stage may import the other.

**Never:**
- No WhisperKit import, no audio read, no `StateStore` open, no write outside the working directory.
- No paid Anthropic call from any target `swift test` runs.
- Do not reimplement `overlap()`, `note_quotes()` or the 0.5 threshold in Swift.
- Do not change `score.py report`'s table, `thresholds.json`, or `Tests/scripts/run-epic4-exit-criteria.sh` — those are Story 4.12.
- Do not add the item-text second recall test — also Story 4.12. `false_keeps` here is counted under the quote-overlap rule that exists today.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Manifest load | Repo root with `Tests/regression/ami/manifest.json` | Five fixtures in manifest order: four from `Tests/SummarizeTests/Fixtures/eval/`, one from `Tests/regression/ami/reference/`, each with its `CanonicalTranscript` decoded | No error expected |
| Missing manifest | Repo root without that file | Throws `manifestUnreadable` | Verb prints the message to stderr, exits 1 |
| Missing fixture dir | Manifest names an absent `reference` path | Throws `fixtureMissing(id:)` naming the id | Same |
| Undecodable transcript | `transcript.json` is not a `CanonicalTranscript` | Throws `transcriptUndecodable(id:)` | Same |
| Score translation | `score.py note` prints `{"kept_items":4,"ungrounded_quotes":0,"expected_items":3,"recalled_items":2,"false_keeps":1}` | Decodes to `RecallBenchScore(keptItems: 4, ungroundedQuotes: 0, expectedItems: 3, recalledItems: 2, falseKeeps: 1)` | No error expected |
| Scorer non-zero exit | Runner returns a non-zero status | Throws `scorerFailed(status:stderr:)` | Row records the failure; the run continues |
| Scorer prints non-JSON | Runner returns unparseable stdout | Throws `scoreUndecodable` | Same |
| Arm call fails | `StrategyComparisonArmResult.outcome == .failure` | Row carries `failureReason`, no score, zero cost; other arms and meetings still run | Report prints the reason; verb exits 1 only if every row failed |
| Report totals | Rows across arms and meetings | Per-arm-per-meeting lines plus one set-total line per arm carrying recall, false keeps, cost and elapsed time | No error expected |

</intent-contract>

## Code Map

Scoring side (Python, one scorer for both consumers):
- `Tests/regression/ami/score.py:129-138` — the note-scoring block inside `meeting()`: `note_quotes`, `kept_items`, `ungrounded_quotes`, `expected_items`, `recalled_items`. Extract verbatim into `score_note(note, hypothesis, expected)`; `meeting()` then does `result.update(score_note(...))`.
- `Tests/regression/ami/score.py:42-54` (`note_quotes`) and `:57-75` (`overlap`, `RECALL_OVERLAP = 0.5`, `MIN_QUOTE_WORDS = 4`) — unchanged. `false_keeps` = kept bullets whose quote clears the threshold against no expected item under the same heading.
- `Tests/regression/ami/score.py:174-176` — hand-rolled dispatch `{"meeting": meeting, "report": report}[command](*args)`; no argparse. Add `"note": note`. All arguments positional and required.
- `Tests/regression/ami/score.py:2-9` — module docstring is the only usage text; add the `note` line.
- `Tests/regression/ami/manifest.json` — `meetings[].id` and `meetings[].reference` (repo-relative fixture dir) are the only fields the bench reads.
- Fixture shape: `transcript.json` is a `CanonicalTranscript` (`text`, `utterances[].speaker_label/start/end`); `expected.json` carries `action_items`/`decisions` of `{text, quote, transcript_start, transcript_end}`. snake_case both.

Swift seams to open:
- `Sources/Summarize/SummaryArtifactMapper.swift:19` (`transcriptSegments(of:transcriptBytes:speakers:utteranceSpeakers:)`), `:75` (`needsAttribution`), `:87` (`artifact(title:match:grounded:transcriptSegments:needsAttribution:transcriptBytes:)`) — `enum SummaryArtifactMapper` is internal. Keep it internal; add a narrow public facade beside it.
- `Sources/Persist/PersistStage.swift:279-294` — `private static func frontmatterMeeting(_ resolved: ResolvedMeeting, supersedes:)`. The mapping is artifact + meetingID + date + supersedes → `MeetingForFrontmatter`. Extract into a public seam and have this call it; no behavior change.
- `Sources/Persist/FrontmatterRenderer.swift:8` — `public static func render(meeting: MeetingForFrontmatter) -> String`. Already public. Emits `## Action Items` / `## Decisions`, bullets `- text` then `  > quote` (`:100-119`), which is exactly what `score.py`'s parser reads.
- `Sources/Persist/MeetingForFrontmatter.swift:6,28` — public struct and init.

Swift pieces to reuse unchanged:
- `Sources/Summarize/StrategyComparisonRunner.swift:7,10,35` — `public struct ... Sendable`, `init(arms:)`, `run(fixtures:glossary:config:progress:) async -> [StrategyComparisonRow]`. Serial over fixtures, concurrent over arms.
- `Sources/Summarize/StrategyComparisonFixture.swift:5` — `name` + `transcript: CanonicalTranscript`.
- `Sources/Summarize/StrategyComparisonArmSpec.swift:12,61,82` — `parse`/`parseAll`, grammar `citations` | `substring` | `substring:<absolute dir>`, `label`, `defaults`.
- `Sources/Summarize/StrategyComparisonArm.swift:8` — `label` + `strategy: any SummarizerStrategy`.
- `Sources/Summarize/StrategyComparisonArmResult.swift:7` — `label`, `outcome` (`.summary(SummaryWithGrounding)` | `.failure(reason:)`), `failureReason`.
- `Sources/SummarizerInterface/SummaryWithGrounding.swift:5,46` — `cost: SummarizerCost` with `costUSD`, `inputTokens`, `outputTokens`, `thinkingTokens`. **No latency field anywhere** — the bench measures wall clock itself with `ContinuousClock`.
- `Sources/Core/AtomicWriter.swift:35` — `write(_:to:permissions:)`.
- `Sources/Core/MeetingID.swift:17` — `generate()` for the synthetic note id.
- `Sources/Core/Glossary.swift` — `Glossary()` all-empty init. `Sources/SummarizerInterface/SummarizerConfig.swift:19` — `SummarizerConfig()` defaults.

CLI pattern to copy:
- `App/auricle-cli/Verbs/StrategyComparisonVerb.swift:16-33` (hidden `AsyncParsableCommand`, `commandName`, `shouldDisplay: false`, `@Option(name: .customLong("arm")) var arms: [String] = []`), `:44-47` (`writeStderr` + `ExitCode(1)`), `:105-112` (`arm(for spec:)` — the only sanctioned place to name `ClaudeSubstringSummarizer` / `ClaudeCitationsSummarizer`).
- `App/auricle-cli/AuricleCLI.swift:8-24` — the single subcommand list.
- `Tests/scripts/run-strategy-comparison.sh` — the shell wrapper pattern for a paid verb (tuist generate, xcodebuild, `AURICLE_CLI` override, timestamped output dir).

Registration and lint (all mandatory, or the build/lint fails):
- `Package.swift:92-100` (`Summarize` target), `:101` (`Persist`), `:205-214` (`SummarizeTests`) — add a `RecallBench` target + `.library` product and a `RecallBenchTests` target. `swift build --explicit-target-dependency-import-check error` enforces every import.
- `App/Project.swift:6-33` — `auricleKitProducts` must list the new product, or the CLI target cannot import it.
- `.swiftlint.yml:194-222` — `print_bypass` (`severity: error`); add the new verb file, as `StrategyComparisonVerb.swift` is at `:218`.
- `.swiftlint.yml:284-350` — concrete-strategy rule; add the new verb file beside `:303`.
- Lint limits that bite: file 600 warn (`--strict` means warnings fail), function body 50 warn, type body 250 warn, line 180 warn, `trailing_comma: mandatory_comma`.
- Test convention: swift-testing only (`import Testing`, `@Test`, `#expect`, `try #require`); camelCase test names; env-gated expensive tests use `.enabled(if:, "why")` — see `Tests/TranscribeTests/PerformanceTests.swift:27`.
- Subprocess idiom: `Sources/Orchestrator/SubprocessDispatcher.swift:53-105`. It injects the executable URL and never captures stdout, so the `Pipe` capture here is new — read the pipe to end before `waitUntilExit()`.

## Tasks & Acceptance

**Execution:**
- `Tests/regression/ami/score.py` -- extract lines 129-138 into `score_note(note, hypothesis, expected)` returning `kept_items`, `ungrounded_quotes`, `expected_items`, `recalled_items`, `false_keeps`; have `meeting()` call it; add a `note <note-path> <expected-json> <transcript-json>` subcommand that prints that dict as JSON; register it in the dispatch dict and the docstring -- one scorer, so Story 4.12's rule change lands once.
- `Sources/Summarize/OfflineSummaryArtifact.swift` -- new `public enum` with `artifact(title:transcript:grounded:) throws -> SummaryArtifact`, delegating to `SummaryArtifactMapper.transcriptSegments` (speakers `nil`) and `.artifact` -- a named public seam for the bench that keeps the mapper itself internal.
- `Sources/Persist/SummaryArtifactFrontmatter.swift` -- new `public enum` with `meeting(_:meetingID:date:supersedes:) -> MeetingForFrontmatter`, moving the body of `PersistStage.frontmatterMeeting`; rewrite that private method to call it -- one artifact→frontmatter mapping.
- `Sources/RecallBench/RecallBenchManifest.swift` -- `Decodable` view of `manifest.json` reading only `meetings[].id` and `meetings[].reference`, explicit snake_case `CodingKeys`.
- `Sources/RecallBench/RecallBenchFixtureLoader.swift` -- `load(repoRoot:) throws -> [RecallBenchFixture]` (`id`, `directory`, `transcript`), manifest order preserved; errors `manifestUnreadable`, `manifestUndecodable`, `fixtureMissing(id:)`, `transcriptUndecodable(id:)`.
- `Sources/RecallBench/RecallBenchScorer.swift` -- `RecallBenchScore` (`Decodable`, snake_case `CodingKeys`) plus a scorer holding `scriptURL` and an injectable `@Sendable (URL, [String]) throws -> Data` runner; default runner spawns `/usr/bin/env python3` with a `Pipe`, reads to end, then checks the exit status; errors `scorerFailed(status:stderr:)`, `scoreUndecodable`.
- `Sources/RecallBench/RecallBenchRunner.swift` -- async `run(...)`: `StrategyComparisonRunner` for the calls, `OfflineSummaryArtifact` + `SummaryArtifactFrontmatter` + `FrontmatterRenderer` for the note, `AtomicWriter` to `<workDir>/<arm-slug>/<id>.md`, scorer per row; returns rows plus measured elapsed `Duration`.
- `Sources/RecallBench/RecallBenchReportRenderer.swift` -- fixed-width table: header, one line per arm per meeting (kept, false keeps, `recalled/expected`, cost), then one set-total line per arm carrying `item recall R/E = P%`, false keeps, total cost and elapsed seconds -- same shape as `score.py report`.
- `App/auricle-cli/Verbs/RecallBenchVerb.swift` -- new hidden `__recall-bench` verb: `--repo-root`, repeatable `--arm`, `--output`; parses specs with `StrategyComparisonArmSpec.parseAll`, builds strategies in an `arm(for:)` switch, runs the bench, prints the report, exits 1 when every row failed.
- `App/auricle-cli/AuricleCLI.swift` -- register the verb in `subcommands`.
- `Package.swift` -- add the `RecallBench` target (Core, Persist, Summarize, SummarizerInterface) and `.library` product, plus a `RecallBenchTests` target (RecallBench, TestSupport, Core, Persist, Summarize, SummarizerInterface).
- `App/Project.swift` -- add the `RecallBench` product to `auricleKitProducts`.
- `.swiftlint.yml` -- add `App/auricle-cli/Verbs/RecallBenchVerb.swift` to the `print_bypass` and concrete-strategy exclusion lists.
- `Tests/RecallBenchTests/` -- unit-test every I/O Matrix row: loader happy path and each error against synthetic manifests in a temp dir; score decoding and each scorer error with an injected runner; report rendering including a failed arm; a whole-runner test with stub `SummarizerStrategy` arms and an injected scorer, asserting the rendered note carries `## Action Items` bullets with `  > ` quotes and that nothing is written outside the working directory. Add one `.enabled(if:)` test that locates the real `score.py` from `#filePath` and scores a synthetic note, so the Python/Swift contract is covered when `python3` exists.
- `Tests/scripts/run-recall-bench.sh` -- thin wrapper mirroring `run-strategy-comparison.sh`: build or accept `AURICLE_CLI`, run the verb over the manifest, write the report under a timestamped dir.
- `Tests/regression/ami/README.md` -- document `score.py note` and the bench as the second consumer of the scorer.

**Acceptance Criteria:**
- Given the bench module, when `swift test` runs, then the fixture loader, arm wiring, score translation and report rendering are all covered and no test makes a network call or opens a state database.
- Given `score.py meeting` before and after the extraction, when both run against the same inputs, then every key it printed before is still printed with the same value, plus `false_keeps`.
- Given `score.py note <note> <expected.json> <transcript.json>`, when it runs, then it prints one JSON object and reads no database, no cache root and no manifest.
- Given `grep -rn "WhisperKit\|StateStore" Sources/RecallBench/`, when it runs, then it matches nothing.
- Given a full five-meeting single-arm run, when it completes, then the report's footer states elapsed seconds under 120 and total cost under $0.30.
- Given `make check`, when it runs, then it passes with no swiftformat, swiftlint, build or test failure.

## Spec Change Log

## Review Triage Log

### 2026-09-20 — Review pass
- verdicts: 37 findings — high 1, medium 20, low 14, false 2, maybe-false 0
- findings:
  - `[medium]` `[patch]` `ungrounded_quotes` is decoded onto every row and never printed, while the README claims a non-zero count is a grounding defect — added an `ungnd` column and an `ungrounded N` figure on each arm's total line.
  - `[medium]` `[defer]` An item with an empty quote scores as grounded — pre-existing in the block this story moved verbatim; deferred with evidence.
  - `[medium]` `[patch]` Only `--output` was preflighted, so a missing `score.py`, absent `python3`, or a fixture without `expected.json` wasted the whole paid run — the loader now requires `expected.json` (`expectedItemsMissing(id:)`) and the verb probes `score.py` and `python3 --version` before the first call.
  - `[medium]` `[patch]` Every arm's total line printed the whole run's wall clock — elapsed moved to a single run-level footer line.
  - `[medium]` `[patch]` `writesNothingOutsideTheWorkingDirectory` enumerated only the temp root, so a real escape to `/tmp/escape` would have passed — the escape arm now targets a path under the root and the test asserts that path is absent.
  - `[low]` `[patch]` A run's numbers could not be traced to the prompt directory that produced them, since the arm label keeps only the last path component — `run-recall-bench.sh` now writes the resolved invocation and output path as the first lines of `report.txt`.
  - `[low]` `[reject]` `score.py report` does not print the new `false_keeps` — epics.md assigns wiring it into `report` and `thresholds.json` to Story 4.12, so the intent itself excludes it.
  - `[medium]` `[patch]` The regenerated `epic-4-context.md` deleted normative specifics stories 4.1-4.10 shipped against and 4.12-4.13 must be written against — restored the file to its committed content and appended only the three new stories and the recall-remediation constraints; the change is now 13 insertions, 0 deletions.
  - `[medium]` `[patch]` That rewrite also stated Story 4.12's item-text matching rule as current behavior — the restored file marks it as pending 4.12.
  - `[low]` `[reject]` `zip(fixtures, comparison)` pairs positionally — verified `StrategyComparisonRunner.run` returns exactly one row per fixture in manifest order, so no bad outcome occurs; the proposed fix adds a guard for state never shown reachable.
  - `[low]` `[patch]` `RecallBenchTests` declared a `TestSupport` dependency no test imports — removed.
  - `[low]` `[reject]` `loadsEveryManifestMeetingInOrder` hardcodes the five manifest ids — pinning the fixture set the story documents is legitimate, and a sixth meeting would fail loudly and obviously.
  - `[low]` `[reject]` Rendered notes carry a fresh `MeetingID` and today's date, so two runs differ — only two frontmatter lines vary and the scored body is deterministic; a fixed id needs a failable-ULID fallback branch.
  - `[low]` `[patch]` `python3Runner` inherited stdin and had no timeout — set `standardInput = FileHandle.nullDevice`; the timeout was rejected, since `score.py` never blocks and bounding the wait adds branching.
  - `[medium]` `[patch]` `score.py note` opened its two JSON files with a bare `open()`, whose encoding is locale-dependent, while AMI transcripts carry non-ASCII — all three opens now pass `encoding="utf-8"`.
  - `[medium]` `[patch]` A fixture directory without `expected.json` was not detected until after the full paid run — grouped with the preflight entry above.
  - `[medium]` `[patch]` An unreadable `score.py` or absent `python3` was not detected until after the full paid run — grouped with the preflight entry above.
  - `[medium]` `[patch]` A Python traceback in `failureReason` injected newlines into the fixed-width table — the failure line now collapses newlines and caps the reason at 120 characters, with a test feeding it a multi-line traceback.
  - `[low]` `[patch]` A row whose arm succeeded but whose scoring failed hid a real cost that the arm total still summed — the failure line now prints the cost.
  - `[low]` `[reject]` An empty manifest makes `allSatisfy` true and exits 1 with no diagnostic — the manifest is committed and non-empty; the fix adds a branch for unreachable state.
  - `[low]` `[reject]` `slug` is not injective, so two arms whose labels differ only in a space versus a hyphen share a directory — requires a prompt directory named with a space; `parseAll` already rejects duplicate labels, and the fix adds an index suffix.
  - `[low]` `[reject]` Duplicate manifest ids would overwrite a note — the manifest is committed with unique ids.
  - `[medium]` `[patch]` `ungrounded_quotes` never read (same defect as the first row) — grouped.
  - `[medium]` `[patch]` `SummarizeEvalHarnessTests` kept a hand-maintained twin of the artifact-to-frontmatter mapping, justified by a doc comment this change made false, already diverging on `schemaVersion` and `needsSummary` — the twin is deleted and the harness now calls `OfflineSummaryArtifact` and `SummaryArtifactFrontmatter`.
  - `[medium]` `[patch]` The only real-`score.py` test asserted `falseKeeps: 0`, where it is 0 under any rule, so deleting the heading filter broke nothing — added a cross-heading test asserting `falseKeeps == 2`.
  - `[medium]` `[defer]` The verb's exit-code predicate lives only in `App/`, which no test target compiles — deferred with evidence; the sibling verb carries the same untested rule.
  - `[medium]` `[patch]` The escape test proves less than its name claims (same defect as above) — grouped.
  - `[low]` `[reject]` `slug` not injective (same as above) — grouped with that rejection.
  - `[high]` `[patch]` Nothing tested the seam the story rests on: a note from the real `FrontmatterRenderer` scored by the real `score.py` against a real fixture's real `expected.json`. Every test held one side real and stubbed the other, so a renderer/parser mismatch was uncaught — added `RecallBenchEndToEndTests`, which loads ES2002b through the loader, grounds items at that fixture's own byte offsets including one spanning three utterances, and asserts `recalledItems == expectedItems` and `ungroundedQuotes == 0` through the real scorer.
  - `[low]` `[patch]` The script's default is two arms, so ten paid calls, while the budget is stated per single-arm five-call run — the header now says so.
  - `[medium]` `[patch]` Elapsed printed per arm (same defect as above) — grouped.
  - `[medium]` `[patch]` `ungrounded_quotes` not surfaced (same defect as above) — grouped.
  - `[medium]` `[defer]` `EvalScorer` scores under a rule different from `score.py`, so 4.12's change will leave it behind — deferred with evidence; the intent names that harness only for stubbing its responses.
  - `[low]` `[reject]` `run-recall-bench.sh` points `--output` at a gitignored directory in the repo tree rather than a temp directory — the acceptance clause sits among "does not touch the pipeline's real resources" and guards the vault and state store, both of which the bench avoids; Story 4.12 also requires bench notes to persist so an earlier run can be re-scored.
  - `[false]` `[reject]` The change adds a fourth entry point rather than joining the existing three — the intent itself requires a `Sources/` module with a thin CLI wrapper, so a new module, verb and script were mandated, not optional.
  - `[false]` `[reject]` `StrategyComparisonReportRenderer`'s hand-scored cells should have been filled in place instead — the intent assigns fixture loading, arm wiring and score translation to a surface `swift test` covers, which that renderer is not.

## Design Notes

Why `score.py` grows a subcommand rather than the bench calling `meeting`: `meeting` needs a state database, a cache root and a WhisperKit-produced transcript, all of which the story forbids. Extracting the note-scoring block is the smallest change that gives the bench the same scorer the gate uses.

Why the bench's "hypothesis" transcript is the reference transcript itself: with no WhisperKit there is no separate hypothesis, so `ungrounded_quotes` becomes a real check that a kept quote is a verbatim slice of the frozen transcript.

Report shape, for the renderer to match:

```
arm                     meeting     kept  false   recall       cost
substring:recall-v2     ES2002a        4      1      3/3   $ 0.0550
substring:recall-v2     ES2002b        5      2      4/8   $ 0.0977
substring:recall-v2  item recall 7/11 = 64%, false keeps 3, $ 0.1527, 41s
```

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build; the new target's imports all declared.
- `swift test --explicit-target-dependency-import-check error` -- expected: all tests pass, `RecallBenchTests` included.
- `python3 Tests/regression/ami/score.py report Tests/regression/ami/thresholds.json Tests/regression/ami/history.jsonl` -- expected: the same table and exit status as before the change.
- `make check` -- expected: the full CI chain green, including the `auricle-cli` embed assertion.

## Auto Run Result

Status: done

### Implemented change

An offline recall bench that runs the five frozen AMI reference transcripts through a real Claude call per arm, renders each result through the shipped note path, and scores item recall automatically by invoking `Tests/regression/ami/score.py`. It joins the three existing harnesses rather than adding a fourth scorer: the matching rule stays in `score.py` alone, so Story 4.12's change to it reaches the bench and the AMI regression suite together.

### Files changed

- `Tests/regression/ami/score.py` -- extracted the note-scoring block out of `meeting()` into `score_note()`, which now also returns `false_keeps`; added a `note` subcommand that scores one note with no database, cache root or manifest.
- `Sources/Summarize/OfflineSummaryArtifact.swift` -- public seam over the still-internal `SummaryArtifactMapper`, for a caller with a transcript and a summarizer result and no stage.
- `Sources/Persist/SummaryArtifactFrontmatter.swift` -- the one `SummaryArtifact` to `MeetingForFrontmatter` mapping, moved out of `PersistStage.frontmatterMeeting`, which now delegates to it.
- `Sources/RecallBench/` -- manifest view, fixture loader, `score.py` wrapper with an injectable runner, runner, and report renderer.
- `App/auricle-cli/Verbs/RecallBenchVerb.swift` -- hidden `__recall-bench` verb; argument parsing, arm construction and printing only.
- `Tests/RecallBenchTests/` -- 23 tests, including three that run the real `score.py`.
- `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift` -- adopts the two new seams and deletes its twin of the mapping.
- `Tests/scripts/run-recall-bench.sh`, `Tests/regression/ami/README.md`, `.gitignore`, `.swiftlint.yml`, `Package.swift`, `App/Project.swift`, `App/auricle-cli/AuricleCLI.swift` -- entry point, documentation and registration.
- `_bmad-output/implementation-artifacts/epic-4-context.md` -- stories 4.11-4.13 and the recall-remediation constraints appended; 13 insertions, 0 deletions.

### Review findings

37 findings across four layers. 15 entries patched (high 1, medium 9, low 5), 3 deferred, 11 rejected. Every rejection and its reason is recorded row by row in the triage log above.

### Follow-up review recommended: true

The named unverified risk: **the cost and time acceptance criterion has never been executed.** "Under two minutes and under $0.30 over a five-meeting single-arm run, measured from the telemetry the run reports" needs a paid Anthropic call, which `swift test` cannot make by design. Every part of the loop is now covered in isolation, and the renderer-to-scorer join is covered end to end with a stub summarizer, but no run has measured real latency or spend. One command settles it:

    Tests/scripts/run-recall-bench.sh --arm substring

Patched counts by verdict: high 1, medium 9, low 5.

### Verification performed

- `make check` -- the full CI chain green (lint, swift, release, app), including the assertion that the built `AuricleApp.app` embeds an executable `auricle-cli`.
- `swift test --filter RecallBench` -- 23 tests pass. The three real-`score.py` tests ran rather than skipping, so the Python-to-Swift field contract is verified, not assumed.
- `python3 Tests/regression/ami/score.py report ... history.jsonl` -- byte-identical table and exit 0 before and after the extraction.
- `grep -rn "WhisperKit\|StateStore" Sources/RecallBench/` -- no match.
- Matrix test audit: every I/O matrix row has a covering test that ran and passed.

### Residual risks

- The cost and time criterion above.
- The three deferred items in frontmatter `deferred`, one of which (`score.py`'s empty-quote handling) also affects the shipped AMI gate.
