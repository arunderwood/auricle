# D3 performance digest

Scope: on-device ASR throughput, memory, footprint and cold start on Apple-silicon Macs. Budget spent at 16 web calls / 7 sources read. No source read this run measured a 20-40 minute file end to end; every throughput number below is on shorter clips or on datasets of short utterances, and must be treated as an upper bound on what a long meeting file will see (long files add VAD/chunking, decoder drift and memory growth that these tests do not exercise). Nothing read this run reports peak memory for any candidate.

Terminology: "RTFx" = audio seconds / processing seconds (higher is faster). "RTF" = processing seconds / audio second (lower is faster). Sources mix them; each row states which.

## Claims

- On a MacBook Pro M4 (24 GB), one harness ran the same audio through nine implementations; ordered by mean wall time: FluidAudio CoreML parakeet-tdt-0.6b-v2 0.1935 s, parakeet-mlx parakeet-tdt-0.6b-v2 0.4995 s, mlx-whisper large-v3-turbo 1.0230 s, whisper.cpp large-v3-turbo-q5_0 (CoreML encoder enabled) 1.2293 s, WhisperKit large-v3 (not turbo) 2.2190 s. Audio length, runtime versions and result date are not stated on the README. | https://github.com/anvanvan/mac-whisper-speedtest | anvanvan (GitHub, independent) | undated | accessed 2026-09-21 | confidence medium (independent, same-machine, same-audio; but undated, unversioned, unknown clip length, and the WhisperKit row is large-v3 so it is not a turbo-vs-turbo comparison) | performance
- mlx_whisper (mlx-community/whisper-large-v3-turbo) ran 2.03 +/- 0.06x faster than whisper.cpp (ggml-large-v3-turbo.bin): mean 13.135 s (+/-0.280) vs 26.704 s (+/-0.625) over 10 hyperfine runs on the author's Mac, file mlk_ihaveadream_long.wav. Machine, clip length, and exact versions ("pip install -U", "git pull" on 2026-01-09) are not given. | https://notes.billmill.org/dev_blog/2026/01/updated_my_mlx_whisper_vs._whisper.cpp_benchmark.html | Bill Mill (independent blog) | 2026-01-09 | accessed 2026-09-21 | confidence medium (rigorous repetition, but machine and versions unstated; whisper.cpp flags unknown, so Metal-vs-CoreML encoder path unknown) | performance
- FluidAudio Parakeet TDT 0.6B v3 CoreML on a 2024 MacBook Pro M4 Pro 48 GB, macOS Tahoe 26.0: LibriSpeech test-clean 2,620 files, 19,452.5 s of audio in 125.0 s = RTFx 155.6x, avg WER 2.5%. v2 on the same rig: 133.4 s = RTFx 145.8x, avg WER 2.1%. FLEURS 23 languages: RTFx ~209.8x. These are batches of short utterances, not long files. | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md | FluidInference (vendor, but reproducible via their CLI) | undated page; Tahoe 26.0 implies >= 2025-09 | accessed 2026-09-21 | confidence medium (vendor-run, method published) | performance
- FluidAudio README (search snippet, page not read): Parakeet TDT v3 "approximately 110x RTF on M4 Pro for batch ASR (1 min audio ~ 0.5 s)". | https://github.com/FluidInference/FluidAudio | FluidInference (vendor) | undated | accessed 2026-09-21 | confidence low (snippet only) | performance
- FluidAudio Parakeet encoder Core ML cold compile: 3361 ms on iPhone 16 Pro Max, 4396 ms on iPhone 13. No Mac cold-compile number published there. | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md | FluidInference | undated | accessed 2026-09-21 | confidence medium (iPhone only; Mac expected to be no worse but unmeasured) | performance
- On an M5 Max 64 GB under MLX: Whisper large-v3 "12 to 18x" realtime, Whisper large-v3-turbo "20 to 30x", Parakeet TDT 0.6B v3 "100x and up"; clean English, Whisper on 30-second windows, Parakeet streaming. Ranges, not measurements; no runtime versions, no memory, no load times. | https://contracollective.com/blog/local-speech-to-text-whisper-parakeet-mlx-m5-max-2026 | Contra Collective (independent blog) | 2026-07-19 | accessed 2026-09-21 | confidence low-medium (only M5-class datapoint found; ranges rather than runs; unversioned) | performance
- WhisperKit paper: audio-encoder latency 218 ms per forward pass on M3 Max Neural Engine (down from 612 ms); text-decoder forward pass 4.6 ms on M3 ANE (from 8.4 ms) via stateful Core ML models, 0.3 W vs 1.5 W; Whisper large-v3-turbo compressed from 1.6 GB to 0.6 GB on disk with OD-MBP; streaming hypothesis latency ~0.45 s, confirmed text ~1.7 s. No file-level RTF, no peak memory, no compile time, no WhisperKit version stated. | https://arxiv.org/html/2507.10860v1 | Argmax (vendor paper) | 2025-07 | accessed 2026-09-21 | confidence medium for the disk sizes, low for extrapolating to file RTF; STALE (>12 months) | performance
- Vendor/app-blog claim (search snippet, page not read): large-v3-turbo on Apple silicon "809 MB on disk, 6 GB RAM peak, 9.1x real-time on M3". Runtime and audio unstated. | https://metawhisp.com/blog/whisper-large-v3-turbo/ | MetaWhisp (app vendor) | undated | accessed 2026-09-21 | confidence low (only peak-memory figure found for any candidate and it is unsourced) | performance
- Vendor claim (search snippet, page not read): on M2 Ultra, mlx-whisper transcribes 12 minutes of audio in 14 seconds (~50x realtime). Model not stated in snippet. | https://simonwillison.net/2024/Oct/1/whisper-large-v3-turbo-model/ (quoting Apple MLX team) | Simon Willison relaying Awni Hannun | 2024-10-01 | accessed 2026-09-21 | confidence low; STALE | performance
- Apple SpeechAnalyzer (search snippet, page not read): on a Mac mini M4 16 GB, macOS 26, 74-89x realtime on the AliMeeting dataset; separate independent test reports SpeechAnalyzer ~3x faster than Whisper Small with 2.12% WER clean / 4.56% noisy vs Whisper Small 3.74% / 7.95%. | https://blog.addpipe.com/apple-speechanalyzer-api/ and https://www.developersdigest.tech/blog/apple-speechanalyzer-vs-whisper-benchmark | addpipe / Developers Digest (independent) | 2025-2026, unconfirmed | accessed 2026-09-21 | confidence low (snippets only; the Whisper comparison is against Small, not large-v3-turbo) | performance
- Apple SpeechAnalyzer model is a system-managed download (no app-bundled weights); an Apple forum thread titled "SpeechTranscriber/SpeechAnalyzer being relatively slow compared to FoundationModel and TTS" exists, contents not read. | https://developer.apple.com/forums/thread/794720 | Apple Developer Forums | unknown | accessed 2026-09-21 | confidence low | version/compat
- parakeet-mlx variant "neuro-parakeet-mlx" card (snippet): RTF 0.042 (~24x realtime) on M4. Audio unstated. | https://huggingface.co/NeurologyAI/neuro-parakeet-mlx | NeurologyAI (HF card) | unknown | accessed 2026-09-21 | confidence low | performance
- Voxtral Mini 3B on MLX (mzbac/mlx.voxtral): quantized weights are 3.2 GB (4-bit mixed) and 5.3 GB (8-bit); requires mlx >= 0.26.5, mlx-lm >= 0.26.0; processes 30-second chunks; README publishes no timing, RTF, or memory numbers. | https://github.com/mzbac/mlx.voxtral | mzbac (community) | undated | accessed 2026-09-21 | confidence medium for sizes, none for speed | version/compat
- Kyutai STT runs on Apple silicon via moshi-mlx (`uvx --with moshi-mlx python scripts/stt_from_mic_mlx.py` from kyutai-labs/delayed-streams-modeling); the write-up reports no speed, memory or size numbers. Models: kyutai/stt-1b-en_fr and kyutai/stt-2.6b-en. | https://anil.recoil.org/notes/kyutai-streaming-voice-mlx | Anil Madhavapeddy (independent) | 2025-07-16 | accessed 2026-09-21 | confidence medium for "a runtime exists", none for performance; STALE | version/compat
- Canary on Apple silicon: search snippets say mlx-audio "supports Canary STT"; no page read confirmed Canary-Qwen-2.5B specifically or gave any number. | https://github.com/Blaizzy/mlx-audio | Blaizzy (community) | unknown | accessed 2026-09-21 | confidence low | version/compat

