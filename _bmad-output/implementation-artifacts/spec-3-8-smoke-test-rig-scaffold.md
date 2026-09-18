---
title: 'Story 3.8 (rig scaffold only): Decision 3.6 smoke-test rig'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: '6d284d48e6c3432dbb36dcfed1cef46a64ebb3c9'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      Assemble >=5 real meeting transcripts (>=1 1:1, >=1 with >=4 attendees) as CanonicalTranscript JSON and run the smoke-test rig against them.
    evidence: |-
      Needs the maintainer's own recordings and live Anthropic spend. WhisperKitTranscriber (Epic 4) is not built, so transcripts must come from another source converted to CanonicalTranscript JSON (`text` + `utterances`, UTF-8 byte offsets).
    severity: high
  - summary: >-
      Score recall, precision (false-keeps) and quote quality per transcript by hand, apply the default-flip rule, and record the outcome and rationale in Tests/fixtures/smoke-test-results.md.
    evidence: |-
      Recall is "items present in the user's memory of the meeting" and quote quality is "did it read sensibly" -- both maintainer judgments the rig cannot compute.
    severity: high
  - summary: >-
      Wire SummarizerOrchestrator(primary:fallback:) in the composition roots (AuricleApp.swift, auricle-cli) from the locked-in default.
    evidence: |-
      Depends on the human run above. Story 3.7 must use an interim default (Citations primary, substring fallback, per Decision 3.6's stated MVP default) until the run happens.
    severity: high
---

<intent-contract>

## Intent

**Problem:** Story 3.8 needs a smoke test that runs the Citations and substring strategies over real transcripts and reports comparable metrics, so the maintainer can pick the MVP default with evidence. No rig exists, and neither strategy exposes its `quote_validation_drop_count` to callers (substring only logs it; Citations is all-or-nothing and never drops per item), so the drop-rate metric cannot be computed at all.

**Approach:** Maintainer decision for this run: scaffold the rig only. Build everything except supplying recordings, judging recall/quality, and making the default-flip call. Expose `quoteValidationDropCount` on `SummaryWithGrounding`; add a testable Summarize-module rig (labeled comparison arms run concurrently per transcript, a fixture loader, a report renderer with blank cells for the human-scored metrics); add a thin hidden CLI verb and a shell wrapper the maintainer runs by hand.

## Boundaries & Constraints

**Always:**
- The rig compares labeled *arms* (`label` + `any SummarizerStrategy`), not a hard-coded strategy pair, so a later prompt-A-vs-B comparison reuses it. The verb builds two arms today: `citations`, `substring`.
- The arms of one transcript run concurrently; arm order in results follows the order given. A throwing arm becomes a recorded failure and never aborts the run.
- Two reports per run. `results.md` is metrics only -- no item text, no source quotes -- and is safe to commit. `detail.md` adds kept item text and `> ` source quotes sliced from `transcript.text` by UTF-8 range, contains real meeting content, and is never committed.
- Both reports carry blank cells for recall, precision and quote quality, plus a blank default/rationale section that states the default-flip rule verbatim from epics.md Story 3.8.
- Fixtures and outputs default to gitignored paths. Report files are written with `AtomicWriter`.
- The verb refuses to start with zero transcripts (before any API call) and prints the planned live-call count to stderr first.
- Real logic lives in `Sources/`; the `App/` verb only parses arguments, wires arms, and calls it.

**Never:**
- Never run the verb or script against real transcripts or the live API while building or verifying; only `--help` and the empty-directory refusal.
- Don't wire the composition-root primary/fallback choice, decide the default, or create `Tests/fixtures/smoke-test-results.md`.
- Don't change strategy behavior: only surface the count they already compute.
- Don't put a transcript, item text, quote, or raw error message into any log field.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Both arms succeed | 2 stub arms return summaries | One row per transcript; each arm's method, kept counts, drop count, cost recorded in arm order | No error |
| One arm throws `SummarizerError` | Arm A throws `.citationsUnavailable`, arm B succeeds | Arm A recorded as failure naming the case; arm B unaffected; run completes | Captured, not rethrown |
| Arm throws other `Error` | Arm throws an arbitrary error | Failure recorded by type name only, never the message | Captured, not rethrown |
| Concurrency | Two arms that each wait for the other to start | Both start before either finishes; test fails within a timeout rather than hanging if run serially | No error |
| Metrics report | Any rows | No item text or quote appears; blank human-score cells and the flip rule are present | No error |
| Detail report | Rows with kept items | Each item followed by a `> ` quote sliced from `transcript.text` by its UTF-8 range | Out-of-range or non-boundary range renders a placeholder, never traps |
| Load fixtures | Directory of `.json` plus other files | `CanonicalTranscript`s in filename order; name = file stem; non-JSON ignored | No error |
| No fixtures | Directory with no `.json` | Throws `noTranscriptsFound` before any strategy call | Typed error |
| Malformed fixture | A `.json` that does not decode | Throws naming the file only, never its contents | Typed error |
| Drop count | Substring drops 1 of 3 items; Citations succeeds | Substring summary reports 1; Citations reports 0 | No error |
| Empty-directory CLI run | `auricle-cli __smoke-test-summarize --transcripts <empty> --output <dir>` | Non-zero exit with a message; no API call; nothing written | Refusal |

</intent-contract>

## Code Map

- `Sources/SummarizerInterface/SummaryWithGrounding.swift` -- add `quoteValidationDropCount` (key `quote_validation_drop_count`); only 5 construction sites exist.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift:96-105` -- already sums `actionItemDrops + decisionDrops` for its log line; pass it through.
- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift:125,156` -- Citations is all-or-nothing, so both success paths report 0.
- `Tests/SummarizerInterfaceTests/SummaryWithGroundingTests.swift`, `Tests/SummarizeTests/SummarizerOrchestratorTests.swift`, `Tests/ClaudeSummarizerTests/*` -- update constructions; assert the drop count.
- `Sources/Summarize/` -- new rig files beside `SummarizerOrchestrator.swift` (depends only on `SummarizerStrategy`, so no concrete-strategy lint hit and no new package edges). One primary type per file.
- `Sources/Summarize/SummarizerOrchestrator.swift` -- shape reference for DI and doc-comment style.
- `App/auricle-cli/AuricleCLI.swift:8-21` -- register the verb; `App/auricle-cli/Verbs/InternalStageWorker.swift:9-13` -- hidden-verb template (`shouldDisplay: false`).
- `.swiftlint.yml:251-278` -- `composition_root_strategy_bypass` exclusion list; the verb constructs `ClaudeCitationsSummarizer()`/`ClaudeSubstringSummarizer()` and needs an entry. Also check the `transcript_decode_bypass` rule (`:191-211`) for the loader.
- `Sources/Core/CanonicalTranscript.swift` -- fixture shape; `Sources/Core/AtomicWriter.swift` -- report writes.
- `Tests/` is the real directory (macOS is case-insensitive): use `Tests/scripts/` and `Tests/fixtures/`, not lowercase `tests/`.
- `_bmad-output/planning-artifacts/epics.md:1610-1650` -- Story 3.8 ACs; `architecture.md:1498` -- Decision 3.6 protocol.

## Tasks & Acceptance

**Execution:**
- `Sources/SummarizerInterface/SummaryWithGrounding.swift`, both strategies, and their tests -- expose and assert `quoteValidationDropCount` -- the drop-rate metric needs it and Story 3.7's telemetry AC needs it too.
- `Sources/Summarize/` rig files -- arm type, concurrent runner, fixture loader, two-mode report renderer -- per the matrix.
- `Tests/SummarizeTests/` rig tests -- one test per matrix row, using stub strategies and a temp directory; never the network.
- `App/auricle-cli/Verbs/` verb, `AuricleCLI.swift`, `.swiftlint.yml` -- thin wrapper and its lint exclusion.
- `Tests/scripts/run-smoke-test.sh` -- builds `auricle-cli` and runs the verb with `$AURICLE_SMOKE_TEST_TRANSCRIPTS` (default `Tests/fixtures/smoke-test-transcripts`) and output to `Tests/fixtures/smoke-test-output`; executable; `set -euo pipefail`.
- `.gitignore` -- ignore `Tests/fixtures/smoke-test-transcripts/` and `Tests/fixtures/smoke-test-output/`.

**Acceptance Criteria:**
- Given stub arms, when the runner processes a transcript, then both arms are invoked concurrently and their results are recorded in arm order, including any failure.
- Given rows, when both reports render, then `results.md` contains no item text or quote, `detail.md` contains sliced `> ` quotes, and both contain the blank human-score cells and the default-flip rule.
- Given an empty transcripts directory, when the verb runs, then it exits non-zero, makes no API call, and writes nothing.
- Given the substring strategy dropping an item, when it returns, then `quoteValidationDropCount` reports the drops; Citations reports 0.
- Given `AURICLE_SMOKE_TEST_TRANSCRIPTS` pointing at an empty directory, when `Tests/scripts/run-smoke-test.sh` runs, then it builds `auricle-cli`, surfaces the verb's refusal, and exits non-zero without any API call. The live path (real transcripts to `results.md`/`detail.md`) is the deferred maintainer run, not verified here.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 37 findings — high 0, medium 2, low 23, false 10, maybe-false 2
- findings:
  - `[false]` `[reject]` (Blind Hunter) Dropped items appear nowhere, so the flip rule's "any false-drop" cannot be judged — a false-drop is a real commitment missing from the kept list, which the maintainer sees as a recall miss against memory; the AC's recall metric is defined on kept items; showing dropped text needs new strategy surface the Never list forbids.
  - `[medium]` `[patch]` (Blind Hunter) A re-run overwrites hand-filled results.md/detail.md — real (fixed file names, AtomicWriter replaces); patched: the script now writes each run to a UTC-timestamped directory under `Tests/fixtures/smoke-test-output/`.
  - `[low]` `[reject]` (Blind Hunter) Reports are written only after the last transcript, so an interrupted run loses paid rows — real but bounded to a few dollars of re-run, needs a changed `progress` signature or signal handling; rare for a hand-run tool.
  - `[low]` `[patch]` (Blind Hunter) results.md is called safe to commit but prints fixture file stems — real overstatement; patched: renderer note, verb stdout line and script header now say fixture names appear as given and must be named neutrally.
  - `[low]` `[patch]` (Blind Hunter) Verb exits 0 when every arm failed, no key preflight — patched: exit 1 after the reports are written when every arm run failed; the Keychain preflight half rejected (extra behavior, and no money is spent when the key is missing).
  - `[low]` `[reject]` (Blind Hunter) Non-`SummarizerError` failures collapse to a type name — that is exactly the contracted behavior (I/O matrix: type name only, never the message); allow-listing more types changes the contract.
  - `[false]` `[reject]` (Blind Hunter) Infra failures are not separated from grounding failures — the recorded reason names the exact case (`SummarizerError.rateLimited` vs `.citationsUnavailable`), so the reader can tell them apart.
  - `[low]` `[reject]` (Blind Hunter) Failed arms show `-` for cost, so spend is under-reported — the strategy throws without cost and the fix needs a strategy interface change the Never list forbids; cost is a secondary metric.
  - `[false]` `[reject]` (Blind Hunter) `Glossary()` is empty so prompts differ from production — no glossary builder exists yet (Story 3.12 is unbuilt), so an empty glossary is the current production prompt.
  - `[maybe-false]` `[reject]` (Blind Hunter) `xcodebuild | awk ... exit` under pipefail can SIGPIPE and abort silently; also no shellcheck step — not reproduced in 6 of 6 runs (single BUILT_PRODUCTS_DIR line); if true it is low (no spend, re-run); settling it needs a larger workspace's output. Missing shellcheck in CI predates this story.
  - `[low]` `[reject]` (Blind Hunter) Verb decision logic sits in `App/` where `swift test` cannot reach — the logic is a failed-arm count and exit codes on thin glue; the substantive logic already lives in Sources and is tested; moving it is more than a direct correction.
  - `[false]` `[reject]` (Blind Hunter) Required `quote_validation_drop_count` key breaks old summaries and Citations "0" misleads — `SummaryWithGrounding` is never persisted or decoded outside its own round-trip test (verified by grep), and Citations does drop nothing.
  - `[low]` `[reject]` (Blind Hunter) `sourceQuote` splits only on `\n`, so CRLF leaves a `\r` in a blockquote line — cosmetic, and canonical transcripts are LF; fix adds a branch.
  - `[low]` `[reject]` (Blind Hunter) `Array(repeating: "-", count: 8)` hard-codes the column count — developer-only; fix adds structure for a table that changes rarely.
  - `[false]` `[reject]` (Blind Hunter) `Default: ` / `Rationale: ` sentinels depend on trailing whitespace — tests assert only the renderer's own output; nothing re-reads the maintainer's edited copy.
  - `[low]` `[patch]` (Edge Case Hunter) Output directory is created only after all paid calls, so an unwritable `--output` discards paid results — patched: the verb creates the directory right after the fixtures load and before any call, exit 1 on failure.
  - `[low]` `[reject]` (Edge Case Hunter) An interrupted process loses completed rows — same root and reasoning as the Blind Hunter row above.
  - `[medium]` `[patch]` (Edge Case Hunter) A re-run silently overwrites earlier reports — same root as the Blind Hunter row above; patched by the timestamped run directory.
  - `[low]` `[patch]` (Edge Case Hunter) Every arm failing identically grinds through all transcripts and exits 0 — patched via the all-arms-failed exit 1; the stop-the-loop guard rejected (failed calls cost nothing and the loop is quick).
  - `[low]` `[reject]` (Edge Case Hunter) A failed arm after a billed response shows no cost — same as the Blind Hunter spend row above.
  - `[maybe-false]` `[reject]` (Edge Case Hunter) The awk `exit` can SIGPIPE xcodebuild under pipefail — same as the Blind Hunter row above: not reproduced, low if true.
  - `[low]` `[patch]` (Edge Case Hunter) A quoted leading `~` in `AURICLE_SMOKE_TEST_TRANSCRIPTS` is mangled as a relative path — patched: the script expands a leading `~` / `~/` to `$HOME` first.
  - `[low]` `[patch]` (Edge Case Hunter) `plannedCallCount` claims one call per arm but `AnthropicHTTPClient` retries within its budget — verified in the client; patched: doc comment now says it counts logical calls before HTTP retries.
  - `[low]` `[patch]` (Edge Case Hunter) Fixture stems in results.md are unsanitised — same root as the stem row above; patched by the wording change.
  - `[low]` `[patch]` (Verification Gap) The sequential-across-transcripts guarantee is untested — a fan-out rewrite passes every test; patched: added `transcriptsRunOneAfterAnotherSoOnlyTheArmsOfOneTranscriptOverlap` (peak in-flight must equal 2), shown to fail against a fan-out runner.
  - `[low]` `[reject]` (Verification Gap) Verb wiring and the script are checked only by manual runs — `App/` has no test target by repo design (AGENTS.md pitfall); swapped labels would still show the true grounding method in the table; both CLI checks were run by hand in this pass.
  - `[low]` `[patch]` (Verification Gap) results.md prints fixture stems while called safe to commit — same root as the stem row above.
  - `[low]` `[reject]` (Intent Alignment) CLI-surface expectations (refusal, stderr count, gitignored defaults) have no automated test — same as the Verification Gap verb-wiring row; verified manually.
  - `[false]` `[reject]` (Intent Alignment) No test carries a real strategy's drop count through the runner into a report — the runner passes the field through untouched; each end is tested (strategy tests, report tests).
  - `[low]` `[patch]` (Intent Alignment) "Live-call count" is logical, not HTTP requests — same root as the `plannedCallCount` row above.
  - `[low]` `[reject]` (Intent Alignment) Reports are written only after every call — same as the interrupted-run row above.
  - `[low]` `[patch]` (Intent Alignment) Exit status ignores arm outcomes — same root as the all-arms-failed row; patched.
  - `[false]` `[reject]` (Intent Alignment) The report-write failure path prints `\(error)` to stderr — that is a filesystem error carrying paths, not transcript or provider content; the rule targets log fields.
  - `[low]` `[patch]` (Intent Alignment) results.md prints fixture stems unfiltered — same root as the stem row above; patched by the wording change.
  - `[false]` `[reject]` (Intent Alignment) The verb compiles only under Xcode, not `swift test` — `scripts/check.sh app` builds it and passed; no bad outcome.
  - `[false]` `[reject]` (Intent Alignment) The loader also ignores hidden files and `*.json` directories — strictly more conservative than the matrix row; no harm.
  - `[false]` `[reject]` (Intent Alignment) `.swiftlint.yml` edited beyond the intent's list — the spec's Code Map names this exclusion as required for the verb.

## Design Notes

Citations never drops items: any grounding failure throws and `SummarizerOrchestrator` falls back. So its drop count is always 0 by construction, and the meaningful Citations signal in the smoke test is *thrown failures*, which the arm result records. Substring drops per item. That asymmetry is exactly what Decision 3.6's flip rule weighs.

`SummaryWithGrounding` is never persisted or decoded outside its own round-trip test (Story 3.7 writes `SummaryArtifact`, a separate type), so adding a required field needs no `schema_version` bump or migration path.

The rig deliberately does not compute a recommended default: recall and false-drop are human judgments, so a computed verdict would be false precision. It prints the rule and leaves the cells blank.

`results.md` is separate from `detail.md` because the required committed results doc must not leak real meeting content into a possibly public repository.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean.
- `swift test --filter SmokeTest` and `swift test --filter ClaudeSummarizerTests` -- expected: pass.
- `scripts/check.sh lint`, `scripts/check.sh swift`, `scripts/check.sh app` -- expected: pass (`app` builds the CLI target).
- Run the built `auricle-cli __smoke-test-summarize --transcripts <empty temp dir> --output <temp dir>` -- expected: non-zero exit, refusal message, no output files, no network activity.
- Run the built `auricle-cli __smoke-test-summarize --help` -- expected: usage prints.

## Auto Run Result

**Summary of implemented change:** Story 3.8's rig scaffold, narrowed with the maintainer to everything except the human-run half. `SummaryWithGrounding` now exposes `quoteValidationDropCount` (substring reports its real drops, Citations always 0 since it fails whole-call instead of dropping). `Sources/Summarize/` gained a strategy-agnostic rig: labeled arms run concurrently per transcript with failures recorded by case or type name only, a fixture loader, and a two-mode report renderer (`results.md` metrics only, `detail.md` with kept items and UTF-8-sliced `> ` quotes) with blank human-score cells and the flip rule verbatim. A hidden `auricle-cli __smoke-test-summarize` verb and `Tests/scripts/run-smoke-test.sh` wrap it; each script run writes to its own timestamped directory under a gitignored path.

**Files changed:**
- `Sources/SummarizerInterface/SummaryWithGrounding.swift`, `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift`, `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift` -- add and populate `quoteValidationDropCount`.
- `Sources/Summarize/SmokeTest*.swift` (8 files) -- arm, arm result, fixture, fixture loader, row, runner, report renderer, report writer.
- `App/auricle-cli/Verbs/SmokeTestSummarizeVerb.swift`, `App/auricle-cli/AuricleCLI.swift`, `.swiftlint.yml` -- hidden verb, registration, concrete-strategy lint exclusion.
- `Tests/scripts/run-smoke-test.sh`, `.gitignore` -- hand-run wrapper and ignored fixture/output paths.
- `Tests/SummarizeTests/SmokeTest*Tests.swift` (3 files, 20 tests), updates to `Tests/ClaudeSummarizerTests/*`, `Tests/SummarizeTests/SummarizerOrchestratorTests.swift`, `Tests/SummarizerInterfaceTests/SummaryWithGroundingTests.swift` -- one test per matrix row plus drop-count assertions.

**Review findings breakdown:** 37 findings across 4 layers -- 0 high, 2 medium, 23 low, 10 false, 2 maybe-false. No `intent_gap` or `bad_spec` routes. Full per-finding detail is in `## Review Triage Log`.
- **Patched (7 entries: 1 medium, 6 low):** timestamped per-run output directory (a re-run no longer overwrites hand-scored cells; two layers found it); honest "fixture names appear as given" wording in the renderer note, verb output and script header (four layers); exit 1 when every arm failed; output directory created before any paid call; leading `~` expanded in the transcripts env var; `plannedCallCount` doc corrected (the HTTP client retries); added a peak-in-flight test proving transcripts run one after another.
- **Deferred:** none new this pass. The three human-run items were recorded up front in `deferred` and are appended to `deferred-work.md`.
- **Rejected (28 findings):** every reason is in the triage log. The main groups: interrupted runs lose unwritten rows (low, needs a signature change); failure reasons stay type-name-only (contracted behavior); failed-arm cost stays blank (needs a strategy interface change the spec forbids); dropped-item text stays out of reports (same); `App/` glue stays manually verified (AGENTS.md pitfall); the SIGPIPE-under-pipefail claim did not reproduce in 6 of 6 runs and would be low.
- **Follow-up review recommendation:** `false`. Only one medium entry was patched and no high, so neither trigger applies.

**Verification performed:**
- `scripts/check.sh lint`, `scripts/check.sh swift` (304 tests, release build), `scripts/check.sh app` (tuist generate, both schemes) -- all passed, before and after the patch round.
- `swift test --filter SmokeTest` -- 20/20; the drop-count test in `ClaudeSubstringSummarizerTests` passes.
- Built `auricle-cli __smoke-test-summarize --help` prints usage and the verb is absent from top-level help; an empty transcripts directory exits 1 with a message and creates nothing.
- `AURICLE_SMOKE_TEST_TRANSCRIPTS=<empty dir> Tests/scripts/run-smoke-test.sh` builds the CLI, prints the refusal and exits 1; `Tests/fixtures` is never created.
- The live path (real transcripts, real API) was never run, as the spec requires.
- Matrix Test Audit: all 11 matrix rows are covered by a passing test; the last row (empty-directory CLI run) by the manual runs above, since `App/` has no test target.

**Residual risks:**
- Story 3.8 is not complete: the three `deferred` items (assemble and run real transcripts, hand-score and lock in the default, wire the composition roots) remain. Story 3.7 must use an interim default (Citations primary, substring fallback) until then.
- A run interrupted mid-way loses unwritten rows; reports are written after the last transcript.
- The verb uses an empty glossary and the default `SummarizerConfig()`; both are printed or fixed, not flag-tunable.
- Fixture file names appear in `results.md`; the maintainer must name fixtures neutrally before committing it.

**Finalization outcome:** pending commit by this orchestrating run.

**Renamed after finalization:** "smoke test" read as throwaway proof-of-concept code, but this is permanent, hand-run tooling, so the code now says what it does. `SmokeTest*` types and files became `StrategyComparison*`; the hidden verb `__smoke-test-summarize` became `__compare-strategies`; `Tests/scripts/run-smoke-test.sh` became `Tests/scripts/run-strategy-comparison.sh`; `AURICLE_SMOKE_TEST_TRANSCRIPTS` became `AURICLE_COMPARISON_TRANSCRIPTS`; the ignored directories became `Tests/fixtures/strategy-comparison-transcripts/` and `Tests/fixtures/strategy-comparison-output/`. The results document keeps its name, `Tests/fixtures/smoke-test-results.md`, because Story 3.8 fixes that path. The sections above, the Story 3.7 spec, and the first entry in `deferred-work.md` still use the old names and are left as written.
