# Epic 4 exit criteria: results

Aggregates only, under opaque labels. No transcript text, no quotes and no titles. The recordings are private and are never committed. Written by hand from the output of `Tests/scripts/run-epic4-exit-criteria.sh`.

## Status

**Part B has been run and did not meet the criteria.** Epic 4 exits when the last line below reads "Epic 4 exit criteria met" and Part A (`Tests/IntegrationTests/PipelineEndToEndTests.swift`) is green. The pass rate is 26.3% against a floor of 80%. Cost is well inside its ceiling.

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

Two causes, in order of size.

**The summarizer did not produce the expected items.** fixture-5 produced no action items and no decisions at all against 3 expected. fixture-2 produced no action items against 4 expected, though it did produce 4 decisions. fixture-4 produced 2 action items, neither overlapping either expected action item. This is the pipeline's own recall, not a fixture artifact: replaying the same notes with a perfect choice of match fragment puts the ceiling at 8 of 19, or 42.1%, still short of 80%. The regression suite measures the same thing independently and agrees, at 42.1% item recall across the five meetings.

**The match fragments were taken from the wrong end of their quotes.** The run scored 26.3% rather than that 42.1% ceiling because `exit-fragments.json` drew several fragments from the middle of the reference quote, while the summarizer quotes the opening of a passage. fixture-1 is the clear case: it identified all three expected action items, with item text nearly matching the curated wording, and scored zero because each fragment started after the point where the model's quote stopped. The fragments have been rewritten to start at the beginning of their quote; replaying them against this run's notes yields 42.1%. That replay is not a recorded result. A rerun is needed to observe it.

## What would move the pass rate

The gap between 42.1% and the 80% floor is summarization recall on meeting audio, not scoring mechanics. Nothing in the fixtures or the scoring can close it.
