---
title: 'Story 3.12: VaultGlossaryBuilder + GlossaryInjector + JargonCorrectionStrategy'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: '78b0cf21bc22ed169670da1f13ac94c939ae5a1d'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      Pass `--vault-path` (and the meetings subdirectory) to the summarize worker from GUI dispatch once a config layer supplies `vault_path`.
    evidence: |-
      `SubprocessDispatcher.makeProcess` builds `__internal-stage <stage> <id> --worker-protocol-version N` only, and no other caller supplies a vault path, so a dispatched summarize run gets an empty glossary and `glossary.json` holds no terms. The `--vault-path` option on `InternalStageWorker` works when passed by hand. `Core/Config` does not exist yet; the empty glossary predates this story. The wedge measurement reports 0 eligible corrections until dispatch passes the path.
    location: >-
      Sources/Orchestrator/SubprocessDispatcher.swift:38
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The summarize stage always injects an empty glossary (`InternalStageWorker.swift`), so vault jargon is never corrected and the AI-correction wedge ("≥40% of meetings show ≥1 applied jargon correction over 30 days") cannot be measured. `VaultGlossary` is an empty target, there is no scoping, and no `JargonCorrectionStrategy` slot exists.

**Approach:** Build the vault glossary from wikilink targets (cached, mtime-invalidated), scope it per meeting with a fuzzy transcript match inside the summarize stage, log the scoped glossary to `glossary.json`, declare `JargonCorrectionStrategy` with an MVP impl that derives corrections post-hoc from artifacts, and add a metrics-only wedge measurement.

## Boundaries & Constraints

