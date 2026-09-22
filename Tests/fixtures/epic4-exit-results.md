# Epic 4 exit criteria: results

Aggregates only, under opaque labels. No transcript text, no quotes and no titles. The recordings are private and are never committed. Written by hand from the output of `Tests/scripts/run-epic4-exit-criteria.sh`.

## Status

**Part B has been run and did not meet the criteria.** Epic 4 exits when the last line of a run reads "Epic 4 exit criteria met" and Part A (`Tests/IntegrationTests/PipelineEndToEndTests.swift`) is green. The run scored 26.3% against a floor of 80%. Re-scoring the same notes under the amended scorer (Story 4.12) gives 57.9%, still short. Cost is well inside its ceiling.

## Run

- Run at: 2026-09-21T00:52Z
- Revision: `74a3d80c790a3d89548017f545c7ec165a4373fa`
- `diarization_review.enabled`: false (ceiling $0.50 per meeting)
- Fixture set: 5 recordings (5 with 4 or more attendees), the public AMI meetings from `Tests/regression/ami`, built by `Tests/regression/ami/prepare-exit-fixtures.sh`. No 1:1 is required: it is deferred beyond Epic 4.

## Per fixture

```
fixture-1: vault note written · grounding_method=substring · kept 4 items (3 expected) · drop count 0 · cost $0.0520
fixture-2: vault note written · grounding_method=substring · kept 4 items (8 expected) · drop count 0 · cost $0.1019
fixture-3: vault note written · grounding_method=substring · kept 1 items (1 expected) · drop count 0 · cost $0.0376
fixture-4: vault note written · grounding_method=substring · kept 6 items (4 expected) · drop count 0 · cost $0.0982
fixture-5: vault note written · grounding_method=substring · kept 0 items (3 expected) · drop count 0 · cost $0.0397
```

Every fixture produced a vault note at a `FilenameResolver`-shaped path with schema-valid frontmatter, every kept item carried a quote that matched the transcript literally, `verified_at` stayed NULL, and no item was dropped by quote validation. Worst per-meeting cost $0.1019 against the $0.50 ceiling; total $0.3294 over 5 fixtures.

## Result

```
Epic 4 exit criteria not met: pass rate = 26.3%
```

## Why it failed

Two causes, in order of size. The 42.1% below is wrong for this run; "Corrected baseline" further down says why and gives the right figure.

**The summarizer did not produce the expected items.** fixture-5 produced no action items and no decisions at all against 3 expected. fixture-2 produced no action items against 4 expected, though it did produce 4 decisions. fixture-4 produced 2 action items, neither overlapping either expected action item. This is the pipeline's own recall, not a fixture artifact: replaying the same notes with a perfect choice of match fragment puts the ceiling at 8 of 19, or 42.1%, still short of 80%. The regression suite measures the same thing independently and agrees, at 42.1% item recall across the five meetings.

**The match fragments were taken from the wrong end of their quotes.** The run scored 26.3% rather than its own quote-test ceiling because the fragment table drew several fragments from the middle of the reference quote, while the summarizer quotes the opening of a passage. fixture-1 is the clear case: it identified all three expected action items, with item text nearly matching the curated wording, and scored zero because each fragment started after the point where the model's quote stopped. Story 4.12 retired fragments altogether; the exit script now calls `score.py`, whose word-overlap test does not depend on where in a quote the model started.

## Re-score of this run under the amended scorer

**This is a re-score of the 2026-09-21T00:52Z run at `74a3d80c790a3d89548017f545c7ec165a4373fa`, not a new run.** Nothing was re-transcribed and no Anthropic credit was spent. The five notes that run left in the scratch vault were read again and scored by `Tests/regression/ami/score.py` as amended by Story 4.12, which counts an expected item as recalled when its quote overlaps a note block quote **or** its item text overlaps a kept item's text at `item_text_overlap` (0.55), and which counts a kept item matching no expected item either way as a false keep.

Re-scored at: 2026-09-20, by `Tests/regression/ami/score.py` as of the commit that adds this section.

### Corrected baseline

The "Why it failed" section above states 42.1% as this run's item recall. That number is not this run's. It is the total of `Tests/regression/ami/history.jsonl`, which holds four meetings from revision `4e40120f` and only fixture-5 from `74a3d80c`. Scored by the pre-amendment `score.py`, this run's own five notes give **7 of 19, or 36.8%**. That is the figure the re-score below should be read against.

### Numbers

```
label       kept  expected  recalled  false keeps
fixture-1      4         3         3            1
fixture-2      4         8         4            0
fixture-3      1         1         1            0
fixture-4      6         4         3            3
fixture-5      0         3         0            0
total         15        19        11            4
```

- Item recall: **11 of 19, or 57.9%** (was 7 of 19, or 36.8%, on the quote test alone).
- False keeps: **4 of 15 kept items.** Nothing measured this before; it is the baseline `max_false_keeps` is set above.
- The exit script and the regression suite now return the same 11 of 19 over these notes. Before Story 4.12 they returned 26.3% and 36.8%.

### The eight kept items the quote test missed

Of the 15 kept items, 7 matched an expected item by quote. The remaining 8 are classified below. The first column is the note's own ordering inside that section. Numbers are the best word-overlap score against any expected item in the same section: `q` on the quote, `t` on the item text.

```
label      section        #   q      t      verdict
fixture-1  Decisions      1   0.000  0.000  false keep
fixture-2  Decisions      2   0.176  0.682  same item, different passage
fixture-4  Action Items   1   0.333  0.632  same item, different passage
fixture-4  Action Items   2   0.231  0.263  false keep
fixture-4  Decisions      1   0.444  1.000  same item, different passage
fixture-4  Decisions      2   0.250  0.267  false keep
fixture-4  Decisions      3   0.211  0.583  same item, different passage
fixture-4  Decisions      4   0.125  0.250  false keep
```

Four are the right item supported by a different sentence of the same discussion. Four are real keeps that match no expected item. The four false keeps are grounded — each quote is literally in the transcript — and each is a plausible item that the reference curator deliberately left out as floated, unassigned, or handed to the group from outside. They are not fabrications. They are the precision cost of the summarizer's current output, and until now nothing counted them.

fixture-4 Decisions #1 is the clearest single case for the amendment: its item text matches the expected item exactly (t = 1.000) while its quote scores 0.444, just under the 0.5 floor, because the model quoted the conclusion of the exchange and the curator quoted its opening.

### A scoring correction cannot close the gap

**The summarizer kept 15 items against 19 expected, so even perfect alignment between the two sets caps recall at 15 of 19, or 78.9% — below the 80% floor.** The remaining gap is output volume, not matching. fixture-5 kept nothing at all against 3 expected, and fixture-2 kept no action items against 4 expected. Story 4.12 measures the right thing; it does not move the bar and it does not reach it. Story 4.13 is where recall is meant to move.

## What would move the pass rate

The gap between 57.9% and the 80% floor is summarization recall on meeting audio. Scoring mechanics accounted for 21.1 points of it and are now spent. Nothing further in the fixtures or the scoring can close what is left.
