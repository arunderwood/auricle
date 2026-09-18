---
title: 'Story 3.7: Summarize Stage Entry Point + Cache-Dir Handoff'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: '03aa5db29ccfb7fb0513197ae4a58ef96f4c0566'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      Record `summarization_prompt_set_hash` in telemetry (epics.md:1421 assigns it to the summarize stage).
    evidence: |-
      No telemetry column or `State.Telemetry` field exists (needs a migration), and the strategies discard `SummarizationPrompt.promptSetHash`, so neither `SummaryWithGrounding` nor `SummarizerOrchestrator.Outcome` can surface it. The hash also differs per mode, so it depends on which strategy answered.
    severity: medium
  - summary: >-
      Thread real attendees and `--prompt-dir` into the prompt.
    evidence: |-
      Both strategies hard-code `attendees: []` and `promptDir: nil`; `SummarizerStrategy.summarize` and `SummarizerConfig` have no channel for either. Calendar attendees arrive with Stories 3.10/3.11.
    severity: medium
  - summary: >-
      A multi-line `quote` renders as a broken blockquote in the vault note.
    evidence: |-
      `FrontmatterRenderer.swift:100` prefixes only the first line with `> `, and Citations pointers span whole utterances, so a multi-utterance quote contains `\n`. The stage emits the exact transcript slice, as the AC requires; the renderer fix belongs to Persist.
    severity: medium
  - summary: >-
      Apply `segment_overrides`/`segment_splits` from `attribution.json`.
    evidence: |-
      They reference `diarization.json` segment ids, which have no Swift type and no mapping to utterance indices. The stage reads only `speakers`.
    severity: low
  - summary: >-
      Whether an utterance's `[start,end)` range includes the `<Speaker_N>: ` prefix is undefined until the transcribe stage exists.
    evidence: |-
      Decision 3.4 (architecture.md:1439) says the text prefixes each utterance; existing test fixtures disagree with each other. It decides whether `quote` and `transcript_segments[].text` carry the prefix. Unverified.
    severity: medium (unverified)
  - summary: >-
      No state sits between a finished summarize and the persist stage.
    evidence: |-
      The stage completes into `summarizing`, matching Persist's own Txn A. The 720s stale sweep for `summarizing` could then flag a meeting that is waiting for persist dispatch. Unverified until real dispatch exists.
    severity: medium (unverified)
  - summary: >-
      Resume from `summarization_failed` has no code path.
    evidence: |-
      `auricle run` is a stub and `CrashRecovery` does not reconcile `summarization_failed`. The stage itself re-runs cleanly because `transcript.json` is immutable.
    severity: low
  - summary: >-
      `cost_usd` records only the answering call; a failed primary call's cost is lost when the fallback wins.
    evidence: |-
      A thrown `SummarizerError` carries no cost, and `Outcome.summary.cost` is the winner's.
    severity: low
  - summary: >-
      `telemetry.grounding_method` has no column, though Decision 4.5 and the Story 3.7 AC list it as a telemetry field.
    evidence: |-
      architecture.md:1533 says the `telemetry` table carries `grounding_method`, but no migration or `State.Telemetry` field defines it. The stage records it only in the `stage_events` completion metadata (`SummarizeMeta.grounding_method`). Adding the column is a migration, which this story's intent excludes.
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The summarize stage has no entry point. `auricle-cli __internal-stage summarize <id>` validates its arguments and then stubs out; nothing loads `transcript.json`, runs `SummarizerOrchestrator`, records telemetry, or writes the `summary.json` the persist stage reads. Story 3.6 (orchestrator), `CacheArtifactWriter`, and `SummaryWithGrounding.quoteValidationDropCount` now exist, so the stage can be built.

