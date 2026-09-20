---
title: 'Run verb state guards (Epic 4 retro F3, F4, F6 cost)'
type: 'bugfix'
created: '2026-09-20'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `auricle run --from/--only` can start a stage from a state that stage cannot follow, and the `started` transition is unguarded. Re-transcribing rewrites `diarization.json` but leaves `attribution.json` and `diarization_suggestions.json` from the old diarization. A re-run of review overwrites a paid review's cost with 0 and `flag_off`.

**Approach:** Reject impossible starts in `RunPlan` and in `PipelineRunner` before each stage, and pass `expectedState` on the `started` transition. `DiarizeStage` clears the dependents of `diarization.json` when it rewrites it. Review reuses a real existing suggestions file instead of overwriting it, and telemetry never lowers a recorded review cost.

</frozen-after-approval>

## Implementation Notes

- F3 and F4 re-verified against the cited lines; both hold. The F6 cost item holds too.
- Entry states live in `RunStage.entryStates`. `PipelineRunner` re-reads the state before every stage, so a stage that leaves the meeting elsewhere stops the run. In-process stages pass what they read as `expectedState` on `started`. Subprocess stages have the read only, because the worker process owns its own `StageRunner`.
- `DiarizeStage` removes `attribution.json` and `diarization_suggestions.json` before it rewrites `diarization.json`. A re-transcribe therefore discards a saved attribution draft.
- Review keeps a real suggestions file (`reviewed_segment_count > 0`). Stubs are rewritten. Telemetry cost never drops and a second paid review adds to it.
- The end-to-end test attributes between two runs: a mapping cannot precede the diarization it names.
- Review layers skipped: no subagent review ran; `make check` passed.
