---
title: 'Story 4.13: Prompt Recall Pass'
type: 'feature'
created: '2026-09-21'
status: 'done'
status_detail: 'Arms run and recorded; the winning arm is promoted. The story ends at its maintainer decision gate, and the gate itself needs amending: the run disproved the premise the gate was written on. Transcription, not summarization, is what holds Epic 4 below 80%.'
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
  '{project-root}/_bmad-output/planning-artifacts/sprint-change-proposal-2026-09-20.md',
  '{project-root}/Tests/fixtures/prompt-arm-results.md',
]
---

## Intent

Iterate the summarization prompt against Story 4.11's bench until item recall
clears 80%, or stop at the maintainer decision gate.

## Outcome

The prompt work succeeded and the gate is still not met, because the gate is not
bounded by the prompt.

| arm | reference transcripts | WhisperKit output |
|---|---:|---:|
| control (prompt shipped before this story) | 15/19 = 79% | 12/19 = 63% |
| `sections-independent` (promoted) | **16/19 = 84%** | **14/19 = 74%** |

Full numbers, per section and per meeting, in `Tests/fixtures/prompt-arm-results.md`.

## What was done

- **Per-section reporting first.** `score_note` reported only totals, and the
  two sections fail in opposite directions — 6 action items produced against 12
  expected, 9 decisions against 7. An arm that moved items between them would
  have held the total flat and read as no change. This is a prerequisite for
  measuring anything here, not a reporting nicety; it was raised by the Story
  4.11 session during review.
- **Three arms, each a single-variable `system.md` diff.** `sections-independent`
  adds a rule that the two lists are built independently. `action-coverage`
  makes rule 5 asymmetric: cover every action item, keep the precision bar for
  decisions. `both` combines them.
- **Two bench runs.** Run 1 over the committed reference transcripts. Run 2 over
  the WhisperKit transcripts the 2026-09-21 Part B run left in the cache, with
  prompt, expected items and scorer held fixed so transcript source was the only
  variable.

## Findings

**Transcription is the binding constraint.** The same prompt loses 2 to 3 items
of 19 between a reference transcript and the pipeline's own WhisperKit output of
the same audio. That output is 14% to 34% shorter than the reference — missing
text, not substitution noise. An item whose only statement was never transcribed
cannot be extracted by any prompt. Sampling variance is about one item, bounded
by run 2's control (12/19) against the independent Part B re-score (11/19).

**Three hypotheses from the sprint change proposal were wrong**, and are
recorded here so they are not retried:

- Rule 2's exclusion of "targets handed to the group from outside" was not
  suppressing ES2002b's decisions. The control kept all four.
- Long-input truncation was not the cause. ES2002b's four decisions sit at 83%
  to 92.5% of the transcript, the same passage as its missed action items.
- Rule 1's "after this meeting" wording was not the discriminator. ES2002a and
  ES2002b state the same closing-assignment construct in near-identical words
  and the model handled them differently.

**`action-coverage` priced the precision trade.** It reached the best
action-item recall of any arm, 11/12, for 10 false keeps against the control's
3. Worth knowing; not worth shipping. `both` was worse than either half alone.

## The promoted arm

`sections-independent` replaces `Sources/Summarize/Prompts/summarize/system.md`.
It wins on both transcript sources, costs no more than the control, and leaves
action-item false keeps at the control's level.

**Story 4.13's own promote-condition was not met** — that condition is an arm
reaching 80% on the bench, and 84% holds only on reference transcripts, which
are not what the pipeline produces. The arm is promoted anyway on the narrower
claim that it is better than the control on every measure taken. The gate is a
separate question and stays open.

`min_item_recall` is left at 0.35. Raising it needs a recorded full-pipeline
regression run under the promoted prompt; `history.jsonl` has none.

## The decision gate needs amending

The gate in `epics.md` offers, for the 65-79% band, a choice between a
multi-pass amendment and moving Story 4.10's floor. **The multi-pass option is
disproven.** It was written while the gap was believed to be summarizer recall.
A second summarization pass cannot recover text that is absent from the
transcript, and the summarizer already clears 80% when the text is there.

The PRD names the response that fits the actual finding: "If WhisperKit
transcription is inadequate, the Parakeet-TDT alternate ASR path is the next
step" (`prd.md:426`).

So the open choice is between pursuing that ASR path and moving Story 4.10's
floor to what the pipeline achieves, about 74%.

## Boundaries & Constraints

- FR32 holds throughout: every arm makes one primary Claude call per meeting.
  No arm was multi-pass.
- Arm prompt directories live under `Tests/fixtures/prompt-arms/`. Each is
  `system.md` only; the builder falls back per file, so the substring addendum
  is the shipped one in every arm.
- Rendered notes hold real meeting content and are written to the gitignored
  `Tests/fixtures/recall-bench-output/`. Only numbers are committed.

## Code Map

- `Tests/regression/ami/score.py`: `score_note` gains eight per-section keys,
  flat, with the totals derived from them. `report` prints the split on its
  total line and says so when every row predates it.
- `Sources/RecallBench/RecallBenchScorer.swift`: `RecallBenchSectionScore`, and
  a custom `init(from:)` that groups the flat keys.
- `Sources/RecallBench/RecallBenchReportRenderer.swift`: `act` and `dec` columns,
  and a per-section breakdown on each arm's total line.
- `Tests/regression/ami/test_score.py`: pins the decoded key set and that the
  per-section counts sum to the totals.
- `Tests/SummarizeTests/Snapshots/prompts/`: regenerated for the promoted prompt.
