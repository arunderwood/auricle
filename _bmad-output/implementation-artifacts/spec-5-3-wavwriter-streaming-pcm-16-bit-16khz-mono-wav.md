---
title: 'Story 5.3: WAVWriter — Streaming PCM 16-bit 16kHz Mono WAV'
type: 'feature'
created: '2026-09-22'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: []
deferred:
  - summary: >-
      WAVWriter has no Sendable/actor isolation and no lock, with no stated
      concurrency contract for how write()/finalize()/repairHeader(at:) may
      be called relative to each other.
    evidence: |-
      If true, this is medium: a data race on `bytesWritten` or the shared
      `FileHandle` under concurrent calls. Unverifiable within Story 5.3,
      which has no concurrent caller — WAVWriter is only exercised
      single-threaded from WAVWriterTests. Settled by Story 5.4's actual
      usage pattern: which task/thread CaptureStage uses to create and drive
      a WAVWriter, and whether write() can be called while finalize() or
      repairHeader() run.
    location: >-
      Sources/Capture/WAVWriter.swift
    severity: medium (unverified)
baseline_revision: '07d3c28cc0ff71d1551cdc30becb2540d9c189b0'
---

<intent-contract>

## Intent

**Problem:** `Capture` has no way to stream live PCM to disk as it arrives — `AudioImporter` only writes a complete WAV it already holds in memory, which a multi-hour live capture cannot do.

**Approach:** Add `WAVWriter`, a `FileHandle`-based streaming writer that opens `audio.wav` immediately (0600, in a 0700 cache directory), appends PCM as it is produced, and patches the RIFF/data chunk sizes on `finalize()` or, after a crash, via `repairHeader(at:)`.

## Boundaries & Constraints

**Always:** Path is `CacheArtifactWriter.cacheDirectory(for:)` joined with `AudioImporter.audioFileName`; `WAVWriter` creates that directory itself at 0700 (`cacheDirectory(for:)` only computes the path). The file is created 0600 before any sample is written (NFR-S3). The header byte layout matches `AudioImporter`'s existing 44-byte RIFF/WAVE header exactly (16kHz, mono, 16-bit) — reused, not re-derived. `finalize()` and `repairHeader(at:)` patch only the RIFF size (offset 4) and data size (offset 40). A write failure leaves the partial file on disk untouched.

