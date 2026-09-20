---
title: 'Story 4.10: Exit-Criteria Gate (CI Pipeline Test + Live Run)'
type: 'feature'
created: '2026-09-20'
status: 'in-progress'
status_detail: 'Part A (CI pipeline test) is done. Part B (live run) awaits the maintainer: it needs private recordings, real WhisperKit and live Anthropic calls, and has not been run.'
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
---

## Intent

Epic 4 exits through two gates. Part A guards the pipeline plumbing on every PR. Part B measures the CLI on real recordings.

## Status by part

- **Part A: done.** `IntegrationTests` runs in `swift test`. It drives `PipelineRunner` with the real stage workers over stub transcriber, stub diarizer, a stubbed Anthropic endpoint, a temp vault and a temp state database.
- **Part B: awaits the maintainer's live run.** `Tests/scripts/run-epic4-exit-criteria.sh` is written and untested against real recordings. `Tests/fixtures/epic4-exit-results.md` is a blank template. The story is not `done` until that file records "Epic 4 exit criteria met".

## Boundaries & Constraints

- No recording, transcript text or title is ever committed. The reference WAV is a synthetic sine tone.
- Part A never loads WhisperKit; WhisperKit correctness belongs to Stories 4.1 and 4.2.
- Part B reads its fixtures from `$AURICLE_EXIT_FIXTURES`.

## Code Map

- `Package.swift`: `IntegrationTests` target, no path filter, passes `--explicit-target-dependency-import-check error`.
- `Tests/IntegrationTests/PipelineEndToEndTests.swift`: two scenarios (1:1 with a speaker map; four speakers with `--publish-anyway`).
- `Tests/IntegrationTests/IntegrationStubs.swift`: stubs and `InProcessLauncher`, which runs each subprocess stage's real worker in-process.
- `Tests/IntegrationTests/Fixtures/reference-tone.wav`: 10 s, 16 kHz mono, 320 KB, synthetic.
- `Tests/scripts/run-epic4-exit-criteria.sh`, `Tests/fixtures/epic4-exit-results.md`: Part B.

## Tasks & Acceptance

- [x] Part A: import through `AudioImporter`; state reaches `awaiting_verification`; note at the `FilenameResolver` path with schema-valid frontmatter; every item followed by a quote that matches the transcript literally; `verified_at` is NULL.
- [x] Part B script and results template written.
- [ ] Part B run by the maintainer; result recorded in `Tests/fixtures/epic4-exit-results.md`.

## Design Notes

- `PipelineFixture` lives in `PipelineTests`, so `IntegrationTests` cannot import it. It scripts workers with closures and an in-memory store; this gate needs the real workers and a file database, so it has its own harness.
- Part A builds the stub transcript the way WhisperKit does (every utterance `Speaker_1`), so the note's speakers can only come from the `diarization.json` join. It asserts the publish-anyway note carries `auricle/needs-attribution`.
- Part B's path check is shape-only (`YYYY-MM-DD-<slug>.md` at `meetings.vault_note_path`); the exact-name check is Part A's.
