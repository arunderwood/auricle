# Epic 5 Context: System-Audio Capture & First-Run Onboarding (J0)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Let auricle record meetings itself instead of only importing files. A fresh Mac walks through a trust-building onboarding flow: mic, system audio, notifications, then vault, Obsidian and API key. The user then starts and stops a recording of any meeting app with no bot joining the call. The recording lands as a Whisper-native WAV and flows into the Epic 4 pipeline up to `awaiting_attribution`. The recording indicator is the visible privacy promise. The main window and its Record button are Epic 6, so this epic ships a debug-only trigger to exercise capture end to end.

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

- Captures all system audio from any meeting app (Zoom, Teams, Meet in a browser) plus the user's microphone. Capture is passive: no added latency and no muting. Nothing signals capture to other participants.
- Output is one mono 16kHz PCM 16-bit WAV per meeting in the cache directory. The file is 0600 inside a 0700 directory, and partial audio always survives a failure.
- Nothing blocks a start:
  - A denied microphone records system audio only, and the metadata says so.
  - macOS offers no public way to read or request the System Audio Recording grant, so auricle treats it as unknown. Onboarding triggers the system prompt through `Capture`'s `SystemAudioPermissionProbe`, a 1-second capture. `Permissions` cannot call it, because `Capture` depends on `Permissions`.
- Exact-zero system buffers are ambiguous — silence, a missing grant, or a known OS fault. Never fail a capture on them; count them.
- Idle CPU with the app open and not recording stays ≤1%. The story measures it.
- Onboarding copy is plain and purpose-first, and each permission step has a "why" line. Denied Notifications and a missing API key degrade gracefully and never block.
- Accessibility: VoiceOver labels are set, Reduce Motion disables the pulse, color is never the only signal, and Light, Dark and Increased Contrast all hold.
- The minimum macOS is 14.4, the process-tap floor. Development and testing happen on the current macOS release.

## Technical Decisions

- **System audio comes from a Core Audio global process tap:**
  - The tap excludes auricle's own process and is read through a private aggregate device and an IOProc.
  - The microphone comes from AVAudioEngine.
  - `AudioMixer` resamples both to 16kHz with `AVAudioConverter` and mixes them to mono.
  - A `SystemAudioSource` seam keeps a ScreenCaptureKit fallback swappable; a Story 5.2 live-app gate (Teams, Meet, Zoom) plus a 60-minute soak decide whether the fallback is ever needed.
  - A watchdog rebuilds the tap, the aggregate device and the IOProc after 30s of exact zeros, at most once per 30s, and never fails the capture.
- **`Info.plist` must carry `NSAudioCaptureUsageDescription` as a literal key.** A missing key fails silently with zero buffers. `scripts/check.sh app` asserts the key. `NSScreenCaptureUsageDescription` goes away.
- **`PermissionChecker` is the only place that queries or requests permissions,** enforced by a lint rule:
  - Status values are `.granted`, `.denied`, `.notDetermined` and `.unknown`.
  - `check` and `request` are async, and deep links are `URL?`.
  - Each deep link is verified on the target macOS before it is recorded.
- **Capture runs in the GUI process only.** TCC grants belong to the app bundle. The `auricle record` and `stop` verbs stay stubs until Story 9.5.
- **Capture bypasses the per-stage runner** (it wraps one closure over an existing row; capture is two user-driven calls that can be hours apart):
  - `StateStore.beginCapture` inserts the `recording` row with its start event, `capture_started_at`, `audio_cache_path` and the IANA `capture_time_zone`.
  - `StateStore.finishCapture` is the end transaction.
  - Transitions add capture: `recording` → `captured` or `capture_failed`.
