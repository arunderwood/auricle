# Digest api-r1-1: API capability of SCStream audio vs Core Audio process taps

Accessed for all sources: 2026-09-22. Apple doc pages were read through their DocC JSON endpoints (`developer.apple.com/tutorials/data/documentation/...json`), because the HTML pages render client-side. Many Apple symbol pages have no abstract text, so some findings rest on the symbol name and signature alone. Those findings are marked as such.

## Findings

### Q1: Global vs per-process capture, late-starting processes, excluding your own app

1. **Claim:** A Core Audio tap can be global or scoped to specific processes. `CATapDescription` has global initializers (`init(stereoGlobalTapButExcludeProcesses:)`, `init(monoGlobalTapButExcludeProcesses:)`), per-process initializers (`init(stereoMixdownOfProcesses:)`, `init(monoMixdownOfProcesses:)`), and device-bound initializers (`init(processes:deviceUID:stream:)`, `init(excludingProcesses:deviceUID:stream:)`). The global initializers take an exclude list, which is the documented way to leave out your own process. Scope semantics are inferred from the initializer names; the symbols have no abstracts.
   - Source: https://developer.apple.com/documentation/coreaudio/catapdescription | Apple | pub_date: undated (living doc) | confidence: medium | class: capability
2. **Claim:** In macOS 26.0, `CATapDescription.bundleIDs` is new: "each String holds the bundle ID of a process to tap or exclude." Taps can now target or exclude processes by bundle ID, not only by live `AudioObjectID`.
   - Source: https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids | Apple | pub_date: macOS 26.0 SDK | confidence: high | class: versions-compat
3. **Claim:** In macOS 26.0, `CATapDescription.isProcessRestoreEnabled` is new: "True if this tap should save tapped processes by bundle ID when they exit, and restore them to the tap when they start up again." This is Apple's answer to processes that exit and relaunch during a per-process tap. The doc does not say whether it covers a new helper process that shares a bundle ID but was never tapped.
   - Source: https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled | Apple | pub_date: macOS 26.0 SDK | confidence: high | class: versions-compat
4. **Claim:** A tap "can specify which outputs it captures from a process or group of processes," and taps can be private ("only visible inside the process that created the tap").
   - Source: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps | Apple sample code | pub_date: undated. The page metadata lists macOS 26.0; the sample needs macOS 14.2+. | confidence: high | class: capability
