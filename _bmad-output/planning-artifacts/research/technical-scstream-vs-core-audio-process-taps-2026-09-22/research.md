---
title: 'technical research: SCStream vs Core Audio process taps'
type: 'technical'
topic: 'SCStream vs Core Audio process taps'
decision: 'Which API captures system audio for Epic 5 Story 5.2 (sets 5.1 TCCCategory list and 5.8 gauntlet)'
source: 'native run'
status: complete
preset: 'standard'
validation: 'normal'
created: '2026-09-22'
updated: '2026-09-22'
claims_verified: 6
claims_unverified: 3
claims_disputed: 1
---

# technical research: SCStream vs Core Audio process taps

**Decision this research serves:** Which API captures system audio for Epic 5 Story 5.2 (sets 5.1 TCCCategory list and 5.8 gauntlet)

_Sections are appended per the approved research plan; the executive summary is written last and placed here, first._

## Executive summary

**Use a Core Audio global process tap (candidate B) for system audio.** Keep AVAudioEngine for the mic. Do not use SCStream.

**Why:**

- **Narrower permission.** Taps need only "System Audio Recording Only" [1][2][6]. SCStream needs the full "Screen & System Audio Recording" grant.
- **Fewer prompts.** SCStream apps on macOS 26 still get a recurring re-authorization prompt [30][32]. No source reports one for taps.
- **Honest privacy indicator.** The tap indicator is a purple audio dot [26], not a screen-capture indicator. That matches what auricle actually does.
- **Weighted score:** B 33, A 29, C 27 (matrix below).

**Two risks the stories must carry:**

1. **An open all-zero-buffer fault on the 26.5 beta [24].** Story 5.2 needs a watchdog that rebuilds the tap, the aggregate device and the IOProc.
2. **No public API to check or request the tap permission [3].** Onboarding has to trigger the prompt by starting a short capture. `PermissionChecker` needs an `.unknown` status for this category.

**Biggest caveat.** The only report of a tap missing Teams audio used a per-process tap [23][19]. No source shows a *global* tap working on Teams or on Meet in Chrome by name. Story 5.2 must verify that on the maintainer's Mac before the backend is locked in. If it fails, SCStream (A) wins.


## Requirements frame

The maintainer ruled that the target is the latest macOS (26 Tahoe), so older-OS behavior is out of scope.

**Hard gates**

1. Captures audio from any meeting app, including browser-based Meet and Teams.
2. Also captures the microphone.
3. Is passive. It adds no playback latency and makes no route change.
4. Works in a non-sandboxed, ad-hoc-signed app.

**Weighted preferences**

| Preference | Weight |
|---|---|
| Permission friction: prompt count, recurring prompts, grant survival across rebuilds | 3 |
| Privacy-indicator quality | 2 |
| CLI capture feasibility | 2 |
| API maturity and known bugs | 2 |
| Swift 6 concurrency fit | 1 |

**Candidates**

- **A.** SCStream audio, with AVAudioEngine for the mic.
- **B.** A Core Audio global process tap in a private aggregate device, with the mic through AVAudioEngine or the same aggregate.
- **C.** SCStream with `captureMicrophone` (macOS 15+).

Virtual audio drivers were cut because they need a driver install.

## Permissions and TCC

The two APIs ask for different permissions.

**Process taps** use their own TCC category, "System Audio Recording Only" (`kTCCServiceAudioCapture`). Their Info.plist key is `NSAudioCaptureUsageDescription` [1][2][3]. **SCStream audio** needs the full "Screen & System Audio Recording" grant, and the audio-only grant is not enough [6]. Candidate C adds Microphone on top of Screen Recording [9].

Taps have **no public API to preflight or request permission**. The prompt fires the first time the tap-backed aggregate device starts [3][4]. AudioCap reaches private TCC SPI to check status, behind a build flag [3].

If `NSAudioCaptureUsageDescription` is missing, TCC denies silently. Every call succeeds and every buffer is zero [4] (confidence: medium). The same report says Xcode ignores the `INFOPLIST_KEY_` build setting for this key, so the key belongs in Info.plist directly [4].

