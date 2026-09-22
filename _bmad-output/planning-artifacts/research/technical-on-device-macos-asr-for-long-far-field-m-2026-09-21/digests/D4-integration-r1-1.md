# D4 integration digest

Scope: integration reality and ecosystem health of Swift-package ASR runtimes on Apple-silicon macOS, as of 2026-09-21. Budget spent: 18 tool calls, 10 sources read. Two fetches (Apple SpeechAnalyzer doc page, HF parakeetkit-pro card) returned partial content; noted below.

Date caveat: the fetch summarizer printed release years as "2024" for the WhisperKit and whisper.cpp release pages while every issue timestamp and search snippet on the same repos reads 2026 (e.g. WhisperKit issue #530 dated Sep 10, 2026; search snippet "WhisperKit reached v1.0.0 in May 2026"). Month/day values are treated as reliable and the year as 2026; confidence on release dates is capped at medium for that reason.

## Claims

- WhisperKit v1.1.0 is the newest tagged release (Aug 6, 2026); the pinned version is current. | https://github.com/argmaxinc/WhisperKit/releases | Argmax (GitHub) | 2026-08-06 | accessed 2026-09-21 | confidence medium (year inferred, see caveat) | version/compat
- The WhisperKit repo now presents itself as "argmax-oss-swift", an umbrella SDK (WhisperKit + SpeakerKit + TTSKit + ArgmaxCore, umbrella product `ArgmaxOSS`), renamed at v1.0.0 (May 1, 2026). | https://github.com/argmaxinc/WhisperKit/releases | Argmax (GitHub) | 2026-05-01 | accessed 2026-09-21 | confidence high | version/compat
- WhisperKit releases in the last 12 months: v0.16.0 (Mar 3), v0.17.0 (Mar 13), v0.18.0 (Apr 1), v1.0.0 (May 1, breaking: deprecated APIs removed, Swift 6 concurrency/Sendable, Hub+Tokenizers vendored into ArgmaxCore), v1.1.0 (Aug 6). Five tags; none before March 2026 shown on the first page. | https://github.com/argmaxinc/WhisperKit/releases | Argmax (GitHub) | 2026-08-06 | accessed 2026-09-21 | confidence medium | version/compat
- v1.1.0 added an `.incremental` audio-file loading mode that cuts chunks at silence boundaries, advertised as "70%+ savings for 3-hour audio input", and fixed Chinese word timestamps, `promptTokens`, `transcribeWithOptions`, and model load/cache paths. | https://github.com/argmaxinc/WhisperKit/releases | Argmax (GitHub) | 2026-08-06 | accessed 2026-09-21 | confidence medium | integration
- WhisperKit open-source SDK does not ship Parakeet; Parakeet on Apple platforms is delivered as "ParakeetKit Pro" model assets that "are only compatible with Argmax Pro SDK", under the "argmax-fmod-license". | https://huggingface.co/argmaxinc/parakeetkit-pro | Argmax (Hugging Face) | undated (card) | accessed 2026-09-21 | confidence high | license
- Argmax Pro SDK is a paid subscription at "$0.42 per month per device", with Parakeet v2 and pyannote 3.1 named as Pro-only models; Android GA was slated for Q1 2026. | https://www.argmaxinc.com/blog/pro-sdk-ga | Argmax | 2025-07-24 | accessed 2026-09-21 | confidence high (pricing may have changed since; page is 14 months old, stale for pricing) | license
- WhisperKit (argmax-oss-swift) has 97 open issues; the ten most recent were opened Jun 10 - Sep 10, 2026, i.e. the tracker is active. | https://github.com/argmaxinc/WhisperKit/issues | Argmax (GitHub) | 2026-09-10 | accessed 2026-09-21 | confidence high | ecosystem
- Open WhisperKit issue #500 (Jul 7, 2026): "AudioProcessor resample silently corrupts long compressed audio (87-min mp3 -> garbage transcript, exit 0)". Still open at access time; not fixed by v1.1.0. | https://github.com/argmaxinc/WhisperKit/issues | Argmax (GitHub) | 2026-07-07 | accessed 2026-09-21 | confidence high | integration
- Open WhisperKit issues also include #517 (Aug 2, 2026) native memory growing ~50 MB per AudioStreamTranscriber recreation on the ANE path, #491 (Jun 12, 2026) partial model download never repaired, #525/#530 decoder early-exit/early-stop state bugs (Aug-Sep 2026). | https://github.com/argmaxinc/WhisperKit/issues | Argmax (GitHub) | 2026-09-10 | accessed 2026-09-21 | confidence high | integration
- FluidAudio newest release is v0.16.1 (Sep 21, 2026, "Mac Catalyst fix"); the first releases page shows 10 tags between Jun 4 and Sep 21; search index reports 63 releases total. | https://github.com/FluidInference/FluidAudio/releases | FluidInference (GitHub) | 2026-09-21 | accessed 2026-09-21 | confidence medium (count beyond first page not verified) | version/compat
- FluidAudio recent changes: a "Parakeet unified" backend with native-Swift mel front-end and word-level timestamps; a breaking `DownloadUtils -> ModelHub` API change; a rebuilt resumable download stack; "15+ new contributors across releases". | https://github.com/FluidInference/FluidAudio/releases | FluidInference (GitHub) | 2026-09-21 | accessed 2026-09-21 | confidence medium | ecosystem
- FluidAudio code license is Apache 2.0; README describes model weights only as "permissive licenses"; 2.8k stars, 429 forks; Swift 6.0+ badge; ASR models: Parakeet TDT v3 (25 languages), Parakeet TDT v2 (English), Parakeet EOU (streaming), SenseVoice, Paraformer. | https://github.com/FluidInference/FluidAudio | FluidInference (GitHub) | 2026-09 (README at access) | accessed 2026-09-21 | confidence high | license
- FluidAudio ASR results expose segments with `startTimeSeconds` / `endTimeSeconds`; the README claims "1 hour of audio in ~19 seconds" on M4 Pro but does not state the internal chunking strategy for file input. | https://github.com/FluidInference/FluidAudio | FluidInference (GitHub) | 2026-09 | accessed 2026-09-21 | confidence medium | integration
- FluidAudio has 11 open issues; recent ones (Sep 9-21, 2026) are mostly TTS, plus #912 "SlidingWindowAsrManager: spurious text at chunk boundary", #899 streaming rescue floors replacing the opening word, and #927 "Provenance and licensing details for diarization Core ML artefacts" (open). | https://github.com/FluidInference/FluidAudio/issues | FluidInference (GitHub) | 2026-09-21 | accessed 2026-09-21 | confidence high | ecosystem
- FluidInference's swift-parakeet-mlx (MIT, depends on mlx-swift, sentence and token timestamps) was archived Jul 18, 2025 in favour of FluidAudio, which the maintainers call "a more efficient and less power-hungry approach". | https://github.com/FluidInference/swift-parakeet-mlx | FluidInference (GitHub) | 2025-07-18 | accessed 2026-09-21 | confidence high | ecosystem
- whisper.cpp newest stable is v1.9.4 (Sep 11); 6 stable + 4 nightly tags in the last 12 months; release notes mention xcframework building and "parakeet encoder support" plus VAD-mapped token timestamps. | https://github.com/ggml-org/whisper.cpp/releases | ggml-org (GitHub) | 2026-09-11 | accessed 2026-09-21 | confidence medium (year inferred) | version/compat
- Apple SpeechAnalyzer/SpeechTranscriber ships in macOS 26 (and iOS/iPadOS/visionOS/tvOS 26, not watchOS); a whole `AVAudioFile` is passed via `analyzeSequence(from:)` and finished with `finalizeAndFinish(through:)`; the caller does not chunk. Timestamps come as the `audioTimeRange` attribute on `AttributedString` runs and are off by default in the `.transcription` preset. Models are downloaded through `AssetInventory`/`AssetInstallationRequest`; availability must be gated with `SpeechTranscriber.isAvailable`. | https://www.theswift.dev/posts/transcribe-audio-with-speechanalyzer-in-swift/ | The Swift Dev (secondary) | 2025-09-17 | accessed 2026-09-21 | confidence medium (secondary source; Apple doc fetch returned no body) | integration

## Runtime table

runtime | current release+date | releases last 12 mo | open issues / responsiveness | backing | code license | weights license | timestamps | long-file handling | pain points (fixed?) | source
--- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---
Argmax WhisperKit / argmax-oss-swift | v1.1.0, 2026-08-06 | 5 tags (v0.16 -> v1.1), 1 breaking (v1.0) | 97 open; recent issues Jun-Sep 2026; maintainer reply rate not visible in list view (unverified) | Argmax Inc.; OSS SDK + paid Pro SDK ($0.42/device/month as of Jul 2025); Pro holds Parakeet and pyannote 3.1 | not re-verified this run (believed MIT; unverified) | Whisper weights: not re-verified (believed MIT via OpenAI; unverified); ParakeetKit Pro: argmax-fmod-license, Pro-only | word timestamps (Chinese fix in 1.1.0); segment timestamps believed present, not re-verified | takes a file; internal chunking; v1.1.0 adds `.incremental` silence-boundary loading | #500 long compressed audio silently corrupted (open); #517 ANE memory growth (open); #491 partial download not repaired (open); v1.0 API removals (breaking, intended) | releases + issues pages
FluidAudio (FluidInference) | v0.16.1, 2026-09-21 | >=10 on first page; 63 total per index | 11 open; issues opened and dated within days; responsiveness not measured | FluidInference (company; business model not stated in README; Discord community) | Apache 2.0 | README: "permissive"; Parakeet CC-BY-4.0 is NVIDIA's published license (belief, not fetched this run); #927 open on diarization artefact provenance | segment start/end seconds; word-level timestamps per release notes | accepts file/samples/buffer; chunking strategy not documented in README; sliding-window streaming has chunk-boundary bugs (#912, #899, open) | breaking ModelHub rename; TTS-heavy churn; frequent 0.x releases (API stability risk) | README + releases + issues
mlx-swift route (swift-parakeet-mlx; mlx-audio-swift) | swift-parakeet-mlx archived 2025-07-18; mlx-audio-swift: no release data retrieved | n/a | n/a | FluidInference (archived); Blaizzy (mlx-audio-swift, individual maintainer per repo owner) | MIT (swift-parakeet-mlx) | same NVIDIA weights (unverified this run) | sentence + token timestamps (swift-parakeet-mlx) | no built-in chunking noted | archived; maintainer says Core ML path is more power-efficient | swift-parakeet-mlx README
whisper.cpp via SwiftPM (whisper.spm / SwiftWhisper) | whisper.cpp v1.9.4, 2026-09-11 | 6 stable + 4 nightly | not retrieved | ggml-org (Georgi Gerganov; ggml.ai) | not re-verified (believed MIT; unverified) | Whisper weights as above | token timestamps; VAD maps tokens to original time | CLI/library processes whole file in 30 s windows internally (belief; not verified this run) | Swift package is a separate repo (ggerganov/whisper.spm); xcframework mentioned in release notes; no retrospective threads read | releases page + search
Apple SpeechAnalyzer + SpeechTranscriber | macOS 26 framework (ships with OS) | OS-cadence | Apple Feedback Assistant only; no public tracker | Apple; platform framework, free | Apple SDK terms (not fetched) | Apple on-device assets via AssetInventory; terms not fetched | `audioTimeRange` attribute, opt-in | whole `AVAudioFile` via `analyzeSequence(from:)`, no caller chunking | must gate on `isAvailable` and asset download state; locale must resolve via `supportedLocale(equivalentTo:)`; macOS 26 floor | theswift.dev (secondary)

## Leads

- Verify maintainer responsiveness numerically: fetch `https://github.com/argmaxinc/WhisperKit/pulse/monthly` and the FluidAudio equivalent (not done; call budget exhausted).
- WhisperKit #500 is the single most decision-relevant thread: read it in full to see whether it affects WAV/CAF input or only compressed formats, and whether a fix landed after Aug 6.
- whisper.cpp release notes mention "parakeet encoder support": if whisper.cpp can run Parakeet with an MIT runtime, it is a third route to Parakeet outside Argmax Pro and FluidAudio.
- FluidAudio #927 (licensing provenance of Core ML artefacts) is the thread to watch for the converted-weights license question.
- Argmax pricing page is 14 months old; re-check `argmaxinc.com` pricing before quoting $0.42/device/month.

## Looked for and could not find

- Closed-issue counts and median time-to-first-response for either WhisperKit or FluidAudio (list pages do not show them).
- The exact text of `argmax-fmod-license` (HF card fetch returned only the gating notice).
- Apple's own SpeechAnalyzer documentation body (fetch returned title only); the framework claims above rest on one secondary post.
- Any 2026 Swift-native ASR runtime other than the five named (search returned none; absence of evidence, not evidence of absence).
- Explicit statement of FluidAudio's batch chunk length/overlap for file transcription.
- Contributor counts over time for any repo (only FluidAudio's "15+ new contributors" note and a 2.8k-star snapshot).

## Sources read

1. https://github.com/argmaxinc/WhisperKit/releases
2. https://github.com/argmaxinc/WhisperKit/issues
3. https://github.com/FluidInference/FluidAudio/releases
4. https://github.com/FluidInference/FluidAudio/issues
5. https://github.com/FluidInference/FluidAudio
6. https://github.com/FluidInference/swift-parakeet-mlx
7. https://huggingface.co/argmaxinc/parakeetkit-pro
8. https://www.argmaxinc.com/blog/pro-sdk-ga
9. https://github.com/ggml-org/whisper.cpp/releases
10. https://www.theswift.dev/posts/transcribe-audio-with-speechanalyzer-in-swift/
(Failed/empty: https://developer.apple.com/documentation/speech/speechanalyzer)
