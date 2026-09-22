# SpeechAnalyzer round 2 digest

Scope: Apple SpeechAnalyzer / SpeechTranscriber (Speech framework, macOS 26) as on-device ASR for 20-40 min far-field four-speaker English meetings. All evidence retrieved 2026-09-21. Budget: 16 tool calls, 9 sources read (two Apple HTML doc pages returned title-only and are listed under "could not find").

## Claims

Format: `claim | source URL | publisher | pub_date | accessed 2026-09-21 | confidence | class`

- Apple's exact long-form/distant wording: "It's good for long-form and distant audio, such as lectures, meetings, and conversations." and "We wanted to create a model that could support long-form and conversational use cases where some speakers might not be close to the mic, such as recording a meeting." and "accurate even at longer distances" | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple (WWDC25 session 277 transcript) | 2025-06 | accessed 2026-09-21 | high (verbatim from transcript) | vendor claim, no numbers attached
- Processing is entirely on-device; only model assets are fetched: "Remember that transcription is entirely on device but the models need to be fetched." and "Our new, on-device model achieves all of that." | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple | 2025-06 | accessed 2026-09-21 | high | vendor primary
- Independent restatement of on-device: "run entirely on the device", "no network call anywhere in the transcription path" | https://blog.addpipe.com/apple-speechanalyzer-api/ | addpipe (vendor of a web recording product, not a competitor) | 2026-08-17 | accessed 2026-09-21 | medium (secondary, consistent with Apple) | third-party
- File input: `analyzer.analyzeSequence(from: file)` returns the last sample; then `analyzer.finalizeAndFinish(through: lastSample)` | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple | 2025-06 | accessed 2026-09-21 | high (code shown in session) | vendor primary
- Timestamps: "Each run has an audioTimeRange attribute represented as CMTimeRange." Enabled via `attributeOptions: [.audioTimeRange]`. Granularity is per AttributedString run; Apple does not say "per word" or "per phrase" in the transcript | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple | 2025-06 | accessed 2026-09-21 | high on the quote, low on granularity (run size unstated) | vendor primary
- yap issue #18 (2025-12-16) is a feature request for word-level timestamps in JSON, which suggests the tool's author did not treat SpeechAnalyzer runs as reliably word-level | https://github.com/finnvoor/yap/issues | finnvoor (OSS) | 2025-12-16 | accessed 2026-09-21 | low (inference from an issue title) | community
- SpeechTranscriber abstract: "A speech-to-text transcription module that's appropriate for normal conversation and general purposes." | https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json | Apple docs (JSON render used because HTML page returned title only) | current for macOS 26 | accessed 2026-09-21 | high | vendor primary
- Concurrency: "Several transcriber instances can share the same backing engine instances and models, so long as the transcribers are configured similarly in certain respects." | same JSON URL | Apple | current | accessed 2026-09-21 | high | vendor primary
- Async decoupling: "Your application can add audio as it becomes available in one task and display or further process the results independently in another task. Swift's async sequences buffer and decouple the input and results." | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple | 2025-06 | accessed 2026-09-21 | high | vendor primary
- Assets: "Simply install the relevant model assets via the new AssetInventory API." Code: `AssetInventory.assetInstallationRequest(supporting: [module])` then `downloader.downloadAndInstall()`. There is a cap on reserved assets: "If you exceed the limit, you can ask AssetInventory to deallocate one or more of them to free up a spot." | https://developer.apple.com/videos/play/wwdc2025/277/ | Apple | 2025-06 | accessed 2026-09-21 | high | vendor primary
- Locales: API exposes `supportedLocales` (incl. downloadable), `installedLocales`, `supportedLocale(equivalentTo:)`, `isAvailable` | speechtranscriber.json | Apple | current | accessed 2026-09-21 | high | vendor primary
- Launch languages: Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Spanish (English variants not enumerated) | https://blog.addpipe.com/apple-speechanalyzer-api/ | addpipe | 2026-08-17 | accessed 2026-09-21 | medium | third-party
- Custom vocabulary is absent: SpeechAnalyzer "lacks the Custom Vocabulary feature" of the older API | https://www.argmaxinc.com/blog/apple-and-argmax | Argmax (WhisperKit vendor) | 2025-06-20 | accessed 2026-09-21 | medium | vendor (competitor)
- Latency to finalized result is 1.4-2.2 s for short utterances; `prepareToAnalyze(in:)` preheats and roughly halves it; Apple engineer pointed to it as the accepted answer | https://developer.apple.com/forums/thread/794720 | Apple Developer Forums | 2025-07 to 2026-03 | accessed 2026-09-21 | medium (n=11 user measurement) | community + Apple engineer
- LibriSpeech (read speech, single speaker): SpeechAnalyzer 2.12% / 4.56% WER (test-clean / test-other) vs Whisper small 3.74% / 7.95%; no large-v3 or turbo in the comparison | https://lyonesse.app/blog/apple-speech-api-benchmark.html | Lyonesse / get-inscribe (app vendor shipping SpeechAnalyzer) | 2026-07-13 | accessed 2026-09-21 | medium (methodology reproduced OpenAI's published Whisper numbers within 0.11-0.42 pp per developersdigest summary) | vendor-adjacent, not meeting audio
- Earnings22 long-form conversational (10% subset, ~12 h): SpeechTranscriber 14.0 WER vs WhisperKit small.en 12.8, base.en 15.2; no large-v3/turbo row | https://www.argmaxinc.com/blog/apple-and-argmax | Argmax | 2025-06-20 | accessed 2026-09-21 | medium (vendor, macOS 26 beta 1, >6 months old) | vendor (competitor)
- LibriSpeech 40-clip balanced subset: Apple 1.98% WER vs whisper.cpp small.en 4.28% | https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4 | IraVoice founder (ships Apple path; bias disclosed) | 2026-08-01 (year inferred from macOS 26.5 build 25F71) | accessed 2026-09-21 | low-medium (n=40 short clips) | vendor-adjacent, not meeting audio
- Real-world failure reports in yap (CLI wrapper): #27 "Transcription hangs indefinitely and crashes on real-world video files" (2026-04-16); #32 asset download "CancellationError()" (2026-07-15); #12 slow on 30 s audio (2025-06-26) | https://github.com/finnvoor/yap/issues | finnvoor | 2025-06 to 2026-07 | accessed 2026-09-21 | medium (issue titles only; not root-caused to the framework) | community

