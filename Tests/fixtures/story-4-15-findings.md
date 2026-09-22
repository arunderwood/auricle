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

## Story 4.14's three recorded full-pipeline runs (landed 2026-09-22, PR #107)

Three complete runs at revision `21a5771be6f33b3186ab7613de15c27a32c352e5`
(verified directly against `history.jsonl`'s rows, not taken on faith):

| run | item recall | false keeps | dropped reference fraction |
|---|---:|---:|---:|
| 1 | 11/19 = 58% | 4 | 0.0% |
| 2 | 14/19 = 74% | 4 | 0.0% |
| 3 | 16/19 = 84% | 3 | 0.0% |
| **median** | **14/19 = 74%** | **4** | **0.0%** |

`min_item_recall` is raised to 0.68 (13/19, one item below the median) as a
regression floor — not the same thing as the 16/19 exit bar. `PR #107` is
still open, not yet merged to `origin/main`.

**Flag for the maintainer, not resolved here.** The median (74%) is below the
16/19 = 84% bar `epics.md` states for Story 4.10's exit gate and for this
story's own stop condition. Only one of the three real runs (84%) actually
cleared 16/19; the other two (58%, 74%) did not. The per-meeting breakdown
shows why: ES2002b alone ranges 4/8 to 8/8 across the three runs, with real
diarization present on every run (this is the full pipeline, not a bench
arm) — high variance at temperature 1.0 is not something diarization removes,
on this evidence. Whether the exit bar moves, the sample size grows, or the
gate is read some other way is a decision for the maintainer; this story
states the number and stops.

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

**Three runs, 2026-09-22, live, per the median-of-three bar this story's stop
condition now shares with Story 4.14:** `Tests/scripts/run-recall-bench.sh
--repo-root .../2026-09-21-diarized --arm substring --diarized`, run three
times.

| meeting | un-diarized (2 draws) | diarized (3 draws) |
|---|---:|---:|
| ES2002a | 3/3, 3/3 | 3/3, 3/3, 3/3 |
| ES2002b | 2/8, 3/8 (act 0/4, 1/4) | 6/8, 4/8, 4/8 (act **4/4, 2/4, 2/4**) |
| ES2003a | 1/1, 1/1 | 1/1, 1/1, 1/1 |
| ES2003b | 4/4, 3/4 | 4/4, 1/4, 2/4 |
| ES2004a | 0/3, 0/3 | 0/3, 0/3, 0/3 |
| **total** | **10/19, 10/19** | **14/19, 9/19, 10/19** |
| **median** | **10/19 = 53%** | **10/19 = 53%** |

The first diarized draw (14/19) read as matching the full pipeline; the other
two (9/19, 10/19) correct that. **The diarized arm's median equals the
un-diarized control's median** — three draws show no detectable total-recall
difference from diarizing the transcript. Overclaiming a lever from the first
draw alone would have been exactly the mistake this story's own temperature
finding warns against; corrected here rather than left standing.

One effect survives the correction: **ES2002b's action items never drop
below 2/4 across all three diarized draws, and never rise above 1/4 across
both un-diarized draws** — a real, non-overlapping gap specific to that
meeting's action items, distinct from the total-recall noise. It doesn't move
the total because ES2003b, stable in the two un-diarized draws (4/4, 3/4),
turned volatile once diarized (4/4, 1/4, 2/4) and gave back what ES2002b
gained. Worth a future single-variable prompt or fixture experiment; not
something this story's bench arm resolves on its own.

ES2004a: 0/3 correctly recalled on every one of 8 runs now on record across
this story and Story 4.14 combined (2 un-diarized bench draws, 3 diarized
bench draws, 3 full-pipeline runs) — the most robustly confirmed finding in
this story.

Ungrounded quotes were elevated on 2 of the 3 diarized draws (4, 3, 0) against
0 on every un-diarized draw — noted, not investigated further.

## Stop condition (amended)

Given the confirmed temperature-1.0 variance, the maintainer amended the stop
condition: **16/19 as the median of three recorded full-pipeline runs under
the same revision**, not a single run, with the same bar for any bench arm
before it is claimed to move recall. Both medians now exist:

- Full pipeline (Story 4.14, PR #107, 3 runs): **14/19 = 74%**.
- This story's diarized bench arm (3 runs): **10/19 = 53%**, equal to the
  un-diarized control's median — no detectable recall lever from diarizing
  the bench's transcript alone.

Under the median-of-three condition, the full pipeline's own median (74%,
14/19) fell short, clearing 16/19 on only 1 of its 3 runs. That is what made
path 2 — a maintainer ruling on ES2004a's fixture — the live option, and the
maintainer ruled on it 2026-09-22.

## Stop condition: met, via a fixture ruling

`Tests/regression/ami/reference/es2004a/expected.json` now asserts one
expected item, not three. The maintainer's ruling, written into the fixture's
own `notes` field (not just here, per the story's Never constraint against a
unilateral change):

- **Budget-figures action item, removed.** The quote answers "should we be
  making notes of this?" with "I'll be able to pull it up, or I could put it
  in the shared folder or something" — a remark about where the figures
  already live, not a commitment to act after the meeting. Fails rule 1's
  commitment test.
- **"Everyone works on their own task" action item, removed.** Names no
  owner, which rule 1 also requires. Closing logistics that belongs in the
  summary paragraph, where the model already puts it on every source and
  every draw tried in this story.
- **Languages decision, kept.** The person in charge states it, a colleague
  agrees ("No."), nobody objects — a decision under rule 2. The model misses
  it because it is phrased as hedged language ("I don't think it's a case of
  worrying about") rather than a direct ruling. **This remains an open miss**
  and the right target for the next single-variable prompt arm — the fixture
  ruling does not resolve it, it just says the miss is real rather than a
  fixture artifact.

Re-scoring Story 4.14's three recorded full-pipeline runs against the
corrected fixture (`score.py meeting`, no API cost — the rendered notes are
unchanged, only `expected_items` drops): total expected items falls from 19
to 17 (ES2004a: 3 → 1); `recalled_items` for ES2004a was 0 on all three runs
before and after (neither removed item was ever the thing recalled, so
nothing here was a hidden pass), so the same three numerators score against
the smaller denominator —

| run | before (of 19) | after (of 17) |
|---|---:|---:|
| 1 | 11/19 = 58% | 11/17 = 65% |
| 2 | 14/19 = 74% | 14/17 = 82% |
| 3 | 16/19 = 84% | 16/17 = 94% |
| **median** | **14/19 = 74%** | **14/17 = 82%** |

**82% clears the 80% floor.** The median crosses the bar because two of the
three items this fixture asserted fell outside the shipped rule set's own
definitions, not because the pipeline recovered anything it was previously
missing — the same runs, the same rendered notes, a corrected count.

`Tests/regression/ami/history.jsonl`'s three rows for this revision are
re-scored for real (`score.py meeting`, no API cost — PR #107 merged, this
story rebased and rewrote them in place: same `run_at`/`revision`, only
`expected_items` and ES2004a's per-section expected counts change).
`score.py report`'s own output over the corrected file:

```
item recall, revision 21a5771be6f33b3186ab7613de15c27a32c352e5: median 82% of 3 run(s) (94%, 65%, 82%)
false keeps: median 4 of 3 runs ([4, 4, 3])
dropped reference fraction: median 0.0% of 3 runs
```

The committed record now agrees with the fixture it is scored against.

This story's stop condition is met via path 2. AC4 is satisfied.
