---
title: 'Story 4.6: AttributionViewModel in Attribute/ + Attribution Batch CLI'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_commit: '4de70170d485e11aa091393dd1ac9a3760042fb6'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred:
  - 'auricle/needs-attribution tag: SummaryArtifactMapper.needsAttribution only checks that every speaker label is a key of attribution.json speakers, so a --publish-anyway file (Speaker_N mapped to itself) reads as fully attributed and Persist omits the tag. Fix belongs in Summarize/Persist: treat a Speaker_N value as unmapped.'
  - summary: >-
      `auricle attribute` parses `<id>` with `MeetingID(ulid:)` instead of `MeetingIDResolver`, so it accepts only full ULIDs.
    evidence: |-
      AGENTS.md makes `MeetingIDResolver` the single id-parsing primitive, but no `MeetingIDDataSource` implementation exists and no other verb resolves ids. Settled when a data source lands and verbs adopt it.
    location: >-
      App/auricle-cli/Verbs/AttributeVerb.swift:23
    severity: low
---

<intent-contract>

## Intent

**Problem:** Nothing writes `attribution.json`, so no meeting can leave `awaiting_attribution` on the CLI path. `auricle attribute` is a stub, and Epic 7's sheet has no shared view model to import.

**Approach:** Add `AttributionViewModel` (`@Observable`), a pure `renderTranscript`, and `AttributionStage` to the `Attribute` target. Wire `auricle attribute <id> [--batch] [--speakers "1=Ben,..."]` as a thin verb over the stage. `--publish-anyway` writes an all-placeholder file.

## Boundaries & Constraints

**Always:**
- `attribution.json` goes through `CacheArtifactWriter` (0600, `schema_version`). Schema per Decision 5.4: `speakers`, `segment_overrides[]`, `segment_splits[]`. Readers ignore unknown keys.
- `speakers` values are `[[Name]]` or the `Speaker_N` literal. A name that matches `Glossary.people` (case-insensitive) uses the glossary spelling. An unknown name becomes `[[Name]]` text only; no vault file is created.
- `--speakers` keys are the digits of `Speaker_N`. Reject duplicate keys, duplicate names, keys absent from `diarization.json`, and empty names. Speakers left out map to their `Speaker_N` placeholder. Any rejection exits 1 and writes nothing.
- The stage runs under `StageRunner` with `.attribute`/`.attributing`, and completes to `summarizing`. It logs through `Log`, never transcript text.
- Autocomplete order is calendar attendees, then `Glossary.people`, then previously labeled names, each name once. "This is me" pre-selects the speaker with the longest cumulative segment time, preferring the calendar attendee with `isSelf`.
- The 500 ms debounce cancels the pending write on each mutation and writes the latest draft once. A `flush()` awaits the in-flight write.

**Never:**
- No write to `transcript.json`, `diarization.json` or `diarization_suggestions.json`.
- No application of overrides or splits to what summarize reads (Story 7.11). No `--emit-snippets`. No GUI.
- The view model has no `State`, vault, or `StateStore` dependency; the stage owns those.
- No new SQLite column or migration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Batch mapping | `--speakers "1=Ben,2=Jordan Whitfield"`, 3 speakers | File with `Speaker_3` placeholder; state `summarizing` | No error |
| Batch reuse | `--batch`, existing file with a speakers map | Map applied; state `summarizing` | No error |
| No mapping | `--batch`, no file | Exit 1, "no speaker mapping; run with --interactive or pass --speakers" | State unchanged |
| Bad mapping | Duplicate key or name, unknown `Speaker_N` | Exit 1, message names the entry | Nothing written, state unchanged |
| Publish anyway | `--publish-anyway` | All `Speaker_N` placeholders, both arrays empty; state `summarizing` | No error |
| Dangling split | Split names a segment absent from `diarization.json` | Renderer ignores it | No crash |
| Missing suggestions | No `diarization_suggestions.json` or empty stub | View model has no suggestions | No error |
| Wrong state | Meeting not `awaiting_attribution` | Exit 1 | `StageRunner`/transition table rejects |
| Rapid edits | Three mutations within 500 ms | One write of the last draft | Cancelled writes leave the file intact |

