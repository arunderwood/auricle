# Digest reality-r1-1: SCStream vs Core Audio process taps (adoption, bugs, privacy UX, effort)

Accessed: 2026-09-22. Budget used: 15 tool calls, 12 distinct sources.

## Findings

1. **Claim:** The permission pane (Sonoma 14.4+) has a "System Audio Recording Only" tier, separate from full screen recording. Apps that capture through ScreenCaptureKit (OBS's "macOS Audio Capture" source, OBS 30.1) failed to start when the user granted only that tier. So the audio-only grant does not cover SCStream audio.
   - Source: https://github.com/obsproject/obs-studio/issues/10401 · publisher: obsproject (GitHub) · pub_date: 2024-03-18 (older than 12 months) · confidence: medium (the reporter did not check the API; the issue is closed, but the fetch did not show how it was resolved) · class: ux

2. **Claim:** A TypeWhisper issue proposes moving from ScreenCaptureKit to Core Audio taps. Reasons given: taps need only "System Audio Recording" instead of "Screen & System Audio Recording"; the prompt then clearly says audio only; SCK needs a dummy 2x2 video stream; and a narrower prompt should earn more user trust. Stated cost: the minimum OS rises from 12.3 to 14.4. The issue is still open and unimplemented.
   - Source: https://github.com/TypeWhisper/typewhisper-mac/issues/495 · publisher: TypeWhisper (GitHub) · pub_date: 2026-05-08 · confidence: medium (a proposal, not a shipped migration) · class: adoption / ux

3. **Claim:** Meetily, an open-source local notetaker, ships both a ScreenCaptureKit backend and a Core Audio tap backend on macOS and lets the user pick one. A bug report says a naming error in the UI disabled the SCK backend by mistake. The same report says SCK matters for Bluetooth-headset users, where the Core Audio path may miss the other participants' audio.
   - Source: https://github.com/Zackriya-Solutions/meetily/issues/509 · publisher: Zackriya-Solutions (GitHub) · pub_date: not captured (read from the search summary; the issue was not fetched) · confidence: low-medium · class: adoption / bug

4. **Claim:** In meeting-transcriber, a Core Audio tap (CATapDescription) records pure silence (peak=0, RMS=0) from Microsoft Teams on macOS Tahoe 26.4, on every output device. The root cause is not known; the reporter's guesses are WebRTC or helper-process routing, or Teams' 24 kHz output rate. The reporter says Jamie and Muesli, which capture through ScreenCaptureKit, do record Teams audio. The issue is open.
   - Source: https://github.com/pasrom/meeting-transcriber/issues/79 · publisher: pasrom (GitHub) · pub_date: 2026-04-01 · confidence: medium (one reporter; the claim about competitors' APIs is second-hand) · class: bug / adoption

5. **Claim:** On macOS 26.5 beta (M2), a process tap plus aggregate device starts delivering all-zero buffers after several minutes, even though audio is audible. The IOProc keeps firing with normal timestamps. Observed zero spans ran from 53 s to 16 min 3 s. Restarting the IOProc or recreating only the aggregate device does not reliably fix it. You have to destroy and recreate both the tap and the aggregate device. The poster suspects sample-rate renegotiation or Bluetooth state changes, unconfirmed. There is no Apple reply and no fix is recorded. Detecting the fault automatically is risky because it looks like real silence.
   - Source: https://developer.apple.com/forums/thread/825780 · publisher: Apple Developer Forums · pub_date: 2026-05 · confidence: medium (one report, no Apple confirmation; whether it is fixed in 26.x GA is unknown) · class: bug

6. **Claim:** Recall.ai says process taps are hard to use for browser-based meetings, because the meeting audio can come from a renderer or helper process rather than the browser's main process. It also says taps leave the developer to handle sync, mute-state detection, and mic/speaker device changes.
   - Source: https://www.recall.ai/blog/core-audio-taps · publisher: Recall.ai (vendor blog; it sells a desktop recording SDK, so downgrade accordingly) · pub_date: 2026-07-08, updated 2026-09-17 · confidence: medium · class: bug / effort
   - Note: the same page says "ScreenCaptureKit can be used for microphone capture (macOS 16+)". There is no macOS 16, so this is likely an error for macOS 15. Treat it as unreliable.

7. **Claim:** Audio Hijack (Rogue Amoeba) moved to "a new audio capture backend" on macOS 14.4+. It needs "System Audio Access" permission, with microphone access optional, and no longer needs an installed extension or an admin password. While it captures, a purple dot shows in the menu bar. Rogue Amoeba says the dot is "entirely controlled by Apple" and cannot be hidden. The page does not name the API. That it is process taps is inferred from the 14.4 cutoff and the "system audio" wording, not stated.
   - Source: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack · publisher: Rogue Amoeba · pub_date: not shown · confidence: high for the permission and indicator facts, low for the API inference · class: ux / adoption

8. **Claim:** Since Sequoia, apps using screen-recording capture that bypasses the picker get a recurring prompt. It reads "[App] is requesting to bypass the system private window picker and directly access your screen and audio…" and offers "Allow For One Month". Apple first planned a weekly prompt and moved to monthly after pushback. The sources do not say whether Tahoe changes this.
   - Source: https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/ (also https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/) · publisher: 9to5Mac / MacRumors · pub_date: 2024-08-14/15 (older than 12 months) · confidence: medium-high for Sequoia behavior, unverified for Tahoe · class: ux

9. **Claim:** Granola requires microphone access and an entry under "Screen & System Audio Recording" in Privacy & Security, and needs macOS 14 or later. Its docs describe the prompt as "system audio" and never name the capture API. The minimum of 14 is not 14.2/14.4, which is weak evidence against a taps-only implementation, but this is not established.
   - Source: https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time · publisher: Granola · pub_date: not shown · confidence: high for requirements, low for API inference · class: adoption / ux

10. **Claim:** AudioCap, insidegui's reference sample for macOS 14.4+, needs `NSAudioCaptureUsageDescription`. It uses a private TCC API only to check permission ahead of time, behind a build flag; otherwise the prompt appears the first time recording starts. The author says the API "is poorly documented and the nature of CoreAudio makes it really hard to figure out exactly how to set things up". The flow is: PID to audio object, CATapDescription, aggregate device, IOProc.
    - Source: https://github.com/insidegui/AudioCap · publisher: insidegui (GitHub) · pub_date: undated README (project from about 2024) · confidence: high · class: effort

11. **Claim:** The AudioTee author says knowledge of the tap API "is sparse and the documentation is lacking". The author adds that the docs, read closely, do explain it fairly well but are easy to miss. AudioTee is a CLI that pipes tap audio to Node for real-time ASR; AudioTee.js wraps it. So there are community wrappers and forks: AudioTee, AudioCapCLI, and a Node SCK addon (screencapturekit-audio-capture).
    - Source: https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos · publisher: Strongly Typed (developer blog) · pub_date: 2025-06-17 (just over 12 months) · confidence: high · class: effort

12. **Claim:** Apple now publishes official sample code, "Capturing system audio with Core Audio taps". The documentation gap is partly closed, compared with the 2024 complaints.
    - Source: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps · publisher: Apple · pub_date: not captured (page not fetched; existence seen in search results only) · confidence: medium · class: effort

## Leads worth chasing
- Muesli and Jamie: the claim that they use ScreenCaptureKit and capture Teams audio. Confirm from their docs or changelogs.
- Meetily source `audio/capture/core_audio.rs` and issue #509: which backend is the default, and the Bluetooth rationale in detail.
- The zero-buffer bug (thread 825780): whether it reproduces on 26.x GA, and any Feedback ID.
- Whether Tahoe 26 changed the monthly "bypass private window picker" prompt, and whether that prompt ever fires for audio-only SCStream (no display capture) or for taps.
- Whether the purple menu-bar dot differs between taps and SCStream. Rogue Amoeba confirms only a purple dot for its own capture.
- OBS issue #10401: how it was resolved.
- sudara's gist (https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) as a minimal tap sample: count its lines.
- The miniaudio issue #875 (tap loopback) for cross-platform library pitfalls.

## Looked for, not found
- Primary evidence of the capture API used by Granola, MacWhisper, Notion AI meeting notes, Jump, Loom, or Zoom. None found this run.
- Swift 6 strict-concurrency friction (non-Sendable CMSampleBuffer, real-time IOProc closures) for either API. No source retrieved.
- SCStream audio dropouts, or the stream stopping on display sleep or lock. No 2025–26 source retrieved.
- Tap failure after headphone or Bluetooth device change as a confirmed bug. It appears only as a suspected trigger (finding 5) and as a Bluetooth caveat (finding 3).
- Whether other meeting participants or the captured apps get any signal. Nothing retrieved. That they get none is an unverified belief.
- A line count for a minimal working sample of either API.
