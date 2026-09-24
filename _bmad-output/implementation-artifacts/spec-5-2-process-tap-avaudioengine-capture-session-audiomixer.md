---
title: 'Story 5.2: Process-Tap + AVAudioEngine Capture Session + AudioMixer'
type: 'feature'
created: '2026-09-22'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: true
baseline_revision: '2ca55f066c016bfc0cda791f2c9c49df593376de'
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The bundled epic-5-context.md diff rewrites content for nearly every
      Epic 5 story, not just this story's, bundling a wholesale context
      regeneration into a single-story implementation diff.
    evidence: |-
      This is step-01's mandated regeneration of a stale cached epic-context
      file (architecture.md was newer than the cached epic-5-context.md at
      dispatch time) — required by the build-auto workflow itself, not a
      choice the implementation made. It makes it harder for a reviewer to
      tell which parts were actually re-validated by this story's own work
      versus edited incidentally by the regeneration. No code-level fix
      exists within this story's scope; it is a workflow/process behavior.
    location: >-
      _bmad-output/implementation-artifacts/epic-5-context.md
    severity: low
---

<intent-contract>

## Intent

**Problem:** auricle has `WAVWriter` (Story 5.3) and `PermissionChecker` (Story 5.1) but nothing produces live PCM — the pipeline only ever ingests pre-existing files via `AudioImporter` (Story 4.8), never a meeting auricle itself records.

**Approach:** Add `Capture/CaptureSession.swift`, backed by a `SystemAudioSource` protocol whose concrete implementation (`ProcessTapSource.swift`) is a Core Audio global process tap, plus an `AVAudioEngine` microphone input; a new `Capture/AudioMixer.swift` resamples and mixes both into mono 16kHz PCM-16 fed to `WAVWriter`. `CaptureSession` also exposes `SystemAudioPermissionProbe.prompt()` for onboarding (Story 5.8) to trigger the OS grant.

## Boundaries & Constraints

