---
title: 'Story 3.11: Calendar Enrichment Graceful Degradation'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: '78b0cf21bc22ed169670da1f13ac94c939ae5a1d'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** `SummarizeStage` never asks a calendar source for anything. It always renders the unenriched variant, writes no `calendar.json`, and the strategies hard-code `attendees: []`, so a matched event could not reach the prompt or the note even if a source existed. Story 3.10 (`GoogleCalendarSource`) is not built, and `CalendarInterface` is an empty placeholder.

**Approach:** Declare the `CalendarInterface` types Story 3.10's first AC defines (`CalendarSource`, `CalendarEvent`, `CalendarError`). Add an optional enrichment sub-step to `SummarizeStage`: a matched event fills the title, attendees and prompt; a nil result, any error, or no source leaves the existing unenriched variant. Either way the stage writes `calendar.json` and never fails on calendar trouble.

## Boundaries & Constraints

**Always:**
- Calendar failure never fails the stage and never blocks `summary.json`. Every error from the source is absorbed, except `CancellationError`, which still ends the stage as a failed outcome.
- The sub-step runs after the inputs are read and before the summarizer call, because attendee names feed the prompt. A bad input never costs a calendar call.
- `calendar.json` is written via `CacheArtifactWriter` (schema_version 1, snake_case keys) for both variants. A failure to write it is logged and ignored.
- Attendee emails never reach the prompt, `calendar.json` or the note. An attendee without a usable display name is omitted from the prompt and from the note's attendees.
- A display name is sanitized before use: `[ ] | # ^ \` and control characters removed, whitespace collapsed and trimmed. One that becomes empty is omitted. In the note it becomes `[[Name]]`; in the prompt it stays plain.
- A matched event whose title is blank after trimming counts as no usable event: the degraded variant.
- Only errors' case or type names are logged (`Log.warn`, `.publicSafe`), never an error's message.
- On a match, `meetings.title` and `meetings.calendar_event_id` are refreshed through `StateStore` inside the stage body. On degradation the row is untouched.
- Default stays backward compatible: `calendarSource` defaults to `nil`, and `SummarizerConfig.attendeeNames` defaults to `[]`, so existing call sites and prompt snapshots do not change.

**Never:**
- No `GoogleCalendarSource` code, OAuth, Keychain, HTTP or `EventMatcher` (Story 3.10). `Sources/GoogleCalendarSource` and `App/` stay unchanged; the composition root keeps passing no source.
- Don't change `SummarizerStrategy`'s method signature, the persist stage, `FrontmatterRenderer`, or any frontmatter schema field.
- No re-enrichment of an existing note (FR26). No timeout logic in the stage: Story 3.10's source owns request timeouts.
- Don't add a field to `SummarizeMeta` / `stage_events.metadata_json`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Match found | Source returns an event with a title and attendees | `calendar.json` `degraded:false` plus the event; `summary.json` title = event title, `calendar_event_title` set, attendees `[[Name]]`, `self_wikilink` set, `needs_calendar_enrichment:false`; strategy sees `attendeeNames`; meeting row `title` and `calendar_event_id` updated | No error |
| No match | Source returns `nil` | `calendar.json` `{degraded:true}` with no `event`; generic `Meeting at <local time>` title, `attendees:[]`, `needs_calendar_enrichment:true`; row untouched | Stage completes |
| Unreachable | Source throws `CalendarError.unreachable` | Same as no match | Warn logged; stage completes |
| Auth expired | Source throws `CalendarError.authorizationExpired` | Same as no match | Warn logged; stage completes |
| Foreign error | Source throws any other error | Same as no match | Warn logged with type name only |
| Blank title | Event with `"  "` title | Same as no match | Stage completes |
| No source | `calendarSource` is `nil` | Same as no match | No call made |
| Cancelled | Source throws `CancellationError` | Stage ends `summarization_failed` | Summarizer is not called |
| Nameless attendee | Attendee with only an email | Omitted from prompt and note; never appears anywhere | No error |
| Hostile name | Display name `Ben]] \| #x` | Sanitized to `Ben x` before wikilinking | No error |
| Degraded note | Stage then persist on a degraded run | Note carries `auricle/meeting` and `auricle/needs-calendar-enrichment`, generic title, `attendees: []`; `FrontmatterReader.read` parses it | No error |

