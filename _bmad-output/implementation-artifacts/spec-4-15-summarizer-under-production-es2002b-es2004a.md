---
title: 'Story 4.15: Summarizer Under-Production on ES2002b and ES2004a'
type: 'feature'
created: '2026-09-21'
status: 'in-progress'
status_detail: 'AC1/AC2/AC3 landed and reviewed (PR #105). AC4 (the stop condition) is open: needs either a recorded full-pipeline run reaching 16/19 (blocked on a live Anthropic call and on Story 4.14 landing its retention metric/rerun on origin/main) or a maintainer ruling written into expected.json notes.'
baseline_revision: 'e88e2e542ac2c73b9f8265d512c81561e0585bc4'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
  '{project-root}/_bmad-output/planning-artifacts/sprint-change-proposal-2026-09-21.md',
  '{project-root}/Tests/fixtures/prompt-arm-results.md',
  '{project-root}/Tests/fixtures/recall-bench-output/2026-09-21-handoff-from-research/README.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      RecallBenchFixtureLoader.body(of:textBytes:) has unsignaled failure
      branches — an out-of-bounds utterance silently drops from the diarized
      transcript, and an utterance whose stored speakerLabel doesn't literally
      prefix its own bytes gets a doubled speaker label instead of an error.
    evidence: |-
      Confirmed both branches exist and behave as described (bounds guard
      returns "" which CanonicalTranscriptBuilder.build then drops; the
      no-match fallthrough returns the unstripped original text, which the
      caller re-prefixes). Neither is reachable via the app's own artifact
      writers today, since CanonicalTranscriptBuilder's invariant guarantees
      an utterance's own speakerLabel always prefixes its own bytes for any
      transcript built through it — only a hand-edited fixture file (the
      workflow this story itself sets up, via shadow-root reference dirs)
      could trigger either. The off-by-one "label with no trailing space"
      branch is also untested and would be deleted, not tested, by the same
      fix. Fix: change body() to return String?, nil on any non-exact-match,
      and have the caller skip relabeling that utterance (keep it as written)
      rather than building blank or doubled-label text.
    location: >-
      Sources/RecallBench/RecallBenchFixtureLoader.swift:117-146
    severity: low
  - summary: >-
      body(of:textBytes:) duplicates the private prefix-stripping algorithm in
      AttributionRenderer.utteranceText instead of sharing it.
    evidence: |-
      Confirmed line-for-line duplication with Sources/Attribute/
      AttributionRenderer.swift:117-134, including its off-by-one branch.
      Closing it means exposing AttributionRenderer's private helper as
      internal/public API across the Attribute/RecallBench module boundary —
      more than a direct correction, and RecallBench already depends on
      Attribute only for UtteranceSpeakers.resolve, not for text-splicing.
    location: >-
      Sources/RecallBench/RecallBenchFixtureLoader.swift:137-146
    severity: low
  - summary: >-
      diarization.json/attribution.json present but undecodable collapses to
      the same silent fallback as "file absent," with no signal distinguishing
      the two — --diarized can silently under-diarize a meeting.
    evidence: |-
      Confirmed via diarizedTranscript(in:from:)'s try? chain: a malformed
      diarization.json or attribution.json returns nil from diarizedTranscript
      exactly like a missing file would, and the caller falls back to the
      transcript as written either way. Inconsistent with this same file's
      existing convention: readTranscript/fixture(for:repoRoot:) throw a typed
      LoadError.transcriptUndecodable when transcript.json itself fails to
      decode, rather than silently degrading. A maintainer running --diarized
      on a hand-authored shadow root can debug a suspiciously low-diarization
      result by inspecting the JSON directly, so this is a bench/test-tooling
      usability gap, not a correctness one — but the fix (distinguish presence
      from decode success, add a stderr signal) is more than a direct
      correction on this pass.
    location: >-
      Sources/RecallBench/RecallBenchFixtureLoader.swift:117-131
    severity: medium
  - summary: >-
      The per-utterance fallback (resolved[index] ?? utterance.speakerLabel)
      mixes resolved speaker names with leftover Speaker_1 placeholders in one
      transcript with no runtime signal that a partial fallback happened.
    evidence: |-
      Confirmed: UtteranceSpeakers.resolve returns nil per-utterance for an
      uncovered or disputed diarization segment (by its own doc comment), and
      diarizedTranscript's fallback to the original label is silent — nothing
      logs or flags that a --diarized run mixed real and placeholder labels.
      This pass added a test
      (diarizedTrueKeepsTheOriginalLabelForAnUtteranceNoDiarizationSegmentCovers)
      that demonstrates and pins the fallback's correctness, which covers the
      behavior; the runtime warning itself is a separate, smaller ask left for
      a future pass rather than compounding this patch round.
    location: >-
      Sources/RecallBench/RecallBenchFixtureLoader.swift:126-131
    severity: medium
