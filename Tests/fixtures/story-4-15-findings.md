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

Running `Tests/scripts/run-recall-bench.sh --repo-root
<absolute path>/Tests/fixtures/recall-bench-output/2026-09-21-diarized --arm
substring --diarized` spends live Anthropic API credit and needs a Keychain
API key this environment does not have; the maintainer runs it and records
the result here or in a further gitignored output directory, per the "one arm
per finding" task.

## Stop condition

Not yet met. Per the spec's Never constraint, this story does not pick a
reading: it does not fabricate a 16/19 recorded run, and it does not write a
fixture ruling into `expected.json`'s notes on its own authority. Two paths
remain open, both requiring a live Anthropic call this environment cannot
make (no Keychain access) and, for the first, Story 4.14's still-unlanded
retention metric and recorded rerun:

1. Run the diarized arm above (and any other single-variable arm the
   findings motivate) through the bench, then a full-pipeline run once Story
   4.14 lands, and record whichever reaches 16/19.
2. The maintainer rules that ES2004a's three items leave the fixture, with
   the rationale written into `expected.json`'s `notes` field verbatim.
