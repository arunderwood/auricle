# Epic 5 Context: System-Audio Capture & First-Run Onboarding (J0)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

A fresh Mac takes the user from install through a 4-step permission gauntlet (Microphone, System Audio, Notifications, Configure) to a working recording: system audio from a Core Audio process tap mixed with the microphone into a Whisper-native WAV, captured entirely in the GUI process. Stopping a recording hands the meeting to the existing pipeline through `awaiting_attribution`. This closes the last gap between "auricle can process a recording" (Epics 1-4) and "auricle can make one" — Day-1 trust in the permission flow and in the always-visible recording indicator is the gate to every later day.

## Stories

- Story 5.1: PermissionChecker + TCC Categories + Deep-Link URLs
- Story 5.2: Process-Tap + AVAudioEngine Capture Session + AudioMixer
- Story 5.3: WAVWriter — Streaming PCM 16-bit 16kHz Mono WAV
- Story 5.4: Capture Stage + State-Machine Integration + Crash Recovery + Mid-Capture Revocation
- Story 5.5: RecordingIndicator Atomic Component (Privacy Contract Surface)
- Story 5.6: Throwaway Debug Record Trigger (Epic 6 Deletes It)
- Story 5.7: OnboardingCoordinator + Welcome / Vault / Obsidian / API Key / Expectation Flow
- Story 5.8: J0 Permission Steps (Microphone, System Audio, Notifications)
- Story 5.9: self.wikilink Setup During Onboarding
- Story 5.10: ConfigWriter + `self.wikilink` Key

## Requirements & Constraints

- Capture starts and stops through one prominent control, with a visible recording-state indicator at all times; capture must add no perceivable audio latency to the meeting app (passive loopback only, no chain insertion).
- System audio must cover any meeting platform (Zoom, Meet, Teams, Discord, browser) without per-platform integration; mic and system audio mix into one two-sided recording.
- auricle requests and handles System Audio, Microphone and Notifications permissions with clear in-app explanation on denial; no permission blocks starting a recording.
- User-editable config (vault path, Obsidian, API key, `self.wikilink`, etc.) lives in a plain, hand-editable file under `~/.auricle/`, edited one key at a time without discarding other keys or comments; secrets never land in that file.
- Idle CPU with nothing recording stays ≤1% (measured, not assumed). Cached audio is 0600 in a 0700 directory. Captured/intermediate artifacts stay in user-owned directories only. auricle gives no external indication to meeting participants that capture is occurring — consent is the user's own responsibility.
- Accessibility: full VoiceOver support, color is never the sole conveyor of state, Reduce Motion disables the recording pulse, Dynamic Type and Dark/Light Mode are respected without configuration.
- Each pipeline stage remains idempotent; a denied Notifications permission must never crash or block the pipeline, only silence the notification.

## Technical Decisions

