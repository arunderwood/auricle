# Permissions digest (r1-1): SCStream audio-only vs Core Audio process taps vs SCStream+captureMicrophone

Accessed for all: 2026-09-22.

## Findings

1. **claim:** Core Audio process taps use their own TCC category ("System Audio Recording Only" / `kTCCServiceAudioCapture`), separate from Screen Recording (`kTCCServiceScreenCapture`). One user's machine on macOS 26.6.2 showed the audio-only grant allowed while screen capture was denied.
   - source: https://github.com/moona3k/macparakeet/issues/924 | publisher: GitHub (MacParakeet issue, user report) | pub_date: 2026-08-22 | confidence: medium (one user's TCC observation, matches the next two sources) | class: behavior

2. **claim:** `NSAudioCaptureUsageDescription` is its own TCC category, separate from microphone access. Process taps need macOS 14.4 or later ("Earlier versions land in different TCC categories"). Reset with `tccutil reset SystemAudioCaptureRequests <bundle-id>`.
   - source: https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html | publisher: DGR Labs blog | pub_date: 2026-04-25 | confidence: medium | class: versions-compat

3. **claim:** The process-tap prompt text comes from the `NSAudioCaptureUsageDescription` Info.plist key. Apple has no public API to request audio-capture permission or check whether it's granted. AudioCap calls private TCC SPI for this, behind a build flag. Without that SPI, the prompt appears the first time recording starts.
   - source: https://github.com/insidegui/AudioCap | publisher: Guilherme Rambo (insidegui), GitHub | pub_date: README undated; repo active | confidence: high for "no public preflight API" (a well-known practitioner states it directly). Freshness not verified against the macOS 26 SDK. | class: behavior

4. **claim:** Permission is enforced at `AudioDeviceStart` on the tap-backed aggregate device, not when the tap is created. Creating the tap and reading its format both succeed without a grant. If `NSAudioCaptureUsageDescription` is missing, TCC denies silently: every call returns success and every buffer is zeros, with no error and no log. Xcode silently ignores the `INFOPLIST_KEY_NSAudioCaptureUsageDescription` build setting, so put the key in Info.plist directly and check the built bundle with `plutil -p`. To prompt during onboarding, build and start the whole pipeline, then tear it down once the dialog has appeared.
   - source: https://dev.to/nickdelv/2000-buffers-of-nothing-3i8 | publisher: DEV Community (individual developer) | pub_date: 2026-06-10 | confidence: medium (one practitioner, specific and consistent with #3) | class: behavior

5. **claim:** Process taps need a stable signing identity because TCC's permission record is keyed to it. With unsigned `xcodebuild` builds, the prompt doesn't fire.
   - source: https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html | publisher: DGR Labs blog | pub_date: 2026-04-25 | confidence: medium | class: behavior

6. **claim:** TCC checks grants against the app's designated requirement (stored as `csreq`). Ad-hoc signing (`codesign -s -`) causes "TCC thrash". DTS recommends Apple Development signing for day-to-day builds so the identity stays stable. Implication, inferred and not stated for audio specifically: an ad-hoc DR is the cdhash, so each rebuild looks like a new app and the grant is lost for every TCC service, taps and SCStream alike.
   - source: https://developer.apple.com/forums/thread/730043 | publisher: Apple Developer Forums (Quinn "The Eskimo!", DTS) | pub_date: 2023-05 (older than 1 year; this TCC mechanism is long-standing) | confidence: high for DR keying; medium for "every rebuild resets" | class: behavior

7. **claim:** ScreenCaptureKit audio capture falls under the Screen & System Audio Recording (Screen Recording) permission. Granting only "System Audio Recording Only" (added in macOS 14.4) was not enough for OBS's SCK-based macOS Audio Capture source. Nobody from Apple or the maintainers explained why.
   - source: https://github.com/obsproject/obs-studio/issues/10401 | publisher: GitHub (OBS issue) | pub_date: 2024 (macOS 14.4 era; older than 1 year) | confidence: medium. #1 (2026, macOS 26) is consistent: its SCK path stays blocked while the audio-only grant is in place. | class: behavior

8. **claim:** Using ScreenCaptureKit for audio-only capture still needs the Screen Recording permission and shows the menu-bar capture indicator.
   - source: https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html | publisher: DGR Labs blog | pub_date: 2026-04-25 | confidence: medium | class: behavior

9. **claim:** On macOS 26, screen-capture apps get periodic re-approval prompts and the menu-bar indicator. Apps that do audio-only capture through SCK get these too. Process taps are proposed as the way to avoid them.
   - source: https://github.com/moona3k/macparakeet/issues/924 | publisher: GitHub (user report) | pub_date: 2026-08-22 | confidence: medium for SCK. Low/inferred that taps are exempt: no source directly confirms taps skip re-authorization. | class: behavior