5. **Claim:** `SCStreamConfiguration.excludesCurrentProcessAudio` is "A Boolean value that indicates whether to exclude audio from your app during capture." SCStream audio has been available since macOS 12.3 (per the doc's availability list; the 13.0 date some sources give comes from the OBS PR title).
   - Source: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration | Apple | pub_date: living doc | confidence: high (property), medium (version) | class: capability

### Q2: Audio-only SCStream

6. **Claim:** SCStream has no native audio-only mode. Developers report that omitting the screen output logs `stream output NOT found. Dropping frame`. The workarounds they use are to keep a screen output with a very large `minimumFrameInterval` (about 0.1 fps), or to capture video and discard it in the callback. The accepted answer (Nov 2024) recommends `AudioHardwareCreateProcessTap` on macOS 14.2+ for audio-only capture. No Apple engineer replied in the thread.
   - Source: https://developer.apple.com/forums/thread/718279 | Apple Developer Forums (community) | pub_date: Oct 2022 to Nov 2024 (older than 1 year, flagged) | confidence: medium | class: capability
7. **Claim:** The macOS 26 (Xcode 26 b1) ScreenCaptureKit API diff adds only screenshot APIs (`SCScreenshotConfiguration`, `SCScreenshotOutput`, `captureScreenshotWithFilter/Rect`) and an HDR10 stream preset. It has no audio-only mode, no audio changes, and no audio deprecations.
   - Source: https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode26.0-b1 | dotnet/macios, generated from Apple headers | pub_date: June 2025 | confidence: medium (secondary, beta 1 only) | class: versions-compat

### Q3: Formats and sample rates

8. **Claim:** SCStream can deliver 16 kHz mono natively. `sampleRate`: "The framework supports sample rates of 8000, 16000, 24000, and 48000 … [otherwise] default sample rate of 48 kHz." `channelCount`: "supports channel counts of 1 (mono) or 2 (stereo) … defaults to stereo."
   - Source: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate and .../channelcount | Apple | pub_date: living doc | confidence: high | class: capability
9. **Claim:** A tap's format is read at runtime from `kAudioTapPropertyFormat` (an `AudioStreamBasicDescription`). The tap offers mono or stereo mixdown (`isMixdown` / `isMono`). The docs name no sample-rate option for taps, so converting to 16 kHz is the app's job (with AVAudioConverter or similar). The lack of a rate option is an inference from its absence in the property list.
   - Source: https://github.com/insidegui/AudioCap (README) plus the CATapDescription property list above | insidegui (open source) and Apple | pub_date: undated | confidence: medium | class: capability
10. **Claim:** A `stereoMixdownOfProcesses` tap reports a fixed nominal 48 kHz from `kAudioTapPropertyFormat` even when the aggregate runs at 44.1 or 96 kHz. A device-bound tap (`init(processes:deviceUID:stream:)`) reports the true device rate. The real rate appears on the first I/O callback, so code that sizes a resampler from the property value is wrong until then.
   - Source: https://github.com/pasrom/meeting-transcriber/issues/683 | pasrom/meeting-transcriber (open-source issue) | pub_date: 2026-09-05 | confidence: medium (one practitioner's observation) | class: capability

### Q4: Microphone and clock alignment

11. **Claim:** `SCStreamConfiguration.captureMicrophone` (Bool) and `microphoneCaptureDeviceID` (String?) are available on macOS 15.0+ and Mac Catalyst 18.2+. Apple's pages for both have no abstract or discussion. The related `SCStreamOutputType.microphone` is named in the SDK. That the microphone arrives as a separate output type on the same SCStream is inferred from that symbol, not from documentation.
   - Source: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone | Apple | pub_date: macOS 15 SDK | confidence: high (availability), low (delivery semantics) | class: versions-compat
12. **Claim:** Practitioners wrap the tap in a private aggregate device. The default output device is the main (clock) sub-device, and drift compensation is enabled on the sub-tap. The tap is added through `kAudioAggregateDevicePropertyTapList`. Adding a microphone input to the same aggregate, with drift correction on the non-clock devices, is the standard Core Audio way to put all sources on one clock (see Rogue Amoeba's general aggregate guidance). No Apple doc retrieved this run confirms tap + mic in one aggregate.
   - Sources: https://github.com/pasrom/meeting-transcriber/issues/683 (2026-09-05); https://rogueamoeba.com/support/knowledgebase/?showArticle=Loopback-AggregateDeviceHandling (Rogue Amoeba, undated) | confidence: medium (tap-in-aggregate with drift compensation), low (tap + mic combined) | class: capability

### Q5: Passive capture and side effects

13. **Claim:** A tap is passive by default, and muting is opt-in through `muteBehavior` (`CATapMuteBehavior`). Apple: "Taps can also mute the process output so that the process will no longer play to the speaker or selected audio device, and all process output will go to the tap."
   - Source: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps | Apple | confidence: high | class: capability
14. **Claim:** Taps require `NSAudioCaptureUsageDescription` in Info.plist. "The first time you start recording from an aggregate device that contains a tap, the system prompts" for system audio recording permission. No public API checks the permission status: AudioCap uses private TCC APIs, with a build flag to turn them off.
   - Sources: the Apple sample code page above; https://github.com/insidegui/AudioCap | confidence: high (plist key and prompt), medium (no public status API) | class: capability

### Q6: macOS 26 changes

15. See findings 2, 3, and 7. Core Audio taps gained `bundleIDs` and `isProcessRestoreEnabled` in macOS 26.0. ScreenCaptureKit's macOS 26 additions are screenshot and HDR only. No deprecations to either API were found.

## Leads worth chasing

- The CoreAudio header `AudioHardwareTapping.h` / `CATapDescription.h` in the macOS 26 SDK. Apple's docs point to the headers for semantics that the web pages leave blank. It should settle whether a global tap picks up processes spawned after it starts.
- The `SCStreamOutputType.microphone` doc page and WWDC24 "What's new in ScreenCaptureKit" (if one exists) for mic timing and alignment with `.audio` sample buffers (PTS on a shared host clock?).
- g00dk0nd0u/work_audio_capture issues #60 and #62, a spike comparing SCK with a tap + microphone aggregate. Not read.
- Recall.ai blog "Exploring macOS screen capture APIs" (a practitioner comparison). Not read.
- The Apple Developer Forums "Core Audio" tag, for DTS replies on taps with a Bluetooth output (AirPods switching to HFP when a mic opens) and on aggregate clock-source choice when the output device changes mid-meeting.

## Looked for, not found

- An Apple statement on whether a global (`...GlobalTapButExcludeProcesses`) tap automatically includes processes that start after the tap is created. Unverified belief: yes, by construction.
- Apple documentation of clock and drift alignment between SCStream `.audio` and `.microphone` outputs.
- Any primary source on AirPods or Bluetooth switching to the hands-free (HFP) profile, and the resulting drop in output quality, when a tap aggregate or `captureMicrophone` opens the Bluetooth mic.
- A native tap sample-rate option (such as 16 kHz). None exists in the CATapDescription property list.
- Any macOS 26 audio change to SCStream, or any deprecation of either API.
- A WWDC session dedicated to Core Audio taps (2023 to 2025). None surfaced.
