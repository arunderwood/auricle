---
date: 2026-09-19
project: auricle
workflow: correct-course
trigger_story: none (Epic 4 is backlog; found by the bmad-sprint-planning readiness gate)
scope_classification: moderate
status: applied
applied: 2026-09-19
artifacts_affected:
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/implementation-artifacts/sprint-status.yaml
---

# Sprint Change Proposal — Epic 4 Readiness Gaps

## 1. Issue Summary

### Problem statement

The readiness gate for Epic 4 returned CONCERNS. A developer building Epic 4 as written would have to invent
decisions that no artifact records. Eight gaps are in scope. All eight are plan text. No Epic 4 code exists.

| # | Gap | Where |
|---|---|---|
| 1 | No path from an audio file on disk to a meeting row | Epic 4 goal (`epics.md:1817`); Story 4.9 inserts rows only inside a test (`epics.md:2141`) |
| 2 | Nothing says which process runs `persist` and `notify` under `auricle run`; nothing owns `published → awaiting_verification` | `architecture.md:372`, Story 4.7, Story 4.8, `InternalStageWorker.swift:42` |
| 3 | Story 4.2 writes `stage='diarize'`, but no such stage exists | `epics.md:1896`, `PipelineStage.swift`, `architecture.md:547` |
| 4 | Story 4.9's exit gate cannot measure what it claims | `epics.md:2148-2166` |
| 5 | Story 4.6 puts `AttributionViewModel` in `Core`, which cannot import the types it decodes | `epics.md:2011-2045` |
| 6 | Story 4.6's `attribute --speakers` conflicts with FR27 [v1.1], Story 10.4 and Story 9.5 | `prd.md:504`, `architecture.md:464`, `epics.md:3733` |
| 7 | `auricle run` spawns workers with a resolver written for the GUI bundle | `SubprocessDispatcher.swift:31-33`, Story 4.7 |
| 8 | Story 4.9's exit gate asserts on `auricle status <id>`, which is a stub until Story 9.6 | `epics.md:657`, `StatusVerb.swift`, Story 9.6 |

Story numbers in this table and in Evidence are the current ones: 4.8 is the notification stub and 4.9 the exit gate.
Section 4 uses the new numbers: 4.8 is the import verb, 4.9 the notification stub, 4.10 the exit gate.

Smaller items folded in: Story 4.4 does not match the shipped `JargonCorrectionStrategy`. Story 4.5 assumes a
`Package.swift` edge that does not exist. Nothing owns applying `segment_overrides` and `segment_splits` in the summarize
stage (`deferred-work.md`, Story 3.7 entry).

### How it was discovered

`bmad-sprint-planning` on 2026-09-18 ran the gate against the Epic 4 stories, `Sources/`, `Package.swift`,
`architecture.md` and the Epic 3 retro. Three of the gaps (3, 5, 6) and the `published → awaiting_verification` owner
in gap 2 surfaced during this correct-course analysis, not in the gate. Gap 8 surfaced while applying the edits.

### Evidence

- **Gap 1.** The only `meetings` row producers are Story 5.4 (`CaptureStage`) and Story 4.9's test. `auricle record [<id>]`
  is capture (`architecture.md:482`). The Epic 3 retro says real-meeting validation "stays open for Epic 4" (SR-4).
- **Gap 2.** Decision 1.1 puts `persist` and `notify` in the GUI process and says the notification delegate must live in
  the app process (`architecture.md:372`). It also says the CLI can run any stage as a subprocess (FR12).
  AR-PIPE-1 (`epics.md:252`) runs `attribute`, `persist` and `notify` in-process. `InternalStageWorker` handles only
  `summarize`, and the other subprocess stages (`transcribe`, `review-diarization`) are wired by their own stories.
  `PersistStage` exists (`Sources/Persist/PersistStage.swift`) but ends at `published`. The state table moves
  `published → awaiting_verification` after notify (`architecture.md:384`, `:1065`, `:1075`, `:2837`). No story said the
  CLI runs notify, or with which `Notifier`.
