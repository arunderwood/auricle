# Epic 5 Context: System-Audio Capture & First-Run Onboarding (J0)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

On a fresh Mac, the user grants permissions through a 4-step onboarding flow, starts a recording, and auricle captures the meeting into a Whisper-native WAV: system audio from a Core Audio process tap, mixed with the microphone. The pipeline then advances on its own to `awaiting_attribution`. In this epic capture runs only inside the GUI process, and the CLI `record`/`stop` verbs stay stubs. The `RecordingIndicator` is the visible proof of the app's privacy contract. A mid-capture permission revocation must never silently lose partial audio. Epics 1–4 built a pipeline that runs on existing recordings; this epic makes it run on audio auricle captured itself.

## Stories

- Story 5.1: PermissionChecker + TCC Categories + Deep-Link URLs
- Story 5.2: Process-Tap + AVAudioEngine Capture Session + AudioMixer
- Story 5.3: WAVWriter — Streaming PCM 16-bit 16kHz Mono WAV
- Story 5.4: Capture Stage + State-Machine Integration + Crash Recovery + Mid-Capture Revocation
- Story 5.5: RecordingIndicator Atomic Component (Privacy Contract Surface)
- Story 5.6: Throwaway Debug Record Trigger (Epic 6 deletes it)
- Story 5.7: OnboardingCoordinator + Welcome / Vault / Obsidian / API Key / Expectation Flow
- Story 5.8: J0 Permission Steps (Microphone, System Audio, Notifications)
- Story 5.9: self.wikilink Setup During Onboarding
- Story 5.10: ConfigWriter + `self.wikilink` Key

## Requirements & Constraints

- System audio is captured without any per-platform integration (Zoom, Meet, Teams, Discord and browser audio all work the same way) and is mixed with the microphone into one recording. FaceTime is out of scope.
- Permission requests explain themselves in plain language. A denial degrades gracefully, and no missing grant ever blocks starting a recording.
- User-editable config is a hand-editable file under `~/.auricle/`, edited one key at a time without disturbing other keys or comments. Secrets never go there.
- Idle CPU is at most 1% when not recording. Capture adds no perceivable latency to the meeting app. Cached audio is 0600 inside user-owned 0700 directories. Other participants get no signal that capture is happening.
- Accessibility: real VoiceOver labels, state is never shown by color alone, and Reduce Motion removes animation. Stages stay idempotent. A revoked Notifications permission degrades to a log line, never a crash.

## Technical Decisions

- **Capture backend:** a global process tap that excludes auricle's own process (private aggregate device + IOProc) supplies system audio. `AVAudioEngine` supplies the microphone. `AudioMixer` resamples both to 16kHz mono PCM-16. System audio sits behind a `SystemAudioSource` seam, so ScreenCaptureKit can replace the tap without changes elsewhere; that is the fallback if a real meeting loses its far side. The macOS floor is 14.4. A watchdog rebuilds the tap after 30s of exact-zero buffers, at most once per 30s. It never fails the capture, because exact zeros look the same as silence or a missing grant.
- **Capture threading contract:** the mic tap and the IOProc callbacks do no work on the real-time thread beyond publishing frames into a per-source ring buffer. A single background consumer task drains the rings, mixes, and is the only caller of `WAVWriter`. `stop()` stops the sources and awaits the consumer's exit before `finalize()`. `WAVWriter` has no locking of its own, so it must stay single-writer.
- **`WAVWriter` is the one exemption from `AtomicWriter`.** It writes a streamed `FileHandle` file, created 0600 up front. The RIFF/data header is patched on finalize, or by `repairHeader(at:)` during crash recovery.
- **Capture bypasses `StageRunner`.** Start and stop are separate user-paced calls, possibly hours apart. `StateStore.beginCapture` and `finishCapture` use the same two-transaction pattern. The transition table gains `(.capture, .recording) → [.captured, .captureFailed]`. At launch, an orphaned `recording` row with audio bytes gets its header repaired and moves to `captured`. One with no audio moves to `capture_failed` (`interrupted`). After `captured`, the GUI runs `PipelineRunner` in-process up to `.reviewDiarization`.
- **Revocation:** a revocation the OS reports finalizes the partial WAV and moves the meeting to `capture_failed` (`permission_revoked_midstream`). It notifies through `Notifier.fireCaptureFailed`, or logs a `warn` when notifications are denied. A revocation the OS doesn't report shows only as exact zeros. Transient stream errors restart inline; the third within 30s fails the capture. The completion metadata records `mic_included`, `exact_zero_seconds` and `tap_rebuilds`.
- **Time zone:** `capture_started_at` is UTC. A nullable `meetings.capture_time_zone` column holds the IANA zone; it is NULL for imported rows. Note and filename dates use that zone, falling back to the current zone. A re-run's date suffix always uses the current zone.
- **`PermissionChecker`** is the only way to read TCC state, and a lint rule enforces it. It has four categories and four statuses (`granted`/`denied`/`notDetermined`/`unknown`). System audio always reports `unknown` because macOS has no API to read it. Its prompt is fired by `Capture`'s `SystemAudioPermissionProbe`, since `Permissions` can't depend on `Capture`. Results are memoized until `refresh()`. `NSAudioCaptureUsageDescription` must be a literal Info.plist key: without it, capture silently returns zero buffers.
- **`AppUI`** is a SwiftPM target for GUI view models and components that contain logic, so `swift test` covers them. `App/` holds only thin views and wiring. No snapshot-testing dependency.
- **`ConfigWriter`** (in `Core`) sets one key atomically and preserves the rest of the file. `Config` gains `selfWikilink`. Onboarding runs until a completion marker exists in Application Support; whether a config file exists doesn't matter. A configured `self.wikilink` wins over the calendar-derived identity. Its default comes from the system account name.