---

<intent-contract>

## Intent

**Problem:** ES2004a's 3 expected items never appear in the summarizer's output on any transcript source tried so far, and ES2002b's action items collapse (3/4 kept to 0/4) when the transcript grows more complete. Both hold Epic 4 below Story 4.10's 80% floor even after Story 4.14's transcription fix.

**Approach:** Diff the 2026-09-21 bench runs meeting-by-meeting to name the regression, characterize ES2004a's three misses against ground truth, extend the offline bench with a diarized WhisperKit-transcript arm, then run single-variable prompt arms against the reproduced findings until the stop condition is met.

## Boundaries & Constraints

**Always:** One primary Claude call per meeting (FR32) — no arm is multi-pass. Reuse `Tests/regression/ami/score.py`'s matching rule via the bench, never a new scorer. Gitignore every rendered note/transcript with real AMI content; only aggregate numbers are committed, matching `Tests/fixtures/prompt-arm-results.md`'s pattern. Ship a prompt change to `Sources/Summarize/Prompts/summarize/` only once it is the recorded winner.

**Never:** Multi-pass summarization. Resolve the stop condition by picking a reading — either land a recorded ≥16/19 full-pipeline run, or write the maintainer's ruling verbatim into `expected.json`'s notes; never invent a middle ground. Do not change `SummarizeStage` to route diarized text into the summarization prompt — that production never does this today is a real finding (see Design Notes) but a larger, separate change; this story documents it, it does not fix it.

</intent-contract>

## Code Map

- `Tests/fixtures/recall-bench-output/2026-09-21-handoff-from-research/README.md` — gitignored 2026-09-21 handoff: bench over app-cached transcripts (13/19), over gate-fixed transcripts (10/19, two runs), and `full-pipeline-with-fix-report.txt` (14/19). This is the required diff source for AC1; already diffed below.
- `Tests/fixtures/recall-bench-output/2026-09-21-handoff-from-research/notes-{app-cached-transcripts,fixed-transcripts-run1,fixed-transcripts-run2}/substring/ES*.md` — per-meeting kept/dropped items, already read and diffed (Design Notes).
- `Tests/regression/ami/reference/es2004a/expected.json` — ES2004a's 3 ground-truth items plus the maintainer's own notes on which floated ideas were correctly left out.
- `~/Library/Caches/com.auricle.app/01M33J8KFM14V0M3H4P73RANSB/` and its 4 siblings (`01M33HCEY1VFNY2ZSGB7ER1FXH`, `01M33HXYJYNDYY2GWNK0F2YTRN`, `01M33J2Q97YMNHFWZJVBE2TJQK`, `01M33J4E08NPMJBAQ3TZBEXGTN`) — today's `full-pipeline-with-fix-report.txt` run's real cache: `transcript.json` + `diarization.json` + `attribution.json` + `utterance_timings.json` for all 5 AMI meetings, content-matched to ES2004a/ES2002a/ES2002b/ES2003a/ES2003b via each `summary.json`'s text. This is the diarization data AC3's arm needs. **Time-sensitive**: this is the machine-global app cache, not worktree-local — copy what's needed into a gitignored `Tests/fixtures/` dir before a concurrent session's pipeline run overwrites it.
- `Sources/RecallBench/RecallBenchFixtureLoader.swift` — `fixture(for:repoRoot:)` (~line 61) reads only `<reference-dir>/transcript.json`, no attribution/diarization join. Extend with an optional path that joins `diarization.json` + `attribution.json` when both sit beside `transcript.json`.
- `Sources/Attribute/UtteranceSpeakers.swift` — `resolve(utteranceCount:diarization:file:)` (~lines 23-52) joins diarization segments + attribution speakers/overrides/splits into `[String?]` per utterance. Reuse this join; do not reimplement it.
- `Sources/Core/CanonicalTranscriptBuilder.swift` — `build(_:)` (~line 19) rebuilds a `CanonicalTranscript` from `(speakerLabel, text)` pairs. Feed it resolved names in place of raw `Speaker_N` for the new arm.
- `Sources/Core/AttributionArtifact.swift:5-6`, `Sources/Attribute/AttributionFile.swift:123-163` — `attribution.json` schema (`speakers`, `segment_overrides`, `segment_splits`).
- `App/auricle-cli/Verbs/RecallBenchVerb.swift` — `--repo-root`/`--arm` parsing and arm construction (~lines 24-110). Add the new arm/flag following the existing `substring:<dir>` convention.
- `Sources/RecallBench/RecallBenchManifest.swift`, `RecallBenchRunner.swift` — manifest/runner shape; confirmed unaffected, no schema edit needed.
- `Tests/scripts/run-recall-bench.sh` (lines ~64, 70) — CLI invocation the new flag extends.
- `Sources/Summarize/SummarizeStage+Inputs.swift:20-41`, `Sources/Summarize/SummarizeStage.swift:155-186` — confirms production's `orchestrator.summarize` call always receives the raw, undiarized `transcript.json`. `attribution.json`/`diarization.json` reach only `SummaryArtifactMapper.transcriptSegments` (note metadata), never the prompt. Document as a finding (Design Notes); do not change it here.
- `Tests/regression/ami/score.py`, `Tests/regression/ami/thresholds.json` — scoring and `min_item_recall`. Story 4.14 (separate, in flight in another session as of this writing) owns raising `min_item_recall` and recording the guarding `history.jsonl` row this story's stop condition needs.
- `Tests/fixtures/prompt-arms/{sections-independent,action-coverage,both}` — existing single-variable arm layout from Story 4.13 to follow for any new prompt arm.