## Measurements table

| source | dataset + condition | SpeechAnalyzer result | Whisper model + result | machine + OS |
|---|---|---|---|---|
| lyonesse.app (2026-07-13) | LibriSpeech test-clean (2,620 utt) / test-other (2,939 utt); read audiobook speech, single speaker, near-field | 2.12% / 4.56% WER; ~3x faster than Whisper small; 12-40x real-time | WhisperKit small 3.74% / 7.95%; base 5.42% / 12.51%; tiny 7.88% / 17.04%; legacy SFSpeechRecognizer 9.02% / 16.25%. No large-v3 or turbo. | M2 Pro 32 GB, macOS 26.5.1 |
| argmaxinc.com (2025-06-20, vendor) | earnings22 10% random subset (~12 h), long-form conversational earnings calls (phone/near-field, few speakers, no far-field) | 14.0 WER, speed factor 70x | WhisperKit whisper-small.en 12.8 WER @35x; whisper-base.en 15.2 @111x; (Argmax Pro parakeet-v2 11.7 @359x). No large-v3 or turbo. | M4 Mac mini, macOS 26 beta seed 1 |
| dev.to/iravoice (2026-08-01) | LibriSpeech test-clean, 40 clips (20F/20M), 4-10 s each, 607 ref words | 1.98% WER, 1.02% CER; median latency 125-132 ms | whisper.cpp 1.8.4 ggml-small.en 4.28% WER, 1.79% CER | M5 Max 128 GB, macOS 26.5 (25F71) |
| developersdigest.tech (2026-07-13) | Same as lyonesse (summary of the get-inscribe benchmark, no new measurement) | same | same | same |
| blog.addpipe.com (2026-08-17) | none; qualitative only ("2.2 times faster than ... Whisper's Large V3", speed not accuracy) | no WER/CER | Whisper large-v3 speed only | not stated |
| Apple WWDC25 277 | none; claim only | "good for long-form and distant audio" | none | none |

No source read this run measured SpeechAnalyzer against Whisper large-v3 or large-v3-turbo on accuracy. No source read this run measured it on far-field multi-speaker English meeting audio (AMI, ICSI, or similar).

## API facts

