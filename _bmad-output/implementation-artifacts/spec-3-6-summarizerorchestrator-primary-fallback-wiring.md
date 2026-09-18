---
title: 'SummarizerOrchestrator — Primary/Fallback Wiring'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: '63c8a5d1327bfa15e3121cfd20ffcb14508861d1'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `ClaudeCitationsSummarizer` (Story 3.5, MVP default) and `ClaudeSubstringSummarizer` (Story 3.4, fallback) exist but nothing mediates between them — each strategy must stay ignorant of the other (SOLID-I, AR-PAT-7), so the primary/fallback decision needs exactly one home.

**Approach:** Add `SummarizerOrchestrator`, a Swift `actor` in `Sources/Summarize/`, DI-constructed with two `SummarizerStrategy`-typed dependencies. It calls primary; on a fallback-eligible `SummarizerError`, it calls fallback once (no chaining); on any other error, it rethrows untouched. It returns an `Outcome` wrapping the winning `SummaryWithGrounding` plus fallback bookkeeping (`fallbackTriggered`, `primaryError`) for a future caller (Story 3.7, not yet built) to record into telemetry — the orchestrator itself never calls `TelemetryRecorder`.

## Boundaries & Constraints

**Always:**
- `SummarizerOrchestrator` is a Swift `actor` (AR-PAT-6), `init(primary: SummarizerStrategy, fallback: SummarizerStrategy)` — protocol-typed, DI'd from the composition root (AR-PAT-5), never instantiating a concrete strategy itself.
- `public func summarize(transcript: CanonicalTranscript, glossary: Glossary, config: SummarizerConfig) async throws -> Outcome`, where `Outcome` is `Sendable` with `summary: SummaryWithGrounding`, `fallbackTriggered: Bool`, `primaryError: SummarizerError?`.
- Call `primary.summarize(transcript:glossary:config:)` first. On success: `Outcome(summary: result, fallbackTriggered: false, primaryError: nil)` — `result.groundingMethod` is already `.citations`/`.substring` per the strategy, so no separate grounding-method bookkeeping is needed.
- On a thrown error that casts to `SummarizerError` with `isFallbackEligible == true` (already implemented: `.citationsUnavailable`, `.malformedResponse`, `.rateLimited`, `.featureToggleDisabled`): call `fallback.summarize(transcript:glossary:config:)` **once**, passing the same `config` unchanged (`config.remainingCostBudgetUSD` already exists on `SummarizerConfig` as the fallback's cost-ceiling hint per Decision 3.3 — the orchestrator has no primary-call cost data to recompute from on a failure, so it forwards the caller-supplied value as-is). On fallback success: `Outcome(summary: fallbackResult, fallbackTriggered: true, primaryError: theCapturedError)`. On fallback failure: rethrow the fallback's error (caller sees a thrown `SummarizerError`; no partial `Outcome`).
- On any other thrown error (not `SummarizerError`, or `isFallbackEligible == false`, i.e. `.networkTimeout`/`.authenticationFailed`/`.quotaExceeded`): rethrow immediately, do not call fallback.

**Never:**
- Don't call `TelemetryRecorder` or any persistence type from the orchestrator (see Design Notes).
- Don't retry primary itself, don't chain a second fallback attempt, don't add a `meetingID` parameter — none of the existing `SummarizerStrategy`/`SummarizerConfig` shapes carry one, and this story's scope is fallback decision logic only.
- Don't touch `Sources/ClaudeSummarizer/*` or `Package.swift` — no new dependency edges are needed (confirmed by building `SummarizeTests` with `--explicit-target-dependency-import-check error`: `Core` and `SummarizerInterface` are already reachable).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Primary succeeds | Stub primary returns a `SummaryWithGrounding` | `Outcome(fallbackTriggered: false, primaryError: nil)`; fallback never invoked | No error |
| Primary throws fallback-eligible, fallback succeeds | Primary throws `.citationsUnavailable` (or `.malformedResponse`/`.rateLimited`/`.featureToggleDisabled`); fallback returns success | `Outcome(fallbackTriggered: true, primaryError: .citationsUnavailable)`, `summary.groundingMethod == .substring` | No error |
| Primary throws fallback-eligible, fallback also fails | Both stubs throw | — | Rethrows fallback's `SummarizerError` |
| Primary throws non-fallback-eligible | Primary throws `.networkTimeout`/`.authenticationFailed`/`.quotaExceeded` | Fallback never invoked | Rethrows primary's error unchanged |

</intent-contract>

## Code Map

- `Sources/Summarize/SummarizerOrchestrator.swift` -- new -- the actor, `Outcome` type, primary/fallback wiring.
- `Sources/SummarizerInterface/SummarizerStrategy.swift` -- existing, read-only -- `protocol SummarizerStrategy: Sendable { func summarize(transcript:glossary:config:) async throws -> SummaryWithGrounding }`.
- `Sources/SummarizerInterface/SummarizerError.swift` -- existing, read-only -- all 4 fallback-eligible + 3 non-eligible cases and `isFallbackEligible` already implemented exactly per Decision 3.3; no changes needed.
- `Sources/SummarizerInterface/SummarizerConfig.swift:10` -- existing, read-only -- `remainingCostBudgetUSD: Double?`, already documented as "passed to the fallback strategy by the orchestrator."
- `Sources/SummarizerInterface/SummaryWithGrounding.swift`, `GroundingMethod.swift` -- existing, read-only -- `groundingMethod` is already part of the returned struct.
- `Sources/ClaudeSummarizer/ClaudeCitationsSummarizer.swift`, `ClaudeSubstringSummarizer.swift` -- existing, read-only -- both `struct: SummarizerStrategy` with identical `summarize(transcript:glossary:config:)` signatures; composition root (not yet built) wires them as `primary`/`fallback`.
- `Sources/Telemetry/TelemetryRecorder.swift`, `Sources/Telemetry/StageMetadata.swift:166,176` -- existing, read-only -- confirms telemetry writing is a full-struct UPSERT keyed by `meetingID` (which the orchestrator doesn't have) and that a `grounding_method`-shaped slot already exists in `StageMetadata.SummarizeMeta`, i.e. in the stage_events payload a future stage entry point writes, not in the orchestrator.
- `_bmad-output/planning-artifacts/epics.md:1537-1562` -- authoritative ACs for this story.
- `_bmad-output/planning-artifacts/architecture.md:1388-1425` (Decision 3.3) -- orchestrator-mediated fallback, cost-ceiling-across-primary+fallback; its illustrative `TelemetrySink` sketch predates and doesn't match the real `TelemetryRecorder` API (see Design Notes).

## Tasks & Acceptance

**Execution:**
- `Sources/Summarize/SummarizerOrchestrator.swift` -- new -- implement per Boundaries.
- `Tests/SummarizeTests/SummarizerOrchestratorTests.swift` -- new -- a file-local stub `SummarizerStrategy` (configurable to return a fixed `SummaryWithGrounding` or throw a given `SummarizerError`); one test per I/O-matrix row, plus a test proving fallback is never invoked on the primary-succeeds and non-fallback-eligible rows (e.g. a stub that fails the test if called).

**Acceptance Criteria:**
- Given stub strategies, when primary succeeds, then `summarize()` returns `fallbackTriggered == false` and the fallback stub is never invoked.
- Given stub strategies, when primary throws a fallback-eligible error and fallback succeeds, then `summarize()` returns `fallbackTriggered == true`, `primaryError` matching the thrown case, and `summary.groundingMethod == .substring`.
- Given stub strategies, when primary throws a fallback-eligible error and fallback also throws, then `summarize()` rethrows a `SummarizerError`.
- Given stub strategies, when primary throws a non-fallback-eligible error, then `summarize()` rethrows it unchanged and the fallback stub is never invoked.

## Spec Change Log

## Review Triage Log

### 2026-09-17 — Review pass
- verdicts: 16 findings — high 0, medium 3, low 6, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` (Intent Alignment) `config` (including `remainingCostBudgetUSD`) is forwarded to `fallback` unchanged but no test verifies this — patch: capture the received `config`/`transcript`/`glossary` in the stub and assert equality (all three types are already `Equatable`).
  - `[medium]` `[patch]` (Verification Gap) Same gap, independently demonstrated: mutating the fallback call to pass `SummarizerConfig()` instead of the forwarded `config` still leaves all 4 tests green — patch: same fix as above.
  - `[medium]` `[patch]` (Blind Hunter) Same gap a third time — `StubSummarizerStrategy` discards `transcript`/`glossary`/`config` via `_:` — patch: same fix as above.
  - `[low]` `[patch]` (Edge Case Hunter) No `Task.checkCancellation()` between primary's failure and the fallback call — a task cancelled in that narrow window still triggers a paid fallback API call — patch: add `try Task.checkCancellation()` immediately before the `fallback.summarize` call.
  - `[low]` `[patch]` (Blind Hunter) No test asserts `primary.callCount` (only `fallback.callCount` is checked, and only in 2 of 4 tests) — patch: add a `primary.callCount == 1` assertion to each of the 4 tests.
  - `[low]` `[patch]` (Blind Hunter) No test throws a non-`SummarizerError` (e.g. a plain `Error`) to exercise the documented "unmatched catch auto-rethrows" path — patch: add one test throwing a local `struct` conforming to `Error` from `primary` and asserting it rethrows unchanged with `fallback.callCount == 0`.
  - `[low]` `[reject]` (Blind Hunter) `deferred: []` stays empty even though Design Notes describes deferring telemetry/state-transition ACs to Story 3.7 — reject: the fix is to edit this build's spec's frontmatter, not the code; per triage rules, a finding whose only fix is a spec edit is rejected outright.
  - `[low]` `[reject]` (Blind Hunter) `## Verification` lists 4 ad hoc commands instead of `make check` — reject: fix edits this build's spec, not the code (the orchestrating run still executes `make check` independently before finalizing).
  - `[low]` `[reject]` (Blind Hunter) The Code Map's claim that `--explicit-target-dependency-import-check error` "confirms" `Core`/`SummarizerInterface` are reachable is imprecise (the flag doesn't error on transitively-reachable-but-undeclared imports for this target) — reject: fix edits this build's spec's prose, not the code; the underlying conclusion (no `Package.swift` change needed) is independently correct, verified by a clean build.
  - `[false]` `[reject]` (Intent Alignment) The orchestrator doesn't call `TelemetryRecorder` despite epics.md's "records telemetry" wording — reject: refuted by AR-DATA-4 (write authority = the stage-entry subprocess, not this actor), `TelemetryRecorder`'s `meetingID`-keyed API (unavailable here), `StageMetadata.SummarizeMeta` already reserving the `grounding_method` slot for that future writer, and the AC's own test list naming only "stub strategies" with no telemetry fixture — already reasoned through in this spec's Design Notes.
  - `[false]` `[reject]` (Intent Alignment) The orchestrator doesn't transition `meetings.state` to `summarization_failed` on double failure — reject: Story 3.7's own AC (epics.md) explicitly assigns that transition to the stage-entry subprocess ("the subprocess exits... `meetings.state` transitions to `summarization_failed`"), not to this orchestrator, which correctly just rethrows.
  - `[false]` `[reject]` (Intent Alignment) No composition-root call site wires `SummarizerOrchestrator` to the concrete Claude strategies yet — reject: `epic-3-context.md`'s own Cross-Story Dependencies section assigns that wiring to Story 3.7 ("Story 3.7 composes... Story 3.6 (orchestrator)... into the subprocess entry point"), not this story.
  - `[false]` `[reject]` (Intent Alignment) Meta-observation that the spec's own intent-contract narrows away from the more literal epics.md/architecture.md readings — reject: descriptive commentary, not a demonstrated bad outcome at any cited location.
  - `[false]` `[reject]` (Blind Hunter) architecture.md's Decision 3.3 sketch models `fallback` as optional (`SummarizerStrategy?`); the shipped orchestrator makes it required, undocumented — reject: refuted by epics.md's own AC instantiation example (`SummarizerOrchestrator(primary: ClaudeCitationsSummarizer, fallback: ClaudeSubstringSummarizer)`, always both provided), which is the authoritative AC; the architecture.md sketch is illustrative, same precedent already established for its `TelemetrySink` sketch.
  - `[false]` `[reject]` (Blind Hunter) epics.md's test-suite AC line about a "terminal `summarization_failed`" transition isn't reconciled in Design Notes — reject: same refutation as the grouped Intent Alignment finding above (Story 3.7 owns that transition); the code is already correct.
  - `[false]` `[reject]` (Blind Hunter) No rationale is given for `actor` vs. a plain `struct`/`final class` — reject: refuted by the AC itself ("the orchestrator is a Swift `actor` per AR-PAT-6" is a mandated architectural constraint, not a discretionary choice), and the shipped doc comment already cites AR-PAT-6.

## Design Notes

**Why the orchestrator never calls `TelemetryRecorder` despite the AC saying "records telemetry":** `TelemetryRecorder.record(meetingID:patch:)` is a full-struct partial-UPSERT keyed by `meetingID` — a parameter `SummarizerStrategy.summarize` doesn't take, and `State.Telemetry` has no `groundingMethod`/`fallbackTriggered` columns at all (those live in `StageMetadata.SummarizeMeta`, the `stage_events.metadata_json` payload). AR-DATA-4 gives write authority to "the subprocess executing the stage," and Story 3.7's own AC performs the telemetry UPSERT "when the orchestrator returns a `SummaryWithGrounding`" — i.e. Story 3.7 is the writer, not this orchestrator. The test AC itself confirms this reading: it exercises "stub strategies" only, with no telemetry/database fixture mentioned, so "correct telemetry" is verified by asserting on the returned `Outcome`'s fields — which is exactly what `Outcome` is for. Decision 3.3's `TelemetrySink`-based sketch in architecture.md is illustrative and predates the real `TelemetryRecorder`, so it isn't followed literally here.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build, no new dependency edges.
- `swift test --filter SummarizerOrchestratorTests` -- expected: all four new tests pass.
- `swift test` -- expected: full suite passes, no regressions.
- `mise exec -- swiftformat --lint .` && `mise exec -- swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations.

## Auto Run Result

**Summary of implemented change:** Added `SummarizerOrchestrator`, a Swift `actor` in `Sources/Summarize/`, DI'd with `primary`/`fallback` `SummarizerStrategy` values. `summarize(transcript:glossary:config:)` calls `primary` once; on a thrown `SummarizerError` with `isFallbackEligible == true` it checks for cancellation, then calls `fallback` exactly once, forwarding `transcript`/`glossary`/`config` unchanged; any other error (a different `Error` type, or a non-eligible `SummarizerError`) rethrows unmatched via Swift's own catch-pattern semantics, with no code path for a second fallback attempt. Returns an `Outcome` (`summary`, `fallbackTriggered`, `primaryError`) that a future caller (Story 3.7, not yet built) uses to record telemetry — the orchestrator itself never calls `TelemetryRecorder`, since it has no `meetingID` and AR-DATA-4 assigns that write authority to the stage-entry subprocess instead.

**Files changed:**
- `Sources/Summarize/SummarizerOrchestrator.swift` -- new -- the actor, `Outcome` type, primary/fallback wiring; patched during review to add `try Task.checkCancellation()` before the fallback call.
- `Tests/SummarizeTests/SummarizerOrchestratorTests.swift` -- new -- a file-local `StubSummarizerStrategy` actor plus one test per I/O-matrix row; patched during review to capture and assert the `transcript`/`glossary`/`config` forwarded to the fallback stub, to assert `primary.callCount` in all tests, and to add a 5th test covering a thrown non-`SummarizerError`.

**Review findings breakdown:** 16 findings across 4 parallel layers (Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment) — 0 high, 3 medium, 6 low, 7 false, 0 maybe-false. No `intent_gap` or `bad_spec` routes were needed. Full per-finding detail is in `## Review Triage Log` above.
- **Patched (1 medium entry — 3 members reporting the same gap — plus 3 low entries, all applied and reverified):** (1) the `config`/`transcript`/`glossary` forwarded to `fallback` is now captured by the stub and asserted equal to what the orchestrator was called with (three layers independently found this gap; Verification Gap demonstrated it concretely by mutating the fallback call and observing all tests still pass). (2) Added `primary.callCount == 1` to all tests. (3) Added a 5th test throwing a non-`SummarizerError` from `primary`, asserting unmatched rethrow. (4) Added `try Task.checkCancellation()` before the fallback call, so a task cancelled between primary's failure and the fallback attempt no longer triggers a paid API call it shouldn't.
- **Rejected (12 findings):** three findings (telemetry recording, meeting-state transition, composition-root wiring) were refuted by architecture evidence already reasoned through in this spec's Design Notes (AR-DATA-4 write authority, `TelemetryRecorder`'s `meetingID`-keyed API, Story 3.7's own AC ownership, `epic-3-context.md`'s explicit sequencing); one (fallback modeled optional in architecture.md's illustrative sketch) was refuted by epics.md's own non-optional instantiation example; one (no actor-vs-struct rationale) was refuted by the AC's explicit AR-PAT-6 mandate and the shipped doc comment; one was descriptive meta-commentary with no demonstrated bad outcome; three more (`deferred: []` left empty, `## Verification` omitting `make check`, an imprecise claim about `--explicit-target-dependency-import-check`) were rejected because their only fix is to edit this build's spec, which the triage rules exclude from patch/defer routing.
- **Follow-up review recommendation:** `false`. Only one medium-severity entry was patched this pass (not two or more), and no high-severity entry was patched, so per the finalize rule this doesn't qualify — patch volume/count below that threshold is not independent grounds. Noting for the record (not a trigger): the patch round was applied by a freshly-launched implementation subagent rather than the original step-03 subagent re-engaged by id (a process deviation from the intended workflow), though the resulting diff was independently re-verified against the full test suite, `swift build --explicit-target-dependency-import-check error`, and `make check` by this orchestrating run before finalizing.

**Verification performed:**
- `swift build --explicit-target-dependency-import-check error` -- clean build, both before and after the patch round.
- `swift test --filter SummarizerOrchestratorTests` -- 5/5 passed (4 pre-patch + 1 added during review).
- `make check` (full CI-matching gate: swiftformat, swiftlint, custom-lint-rule fixture self-check, actionlint, zizmor, `swift build`/`swift test` with the explicit-dependency check, a release build, both Xcode schemes) -- `BUILD SUCCEEDED`, `checks passed: all`.
- Matrix Test Audit: all 4 I/O-matrix rows confirmed covered by a test that ran and passed, both before and after the patch round.

**Residual risks:** None beyond the noted process deviation above (independently re-verified, not a functional risk). Story 3.7 (not yet built) is the intended caller of `SummarizerOrchestrator.summarize(...)` and the actual writer of `telemetry`/`meetings.state` based on the `Outcome` this story returns — that composition-root wiring and the telemetry/state-transition ACs this story's Design Notes deliberately deferred remain unverified until Story 3.7 lands.

**Finalization outcome:** pending commit by this orchestrating run.