- **Gap 3.** `architecture.md:547`: "there's no separate diarize stage to run". `PipelineStage` has nine cases and no
  `diarize`. `architecture.md:2614` says `Transcribe` and `Diarize` share a subprocess but do not import each other.
- **Gap 4.**
  - Story 4.9 measures a ≥80% grounding rate and a cost ceiling, but its CI test stubs Anthropic. A stub returns fixed text,
    so the rate and cost are properties of the stub.
  - The AC calls the fixture set "the same one the user used in Story 3.8 and 3.9". Epic 3 used public transcripts (four AMI
    meetings, two film scenes) with no audio for the film scenes (retro SR-4).
  - A hosted `macos-26` runner has no ANE and would download the Whisper model. `ci.yml` has no path filters, so the
    "any PR touching…" trigger is moot.
  - The filter names `Sources/auricle-cli/Verbs/RunVerb.swift`; the file is `App/auricle-cli/Verbs/RunVerb.swift`.
  - `Tests/IntegrationTests/` and its `Package.swift` target do not exist. The script path is written `tests/scripts/`;
    the directory is `Tests/scripts/`.
  - The repository is public, so private recordings cannot be checked in.
- **Gap 5.** `AttributionViewModel` decodes `DiarizationArtifact` (`DiarizerInterface`) and `DiarizationSuggestion`
  (`AIReviewerInterface`). Both targets depend on `Core`, so a `Core` type cannot import them. `Core` already holds
  `Glossary` and `CalendarArtifact`, so the autocomplete inputs are not a problem. Nothing records the store behind
  "previously labeled speakers" (FR23, item 3). `architecture.md:2501` lists the view model under the GUI target.
- **Gap 6.** FR27 is [v1.1] and names `--speakers` and `--emit-snippets`. `architecture.md:464` defers
  `attribute --emit-snippets/--speakers` to v1.1. Story 10.4 ships `--speakers` and cites "Epic 4 Story 4.6". Story 4.6
  ships `--speakers` in Epic 4. Story 9.5 lists `attribute <id> [--batch]` "per Story 4.6", and Story 4.6 has no `--batch`.
- **Gap 7.** The default resolver is `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")`. Story 4.7 calls the
  dispatcher from `auricle-cli` itself. Whether the lookup resolves from an unbundled CLI is unverified. `AGENTS.md`
  records a related pitfall: by-name executable lookups fail silently when the product name differs.
- **Gap 8.** `StatusVerb.run` calls `notYetImplemented`. Story 9.6 (Epic 9) builds `auricle status <id>`. The Epic 4
  exit criteria (`epics.md:657`) and Story 4.9's step 7 assert `verified_at: null` through it, and the notification
  story says the state is observable only through SQLite in Epic 4. The fix reads `meetings.verified_at` from the state
  store (`StateStore` in Part A, `sqlite3` in Part B). This edit was not in the approved text and follows from it.

### Explicitly NOT part of this issue

- FR76, Phase 2 activation, the Epic 3 open items (SR-6, SR-7), and the Google sign-in (Story 9.1).
- A public `auricle import` verb. It is deferred (see 4.1).
- Posting a system notification from the CLI. It is deferred (see 4.3).

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact |
|---|---|
| Epic 4 | One story added (new 4.8). Old 4.8 and 4.9 become 4.9 and 4.10. ACs amended in 4.1, 4.2, 4.4, 4.5, 4.6, 4.7, 4.9, 4.10. Epic goal, exit criteria, story list and summary text updated |
| Epic 7 | Story 7.11 gains one AC (owner for applying overrides and splits). References to `AttributionViewModel` in `Core/` change to `Attribute/` (7.2, epic text) |
| Epic 8 | One cross-reference: "Story 4.8" becomes "Story 4.9" (`epics.md:3557`) |
| Epic 10 | Story 10.4 text: `--speakers` already ships in Story 4.6 |
| Epics 1–3, 5, 6, 9 | None. Story 9.5's `attribute --batch` line now has an owner (Story 4.6) |

Epic order, priority and count are unchanged. Epic 4 remains a gate.

### Artifact conflicts

