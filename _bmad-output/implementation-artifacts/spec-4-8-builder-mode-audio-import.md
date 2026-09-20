---
title: 'Story 4.8: Builder-Mode Audio Import (`auricle __internal-import`)'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'oneshot'
baseline_revision: '7b26bba02dadbc3f2386d92dd5fa46081934f1b8'
review_loop_iteration: 0
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 4's pipeline needs real recordings before Epic 5's capture exists, and Story 4.10's live gate needs a supported way to register one.

**Approach:** A hidden `auricle __internal-import <audio-file> [--started-at <ISO 8601>] [--title <text>]` verb converts the file to PCM 16-bit 16 kHz mono WAV, writes it to the meeting's cache directory, registers a `captured` meeting, and prints the id. Logic lives in `Sources/Capture/AudioImporter.swift`. The argument type lives in `Sources/Orchestrator/CLIVerbArguments.swift`. `App/auricle-cli/Verbs/ImportVerb.swift` is a thin wrapper. The acceptance criteria in `epics.md` Story 4.8 are the full contract.

</frozen-after-approval>

## Implementation Notes

Decisions made at planning time:

- The verb opens the store with `StateStore.subprocess()`, like every other CLI entry. It never migrates, so the GUI must have created the database once. A missing database exits 1 with a message that says so.
- Audio is finalized on disk before the row is written. Any failure after the cache directory exists removes that directory. A failure between the row insert and the `capture` event leaves a `captured` row with valid audio, so the audio stays.
- `Capture` gains no new dependency: it already depends on `Core`, `State` and `Telemetry`. AVFoundation is a system framework.
- The `capture` event's metadata is `{imported, source_format, audio_duration_s}`, encoded by a new `ImportedCaptureMeta` in `Sources/Capture`. `CaptureMeta` in `Telemetry` stays an empty placeholder because the real capture story owns its shape.
- `Package.swift` -- `CaptureTests` gains `Core`, `State`, `Telemetry` and GRDB so the tests can use an in-memory store.
- An input-block read at end of file throws in `AVAudioFile`, so the reader checks the frames left before each read.
- No `tuist generate` was needed: `Capture` was already linked into both app targets and `Project.swift` is unchanged.
- `sprint-status.yaml` is not touched, per AGENTS.md: this spec's `status` is the record.

## Review Triage Log

- medium, patched: a failed `capture` event after the row insert printed no id. Now `AudioImportError.eventNotRecorded(id)` names the meeting.
- low, rejected: `ImportVerb` has no test of its own. It is thin by design and its flags are covered by `ImportArguments` tests.
- low, rejected: the cache directory is not 0700. `CacheArtifactWriter` creates directories the same way, and the audio file is 0600.
- low, rejected: the `--started-at` fallback can be a copy date. The story specifies the creation-date fallback.
- false: `.inputRanDry` could spin the convert loop. The input block only ever returns data or `.endOfStream`.
- maybe-false, rejected as low: whole audio is held in memory (about 115 MB per hour, twice). Acceptable for a builder-mode verb.
- Format coverage: an AAC m4a test was added.