SCK apps get a recurring re-authorization prompt, "Allow For One Month", on Sequoia [7][27]. The macOS 26 evidence is one issue report [1] (confidence: low for Tahoe). No source confirms that taps are exempt from the recurring prompt. The `persistent-content-capture` entitlement is meant for VNC-style apps and is granted by request, so it is not a general exemption [7][8].

**Signing.** TCC keys every grant to the app's designated requirement. DTS recommends Apple Development signing to avoid "TCC thrash" [5]. An ad-hoc designated requirement is the cdhash, so each rebuild likely loses every grant, whichever API is used [5][2] (inference; confidence: medium).

**CLI.** TCC credits a request to the responsible app when the app spawns the helper [10]. A CLI launched from Terminal would make Terminal responsible (unverified belief; not checked for either API specifically).

**Deep links.** A community list gives `Privacy_ScreenCapture`, `Privacy_Microphone` and `Privacy_AudioCapture` anchors under `com.apple.settings.PrivacySecurity.extension` for Tahoe [11] (not tested; not Apple-documented).

## API capability

**Scope.** A tap can be global with an exclude list (`init(stereoGlobalTapButExcludeProcesses:)` and the mono variant), per-process, or device-bound [12]. macOS 26 adds `bundleIDs` and `isProcessRestoreEnabled`, which re-attach a tapped process when it restarts [13][14]. SCStream removes the app's own audio with `excludesCurrentProcessAudio` [16].

**Audio-only.** SCStream has no audio-only mode. Developers keep a screen output at a very low frame rate or discard the video frames [17]. The macOS 26 ScreenCaptureKit diff adds screenshots and HDR only. It has no audio changes and no deprecations [18].

**Format.** SCStream delivers **16 kHz mono natively** (`sampleRate` 16000, `channelCount` 1) [16]. A tap offers mono or stereo mixdown but no sample-rate option, so the app resamples [3][12]. A mixdown tap's reported format (48 kHz) can differ from the true device rate until the first I/O callback [19] (one practitioner).

**Microphone and clock.** `captureMicrophone` (macOS 15+) delivers the mic as `SCStreamOutputType.microphone` on the same stream [16]. Clock alignment between the two outputs is undocumented. For taps, practitioners use a private aggregate device with drift compensation [19][20]. Putting the mic in the same aggregate is standard Core Audio practice, but no source confirms that it works together with a tap (confidence: low).

**Passive.** A tap does not mute by default. Muting is opt-in through `muteBehavior` [15].

## Implementation reality and privacy UX

**Adoption.** No closed-source notetaker names its API. Granola asks for Mic plus "Screen & System Audio Recording" [28], which fits SCK, but the docs never name the API. Audio Hijack's 14.4+ backend needs only "System Audio Access" and shows the purple dot [26], which fits taps (inference). Among open-source projects:

- Meetily ships both backends [22].
- TypeWhisper proposes moving from SCK to taps for the narrower prompt [21].
- meeting-transcriber uses taps and reports bugs [19][23].

**Tap bugs on macOS 26 (open, one report each):**

- A tap records silence from Microsoft Teams on 26.4 [23]. The same report says the SCK-based apps Jamie and Muesli do capture Teams, but that is second-hand. The issue closed without a stated fix.
  - The project's code uses the per-process `stereoMixdownOfProcesses` tap [19]. So the failing tap most likely targeted chosen Teams processes (inference; confidence: medium-high).
  - No source reports a *global* tap missing Teams or browser audio. SyntaxCue ships a global exclude-self tap for calls [31], but it does not name Teams or Chrome.
- A tap plus aggregate returns all-zero buffers after about 7 minutes on the 26.5 beta [24].
  - Stretches of zeros lasted up to 16 minutes. The IOProc kept firing normally throughout.
  - Only destroying and recreating the tap, the aggregate device and the IOProc recovered.
  - The thread has no Apple reply and no Feedback ID. No release fix is recorded.