- **PRD:** no change. FR27 stays [v1.1] as the documented user surface. FR42 and FR43 stay stubs.
- **Architecture:** six small edits (Section 4.8). No decision reversed. Decision 1.1 gains a CLI note.
- **UX spec:** none. `ux-design-specification.md:1291` describes the view model, not its target.
- **Code:** none. `Package.swift` edits happen in the stories that own them (4.5, 4.6, 4.10).
- **CI:** no `ci.yml` change. The new test target runs under the existing `swift` job.

### Technical impact

None today. Forward effects: `Attribute` gains dependencies on `DiarizerInterface` and `AIReviewerInterface`.
`ClaudeAIReviewers` gains a dependency on `ClaudeSummarizer`. The architecture graph already lists the `ClaudeSummarizer`
edge and the `AIReviewerInterface` edge of `Attribute`; `Package.swift` lags. The graph gains `DiarizerInterface` for `Attribute`.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1)

- **Option 1, Direct Adjustment.** Viable. Effort Low, risk Low. All edits are planning text against backlog stories.
- **Option 2, Rollback.** Not viable and not needed. Nothing in Epic 4 is built, and Epics 1–3 are unaffected.
- **Option 3, MVP Review.** Not needed. No scope is cut. The one addition is a hidden builder-mode verb outside the
  10-verb contract.

### Decisions taken (maintainer, 2026-09-19)

| Gap | Decision | Rejected |
|---|---|---|
| 1 | Hidden builder verb `auricle __internal-import` (new Story 4.8) | Public `import` verb (11th binding verb, new FR, Story 9.5 edit); test-only helper |
| 2 | Stdout only in Epic 4. `StdoutNotifier` in the CLI composition root; `UserNotificationNotifier` in the GUI | Spike-first CLI notification |
| 4 | Split the exit gate: CI pipeline test with stubs, plus a manual live gate on private recordings | One stubbed test |

Gaps 3, 5, 6, 7 and the small items have one recommended fix each, shown below. Each can be skipped at approval.

### Timeline impact

None on the critical path. Story 4.1 is unaffected and can start now. Stories 4.2, 4.6, 4.7, 4.8, 4.9 and 4.10 carry
the amended text. Estimated effort to apply: 45 minutes.

---

## 4. Detailed Change Proposals

Line numbers refer to `epics.md` and `architecture.md` before any edit. Proposals 4.1–4.7 edit `epics.md`. Proposal 4.8 edits `epics.md` and `architecture.md`. Proposal 4.9 follows from them.

### 4.1 New Story 4.8 — Builder-Mode Audio Import (gap 1)

Insert after Story 4.7 and before the notification story.

```
### Story 4.8: Builder-Mode Audio Import (`auricle __internal-import`)

As the maintainer (in builder mode),
I want a hidden `auricle __internal-import <audio-file>` verb that registers an existing recording as a `captured` meeting,
So that Epic 4's pipeline runs on real recordings before Epic 5's capture exists, and Story 4.10's live gate has a supported entry point.

**Acceptance Criteria:**

**Given** a readable audio file (WAV, or any format AVFoundation reads, such as m4a)
**When** I run `auricle __internal-import <audio-file> [--started-at <ISO 8601>] [--title <text>]`
**Then** the audio is converted to the Decision 1.4 format (PCM 16-bit, 16 kHz, mono WAV) and written to `~/Library/Caches/com.auricle.app/<meeting-id>/audio.wav` through `AtomicWriter` at mode 0600 per NFR-S3
**And** a `meetings` row is inserted through `StateStore` with `state='captured'`, `audio_cache_path`, `duration_seconds`, `capture_started_at` (`--started-at` if given, else the source file's creation date), `capture_ended_at` (start plus duration) and `title` (if given)
**And** one `stage_events` row is written through `StageEventLogger` with `stage='capture'`, `event='completed'` and `metadata_json` of `{imported: true, source_format, audio_duration_s}`
**And** stdout carries the new meeting id and nothing else, so `id=$(auricle __internal-import call.m4a)` works
**And** the source path is never logged at a public log level

**Given** an unreadable, empty or zero-length audio file, or a malformed `--started-at`
**When** the verb runs
**Then** it exits 1 with an actionable message, inserts no row, and leaves no cache directory behind (audio is finalized before the row is written)

**Given** the hidden-verb contract
**When** I run `auricle help` or generate shell completions
**Then** the verb is absent (`shouldDisplay: false`) and is exempt from the NFR-I7 binding contract, like `__internal-stage`
**And** promoting it to a public `import` verb is a separate PRD decision and is not part of this story

**Given** the AGENTS.md rule that logic lives in `Sources/`
**When** I inspect the implementation
**Then** conversion and registration live in `Sources/Capture/AudioImporter.swift`, and `App/auricle-cli/Verbs/ImportVerb.swift` is a thin wrapper

**Given** the test suite
**When** I run `Tests/CaptureTests/AudioImporterTests.swift`
**Then** tests cover: a 16 kHz mono WAV passes through; a 48 kHz stereo input is converted to 16 kHz mono; file mode 0600; row fields and the `capture` event; `--started-at` and file-date fallback; unreadable input leaves no row and no directory; two imports of one file produce two ids
**And** test audio is generated in the test, not checked in
```