## UX & Interaction Patterns

- J0 flow: Welcome names the 4 steps and fires no prompt. Then Microphone, System Audio, Notifications, and Configure: vault path, then `self.wikilink`, the Obsidian URL check (opens a URL, writes no note), the API key (skippable), and first-meeting expectations. It ends on a quiet "You're set up."
- Each permission step shows a *why* line before the system dialog. A denied mic still records system audio only, with a Settings deep link. The System Audio grant can't be read back, so its copy hedges and never claims success. A denied Notifications grant just goes quiet.
- `RecordingIndicator` is a pure mapping from `(isRecording, reduceMotion)` to an appearance. Active: filled red symbol pulsing 1.0→0.7→1.0 over 1.4s (no pulse under Reduce Motion), labeled "Recording". Idle: outline symbol, secondary tint, "Not recording". A label always accompanies the symbol. It lives in the window toolbar for this epic.
- A `#if DEBUG`-only `Cmd-Shift-R` menu trigger stands in for the Record button until Epic 6.

## Cross-Story Dependencies

- **Build order:**
  - Wave 1: 5.1, 5.3, 5.10 and 5.5. 5.5 adds `AppUI`.
  - Wave 2: 5.2 (needs 5.1 and 5.3) and 5.7 (needs 5.10 and `AppUI`).
  - Wave 3: 5.4 (needs 5.2), 5.8 (needs 5.1, 5.2's probe and 5.7) and 5.9 (needs 5.7 and 5.10).
  - Wave 4: 5.6 (needs 5.4 and 5.5).
  - Critical path: 5.2 → 5.4 → 5.6.
- **No live-testing asks before 5.6.** Every earlier story is done on automated tests. The live check of the tap happens in 5.6, through the maintainer's normal Teams, Meet and Zoom meetings, with evidence read from `stage_events` capture metadata. A missing far side triggers a correct-course to ScreenCaptureKit.
- **Owned by later epics:** 6.2 deletes the debug trigger and moves the indicator. 6.3 owns the empty list. 9.2 owns the post-onboarding doctor run. 9.5 owns the CLI `record`/`stop` verbs. Epic 7 owns "Set me first…".
- **Open questions:**
  - Ad-hoc Debug signing may make TCC re-prompt on every rebuild and block cross-process Keychain reads. The choice is to keep ad-hoc until 9.3 or pull 9.3's signing identity forward.
  - Nobody has confirmed whether macOS still shows `NSUserNotificationsUsageDescription`.
  - `obsidian://open?vault=` may not resolve a vault Obsidian has never opened.
- Shared files: `Package.swift` (5.1, 5.2, 5.4, 5.5, 5.7). `StateStore`/`PipelineTransitions` (5.4 only).