10. **claim:** Sequoia's re-authorization prompt for screen recording went from weekly (betas) to monthly ("Allow For One Month") and no longer appears at every reboot. macOS 15.1 cut the frequency further for regularly used apps. There is no option to turn it off permanently. The prompt wording covers "screen and audio".
    - source: https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/ (aggregates 9to5Mac 2024-08-14 and iDownloadBlog 2024-10-09) | publisher: Michael Tsai blog | pub_date: 2024-08-08, updated through 2024-10 (older than 1 year) | confidence: medium. Behavior on 26 not verified beyond #9. | class: versions-compat

11. **claim:** The `com.apple.developer.persistent-content-capture` entitlement is documented as meant for VNC (remote screen) apps and is obtained by request form. It isn't a general exemption for recorder apps. `SCContentSharingPicker` is described as avoiding repeated permission dialogs because the user picks the content on each capture.
    - source: https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/ ; https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture | publisher: Michael Tsai; Apple docs (not fetched directly) | pub_date: 2024-08-21 update | confidence: medium | class: versions-compat

12. **claim:** Nobody from Apple answered the forum question about whether persistent-content-capture suppresses the prompts or who qualifies for it. A developer reported the interval became 30 days without the entitlement.
    - source: https://developer.apple.com/forums/thread/761641 | publisher: Apple Developer Forums | pub_date: 2024-08/09 | confidence: high (that no answer exists in that thread) | class: behavior

13. **claim:** SCStream `captureMicrophone` (with `microphoneCaptureDeviceID`, macOS 15+) delivers mic buffers as a separate output type on the same stream. It needs `NSMicrophoneUsageDescription`, so the Microphone TCC permission applies on top of Screen Recording.
    - source: https://developer.apple.com/videos/play/wwdc2024/10088/ ; https://www.recall.ai/blog/how-to-use-screencapturekit-to-record-a-meeting (via search summaries, not fetched directly) | publisher: Apple WWDC24; Recall.ai | pub_date: 2024-06; Recall.ai undated | confidence: medium | class: versions-compat

14. **claim:** TCC attributes a request to the "responsible code". When a helper tool embedded in an app triggers a prompt, the app's name and usage description appear in the alert and the decision is recorded for the whole app. For that to work, the system has to be able to identify the app as responsible for the helper. Shell scripts and TCC don't mix well, and launchd agents should be native code.
    - source: https://developer.apple.com/forums/thread/694948 and https://developer.apple.com/forums/thread/678819 (Quinn, DTS; via search summary) | publisher: Apple Developer Forums | pub_date: 2021-2022 (older than 1 year) | confidence: medium-high for the general rule. Not verified separately for SCStream and process taps. | class: pattern

15. **claim:** Deep links on Sequoia and Tahoe (26.2), from a community-maintained list: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone`, `...?Privacy_ScreenCapture`, and `...?Privacy_AudioCapture` (in the Tahoe list). No comments report these three as broken.
    - source: https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751 | publisher: GitHub gist (community) | pub_date: list dated 2026-01-18, gist updated 2026-09-05 | confidence: medium (community list, not Apple-documented, not tested this run) | class: versions-compat

## Leads worth chasing
- Apple doc page for `NSAudioCaptureUsageDescription` (https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription): search turned it up but it wasn't fetched. Check for a stated macOS version and any mention of a request API.
- Whether process taps (`kTCCServiceAudioCapture`) trigger the monthly/periodic re-authorization prompt on macOS 15/26. The only evidence is inferred from #9. Test by granting, advancing past 30 days, or checking `TCC.db` for an expiry column.
- Responsible process for a CLI embedded in an .app that's launched from Terminal. The belief is that Terminal becomes responsible unless the tool is spawned by the app, or `responsibility_spawnattrs_setdisclaim` (SPI) is used. This is unverified. Look at Quinn's "responsible code" posts and at how AudioCap/CLI tools handle it.
- Whether `Privacy_AudioCapture` actually opens the "System Audio Recording Only" subsection or just the Screen & System Audio Recording pane.
- Apple docs for `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` and SCShareableContent's first-call prompt behavior on macOS 26. These weren't retrieved this run.
- https://github.com/SamWongML/macos-audio-recording/issues/1 (mentions a macOS 27 app-audio recorder). It may carry newer permission notes.

## Looked for, not found
- Any Apple DTS or official statement on whether process taps are subject to the periodic re-auth prompt.
- A public API to preflight or request the process-tap (audio capture) permission. Only the absence is evidenced (#3).
- Apple-official confirmation that `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` cover SCStream audio-only on macOS 26 (not retrieved).
- Apple guidance that separates responsible-process rules for SCStream from those for process taps.
- A macOS 26-specific news source (9to5mac/macrumors) on changes to the re-auth cadence. Coverage found was 2024 (Sequoia) only.