Rationale: Epic 4's stated goal starts at "a meeting audio file on disk". This gives that sentence an implementation.

### 4.2 Story 4.2 — stage identifier (gap 3)

```
OLD (epics.md:1894-1896):
**Given** the stage execution
**When** diarization succeeds
**Then** a `stage_events` row is written with `stage='diarize'`, `event='completed'`, `metadata_json` containing `{model_id, segment_count, speaker_count, snippet_count}` per Decision 4.5

NEW:
**Given** the stage execution
**When** diarization succeeds
**Then** no separate `stage_events` row is written: `PipelineStage` has no `diarize` case, and the combined subprocess runs under the `transcribe` stage per Decision 1.1 and the architecture's "no separate diarize stage" rule
**And** the diarize step's `{model_id, segment_count, speaker_count, snippet_count}` is added to the same `stage='transcribe'`, `event='completed'` row's `metadata_json` under a `diarize` key (snake_case per the `stage_events` dialect)
**And** the composition root merges the two metadata blocks, because `Transcribe` and `Diarize` do not import each other
**And** `PipelineStage` stays at nine cases and `__internal-stage diarize` stays invalid
```

Story 4.1, last block, gains one line:

```
NEW (append to the "Given the stage execution" block, after the telemetry line):
**And** this row is the single `completed` row for the combined transcribe and diarize subprocess; Story 4.2 adds a `diarize` object to its `metadata_json`
```

Rationale: `architecture.md:547` already settles this. Only the story text disagrees.

### 4.3 Story 4.9 (was 4.8) — notification stub (gap 2, decision: stdout only)

Goal line:

```
OLD: I want the absolute minimum notification + Obsidian URL-open path so that Epic 4's CLI dogfood produces a complete user experience in terminal mode (notification fires; clicking opens the note in Obsidian),
NEW: I want the absolute minimum notification + Obsidian URL-open path so that Epic 4's CLI dogfood ends with the note path and its Obsidian URL printed to the terminal, and the `published → awaiting_verification` transition has an owner,
```

First AC block:

```
OLD (epics.md:2101-2105):
**Given** the `Notifications` target
**When** the persist stage completes (Epic 2 Story 2.4)
**Then** `Notifier.fire(meetingID:, title:, vaultPath:)` posts a `UNNotificationRequest` to `UNUserNotificationCenter` per FR42
**And** the notification body shows the meeting title (e.g., *"auricle: meeting ready — Tuesday sync with Ben"*)
**And** the notification's `userInfo` payload carries `{meeting_id, schema_version, payload_version}` per AR-FAIL-5

NEW:
**Given** the `Notifications` target
**When** I declare the `Notifier` protocol (`func fire(meetingID:, title:, vaultPath:) async`)
**Then** two conformers exist
**And** `UserNotificationNotifier` posts a `UNNotificationRequest` through an injectable notification center per FR42, with body *"auricle: meeting ready — <title>"* and a `userInfo` payload of `{meeting_id, schema_version, payload_version}` per AR-FAIL-5
**And** `StdoutNotifier` prints the vault note path and the `obsidian://open?vault=...&file=...` URL to stdout, one per line