- **After `captured`, the GUI runs the existing pipeline runner in-process** up to review-diarization, so the meeting rests at `awaiting_attribution`.
- **On launch, an orphaned `recording` row is recovered.** If it has audio, its WAV header is repaired and it moves to `captured`. If it has none, it moves to `capture_failed` with reason `interrupted`.
- **`WAVWriter` is the one recorded exemption from the atomic-write rule.** It streams through a `FileHandle` and patches the header on finalize and on recovery, reusing the importer's WAV header code and cache path helpers.
- **Local dates use the stored capture zone,** falling back to the current zone. A re-publish's re-run date uses the current zone, not the capture zone.
- **A reported permission revocation fails the capture:** it saves the partial audio, marks `capture_failed` with `permission_revoked_midstream`, and notifies through a capture-failure notifier call. If notifications are denied, it logs instead. A revocation the OS doesn't report (System Audio) shows up only as exact zeros.
- **GUI logic that needs tests lives in a new `AppUI` SwiftPM target** (covers the recording indicator's appearance mapping, the onboarding coordinator, and the permission and self-wikilink steps). `App/` holds only views and wiring; no snapshot-testing dependency is added.
- **Config is written through a key-preserving `ConfigWriter`,** because the maintainer edits the file by hand. Onboarding runs when no completion marker exists in Application Support, not when the config file is missing (the maintainer already has one).
- **A configured `self.wikilink` wins over the calendar-derived identity;** the default comes from the system account name.

## UX & Interaction Patterns

- Onboarding runs in the existing single window and never opens a new one: Welcome ("4 quick steps"), then Microphone, System Audio, Notifications, Configure, Done.
- A denied permission step offers Open Settings, Skip and Try Again. Try Again appears only while the status is not yet determined.
- The System Audio step never claims success, because the grant cannot be read back.
- The Configure step, in order: vault picker (validates, never creates the vault) → Obsidian check (opens the vault by URL, doesn't block if Obsidian is missing) → self wikilink (pre-filled from the account name, with vault suggestions) → Anthropic API key (skippable) → first-meeting expectations.
- Done shows a quiet "You're set up" state.
- The recording indicator is the privacy contract surface: active state is filled red `record.circle.fill` with a 1.4s pulse and the label "Recording"; idle is outlined with the label "Not recording"; color is never the sole signal and Reduce Motion drops the pulse but keeps the fill. It sits in the window toolbar until Epic 6's header takes it.

## Cross-Story Dependencies

- **Build order, in waves (parallel within a wave):**
  - Wave 1: 5.1, 5.3, 5.10, 5.5 (no dependencies; land 5.5 early because it adds the `AppUI` target that 5.7 needs).
  - Wave 2: 5.2 (needs 5.1, 5.3) and 5.7 (needs 5.10 and `AppUI`).
  - Wave 3: 5.4 (needs 5.2), 5.8 (needs 5.1, 5.2's `SystemAudioPermissionProbe`, 5.7) and 5.9 (needs 5.7, 5.10).
  - Wave 4: 5.6 (needs 5.4, 5.5) — the end-to-end dogfood run.
  - Critical path: 5.1 or 5.3 → 5.2 → 5.4 → 5.6. 5.2's manual live-app gate waits on the maintainer's real calls; 5.4 can start against a fake `SystemAudioSource` before the gate passes, at the risk of rework if it fails.
- **Shared files across stories:** `Package.swift` (5.1, 5.2, 5.4, 5.5), `Info.plist` and `scripts/check.sh` (5.1 only), `StateStore` and `PipelineTransitions` (5.4 only).
- **Later epics/stories own:**
  - Story 6.2: deletes the Story 5.6 debug trigger and moves the recording indicator into the main-window header.
  - Story 6.3: the empty meeting list.
  - Story 9.2: the silent post-onboarding doctor run.
  - Story 9.5: implements the `auricle record` / `stop` CLI verbs and how they reach the running GUI process.
  - Epic 7: the "Set me first…" state for a missing `self.wikilink`.
- **Open maintainer decisions (unresolved, tracked in `deferred-work.md`):**
  - Debug signing: ad-hoc Debug builds likely re-prompt for TCC permissions on every rebuild and may block a GUI-written Keychain item from being read cross-process. Choice is to keep ad-hoc until Story 9.3 or pull its signing identity forward.
  - Capture fallback: if Story 5.2's live check misses Teams, Meet or Zoom audio, the story stops and a correct-course switches `SystemAudioSource` to ScreenCaptureKit, adding the Screen Recording grant back into Stories 5.1 and 5.8.