- Entry points (Apple, session 277): `SpeechAnalyzer`, `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` or `init(locale:preset:)`; file path is `analyzeSequence(from: AVAudioFile)` -> last `CMTime`, then `finalizeAndFinish(through:)`. Results arrive on `transcriber.results` as an `AsyncSequence` of `SpeechTranscriber.Result`.
- Options exposed on the type: `Preset`, `TranscriptionOption`, `ReportingOption` (session shows `.volatileResults`; forum thread also uses `.fastResults`), `ResultAttributeOption` (`.audioTimeRange`).
- Timestamps: `audioTimeRange` is an AttributedString run attribute of type `CMTimeRange`. Apple's transcript says "each run"; run granularity (word vs phrase) is not specified in anything read. Treat per-word as unverified.
- Confidence: not mentioned in the session transcript, the SpeechTranscriber JSON abstract, or any independent source read. Unverified whether any confidence attribute exists; nothing read says it does.
- On-device: Apple states transcription is entirely on device; models are downloaded via `AssetInventory` and not preinstalled (Apple and Argmax agree). `AssetInventory` has a reservation limit that requires deallocating assets when exceeded (count not stated in what was read).
- Locales: `supportedLocales` / `installedLocales` / `supportedLocale(equivalentTo:)`; English is among launch languages; specific English variants (en-US, en-GB, etc.) not enumerated in anything read.
- Concurrency: multiple transcriber instances may share one backing engine if configured similarly; input and output are decoupled by async sequences. No documented input-length limit was found in anything read.
- Preheat: `prepareToAnalyze(in:)` recommended by an Apple engineer; user measurement shows ~2.2 s -> ~1.45 s to finalized result on short utterances.
- Platform: iOS/iPadOS/macOS/tvOS/visionOS/Mac Catalyst 26.0+; Apple Silicon (per developersdigest; not confirmed from Apple text read).
- No custom vocabulary / contextual strings (Argmax, vendor).

## Leads

- The round-2 search summary reported "SpeechAnalyzer, AliMeeting Chinese: near-field CER 34% (excluding outliers ~25%), far-field CER 40% (single channel, no beamforming, >30% overlap)". The addpipe post did not contain it. Likely origin is https://origin-devforums.apple.com/forums/thread/819555 ("Building Real-Time Voice Input on ...") or https://dev.to/xiaocai_oh_07632a08eb20c6/ambient-voice-v2-... ; neither was fetched (budget). This is the only far-field, overlapped, meeting-style number seen anywhere and it is Mandarin, not English. Worth one fetch next round.
- https://mjtsai.com/blog/2026/07/22/whisper-and-speechanalyzer/ aggregates community reactions; may link further measurements.
- https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621 claims SpeechAnalyzer runs ~2x faster than Whisper large-v3-turbo "in independent 2026 benchmarks"; the underlying benchmark was not identified.
- yap issue #27 (hangs/crashes on real-world video) is the closest thing to a long-file failure report; needs reading for file length and whether the fault is in yap or the framework.
- Apple SpeechTranscriber.Result page (JSON path https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/result.json) would settle whether `alternatives` or a confidence field exists.

## Looked for and could not find

- Any measurement of SpeechAnalyzer vs Whisper large-v3 or large-v3-turbo on accuracy (every comparison read used small/base/tiny).
- Any English far-field multi-speaker meeting measurement (AMI, ICSI, CHiME) for SpeechAnalyzer.
- Any Apple statement of a maximum input duration, or of behaviour on overlapping speech, silence, language switching, or memory footprint.
- A confidence-score attribute in the API.
- Word-level timestamp guarantee (Apple says "each run").
- Enumerated English locale variants.
- HTML bodies for developer.apple.com/documentation/speech/speechanalyzer, /speechtranscriber, and the sample page "bringing-advanced-speech-to-text-capabilities-to-your-app" (all three returned title only; the /tutorials/data/.../speechtranscriber.json path worked and was used instead).
- blog.addpipe.com/apple-speechanalyzer-speechtranscriber-benchmark/ (404); the live post is /apple-speechanalyzer-api/ and has no accuracy numbers.

## Sources read

1. https://developer.apple.com/videos/play/wwdc2025/277/ (Apple, transcript body returned)
2. https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json (Apple docs JSON; HTML page was title-only)
3. https://lyonesse.app/blog/apple-speech-api-benchmark.html (2026-07-13)
4. https://www.argmaxinc.com/blog/apple-and-argmax (2025-06-20, vendor, older than 6 months)
5. https://developer.apple.com/forums/thread/794720 (2025-07 to 2026-03)
6. https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4 (2026-08-01)
7. https://www.developersdigest.tech/blog/apple-speechanalyzer-vs-whisper-benchmark (2026-07-13, secondary)
8. https://github.com/finnvoor/yap/issues (issue list only)
9. https://blog.addpipe.com/apple-speechanalyzer-api/ (2026-08-17)

Title-only (not counted as read): developer.apple.com/documentation/speech/speechanalyzer, developer.apple.com/documentation/speech/speechtranscriber, developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app. 404: blog.addpipe.com/apple-speechanalyzer-speechtranscriber-benchmark/.