**Given** one composition root per binary (`architecture.md`, DIP)
**When** the CLI and the GUI are wired
**Then** `auricle-cli` wires `StdoutNotifier` and `AuricleApp` wires `UserNotificationNotifier` (the notification delegate must live in the app process per Decision 1.1)
**And** Epic 4 posts no system notification from the CLI; whether a bundled `auricle-cli` can post one is not settled here and is left to the GUI dispatch in Epic 6

**Given** the notify stage runs after persist (in-process under `auricle run`, per Story 4.7)
**When** the notifier returns or fails (notify failure is non-blocking per NFR-R8)
**Then** the meeting transitions `published → awaiting_verification` in the same run
```

Third and fourth AC blocks (click handler, revoked permission) stay, scoped to `UserNotificationNotifier` and the GUI delegate.
The test block adds `StdoutNotifierTests` and a notify-stage transition test. The FR42 stub tag adds: "unit-tested only; not
exercised end-to-end until the GUI dispatches in Epic 6."

Rationale: nothing else owns `published → awaiting_verification`. `StdoutNotifier` keeps the pipeline shape identical
between CLI and GUI and avoids a system call the CLI may not be able to make.

### 4.4 Story 4.7 — worker coverage, notify in the run sequence, CLI path (gaps 2 and 7)

Append three AC blocks after the `--publish-anyway` block.

```
NEW:
**Given** every stage `auricle run` drives
**When** I run the worker-coverage test
**Then** `InternalStageWorker` has a case for each subprocess stage: `transcribe` (Stories 4.1 and 4.2), `review-diarization` (Story 4.3) and `summarize` (Story 3.7)
**And** `auricle run` runs `attribute`, `persist` and `notify` in-process per AR-PIPE-1
**And** the test enumerates the stages the verb drives, so a stage with neither a worker case nor an in-process path fails the build

**Given** persist has published the note
**When** the run continues
**Then** the verb runs the notify stage in-process with the CLI composition root's `Notifier` (Story 4.9), not as a subprocess, and the meeting reaches `awaiting_verification`

**Given** the CLI dispatches workers
**When** `RunVerb` builds its `SubprocessDispatcher`
**Then** it passes `resolveExecutablePath` returning the running `auricle-cli`'s own executable URL, because the default resolver is written for the GUI bundle and its behavior from an unbundled CLI is unverified
**And** a test asserts the CLI-built dispatcher's `makeProcess` executable exists and is the current binary
```

### 4.5 Story 4.6 — view-model location, speaker flags, ownership (gaps 5 and 6)

**(a) Location.** Retitle "AttributionViewModel in `Attribute/` + Attribution Batch CLI". Replace the `Core` target text:

```
OLD: I want `AttributionViewModel` to live in the `Core` target (NOT in the GUI target), and ...
NEW: I want `AttributionViewModel` to live in the `Attribute` target (NOT in the GUI target), and ...

OLD: **Given** the `Core` target (NOT `App/Auricle/MainWindow/`)
NEW: **Given** the `Attribute` target (NOT `App/Auricle/MainWindow/`), which both `auricle-cli` and `AuricleApp` link