Recall.ai, a vendor, warns that taps need extra work for browser audio, which plays from helper processes, and for device changes [25].

**SCK bugs.** No 2025–2026 reports of SCK audio dropouts turned up in this round. That is a gap in the search, not evidence that SCK is clean.

**Documentation.** Tap documentation was widely called sparse [3][29]. Apple now publishes the sample "Capturing system audio with Core Audio taps" [15].

**Indicator.** Tap capture shows a purple menu-bar dot that apps cannot hide [26]. SCK capture shows the screen-capture indicator [2]. On 26.x, SCK apps still get the recurring "bypass the system private window picker" prompt, in one case 10 to 15 times a day [30][32]. No source reports an OS-level recurring prompt for tap apps [30]. An all-zero tap buffer is ambiguous: it can mean permission is missing or that nothing is playing [33]. No source says other meeting participants get any signal.

**Swift 6.** Neither API has sourced evidence on strict-concurrency friction.

## Cross-dimension insights

- **Signing, not the capture API, drives day-to-day permission friction.** TCC keys every grant to the designated requirement [5]. An ad-hoc build likely looks like a new app on every rebuild, so every grant would re-prompt whichever API is used (inference; confidence: medium). That affects the Debug build loop more than either candidate does.
- **The tap's missing preflight and its zero-buffer fault look the same.** A denied grant returns zeros silently [4]. So does the 26.5 fault [24]. So does a quiet meeting [33]. Any "am I capturing?" signal must combine a peak meter with elapsed time, not treat zeros as an error.
- **SCStream's native 16 kHz mono output does not decide the choice.** Taps need an `AVAudioConverter` resample step [3][12], and the design already has one: `AudioMixer` resamples the mic anyway.

## Decision matrix

Scores run 1 to 5, and the weighted total is the sum of score × weight. Every candidate passes all four hard gates. B passes the "any app" gate on inference only (see caveat).

| Criterion (weight) | A SCStream + AVAudioEngine | B Global tap + AVAudioEngine | C SCStream + `captureMicrophone` |
|---|---|---|---|
| Permission friction (3) | 2: Screen Recording plus a recurring prompt [6][30] | 4: narrow grant, no recurring prompt found, no public preflight [1][3] | 2: as A, plus Microphone [9] |
| Privacy indicator (2) | 3: screen-capture indicator; "screen" misstates the scope [2] | 4: purple audio dot [26] | 3: as A |
| CLI feasibility (2) | 3: same responsible-process rule [10] | 3: same [10] | 3: same |
| Maturity and bugs (2) | 4: native 16 kHz mono, no 26.x audio bugs found [16][18] | 2: zero-buffer fault [24], sparse docs [29], rate quirk [19] | 3: mic delivery undocumented [16] |
| Swift 6 fit (1) | 3: no evidence | 3: no evidence; real-time IOProc | 3: no evidence |
| **Weighted total** | **29** | **33** | **27** |

**Pick: B.** Use `CATapDescription(monoGlobalTapButExcludeProcesses: [own process])` in a private aggregate device.

**Runner-up: A.** A wins if either of these happens:

- the live check in Story 5.2 finds a global tap misses Teams, Meet in Chrome, or Zoom audio
- the zero-buffer fault reproduces on a released 26.x build and the watchdog cannot hide it

**Strongest argument against B.** SCStream is the path with no reported audio-loss bugs on 26.x. B trades a known prompt annoyance for an unresolved data-loss risk.

**Reversibility hedge.** Put a `SystemAudioSource` protocol seam inside `Capture`. The SCStream backend then drops in without touching `AudioMixer`, `WAVWriter` or `CaptureStage`.

## Recommendations

These feed `epics.md` Epic 5, `architecture.md` AR-FAIL-6 and Decision 1.4, and the UX J0 gauntlet.

1. **Story 5.1:** replace `TCCCategory.screenCapture` with `.systemAudioCapture`, and add `PermissionStatus.unknown`.
   - Reason: taps use a separate category with no public check [1][3].
   - Deep link: the `Privacy_AudioCapture` anchor [11]. It is community-sourced, so the story must test it on the maintainer's Mac.
   - Confidence: medium-high.