## Tasks & Acceptance

**Execution:**
- `Tests/fixtures/recall-bench-output/2026-09-21-handoff-from-research/` -- write up the per-meeting kept-item diff between the app-cached and fixed-transcript runs (already done below; land it in a committed `Tests/fixtures/*.md` results file) -- satisfies AC1.
- `Tests/regression/ami/reference/es2004a/expected.json` + the matched cache dir above -- write up which rule each of ES2004a's 3 items falls under and whether it is discarded or never proposed (already done below; land it alongside the diff) -- satisfies AC2.
- `Sources/RecallBench/RecallBenchFixtureLoader.swift` -- add an optional diarized-load path: when `diarization.json` and `attribution.json` sit beside `transcript.json`, join them via `UtteranceSpeakers.resolve` and rebuild the transcript via `CanonicalTranscriptBuilder.build`; fall back to today's behavior when either file is absent.
- `App/auricle-cli/Verbs/RecallBenchVerb.swift` -- wire a flag/arm spec that opts a `--repo-root` invocation into the diarized load path.
- New gitignored `Tests/fixtures/recall-bench-output/<date>-diarized/` reference set -- copy `transcript.json`/`diarization.json`/`attribution.json` for the 5 AMI meetings out of the local app cache before it is overwritten; this is the fixture the new arm runs against.
- Run one prompt arm per finding (let the diff and the ES2004a characterization pick the finding — do not presuppose the fix), single-variable, through the bench, recorded under `Tests/fixtures/`.
- Stop per the epics.md condition: either a recorded full-pipeline run reaches 16/19 (after Story 4.14 lands its recorded row and raised `min_item_recall` — rebase onto `origin/main` and check before this measurement), or write the maintainer's ruling into `expected.json`'s notes.

**Acceptance Criteria:**
- Given the 2026-09-21 bench runs over cached and fixed transcripts, when their kept items are diffed per meeting, then the story records what the summarizer stops emitting when the input grows.
- Given ES2004a's reference transcript, when summarized with the promoted prompt, then the story records which rule each of the three expected items falls under and whether the model proposes-and-discards or never proposes them.
- Given the bench's fixture loader, when a WhisperKit-transcript arm is added, then the arm carries diarized speaker labels from `attribution.json`.
- Given arms run one finding at a time, when a recorded full-pipeline run reaches 16/19, or the maintainer rules ES2004a's items leave the fixture (rationale in `expected.json`'s notes), then the story stops.