## Performance table

RTF column: "RTFx" = faster-than-realtime multiple; "s" = wall seconds on an unstated clip. "n/s" = not stated by the source.

| candidate | runtime+version | machine | audio length | realtime factor | peak memory | download size | cold start | source |
|---|---|---|---|---|---|---|---|---|
| WhisperKit large-v3 (NOT turbo) | WhisperKit, version n/s | MacBook Pro M4 24 GB | n/s (same clip as other rows) | 2.2190 s mean | n/s | n/s | n/s | mac-whisper-speedtest |
| WhisperKit large-v3-turbo | WhisperKit, version n/s | M3 Max (ANE) | per 30 s encoder window | encoder 218 ms/window; decoder 4.6 ms/token | n/s | 0.6 GB compressed (1.6 GB uncompressed) | n/s | arXiv 2507.10860 (stale) |
| WhisperKit/unspecified large-v3-turbo | n/s | "M3" | n/s | 9.1x RTFx | 6 GB (unsourced) | 809 MB | n/s | metawhisp snippet (low) |
| whisper.cpp large-v3-turbo-q5_0, CoreML encoder on | whisper.cpp, version n/s | MacBook Pro M4 24 GB | n/s | 1.2293 s mean | n/s | n/s | n/s | mac-whisper-speedtest |
| whisper.cpp ggml-large-v3-turbo.bin | whisper.cpp git HEAD 2026-01-09, flags n/s | author's Mac, n/s | mlk_ihaveadream_long.wav, length n/s | 26.704 s +/- 0.625 (10 runs) | n/s | n/s | n/s | billmill 2026-01 |
| mlx-whisper large-v3-turbo | mlx_whisper, version n/s | MacBook Pro M4 24 GB | n/s | 1.0230 s mean | n/s | n/s | n/s | mac-whisper-speedtest |
| mlx-whisper large-v3-turbo | mlx_whisper pip latest 2026-01-09 | author's Mac, n/s | same clip as above | 13.135 s +/- 0.280 (10 runs); 2.03x faster than whisper.cpp | n/s | n/s | n/s | billmill 2026-01 |
| mlx-whisper large-v3-turbo | MLX, version n/s | M5 Max 64 GB | 30 s windows, clean English | "20 to 30x" RTFx | n/s | n/s | n/s | contracollective 2026-07 |
| mlx-whisper large-v3 | MLX, version n/s | M5 Max 64 GB | 30 s windows | "12 to 18x" RTFx | n/s | n/s | n/s | contracollective 2026-07 |
| parakeet-mlx parakeet-tdt-0.6b-v2 | parakeet-mlx, version n/s | MacBook Pro M4 24 GB | n/s | 0.4995 s mean | n/s | n/s | n/s | mac-whisper-speedtest |
| Parakeet TDT 0.6B v3 (MLX) | MLX, version n/s | M5 Max 64 GB | streaming, clean English | "100x and up" RTFx | n/s | n/s | n/s | contracollective 2026-07 |
| neuro-parakeet-mlx | parakeet-mlx fork | M4 | n/s | RTF 0.042 (~24x) | n/s | n/s | n/s | HF card snippet (low) |
| FluidAudio parakeet-tdt-0.6b-v2-coreml | FluidAudio, version n/s | MacBook Pro M4 24 GB | n/s | 0.1935 s mean | n/s | n/s | n/s | mac-whisper-speedtest |
| FluidAudio parakeet-tdt-0.6b-v3-coreml | FluidAudio CLI, version n/s | MacBook Pro M4 Pro 48 GB, macOS 26.0 | LibriSpeech test-clean, 19,452.5 s total across 2,620 short files | 155.6x RTFx (125.0 s) | n/s | n/s | encoder compile 3.4 s (iPhone 16 Pro Max) / 4.4 s (iPhone 13); Mac n/s | FluidAudio Benchmarks.md |
| FluidAudio parakeet-tdt-0.6b-v2-coreml | same | same | same | 145.8x RTFx (133.4 s) | n/s | n/s | as above | FluidAudio Benchmarks.md |
| Apple SpeechAnalyzer / SpeechTranscriber | macOS 26 system model | Mac mini M4 16 GB | AliMeeting (Chinese) dataset | 74-89x RTFx | n/s | system-managed asset, size n/s | n/s | addpipe snippet (low) |
| Voxtral Mini 3B (MLX) | mlx.voxtral, mlx >= 0.26.5 | n/s | n/s | n/s | n/s | 3.2 GB (4-bit mixed) / 5.3 GB (8-bit) | n/s | mzbac/mlx.voxtral |
| Kyutai stt-1b-en_fr / stt-2.6b-en | moshi-mlx, version n/s | "Mac laptop" | live mic | n/s | n/s | n/s | n/s | anil.recoil.org (stale) |
| Canary-Qwen-2.5B | possibly mlx-audio; unconfirmed | none | none | none | none | none | none | none read |