OLD: **Then** the sheet imports `AttributionViewModel` from `Core` and uses it directly ...
NEW: **Then** the sheet imports `AttributionViewModel` from `Attribute` and uses it directly ...
```

Add one AC block:

```
NEW:
**Given** the view model decodes `DiarizationArtifact` and `DiarizationSuggestion`
**When** I inspect `Package.swift`
**Then** `Attribute` depends on `DiarizerInterface` and `AIReviewerInterface` (both depend on `Core`, which is why the view model cannot live in `Core`)
**And** calendar attendees and vault wikilink targets come from the `Core` types `CalendarArtifact` and `Glossary`
**And** the "previously labeled" names arrive through an injected protocol defined in `Attribute`, so the view model has no `State` or vault dependency of its own
**And** the story's Design Notes name the store behind "previously labeled" (FR23 item 3), which no artifact records today
```

The same `Core/` → `Attribute/` replacement applies at `epics.md:649`, `:668`, `:723`, `:2182`, `:2927`, `:2934` and `:3346`,
and at `architecture.md:1756` and `:2501` (the `AttributionViewModel.swift` tree entry moves to `Sources/Attribute/`).

**(b) Speaker flags.** Append to the batch CLI block:

```
NEW:
**And** `--speakers` ships here as the batch path. FR27 stays [v1.1] as the documented fallback surface, which adds `--emit-snippets` (Story 10.4). A pre-1.0 addition is not an NFR-I7 contract break
**And** `auricle attribute <id> --batch` with no `--speakers` applies the meeting's existing `attribution.json` speakers map if one exists; otherwise it exits 1 with "no speaker mapping; run with --interactive or pass --speakers" per Decision 1.5
**And** until Epic 7 ships the sheet, `auricle attribute <id>` with no flags behaves as `--batch`
```

**(c) Cross-reference slip.**

```
OLD (epics.md:2022): ... consumed identically by Story 4.7's CLI batch attribution AND Epic 7's `AttributionSheet` GUI ...
NEW: ... consumed identically by Story 4.6's CLI batch attribution AND Epic 7's `AttributionSheet` GUI ...
```

**(d) Ownership of overrides and splits.** Append to Story 4.6:

```
NEW:
**And** applying `segment_overrides` and `segment_splits` to the transcript the summarize stage reads is out of scope here: both arrays are empty on every Epic 4 path. Story 7.11 owns it
```

Append to Story 7.11:

```
NEW:
**Given** non-empty `segment_overrides` or `segment_splits` in `attribution.json`
**When** the summarize stage runs
**Then** it reads the Decision 5.4 `RenderedTranscript`, not the raw speaker labels in `transcript.json`
**And** `diarization.json` segment ids map to utterance indices through `DiarizationArtifact` (Story 4.2)
```

Story 10.4:

```
OLD (epics.md:3845 region, Story 10.4 goal): I want `auricle attribute <id> --emit-snippets` + `auricle attribute <id> --speakers "1=Ben,2=Sara,..."` per FR27 ...
NEW: I want `auricle attribute <id> --emit-snippets`, and the documented FR27 surface for `--speakers "1=Ben,2=Sara,..."`, which already ships from Epic 4 Story 4.6 ...

And the `--speakers` Given block: "parses the mapping ... per Epic 4 Story 4.6" becomes "behaves as Story 4.6 built it; this story adds the mutual-exclusion test with `--emit-snippets`".
```

### 4.6 Story 4.4 and Story 4.5 — match the shipped code (small items)

Story 4.4:

```
OLD (epics.md:1952): `JargonCorrectionStrategy` has `Input = (SummaryDraft, Glossary)`, `Output = JargonCorrection` (with `charRange`, `originalSpan`, `correctedSpan`); MVP impl wraps the existing `GlossaryInjector` from Story 3.12 per Decision 5.1
NEW: `JargonCorrectionStrategy` already ships from Story 3.12 in `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` as `correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection]`. This story keeps that signature and makes `JargonCorrection` conform to `Suggestion` (it already carries `suggestionId` and `reasoning`). It does not force the glossary path through `AIReviewerStrategy.review(input:config:)`, because that shape serves reviewers that call a model and FR73 does not require it

OLD (epics.md:1954-1957): the "Given Story 3.12's JargonCorrectionStrategy (already implemented)" block: "`Sources/Summarize/GlossaryInjector.swift` (or wherever Story 3.12 placed it) is wrapped/conformed ... adapter, not rewrite"
NEW: **Given** `GlossaryJargonCorrector` (`Sources/Summarize/GlossaryJargonCorrector.swift`) **When** Story 4.4 lands **Then** it is unchanged and its behavior (FR55–FR57) is unchanged
```

Story 4.5 — append to the first AC block:

```
NEW:
**And** this story adds the `ClaudeSummarizer` dependency to the `ClaudeAIReviewers` target in `Package.swift`, which the architecture's dependency graph already lists (the shared `AnthropicHTTPClient` and `KeychainAPIKey` live in `ClaudeSummarizer`)
```

### 4.7 Story 4.10 (was 4.9) — exit gate rewrite (gap 4)

Retitle "Exit-Criteria Gate (CI Pipeline Test + Live Run)". Replace the fixture, CI and fixture-source blocks; keep the per-fixture
assertions, the ≥80% target, the cost ceilings and the summary-line format.

```
NEW (replaces the fixture-set block and the CI block, epics.md:2137-2166):

