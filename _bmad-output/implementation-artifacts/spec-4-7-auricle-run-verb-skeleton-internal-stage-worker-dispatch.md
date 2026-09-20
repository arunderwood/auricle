---
title: 'Story 4.7: `auricle run` Verb Skeleton + `__internal-stage` Worker Dispatch'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_revision: 'eb066309fddc44e72348df23528a32be6080a2db'
route: 'dispatch'
review_loop_iteration: 0
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
warnings: [oversized]
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `auricle run` is a `notYetImplemented("run")` stub, so nothing drives a meeting through the pipeline, persist has no production caller, and the `--publish-anyway` `published_partial` path (stub `summary.json`, `needs_summary`, `auricle/needs-summary` tag) does not exist.

**Approach:** Put the run logic in `Sources/` behind a thin `RunVerb`: a pure `RunPlan` (flag validation, start stage from state), a `PipelineRunner` that dispatches `transcribe`, `review-diarization` and `summarize` as `__internal-stage` subprocesses and runs `attribute`, `persist` and `notify` in-process (AR-PIPE-1), plus the `published_partial` changes in summarize, persist, the renderer and `PipelineTransitions`. The acceptance criteria in `epics.md` Story 4.7 are the full contract.

## Boundaries & Constraints

**Always:** Logic in `Sources/`; `App/` files are thin wrappers. The CLI builds its `SubprocessDispatcher` with `resolveExecutablePath` returning `Bundle.main.executableURL`/the running binary. `meetings.verified_at` is never written. Persist gets no re-publish flag. State writes go through `StageRunner`/`StageEventLogger`; logging through `Log`; JSON dialects declared with `CodingKeys`. Flag conflicts are rejected at parse time (`RunArguments.validate`), exit 1.

**Never:** No Story 4.10 work. No change to retention timers. No `WorkerProtocolVersion` bump. No new run behavior for `verified`, `discarded`, `silent`, `recording`, `retention_expired` meetings (refused, exit 1). No persist re-publish signalling. Notify does not run for `published_partial`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Resume | `captured`, no flags | transcribe → review-diarization → attribute → summarize → persist → notify; ends `awaiting_verification`, `verified_at` NULL | Worker non-zero → stop, exit = worker code |
| Resume persist | `persist_failed` | persist, notify only | — |
| Publish anyway | `awaiting_attribution` + `--publish-anyway` | placeholder attribution, summarize (stub on failure), persist; `published` or `published_partial` | — |
| No mapping | `awaiting_attribution`, no flag | stop before attribute, exit 1, hint to `auricle attribute` or `--publish-anyway` | — |
| Permanent failure | `transcription_failed`/`capture_failed` | refuse exit 1 naming `--force` | `--force` runs from `transcribe` |
| Conflicts | `--from`+`--only`, `--to`+`--only`, `--publish-anyway`+`--from attribute`/`--only attribute`/`--reattribute`, `--reattribute`+`--from`/`--only`, `--from` after `--to` | parse-time error, exit 1 | — |
| Reattribute | `awaiting_verification`/`published`/`published_partial` + `--reattribute` | attribute from stored mapping, summarize, persist → `--rerun-` sibling | timer untouched |
| SIGINT | during summarize | child terminated, meeting `summarization_failed` (only if still `summarizing`), exit 130 | — |

</frozen-after-approval>

## Code Map

- `Sources/Orchestrator/CLIVerbArguments.swift` -- `RunArguments`; add `validate()`.
- `Sources/Orchestrator/InternalStageArguments.swift`, `SubprocessDispatcher.swift` -- add `--publish-anyway` flag, pass through `makeProcess`/`dispatch`.
- `Sources/Orchestrator/RunPlan.swift` (new) -- pure plan; `InternalStageKind` (worker coverage).
- `Sources/Pipeline/` (new target) -- `PipelineRunner`, `StageWorkerLauncher`, `SubprocessStageLauncher`.
- `Sources/Core/SummaryArtifact.swift`, `PipelineTransitions.swift` -- `needsSummary`; persist → `published_partial`.
- `Sources/Persist/{MeetingForFrontmatter,FrontmatterRenderer,PersistStage}.swift` -- `needsSummary` tag, omitted sections, `published_partial`.
- `Sources/Summarize/{SummarizeStage,SummarizeWorker}.swift`, `SummaryArtifactMapper.swift` -- stub on `--publish-anyway` failure.
- `Sources/Attribute/AttributionStage.swift` -- accept published states for `--reattribute`.
- `App/auricle-cli/Verbs/{RunVerb,InternalStageWorker}.swift` -- thin wrappers; `NotifierFactory.swift` reused.
- `Package.swift`, `App/Project.swift` -- `Pipeline` target/product/tests, CLI dependency.

## Tasks & Acceptance

**Execution:**
- [ ] Core/Persist/Summarize/Orchestrator changes above, each with tests named in `epics.md` Story 4.7.
- [ ] `Sources/Pipeline` + `Tests/PipelineTests` (runner with fake launcher: resume, subsets, force, reattribute, publish-anyway, SIGINT cancel, retry, verified_at NULL, note at vault path, rerun sibling).
- [ ] `RunVerb` wrapper with SIGINT source, exit 130.

**Acceptance Criteria:** as `epics.md` Story 4.7.

## Implementation Notes

- Decisions: `published_partial` resumes at `summarize`; explicit `--from`/`--only` beats the state-derived start; `--force` starts at `transcribe` and implies `--reattribute`; in-process stages are not interrupted mid-stage (SIGINT is honored between stages); notify does not run for `published_partial` (the runner prints the note path).
- The CLI-only `Tests/CLITests` target named in the epic does not exist; the tests live in `Tests/PipelineTests` and `Tests/OrchestratorTests`, since `App/` is outside `swift test`.

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Route / evidence |
|---|---|---|
| Explicit `--from`/`--only` bypasses the permanent-failure refusal | medium | patch: refusal now precedes explicit flags |
| `--to` before the start gives an empty plan, exit 0 | medium | patch: `toPrecedesStart` refusal |
| `attribute` accepts published states for every caller | medium | patch: opt-in `reattribute` parameter |
| Stub overwrites a good `summary.json` | medium | patch: rethrow when a complete summary exists |
| `SummarizeWorker.publishAnyway` defaulted | low | patch: required parameter |
| Second Ctrl-C cannot force-quit | low | patch: restore `SIG_DFL` after first |
| Recovery test does not read the note | medium | patch: asserts summary text, no `needs-summary` |
| Doc comment splice in `PipelineTransitions` | low | patch |
| Reattribute re-notifies and returns the meeting to `awaiting_verification` | low | false: intended flow, `verified` is refused |
| Interrupt between attribute and summarize records a failure | low | false: resume from `summarization_failed` runs summarize |
| No SIGKILL after SIGTERM grace | low | rejected: fix adds a timer branch, unlikely in everyday use |
| `--only notify` on `published_partial` is silent; notify outcome discarded | low | rejected: cosmetic |
| `WorkerProtocolVersion` not bumped | low | carried: already in `deferred-work.md` |
| `InternalStageWorker` wiring of `--publish-anyway` has no test (`App/` is outside `swift test`) | medium | defer |