</intent-contract>

## Code Map

- `Sources/CalendarInterface/ManifestPlaceholder.swift` -- delete once real files land. Target depends on `Core` only. Architecture tree (`architecture.md:2342-2345`) names `CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift`.
- `_bmad-output/planning-artifacts/epics.md:1682-1720` -- Story 3.10 AC1 gives the exact protocol shape (`authorize()`, `fetchActiveEvent(at:)`, `upcomingEvents(in:)`), the event fields (title, attendees with email and display name, `google:<id>` event ID, start/end) and the two error cases.
- `Sources/Core/SummaryArtifact.swift` -- template for a cache-artifact type in `Core` (explicit `CodingKeys`, snake_case). New `CalendarArtifact` sits beside it because `CalendarInterface` depends on `Core`, not the reverse.
- `Sources/Core/CacheArtifactWriter.swift:27-46` -- `write(_:for:named:schemaVersion:)` injects `schema_version`; the value must encode to a JSON object.
- `Sources/Core/ISO8601UTC.swift` -- `string(from:)` for the artifact's `start`/`end`.
- `Sources/Core/Log.swift` -- `Log(category:)`, `.warn(StaticString, [String: LogSensitivity])`. `ClaudeSubstringSummarizer.swift:61` shows the usage.
- `Sources/Summarize/SummarizeStage.swift:122-177` -- stage body. Insert enrichment after `resolvePromptSetHashes` (line 142) and before `orchestrator.summarize` (line 144); pass the enriched `SummarizerConfig`. Both `run` overloads (lines 32, 58) gain `calendarSource: (any CalendarSource)? = nil`. The `RunContext` struct (line 105) can carry it.
- `Sources/Summarize/SummaryArtifactMapper.swift:36-58` -- `artifact(...)` hard-codes the unenriched variant. It gains an optional enrichment input and derives title, `calendarEventTitle`, `attendees`, `selfWikilink`, `needsCalendarEnrichment`.
- `Sources/Summarize/UnenrichedMeetingTitle.swift` -- the generic title; reused unchanged for every degraded case.
- `Sources/Persist/FilenameResolver.swift:44-52` -- attendees minus `selfWikilink` feed slug source 2, so the mapper must set `selfWikilink` from the event's self attendee.
- `Sources/SummarizerInterface/SummarizerConfig.swift` -- gains `attendeeNames: [String] = []`. `SummarizerOrchestrator.swift:58,63` passes `config` through unchanged, so the fallback inherits it.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift:75-85` and `ClaudeCitationsSummarizer.swift:82-93` -- replace `attendees: []` with `config.attendeeNames`; rewrite the comments above them. `SummarizationPromptBuilder.swift:235-237` renders `Attendees: a, b`, empty when none.
- `Sources/State/StateStore.swift:75,91` -- `fetchMeeting`, `updateMeeting` (whole row). `PersistStage.swift:139-140` does the same fetch-then-update inside its work closure.
- `Sources/Persist/PersistStage.swift:120-200` and `FrontmatterRenderer.swift:19-20` -- already render the degraded variant from `SummaryArtifact`; read-only here.
- `Tests/SummarizeTests/SummarizeStageFixture.swift` -- `StageFixture`, `StageStubStrategy` (ignores `config`; gains a captured `lastConfig`), `makeStageGrounded`, `stageExpectedTitle`. `Tests/SummarizeTests/SummarizeToPersistTests.swift` shows stage-then-persist and the vault setup.
- `Tests/ClaudeSummarizerTests/ClaudeSubstringSummarizerTests.swift`, `ClaudeCitationsSummarizerTests.swift` -- `URLProtocol` stub pattern that can read the request body.
- `Package.swift:144-148` -- `SummarizeTests` deps lack `CalendarInterface`; `--explicit-target-dependency-import-check error` needs it. `Package.swift:77` -- `CalendarInterface` deps.
- `_bmad-output/implementation-artifacts/deferred-work.md:62-64` -- the "thread real attendees" entry; this story closes its attendee half.

## Tasks & Acceptance

**Execution:**
- `Sources/CalendarInterface/CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift` (delete `ManifestPlaceholder.swift`) -- public `CalendarSource: Sendable` protocol; `CalendarEvent` (`id` as `google:<id>`, `title`, `start`, `end`, `attendees`) and `CalendarAttendee` (`email`, `displayName?`, `isSelf`); `CalendarError` (`authorizationExpired`, `unreachable`) -- the types the stage consumes and Story 3.10 will implement.
- `Sources/Core/CalendarArtifact.swift` -- `degraded`, optional `event` (`event_id`, `title`, `start`, `end`, `attendees[{display_name?, is_self}]`), no emails -- the `calendar.json` contract.
- `Sources/SummarizerInterface/SummarizerConfig.swift` -- add `attendeeNames` -- the missing prompt channel.
- `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift`, `ClaudeCitationsSummarizer.swift` -- pass `config.attendeeNames` to the prompt builder -- injects event metadata into the prompt.
- `Sources/Summarize/CalendarEnrichment.swift` -- internal: run the source (absorbing errors, rethrowing cancellation), sanitize names, build the enriched result (title, wikilinks, self link, plain names, `CalendarArtifact`) or the degraded one -- one place for the degradation rule.
- `Sources/Summarize/SummaryArtifactMapper.swift` -- accept the enrichment and fill the artifact fields for both variants -- frontmatter injection.
- `Sources/Summarize/SummarizeStage.swift` -- add the `calendarSource` parameter, run the sub-step, write `calendar.json`, pass `attendeeNames` in the config, refresh the meeting row on a match -- wires the story together.
- `Package.swift` -- add `CalendarInterface` to `SummarizeTests` -- import check.
- `Tests/SummarizeTests/StubCalendarSource.swift` and `Tests/SummarizeTests/CalendarDegradationTests.swift` -- one test per matrix row; the degraded and standard cases run stage then persist and parse the note with `FrontmatterReader` -- the AC's test list.
- `Tests/SummarizeTests/SummarizeStageFixture.swift` -- capture the config in `StageStubStrategy`; let `StageFixture.run` take a `calendarSource` -- test plumbing.
- `Tests/CoreTests/`, `Tests/CalendarInterfaceTests/`, `Tests/ClaudeSummarizerTests/` -- `CalendarArtifact` key shape (degraded has no `event`), `CalendarError` equality, and that each strategy's outbound request carries `config.attendeeNames` and nothing else about attendees -- boundary coverage.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- narrow the attendees entry to the remaining `--prompt-dir` half -- keeps the ledger true.

**Acceptance Criteria:**
- Given a source that returns an event, when the stage runs, then `calendar.json` holds the event with `degraded:false` and the note's title, attendees and tags are the standard variant.
- Given a source that returns `nil` or throws, when the stage runs, then `calendar.json` is `{degraded:true}`, the stage completes, and the persisted note has the generic title, `attendees: []` and both tags.
- Given the full gate, when `scripts/check.sh lint` and `scripts/check.sh swift` run, then both pass.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 34 findings — high 0, medium 2, low 32, false 0, maybe-false 0
- findings:
  - `[low]` `[patch]` (Blind Hunter) No time bound on the calendar lookup — a stage-level race cannot preempt a non-cooperative await, so the bound must live in the source and no source exists yet; patched by documenting the obligation on `CalendarSource.fetchActiveEvent` and in the `CalendarEnrichment` doc.
  - `[low]` `[patch]` (Blind Hunter) Only `CancellationError` is treated as cancellation — real: a `URLError(.cancelled)` from a cancelled task was absorbed as degraded; patched with `try Task.checkCancellation()` in the catch-all and a test.
  - `[low]` `[reject]` (Blind Hunter) `refreshMeetingRow` can fail the stage after the summary is written, and its fetch-then-update is two transactions — a row-write failure has the same failure domain as the telemetry write that follows it, and swallowing it would leave the row silently stale; no other writer touches the row in that window. A narrow `StateStore` method is new public surface for a negligible race.
  - `[low]` `[reject]` (Blind Hunter) A degraded re-run leaves the row and a dropped `calendar.json` write stale — the matrix says the row is untouched on degradation; the earlier values were true when written, and the case needs a re-run plus a failed write. A fix adds branches for a rare path.
  - `[low]` `[reject]` (Blind Hunter) The degraded artifact does not say why — speculative feature; nothing reads `calendar.json` yet, and the warn log names the cause.
  - `[low]` `[reject]` (Blind Hunter) Sanitizing gaps (format characters, no length or count caps) — no real source exists, and the grounding validator drops any ungrounded output. A naive format-character strip corrupts legitimate Persian and Indic names (U+200C). Caps are best set when Story 3.10 supplies real event data.
  - `[low]` `[reject]` (Blind Hunter) Duplicate attendee names produce duplicate wikilinks — needs two invitees with one display name; harmless in the prompt.
  - `[low]` `[patch]` (Blind Hunter) Nothing verifies the stage never calls `authorize()` — real test gap for a documented contract; patched with an `authorizeCount` on the stub and assertions that it stays 0.
  - `[low]` `[patch]` (Blind Hunter) `withAttendeeNames` copies fields by hand and will drop a future field — real; patched by making `attendeeNames` `public private(set) var` and copying `self`.
  - `[low]` `[reject]` (Blind Hunter) The matching contract is thin (no tolerance window, `upcomingEvents` has no reference date) — matching is Story 3.10's `EventMatcher` (its AC is `start <= t <= end`), and this story only declares the protocol.
  - `[low]` `[reject]` (Blind Hunter) `calendarErrorCasesAreNamedByTheirCaseAlone` tests the language — cosmetic; it fails if a payload is added.
  - `[medium]` `[patch]` (Edge Case Hunter) A display name that is itself an email address reaches the prompt, `calendar.json`, the wikilinks and the note — real: `sanitizedName("ada@example.com")` returned it unchanged; patched by treating any name containing `@` as unusable, with tests.
  - `[low]` `[patch]` (Edge Case Hunter) A hung lookup stalls the stage — same root as the first Blind Hunter row; patched the same way.
  - `[low]` `[patch]` (Edge Case Hunter) Cancellation absorbed when the source throws a non-`CancellationError` — same root as the second Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) `updateMeeting` failure after the summary is written fails the stage — same as the third Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) A degraded re-run leaves the row stale — same as the fourth Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) A stale `calendar.json` survives a failed write on a re-run — same as the fourth Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) Hundreds of attendees, long names and duplicates — same as the sanitizing and duplicate rows above.
  - `[low]` `[reject]` (Edge Case Hunter) A title of only invisible characters, or an empty event id, counts as a match — needs a source that breaks its contract; no source exists.
  - `[low]` `[reject]` (Edge Case Hunter) A display name with `/` or `:` makes a wikilink resolve to a path — names such as `Ben/Sam` are legitimate; stripping them changes real names for a spoof that needs a hostile invitee.
  - `[low]` `[reject]` (Edge Case Hunter) An event whose window does not contain the capture time is accepted — choosing the event is the source's job; a second check in the stage duplicates `EventMatcher`.
  - `[low]` `[patch]` (Edge Case Hunter) `withAttendeeNames` drops a future field — same root as the ninth Blind Hunter row.
  - `[low]` `[reject]` (Edge Case Hunter) Claim "never fails on calendar trouble" is false for a row-refresh error — the claim is about the source's errors, which are all absorbed; a state-store failure is not calendar trouble.
  - `[medium]` `[patch]` (Edge Case Hunter) Claim "nothing built from a `Match` can carry an email" is false for an email-valued display name — same root as the email row above.
  - `[low]` `[patch]` (Edge Case Hunter) Claim "every way a lookup can go wrong lands on `degraded`" over-states — same roots as the hang and cancellation rows; the doc now names both exceptions.
  - `[low]` `[patch]` (Verification Gap) No test shows the row refresh re-reads the row — real: reusing the start-of-stage row passes every test; patched with a strategy hook that changes `audioCachePath` mid-run and a test that it survives.
  - `[low]` `[patch]` (Verification Gap) The "bad input never costs a lookup" ordering is tested only for a missing transcript — real; patched with tests for malformed attribution, missing `capture_started_at`, an out-of-range utterance and a throwing prompt-set hash.
  - `[low]` `[reject]` (Verification Gap) A re-run after an enriched run degrades and leaves the row — same as the fourth Blind Hunter row; the matrix fixes this behavior.
  - `[low]` `[reject]` (Intent Alignment) The production call site (`InternalStageWorker.swift`) passes no source, so every real run degrades — by design: the concrete source is Story 3.10, and the spec's `Never` list keeps `App/` unchanged. Recorded as a residual risk.
  - `[low]` `[reject]` (Intent Alignment) The match branch is reachable only through a stub — same cause: `GoogleCalendarSource` is still a placeholder.
  - `[low]` `[reject]` (Intent Alignment) The degradation outcome was already what users got — true, and expected: the story adds `calendar.json` and the stage contract that Story 3.10 plugs into.
  - `[low]` `[reject]` (Intent Alignment) The AC names `GoogleCalendarSource` and the diff calls the `CalendarSource` protocol — the composition roots inject the concrete type (architecture DIP rule); the stage must depend on the protocol.
  - `[low]` `[reject]` (Intent Alignment) Nothing reads `calendar.json` — its consumers are later stories (Epic 7's coverage strip); the story only writes it.
  - `[low]` `[reject]` (Intent Alignment) `sprint-status.yaml` still says `backlog` — the workflow does not update it; the spec's own `status` is the record (AGENTS.md).

## Design Notes

Story 3.10 is unbuilt, so this story owns the interface types and leaves the concrete source to it. `authorize()` and `upcomingEvents(in:)` are declared to match Story 3.10's first AC; the stage calls only `fetchActiveEvent(at:)`.

`calendar.json` carries no emails: the file is local, but nothing yet needs them, and a later story that does can add the field.

The row refresh sits inside the stage body, after `summary.json` is written, using a fresh `fetchMeeting` so it cannot write back a stale `state`.

A display name that contains `@` is unusable, the same as a blank one: some invitations carry the address itself as the name, and the no-email rule has to hold for that input too.

A lookup that never returns is not bounded here. A stage-level race cannot preempt an await that ignores cancellation, so `CalendarSource.fetchActiveEvent` documents that each implementation bounds its own request time.

## Verification

**Commands:**
- `swift test --explicit-target-dependency-import-check error --filter CalendarDegradation` -- expected: every test passes.
- `scripts/check.sh lint` and `scripts/check.sh swift` -- expected: pass.

**Manual checks:**
- `git diff --stat` shows no change under `App/` or `Sources/GoogleCalendarSource/`.

## Auto Run Result

**Summary of implemented change:** Story 3.11's calendar degradation, built against a protocol because Story 3.10 (`GoogleCalendarSource`) does not exist yet. `CalendarInterface` now declares `CalendarSource`, `CalendarEvent`/`CalendarAttendee` and `CalendarError` in the shape Story 3.10's first AC defines. `SummarizeStage` takes an optional `calendarSource` and runs an enrichment sub-step after the inputs are read and before the summarizer call. A matched event supplies the note's title, attendee wikilinks and self link, the prompt's attendee names (through the new `SummarizerConfig.attendeeNames`), and a refresh of `meetings.title` and `calendar_event_id`. No source, no match, a blank title or any error from the source leaves the unenriched variant: generic `Meeting at <local time>` title, `attendees: []` and both tags. Either way `calendar.json` is written with a `degraded` flag, and calendar trouble never fails the stage.

**Files changed:**
- `Sources/CalendarInterface/CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift` -- the interface types (placeholder removed).
- `Sources/Core/CalendarArtifact.swift` -- the `calendar.json` contract, without emails.
- `Sources/Summarize/CalendarEnrichment.swift` -- lookup, error absorption, name sanitizing, match shaping.
- `Sources/Summarize/SummarizeStage.swift`, `SummaryArtifactMapper.swift` -- the sub-step, `calendar.json` write, row refresh, enriched artifact.
- `Sources/SummarizerInterface/SummarizerConfig.swift`, `Sources/ClaudeSummarizer/ClaudeSubstringSummarizer.swift`, `ClaudeCitationsSummarizer.swift` -- the attendee-name channel into the prompt.
- `Package.swift` -- `CalendarInterface` added to the `SummarizeTests` dependencies.
- `Tests/SummarizeTests/CalendarDegradationTests.swift`, `StubCalendarSource.swift`, `SummarizeStageFixture.swift`; `Tests/CoreTests/CalendarArtifactTests.swift`; `Tests/CalendarInterfaceTests/CalendarErrorTests.swift`; `Tests/ClaudeSummarizerTests/*`; `Tests/SummarizerInterfaceTests/SummarizerConfigTests.swift` -- 25 stage-level tests plus boundary tests.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- the attendee half of an earlier entry is closed.

**Review findings breakdown:** 34 findings across 4 layers -- 0 high, 2 medium, 32 low, 0 false. Full per-finding detail is in `## Review Triage Log`.
- **Patched (7 entries: 1 medium, 6 low):** an email-valued display name is dropped (found by two claims and one hunter row); a cancelled task that surfaces a non-`CancellationError` still stops the stage; the no-deadline obligation is documented on `CalendarSource`; `SummarizerConfig.withAttendeeNames` copies `self` so a new field cannot be dropped; the stub counts `authorize()` calls; a mid-run column change survives the row refresh; the "bad input never costs a lookup" ordering is tested for five inputs.
- **Deferred (0).**
- **Rejected (22 rows):** each with its reason in the log. Main groups: stale row or `calendar.json` on a degraded re-run (the matrix fixes it); sanitizing caps and format characters (no real source yet, and a naive strip corrupts Persian names); event matching and window checks (Story 3.10's `EventMatcher`); the intent-alignment notes that production still passes no source (by design).
- **Follow-up review recommendation:** `false`. One medium entry was patched; no high.

**Verification performed:**
- `swift test --explicit-target-dependency-import-check error --filter CalendarDegradation` -- 25 tests pass, before and after the patch round.
- `scripts/check.sh lint` and `scripts/check.sh swift` (452 tests) -- pass after the patch round.
- Mutation checks: removing the `checkCancellation` line and the `@` guard fails their tests; making the row refresh write back a stale `audioCachePath` fails `theRowRefreshKeepsColumnsChangedWhileTheSummarizerRan`. All reverted.
- Matrix Test Audit: all eleven matrix rows are covered by tests that ran and passed.
- `git diff --stat -- App Sources/GoogleCalendarSource` is empty. `scripts/check.sh app` was not run: no `App/` or Tuist input changed.

**Residual risks:**
- Nothing yet supplies a real source: `InternalStageWorker` still passes none, so every real run takes the degraded path until Story 3.10 lands and wires `GoogleCalendarSource`. If "complete story 3.11" was meant to include a working calendar match, Story 3.10 is the missing piece.
- Event matching (a start tolerance window, overlapping events) belongs to Story 3.10's `EventMatcher`; this story does not exercise it.
- Attendee count and name length are uncapped, and Story 3.10 is where real event data first arrives.
- The branch is `claude/bmad-build-autocomplete-3-11-b1dcee`; project policy asks for a semantic `type/short-kebab-description` name, so rename it before any push.