**Given** Part A, the CI pipeline test
**When** I run `swift test`
**Then** `Tests/IntegrationTests/PipelineEndToEndTests.swift` runs the stages through the library entry points (not the binary) with a stub `TranscriberStrategy`, a stub `DiarizerStrategy`, stubbed Anthropic responses, a temp vault and a temp state database
**And** the story adds an `IntegrationTests` test target to `Package.swift` that passes `--explicit-target-dependency-import-check error`
**And** it uses one small checked-in reference WAV (NFR-M5, at most 1 MB, synthetic or public-domain) so the audio path is exercised
**And** for each fixture it asserts: `auricle __internal-import` semantics via `AudioImporter`; state reaches `awaiting_verification`; a vault note exists at the `FilenameResolver` path with schema-valid frontmatter; every action item and decision is followed by a `> source quote` that survives literal substring match; `verified_at` is NULL
**And** it runs on every PR through the existing `swift` job, with no path filter
**And** it does not run WhisperKit (model download, no ANE on hosted runners); WhisperKit correctness belongs to Stories 4.1 and 4.2

**Given** Part B, the live gate
**When** the maintainer runs `Tests/scripts/run-epic4-exit-criteria.sh` against `$AURICLE_EXIT_FIXTURES`
**Then** the directory holds at least 5 recordings (at least one 1:1, at least two with 4 or more attendees) plus each recording's expected speaker mapping and expected item list
**And** for each recording the script runs `auricle __internal-import`, then `auricle run <id> --publish-anyway` (or `--speakers` per the mapping), and asserts exit 0, a note with valid frontmatter, grounded quotes, and `meetings.verified_at` NULL read with `sqlite3` (`auricle status <id>` is a stub until Story 9.6)
**And** across the set at least 80% of expected action items and decisions survive grounding, or the script fails with "Epic 4 exit criteria not met: <metric> = <value>"
**And** per-meeting cost is at most $0.50 with `diarization_review.enabled = false` and at most $0.60 with it `true`, per NFR-C1 read as per meeting
**And** it uses real WhisperKit and live Anthropic calls

**Given** the recordings are private and the repository is public
**When** results are recorded
**Then** recordings are never checked in and the fixture path comes from the environment variable
**And** `Tests/fixtures/epic4-exit-results.md` records aggregates only: pass rate, total cost, per-fixture counts under opaque labels (`fixture-1` …), no transcript text and no titles
**And** the AMI meeting audio (CC BY 4.0) behind the Epic 3 fixtures is an allowed public source for repeatable runs
**And** changing the fixture set needs a rationale in the PR description

