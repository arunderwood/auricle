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
- The macOS floor is the tap's minimum, 14.4. SwiftPM's `SupportedPlatform.MacOSVersion` has no `.v14_4` case (verified against the installed toolchain's `PackageDescription.swiftinterface` — only whole-number cases exist), so `Package.swift`'s `platforms: [.macOS(.v14)]` cannot express it and stays as-is. Enforce 14.4 instead with `@available(macOS 14.4, *)` on every tap-touching declaration, and by bumping both `App/Project.swift:58` and `:73` `deploymentTargets` from `.macOS("14.0")` to `.macOS("14.4")` (Tuist's string form takes any minor version).

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
- This spec file, `## Auto Run Result` -- record the manual live-app check (Teams, Meet in Chrome, Zoom, 5 minutes each) and the 60-minute soak (exact-zero seconds, watchdog rebuilds, whether an ad-hoc rebuild re-prompts for System Audio Recording) -- AC's manual verification; needs the maintainer, see Design Notes

**Acceptance Criteria:**
- Given the `Capture` target, when `CaptureSession(meetingID:)` is instantiated, then system audio comes through the `CATapDescription`-based `SystemAudioSource` and the microphone through `AVAudioEngine`, mixed by `AudioMixer` into mono 16kHz PCM16
- Given `Capture`, when `SystemAudioPermissionProbe.prompt()` runs, then it performs a 1-second discarded capture so macOS shows the System Audio Recording prompt
- Given `Tests/CaptureTests/`, when the suite runs, then it covers `AudioMixer` resampling/mixing, the watchdog rebuild rule, the mic-denied path, and idempotent start/stop
- Given the manual Teams/Meet/Zoom check fails on the maintainer's Mac, then this is recorded as a correct-course trigger for the ScreenCaptureKit fallback per epics.md, not silently marked done

## Spec Change Log

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



**Why `Package.swift` stays at `.macOS(.v14)`:** confirmed against the installed toolchain (`PackageDescription.swiftinterface`) that `SupportedPlatform.MacOSVersion` only defines whole-number cases (`.v14`, `.v15`, …) — there is no way to declare a 14.4 floor at the SwiftPM manifest level. The real floor is enforced by `@available(macOS 14.4, *)` on `ProcessTapSource` (and anything else touching `CATapDescription`) plus the two `App/Project.swift` deployment-target bumps, which Tuist does accept as arbitrary version strings.

**Reference implementation:** no tap/aggregate-device/IOProc code exists anywhere in this repo yet — this is the first. `insidegui/AudioCap` (referenced in the research doc as high-confidence, since it is the one source that documents the full setup chain) is the closest known-good shape for the aggregate-device creation and IOProc registration; use it to avoid inventing an incorrect Core Audio call sequence, not to copy verbatim.

**Unresolved manual verification (needs the maintainer, not more code):** this run has no way to join a live Teams/Meet/Zoom call or run an unattended 60-minute capture soak. Per epics.md's own AC, these gate the backend choice itself — a failed live check is what would trigger the ScreenCaptureKit correct-course, not a fixable code defect. Both are recorded here as outstanding rather than resolved:
- 5 minutes each from Microsoft Teams, Google Meet in Chrome, and Zoom, confirming the far side is audible in `audio.wav`.
- A 60-minute soak reporting exact-zero seconds, watchdog rebuild count, and whether an ad-hoc rebuild of the app re-prompts for System Audio Recording.

## Verification

**Commands:**
- `swift build && swift test --filter CaptureTests` -- expected: builds clean, new tests pass
- `mise exec -- swiftlint lint --config .swiftlint.yml --strict .` -- expected: no violations
- `scripts/check.sh app` -- expected: passes at the bumped 14.4 deployment target

**Manual checks (if no CLI):**
- 5-minute capture each from Microsoft Teams, Google Meet in Chrome, and Zoom on the maintainer's Mac -- expected: the far side is audible in the resulting `audio.wav`
- 60-minute capture soak on the maintainer's Mac -- expected: report of exact-zero seconds, watchdog rebuild count, and whether an ad-hoc app rebuild re-prompts for System Audio Recording

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

**Residual risks:**
- `ProcessTapSource`'s Core Audio glue (tap/aggregate device/IOProc creation and teardown) has no automated test coverage — it cannot be exercised without a live Mac and a live System Audio Recording grant, which this run had neither of. `ProcessTapSourceTests` covers the watchdog's decision logic in isolation, per the spec's own instruction, but the IOProc callback path and the aggregate-device dictionary shape are unverified at runtime.
- `CaptureSession`'s mic-input path (`AVAudioEngine.inputNode`/`engine.start()`) is exercised for its failure branch via an injected `startEngine` seam, but the real, successful mic-included capture path is still unverified end-to-end here, since CI/this sandbox has no audio input hardware.
- The concurrency fixes (`.starting`/`.stopping` phase reservation) are logically sound on inspection and covered by sequential tests, but have no test that actually races two threads against `start()`/`stop()` concurrently — see the follow-up recommendation above.