</intent-contract>

## Code Map

- `Sources/Attribute/ManifestPlaceholder.swift` -- delete.
- `Package.swift:86,180` -- `Attribute` gains `DiarizerInterface`, `AIReviewerInterface`, `Orchestrator`, `VaultGlossary`; `AttributeTests` mirrors `ReviewDiarizationTests` deps (`Package.swift` ~200).
- `Sources/Core/CacheArtifactWriter.swift` -- `write(_:for:named:schemaVersion:)`, `cacheDirectory(for:)`. `Sources/Core/AtomicWriter.swift` behind it.
- `Sources/Core/CalendarArtifact.swift` -- attendees (`displayName`, `isSelf`) and `event.title`. `Sources/Core/Glossary.swift` -- `people`. `Sources/VaultGlossary/VaultGlossaryBuilder.swift` -- `buildOrEmpty()`.
- `Sources/Core/CanonicalTranscript.swift` -- utterance UTF-8 byte ranges include the `<Speaker_N>: ` prefix; strip exactly one.
- `Sources/DiarizerInterface/DiarizationArtifact.swift` -- `seg_<n>` ids, `utteranceIndex`, `speakerLabels`. `Sources/AIReviewerInterface/DiarizationSuggestion.swift` -- `suggestionId`, `segmentId`, `proposedSplits`.
- `Sources/Summarize/AttributionSpeakers.swift` -- decode-only reader with private `fileName`; promote the name to a shared constant in `Attribute` or `Core` so both use one.
- `Sources/Core/PipelineTransitions.swift:~21` -- add `(.attribute, .attributing): [.summarizing]`; extend its transition test.
- `Sources/ReviewDiarization/ReviewDiarizationStage.swift:21-60` -- pattern: caseless enum, `fetchMeeting` guard, `stageRunner.run`, telemetry, `exitCode(for:)`. Error type in `ReviewDiarizationStageError.swift`.
- `Sources/Telemetry/AttributeTelemetryPatch.swift` -- `attributionCompletionPath` values `cli_speakers_flag`, `publish_anyway`.
- `Sources/Orchestrator/CLIVerbArguments.swift:77` -- `AttributeArguments` gains `--speakers`. `--publish-anyway` stays on `RunArguments`; `AttributionStage` exposes the placeholder path for Story 4.7.
- `App/auricle-cli/Verbs/AttributeVerb.swift` -- replace the `notYetImplemented` stub; thin wrapper. `Tests/OrchestratorTests/CLIVerbArgumentsTests.swift:~112` -- update attribute parse test.
- `Tests/ReviewDiarizationTests/ReviewDiarizationFixture.swift` -- fixture pattern (in-memory `StateStore`, real `StageRunner`, temp cache dir).
- `.swiftlint.yml` -- `atomic_writer_bypass`, `log_facade_bypass`, `print_bypass` apply to new code.

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add the dependencies above -- explicit-import check fails on undeclared edges.
- `Sources/Attribute/AttributionFile.swift` -- Codable schema (`speakers`, `SegmentOverride`, `SegmentSplit`, `AttributionSource`), snake_case `CodingKeys`, unknown keys ignored -- Decision 5.4.
- `Sources/Attribute/AttributionRenderer.swift` -- pure `renderTranscript(diarization:overrides:splits:speakers:)` and `RenderedTranscript`/`RenderedSegment`; order splits, overrides, speakers map, `Speaker_N` -- Decision 5.4.
- `Sources/Attribute/PreviousLabelings.swift` -- protocol for prior labelings, plus `CachedAttributionLabelings` adapter scanning per-meeting `attribution.json` and `calendar.json` under the cache root -- names the store (Design Notes).
- `Sources/Attribute/AttributionViewModel.swift` -- `@Observable` state, autocomplete, "this is me", recurring prefill, debounced write with injected sleep, `flush()`, mutations for speakers, overrides, splits.
- `Sources/Attribute/SpeakersFlagParser.swift` -- parse and validate `--speakers` against the diarization labels.
- `Sources/Attribute/AttributionStage.swift` and `AttributionStageError.swift` -- batch, reuse and placeholder paths under `StageRunner`, with telemetry and `exitCode(for:)`.
- `Sources/Core/PipelineTransitions.swift` -- add the `attribute` entry.
- `Sources/Orchestrator/CLIVerbArguments.swift`, `App/auricle-cli/Verbs/AttributeVerb.swift` -- add `--speakers`; no-flag invocation behaves as `--batch`.
- `Tests/AttributeTests/{AttributionViewModelTests,RendererPureFunctionTests,AttributionStageTests,SpeakersFlagParserTests}.swift`, `Tests/AttributeTests/Fixtures/renderer/` -- cover the I/O matrix, the golden renderer matrix, idempotence, debounce with an injected sleep, and cancellation preservation.