Reading across rows on the one same-machine harness (M4 24 GB): the two Parakeet runtimes finish the clip 2-5x sooner than the two turbo-Whisper runtimes, and FluidAudio CoreML is ~2.6x faster than parakeet-mlx. mlx-whisper beats whisper.cpp on both independent runs that compare them (1.2x on M4 with CoreML encoder; 2.0x on Bill Mill's unstated machine with unstated whisper.cpp flags). These two whisper.cpp results are not the same configuration, so do not merge them.

## Leads

- Argmax's live benchmark space (huggingface.co/spaces/argmaxinc/whisperkit-benchmarks) was not fetched; it is the only place likely to publish WhisperKit large-v3-turbo file-level speed factor and per-device numbers by WhisperKit version. Highest-value next read.
- Argmax blog "Apple SpeechAnalyzer and Argmax WhisperKit" (argmaxinc.com/blog/apple-and-argmax) reportedly compares the two head-to-head; not read.
- lyonesse.app/blog/apple-speech-api-benchmark.html (redirect target of get-inscribe.com) claims a SpeechAnalyzer-vs-Whisper benchmark with methodology; fetch failed on redirect, not retried.
- mac-whisper-speedtest README likely has a commit date and the test clip in-repo; `git log` on the repo would date the M4 table and give the clip length.
- FluidAudio releases page (v0.13.4 and later) mentions "RTFx tracking added to all benchmark workflows"; per-release Mac numbers may live in release notes.
- whisper.cpp's own benchmark issue threads (ggml-org/whisper.cpp "Benchmark results" issue) collect user-submitted Metal numbers per chip; not queried this run.
- arXiv 2510.18921 "Benchmarking On-Device Machine Learning on Apple Silicon with MLX" may include ASR memory numbers; not read.
- Apple forum thread 794720 on SpeechAnalyzer slowness could contain concrete Mac timings.

## Looked for and could not find

- Any measurement on a single 20-40 minute file for any candidate on any Mac.
- Peak memory for any candidate from a source with stated methodology (only an unsourced "6 GB" app-blog figure).
- Cold-start / model-compile time on a Mac for WhisperKit, whisper.cpp, mlx-whisper, parakeet-mlx, or SpeechAnalyzer (FluidAudio publishes iPhone compile times only).
- Runtime version numbers on every performance source; none states one.
- M1/M2/M3-class numbers for large-v3-turbo with a stated runtime and clip (M3 numbers found are per-window encoder latency or unsourced).
- Any Canary-Qwen-2.5B Apple-silicon runtime confirmed by a page read; any Kyutai STT or Voxtral Mini throughput number on a Mac.
- SpeechAnalyzer model download size and its throughput on English meeting audio (the only speed figure found is on a Chinese meeting corpus).

## Sources read

1. https://github.com/anvanvan/mac-whisper-speedtest (undated, M4 24 GB nine-way table)
2. https://notes.billmill.org/dev_blog/2026/01/updated_my_mlx_whisper_vs._whisper.cpp_benchmark.html (2026-01-09)
3. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md (undated, macOS 26.0)
4. https://contracollective.com/blog/local-speech-to-text-whisper-parakeet-mlx-m5-max-2026 (2026-07-19)
5. https://arxiv.org/html/2507.10860v1 (2025-07, stale)
6. https://github.com/mzbac/mlx.voxtral (undated)
7. https://anil.recoil.org/notes/kyutai-streaming-voice-mlx (2025-07-16, stale)

Fetched but not read: https://get-inscribe.com/blog/apple-speech-api-benchmark.html (308 redirect to lyonesse.app). Search-snippet-only (not read, low confidence): metawhisp.com, developersdigest.tech, blog.addpipe.com, huggingface.co/NeurologyAI/neuro-parakeet-mlx, github.com/FluidInference/FluidAudio README, simonwillison.net 2024-10-01, developer.apple.com/forums/thread/794720, github.com/Blaizzy/mlx-audio.
