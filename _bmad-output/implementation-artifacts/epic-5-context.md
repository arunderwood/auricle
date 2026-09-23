# Epic 5 Context: System-Audio Capture & First-Run Onboarding (J0)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

On a fresh Mac, a user grants permissions through a 4-step onboarding gauntlet, starts a recording, and auricle captures the meeting (system audio from a Core Audio process tap, mixed with the microphone) into a Whisper-native WAV file; the pipeline then advances automatically to `awaiting_attribution`. Capture runs only inside the GUI process in this epic — the CLI `record`/`stop` verbs stay stubs. The `RecordingIndicator` is the visible proof of the app's privacy contract, and mid-capture permission revocation is handled so partial audio is never silently lost. This is the epic that turns the pipeline (built in Epics 1–4) from "runs on pre-existing recordings" into "runs on audio auricle itself captured."

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

- Start/stop capture via a prominent control (the button itself lands in Epic 6; this epic wires the underlying path), with an unambiguous recording-state indicator visible throughout.
- System audio must capture without any per-platform integration (Zoom, Meet, Teams, Discord, browser audio all work the same way) and mix with the microphone into one recording.
- Permission requests explain themselves in plain language and degrade gracefully on denial — nothing about starting a recording is ever blocked by a missing grant; missing permissions are detectable on launch with a clear remediation path.
- User-editable config lives in a plain, hand-editable file under `~/.auricle/`, edited key-by-key without disturbing other keys/comments; secrets never go there.
- Idle CPU stays ≤1% when not recording; active capture adds no perceivable audio latency to the meeting app; cached audio is 0600 and confined to user-owned directories; auricle gives other participants no indication capture is occurring.
- Accessibility: real VoiceOver labels, state never conveyed by color alone, Reduce Motion simplifies/removes animation. Every stage stays idempotent; a revoked Notifications permission degrades to a log line, never a crash.

## Technical Decisions

- **Capture backend:** system audio comes from a Core Audio global process tap excluding auricle's own process (aggregate device + IOProc); the microphone comes from `AVAudioEngine`. Both feed an `AudioMixer` that resamples to 16kHz mono PCM-16. System audio sits behind a `SystemAudioSource` seam so ScreenCaptureKit can replace the tap later without touching the mixer/writer/stage — the recorded fallback if live testing against Teams/Meet/Zoom fails. macOS floor rises to 14.4 (the tap's minimum). A watchdog rebuilds the tap/device/IOProc after 30s of exact-zero buffers (max once per 30s) but never fails the capture, since exact zeros are indistinguishable from silence, a missing grant, or a real fault.
- **`WAVWriter` is the one recorded exemption from atomic temp-write+rename:** a ~115MB stream that must survive a crash partially can't be written atomically. It streams via `FileHandle`, creates the file 0600 in a 0700 directory up front, and patches the RIFF/data header on finalize or crash-recovery repair.
- **Capture bypasses the per-stage `StageRunner`** (built for one closure over an existing row) since start/stop are independent, user-paced calls hours apart. `StateStore.beginCapture`/`finishCapture` run the same start/end two-transaction pattern directly; `(.capture, .recording) → [.captured, .captureFailed]` is added to the transition table. No permission ever blocks a start. An orphaned `recording` row with no live session is repaired at next launch: audio bytes present → header repaired, moves to `captured`; none → `capture_failed` (`interrupted`).
- **Mid-capture revocation the OS reports** finalizes the partial WAV, moves to `capture_failed` (`permission_revoked_midstream`), and notifies (or logs `warn` if notifications are denied). A revocation the OS doesn't report only shows as exact zeros. Transient stream errors restart inline, capped at 3 within 30s before failing permanently.
- **Time zone:** `capture_started_at` is UTC; a new nullable `meetings.capture_time_zone` stores the IANA zone at capture start (NULL for imported rows). Note/filename dates use that zone, falling back to the current zone when NULL; a re-run's date suffix always uses the *current* zone.
- **`PermissionChecker`** is the sole choke point (lint-enforced) for TCC state across four categories (system-audio, microphone, notifications, calendar OAuth) and four statuses (granted/denied/notDetermined/unknown). System-audio always reports `unknown` (no read API exists); its actual OS prompt fires separately through `Capture`'s `SystemAudioPermissionProbe`, since `Permissions` can't depend on `Capture`. Status is memoized per process, invalidated by `refresh()`. Each category maps to a verified System Settings deep link except calendar OAuth (a re-auth flow instead). The literal `NSAudioCaptureUsageDescription` Info.plist key is required — a missing key silently zero-buffers capture.
- A new **`AppUI`** SwiftPM target holds GUI view models/components with real logic so `swift test` covers them; `App/` stays thin views-and-wiring, and no snapshot-testing dependency is introduced.
- **`ConfigWriter`** (in `Core`) edits one key at a time in `~/.auricle/config.toml` atomically, preserving every other key/comment, and never writes secrets; `Config` gains `selfWikilink: String?`. Onboarding gates on a completion marker in Application Support, not config-file presence. `self.wikilink` pre-fills from the system account name and, once set, always wins over a later calendar-derived identity.

