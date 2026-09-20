# Epic 4 exit criteria: results

Aggregates only, under opaque labels. No transcript text, no quotes and no titles. The recordings are private and are never committed. Written by hand from the output of `Tests/scripts/run-epic4-exit-criteria.sh`.

## Status

**Part B has not been run.** Epic 4 exits when the last line below reads "Epic 4 exit criteria met" and Part A (`Tests/IntegrationTests/PipelineEndToEndTests.swift`) is green.

## Run

- Run at: _not run_
- Revision: _not run_
- `diarization_review.enabled`: _not run_
- Fixture set: _N_ recordings (_n_ 1:1, _n_ with 4 or more attendees). Changing the set needs a rationale in the PR description.

## Per fixture

```
fixture-1: vault note written · grounding_method=substring · kept N items (M expected) · drop count K · cost $X
```

## Result

```
Epic 4 exit criteria met: pass rate Y%, total cost $Z over <N> fixtures
```

Ceilings: at least 80% of expected action items and decisions survive grounding; per-meeting cost at most $0.50 with `diarization_review.enabled = false`, $0.60 with it `true`.