- **Capture backend:** a Core Audio global process tap (excluding auricle's own process) for system audio, `AVAudioEngine` for the microphone, mixed and resampled to 16kHz mono PCM by `AudioMixer`. System audio sits behind a `SystemAudioSource` seam so a ScreenCaptureKit fallback can replace it later without touching the mixer, writer, or stage. A watchdog rebuilds the tap after 30s of exact-zero buffers (at most once per 30s) and never fails the capture outright, since zero buffers can also mean silence or a missing grant. Minimum macOS rises to 14.4, the process-tap floor.
- **Permission model:** macOS exposes no API to read or request the System Audio grant, so `PermissionChecker` always reports it `.unknown`; the only way to trigger its system prompt is a live 1-second tap probe run from `Capture`, not `Permissions`. All TCC/OAuth access goes through `PermissionChecker` — a lint rule blocks direct `AVCaptureDevice`/`UNUserNotificationCenter`/screen-capture API calls elsewhere. `NSAudioCaptureUsageDescription` must exist as a literal Info.plist key (a missing key silently zeroes the buffers).
- **File format:** streamed PCM 16-bit 16kHz mono WAV, written by `WAVWriter` directly through a `FileHandle` with the header patched on finalize and on crash recovery. This is the one recorded exemption from `AtomicWriter` — a large stream that must survive a crash partially cannot be written atomically.
- **State machine / process boundary:** capture is long-running and stays in the GUI process only (TCC grants belong to the app bundle); it bypasses `StageRunner.run` (built for one closure over an existing row) via new `StateStore.beginCapture`/`finishCapture` calls and a `(.capture, .recording) → [.captured, .captureFailed]` transition. On stop, the GUI runs the rest of the pipeline in-process up to `awaiting_attribution`. A `recording` row with no live session on launch is crash-recovered: header repair to `captured` if bytes exist, else `capture_failed` (reason `interrupted`). `auricle record`/`stop` remain CLI stubs until a later epic decides how they reach the running app.
- **Config:** a new `Core` `ConfigWriter` edits one TOML key at a time in `~/.auricle/config.toml` through `AtomicWriter`, preserving unrelated keys/comments; it backs both onboarding and `auricle config set`. Onboarding gates on a completion marker in Application Support, not on config-file presence.
- **GUI testability:** a new `AppUI` SwiftPM target holds GUI view models and SwiftUI components with real logic (covered by `swift test`); `App/` stays thin wiring so nothing epic-5-specific lands untested.

## UX & Interaction Patterns

- Onboarding (J0) is a linear gauntlet: Welcome → Microphone → System Audio → Notifications → Configure (vault path, Obsidian check, API key, `self.wikilink`, expectations) → quiet "You're set up" state. Each permission step carries a *why* line before the system prompt, so the TCC dialog is never a surprise. No onboarding theatrics — this is a permission flow, not a marketing intro.
- Denials never terminally block: a denied microphone records system-audio-only with a settings deep link; the System Audio step can't confirm the grant, so it just explains where to check; denied notifications leave the meeting visible in the main window instead. Calendar connection is out of scope for onboarding.
- The recording indicator is the privacy-contract surface: active state pairs a filled red `record.circle.fill` with a gentle pulse (disabled under Reduce Motion) and the text label "Recording" — color is never the only signal. It shows in the window toolbar for this epic; a later epic moves it into the main-window header.
- `self.wikilink` defaults to the system account name, is user-editable during onboarding, and always wins over any later calendar-derived guess.

## Cross-Story Dependencies

- Build order runs in waves: (1) 5.1, 5.3, 5.10, 5.5 — no dependencies, and 5.5 must land early because it adds the `AppUI` target that 5.7 needs; (2) 5.2 (needs 5.1, 5.3) and 5.7 (needs 5.10 and `AppUI`); (3) 5.4 (needs 5.2), 5.8 (needs 5.1, 5.2's probe, 5.7), 5.9 (needs 5.7, 5.10); (4) 5.6, the end-to-end dogfood story.
- Critical path: 5.1/5.3 → 5.2 → 5.4 → 5.6. Every story before 5.6 relies on automated tests only; 5.6 is the first story with an ergonomic way to trigger a real recording, so it carries the risk that a live meeting app behaves differently from the fakes used in 5.2/5.4.
- Forward references, all owned by later epics: the main-window Record button and moving the recording indicator into the header; the empty meeting-list state; running Doctor once after onboarding; implementing the real `auricle record`/`stop` verbs; the "Set me first…" affordance when `self.wikilink` is missing.
- Shared files across stories: `Package.swift` (5.1, 5.2, 5.4, 5.5); `Info.plist`/`scripts/check.sh` (5.1 only); `StateStore`/`PipelineTransitions` (5.4 only). `AppUI` depends on `Capture` for 5.8's System Audio probe.
- **Open maintainer decision (signing):** ad-hoc Debug signing likely re-prompts for permissions on every rebuild and may block cross-process Keychain reads; stays ad-hoc until Story 9.3, unless its signing identity gets pulled forward sooner.
- **Open maintainer decision (capture fallback):** if a real meeting recorded in 5.6 misses the far side, switching `SystemAudioSource` to ScreenCaptureKit brings the Screen Recording grant back into 5.1 and 5.8.