## UX & Interaction Patterns

- J0 flow: Welcome (names the 4 steps, no TCC prompt yet) → Microphone → System Audio → Notifications → Configure (vault path, `self.wikilink`, Obsidian-open check, API key, first-meeting expectations) → quiet "you're set up" Done. Each permission step shows a plain-language *why* line before the system dialog, so it's never a surprise. Denials never hard-block: denied mic still records (system-audio-only) with a settings deep link; the System Audio grant can't be read back, so copy hedges ("if you chose Allow, you're done…"); denied Notifications just goes quiet, with the meeting list as fallback visibility.
- `RecordingIndicator` is a pure `(isRecording, reduceMotion) → appearance` mapping: active = filled red icon pulsing 0.7↔1.0 over 1.4s (no pulse under Reduce Motion) + label "Recording"; idle = outline icon, secondary tint, "Not recording." Label always accompanies the symbol — color is never the sole signal. Lives in the window toolbar this epic; Epic 6 moves it into the main-window header.
- A `#if DEBUG`-only Cmd-Shift-R record/stop trigger stands in for the real Record button so capture can be exercised before Epic 6 exists.

## Cross-Story Dependencies

- **Build order:**
  - Wave 1, all parallel: 5.1, 5.3, 5.10, 5.5. Land 5.5 early, because it adds the `AppUI` target.
  - Wave 2: 5.2 (after 5.1 and 5.3) and 5.7 (after 5.10 and `AppUI`).
  - Wave 3: 5.4 (after 5.2), 5.8 (after 5.1, 5.2's probe and 5.7), and 5.9 (after 5.7 and 5.10).
  - Wave 4: 5.6 (after 5.4 and 5.5), the dogfood run.
  - Critical path: 5.1 or 5.3 → 5.2 → 5.4 → 5.6.
- **No story asks the maintainer for live testing before a facility for it exists.** Stories 5.1–5.5 are done on automated tests. Story 5.6's debug Record hotkey is the first ergonomic way to capture, so the live check of the process tap happens there, through the maintainer's normal Teams, Meet and Zoom meetings, with the evidence read from `stage_events` capture metadata. A real meeting whose far side is missing triggers a correct-course to the ScreenCaptureKit fallback.
- **Later epics own:**
  - Story 6.2: deleting the debug trigger and moving the indicator
  - Story 6.3: the empty meeting list
  - Story 9.2: the silent post-onboarding doctor run
  - Story 9.5: the `record` and `stop` CLI verbs and how they reach the app
  - Epic 7: the "Set me first…" state
- **Open maintainer decision:** ad-hoc Debug signing likely makes each rebuild re-prompt for permissions, and it may block cross-process Keychain reads. The choice is to keep ad-hoc until Story 9.3 or pull its signing identity forward.
- Shared files across stories: `Package.swift` (5.1, 5.2, 5.4, 5.5, 5.7); `Info.plist`/`scripts/check.sh` (5.1 only); `StateStore`/`PipelineTransitions` (5.4 only).