**Approach:** Add `Summarize/SummarizeStage.swift`: load `transcript.json` (and `attribution.json` if present), run the orchestrator, map the result into a `SummaryArtifact`, write `summary.json` through `CacheArtifactWriter` with `schema_version` 1, upsert telemetry and write the `stage_events` completion row via `StageRunner`, and fold every failure into `summarization_failed` with exit code 2. Wire the `summarize` case of `InternalStageWorker` to it, with `ClaudeCitationsSummarizer` as primary and `ClaudeSubstringSummarizer` as fallback (Decision 3.6's stated MVP default). Story 3.8 was built as a rig only, so its smoke test has not run and this default is interim. Calendar enrichment (Stories 3.10/3.11) and the glossary builder (Story 3.12) are unbuilt: the stage always takes the unenriched calendar fallback, and the glossary arrives through an injected parameter that the worker sets to an empty `Glossary()`.

## Boundaries & Constraints

**Always:**
- `SummarizeStage` is a caseless enum namespace like `PersistStage`. Everything runs inside one `stageRunner.run(stage: .summarize, meetingID:, activeState: .summarizing)`; nothing escapes `work`. Success is `.completed(targetState: .summarizing, ...)`, matching Persist's own Txn A; every failure is `.failed(targetState: .summarizationFailed, errorClass:, errorMessage:, ...)`.
- Inputs and the output live in `CacheArtifactWriter.cacheDirectory(for: meetingID)`; `summary.json` is written only with `CacheArtifactWriter.write(_:for:named:schemaVersion: 1)`. The stage takes no cache-directory parameter, so a test plants `transcript.json` in a fresh meeting's real cache directory and removes it afterward, as `CacheArtifactWriterTests` does.
- The `CanonicalTranscript` is decoded once and that one value goes to the orchestrator and to quote extraction. A `quote` is the exact UTF-8 byte slice `transcript.text[start..<end]`; share one bounds-checked slicer with `SmokeTestReportRenderer.sourceQuote` rather than writing a second.
- `SummaryArtifact`, `QuotedItemArtifact` and `TranscriptSegmentArtifact` move from `Sources/Persist/` to `Sources/Core/` unchanged, because `Summarize` may not import `Persist` (no stage-to-stage imports) and the producer and consumer must share one definition.
- Unenriched calendar output: `title` = `Meeting at <YYYY-MM-DD'T'HH:mm> <local time zone abbreviation>` from `meetings.capture_started_at` in an injected `TimeZone` (default `.current`), `calendarEventTitle` nil, `needsCalendarEnrichment` true, `attendees` `[]`, `selfWikilink` nil. This matches Decision 2.2 and the renderer's own combined-variant test.
- `needsAttribution` is true unless `attribution.json` exists and maps every distinct utterance `speakerLabel`. Read only its `speakers` object (`Speaker_N` → `[[Name]]`); ignore every other key. A segment's `speaker` is the mapped wikilink, else `[[<speakerLabel>]]`.
- Telemetry goes only through `TelemetryRecorder.record`, with `summarizationPath` `"claude_api"`, `summarizationModel`, `summarizationEffortBudget`, `costUSD`, `quoteValidationDropCount`. The completion `metadataJSON` is an encoded `SummarizeMeta` (not `StageMetadata.summarize`), which gains `fallbackTriggered: Bool` and `fallbackErrorClass: String?` from `SummarizerOrchestrator.Outcome`.
- Error classes are stable snake_case strings. No transcript text, quote, or raw foreign error message may appear in `errorMessage`, `metadataJSON`, or a log field; use the error case or type name only.
- `SummarizeStage.exitCode(for: StageRunner.StageOutcome) -> Int32` is a pure function: completed 0, failed 2. `InternalStageWorker` only wires dependencies and calls it.
- `Summarize` gains a dependency on `Orchestrator` (Persist already has that edge). Real logic lives in `Sources/`; `App/` stays thin.

**Never:**
- Never run `__internal-stage summarize` with a well-formed meeting id, or anything that opens the production database or calls the live API, while building or verifying. Use only invalid-id, bad-protocol-version, `--help`, and stub-stage checks.
- Don't build or wire `CalendarSource`, calendar fetching, `calendar.json`, the glossary builder, `glossary.json`, `--prompt-dir`, or attendee threading. Don't add a telemetry migration. Don't change `FrontmatterRenderer`. Don't change strategy behavior.
- Don't decide the default between Citations and substring; wire the interim default and say so in a comment on the wiring.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path, no `attribution.json` | Meeting row with `capture_started_at`; `transcript.json` with 2 utterances; stub primary returns 2 items | `summary.json` written with `schema_version` 1 that decodes as `SummaryArtifact`; unenriched title, `needsCalendarEnrichment` true, `needsAttribution` true, `attendees` `[]`; each `quote` equals the slice; segments `[[Speaker_1]]`/`[[Speaker_2]]`; telemetry columns upserted; `started` then `completed` events; state `summarizing`; outcome completed | None |
| Attribution maps every speaker | `attribution.json` `speakers` covers all labels | `needsAttribution` false; segments use `[[Name]]` | None |
| Attribution partial | Only some labels mapped | `needsAttribution` true; mapped names used, others `[[Speaker_N]]` | None |
| Attribution malformed | `attribution.json` is not decodable | Nothing written to `summary.json` | `.failed`, class `attribution_undecodable`, state `summarization_failed` |
| Transcript missing or bad | No `transcript.json`, or undecodable | Nothing written | `.failed`, class `transcript_missing` / `transcript_undecodable` |
| No capture time | Meeting row has no `capture_started_at` (or no row fields for it) | Nothing written | `.failed`, class `capture_started_at_missing` |
| Fallback wins | Primary throws a fallback-eligible `SummarizerError`; fallback succeeds | Completed; `grounding_method` `substring`; metadata `fallback_triggered` true with the primary's error class | None |
| Orchestrator throws | Both strategies fail, or a non-eligible error | No `summary.json`; state `summarization_failed` | `.failed`, class `summarizer_<case>` |
| Other error | A non-`SummarizerError` is thrown | Failure records the type name only | `.failed`, class `summarize_unexpected_error` |
| Bad pointer | A returned `GroundingPointer` is out of range | No `summary.json` | `.failed`, class `quote_extraction_failed` |
| Re-run | Stage succeeds twice for the same meeting | `summary.json` atomically replaced, no leftover temp file; a second `started`/`completed` pair | None |
| Exit codes | Completed / failed outcome | 0 / 2 | None |
| CLI, invalid id | `__internal-stage summarize not-a-ulid --worker-protocol-version 1` | Message on stderr, exit 1, state store never opened | User error |

</intent-contract>

## Code Map

- `Sources/Persist/PersistStage.swift:12,73-98,200-213,294-303` -- the stage precedent: caseless enum, one `stageRunner.run`, `do/catch` returning `.failed`, a nested error enum with an `errorClass`, `Data(contentsOf:)` + `JSONDecoder`. Mirror its shape; `Tests/PersistTests/PersistStageTests.swift:12-14` -- real in-memory `StateStore.forTesting` (needs `@testable import State` + GRDB), real `StageRunner`, no stubs.
- `Sources/Orchestrator/StageRunner.swift:23,63-76` -- `run(stage:meetingID:activeState:work:)`, `StageOutcome`.
- `Sources/Summarize/SummarizerOrchestrator.swift` -- `summarize(transcript:glossary:config:) -> Outcome{summary, fallbackTriggered, primaryError}`.
- `Sources/Persist/SummaryArtifact.swift` -- move to `Sources/Core/`; consumed by `PersistStage.swift:200-213`.
- `Sources/Telemetry/StageMetadata.swift:150-198` -- `SummarizeMeta` (add the two fallback fields; update `StageMetadataRoundTripTests`). `Sources/Telemetry/TelemetryRecorder.swift` -- `record(meetingID:patch:)`. `Sources/State/Telemetry.swift:25-70` -- the real columns.
- `Sources/State/StateStore.swift:51,75` -- `subprocess(path: nil)` defaults to the production path; `fetchMeeting(id:)`; `Sources/State/Meeting.swift:13` -- `captureStartedAt: String?`.
- `Sources/Summarize/SmokeTestReportRenderer.swift` -- `sourceQuote(for:in:)`, the UTF-8 slicer to share.
- `Sources/Core/CacheArtifactWriter.swift`, `CanonicalTranscript.swift`, `MeetingID.swift`; `.swiftlint.yml` `transcript_decode_bypass` exempts `JSONDecoder().decode(CanonicalTranscript.self, ...)`.
- `App/auricle-cli/Verbs/InternalStageWorker.swift:25-27` -- replace the `notYetImplemented` stub for `.summarize` only; the other stages stay stubs. `InternalStageValidation.swift`, `NotYetImplemented.swift` -- validation and exit-code style. Needs a `composition_root_strategy_bypass` exclusion in `.swiftlint.yml` (currently `AuricleApp.swift`, `AuricleCLI.swift`, `SmokeTestSummarizeVerb.swift`).
- `Package.swift:83-88,157-160` -- add `Orchestrator` to `Summarize`; mirror `PersistTests`' dependencies for `SummarizeTests` (`Orchestrator`, `State`, GRDB).
- `_bmad-output/planning-artifacts/epics.md:1575-1608` -- Story 3.7 ACs; `architecture.md:892` -- Decision 2.2 variants; `:608-616` -- exit codes.

## Tasks & Acceptance

**Execution:**
- `Sources/Persist/SummaryArtifact.swift` -> `Sources/Core/SummaryArtifact.swift` -- move; fix imports in Persist and its tests.
- `Sources/Telemetry/StageMetadata.swift` and its test -- add the two fallback fields to `SummarizeMeta` with snake_case keys `fallback_triggered`, `fallback_error_class`.
- `Sources/Summarize/` -- `SummarizeStage.swift` plus small helpers (title fallback, attribution reader, mapper) one primary type per file; extract the shared slicer.
- `Package.swift` -- dependency edges above.
- `Tests/SummarizeTests/SummarizeStageTests.swift` (and helper tests) -- one test per matrix row using stub `SummarizerStrategy` values, a real in-memory `StateStore`, and a fresh meeting id with cache cleanup.
- `App/auricle-cli/Verbs/InternalStageWorker.swift`, `.swiftlint.yml` -- wire `summarize`: parse the id with `MeetingID(ulid:)` (invalid: stderr, exit 1), `StateStore.subprocess()`, `StageEventLogger`, `StageRunner`, `TelemetryRecorder`, the interim orchestrator, an empty `Glossary()`, `SummarizerConfig()`; throw `ExitCode` from `exitCode(for:)`.

**Acceptance Criteria:**
- Given a meeting with `transcript.json` and a stub orchestrator result, when the stage runs, then `summary.json` exists with `"schema_version": 1`, decodes as `SummaryArtifact`, and each quote equals `transcript.text` sliced by the item's pointer.
- Given a completed run, when telemetry and events are read, then the telemetry columns hold the model, effort, cost, drop count and `claude_api`, and the `completed` event's metadata holds the eight `SummarizeMeta` fields plus the fallback fields.
- Given a failing orchestrator, when the stage runs, then the meeting is in `summarization_failed`, no `summary.json` exists, and the exit code is 2.
- Given a successful run repeated, when the stage runs again, then `summary.json` is replaced atomically and another `started`/`completed` pair is recorded.
- Given `__internal-stage summarize not-a-ulid --worker-protocol-version 1`, when the built CLI runs it, then it exits 1 with a message and never opens the state store.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 38 findings — high 0, medium 6, low 25, false 7, maybe-false 0
- findings:
  - `[low]` `[reject]` (Blind Hunter) A failed run can leave `summary.json` on disk (telemetry fails after the write; a failed re-run keeps the earlier file) — no reader opens `summary.json` unless summarize completed, and a leftover is a valid summary of an immutable transcript; deleting on failure adds a failure path.
  - `[low]` `[reject]` (Blind Hunter) `CancellationError` becomes `summarize_unexpected_error` — the worker subprocess has no cancellation source (a signal kills the process without cancelling tasks), so it is unreachable today.
  - `[low]` `[reject]` (Blind Hunter) Failure rows drop the primary's error class, metadata and cost — the orchestrator rethrows only the fallback's error and the spec asks for class and type name only.
  - `[low]` `[reject]` (Blind Hunter) One bad grounding pointer fails the whole stage — contracted by the I/O matrix (fail loud), and the strategies' validators keep pointers in range.
  - `[medium]` `[patch]` (Blind Hunter) `SummarizeStageError.meetingNotFound` looks unreachable — verified: production enforces foreign keys, so a missing row fails Txn A with a `DatabaseError` and the worker's exit-3 branch never fires; patched: the stage checks the meeting first and throws `StateStoreError.meetingNotFound`, the dead case is removed.
  - `[low]` `[reject]` (Blind Hunter) Worker logic (id parse, exit-code mapping) sits in `App/` untested — `App/` has no test target by repo design (AGENTS.md pitfall); the mapping is a dozen lines, and moving it adds a public seam.
  - `[low]` `[reject]` (Blind Hunter) The worker parses the id with `MeetingID(ulid:)`, not `MeetingIDResolver` — the dispatcher always passes the full canonical ULID, and the resolver has no GRDB data-source conformance to use yet.
  - `[medium]` `[patch]` (Blind Hunter) Attribution values are not validated — an empty value counted as mapped, against architecture.md:1718 ("empty or missing values mean render as `Speaker_N`"); patched: blank values are dropped. Bare non-wikilink values are not documented, so they stay as read.
  - `[low]` `[reject]` (Blind Hunter) An empty transcript still costs an API call — silent meetings are the `silent` state upstream and the guard needs a new error class for a case not shown reachable.
  - `[low]` `[reject]` (Blind Hunter) Distinct root causes share one error class — diagnostic granularity only; splitting adds cases.
  - `[false]` `[reject]` (Blind Hunter) Tests assume utterance ranges include the `Speaker_N: ` prefix and the attributed case never asserts segment text — the stage slices whatever range an utterance carries, the contract is already a deferred item, and the mapper tests assert segment text and speaker.
  - `[low]` `[reject]` (Blind Hunter) `UnenrichedMeetingTitle` soft spots (`?? 0`, `%d`, zone dependence, one test zone) — no wrong output demonstrated; the components are always present for a Gregorian calendar.
  - `[low]` `[reject]` (Blind Hunter) `SummarizeMeta` gained required fields and no schema bump — no summarize rows exist yet, and the fields are additive.
  - `[low]` `[reject]` (Blind Hunter) Telemetry records the configured model, not the answering model — surfacing it needs a strategy interface change; the request always uses the configured id.
  - `[low]` `[reject]` (Edge Case Hunter) No entry-state guard, so concurrent runs race on `summary.json` — `PersistStage` has the same shape; dispatch-time gating belongs to the orchestrator.
  - `[low]` `[reject]` (Edge Case Hunter) Telemetry throwing after the write leaves `summary.json` — same root as the first Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) Empty text or zero utterances — same as the empty-transcript row above.
  - `[low]` `[reject]` (Edge Case Hunter) A pointer with `start == end` yields an empty quote — the validators cannot produce one for non-empty input, so it is not shown reachable.
  - `[medium]` `[patch]` (Edge Case Hunter) Attribution values empty, null or not `[[Name]]` — same root as the attribution row above; null still fails loud as `attribution_undecodable`.
  - `[low]` `[reject]` (Edge Case Hunter) `segment_overrides`/`segment_splits` are not applied — already a deferred item; the schema composes them over `diarization.json` segment ids, which have no type yet.
  - `[false]` `[reject]` (Edge Case Hunter) "Fold every failure into `summarization_failed`" is not true when `StageRunner`'s own writes fail — that is `StageRunner`'s documented crash model (state stays in the active state for the stale sweep), and the worker exits 2.
  - `[low]` `[reject]` (Edge Case Hunter) A failed re-run keeps the earlier `summary.json` — same root as the first Blind Hunter row.
  - `[low]` `[reject]` (Verification Gap) Worker wiring and exit mapping have no automated test — same as the `App/` row above; the CLI checks were run by hand.
  - `[medium]` `[patch]` (Verification Gap) A missing meeting row is never exercised through `SummarizeStage.run` — same root as the `meetingNotFound` row; patched with `missingMeetingRowThrowsMeetingNotFoundAndWritesNothing`.
  - `[low]` `[patch]` (Verification Gap) Four of seven `SummarizerError` class strings are never asserted — patched: a table-driven test over all seven with literal expected strings.
  - `[low]` `[patch]` (Verification Gap) `summary_write_failed` and the telemetry-failure path are untested — the write failure is forced without a seam by planting a directory at `summary.json`; patched. The telemetry-failure half is rejected (it would pin the leftover-file behavior rejected above).
  - `[low]` `[reject]` (Verification Gap) Telemetry throwing after the write leaves `summary.json` — same root as the first Blind Hunter row.
  - `[low]` `[patch]` (Verification Gap) `SummaryArtifact.swift` still describes a `Meeting at <HHMM>` title and a fixture producer — patched: comments now describe the current producer and format.
  - `[low]` `[reject]` (Intent Alignment) The AC lives at the subprocess boundary but tests run in-process — same as the `App/` row; the safe CLI paths were run by hand and the live path is out of scope by design.
  - `[low]` `[patch]` (Intent Alignment) Retry from `summarization_failed` is untested — the stage re-enters cleanly; patched with `aFailedRunCanBeRetriedOnTheSameMeeting` (started, failed, started, completed). The `auricle run` path is a separate deferred item.
  - `[medium]` `[defer]` (Intent Alignment) `grounding_method` is not a telemetry column — verified: no migration defines it though architecture.md:1533 says the table carries it; the intent excludes a migration, so it is recorded in `deferred`.
  - `[low]` `[reject]` (Intent Alignment) `summarization_model` records the configured, not the answering, model — same as the model row above.
  - `[false]` `[reject]` (Intent Alignment) The stage never reads `calendar.json` — the AC allows the unenriched fallback and the intent scopes calendar out.
  - `[false]` `[reject]` (Intent Alignment) "Validates groundings" is only a bounds check in the stage — grounding validation lives inside the strategies by design.
  - `[false]` `[reject]` (Intent Alignment) A `StageRunner` write failure leaves the meeting in `summarizing` — same as the fold-every-failure row.
  - `[medium]` `[patch]` (Intent Alignment) `SummarizeStageError.meetingNotFound` inside `work` has no test — same root as the `meetingNotFound` row.
  - `[false]` `[reject]` (Intent Alignment) `metadata_json` emits 10 fields against the AC's 8 — the two fallback fields are additive and intended.
  - `[false]` `[reject]` (Intent Alignment) Scope beyond the literal story (moving `SummaryArtifact`, sharing the slicer, config edits) — each is named in the spec and sits on a surface `swift test` reaches.