**Always:**
- Glossary terms are the union of markdown page names (file basename, recursive) and `[[target]]` link targets found in file contents (`[[t|alias]]`, `[[t#h]]`, `[[t^b]]` reduce to `t`). Ghost links matter: the maintainer links to notes that do not exist.
- Category comes from the page's ancestor folder named `People`, `Projects` or `Concepts` (case-insensitive). Every other term, including every ghost link, goes to `Glossary.uncategorized`. Terms are deduplicated case-insensitively, sorted, and stored without brackets.
- Skip hidden entries (`.obsidian`, `.trash`, `.git`), the meetings subdirectory (default `Meetings`; auricle's own notes must not feed back), and date-named pages (`YYYY-MM-DD…`). Never follow symlinked directories.
- Cache: `<cache root>/glossary-cache.json` (`Core` gains `CacheArtifactWriter.cacheRoot()`, reused by `cacheDirectory(for:)`). Written with `AtomicWriter`, mode 0600, snake_case, `schema_version`. It stores the vault path and a fingerprint: the newest modification date and the entry count over every non-skipped file and directory. A different vault path, fingerprint, schema version, or an undecodable cache means rebuild. A cache write failure is swallowed; the built glossary is still returned.
- Fuzzy match works on squashed forms (lowercase, diacritics folded, non-alphanumerics dropped), so `mesh core` equals `meshcore`. Windows of 1…4 consecutive transcript words are compared with the term. Allowed edits: 0 below 4 characters, 1 for 4–7, 2 for 8 or more. A person term also matches on any single name part of 3 or more characters. Phonetic matching is not attempted.
- `GlossaryInjector.scope` keeps a person term that fuzzy-matches an attendee name or a transcript word, and any other term that fuzzy-matches the transcript. It keeps at most 40 terms (strongest match first, then alphabetical), so a rendered glossary stays near 200 tokens. Output is deterministic.
- The stage scopes with attendees from `attribution.json` speaker values (brackets stripped), scopes before the summarizer call, and passes the scoped glossary to the orchestrator. It writes the scoped glossary to `glossary.json` through `CacheArtifactWriter` before that call. A failed `glossary.json` write never fails the stage.
- `SummarizeStage.run`'s `glossary` parameter now means the full, unscoped vault glossary.
- Glossary building never blocks a note: no vault path, a missing vault, or an unreadable vault yields an empty glossary. The worker prints one stderr line with the error type only, never a path.
- `JargonCorrectionStrategy.correct(summary:glossary:)` lives in `AIReviewerInterface`. `JargonCorrection` carries `suggestionId` (deterministic, unique per result), `reasoning`, `charRange` (UTF-8 byte offsets into the summary text), `originalSpan`, `correctedSpan`, explicit snake_case `CodingKeys`, so Story 4.4 can conform it to `Suggestion` with no change. `SummaryDraft` carries the summary text and the source transcript text.
- The MVP impl, `GlossaryJargonCorrector` in `Summarize`, makes no API call. A glossary term is corrected when it appears in the summary (whole-term, case-insensitive), is not present in the transcript as a case-insensitive whole term, and fuzzy-matches transcript text. `originalSpan` is that transcript text. A case-only difference is not a correction.
- `JargonWedgeMeasurement` reads `summary.json`, `transcript.json`, `glossary.json` per cache directory, counts meetings whose summary, action items or decisions text yields at least one correction, and reports eligible meetings, meetings with a correction, missing-artifact meetings, the rate, and whether it meets 0.4. A meeting is in the 30-day window when its `summary.json` modification date is inside it. The report and the verb output hold counts only, never meeting text.
- All logic lands in `Sources/`. `App/` stays a thin wrapper (no test coverage there).

**Never:**
- No new telemetry column, no `jargon_suggestions.json`, no extra API call, no `Core/Config` layer, no `auricle stats` verb.
- Do not read attendees from a calendar, thread attendees into the prompt, or change the strategies, validators, mapper or renderer.
- Do not change `SubprocessDispatcher`'s argument vector; GUI dispatch does not pass a vault path until config exists.
- No public CLI verb; the measurement verb is hidden, like `__compare-strategies`.
- Do not take `MeetingForFrontmatter` in the injector's API: it is Persist's rendering input, unavailable before summarization.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Standard vault | `People/Ben Smith.md`, `Projects/chicken-palace.md`, `Concepts/packet radio.md` | Terms land in `people`, `projects`, `concepts` | No error |
| Ghost link | Note text `[[meshcore]]`, no `meshcore.md` | `meshcore` in `uncategorized` | No error |
| Non-standard vault | No `People`/`Projects`/`Concepts` folders | Every term in `uncategorized` | No error |
| Fresh cache | Second `build()`, vault unchanged | Same glossary, no rescan (`rebuilt == false`) | No error |
| Stale cache | Any file or directory mtime newer | Rescan, cache rewritten (`rebuilt == true`) | Corrupt or old-schema cache also rescans |
| 10K-file vault | 10,000 markdown files | Builds within a generous bound (10 s) | No error |
| Missing vault | `vaultPath` not a directory | `build()` throws `vaultPathMissing`; `buildOrEmpty` returns empty | Worker: one stderr line, run continues |
| Mangled term | Glossary `meshcore`; transcript "mesh core" | Term survives scoping | No error |
| Unrelated term | Glossary `zebra`; transcript never says it | Term dropped | No error |
| Huge vault | 2,000 terms, matching transcript | At most 40 kept; rendered glossary ≤ ~200 tokens vs ≥ 5,000 unscoped | No error |
| Attendee only | Attendee `Priya`, glossary person `Priya Patel`, transcript silent | Person kept | No error |
| Stage run | Orchestrator strategy records its glossary | Strategy receives the scoped glossary; `glossary.json` holds it | `glossary.json` write failure is ignored |
| Correction found | Summary `[[meshcore]]`, transcript "mesh core" | One correction: original `mesh core`, corrected `meshcore`, `charRange` inside summary | No error |
| No correction | Exact term in transcript, or term in neither | Empty array | No error |
| Wedge rate | 5 eligible meetings, 2 with a correction | rate 0.4, `meetsCriterion` true; a meeting missing an artifact counts under missing | Unreadable artifact counts as missing; zero eligible gives nil rate |

</intent-contract>

## Code Map

- `Sources/Core/Glossary.swift` -- existing `Glossary {people, projects, concepts, uncategorized}`; already snake_case-safe and rendered by the prompt builder. Reuse, no change.
- `Sources/Core/CacheArtifactWriter.swift:56-72` -- `cacheDirectory(for:)` holds the `~/Library/Caches/com.auricle.app` construction; extract `cacheRoot()` from it. `AtomicWriter.swift` is the write primitive; `.swiftlint.yml` `atomic_writer_bypass` bans `.write(to:` elsewhere.
- `Sources/VaultGlossary/ManifestPlaceholder.swift` -- delete when real files land. Target deps are `Core` only (`Package.swift`); keep it that way.
- `Sources/Summarize/SummarizationPromptBuilder.swift:172-209` -- `renderGlossary` already emits `[[wikilink]]` lines, including `Uncategorized`; the token-bound test can measure `build(...).glossary.text`.
- `Sources/Summarize/SummarizeStage.swift:71-160` -- `summarize(...)` reads the transcript and `AttributionSpeakers`, then calls `orchestrator.summarize(transcript:glossary:config:)` with the injected glossary. Scope and write `glossary.json` between `resolvePromptSetHashes` and that call.
- `Sources/Summarize/AttributionSpeakers.swift` -- `read(in:)` returns `[String: String]?` (`Speaker_N` to `[[Name]]`); source of attendee names.
- `Sources/Core/SummaryArtifact.swift` -- `summary.json` contract (`summary`, `action_items[].text`, `decisions[].text`); the measurement decodes it.
- `App/auricle-cli/Verbs/InternalStageWorker.swift:63-88` -- passes `Glossary()` with a comment naming this story; add optional `--vault-path`, expand `~`, call `VaultGlossaryBuilder.buildOrEmpty`. `AuricleCLI.swift` registers verbs.
- `App/auricle-cli/Verbs/StrategyComparisonVerb.swift` -- pattern for the hidden measurement verb (`shouldDisplay: false`, thin, logic in `Sources/`).
- `Sources/AIReviewerInterface/ManifestPlaceholder.swift` -- delete when the protocol lands. Deps `Core`, `DiarizerInterface`, `TranscriberInterface`; `Tests/AIReviewerInterfaceTests/` exists for its tests.
- `Package.swift:73-77,120-124,131` -- `Summarize` gains `AIReviewerInterface`; test targets gain the deps `--explicit-target-dependency-import-check error` demands (`VaultGlossaryTests` needs `Core`).
- `Tests/SummarizeTests/SummarizeStageFixture.swift` -- real in-memory store and runner, stub strategies, cache-dir cleanup; extend with a glossary-recording strategy.
- `.swiftlint.yml` `atomic_writer_bypass` `excluded` -- fixture-writing test files are listed with a rationale each; add the new vault-fixture test file the same way.
- `_bmad-output/planning-artifacts/architecture.md:1566-1610,2339,2365,2398-2400` -- Decision 5.1 shapes and target file layout; `epics.md:1751-1798` ACs; Story 4.4 later wraps `JargonCorrectionStrategy` in the `AIReviewerStrategy` family.

## Tasks & Acceptance

**Execution:**
- `Package.swift`, `.swiftlint.yml` -- dependency edges and fixture exclusion -- build and lint gates.
- `Sources/Core/CacheArtifactWriter.swift` -- add public `cacheRoot()`; `cacheDirectory(for:)` builds on it -- one owner of the cache root path.
- `Sources/VaultGlossary/VaultGlossaryBuilder.swift` -- vault scan, categorization, `build() -> Outcome{glossary, rebuilt}`, `buildOrEmpty()`, typed `VaultGlossaryError` -- FR55 and graceful degradation.
- `Sources/VaultGlossary/GlossaryCache.swift` -- cache model, fingerprint, read and atomic write at `glossary-cache.json` -- AR-INIT-5 cache.
- `Sources/VaultGlossary/FuzzyTermMatcher.swift` -- squash, windows, bounded edit distance, cheap prefilter, match text -- shared by the injector and the corrector.
- `Sources/Summarize/GlossaryInjector.swift` -- `scope(_:transcript:attendees:)` with the 40-term cap -- FR56.
- `Sources/Summarize/SummarizeStage.swift` -- scope, write `glossary.json`, pass scoped glossary; update the type comment -- FR57 wiring.
- `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` (+ `SummaryDraft`, `JargonCorrection`) -- protocol and value types; remove the placeholder -- AR-AI-1 slot.
- `Sources/Summarize/GlossaryJargonCorrector.swift` -- MVP conformer using `FuzzyTermMatcher` -- no separate API call.
- `Sources/Summarize/JargonWedgeMeasurement.swift` -- artifact scan, report, 0.4 criterion -- AR-AI-9.
- `App/auricle-cli/Verbs/InternalStageWorker.swift`, `App/auricle-cli/Verbs/JargonWedgeVerb.swift`, `App/auricle-cli/AuricleCLI.swift` -- `--vault-path`; hidden `__measure-jargon-wedge` printing counts only -- thin wrappers.
- `Tests/VaultGlossaryTests/`, `Tests/SummarizeTests/`, `Tests/AIReviewerInterfaceTests/` -- one test per matrix row, incl. the must-fail inputs (mangled term survives, unrelated term drops, cap holds, stale cache rescans, 10K-file bound), plus `JargonCorrection` JSON round trip -- proves each row.

**Acceptance Criteria:**
- Given a synthetic vault, when `VaultGlossaryBuilder.build()` runs twice with no change and then after a file's mtime is advanced, then the two unchanged calls return the same glossary and the second reports no rescan, and the third rescans.
- Given a glossary term the transcript spells wrongly, when `GlossaryInjector.scope` runs, then the term survives; an unmentioned term does not.
- Given the summarize stage with a full glossary, when it runs, then the strategy receives the scoped glossary, the prompt's glossary block is in `[[wikilink]]` form, and `glossary.json` holds the scoped glossary.
- Given `summary.json`, `transcript.json` and `glossary.json` for five meetings, two with a mangled-term correction, when `JargonWedgeMeasurement` runs, then it reports 2 of 5, rate 0.4, criterion met.
- Given the full gate, when `scripts/check.sh lint`, `swift` and `app` run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 59 findings — high 0, medium 8, low 49, false 2, maybe-false 0
- findings:
  - `[medium]` `[defer]` (Blind Hunter) `SubprocessDispatcher` never passes `--vault-path`, so dispatched summarize runs get an empty glossary — real: `makeProcess` builds only stage, id and protocol version. Not caused by this story: no config layer exists to supply `vault_path` (Core/Config is a separate story), and the empty glossary predates it. Deferred with the residual risk.
  - `[false]` `[reject]` (Blind Hunter) `WorkerProtocolVersion` not bumped for the new worker option — the version gates incompatible argument changes; `--vault-path` is optional, so an older dispatcher's argument vector still parses and behaves as before.
  - `[low]` `[reject]` (Blind Hunter) Worker does not pass `meetingsSubdir`, so a non-default meetings folder feeds auricle's own notes back — real only for a non-default `meetings_subdir`, and no config exists to set one; dated note names are also skipped by the date rule. The fix needs a new option.
  - `[low]` `[reject]` (Blind Hunter) Empty-glossary meetings count as eligible and drag the wedge rate down — the epic defines the rate over total meetings and the report prints the eligible and correction counts, so the reader sees the denominator; the dormant-dispatch cause is the deferred entry.
  - `[low]` `[reject]` (Blind Hunter) The 40-term cap ranks exact mentions ahead of mangled ones and alphabetically breaks ties — only bites when more than 40 vault terms qualify for one meeting; the ranking is a design trade-off (exact mentions are certain), and inverting it needs a rule the spec did not set.
  - `[medium]` `[patch]` (Blind Hunter) Inflected forms (plural, tense) of a glossary term count as jargon corrections, and no test measures the false-positive rate — real: `packet radio` in the summary against `packet radios` in the transcript passes the whole-term check as absent and fuzzy-matches at distance 1, inflating the wedge rate. Patched: `GlossaryJargonCorrector` skips a match that differs from the term by a trailing `s`, `es`, `d`, `ed` or `ing`, with three tests that failed before the fix.
  - `[low]` `[reject]` (Blind Hunter) Only a term's first occurrence in the summary is reported, so `charRange` covers one spelling — the wedge needs one correction per meeting and no consumer of the range exists in the MVP.
  - `[low]` `[reject]` (Blind Hunter) The wedge report renders a verdict at any sample size — the verb prints the eligible and correction counts beside the verdict, and the maintainer runs it by hand.
  - `[low]` `[reject]` (Blind Hunter) Window membership from `summary.json` mtime drifts on rewrite, and the OS may purge caches — documented in the spec and the code; a rewrite means a re-run, and a purge lowers the count, not the rate's meaning. Recorded as a residual risk.
  - `[low]` `[reject]` (Blind Hunter) `writeGlossaryArtifact` swallows failures with no log line — the contract says a failed write never fails the stage; the meeting shows under `missing_artifact_meetings`. A log line needs a `Log` instance plumbed into the stage.
  - `[low]` `[reject]` (Blind Hunter) `glossary.json` is written before the call, so a failed re-run leaves a fresh glossary beside an older `summary.json` — requires a failed re-run, and the scoped glossary differs only if attendees changed; the effect on the count is negligible. The spec fixes the write order.
  - `[low]` `[reject]` (Blind Hunter) The worker's stderr line prints `VaultGlossaryError` and cannot say which case — the contract names the error type only; the two cases carry no path, so this is a usability nicety.
  - `[low]` `[reject]` (Blind Hunter) `--vault-path` and tilde handling live in `App/`, untested by `swift test` — `App/` stays thin by rule; the logic that can fail is `buildOrEmpty` in `Sources/`, and the manual check ran.
  - `[low]` `[reject]` (Blind Hunter) The cache file is chmod 0600 after the write, and a chmod failure leaves it default-mode — `~/Library` is owner-only by default, so the file is not reachable by other users either way.
  - `[low]` `[reject]` (Blind Hunter) Concurrent workers can race on `glossary-cache.json` — worst case is a torn file that fails to decode and costs one rescan; a fix needs a lock file.
  - `[low]` `[reject]` (Blind Hunter) Embeds (`![[x.png]]`), file extensions and links inside code fences become glossary terms — such terms never fuzzy-match a transcript, so scoping drops them; the cost is cache size only.
  - `[low]` `[reject]` (Blind Hunter) No direct tests for `WikilinkScanner` — alias, heading, block, folder path and unclosed-link cases run through the builder tests.
  - `[low]` `[reject]` (Blind Hunter) Whole-file reads could trigger iCloud downloads in an evicted vault — speculative for this vault (a git checkout); no evidence of the condition.
  - `[low]` `[reject]` (Blind Hunter) Short person name parts (`Will`, `Dave`) fuzzy-match common words — thresholds are spec-defined and the 40-term cap bounds the noise; tuning is a design change. Recorded as a residual risk.
  - `[low]` `[patch]` (Blind Hunter) `FuzzyTermMatcher`'s doc comment claims scoping and the corrector find the same terms, which is false for person name parts — real: the corrector matches a person on the whole term only. Patched: the comment now says both share the squash-and-edit-distance match and only scoping also matches name parts.
  - `[low]` `[reject]` (Blind Hunter) No realistic-prose false-positive test for the matcher — the unrelated-term, short-term and edit-bound tests pin the rules; realistic-prose tuning needs real transcripts.
  - `[low]` `[reject]` (Blind Hunter) No scale test for `scope`, only for the vault scan — the implementer timed 10K terms against a 5,600-word transcript by hand; a timing assertion would only add flake risk.
  - `[low]` `[reject]` (Blind Hunter) The 10 s wall-clock bound in the 10K-file test could flake — the full test, including fixture creation, ran in 3.7 s in a debug build, so the bound has headroom.
  - `[low]` `[reject]` (Blind Hunter) `charRange` holds UTF-8 bytes, not characters — the name is Decision 5.1's; `ByteRange` documents the unit and a test pins it on non-ASCII text.
  - `[low]` `[reject]` (Blind Hunter) `ByteRange` duplicates the byte-offset idea in `GroundingPointer` — cosmetic; sharing a type would add a `Core` type for two fields.
  - `[low]` `[reject]` (Blind Hunter) `suggestionId` is derived from position only — the contract asks for deterministic and unique within a result, which it is; no accept/reject state exists to key against.
  - `[low]` `[reject]` (Blind Hunter) Replacing a note with an older-mtime copy leaves the fingerprint unchanged — narrow (restore or `rsync -t` with the same entry count); the mtime comparison is the epic's own rule.
  - `[low]` `[reject]` (Blind Hunter) The fingerprint ignores `meetingsSubdir` — changing the skipped folder changes the entry count, so the fingerprint differs in practice.
  - `[low]` `[reject]` (Blind Hunter) Attachments count toward the entry count and force a rescan — performance only, and the spec says every non-skipped file counts.
  - `[low]` `[reject]` (Blind Hunter) The `Speaker_N:` label check is a hard-coded literal — cosmetic; `VaultGlossary` depends on `Core` only and no shared constant exists.
  - `[low]` `[reject]` (Blind Hunter) Unspaced scripts and words over 64 scalars are never indexed — auricle's transcripts are English-first; recorded as a known limit.
  - `[low]` `[reject]` (Blind Hunter) `anUnreadableVaultDirectoryThrowsVaultUnreadable` returns silently when run as root — neither CI nor the maintainer runs tests as root.
  - `[false]` `[reject]` (Blind Hunter) An unreadable subdirectory is skipped, so a partial glossary is cached as complete — the subtree's entries are absent from the count, so fixing permissions changes the count and forces a rescan.
  - `[low]` `[reject]` (Edge Case Hunter) An empty or relative `--vault-path` resolves to the working directory — a hand-typed hidden flag; the scan is read-only.
  - `[medium]` `[defer]` (Edge Case Hunter) Nothing passes `--vault-path`, so the wiring ending the always-empty glossary is unreachable from dispatch — same root as the first Blind Hunter row: grouped under the deferred entry.
  - `[low]` `[reject]` (Edge Case Hunter) chmod failure or lag leaves the cache world-readable — same as the Blind Hunter chmod row.
  - `[low]` `[reject]` (Edge Case Hunter) Concurrent cache writers share `AtomicWriter`'s temp path — same as the Blind Hunter concurrency row.
  - `[low]` `[reject]` (Edge Case Hunter) An older-mtime overwrite serves a stale cache — same as the Blind Hunter older-mtime row.
  - `[low]` `[reject]` (Edge Case Hunter) A same-named page in an uncategorized folder can shadow its `People` copy — rare (two pages of one name); the term still survives scoping through a transcript mention.
  - `[low]` `[reject]` (Edge Case Hunter) A huge markdown file is loaded whole — not a realistic note size.
  - `[low]` `[reject]` (Edge Case Hunter) Embeds and `.md`-suffixed targets pollute the glossary — same as the Blind Hunter embeds row.
  - `[low]` `[reject]` (Edge Case Hunter) Links inside code fences or frontmatter become terms — same as the Blind Hunter embeds row.
  - `[medium]` `[patch]` (Edge Case Hunter) Inflected transcript forms count as corrections and inflate the wedge rate — same root as the Blind Hunter inflection row; fixed by the same patch.
  - `[low]` `[reject]` (Edge Case Hunter) A possessive (`Ben's`) does not match a term under four characters — a short term also survives through its attendee entry or a plain mention; adding an apostrophe rule is new matching behaviour.
  - `[low]` `[reject]` (Edge Case Hunter) Unspaced scripts tokenize as one word — same as the Blind Hunter unspaced-script row.
  - `[low]` `[reject]` (Edge Case Hunter) A `summary.json` dated in the future drops out of every count — needs clock skew or a restored file.
  - `[low]` `[reject]` (Edge Case Hunter) A mistyped `--cache-root` prints zeros and exits 0 — a hand-run hidden verb; the default root needs no argument.
  - `[low]` `[reject]` (Edge Case Hunter) A failed re-run pairs a new `glossary.json` with an old `summary.json` — same as the Blind Hunter pairing row.
  - `[medium]` `[patch]` (Verification Gap) `aCacheBuiltForAnotherVaultPathRescans` cannot fail on the vault-path check — pre-verified: the second vault's newer root mtime forces the rescan. Patched: the test rewrites only `vault_path` in the cache; it fails with the check removed.
  - `[medium]` `[patch]` (Verification Gap) No test plants decision text, so dropping decisions from the wedge input stays green — pre-verified: `plantMeeting` always sets `decisions: []`. Patched: a `decisionText:` parameter and `aCorrectedTermInADecisionCounts`, which fails with decisions dropped.
  - `[low]` `[reject]` (Verification Gap) The `App/` wiring (`--vault-path`, verb output) has no automated check — `App/` stays thin by rule and the manual check ran; a subprocess smoke test belongs with the dispatch wiring.
  - `[low]` `[reject]` (Verification Gap) The shared cache path is not safe for concurrent writers — same as the Blind Hunter concurrency row.
  - `[medium]` `[defer]` (Intent Alignment) No production path supplies a vault path to the summarize stage — same root as the first Blind Hunter row: grouped under the deferred entry.
  - `[low]` `[reject]` (Intent Alignment) The `App/` wrappers are not covered by unit tests — same as the Verification Gap `App/` row.
  - `[low]` `[reject]` (Intent Alignment) The wikilink-form stage test rebuilds the prompt instead of going through a strategy — the strategies' own tests cover how the prompt's glossary block enters the request.
  - `[low]` `[reject]` (Intent Alignment) Nothing in production calls `JargonCorrectionStrategy.correct`, only the static function — the epic fills a slot and Story 4.4 adopts it; the measurement shares the implementation through the static entry.
  - `[low]` `[reject]` (Intent Alignment) The diff departs from the epic text on the `scope` signature, the corrector, the denominator and the test location — each departure is reasoned in the spec's Design Notes and Boundaries; the epic names no observable behaviour the diff misses.
  - `[low]` `[reject]` (Intent Alignment) The diff adds ghost links, skip rules and the 40-term cap the epic does not name — the spec's decisions; the epic's ~200-token bound needs the cap.
  - `[medium]` `[defer]` (Intent Alignment) No config or GUI path supplies `vault_path` — same root as the first Blind Hunter row: grouped under the deferred entry.

## Design Notes

Page names alone would miss the terms this maintainer cares about: notes are linked long before they exist. Content parsing adds those ghost links, and the mtime fingerprint covers files as well as directories because a link added inside an existing note changes no directory's mtime.

The epic names `GlossaryInjector.scope(_:forMeeting: MeetingForFrontmatter)`. That type belongs to `Persist`, is built after summarization, and would add a `Summarize`→`Persist` edge. Attendees plus the transcript are the inputs FR56 names, so the signature takes those.

Correction detection reads the summary and transcript rather than instrumenting the model call, so it needs no new artifact and matches the epic's "difference between summary-side and transcript-side terms". A glossary term absent from both is an invention, not a correction.

## Verification

**Commands:**
- `swift test --explicit-target-dependency-import-check error --filter "VaultGlossary|GlossaryInjector|GlossaryJargon|JargonWedge|SummarizeStage|JargonCorrection"` -- expected: pass.
- `scripts/check.sh lint`, `scripts/check.sh swift`, `scripts/check.sh app` -- expected: pass.

**Manual checks:**
- Build `auricle-cli`, run `__measure-jargon-wedge` against an empty cache root, and expect zero eligible meetings, no rate, exit 0. Confirm `git diff` leaves `SubprocessDispatcher` unchanged.

## Auto Run Result

**Summary of implemented change:** Story 3.12. `VaultGlossaryBuilder` builds the vault glossary from markdown page names and `[[wikilink]]` targets (ghost links included), categorizes it by `People`/`Projects`/`Concepts` folders, and caches it at `glossary-cache.json` until the vault fingerprint changes. `GlossaryInjector` scopes it per meeting with a fuzzy squash-and-edit-distance match, capped at 40 terms. `SummarizeStage` scopes the glossary with attendees from `attribution.json`, writes the scoped glossary to `glossary.json`, and passes it to the orchestrator. `JargonCorrectionStrategy`, `SummaryDraft` and `JargonCorrection` are declared in `AIReviewerInterface`; `GlossaryJargonCorrector` is the MVP conformer and makes no API call. `JargonWedgeMeasurement` and a hidden `__measure-jargon-wedge` verb report the 30-day, 40% wedge criterion as counts only. `InternalStageWorker` gains an optional `--vault-path`.

**Files changed:**
- `Package.swift`, `.swiftlint.yml` -- `Summarize` gains `AIReviewerInterface`; test targets gain declared deps; the vault fixture joins the `atomic_writer_bypass` exclusions.
- `Sources/Core/CacheArtifactWriter.swift` -- `cacheRoot()` extracted.
- `Sources/VaultGlossary/` -- `VaultGlossaryBuilder`, `GlossaryCache`, `WikilinkScanner`, `FuzzyTermMatcher`, `FuzzyTermIndexing`; placeholder removed.
- `Sources/AIReviewerInterface/JargonCorrectionStrategy.swift` -- protocol, `SummaryDraft`, `JargonCorrection`, `ByteRange`; placeholder removed.
- `Sources/Summarize/` -- `GlossaryInjector`, `GlossaryJargonCorrector`, `JargonWedgeMeasurement`, `AttributionSpeakers.attendeeNames`, `SummarizeStage` scoping and `glossary.json`.
- `App/auricle-cli/` -- `--vault-path` on `InternalStageWorker`, `JargonWedgeVerb`, registration in `AuricleCLI`.
- `Tests/VaultGlossaryTests/`, `Tests/SummarizeTests/`, `Tests/AIReviewerInterfaceTests/`, `Tests/CoreTests/CacheArtifactWriterTests.swift` -- a test per matrix row plus the must-fail cases.

**Review findings breakdown:** 59 findings across 4 layers -- 0 high, 8 medium, 49 low, 2 false. Full per-finding detail is in `## Review Triage Log`.
- **Patched (4 entries: 3 medium, 1 low):**
  - The corrector no longer counts plural or tense variants of a term as corrections (found by two layers).
  - The vault-path invalidation test now fails when the check is removed.
  - A test now covers decision text in the wedge input.
  - The `FuzzyTermMatcher` doc comment no longer claims the corrector matches name parts.
- **Deferred (1 entry, medium):** GUI dispatch passes no `--vault-path`, so dispatched runs still get an empty glossary until a config layer exists (found by four rows).
- **Rejected (54):** each with its reason in the log. Main groups: cache concurrency, permissions and fingerprint edge cases that cost at most a rescan; scanner pollution that scoping drops; `App/` wrappers that stay thin by rule; matching-threshold tuning the spec set; two false claims.
- **Follow-up review recommendation:** `true`. Three medium entries were patched. The named unverified risk: the inflection guard looks only at the single best fuzzy match, and no real-transcript sample has measured the corrector's false-positive rate against the 40% criterion.

**Verification performed:**
- `swift test --explicit-target-dependency-import-check error` -- 505 tests pass, before and after the patch round. The 10K-file vault test builds inside its bound.
- `scripts/check.sh lint` and `scripts/check.sh app` -- pass, before and after the patch round.
- Manual check: the built `auricle-cli __measure-jargon-wedge --cache-root <empty dir>` reports zero eligible meetings, no rate, exit 0, and is absent from `auricle --help`. `SubprocessDispatcher` is unchanged.
- Mutation checks by the implementer, each reverted: removing the vault-path check, dropping decisions from the wedge input, and tightening the fuzzy prefilter each fail a test.
- Matrix Test Audit: every I/O matrix row is covered by a test that ran and passed in the full run.

**Residual risks:**
- Dispatched runs stay glossary-free until GUI dispatch passes a vault path (the deferred entry), so the wedge reads 0 until then.
- The corrector's false-positive rate on real transcripts is unmeasured, and the 40% criterion is judged on it.
- Short person name parts (`Will`, `Dave`) fuzzy-match common words in scoping, and the 40-term cap bounds only the token cost.
- The wedge window keys on `summary.json` modification time, and a cleaned cache lowers the counts.
- Story 4.4's text says the MVP conformer wraps `GlossaryInjector`; this one shares the matcher instead and needs that sentence reconciled.
- The branch is `claude/bmad-build-autocomplete-3-12-56ad06`; project policy asks for a semantic `type/short-kebab-description` name, so rename it before any push.
