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
      be called relative to each other; finalize() is not idempotent and
      write() after finalize() fails on a closed handle rather than being a
      defined no-op.
    evidence: |-
      If true, this is medium: a data race on `bytesWritten` or the shared
      `FileHandle` under concurrent calls. Unverifiable within Story 5.3,
      which has no concurrent caller — WAVWriter is only exercised
      single-threaded from WAVWriterTests. Per epic-5-context.md's build
      order, Story 5.2 (Process-Tap + AVAudioEngine Capture Session +
      AudioMixer), not 5.4, is WAVWriter's direct consumer (5.2 depends on
      5.1 and 5.3) and is likely to drive it from a real-time audio
      callback. Settled by Story 5.2's actual usage pattern: which
      task/thread creates and drives a WAVWriter, whether write() can be
      called while finalize()/repairHeader() run, and whether finalize()
      needs to be idempotent.
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

### 2026-09-22 — Review pass (external, PR #112)
A peer session reviewing PR #112 on the maintainer's behalf. All 8 findings verified by direct code inspection (and, for the epic-5-context.md claim, by checking `git show 55c2522` and `deferred-work.md` directly) before acting.
- verdicts: 8 findings — high 1, medium 6, low 0, false 0, maybe-false 1
- findings:
  - `[high]` `[patch]` neither `finalize()` nor `repairHeader(at:)` called `handle.synchronize()` (unlike `AtomicWriter`, which fsyncs) — a patched header could survive only in the page cache; power loss right after `finalize()` commits `captured` leaves the on-disk header at data size 0 and the meeting transcribes as empty, with no recovery path since it's no longer in `recording`. Fix: `synchronize()` after `patchSizes` in both paths.
  - `[medium]` `[patch]` the prior pass's overflow fix was incomplete: `36 + dataSize` in `patchSizes` still traps for `dataSize` within 36 of `UInt32.max`, and nothing bounded `write(_:)` itself, so a capture past ~4GiB could never be finalized or repaired once written. Fix: `maxDataSize = UInt32.max - 36` constant, enforced by `write(_:)` refusing (not just failing later at `finalize`) any write that would cross it.
  - `[medium]` `[patch]` `write(_:)` accepted an odd byte count, and `repairHeader` could patch an odd `data` chunk size with no pad byte and report a duration including half a sample. Fix: `write(_:)` rejects odd-length data; `repairHeader` rounds its recovered size down to the last whole sample.
  - `[medium]` `[patch]` `repairHeader(at:)` patched offsets 4-7/40-43 of any file ≥44 bytes without checking it was actually a WAV. Fix: `validateWAVHeader` confirms `RIFF`/`WAVE`/`data` at their fixed offsets first.
  - `[medium]` `[patch]` `epic-5-context.md`'s regeneration (step-01 of this run) was a false positive: commit `55c2522`, already in this run's baseline, had already updated it: the file's mtime looked stale only because a git-worktree checkout doesn't preserve original commit timestamps. The regenerated version dropped the "Edit freely" marker, rewrote hand-edited prose, and asserted the capture fallback is tracked in `deferred-work.md`, which `grep` confirms it is not. Fix: reverted to the baseline version (`git checkout 07d3c28 -- epic-5-context.md`).
  - `[medium]` `[patch]` (revises this pass's earlier `reject` on the same root cause) `init` created the file via `FileManager.createFile` + a separate `setAttributes`, so 0600 landed after the file existed, a pre-existing `audio.wav` was silently overwritten, and a pre-existing directory kept its prior permissions. The earlier rejection held because the only fix on the table added guard branches; this pass's concrete fix is a direct swap, not an addition: `open(2)` with `O_CREAT|O_EXCL|O_WRONLY` mode 0600 (atomically refuses an existing file) and an unconditional `setAttributes` on the directory. Also let `.swiftlint.yml` drop the `atomic_writer_bypass` exclusion for `WAVWriter.swift`, since neither pattern it matches appears anymore.
  - `[medium]` `[patch]` `WAVWriterTests.swift`'s EBADF test called `close(writer.handle.fileDescriptor)` directly; Swift Testing runs suites in parallel, so the freed fd number could be reassigned to an unrelated concurrently-open file before the test's next write, risking cross-test flakiness or corruption. Fix: `dup2` a read-only `/dev/null` onto the same fd number instead of closing it, so the number is never released back to the OS.
  - `[maybe-false]` `[defer]` (revises this pass's `Story 5.4` reference) `WAVWriter` has no `Sendable`/isolation and `finalize()` isn't idempotent — still unverifiable without a concurrent caller, but per `epic-5-context.md`'s build order it's Story 5.2 (Process-Tap + AVAudioEngine Capture Session), not 5.4, that depends directly on 5.3 and is the actual consumer likely driving `WAVWriter` from a real-time audio callback. Frontmatter `deferred` entry corrected to name 5.2 and to include `finalize()` idempotency as part of what that story must settle.

Applying these fixes also surfaced one implementation bug in the fixes themselves, caught by `swift test` before commit: `repairHeader(at:)`'s new header-validation step needed to *read* bytes, but the function opened the file `FileHandle(forWritingTo:)` (write-only) — reading from it threw `EBADF`. Fixed by opening `FileHandle(forUpdating:)` (read-write) instead.

## Design Notes

The header is written twice, not once: a placeholder 44-byte header goes out at `init` (so the file is non-empty and byte-sliceable immediately, and so `finalize()`/`repairHeader` always patch a header of the same known shape), then `finalize()` (or `repairHeader` after a crash) overwrites only bytes 4-7 and 40-43 in place via `FileHandle.seek(toOffset:)` — the rest of the header and all sample data are untouched. This is why only two offsets matter regardless of how the header was built.

## Verification

**Commands:**
- `swift build` -- expected: builds cleanly with the new `Capture` files and the widened `wavFile` visibility.
- `swift test --filter WAVWriterTests` -- expected: all new tests pass, covering header correctness, 0600/0700 permissions, `repairHeader`, and partial-file survival on a thrown write.
- `swift test --filter CaptureTests` -- expected: existing `AudioImporterTests` still pass after the `wavFile(pcm:)` visibility change.

## Auto Run Result

**Summary:** Implemented `WAVWriter`, a `FileHandle`-based streaming WAV writer for `Capture`: creates the 0700 cache directory and 0600 `audio.wav` (via `open(2)` with `O_CREAT|O_EXCL`, refusing a pre-existing file) before any sample write, streams PCM via `write(_:)` (rejecting odd-length or over-limit writes), patches and fsyncs the RIFF/data chunk sizes on `finalize()`, and recovers a crashed file's header via `static repairHeader(at:)` (which validates the file is actually a WAV first, and rounds an odd trailing byte down to the last whole sample). Widened `AudioImporter.wavFile(pcm:)` to module-internal so both types share one header byte layout. Two review passes ran: this workflow's own 4-layer review (17 findings), and an external peer-session review of the opened PR (8 findings, including 1 high-severity durability bug). All confirmed-real findings from both passes are patched.

**Files changed:**
- `Sources/Capture/WAVWriter.swift` (new) — the writer: init/write/finalize/repairHeader, overflow-bounded chunk-size patching (`maxDataSize`), whole-sample-only writes, `RIFF`/`WAVE`/`data` validation before `repairHeader` patches anything, `synchronize()` after every header patch, `FileHandle` failures mapped to `CaptureError` at every write site, handle closed via `defer`, exclusive file creation via raw `open(2)`.
- `Sources/Capture/AudioImporter.swift` — `wavFile(pcm:)` widened from `private` to module-internal; no behavior change.
- `Tests/CaptureTests/WAVWriterTests.swift` (new) — 12 tests covering the I/O matrix, the zero-duration and non-WAV-file `repairHeader` boundaries, odd-byte-count rejection, and odd-trailing-byte recovery; the simulated-write-failure test uses `dup2` onto `/dev/null` rather than closing the real fd, so it can't leak a reusable fd number into a concurrently-running test.
- `.swiftlint.yml` — added, then removed, an `atomic_writer_bypass` exclusion for `WAVWriter.swift` itself (no longer needed once file creation moved off `FileManager.createFile`); kept the exclusion for the test file's own fixture writes.
- `_bmad-output/implementation-artifacts/epic-5-context.md` — **unchanged from baseline.** This run's step-01 regenerated it based on a stale mtime comparison that doesn't hold in a git worktree (checkout order, not edit history); the peer review caught that commit `55c2522`, already in this run's baseline, had already updated it, and that the regenerated version fabricated a claim not present in `deferred-work.md`. Reverted.

**Review findings breakdown (see `## Review Triage Log` for full per-finding detail):**
- Pass 1 (this workflow's 4 layers, 17 findings): 4 entries patched (2 medium: overflow-trap guard, `CaptureError` mapping consistency; 2 low: `FileHandle` leak on throw, untested `repairHeader` zero-byte boundary). 3 entries rejected as low-severity/non-trivial at the time. 1 false (test-access visibility). 1 deferred (concurrency contract).
- Pass 2 (external peer review of PR #112, 8 findings, all confirmed real): 1 high (missing `fsync` — a patched header could survive only in the page cache, so power loss right after `finalize()` leaves a `captured` meeting with a 0-byte-duration header and no recovery path). 6 medium, all patched: the overflow fix from pass 1 was itself incomplete (`36 + dataSize` could still overflow, and nothing bounded `write(_:)`); odd-byte-count handling was missing entirely; `repairHeader` never validated the file was actually a WAV before patching it; the epic-5-context.md regeneration (above); the pass-1 "reject" on silent-overwrite/stale-permissions was revised to patch once a genuinely trivial fix (`open(2)` with `O_EXCL`) was available; the EBADF test's direct fd-close was a latent CI-flakiness risk. 1 finding revised the pass-1 `deferred` entry's target story from 5.4 to 5.2 (WAVWriter's actual direct consumer per the build order) and added `finalize()` idempotency to what that story must settle.
- Applying pass 2's fixes surfaced one bug in the fixes themselves before commit: `repairHeader`'s new WAV-validation needed to read the file, but it was opened write-only — `swift test` caught the resulting `EBADF` immediately; fixed by opening `forUpdating:` instead.

**Verification performed:** `swift build` clean; `swift test --filter CaptureTests` 22/22 pass (12 `WAVWriterTests` + 10 `AudioImporterTests`); `swiftformat --lint` and `swiftlint` clean on all changed files.

**Follow-up review recommendation:** `true`. This pass patched 1 high and 6 medium findings against code that had already been through one review round — including a data-loss-on-power-failure bug that round missed entirely — which is reason enough for a fresh pass before Story 5.2 builds on this surface.

**Verification performed:** `swift build` clean; `swift test --filter WAVWriterTests` 9/9 pass; `swift test --filter CaptureTests` 19/19 pass (9 new + 10 existing `AudioImporterTests`, confirming the `wavFile` visibility change didn't regress the importer). Matrix Test Audit: all 5 I/O-matrix rows covered by a passing test.

**Residual risks:** The deferred concurrency-isolation question (see frontmatter `deferred`) is unresolved until Story 5.4 defines `WAVWriter`'s actual caller and threading. `WAVWriter` itself has no production caller yet — expected, since wiring it into `CaptureSession`/`CaptureStage` is explicitly Story 5.4's scope.