## Design Notes

The stage completes into `summarizing` because no state sits between summarize and persist and `PersistStage` already begins by re-asserting `.summarizing`; see the matching deferred item.

The combined title/attendees case (no calendar and no attribution, the only case reachable today) follows `FrontmatterRenderer`'s own test: generic title, `attendees: []`, both flag tags. The renderer, not the stage, derives placeholder speaker wikilinks for the body.

End to end through the built CLI, with a real meeting row and a live Claude call, is not verified here: it needs the maintainer's API key and a meeting the pipeline produced. The stage function is tested with stubs, and the CLI checks are limited to the safe paths above. The first real pipeline run (Epic 4) is the first true end-to-end check.

`SummaryArtifact.summary` is documented as "already wikilinked" but no prompt asks the model for wikilinks, so it passes through as the model wrote it. Not fixed here.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean.
- `swift test --filter SummarizeStage` and `swift test --filter StageMetadata` and `swift test --filter PersistStage` -- expected: pass.
- `scripts/check.sh lint`, `scripts/check.sh swift`, `scripts/check.sh app` -- expected: pass.
- Built `auricle-cli __internal-stage summarize not-a-ulid --worker-protocol-version 1` -- expected: exit 1, message, no database file created or opened.
- Built `auricle-cli __internal-stage summarize <any-ulid> --worker-protocol-version 99` -- expected: existing exit 2 protocol-mismatch JSON.
- Built `auricle-cli __internal-stage transcribe <any-ulid> --worker-protocol-version 1` -- expected: unchanged stub, exit 2.