## Spec Change Log

## Review Triage Log

### 2026-09-21 — Review pass
- verdicts: 13 findings — high 0, medium 4, low 6, false 3, maybe-false 0
- findings:
  - `[low]` `[defer]` (blind-hunter) `RecallBenchFixtureLoader.body(of:textBytes:)` returns `""` when its bounds guard fails, and `CanonicalTranscriptBuilder.build` silently drops any utterance whose text canonicalizes to blank — a diarized transcript could lose an utterance with no signal. Only reachable when `transcript.json`'s own `start`/`end` violate the invariant `CanonicalTranscriptBuilder` itself enforces on every writer; the app's own artifact writers never produce that. Fix (change `body` to `String?` and skip relabeling instead of building blank text) is more than a direct correction — deferred, not patched. Root of the group below.
  - `[low]` `[defer]` (blind-hunter) `body(of:textBytes:)` duplicates the private prefix-stripping algorithm in `Sources/Attribute/AttributionRenderer.swift:117-134` instead of sharing it, so the two can drift. Real DRY concern; closing it means exposing new cross-module API surface, more than a direct correction — deferred, standalone.
  - `[low]` `[defer]` (blind-hunter) If an utterance's stored `speakerLabel` doesn't literally prefix its own text bytes, `body(of:textBytes:)` falls through and returns the untouched original (prefix included), and the caller re-prepends the new label, producing a doubled label. Verified reachable only via a hand-edited fixture file, never via the app's own writers (`body` matches against the utterance's *own* original label, which `CanonicalTranscriptBuilder`'s invariant guarantees always prefixes its own bytes). Grouped with the bounds-guard finding above — same function, same fix, deferred together.
  - `[low]` `[defer]` (blind-hunter) The off-by-one "label with no trailing space" branch in `body(of:textBytes:)` is copied from `AttributionRenderer` but never exercised by any new test. Grouped with the same `body()` root cause; the deferred fix would delete this branch rather than test it.
  - `[medium]` `[defer]` (blind-hunter) The per-utterance fallback `resolved[index] ?? utterance.speakerLabel` mixes resolved names with leftover `Speaker_1` placeholders in one transcript with no runtime signal this happened. Real; the patched test below (verification-gap finding, same location) demonstrates and pins the fallback path, which covers the behavior even without a stderr warning — the warning itself is a separate, smaller ask not worth a second patch round this pass.
  - `[low]` `[patch]` (blind-hunter) No test exercises `diarization.json` missing while `attribution.json` is present (only the reverse is tested). Trivial, symmetric addition to the existing test file. Patched: `diarizedTrueFallsBackToTheTranscriptAsWrittenWhenDiarizationIsMissing` added to `Tests/RecallBenchTests/RecallBenchFixtureLoaderTests.swift`.
  - `[low]` `[false]` (blind-hunter) `Package.swift`'s new dependency comment carries a `(Story 4.15)` parenthetical, which reads as process residue under the user's stated comment policy. Refuted by direct fix: removed the parenthetical directly rather than deferring or routing through the implementation subagent — a one-line, unambiguous removal.
  - `[low]` `[false]` (blind-hunter) `Tests/fixtures/story-4-15-findings.md` and the spec's own Design Notes carry near-duplicate prose/tables. Matches the established, already-accepted pattern from Story 4.13 (`spec-4-13-prompt-recall-pass.md` duplicates its own findings into `Tests/fixtures/prompt-arm-results.md`) — not a novel defect, and de-duplicating would break that convention.
  - `[low]` `[false]` (blind-hunter) `--diarized`'s CLI wiring in `App/auricle-cli/Verbs/RecallBenchVerb.swift` has no test. Matches AGENTS.md's documented, accepted pattern: the actual logic lives in `Sources/RecallBench` and is tested there; the `App/` layer is a thin, untestable-by-`swift test` wrapper by design, not an oversight.
  - `[medium]` `[defer]` (edge-case-hunter) Unmatched-label branch in `body(of:textBytes:)` doubles the speaker prefix. Same location and root cause as the third blind-hunter row above; grouped and deferred together (highest verdict in the group carries: `medium`).
  - `[medium]` `[defer]` (edge-case-hunter) `diarization.json`/`attribution.json` present-but-undecodable silently collapses to the same fallback as "file absent," with no distinguishing signal — `--diarized` can silently under-diarize a meeting. Real, and inconsistent with this same file's existing convention of throwing a typed `LoadError` when `transcript.json` itself is undecodable. Fix (a presence-vs-decode-success distinction plus a stderr signal) is more than a direct correction on a bench/test-tooling path a maintainer can already debug by inspecting the JSON directly — deferred, standalone.
  - `[low]` `[defer]` (edge-case-hunter) Out-of-bounds utterance bytes silently drop the utterance via `CanonicalTranscriptBuilder`'s blank-text filter. Same location and root cause as the first blind-hunter row above; grouped and deferred together.
  - `[medium]` `[patch]` (verification-gap) No test covers an utterance outside every `diarization.json` segment's range (`UtteranceSpeakers.resolve` returning `nil`), so a regression in `resolved[index] ?? utterance.speakerLabel` (e.g. a force-unwrap or a blank-label fallback) would ship undetected. Pre-verified per the verification-gap layer's own evidence rules; disposition filed as `patch`. Patched: `diarizedTrueKeepsTheOriginalLabelForAnUtteranceNoDiarizationSegmentCovers` added to the same test file.