**Given** Story 4.10 passes
**When** the maintainer reads the output
**Then** each per-fixture line reads: *"fixture-N: vault note written · grounding_method=substring · kept N items (M expected) · drop count K · cost $X"*
**And** the last line reads: *"Epic 4 exit criteria met: pass rate Y%, total cost $Z over <N> fixtures"*
**And** Epic 4 exits when `epic4-exit-results.md` records that line and Part A is green
```

Rationale: stubbed responses cannot measure a real grounding rate or cost. Only the live run can. The CI part guards the plumbing
on every PR.

### 4.8 Epic 4 text, cross-references, `architecture.md`

`epics.md`:

- Epic 4 intro (`:1817`) and Epic List entry (`:648`): "has a meeting audio file on disk → registers it with the hidden
  `auricle __internal-import <audio-file>` (Story 4.8), which prints a meeting id → runs `auricle run <id> --publish-anyway`…".
- Exit criteria (`:651-659`): "Story `4.9`" → "Story `4.10`"; drop "the same fixture set used in Epic 3's smoke-test"; the
  last bullet becomes "Part A runs in CI on every PR; Part B runs on the maintainer's recordings, path-referenced by
  environment variable"; the `auricle status <id>` bullet becomes a `verified_at` state-store read.
- Story list (`:664-672`): insert `4.8` builder-mode audio import; `4.9` notification stub; `4.10` exit gate. "Amelia's
  9-story breakdown" → "10-story"; "4.8 cannot land before 4.1–4.7" → "4.9 cannot land before 4.1–4.8".
- Summary (`:2175-2183`): "9 stories" → "10 stories"; sequence `4.1 → … → 4.10`; FR27 note: "FR27 mechanism (`--speakers`)
  lands early in Story 4.6; FR27 stays [v1.1] as the documented surface".
- Cross-references: `:1996` (4.5) "Story 4.9's" → "Story 4.10's"; body of the notification story "Story 4.9" → "Story 4.10";
  `:3557` (Epic 8) and the Epic 2 summary's re-publish notification line (added by the Epic 2 reassignment) "Story 4.8" → "Story 4.9".

`architecture.md`:

1. `:464`, bullet on deferred verbs: remove `--speakers` from "`attribute --emit-snippets/--speakers`" and add "the
   `attribute --speakers` batch path ships pre-1.0 in Epic 4 Story 4.6".
2. `:372`, Decision 1.1, after the CLI bullet: "In Epic 4, `auricle run` runs `attribute`, `persist` and the notify stage
   in-process (AR-PIPE-1), with the CLI composition root's `Notifier`. Only the GUI composition root posts
   `UNUserNotificationCenter` notifications."
3. `:495`, after the "Individual-stage verbs" paragraph: "Hidden builder-mode verbs (`__internal-stage`, `__internal-import`)
   are outside the 10-verb binding contract."
4. `:2595`, dependency graph: `Attribute` gains `DiarizerInterface`. The `ClaudeAIReviewers → ClaudeSummarizer` edge is
   already listed (`:2603`).
5. `:1756` and `:2501`: `AttributionViewModel.swift` moves from the GUI tree to `Sources/Attribute/`.
6. `:464`: the deferred-verb list drops `--speakers`.

### 4.9 `sprint-status.yaml`

After the `epics.md` edits, rerun `bmad-sprint-planning`. All affected keys are `backlog`, so nothing is transplanted:

```
NEW:  4-8-builder-mode-audio-import-auricle-internal-import: backlog
RENAMED (backlog):  4-8-basic-notification-stub-obsidian-url-open → 4-9-…
RENAMED (backlog):  4-9-exit-criteria-smoke-test → 4-10-exit-criteria-gate-ci-pipeline-test-live-run
```

---

## 5. Implementation Handoff

### Scope classification: Moderate

One story added and two renumbered. No PRD change and no architecture decision reversed. Backlog reorganization is
needed, but every affected story is `backlog`.

### Handoff

| Recipient | Responsibility |
|---|---|
| **This workflow** | Applies 4.1–4.8 to `epics.md` and `architecture.md` after approval, then reruns `bmad-sprint-planning` for 4.9 |
| **Developer (Story 4.1)** | No blocking change. Starts now |
| **Developer (Stories 4.2, 4.6–4.10)** | Builds from the amended text |
| **Maintainer** | Approves the proposal. Later decides whether `__internal-import` becomes a public `import` verb (an Epic 10 candidate) and whether a bundled `auricle-cli` may post notifications (Epic 6) |

### Success criteria

1. `epics.md` no longer describes a CLI-posted notification, a `diarize` stage row, a `Core`-resident view model, or
   "the user's real meetings" as the Epic 3 fixture set.
2. Story numbers 4.1–4.10 are consistent across `epics.md`, and `sprint-status.yaml` carries the same ten keys.
3. FR text, AR tags and all Epic 1–3 text are unchanged, except the Story 4.6 and 7.11 references named above.
4. A developer reading Stories 4.7–4.10 can answer without inventing: how a recording enters the pipeline, which process
   runs persist and notify, what CI proves, and what the live gate proves.

### Open items left for later (not blocking)

- Store behind FR23 "previously labeled speakers": decided in Story 4.6's Design Notes.
- Public `import` verb: PRD decision, Epic 10 queue.
- CLI-posted notifications: settled with the GUI dispatch in Epic 6.