**Never:** Never use `AVAudioFile` or `AtomicWriter` to write the stream (this is Decision 1.4's recorded exemption); never buffer the whole recording in memory; never delete, truncate, or clean up the partial file when a write fails. Out of scope: wiring `WAVWriter` into `CaptureSession`/`CaptureStage`, and calling `repairHeader` from crash recovery — both are Story 5.4.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Normal capture | `init` → `write(chunks)` → `finalize()` | `audio.wav` with correct RIFF/data sizes; `AVAudioFile` reads it at 16kHz/1ch with the expected frame count | No error expected |
| Disk fills mid-write | a `write()` call hits `ENOSPC` | throws `CaptureError.diskFull`; bytes already flushed remain on disk | `diskFull` |
| Non-space write failure | `FileHandle.write` throws another POSIX/NSError | throws `CaptureError.streamInterrupted(reason:)`; partial file remains | `streamInterrupted` |
| Crash before finalize | header still holds placeholder sizes, file has audio bytes | `repairHeader(at:)` patches sizes from file size and returns the recovered duration | No error expected |
| First write for a new meeting id | no cache directory exists yet | directory created at 0700, then `audio.wav` at 0600, before the first sample is written | No error expected |

</intent-contract>

## Code Map

- `Sources/Capture/AudioImporter.swift:243-270` -- `private static func wavFile(pcm:)` builds the canonical 44-byte RIFF/WAVE header (offset 4 = RIFF chunk size, offset 40 = data chunk size). `audioFileName` (line 56) = `"audio.wav"`; `sampleRate` (line 55) = `16000`. Currently file-private — `WAVWriter` cannot call it as-is.
- `Sources/Core/CacheArtifactWriter.swift:76-78` -- `cacheDirectory(for:)` only computes `~/Library/Caches/com.auricle.app/<id>/`; it never creates the directory or sets permissions (confirmed: no `attributes:` on its own `createDirectory` call at line 37, which is a different code path anyway).
- `Sources/Diarize/SnippetExtractor.swift:30` -- precedent for the exact call: `FileManager.default.createDirectory(at:withIntermediateDirectories:attributes: [.posixPermissions: 0o700])`.
- `Sources/Core/Errors.swift:14-22` -- `CaptureError` already declares `.diskFull` and `.streamInterrupted(reason:)`; no new error type needed.
- `Sources/Core/AtomicWriter.swift:35-96` -- the atomic write pattern `WAVWriter` is exempted from (Decision 1.4, `architecture.md:464`); its `try handle.write(contentsOf:)` / `try? handle.close()` idiom on failure is the shape to mirror for `WAVWriter`'s own error handling, substituting `CaptureError` cases for `AtomicWriter.WriteError`.
- `Package.swift:76` -- `Capture` target already exists (deps: `Core`, `State`, `Telemetry`, `Permissions`); `Package.swift:176-181` -- `CaptureTests` target already wired. No `Package.swift` changes needed.
- `Tests/CaptureTests/AudioImporterTests.swift:12-46` -- `ImporterFixture` pattern (temp root, injectable cache directory, UUID-scoped, `cleanUp()` in a `defer`) to follow for `WAVWriterTests`' fixture.
- `Tests/DiarizeTests/DiarizeTestSupport.swift:94-105` -- `permissions(of:)` helper and `wavSampleCount(_:)` (`(count - 44) / 2`) — reuse both idioms for `WAVWriterTests` assertions.

## Tasks & Acceptance

**Execution:**
- `Sources/Capture/AudioImporter.swift` -- widen `wavFile(pcm:)`'s header-byte-construction logic from `private` to module-internal (either raise its access level directly, or extract the offset/layout logic into a small internal helper both `AudioImporter` and `WAVWriter` call) -- lets `WAVWriter` reuse the exact 44-byte layout instead of re-deriving it, satisfying the AC's "the WAV header code that `AudioImporter` already has."
- `Sources/Capture/WAVWriter.swift` (new) -- implement `WAVWriter`: `init(meetingID:)` creates the 0700 cache directory (`SnippetExtractor.swift:30`'s pattern) and the 0600 `audio.wav` before any write, opens a `FileHandle`, and writes a placeholder 44-byte header; `write(_ samples: Data) throws` appends PCM bytes through the handle and tracks total bytes written; `finalize() throws` seeks to offsets 4 and 40 and patches the RIFF/data chunk sizes from the tracked byte count, then closes the handle; `static func repairHeader(at: URL) throws -> TimeInterval` reopens a file, computes `dataSize = fileSize - 44`, patches the same two offsets, and returns the recovered duration (`dataSize / 2 / sampleRate` seconds) -- the streaming, patch-after-the-fact counterpart to `AudioImporter`'s all-at-once write.
- `Sources/Capture/WAVWriter.swift` -- map a `FileHandle.write` failure to `CaptureError.diskFull` when the underlying error's POSIX code is `ENOSPC`, else `CaptureError.streamInterrupted(reason:)`; never delete or truncate the partial file on either path.
- `Tests/CaptureTests/WAVWriterTests.swift` (new) -- cover the I/O matrix above: header correctness after `finalize()` (`AVAudioFile` reads 16kHz/1ch/expected frame count); 0600 file existing before the first write and 0700 directory; `repairHeader(at:)` on a file whose header was never finalized; a thrown write leaves the partial file on disk with its already-written bytes intact.

**Acceptance Criteria:**
- Given a fresh meeting id with no existing cache directory, when `WAVWriter` is initialized, then the cache directory is 0700 and `audio.wav` exists at 0600 before any sample is written.
- Given a writer that has streamed N bytes of PCM, when `finalize()` runs, then the file's RIFF chunk size is `36 + N` and its data chunk size is `N`, and `AVAudioFile` reads it as 16kHz mono with `N / 2` frames.
- Given a WAV file whose header still holds placeholder sizes (simulating a crash before finalize), when `WAVWriter.repairHeader(at:)` runs, then it patches the RIFF and data sizes from the file's actual size and returns the recovered duration.
- Given a write that throws mid-stream, when the error propagates, then it is `CaptureError.diskFull` (ENOSPC) or `.streamInterrupted(reason:)`, and the partial file is left on disk exactly as it was at the point of failure.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 17 findings — high 0, medium 8, low 7, false 1, maybe-false 1
- findings:
  - `[medium]` `[patch]` (blind-hunter) `finalize()`'s `UInt32(bytesWritten)` traps instead of throwing past ~37h of audio — fix: guarded conversion, throws `.streamInterrupted`.
  - `[medium]` `[patch]` (edge-case-hunter) `finalize()`'s size conversion has no overflow guard (`WAVWriter.swift:61-64`) — same root cause, same fix.
  - `[medium]` `[patch]` (edge-case-hunter) `repairHeader(at:)`'s `UInt32(fileSize - 44)` traps on files ≥4GiB (`WAVWriter.swift:70-82`) — same root cause, same fix applied to both call sites.
  - `[medium]` `[patch]` (verification-gap, Other findings) same overflow-trap defect, independently noticed while tracing verification — same root cause, same fix.
  - `[medium]` `[patch]` (blind-hunter) only `write(_:)` maps `FileHandle` failures through `captureError(for:)`; `init`'s header write and `patchSizes` (used by `finalize`/`repairHeader`) propagate raw `NSError`, breaking `Errors.swift`'s AR-PAT-7 typed-error convention — fix: wrap those calls the same way.
  - `[medium]` `[patch]` (edge-case-hunter, claim) claims-check: the task's "map a `FileHandle.write` failure to `CaptureError`" claim is false for `init`'s placeholder-header write — same root cause, same fix.
  - `[medium]` `[patch]` (edge-case-hunter, claim) same claim false for `finalize()`'s `patchSizes` call — same root cause, same fix.
  - `[medium]` `[patch]` (edge-case-hunter, claim) same claim false for `repairHeader(at:)`'s `patchSizes` call — same root cause, same fix.
  - `[low]` `[reject]` (blind-hunter) `init` silently overwrites a pre-existing `audio.wav` for a reused meeting id — unlikely in everyday use (meeting ids are freshly generated per recording session, per `MeetingID.generate()`'s established pattern) and the fix requires a new guard/error-design decision, not a direct correction.
  - `[low]` `[reject]` (edge-case-hunter) pre-existing cache directory keeps its old permissions instead of 0700 on re-init — same root cause and same rejection reasoning as the row above.
  - `[low]` `[patch]` (blind-hunter) `finalize()`/`repairHeader(at:)` call `patchSizes` then `handle.close()` without a `defer`; a throw from `patchSizes` skips the close — fix: close the handle in a `defer` instead of a trailing unconditional call.
  - `[false]` (blind-hunter) `handle` is declared without `private` so `WAVWriterTests` (a different file) can reach it via `@testable import` — refuted: `private` is file-scoped in Swift and would block that same-module-different-file test access entirely; internal visibility for test access is this codebase's established pattern (`AudioImporter.wavFile(pcm:)`, `SnippetExtractor.wavData`), and no current caller other than the test touches `handle`.
  - `[maybe-false]` `[defer]` (blind-hunter) `WAVWriter` has no `Sendable`/actor isolation and no lock, with no stated concurrency contract — if true, medium; unverifiable without a concurrent caller, which this story explicitly excludes (`CaptureStage` wiring is Story 5.4). Settled by Story 5.4's actual usage pattern (which task/thread creates and drives a `WAVWriter`).
  - `[low]` `[reject]` (blind-hunter) the spec's own `## Verification` section lists only `swift build`/`swift test`, omitting `swiftformat`/`swiftlint`/`make check` — its fix is to edit this build's spec, which is out of scope for triage per this workflow's rejection rule.
  - `[low]` `[reject]` (blind-hunter) no test exercises `write(_:)` after `finalize()` or a double `finalize()` — unlikely in everyday use (Story 5.4's real caller is expected to sequence these correctly) and the fix requires defining new lifecycle-misuse behavior, not a direct correction.
  - `[low]` `[patch]` (blind-hunter) `repairHeader(at:)`'s exactly-44-byte (zero-sample) boundary is untested — only the 9-byte too-short rejection is covered; fix: add a test for the zero-duration recovery case.

## Design Notes

The header is written twice, not once: a placeholder 44-byte header goes out at `init` (so the file is non-empty and byte-sliceable immediately, and so `finalize()`/`repairHeader` always patch a header of the same known shape), then `finalize()` (or `repairHeader` after a crash) overwrites only bytes 4-7 and 40-43 in place via `FileHandle.seek(toOffset:)` — the rest of the header and all sample data are untouched. This is why only two offsets matter regardless of how the header was built.

## Verification

**Commands:**
- `swift build` -- expected: builds cleanly with the new `Capture` files and the widened `wavFile` visibility.
- `swift test --filter WAVWriterTests` -- expected: all new tests pass, covering header correctness, 0600/0700 permissions, `repairHeader`, and partial-file survival on a thrown write.
- `swift test --filter CaptureTests` -- expected: existing `AudioImporterTests` still pass after the `wavFile(pcm:)` visibility change.

## Auto Run Result

**Summary:** Implemented `WAVWriter`, a `FileHandle`-based streaming WAV writer for `Capture`: creates the 0700 cache directory and 0600 `audio.wav` before any sample write, streams PCM via `write(_:)`, patches the RIFF/data chunk sizes on `finalize()`, and recovers a crashed file's header via `static repairHeader(at:)`. Widened `AudioImporter.wavFile(pcm:)` to module-internal so both types share one header byte layout. A review pass found 4 groups of real defects (2 medium, 2 low), all patched; 3 groups were rejected as low-severity/out-of-scope, 1 false, 1 deferred.

**Files changed:**
- `Sources/Capture/WAVWriter.swift` (new) — the writer itself: init/write/finalize/repairHeader, overflow-guarded chunk-size patching, `FileHandle` failures mapped to `CaptureError` at every write site, handle closed via `defer`.
- `Sources/Capture/AudioImporter.swift` — `wavFile(pcm:)` widened from `private` to module-internal; no behavior change.
- `Tests/CaptureTests/WAVWriterTests.swift` (new) — 9 tests covering the I/O matrix plus the zero-duration `repairHeader` boundary added during review.
- `.swiftlint.yml` — added `WAVWriter.swift` and its test file to the `atomic_writer_bypass` exclusion list (Decision 1.4's recorded exemption).
- `_bmad-output/implementation-artifacts/epic-5-context.md` — recompiled (step-01) because planning docs had changed since the cached version; not WAVWriter-specific.

**Review findings breakdown (17 findings across blind-hunter, edge-case-hunter, verification-gap, intent-alignment; see `## Review Triage Log` for full detail):**
- Patched (4 entries, 8 rows): UInt32 overflow trap in `finalize()`/`repairHeader(at:)` on >37h captures (medium) — now throws `.streamInterrupted` via `UInt32(exactly:)`; inconsistent `CaptureError` mapping on `init`'s header write and `patchSizes` (medium) — now wrapped through `captureError(for:)` everywhere `write(_:)` is; `FileHandle` leak if `patchSizes` throws before close (low) — now closed via `defer`; `repairHeader`'s zero-byte boundary untested (low) — test added.
- Rejected (3 entries, 5 rows): silent overwrite of a pre-existing `audio.wav`/stale directory permissions on re-init (low, unlikely given fresh-`MeetingID`-per-session and non-trivial fix); spec's own Verification section omitting lint commands (fix would edit the spec itself, out of scope for triage); no test for write-after-finalize/double-finalize misuse (low, unlikely, non-trivial).
- False (1): `handle`'s internal (not `private`) visibility — refuted as this codebase's established same-module-test-access pattern, matching `AudioImporter.wavFile`/`SnippetExtractor.wavData` precedent.
- Deferred (1): no `Sendable`/isolation contract on `WAVWriter` — real only if Story 5.4 introduces concurrent access; recorded in frontmatter `deferred` for that story to settle.

**Follow-up review recommendation:** `true`. Two medium-severity entries were patched this pass (the overflow-trap fix and the error-mapping fix), both touching `WAVWriter`'s core write/finalize/repair paths — worth a fresh pass to confirm the patches didn't introduce their own gap before Story 5.4 builds on this surface.

**Verification performed:** `swift build` clean; `swift test --filter WAVWriterTests` 9/9 pass; `swift test --filter CaptureTests` 19/19 pass (9 new + 10 existing `AudioImporterTests`, confirming the `wavFile` visibility change didn't regress the importer). Matrix Test Audit: all 5 I/O-matrix rows covered by a passing test.

**Residual risks:** The deferred concurrency-isolation question (see frontmatter `deferred`) is unresolved until Story 5.4 defines `WAVWriter`'s actual caller and threading. `WAVWriter` itself has no production caller yet — expected, since wiring it into `CaptureSession`/`CaptureStage` is explicitly Story 5.4's scope.