Two items patched this pass, both in `Tests/RecallBenchTests/RecallBenchFixtureLoaderTests.swift`; one item fixed directly (the `Package.swift` comment) rather than routed as a patch. Everything else groups into three deferred entries (`body()`'s unsignaled fallback branches; the DRY duplication with `AttributionRenderer`; the undecodable-vs-absent file distinction) plus the per-utterance-fallback signal, all written to `deferred` in this spec's frontmatter.

intent-alignment audited the diff against the verbatim invocation intent and found no itemized defects: it confirmed the diff implements the bounded/conditional reading (do what's achievable, document what's blocked, don't fabricate the rest) and that every surface where the intent and the diff diverge — AC4 unmet, AC1/AC2 sourced from a gitignored directory, the AC3 premise mismatch, "base off origin/main" excluding Story 4.14's unlanded work — is already named in the spec's own Design Notes rather than silently absorbed. No finding routed from this layer.

## Design Notes

**AC1 — the diff, cached → fixed (run1):**

| meeting | cached | fixed run1 | fixed run2 | note |
|---|---:|---:|---:|---|
| ES2002a | 3/3 | 3/3 | 3/3 | no change |
| ES2002b | 5/8 (act 3/4, dec 2/4) | 2/8 (act 0/4, dec 2/4) | 3/8 (act 1/4, dec 2/4) | action items collapse; decisions steady |
| ES2003a | 1/1 | 1/1 | 1/1 | no change |
| ES2003b | 3/4 | 4/4 | 3/4 | improves in run1 |
| ES2004a | 1/3 | 0/3 | 0/3 | already worst, stays worst |

Not a uniform "more text, fewer items": the loss concentrates in ES2002b's action items (its "Action Items" section is empty in both fixed runs, confirmed by reading the notes directly) and in ES2004a, already at zero; ES2003b moves the other way.

**AC2 — ES2004a's 3 expected items, characterized against `expected.json` and both transcript sources (hand-verified against the actual transcript text, not inferred from the score):**

1. Budget-sharing action item ("[PM] will make the project budget figures available ... in the shared folder"). A close paraphrase of the reference quote is present in both transcript sources. Extracted on the shorter cached transcript (grounded on a nearby line, "I think I'd be able to pull it up or put it in the shared folder"); dropped on both longer fixed-transcript runs despite the same line surviving there too (as "I'd be able to pull it up"). Never discarded — no ungrounded-quote entries for it anywhere. A longer-context effect, not a missing-text one.
2. "Everyone works on their own task during the half hour before the next meeting." The quote ("we've got half an hour before the next meeting, so we're all gonna go off and do our individual things") is present near-verbatim in every transcript source and gets folded into the note's summary prose every time — never extracted as a discrete action item, on cached or fixed. No named individual owner; reads as a closing announcement rather than an assignment.
3. "Multiple languages are not a key point of the design" decision. Its quote was one of the windows the first-token gate dropped from the cached transcript (absent there entirely — grep confirms). Present verbatim in the fixed transcript. Still never proposed there either. A terse, one-line ruling with no decision-marking language ("we decided", "we agreed").

All three are **never-proposed**, not proposed-and-discarded, on every transcript source tried so far.

**A discovered discrepancy in epics.md's AC3 premise.** The AC's stated reason for the diarized arm is that the pipeline "never runs" a `Speaker_1`-only summarization condition. `Sources/Summarize/SummarizeStage+Inputs.swift:20-41` and `SummarizeStage.swift:155-186` show the opposite: `orchestrator.summarize` is always given the raw `transcript.json` WhisperKit wrote (`Speaker_1` for every utterance); `attribution.json`/`diarization.json` are joined only into `SummaryArtifactMapper.transcriptSegments`, for the published note's metadata, never into the prompt. Production always runs the `Speaker_1`-only condition, today, unconditionally. The diarized arm is still worth building — it tests whether per-speaker context is a real recall lever the team hasn't tried — but it tests a hypothetical pipeline change, not today's pipeline. Flag this for the maintainer; do not silently reframe the AC or expand this story into rewiring `SummarizeStage`.

A second, related gap: the offline bench (`RecallBenchVerb`/`Sources/RecallBench`) never passes attendee names into the prompt at all (no `attendee` reference anywhere under either path), while a full pipeline run may carry real attendee names from calendar enrichment or `--speakers`. This is a second, undocumented bench/pipeline divergence, unrelated to diarization, worth the same flag.

**Dependency on Story 4.14.** Confirmed via a peer session ("Story 4.14 completion", live as of this writing): this story's stop condition needs Story 4.14's recorded `history.jsonl` row and raised `min_item_recall` first. The gate fix itself (`firstTokenLogProbThreshold: nil`) is already on `origin/main` (PR #104); the retention metric and the recorded Part B rerun are not yet. Do the investigation and bench-loader work now; rebase onto `origin/main` and re-check before the closing measurement.

## Verification

**Commands:**
- `Tests/scripts/run-recall-bench.sh --repo-root <gitignored diarized fixture dir>` -- expected: bench runs against diarized WhisperKit transcripts without error; report shows the new arm's per-meeting recall.
- `swift build && swift test --explicit-target-dependency-import-check error` -- expected: no regression in the RecallBench, Attribute, or Summarize suites.
- `scripts/check.sh lint` -- expected: passes (exercises `score.py report` over `history.jsonl`).

**Manual checks (if no CLI):**
- Open the new gitignored diarized fixture dir's `transcript.json` and confirm per-utterance speaker labels differ from a flat `Speaker_1` before trusting a bench run over it.

## Auto Run Result

**Summary:** AC1 (per-meeting diff) and AC2 (ES2004a's three items characterized as never-proposed) are satisfied by direct investigation, written up committed. AC3 (diarized bench arm) is implemented, tested, and reviewed. A follow-up investigation ruled out glossary, attendee context, and `SummarizerConfig` defaults as explanations for the full-pipeline-vs-bench recall gap (real cache artifacts as evidence) and identified the actual cause: no summarization call in this codebase sets `temperature`, so every call samples at the API default of 1.0 — three runs of byte-identical input spanning 10/19 to 14/19 is that variance, not a hidden input (see findings doc). AC4 (the stop condition) is not met and cannot be from this worktree: it needs a live Anthropic API call, which this session's own permission mode currently blocks the setup for (Keychain/config reads are refused as credential exploration — a key may still exist on this machine), and — for the 16/19 path — Story 4.14's recorded `history.jsonl` row and raised `min_item_recall`, which were still landing in a separate session as of this writing. Per the spec's own `Never` constraint, no result was fabricated and no fixture ruling was made unilaterally.

**Files changed:**
- `Sources/RecallBench/RecallBenchFixtureLoader.swift` — new `diarized` parameter on `load`/`fixture(for:repoRoot:)`; joins `diarization.json`+`attribution.json` via `UtteranceSpeakers.resolve` and rebuilds the transcript via `CanonicalTranscriptBuilder.build` when both are present, falling back per-fixture otherwise.
- `App/auricle-cli/Verbs/RecallBenchVerb.swift` — new `--diarized` flag, threaded to the loader and into the planned-calls stderr line.
- `Tests/scripts/run-recall-bench.sh` — comment documenting `--diarized` and the "shadow root" convention.
- `Package.swift` — `RecallBench`/`RecallBenchTests` gain `Attribute`/`DiarizerInterface` dependencies for the join.
- `Tests/RecallBenchTests/RecallBenchFixtureLoaderTests.swift` — 5 new tests: diarized-off is a no-op, diarized-on joins correctly, and three fallback cases (attribution missing, diarization missing, one utterance outside every diarization segment's range).
- `Tests/fixtures/story-4-15-findings.md` (new, committed) — AC1's diff table and AC2's ES2004a characterization, plus the two flagged premise/gap findings and the Story 4.14 dependency note.
- `Tests/fixtures/recall-bench-output/2026-09-21-{handoff-from-research,full-pipeline-diarized}/` and `.../2026-09-21-diarized/` (new, gitignored) — the real research-session handoff data, a copy of today's full-pipeline-with-fix run's cache (transcript/diarization/attribution for all 5 AMI meetings, copied out of `~/Library/Caches/com.auricle.app/` before a concurrent session's run could overwrite it), and a "shadow root" built from the same data for the new arm to run against.
- `_bmad-output/implementation-artifacts/spec-4-15-summarizer-under-production-es2002b-es2004a.md` (this file, new).

**Review findings breakdown (13 total across 4 layers):**
- Patched (2): no test for `diarization.json` absent with `attribution.json` present; no test for an utterance outside every diarization segment's coverage.
- Fixed directly, not routed as a patch (1): a `(Story 4.15)` process-residue parenthetical in a `Package.swift` comment, removed.
- Deferred (4, written to frontmatter `deferred`): `body(of:textBytes:)`'s unsignaled failure/fallthrough branches (bounds-guard drop, mismatched-label doubling, untested off-by-one branch — grouped, one root cause); its duplication of `AttributionRenderer`'s prefix-stripping logic; `diarization.json`/`attribution.json` present-but-undecodable collapsing silently into the same fallback as absent; the per-utterance resolve-fallback's lack of a runtime signal (its test coverage was patched, the signal itself was not).
- Rejected as false (2): the findings doc's duplication with the spec's own Design Notes (matches Story 4.13's established `prompt-arm-results.md` precedent); `--diarized`'s untested CLI wiring (matches AGENTS.md's documented App/-thin-wrapper convention).
- intent-alignment: no itemized findings — confirmed the diff implements the bounded/conditional reading of the intent and that every divergence point it could name was already surfaced in this spec rather than silently absorbed.

**Follow-up review recommendation:** `false`. One `medium` and one `low` entry were patched this pass — not two or more `medium`, and no `high`.

**Verification performed:** `swift build` (clean); `swift test --filter RecallBenchTests` (28/28 pass, including all 5 new/patched tests); `scripts/check.sh lint` (0 lint violations, custom-lint fixture self-check green, AMI scorer self-check green, actionlint/zizmor clean) — all run twice, before and after the patch round, against the diff staged from `baseline_revision`.

**Residual risks:**
- The diarized bench arm has never actually been run against live data — its plumbing is unit-tested but its real recall number is unmeasured; this session's permission mode blocks the Keychain/config setup a run needs, independent of whether a key exists on the machine.
- AC4's 16/19 path is blocked on Story 4.14 landing on `origin/main`; the maintainer should rebase this work onto `origin/main` once that happens and re-check before treating the stop condition as open or closed.
- The full pipeline's 14/19 vs the un-diarized bench's 10/19 (twice) on byte-identical transcript text, empty glossary, empty attendee context, and identical `SummarizerConfig` defaults is explained: `ClaudeSubstringSummarizer.swift:191-201` never sets `temperature` in the Messages API request, so every summarization call in this codebase samples at the API default of 1.0 (see findings doc). Three runs of byte-identical input spanning 10/19 to 14/19 means a single recorded full-pipeline run cannot certify 16/19 as a stop condition — this is a methodology question for the maintainer, not fixed here.
- The four deferred findings are all in `Sources/RecallBench/RecallBenchFixtureLoader.swift`'s diarized-load path and are all reachable only via malformed or hand-edited fixture data — a real risk given this exact story's workflow involves hand-copying fixture directories, but none is reachable via the app's own artifact writers today.
