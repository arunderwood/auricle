# Story 4.15: summarizer under-production on ES2002b and ES2004a

Numbers and rule characterizations only, per the same discipline as
`prompt-arm-results.md`: the notes each bench run produced hold real AMI
meeting content and stay in the gitignored
`Tests/fixtures/recall-bench-output/<timestamp>/`, never here. The short
quoted phrases below are the same ones already load-bearing in
`Tests/regression/ami/reference/es2004a/expected.json`'s own `quote` fields
and `notes`, which are committed; nothing here goes further than that file
already does.

## AC1 — the diff, cached transcripts to fixed transcripts

Source: `Tests/fixtures/recall-bench-output/2026-09-21-handoff-from-research/`
(gitignored), comparing the offline recall bench's `substring` control arm over
the app's cached (gate-on) WhisperKit transcripts against the same arm over the
fixed (gate-off, PR #104) transcripts, two runs. All utterances `Speaker_1`.

| meeting | cached | fixed run1 | fixed run2 | note |
|---|---:|---:|---:|---|
| ES2002a | 3/3 | 3/3 | 3/3 | no change |
| ES2002b | 5/8 (act 3/4, dec 2/4) | 2/8 (act 0/4, dec 2/4) | 3/8 (act 1/4, dec 2/4) | action items collapse; decisions steady |
| ES2003a | 1/1 | 1/1 | 1/1 | no change |
| ES2003b | 3/4 | 4/4 | 3/4 | improves in run1 |
| ES2004a | 1/3 | 0/3 | 0/3 | already worst, stays worst |

Not a uniform "more text, fewer items": the loss concentrates in ES2002b's
action items (its "Action Items" section is empty in both fixed runs,
confirmed by reading the notes directly) and in ES2004a, already at zero;
ES2003b moves the other way.

## AC2 — ES2004a's 3 expected items, characterized

Against `Tests/regression/ami/reference/es2004a/expected.json` and both
transcript sources (hand-verified against the actual transcript text, not
inferred from the score):

1. **Budget-sharing action item** ("[PM] will make the project budget figures
   available ... in the shared folder"). A close paraphrase of the reference
   quote is present in both transcript sources. Extracted on the shorter
   cached transcript (grounded on a nearby line, "I think I'd be able to pull
   it up or put it in the shared folder"); dropped on both longer
   fixed-transcript runs despite the same line surviving there too (as "I'd be
   able to pull it up"). Never discarded — no ungrounded-quote entries for it
   anywhere. A longer-context effect, not a missing-text one.
2. **"Everyone works on their own task during the half hour before the next
   meeting."** The quote ("we've got half an hour before the next meeting, so
   we're all gonna go off and do our individual things") is present
   near-verbatim in every transcript source and gets folded into the note's
   summary prose every time — never extracted as a discrete action item, on
   cached or fixed. No named individual owner; reads as a closing announcement
   rather than an assignment.
3. **"Multiple languages are not a key point of the design" decision.** Its
   quote was one of the windows the first-token gate dropped from the cached
   transcript (absent there entirely — grep confirms). Present verbatim in the
   fixed transcript. Still never proposed there either. A terse, one-line
   ruling with no decision-marking language ("we decided", "we agreed").

All three are **never-proposed**, not proposed-and-discarded, on every
transcript source tried so far.

## Flagged for the maintainer, not fixed by this story

**The Epic 4 AC3 premise does not match what `SummarizeStage` does today.**
The AC's stated reason for a diarized bench arm is that the pipeline "never
runs" a `Speaker_1`-only summarization condition. `SummarizeStage+Inputs.swift`
and `SummarizeStage.swift` show the opposite: `orchestrator.summarize` is
always given the raw `transcript.json` WhisperKit wrote (`Speaker_1` for every
utterance); `attribution.json`/`diarization.json` are joined only into
`SummaryArtifactMapper.transcriptSegments`, for the published note's metadata,
never into the prompt. **Production always runs the `Speaker_1`-only
condition, today, unconditionally.** The diarized bench arm added by this
story is still worth having — it tests whether per-speaker context is a real
recall lever the team hasn't tried — but it tests a hypothetical pipeline
change, not today's pipeline. This story does not change `SummarizeStage` to
route diarized text into summarization; that is a larger, separate change.

**A second, related gap:** the offline bench (`RecallBenchVerb`/
`Sources/RecallBench`) never passes attendee names into the prompt at all (no
`attendee` reference anywhere under either path), while a full pipeline run
may carry real attendee names from calendar enrichment or `--speakers`. This
is a second, undocumented bench/pipeline divergence, unrelated to
diarization.

## Why the full pipeline (14/19) beats the un-diarized bench (10/19, twice) on the same text

The 2026-09-21 full-pipeline-with-fix run and the offline bench's two
gate-fixed runs summarize the *same* transcript text — confirmed by a direct
byte comparison of `transcript.json`'s `text` field for ES2002b between the
bench's shadow root and the real run's cache (`ea91c672d19f...` vs
`5679bb837155...` file hashes differ only because of JSON formatting; decoded
`text` is `==`, 37,692 characters both sides, 667 utterances both sides) — yet
the full pipeline recalls 14/19 against the bench's 10/19 on two independent
runs. Three candidate explanations were checked directly against the real
run's own cache artifacts, not assumed:

- **Glossary.** `App/auricle-cli/Verbs/RecallBenchVerb.swift` never passes a
  `glossary:` argument to `RecallBenchRunner.run`, so it defaults to an empty
  `Glossary()`. The real pipeline scopes the actual vault glossary
  (`InternalStageWorker.vaultGlossary`, `SummarizeStage+Glossary.swift`'s
  `scopeAndRecordGlossary`) — but the cached `glossary.json` for both ES2002b
  and ES2004a's real run is `{"concepts": [], "people": [], "projects": [],
  "uncategorized": []}`, empty on every category. Ruled out: both sides passed
  an empty glossary.
- **Attendee names.** `SummarizerConfig.attendeeNames` comes from calendar
  enrichment (`enrichment.match?.attendeeNames ?? []`); the cached
  `calendar.json` for both meetings reads `{"degraded": true}` — no match, so
  the real run's attendee names were empty too, same as the bench's default
  `SummarizerConfig()`. Ruled out.
- **SummarizerConfig defaults (model, effort, cost ceiling).** The real
  pipeline's composition root (`InternalStageWorker.swift:134`,
  `summarizeDependencies`) constructs `SummarizerConfig()` with no overrides —
  the identical bare initializer `RecallBenchVerb.swift:73` uses. Ruled out.

With transcript text, glossary, attendee context and config all confirmed
identical, the two summarizer calls build byte-identical prompts. The
explanation is not a hidden input: `ClaudeSubstringSummarizer.swift:191-201`
(`buildRequestBody`) sends `model`, `max_tokens`, `output_config` and `system`
in the Messages API request body and never sets `temperature`. Every
summarization call this codebase makes therefore samples at the API's default
temperature of 1.0, on both the bench and the full pipeline, on every arm
Story 4.13 and this story ran. `ClaudeCitationsSummarizer` and the rest of
`Sources/ClaudeSummarizer` and `Sources/SummarizerInterface` carry no
`temperature` reference either — this is not a substring-arm-specific gap.

**Consequence.** Three samples of byte-identical input (the two bench runs
plus the full pipeline) scored 10, 10 and 14 of 19 — a 4-item spread at
temperature 1.0, not evidence of a missing input. Story 4.13's own read of its
data — "Sampling variance is about one item, bounded by run 2's control
(12/19) against the independent Part B re-score (11/19)" — rested on a single
pair of runs. A single recorded full-pipeline run cannot certify 16/19 as a
stop condition when three runs of the same input already span four items;
whatever the true mean recall is, one run's number is not distinguishable from
noise at this sample size. Changing `temperature` or amending the stop
condition's single-run methodology are both maintainer decisions, not made
here.

## Dependency on Story 4.14

This story's stop condition (16/19 on a recorded full-pipeline run) needs
Story 4.14's recorded `history.jsonl` row and raised `min_item_recall`. As of
this writing, `origin/main` carries the gate fix itself
(`firstTokenLogProbThreshold: nil`, PR #104) but not the retention metric
(`dropped_reference_fraction` / `max_dropped_reference_fraction`) or the
recorded Part B rerun under the promoted prompt — `thresholds.json` still
reads `min_item_recall: 0.35` and `history.jsonl` carries no row past
2026-09-21. Until that lands, "16/19 on a recorded full-pipeline run" cannot
be produced from this worktree.

## AC3 — the diarized bench arm

`Sources/RecallBench/RecallBenchFixtureLoader.swift` now takes a `diarized`
flag: when `diarization.json` and `attribution.json` sit beside a fixture's
`transcript.json`, they are joined via `UtteranceSpeakers.resolve` (the same
join the attribution sheet uses) and the transcript is rebuilt via
`CanonicalTranscriptBuilder.build` with the resolved per-utterance speaker
labels in place of the placeholder. A fixture missing either file falls back
to the transcript as written, so a mixed repo root still loads.
`App/auricle-cli/Verbs/RecallBenchVerb.swift` exposes this as `--diarized`.

The arm's fixture data — `transcript.json` (WhisperKit, gate-fix,
`Speaker_1`-only as written), `diarization.json` and `attribution.json` for
all 5 AMI meetings from the 2026-09-21 `full-pipeline-with-fix-report.txt`
run's cache — is staged as a gitignored "shadow root" at
`Tests/fixtures/recall-bench-output/2026-09-21-diarized/`, holding its own
`Tests/regression/ami/{manifest.json,score.py,thresholds.json}` and
`reference/<id>/` fixtures, per the same pattern the 2026-09-21 research
session's `shadow-root-*/` directories used. `attribution.json`'s `speakers`
map is the identity map (`Speaker_N` to itself) for every meeting — no human
named the speakers on this run — so the arm's per-speaker labels are still
`Speaker_1`..`Speaker_5`, just no longer collapsed onto one placeholder.

**Run, 2026-09-22, one arm, live:** `Tests/scripts/run-recall-bench.sh
--repo-root .../2026-09-21-diarized --arm substring --diarized` —

| meeting | un-diarized (run1/run2) | diarized |
|---|---:|---:|
| ES2002a | 3/3 / 3/3 | 3/3 |
| ES2002b | 2/8 / 3/8 (act 0-1/4) | **6/8 (act 4/4)** |
| ES2003a | 1/1 / 1/1 | 1/1 |
| ES2003b | 4/4 / 3/4 | 4/4 |
| ES2004a | 0/3 / 0/3 | 0/3 |
| **total** | **10/19 / 10/19** | **14/19 = 74%** |

Matches the full pipeline's 14/19 exactly, item for item on the meetings that
moved: ES2002b's action items go from 0-1/4 to 4/4 kept, the same recovery the
full pipeline showed over the un-diarized bench. This is one run, not three —
consistent with a real diarization effect (a plausible mechanism: with every
utterance labelled identically, the model may struggle to bind a commitment to
a distinct owner) but not distinguishable from a favorable roll of the
temperature-1.0 variance documented above without repeat runs. ES2004a stays
at 0/3 regardless of diarization, holding the AC2 finding: its three items are
never proposed on any transcript source or labelling tried so far.

New observation, not present on any prior arm: 4 ungrounded quotes this run
(0 on every un-diarized arm). Not investigated further — recorded as a data
point for whoever runs the next arm, not a blocker.

## Stop condition (amended)

Given the confirmed temperature-1.0 variance above, the maintainer amended the
stop condition: **16/19 as the median of three recorded full-pipeline runs
under the same revision**, not a single run — Story 4.14 is adding the median
to `report()` and recording the two further runs. The same bar applies to any
bench arm before it is claimed to move recall: three bench runs, median
reported. This story's diarized arm has one bench draw (14/19), not three, so
it does not itself demonstrate a recall change — it sits inside the 10-to-14
spread already seen on byte-identical input.

Not met, under either the amended condition or the fixture-ruling path. Per
the spec's Never constraint, this story does not pick a reading: it does not
fabricate a recorded median, and it does not write a fixture ruling into
`expected.json`'s notes on its own authority. Two paths remain open:

1. Three full-pipeline runs recorded to `history.jsonl` under the same
   revision, median computed, once Story 4.14 lands its retention metric,
   rerun, and the median-of-three `report()` change.
2. The maintainer rules that ES2004a's three items leave the fixture, with
   the rationale written into `expected.json`'s `notes` field verbatim —
   unaffected by the above, since ES2004a scored 0/3 on every arm tried,
   diarized included.