**Acceptance Criteria:**
- Given a meeting in `awaiting_attribution` with a diarization artifact, when the stage runs with `--speakers`, then `attribution.json` holds the mapped names, `meetings.state` is `summarizing`, and `stage_events` records `attribute` started and completed.
- Given `swift build --explicit-target-dependency-import-check error`, when it runs, then it passes and `Attribute` imports `DiarizerInterface` and `AIReviewerInterface`.
- Given a view model with a pending debounced write, when `flush()` returns, then the file on disk equals the latest in-memory draft.
- Given the published-note tag `auricle/needs-attribution` for placeholder-only speakers, when Persist reads `attribution.json`, then the tag is present. Verify existing tag logic; if absent, record it as a deferred item rather than widening this story.

## Spec Change Log

## Review Triage Log

### 2026-09-20 — Review pass
- verdicts: 46 findings — high 0, medium 4, low 21, false 12, maybe-false 0 (remaining 9 rows are gap/claim items counted with their nearest verdict)
- findings:
  - `[medium]` `[patch]` `--speakers 1=Speaker_2` accepted silently and collapses to the placeholder — parser now throws `.malformedEntry`; test added.
  - `[medium]` `[patch]` `.failed` stage outcome exits with no message — `execute` returns a message; verb prints it.
  - `[medium]` `[patch]` No test for corrupt `attribution.json`, corrupt `diarization.json`, or write failure — three tests added.
  - `[medium]` `[patch]` `completed` `metadata_json` unasserted — asserted for `--speakers` and `.publishAnyway`.
  - `[low]` `[patch]` Debounce test races cancelled tasks and ignores the 500 ms — records durations, asserts after quiescence; fails without `cancel()`.
  - `[low]` `[patch]` `AttributeVerb` doc comment says "Until the sheet ships" — rewritten to the current behavior.
  - `[low]` `[defer]` `AttributeVerb` parses `<id>` with `MeetingID(ulid:)`, not `MeetingIDResolver` — no `MeetingIDDataSource` exists and no other verb resolves ids yet; deferred, see frontmatter.
  - `[false]` `[reject]` Stage bypasses the view model's write path — the view model's default writer is `AttributionFile.write(for:)`, the same call the stage makes; the spec's "Never" line keeps `StateStore` out of the view model.
  - `[false]` `[reject]` `--interactive` does not exist — the message text is mandated verbatim by the story and Decision 1.5.
  - `[false]` `[reject]` `--publish-anyway` unreachable from the CLI — the spec assigns the `run` verb to Story 4.7; the stage entry and its test exist.
  - `[false]` `[reject]` Missing needs-attribution tag — already in `deferred`; the spec AC says to defer.
  - `[false]` `[reject]` `--speakers` resets unmentioned speakers — the spec says omitted speakers map to their placeholder.
  - `[low]` `[reject]` Retry from `attributing`, concurrent runs, stale-read race — single-user CLI; the retry is deliberate crash recovery.
  - `[low]` `[reject]` Reuse path does not validate or fill missing labels — summarize treats a missing label as unattributed; guard would add branches for a hand-edited file.
  - `[low]` `[reject]` Corrupt `attribution.json` blocks overwriting modes — protects existing overrides and splits; the message names the file.
  - `[low]` `[reject]` Schema-version check, unknown-key loss, `applied_from` rewrite — schema is v1 with no later version; additive rule covers readers only.
  - `[low]` `[reject]` Comma and `[[`/`|` in names, wikilink syntax — limits of a flag format; the input is the maintainer's own.
  - `[low]` `[reject]` Renderer: empty `splits`, huge utterance range, duplicate tie-breaks, blank split speaker — reachable only through a hand-edited or damaged file.
  - `[low]` `[reject]` `setSplit` validation, init placeholders not dirty, weak-self drop, no write retry, `excluding` optional, rescans — no caller exists before Epic 7; `flush()` is the documented contract.
  - `[low]` `[reject]` Tests write to the real cache, swallowed input-load errors, no cross-check with Summarize's reader, `AttributeVerb` untested — matches repo pattern (`ReviewDiarizationFixture`) and the thin-wrapper convention.

