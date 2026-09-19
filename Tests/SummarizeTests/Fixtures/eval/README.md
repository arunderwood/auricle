# Eval fixtures

Frozen meetings that `SummarizeEvalHarness` runs through the summarize pipeline on every test run.

## Adding a fixture

1. Make a directory here named for the meeting.
2. Put a `transcript.json` (a `CanonicalTranscript`) and an `expected.json` in it.
3. Add the fixture to `NOTICE.md` with its source and license.

No Swift changes. The harness and `EvalFixtureContractTests` both run every directory that has a `transcript.json`.

## expected.json

- `action_items` and `decisions` are lists of `text`, `quote`, `transcript_start` and `transcript_end`. The offsets are UTF-8 byte offsets, the end is exclusive, and the quote sits inside one utterance, after its `Speaker_N: ` label.
- `targets` is optional, and so is each key in it. A missing key takes the project default.

| Key | What it limits | Default |
| --- | --- | --- |
| `min_recall` | Smallest share of expected items that must survive grounding | 0.8 |
| `max_false_keeps` | Most kept items that match no expected item | 1 |
| `max_drop_rate` | Largest share of expected items the validator may drop | 0.2 |

The stubbed runs require every expected item to be kept and shown in the note, so the targets bound only the scorer's tolerance.

## What it measures

The harness answers every model call with a canned response built from `expected.json` alone. The real strategies, validators, orchestrator, artifact mapper and note renderer all run on it. It never reads the prompt, so a prompt change cannot move a result.

That makes it a regression check on the validators, the grounding-to-artifact mapping and the renderer. It says nothing about whether a prompt got better or worse; compare prompts with the strategy comparison rig instead.

Each run prints one line:

```
Fixture <name>: kept N items (M expected) · dropped K · false-keeps F · grounding_method=<method>
```

The substring runs also send one invented item per section that the transcript cannot support. Those must be dropped, so `dropped` is at least 2 there.

## Changing a target or an expected item

A change to a `targets` value or to an expected item needs a stated reason in the pull request description. Say why the new value is right. A run that now fails is not a reason to loosen a target.