2. **Info.plist:** add `NSAudioCaptureUsageDescription` to the app's Info.plist file itself, not through a build setting [4]. Make `scripts/check.sh app` assert the key in the built bundle, because a missing key fails silently with all-zero buffers [4].
   - Confidence: medium, one source.
3. **Story 5.2:** add these acceptance criteria:
   - a global exclude-self tap
   - an all-zero-buffer watchdog that performs a full rebuild [24]
   - resampling to 16 kHz in `AudioMixer`
   - a manual live check on Teams, Meet in Chrome, Zoom and FaceTime before the story closes
   - Confidence: medium.
4. **Story 5.8:** the second gauntlet step becomes "System Audio Recording". It triggers the prompt by starting a 1-second capture, because no request API exists [3][4].
5. **Maintainer decision:** whether the Debug build's ad-hoc signing stays, given the TCC re-grant churn on each rebuild [5]. This is inference and should be confirmed on the first Story 5.2 build.

## Open questions

- **Does a global tap capture Teams, Meet in Chrome and Zoom on the maintainer's 26.x Mac?** Answer: the live check in Story 5.2.
- **Does the zero-buffer fault [24] happen on released 26.x?** Answer: a 60-minute capture soak during Story 5.2.
- **Does an ad-hoc rebuild reset the tap grant?** Answer: rebuild once and watch for the prompt.
- **When the CLI is launched from Terminal, which process owns the TCC grant?** Answer: a manual check, if the CLI ever hosts capture.
- **How do mic and system-audio clocks drift over 60 minutes with separate devices?** Answer: measure it in the Story 5.2 soak. Whisper tolerates tens of milliseconds.

## Source appendix