## Auto Run Result

**Summary of implemented change:** Added `SummarizeStage`, the summarize stage's subprocess entry point. It loads `transcript.json` (and `attribution.json` when present), runs `SummarizerOrchestrator`, maps the result into a `SummaryArtifact` (unenriched calendar variant; quotes and segments are exact UTF-8 slices of the one decoded transcript), writes `summary.json` through `CacheArtifactWriter` with `schema_version` 1, upserts telemetry, and completes into `summarizing` through `StageRunner` with a `SummarizeMeta` completion row that now also records `fallback_triggered` and `fallback_error_class`. Every failure inside the stage becomes `summarization_failed` with a stable snake_case class, and `exitCode(for:)` maps completed to 0 and failed to 2. `InternalStageWorker` now runs the stage for `summarize` only, with Citations as primary and substring as fallback (Decision 3.6's stated default, marked provisional because Story 3.8's smoke test has not run) and an empty `Glossary()`. `SummaryArtifact` moved from `Persist` to `Core` so producer and consumer share one definition.

**Files changed:**
- `Sources/Summarize/SummarizeStage.swift`, `SummarizeStageError.swift`, `SummaryArtifactMapper.swift`, `AttributionSpeakers.swift`, `UnenrichedMeetingTitle.swift`, `TranscriptSlicer.swift` -- the stage and its helpers; `SmokeTestReportRenderer.swift` now shares the slicer.
- `Sources/Core/SummaryArtifact.swift` -- moved from `Sources/Persist/`; comments updated to the current producer and title format.
- `Sources/Telemetry/StageMetadata.swift` -- `SummarizeMeta` gains the two fallback fields.
- `App/auricle-cli/Verbs/InternalStageWorker.swift`, `.swiftlint.yml`, `Package.swift` -- wiring, lint exclusion, dependency edges.
- `Tests/SummarizeTests/` (7 new files), `Tests/TelemetryTests/StageMetadataRoundTripTests.swift` -- one test per matrix row plus review-added tests.