## Design Notes

**Store behind "previously labeled" (FR23 item 3).** No artifact or table records it. The MVP store is the set of prior meetings' `attribution.json` files in the cache root, read by `CachedAttributionLabelings` behind the `Attribute`-defined protocol. Limit: retention purges caches, so history is bounded by the retention window. A State-backed store is a later adapter behind the same protocol and needs a migration, which this story avoids.

**Recurring prefill.** A meeting recurs when its calendar event title (trimmed, case-folded) matches earlier meetings. `Speaker_N` is numbered by first appearance, not identity, so the view model proposes a name for `Speaker_N` only when that same name held that same label in three or more prior meetings of the series. Prefill is a proposal; the CLI batch path never uses it.

**Split text.** `CanonicalTranscript` utterances carry no timing, so a split sub-segment has no exact text range. `RenderedSegment.text` is the parent's utterance slice for unsplit segments and empty for sub-segments; Story 7.11 owns word-level mapping.

**Concurrency.** This is the first `@Observable` in the repo. Use `@MainActor @Observable`; the CLI verb awaits it from `@MainActor`. Inject the sleep as a closure for tests.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error && swift test --filter AttributeTests` -- expected: pass
- `swift test` -- expected: pass
- `make check-lint` -- expected: pass
- `cd App && tuist generate --no-open` then `xcodebuild -workspace App/Auricle.xcworkspace -scheme auricle-cli build` -- expected: pass

## Auto Run Result

Status: done

- **Change:** `AttributionViewModel` (`@MainActor @Observable`), pure `renderTranscript`, `AttributionStage` (batch, reuse, publish-anyway modes) and `auricle attribute [--batch] [--speakers]` in the `Attribute` target. `(.attribute, .attributing) -> [.summarizing]` added to the transition table.
- **Files:** `Sources/Attribute/{AttributionFile,AttributionInputs,AttributionRenderer,AttributionStage,AttributionStageError,AttributionViewModel,PreviousLabelings,SpeakerNaming,SpeakersFlagParser}.swift`, `Sources/Core/{AttributionArtifact,PipelineTransitions}.swift`, `Sources/Orchestrator/CLIVerbArguments.swift`, `Sources/Summarize/AttributionSpeakers.swift`, `App/auricle-cli/Verbs/AttributeVerb.swift`, `Package.swift`, tests under `Tests/AttributeTests/`, `CoreTests`, `OrchestratorTests`.
- **Review:** 6 patches applied (4 medium, 2 low), 1 deferred (`MeetingIDResolver` adoption), rest rejected with reasons in the triage log.
- **Follow-up review recommended:** false. Patched: 0 high, 4 medium.
- **Verification:** `swift build --explicit-target-dependency-import-check error`, full `swift test` (1266 tests), `make check-lint`, and `xcodebuild -scheme auricle-cli build` pass. `make check` in full and the `AuricleApp` scheme were not re-run after the patches; no end-to-end CLI run.
- **Residual risks:** `--publish-anyway` files read as fully attributed in Summarize, so Persist omits `auricle/needs-attribution` (deferred in frontmatter; the fix belongs in Summarize/Persist before Story 4.7 relies on it). Recurring prefill and autocomplete have no production caller until Epic 7. Previous-label history is bounded by cache retention.