| # | Supports | Publisher | Pub date | Accessed | Confidence |
|---|---|---|---|---|---|
| 1 | Taps use a separate TCC category | [GitHub macparakeet #924](https://github.com/moona3k/macparakeet/issues/924) | 2026-08-22 | 2026-09-22 | medium |
| 2 | `NSAudioCaptureUsageDescription`; SCK indicator; stable signing | [DGR Labs](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html) | 2026-04-25 | 2026-09-22 | medium |
| 3 | No public preflight; setup chain | [insidegui AudioCap](https://github.com/insidegui/AudioCap) | undated | 2026-09-22 | high |
| 4 | Permission check at device start; silent zeros; plist gotcha | [DEV Community](https://dev.to/nickdelv/2000-buffers-of-nothing-3i8) | 2026-06-10 | 2026-09-22 | medium |
| 5 | TCC keyed to designated requirement; ad-hoc thrash | [Apple Developer Forums 730043](https://developer.apple.com/forums/thread/730043) | 2023-05 | 2026-09-22 | medium |
| 6 | SCK audio needs full Screen Recording grant | [OBS #10401](https://github.com/obsproject/obs-studio/issues/10401) | 2024-03-18 | 2026-09-22 | medium |
| 7 | Sequoia re-prompt cadence; persistent-content-capture | [Michael Tsai](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/) | 2024-08 | 2026-09-22 | medium |
| 8 | No Apple answer on the entitlement | [Apple Developer Forums 761641](https://developer.apple.com/forums/thread/761641) | 2024-08 | 2026-09-22 | high |
| 9 | `captureMicrophone` adds Microphone permission | [WWDC24 10088](https://developer.apple.com/videos/play/wwdc2024/10088/) | 2024-06 | 2026-09-22 | medium |
| 10 | Responsible-process rule | [Apple Developer Forums 694948](https://developer.apple.com/forums/thread/694948) | 2021 | 2026-09-22 | medium |
| 11 | Tahoe deep-link anchors | [rmcdongit gist](https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751) | 2026-09-05 | 2026-09-22 | medium |
| 12 | Tap scopes and initializers | [Apple CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription) | living doc | 2026-09-22 | medium |
| 13 | `bundleIDs` new in 26.0 | [Apple](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids) | macOS 26 SDK | 2026-09-22 | high |
| 14 | `isProcessRestoreEnabled` new in 26.0 | [Apple](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled) | macOS 26 SDK | 2026-09-22 | high |
| 15 | Tap sample; passive by default | [Apple sample code](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) | macOS 26 page | 2026-09-22 | high |
| 16 | SCStream 16 kHz mono; `excludesCurrentProcessAudio`; `captureMicrophone` | [Apple SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration) | living doc | 2026-09-22 | high |
| 17 | No SCStream audio-only mode | [Apple Developer Forums 718279](https://developer.apple.com/forums/thread/718279) | 2022-2024 | 2026-09-22 | medium |
| 18 | No SCK audio change in macOS 26 | [dotnet/macios diff](https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode26.0-b1) | 2025-06 | 2026-09-22 | medium |
| 19 | Mixdown rate quirk; per-process tap in use | [meeting-transcriber #683](https://github.com/pasrom/meeting-transcriber/issues/683) | 2026-09-05 | 2026-09-22 | medium |
| 20 | Aggregate drift compensation | [Rogue Amoeba Loopback KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=Loopback-AggregateDeviceHandling) | undated | 2026-09-22 | medium |
| 21 | Proposal to move SCK to taps | [TypeWhisper #495](https://github.com/TypeWhisper/typewhisper-mac/issues/495) | 2026-05-08 | 2026-09-22 | medium |
| 22 | Meetily ships both backends | [Meetily #509](https://github.com/Zackriya-Solutions/meetily/issues/509) | undated | 2026-09-22 | low |
| 23 | Tap silent on Teams, 26.4 | [meeting-transcriber #79](https://github.com/pasrom/meeting-transcriber/issues/79) | 2026-04-01 | 2026-09-22 | medium |
| 24 | Zero-buffer fault, 26.5 beta | [Apple Developer Forums 825780](https://developer.apple.com/forums/thread/825780) | 2026-05 | 2026-09-22 | medium |
| 25 | Browser helper-process caution | [Recall.ai](https://www.recall.ai/blog/core-audio-taps) | 2026-07-08 | 2026-09-22 | medium |
| 26 | Purple dot; system-audio permission | [Rogue Amoeba ARK KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack) | undated | 2026-09-22 | high |
| 27 | Sequoia monthly prompt | [9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/) | 2024-08-14 | 2026-09-22 | medium |
| 28 | Granola permissions | [Granola docs](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time) | undated | 2026-09-22 | high |
| 29 | Tap docs sparse | [Strongly Typed](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos) | 2025-06-17 | 2026-09-22 | high |
| 30 | SCK recurring prompt on 26.3 | [Codex #19134](https://github.com/openai/codex/issues/19134) | 2026-03 | 2026-09-22 | medium |
| 31 | Global exclude-self tap shipped for calls | [DEV Community (SyntaxCue)](https://dev.to/baurzhan_zhetenov_442c4cd/how-i-capture-system-audio-and-transcribe-it-locally-with-no-server-in-the-loop-tauri-rust--4a0n) | 2026 | 2026-09-22 | medium |
| 32 | SCK prompt 10-15×/day on 26.3.2 | [BeyondTrust community](https://beekeepers.beyondtrust.com/general-45/beyondtrust-remote-support-customer-client-repeated-screen-capture-permission-pop-ups-on-macos-tahoe-7998) | 2026 | 2026-09-22 | medium |
| 33 | All-zero tap ambiguity | [Sokuji PR #498](https://github.com/kizuna-ai-lab/sokuji/pull/498) | 2026 | 2026-09-22 | medium |

## Staleness map

- **Re-check before Story 5.2 closes:**
  - the macOS version and bug claims [23][24][30][32]
  - the deep-link anchors [11]
- **Earliest re-check:** 2026-10-22. The one-month window on version and compatibility claims starts from the Aug–Sep 2026 sources.
- **Refresh rule:** this is a selection report, so refresh it before acting on it after 2027-03-22.