**Review findings breakdown:** 38 findings across 4 layers -- 0 high, 6 medium, 25 low, 7 false, 0 maybe-false. No `intent_gap` or `bad_spec` routes. Full detail is in `## Review Triage Log`.
- **Patched (6 entries: 2 medium, 4 low):** the stage now checks the meeting exists before `StageRunner` runs, so a missing row throws `StateStoreError.meetingNotFound` and the worker's exit-3 branch is reachable (production enforces foreign keys, which would have made it a `DatabaseError`; three layers found it); blank attribution values are treated as unmapped per Decision 5.4; added tests for retry after failure, all seven `SummarizerError` class strings, and `summary_write_failed`; corrected `SummaryArtifact` comments.
- **Deferred (1 new entry):** `telemetry.grounding_method` has no column, so it is recorded only in the completion metadata; the fix is a migration the intent excludes. Eight more were recorded up front in `deferred` and are appended to `deferred-work.md`.
- **Rejected (31 findings):** every reason is in the triage log. The main groups: a leftover `summary.json` after a failed run (no reader opens it unless summarize completed); `App/` glue staying manually verified (AGENTS.md pitfall); cancellation and empty-transcript cases not shown reachable; diagnostic-granularity requests; and the planning-level scope lines.
- **Follow-up review recommendation:** `true`. Two medium entries were patched. The unverified risk: the missing-meeting and blank-attribution fixes were verified against an in-memory, foreign-keys-unenforced store and synthetic `attribution.json` files, never through the built CLI against the production database or a real `attribution.json` (the Attribute stage is unbuilt, and the spec forbids running the worker with a well-formed id). Patched counts: medium 2, low 4.

**Verification performed:**
- `scripts/check.sh lint`, `scripts/check.sh swift` (348 tests, release build), `scripts/check.sh app` (both schemes) -- all passed, before and after the patch round.
- Built `auricle-cli`: `__internal-stage summarize not-a-ulid` exits 1 with a message; a bad protocol version exits 2 with the mismatch JSON; `transcribe` is the unchanged stub (exit 2). `~/Library/Application Support/com.auricle.app` was absent before and after, so the state store was never opened.
- Matrix Test Audit: all 12 matrix rows with unit tests have a passing test; the CLI row was verified by hand.
- The live path (real meeting row, real Claude call) was never run, as the spec requires.

**Residual risks:**
- Story 3.7 runs on an interim strategy default; Story 3.8's human smoke-test run still decides it.
- Telemetry is written after `summary.json`, so a telemetry failure leaves a valid `summary.json` beside a `summarization_failed` meeting; a re-run overwrites it.
- `cost_usd` and `summarization_model` record the answering call and the configured model only.
- A multi-line quote will render as a broken blockquote until `FrontmatterRenderer` is fixed (deferred).

**Finalization outcome:** pending commit by this orchestrating run.