**Always:**
- System audio: `CATapDescription(monoGlobalTapButExcludeProcesses:)` excluding auricle's own process, wrapped in a private aggregate device, read via an `AudioDeviceIOProc` (Decision 1.4). Reference pattern: `insidegui/AudioCap` (research.md source #3, high confidence) for the tap/aggregate/IOProc setup shape — no comparable code exists yet in this repo.
- Microphone: an `AVAudioEngine` input node.
- `AudioMixer` resamples both sources to 16kHz with `AVAudioConverter` and mixes to mono 16-bit PCM before handing bytes to `WAVWriter.write(_:)`.
- The tap stays passive: `muteBehavior` unmuted, no perceivable latency added to the meeting app (NFR-P13).
- Mic permission denied at `start()` → record system-audio only, report `micIncluded == false`. No permission state ever blocks a start.
- 30 consecutive seconds of exact-zero system-audio buffers → watchdog tears down and rebuilds the tap, aggregate device and IOProc, at most once per 30s; counts rebuilds and exact-zero seconds for later capture metadata (Story 5.4 reads these counters, does not need to exist yet). Never fails the capture on this — zeros are ambiguous with silence or a missing grant.
- `stop()` flushes both sources, calls `WAVWriter.finalize()`, returns the finished `audio.wav` path. One `CaptureSession` instance is single-use.
- `SystemAudioPermissionProbe.prompt()` runs the tap for 1 second and discards the audio, purely to surface the OS's System Audio Recording prompt.
- The macOS floor is the tap's minimum, 14.4. `PackageDescription` declares `.macOS(_ versionString: String)` alongside the whole-number `.v14`/`.v15`-style cases (confirmed against the installed toolchain's `PackageDescription.swiftinterface`), so `Package.swift`'s `platforms` is `[.macOS("14.4")]` — the package's own floor, not just an availability annotation. `App/Project.swift:58` and `:73` `deploymentTargets` match at `.macOS("14.4")` (Tuist's string form takes any minor version).

**Never:**
- No ScreenCaptureKit implementation in this story — it is the recorded fallback behind `SystemAudioSource` only if the live-app check below fails.
- No `StateStore`/`CaptureStage`/`PipelineTransitions` wiring, crash recovery, or mid-capture revocation handling — all Story 5.4.
- No CLI `record`/`stop` verbs — capture is GUI-process-only per Decision 1.4/9.5.
- Don't add a `CaptureError` case for permission revocation — `.permissionDenied`/`.permissionRevokedMidstream` already exist in `Core/Errors.swift` for Story 5.4 to use; this story's failures map to the existing `.streamInterrupted(reason:)`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mic denied at start | `PermissionChecker.check(.microphone) == .denied` | Session records system audio only, reports `micIncluded == false` | No error thrown |
| 30s of exact-zero system buffers | Watchdog observes 30 consecutive zero buffers | Tap/aggregate/IOProc rebuilt once; rebuild count and zero-seconds count both increment | Capture never fails |
| Mismatched source rates | Mic delivers 44.1kHz, system tap delivers 48kHz | `AudioMixer` resamples both to 16kHz mono PCM16 before mixing | N/A |
| `stop()` called twice | Second call on an already-stopped session | Second call is a no-op (idempotent per NFR-R5) | No error thrown |

</intent-contract>

## Code Map

- `Sources/Capture/SystemAudioSource.swift` -- new; `Sendable` protocol seam so `ProcessTapSource` can be swapped for a future ScreenCaptureKit source without touching `AudioMixer`/`WAVWriter`/`CaptureStage`
- `Sources/Capture/ProcessTapSource.swift` -- new; the one `SystemAudioSource` conformance: `CATapDescription(monoGlobalTapButExcludeProcesses:)`, private aggregate device, IOProc, and the 30s exact-zero watchdog
- `Sources/Capture/AudioMixer.swift` -- new; `AVAudioConverter`-based resample-and-mix to mono 16kHz PCM16
- `Sources/Capture/CaptureSession.swift` -- new; `CaptureSession(meetingID:)`, `start()`/`stop()`, wires `AVAudioEngine` mic + `SystemAudioSource` + `AudioMixer` + `WAVWriter`; also declares `SystemAudioPermissionProbe`
- `Sources/Capture/WAVWriter.swift` -- existing (Story 5.3, done); `init(meetingID:)`, `write(_:)`, `finalize()` are the exact API `CaptureSession.stop()` calls
- `Sources/Capture/AudioImporter.swift:55-56` -- existing; `Self.sampleRate` (16000) and `Self.audioFileName` constants to reuse, not redeclare
- `Sources/Permissions/PermissionChecker.swift:105-133` -- existing; `check(.microphone) async -> PermissionStatus` is what `CaptureSession.start()` calls before enabling the mic input
- `Sources/Core/Errors.swift:14-22` -- existing `CaptureError`; this story only throws `.streamInterrupted(reason:)`/`.diskFull` (already used by `WAVWriter`)
- `Package.swift:77` -- existing `Capture` target already depends on `["Core", "State", "Telemetry", "Permissions"]`; no dependency change needed
- `Package.swift:180-186` -- existing `CaptureTests` target already includes `Capture`, `TestSupport`, `Core`, `State`, `Telemetry`; add new test files under its `path`
- `App/Project.swift:58` and `:73` -- both `deploymentTargets: .macOS("14.0")` bump to `.macOS("14.4")`
- `_bmad-output/planning-artifacts/research/technical-scstream-vs-core-audio-process-taps-2026-09-22/research.md` -- read-only; API choice rationale, the `insidegui/AudioCap` reference, and the known zero-buffer fault this watchdog exists for

## Tasks & Acceptance

**Execution:**
- `Sources/Capture/SystemAudioSource.swift` -- declare the `Sendable` protocol (buffer delivery + exact-zero/rebuild counters) -- the ScreenCaptureKit-swap seam Decision 1.4 requires
- `Sources/Capture/ProcessTapSource.swift` -- implement the global exclude-self tap, private aggregate device, IOProc, and the 30s/one-rebuild-per-30s watchdog -- AC's Core Audio backend
- `Sources/Capture/AudioMixer.swift` -- resample mic + tap buffers to 16kHz mono PCM16 via `AVAudioConverter` and mix -- AC's mixing requirement
- `Sources/Capture/CaptureSession.swift` -- `start()` checks `PermissionChecker.check(.microphone)` then wires `AVAudioEngine` input + `SystemAudioSource` + `AudioMixer` + `WAVWriter`; `stop()` flushes both sources, calls `WAVWriter.finalize()`, returns the `audio.wav` path; both idempotent/single-use -- AC's session lifecycle
- `Sources/Capture/CaptureSession.swift` -- add `SystemAudioPermissionProbe.prompt()`: runs `ProcessTapSource` for 1s, discards output -- AC's onboarding trigger for Story 5.8
- `App/Project.swift` -- bump both `deploymentTargets` to `.macOS("14.4")` -- process-tap floor
- `Tests/CaptureTests/AudioMixerTests.swift` -- synthetic 44.1kHz mic + 48kHz system input resampled/mixed to 16kHz mono -- AC's test requirement
- `Tests/CaptureTests/ProcessTapSourceTests.swift` -- watchdog rebuild rule driven against a fake buffer source, since a real tap needs a live Mac -- AC's test requirement
- `Tests/CaptureTests/CaptureSessionTests.swift` -- mic-denied → system-audio-only path; idempotent `start()`/`stop()` -- AC's test requirement
- ~~This spec file, `## Auto Run Result` -- record the manual live-app check~~ -- moved to Story 5.6 (per PR #117): the live Teams/Meet/Zoom check and the soak are no longer this story's acceptance gate. Story 5.6's debug hotkey and the maintainer's normal meetings serve as the check instead.

**Acceptance Criteria:**
- Given the `Capture` target, when `CaptureSession(meetingID:)` is instantiated, then system audio comes through the `CATapDescription`-based `SystemAudioSource` and the microphone through `AVAudioEngine`, mixed by `AudioMixer` into mono 16kHz PCM16
- Given `Capture`, when `SystemAudioPermissionProbe.prompt()` runs, then it performs a 1-second discarded capture so macOS shows the System Audio Recording prompt
- Given `Tests/CaptureTests/`, when the suite runs, then it covers `AudioMixer` resampling/mixing, the watchdog rebuild rule, the mic-denied path, idempotent start/stop, a mid-stream format change, a source that stops calling back entirely, and a slow writer that must not block the producer side
- ~~Given the manual Teams/Meet/Zoom check fails...~~ -- superseded: per PR #117, the live-app check and the tap-vs-ScreenCaptureKit backend decision it gates move to Story 5.6, which is where a failed check would trigger the ScreenCaptureKit correct-course. This story ships the tool the check will run against, not the check itself.

## Spec Change Log

### 2026-09-22 — Post-merge review of PR #118
- The "Verification performed (round 2)" section claimed all three AC-mandated fake-`SystemAudioSource` tests existed, naming "format change mid-stream" among them; only the no-callback and slow-writer cases were actually present. Corrected in place; the missing format-change test (`midStreamSystemFormatChangeIsHandledWithoutLosingAudio`) was added to `Tests/CaptureTests/CaptureSessionTests.swift`.
- Fixed a concurrent-rebuild handle leak, a rate-check rebuild storm, and a vacuous slow-writer test surfaced by the same review — see `Sources/Capture/RebuildCoordinator.swift`, `Sources/Capture/CaptureSession.swift`'s `checkEffectiveRate`, and the rewritten `aSlowWriterNeverBlocksTheProducerSideOrTheRealRingBuffer` test.

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 23 findings — high 0, medium 14, low 8, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind-hunter) `AudioMixer.ingestSystem`/`ingestMic` replace a side's `SourcePipeline` outright when the incoming buffer's format differs (e.g. after a watchdog rebuild), discarding already-converted samples still in `buffered` — verified at `AudioMixer.swift` lines 64-67/74-77; own doc comments claim this case is handled. Action: drain the old pipeline's buffered samples through before swapping in the new one.
  - `[medium]` `[patch]` (blind-hunter) `CaptureSession.stop()` reads `phase`/releases the lock/tears down/only sets `.stopped` at the end, so two concurrent `stop()` calls can both pass the `.running` check and both run teardown — verified against `stop()`'s lock scope. Action: shares the fix below (transition phase inside the critical section).
  - `[medium]` `[patch]` (blind-hunter) `CaptureSession.start()`'s single-use guard is checked before `phase` becomes `.running` (only set after permission check, tap start, mic start, and `WAVWriter` init all succeed), so two concurrent `start()` calls can both pass the guard — verified against `start()`'s lock scope, contradicts the class's own single-use doc claim. Action: reserve the running state atomically inside the same lock as the guard.
  - `[low]` `[patch]` (blind-hunter) `start()`'s two error-cleanup branches (`startMicInput()` failing, `WAVWriter(...)` init failing) have no test coverage — verified against `CaptureSessionTests.swift`; the cleanup code itself reads correctly on inspection. Action: add one test per branch.
  - `[medium]` `[patch]` (blind-hunter) `stop()`: if `writer.finalize()`/`cacheDirectory(...)` throws, `phase` never reaches `.stopped`, so a retried `stop()` re-enters `.running` and repeats `systemAudioSource.stop()`/`stopMicInput()`/`finalize()` — verified against `stop()`'s control flow. Action: shares the fix below (guarantee a terminal phase on every path).
  - `[medium]` `[patch]` (blind-hunter) `FakeSystemAudioSource` doesn't model `ProcessTapSource`'s real "cannot restart after a failed start" latch, masking that gap from `CaptureSessionTests` — verified: the fake's `stop()` just clears `onBuffer` with no `isStopped`-style latch. Action: shares the `ProcessTapSource.start()` fix below.
  - `[low]` `[patch]` (blind-hunter) `SystemAudioPermissionProbe.prompt()` has no test anywhere, though it's one of this spec's own Acceptance Criteria — verified via the test files' contents. Action: add one test against a `FakeSystemAudioSource`.
  - `[medium]` `[patch]` (blind-hunter) `AudioMixer.drain()` has no staleness bound: once a side has been ingested from, a side that stops delivering (mic stall, or system's first buffer arriving late) makes `drain()` return empty indefinitely for that pairing, buffering audio unboundedly in memory until `stop()`'s `flush()` — verified against `drain()`'s `min()` logic; this defeats `WAVWriter`'s whole crash-survival rationale (Decision 1.4) since nothing reaches disk until `stop()`. Action: cap the holdback and pad with silence past it, mirroring `flush()`'s existing pattern.
  - `[low]` `[reject]` (blind-hunter) `SourcePipeline.take(_:)`'s `buffered.removeFirst(count)` on a plain `Array` is O(n) per call on the ingest hot path — verified, real, but buffered counts stay small (drain runs every ~100-250ms) and the fix (ring buffer/index cursor) is more than a direct correction; rejected per the low-finding rule.
  - `[low]` `[defer]` (blind-hunter) the bundled `epic-5-context.md` diff rewrites content for nearly every Epic 5 story, not just 5.2's — verified: this is step-01's mandated regeneration of a stale cached context file (architecture.md was newer), not implementation discretion; a workflow-process observation, not a code defect this story's diff can fix.
  - `[low]` `[defer]` (blind-hunter, same group as above) inside that same rewrite, "(Epic 6 Deletes It)" → "(Epic 6 deletes it)" is a pure capitalization change unrelated to Story 5.2 — same cause as above.
  - `[false]` `[reject]` (blind-hunter) claimed the "41 in `CaptureTests`" figure in `## Auto Run Result` is unverifiable without a stated baseline — refuted: independently reran `swift test --filter CaptureTests` and got "Test run with 41 tests in 5 suites passed", exactly matching the report.
  - `[low]` `[patch]` (edge-case-hunter) `SourcePipeline.append`'s `ratio = targetFormat.sampleRate / buffer.format.sampleRate` has no guard against a zero/non-finite `buffer.format.sampleRate`; the resulting infinite/NaN ratio traps when converted to `AVAudioFrameCount` — verified, real but reachable only via a malformed format (never observed from real `AVAudioEngine`/tap formats). Action: guard `sampleRate > 0` and finite before dividing.
  - `[medium]` `[patch]` (edge-case-hunter, same group as the drain finding above) mic buffers accumulate unboundedly in `micPipeline.buffered` while `systemPipeline` is still `nil` (before the tap's first callback) — verified against `drain()`'s `min(systemFrames, micFrames ?? systemFrames)`, same root cause as the staleness-bound finding above. Action: shares that fix.
  - `[medium]` `[patch]` (edge-case-hunter, same group as the format-change finding above) confirms the format-change buffered-sample loss with an exact repro (ingest-then-partial-drain, then a format change on that side) — verified independently, same location/cause.
  - `[medium]` `[patch]` (edge-case-hunter, same group as the start() race above) confirms the `start()` concurrent-call race with the same root cause.
  - `[medium]` `[patch]` (edge-case-hunter, same group as the stop() race above) confirms the `stop()` concurrent-call race with the same root cause.
  - `[medium]` `[patch]` (edge-case-hunter, same group as the stop()-stuck-phase finding above) confirms `cacheDirectory`/`finalize` throwing leaves `phase` stuck at `.running`, causing a retried `stop()` to redo teardown — same root cause.
  - `[medium]` `[patch]` (edge-case-hunter) if `writer.write(remaining)` throws inside `stop()`, `mixer.flush()` has already dequeued those frames via `take()`, so they are lost permanently rather than merely unwritten — verified against `flush()`/`take()`'s destructive-read semantics. Action: shares the `stop()` terminal-phase fix; don't dequeue until the write succeeds.
  - `[low]` `[patch]` (edge-case-hunter) a buffer arriving while `runningComponents()` returns `nil` (the start/stop race window) is silently dropped with no log line, unlike every other drop path in `CaptureSession.swift` — verified. Action: add the matching `Self.log.error(...)` call.
  - `[medium]` `[patch]` (edge-case-hunter) `ProcessTapSource.start()` sets `onBuffer` before calling `buildAndStart()`; if that throws, `onBuffer` stays non-nil forever, so every later `start()` on the same instance throws "already called" though no tap ever ran — verified against `start()`'s ordering. Action: reset `onBuffer` to `nil` on `buildAndStart()` failure.
  - `[low]` `[patch]` (edge-case-hunter) `ProcessTapSource.handleInput`'s `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` returning `nil` is silently dropped with no log line — verified. Action: add a matching log line.
  - `[medium]` `[patch]` (verification-gap, pre-verified) same `AudioMixer` format-change buffered-sample-loss finding, independently traced and confirmed with a specific non-repro-by-existing-tests demonstration — same location/cause/fix as above.



**`Package.swift`'s 14.4 floor:** `PackageDescription` declares both the whole-number `SupportedPlatform.MacOSVersion` cases (`.v14`, `.v15`, …) and a separate `.macOS(_ versionString: String)` overload taking an arbitrary version string (confirmed against the installed toolchain's `PackageDescription.swiftinterface`) — `Package.swift` uses the latter, `platforms: [.macOS("14.4")]`, so the package's own declared minimum matches the tap's real floor rather than relying on `@available` annotations alone to enforce it above a lower manifest floor.

**Reference implementation:** no tap/aggregate-device/IOProc code exists anywhere in this repo yet — this is the first. `insidegui/AudioCap` (referenced in the research doc as high-confidence, since it is the one source that documents the full setup chain) is the closest known-good shape for the aggregate-device creation and IOProc registration; use it to avoid inventing an incorrect Core Audio call sequence, not to copy verbatim.

**Aggregate device shape:** the aggregate uses the default output device as its main/clock sub-device (`kAudioAggregateDeviceMainSubDeviceKey`/`kAudioAggregateDeviceClockDeviceKey`), with drift compensation enabled on the tap sub-entry (`kAudioSubTapDriftCompensationKey`) — matching `insidegui/AudioCap` and Apple's own "Capturing system audio with Core Audio taps" sample, rather than a tap-only aggregate with no real clock source. The reasoning: drift compensation needs something to compensate against, and a tap-only aggregate has no independent clock to drift relative to. This is a judgment call, not an empirically confirmed one — it cannot be conclusively settled without the live-Mac check Story 5.6 owns. If that check surfaces clock or drift artifacts, revisit this shape first.

**`WAVWriter`'s concurrency contract (settles the open `deferred-work.md` item from Story 5.3):** `CaptureSession` is `WAVWriter`'s one real caller, and it drives `write(_:)`/`finalize()` from exactly one place — the background consumer `Task` `start()` launches. `stop()` cancels that task and `await`s its exit *before* touching the writer itself (its own final flush-then-`finalize()`), so `write(_:)` and `finalize()` can never execute concurrently, and a `write(_:)` can never land after `finalize()` has closed the file — both by construction, not by locking inside `WAVWriter`. `WAVWriter` itself needed no changes to get this guarantee; it falls out of `CaptureSession`'s own task-sequencing. `repairHeader(at:)` remains a separate, offline recovery path (run after a crash, never concurrently with a live `WAVWriter` instance) and is unaffected.

**Real-time safety (NFR-P13) — the producer/consumer split:** the mic tap's callback (`AVAudioEngine.installTap`) and `ProcessTapSource`'s IOProc callback do the least possible work: a bounds check and a raw-pointer `memcpy` into a preallocated `AudioRingBuffer` slot, guarded by a bounded `os_unfair_lock` critical section (sized to one slot's worth of samples, never more) — no heap allocation, no resampling, no mixing, no file I/O, no logging. Everything else (`AVAudioConverter` resampling, `AudioMixer` mixing, the watchdog, stream alignment, `WAVWriter.write(_:)`) runs on `CaptureSession.runConsumerLoop()`, a background `Task` that drains both rings on a ~20ms poll. `SystemAudioSource` changed shape accordingly: `start()`/`stop()`/`drain(_:)`/`rebuild()`, pull-based, rather than a per-buffer push callback — `drain(_:)` is what lets the consumer retrieve chunks without the producer ever calling into consumer-owned code.

**Stream alignment:** mic and system audio start at different host times (`AVAudioEngine`'s mic tap starts after the permission check and after the system tap is already running). `CaptureSession` holds each side's earliest chunks until it has seen the first chunk from every side it expects, then primes whichever side started later with exactly that much leading silence (`AudioMixer.primeMicLeadIn`/`primeSystemLeadIn`) before any real ingestion — a one-time startup correction by host time, not continuous drift correction. Continuous drift across a long meeting is left to the aggregate device's own drift compensation on the system side (see above); mic-vs-system drift beyond that is not corrected mid-capture in this story.

**Watchdog, widened:** the exact-zero-buffer trigger (30 consecutive seconds) only fires when a buffer actually arrives. A dead IOProc — the aggregate device's output device removed or changed — stops calling back entirely rather than calling back with zeros, so `CaptureSession`'s consumer loop also tracks wall-clock time since the last system chunk and calls `SystemAudioSource.rebuild()` directly once that exceeds a threshold (5s in production, injectable for tests). `ProcessTapSource` also registers Core Audio property listeners for `kAudioTapPropertyFormat` and `kAudioHardwarePropertyDefaultOutputDevice` changes, rebuilding on either (e.g. AirPods switching to HFP call mode mid-meeting), and the consumer cross-checks the tap's declared sample rate against the rate implied by callback host-time deltas over the capture's first second, rebuilding on a >5% disagreement.

**Live-app check moved to Story 5.6 (per PR #117):** the 5-minutes-each Teams/Google Meet-in-Chrome/Zoom check and the 60-minute soak are no longer this story's acceptance gate — they move to Story 5.6, where the maintainer's own meetings (recorded via that story's debug hotkey) serve as the check, including a Bluetooth/AirPods run that exercises this story's format-change rebuild path. This story's job was building `ProcessTapSource`/`CaptureSession`/`AudioMixer` correctly against the documented Core Audio API shapes (verified against the installed SDK's actual headers — `CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h` — not from memory) and covering the consumer-side logic with fake-`SystemAudioSource` tests; it was never this story's job to run the live check itself.

## Verification

**Commands:**
- `swift build` (full package) -- expected: builds clean
- `swift test --filter CaptureTests` -- expected: all `CaptureTests` pass, including the format-change, no-callback-watchdog, and slow-writer-doesn't-block-the-producer cases
- `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` -- expected: no violations
- `scripts/check.sh app` -- expected: passes at the 14.4 deployment target

## Auto Run Result

**Summary:** Implemented Story 5.2 — `SystemAudioSource` protocol seam, `ProcessTapSource` (Core Audio global exclude-self process tap in a private aggregate device, read via an `AudioDeviceIOProc`, with a 30s exact-zero-buffer watchdog), `AudioMixer` (per-source lazy `AVAudioConverter` resample-to-16kHz-mono pipelines, summed and clamped to Int16), and `CaptureSession` (wires `AVAudioEngine` mic + `SystemAudioSource` + `AudioMixer` + `WAVWriter`, plus `SystemAudioPermissionProbe.prompt()` for Story 5.8's onboarding trigger). Both `App/Project.swift` deployment targets bumped to 14.4.

**Files changed:**
- `Sources/Capture/SystemAudioSource.swift` (new) — `SystemAudioSource` protocol + `SystemAudioWatchdogStats`
- `Sources/Capture/ProcessTapSource.swift` (new) — `ZeroBufferWatchdog` (pure rebuild-decision logic, independently testable), `ZeroBufferDetector`, and `ProcessTapSource` itself: `CATapDescription(monoGlobalTapButExcludeProcesses:)`, private aggregate device, `AudioDeviceCreateIOProcIDWithBlock`, async off-queue rebuild; post-review, resets `onBuffer` to `nil` on a failed `start()` and logs a dropped-nil-buffer IOProc case
- `Sources/Capture/AudioMixer.swift` (new) — `AudioMixer` (`ingestMic`/`ingestSystem`/`drain`/`flush`/`peekFlush`/`discardFlushed`) and private `SourcePipeline`/`SingleBufferSource`; post-review, carries a format change's unmixed samples forward instead of discarding them, bounds one-sided starvation to 2s before padding with silence, and guards a non-finite/zero sample rate
- `Sources/Capture/CaptureSession.swift` (new) — `CaptureSession` (`start()`/`stop()`, single-use, idempotent `stop()`) and `SystemAudioPermissionProbe`; post-review, gained `.starting`/`.stopping`/`.stopFailed` phases closing two concurrency races and guaranteeing a terminal phase on every `stop()` exit path, an injectable `startEngine` seam, and buffer-drop logging in the start/stop race window
- `App/Project.swift` — both `deploymentTargets` bumped from `.macOS("14.0")` to `.macOS("14.4")`
- `Tests/CaptureTests/AudioMixerTests.swift` (new, 6 tests) — 44.1kHz mic + 48kHz system → 16kHz mono, mic-denied passthrough, drain-holds-back/flush-pads, empty mixer, format-change carry-over, starvation-cap padding
- `Tests/CaptureTests/ProcessTapSourceTests.swift` (new, 10 tests) — `ZeroBufferDetector` (4) + `ZeroBufferWatchdog`'s 30s/once-per-30s rule (6)
- `Tests/CaptureTests/CaptureSessionTests.swift` (new, 8 tests) — mic-denied system-only path (real WAV output verified), `.notDetermined` still includes mic, stop-before-start throws, start-twice throws, stop-twice is idempotent, mic-engine-start failure tears down and propagates, `WAVWriter` construction failure tears down and propagates, `SystemAudioPermissionProbe.prompt()` starts and stops the source

**Design decisions not fully spelled out in the spec:**
- `AudioMixer` builds each side's resample pipeline lazily from that side's *first buffer's format* rather than requiring formats up front — this is what lets `CaptureSession` wire `SystemAudioSource.start(onBuffer:)` without a chicken-and-egg dependency on a format only the tap knows once it's running, and lets a watchdog rebuild hand back a different format without `AudioMixer` needing to know.
- `CaptureSession.stop()` independently recomputes the `audio.wav` URL via the same `cacheDirectory` closure `WAVWriter` uses, rather than adding a URL accessor to `WAVWriter` — the spec's Code Map scopes `WAVWriter` to exactly `init`/`write`/`finalize`.
- Swift Testing's `@Suite`/`@Test` macros reject being combined with `@available` on the same declaration (a toolchain limitation, not a design choice) — `CaptureSessionTests` instead opens each test body with `guard #available(macOS 14.4, *) else { ... }`.

**Review findings breakdown (2026-09-22 pass, 23 findings from blind-hunter/edge-case-hunter/verification-gap):**
- **Patched (10 entries, 19 member rows):** `AudioMixer` discarding buffered samples on a mid-capture format change; `CaptureSession.start()`'s and `.stop()`'s concurrency races (two concurrent calls both passing their guard); `stop()`'s error path (stuck phase causing double-teardown/double-finalize, and losing the final buffered chunk if `write` failed after `flush` dequeued it); `ProcessTapSource.start()` permanently locking out retries after any first failure; `AudioMixer.drain()` holding a starved side back with no bound (unbounded memory, violates `WAVWriter`'s crash-survival rationale); a zero/non-finite sample rate crashing the resample-ratio arithmetic; missing diagnostic logs for two silent-drop paths; missing test coverage for `start()`'s two error-cleanup branches; missing test coverage for `SystemAudioPermissionProbe.prompt()`. All verified for real against the code before patching, and the fixes independently re-verified below.
- **Deferred (1 entry, 2 rows):** the bundled `epic-5-context.md` diff rewrites content for most of Epic 5, not just this story — this is step-01's mandated regeneration of a stale cached context file (`architecture.md` was newer), not implementation discretion, so there's no code fix in this story's scope; recorded in frontmatter `deferred`.
- **Rejected (2 findings):** `SourcePipeline.take(_:)`'s O(n) `removeFirst` on the ingest hot path — real but buffered counts stay small in practice and the fix (ring buffer/index cursor) is more than a direct correction. The claim that "41 in `CaptureTests`" was an unverifiable figure — refuted by independently rerunning `swift test --filter CaptureTests`, which reported exactly that count both before and after patching (46 after the review's new tests).

**Follow-up review recommendation: `true`.** Six `medium`-verdict entries were patched (≥ 2 on a first pass triggers this). Specific unverified risk: the new `AudioMixer` starvation-bound/format-carryover logic and `CaptureSession`'s new `.starting`/`.stopping`/`.stopFailed` phase transitions are covered only by synthetic single-threaded unit tests — none of it has been exercised against a real multi-hour capture, a real concurrent double-tap of a record control (no such control exists yet; Story 5.6), or the real Core Audio tap under load.

**Verification performed:**
- Before the review's patches: `swift build` (full package, clean) and `swift test --filter CaptureTests` (41/41 passed), independently rerun by the reviewer (not just the implementer's report).
- After the review's patches: `swift build` (full package) — clean; `swift test --filter CaptureTests` — 46/46 passed; `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` (whole repo) — 0 violations, 401 files; `scripts/check.sh app` — both `xcodebuild AuricleApp` and `xcodebuild auricle-cli` schemes `BUILD SUCCEEDED` at the bumped 14.4 deployment target, `auricle-cli` embedded check and `NSAudioCaptureUsageDescription` presence check both passed. All commands rerun directly by the reviewer against the patched tree, matching the implementer's own report.
- The four I/O & Edge-Case Matrix rows (mic denied, 30s zero-buffer watchdog, mismatched rates, idempotent `stop()`) each have a passing covering test, confirmed by name against the test-run output.

**Left incomplete — needs the maintainer, not more code** (this run had no way to join a live call or run an unattended soak):
- The 5-minutes-each Teams/Google Meet-in-Chrome/Zoom live-audio check (epics.md's own AC gates the tap-vs-SCStream backend choice on this).
- The 60-minute capture soak (exact-zero seconds, watchdog rebuild count, whether an ad-hoc rebuild re-prompts for System Audio Recording).
- Since neither of these has run, the process tap's real-world behavior against a live meeting app and the watchdog's real-world rebuild path (`buildAndStart`/`rebuild`/`tearDown`) are unverified beyond compiling correctly against the documented Core Audio API shapes (verified against the installed SDK's actual headers — `CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h` — not from memory).

**Residual risks (round 1, largely superseded by round 2's redesign below):**
- `ProcessTapSource`'s Core Audio glue (tap/aggregate device/IOProc creation and teardown) has no automated test coverage — it cannot be exercised without a live Mac and a live System Audio Recording grant, which this run had neither of. `ProcessTapSourceTests` covers the watchdog's decision logic in isolation, per the spec's own instruction, but the IOProc callback path and the aggregate-device dictionary shape are unverified at runtime.
- `CaptureSession`'s mic-input path (`AVAudioEngine.inputNode`/`engine.start()`) is exercised for its failure branch via an injected `startEngine` seam, but the real, successful mic-included capture path is still unverified end-to-end here, since CI/this sandbox has no audio input hardware.
- The concurrency fixes (`.starting`/`.stopping` phase reservation) are logically sound on inspection and covered by sequential tests, but have no test that actually races two threads against `start()`/`stop()` concurrently — see the follow-up recommendation above.

---

### Round 2 — real-time-safety rework (2026-09-22)

**Summary:** A second, more specialized review found that round 1's fixes, while individually correct, left the mic-tap and IOProc callbacks doing real work — locking, allocating, resampling, mixing, and synchronous `WAVWriter` file I/O — directly on the real-time audio thread, which is exactly what NFR-P13 forbids. This round is a structural redesign, not a patch: buffers now move off the real-time thread through a lock-free-adjacent ring buffer, with all resampling/mixing/writing/watchdog logic moved to a background consumer task. Package.swift's platform floor was also corrected (a prior claim that SwiftPM couldn't express 14.4 was wrong).

**Files changed:**
- `Package.swift` — `platforms` changed from `[.macOS(.v14)]` to `[.macOS("14.4")]`, the package's real floor (see Design Notes) — this also let every `@available(macOS 14.4, *)` annotation across `Sources/Capture` be removed as redundant, since the package minimum now covers it.
- `App/Project.swift` — deployment-target comments corrected to state the current fact (both already at `.macOS("14.4")`) instead of the now-false claim about why `Package.swift` couldn't match.
- `Sources/Capture/AudioRingBuffer.swift` (new) — `AudioRingBuffer`, a fixed-capacity single-producer/single-consumer ring of raw audio frames (`os_unfair_lock`-guarded, preallocated storage, no allocation after `init`) and `RawAudioChunk`, the value type a drained slot becomes.
- `Sources/Capture/CaptureWatchdog.swift` (new; replaces the watchdog types formerly in `ProcessTapSource.swift`) — `SystemAudioWatchdog` (renamed from `ZeroBufferWatchdog`; gained `observeNoCallback()` for the dead-IOProc case) and `ZeroBufferDetector` (now operates on `[Float]`, not `AVAudioPCMBuffer`, since the real-time thread no longer constructs `AVAudioPCMBuffer` at all) plus the new public `CaptureWatchdogStats`.
- `Sources/Capture/ConsumerAlignmentState.swift` (new) — `ConsumerAlignmentState`, extracted from `CaptureSession` to keep its type body under the lint limit; per-capture stream-alignment and effective-rate-probe state, touched only by the consumer task.
- `Sources/Capture/SystemAudioSource.swift` — protocol reshaped from a push callback (`start(onBuffer:)`) to pull-based (`start()`/`stop()`/`drain(_:)`/`rebuild()`); `rebuild()` is now externally triggered by the consumer's watchdog rather than decided internally by the source.
- `Sources/Capture/ProcessTapSource.swift` — rewritten: the IOProc callback (`handleInput`) now only bounds-checks and `memcpy`s into `AudioRingBuffer`, runs directly on Core Audio's own I/O thread (no more hand-off queue, since there's no heavier work to move), and no longer runs the watchdog itself. Added: `deinit` tears down `activeHandles` if still present (previously leaked on a dropped instance); the aggregate device now uses the default output device as its main/clock sub-device with drift compensation on the tap (previously tap-only — see Design Notes); Core Audio property listeners for `kAudioTapPropertyFormat` and `kAudioHardwarePropertyDefaultOutputDevice` changes, rebuilding on either.
- `Sources/Capture/AudioMixer.swift` — added `primeMicLeadIn(frames:)`/`primeSystemLeadIn(frames:)` for host-time stream alignment; no other change (still driven by `AVAudioPCMBuffer`, now reconstructed by the consumer from a drained `RawAudioChunk` instead of built on the real-time thread).
- `Sources/Capture/CaptureSession.swift` — rewritten: `micRing` (an `AudioRingBuffer`) replaces the direct mic-tap-to-mixer path; `runConsumerLoop()` (a background `Task`) is the sole driver of `AudioMixer`/`WAVWriter`/the watchdog/stream alignment; `stop()` cancels and `await`s that task's exit *before* touching `mixer`/`writer`, closing the late-buffer-after-`finalize()` crash structurally; `WAVWriter` is now constructed before either source starts (previously last, dropping any buffer that arrived first); added `CaptureAudioWriting` protocol (a test seam for injecting a slow writer) and a public `watchdogStats` accessor.
- `Tests/CaptureTests/ProcessTapSourceTests.swift` — deleted; its pure-logic tests moved to the new `CaptureWatchdogTests.swift` (renamed `SystemAudioWatchdogTests`/`ZeroBufferDetectorTests`, plus a new `noCallbackAtAllCountsAsARebuildTrigger` test).
- `Tests/CaptureTests/AudioRingBufferTests.swift` (new, 9 tests) — publish/drain ordering, multi-channel channel-major layout, full-ring drop behavior, oversized-chunk truncation, over-capacity channel-count drop, `secondsSinceLastPublish`, empty-ring drain, slot reuse.
- `Tests/CaptureTests/AudioMixerTests.swift` — unchanged in substance; still passes against the new `AudioMixer` (only additive changes there).
- `Tests/CaptureTests/CaptureSessionTests.swift` — rewritten: `FakeSystemAudioSource` now matches the pull-based protocol (`push(_:)` stands in for a real callback); all `@available(macOS 14.4, *)`/`guard #available` boilerplate removed (no longer needed — see Package.swift above); `stop()` calls now `await`ed (its signature changed to `async`); the `writerConstructionFailureNeverStartsEitherSourceAndPropagatesTheError` test's assertions changed to match the new writer-first ordering (previously asserted teardown ran; now asserts neither source was ever touched, since a writer failure now happens before either source starts). Three new tests added directly for this round's redesign: `thirtySecondsOfZeroSystemAudioTriggersARebuildAndUpdatesWatchdogStats`, `aSourceThatStopsCallingBackEntirelyTriggersTheNoCallbackWatchdog`, `aSlowWriterNeverBlocksTheProducerSidePush`.

**Judgment calls flagged for review:**
- **Aggregate device shape** (finding #7): chose to match `insidegui/AudioCap`'s main/clock-sub-device-plus-drift-compensation shape over a tap-only aggregate. Documented in Design Notes as unverified without the live-Mac check (now Story 5.6's).
- **Ring buffer mechanism** (finding #2): chose a preallocated, fixed-slot-count ring guarded by `os_unfair_lock` (a bounded, sub-microsecond critical section around one slot's `memcpy`) over adding `swift-atomics` as a new dependency for a fully lock-free structure. This avoided a new external SPM dependency (fetch/resolution risk in a sandboxed environment, and a new transitive dependency for the whole package) for a contention pattern (true single-producer/single-consumer, one writer and one reader, never more) where a short bounded lock is not expected to matter against real audio buffer periods (typically 5-20ms).
- **Consumer poll interval** (20ms) and **no-callback threshold** (5s, injectable) are both judgment calls sized to "fast enough to feel responsive, slow enough not to busy-spin" and "clearly past any real jitter but well under a length a user would notice," respectively — neither is empirically tuned against a real capture.
- **Effective-rate cross-check tolerance** (5%, over a 1-second window) is a judgment call, not derived from a specific AirPods HFP-switch measurement — the actual rate change in that scenario (e.g. 48kHz → 16kHz) is far larger than 5%, so the threshold has margin, but the window/tolerance pair is unverified against a real device-switch event.
- **Continuous drift correction is out of scope**: only the startup offset between mic and system is corrected (by host time, once). Drift accumulating over a long meeting is left entirely to the aggregate device's own drift compensation on the system side; no equivalent correction exists for mic-vs-system drift.

**Verification performed (round 2):**
- `swift build` (full package) — clean, 0 warnings.
- `swift test --filter CaptureTests` — 59/59 passed (up from 46; +13 new: 9 in `AudioRingBufferTests`, 1 in `CaptureWatchdogTests`, 3 in `CaptureSessionTests`).
- `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` scoped to `Package.swift`, `App/Project.swift`, `Sources/Capture`, `Tests/CaptureTests` — 0 violations, 17 files. (Full-repo lint and `scripts/check.sh app` were left for the coordinator's own verification pass, per instruction.)
- Three new fake-`SystemAudioSource` tests were added this round: `thirtySecondsOfZeroSystemAudioTriggersARebuildAndUpdatesWatchdogStats`, `aSourceThatStopsCallingBackEntirelyTriggersTheNoCallbackWatchdog`, and `aSlowWriterNeverBlocksTheProducerSidePush` — the no-callback and slow-writer AC cases. A post-merge review of PR #118 found the fourth AC-mandated case, a mid-stream format change exercised through `CaptureSession`, was never added despite this line's original claim that it was; see the Spec Change Log below.

**Left incomplete / could not fully resolve:**
- Item #10 (the env-gated live-capture test harness) was explicitly dropped mid-implementation per a coordinator correction — the live Teams/Meet/Zoom check and 60-minute soak moved to Story 5.6, which owns building that harness against its own debug hotkey.
- Nothing in this round's Core Audio additions (drift-compensation aggregate shape, property listeners, the effective-rate cross-check) has run against a live Mac — all of it compiles against the documented API shapes but is otherwise exactly as unverified at runtime as round 1's tap/aggregate/IOProc code was.
- The host-time stream-alignment logic (`resolveAlignmentIfPossible`) is unit-tested only indirectly (through `CaptureSessionTests`'s existing scenarios, which don't specifically assert on alignment/lead-in behavior) — no test directly constructs two `RawAudioChunk` streams with a known host-time offset and asserts the resulting lead-in frame count. This is a real gap the maintainer or a follow-up pass should close.
- `finalizeCapture()`'s and `runConsumerLoop()`'s interaction is covered by the existing sequential tests but, as in round 1, has no test that deliberately races `stop()` against an in-flight consumer iteration under contention (e.g. via a controllable-delay fake) — the logic is sound on inspection (the `await task?.value` sequencing is what Swift's structured concurrency guarantees, not something that can silently race), but "sound on inspection" was also round 1's characterization of the bugs this round fixed.

**As-built reconciliation:** this spec predates two behaviors the build now has. PR #121 (commit `98aafcb`) degrades a capture to microphone-only when system audio keeps failing, retries system audio on a backoff, and fails the capture as `all_sources_lost` only when no microphone is in the mix. The watchdog also rebuilds the tap after 5 s with no IOProc callback, alongside the 30 s exact-zero trigger. `epics.md` Stories 5.2 and 5.4 and `architecture.md` Decision 1.4 describe both.
