# D2 retention digest

Scope: content retention (dropped stretches, not WER) on long far-field multi-speaker audio. Budget spent: 20 tool calls, 12 sources. Every number below is tied to the dataset, condition and model version the source named; where the source was ambiguous that is flagged rather than resolved.

## Claims

- OpenAI reference decoder skips a whole 30 s window when `no_speech_prob > 0.6` AND `avg_logprob <= -1.0` (`seek += segment_size; continue`); a high avg_logprob overrides the no-speech skip. Defaults: temperature fallback `(0.0, 0.2, 0.4, 0.6, 0.8, 1.0)`, `compression_ratio_threshold=2.4`, `logprob_threshold=-1.0`, `no_speech_threshold=0.6`, `condition_on_previous_text=True`, `hallucination_silence_threshold=None` (off). | https://raw.githubusercontent.com/openai/whisper/main/whisper/transcribe.py | openai/whisper (main branch, unversioned) | n/a | accessed 2026-09-21 | confidence high | class quality
- WhisperKit `DecodingOptions` defaults mirror OpenAI's window-skip rule (`noSpeechThreshold=0.6`, doc comment: silent only if no-speech prob is high AND avg logprob below `logProbThreshold=-1.0`), with fallback enabled by default (`temperatureFallbackCount=5`, `temperatureIncrementOnFallback=0.2`, `compressionRatioThreshold=2.4`). It adds a mechanism OpenAI does not have: `firstTokenLogProbThreshold=-1.5` ("If the log probability over the first sampled token is below this value, treat as failed"). `chunkingStrategy` defaults to `nil` (no VAD chunking unless the caller opts in); `concurrentWorkerCount=16` on macOS. | https://raw.githubusercontent.com/argmaxinc/WhisperKit/main/Sources/WhisperKit/Core/Configurations.swift | argmaxinc/WhisperKit (main branch) | n/a | accessed 2026-09-21 | confidence high (defaults) / low (what happens to the window after 5 failed fallbacks is NOT in this file) | class quality
- whisper.cpp CLI defaults: `temperature=0.0`, `temperature_inc=0.2`, `no_fallback=false` (fallback ON in the CLI; `wparams.temperature_inc = no_fallback ? 0 : temperature_inc`), `entropy_thold=2.40` (entropy replaces compression ratio), `logprob_thold=-1.0`, `no_speech_thold=0.6`, `suppress_nst=false`, `vad=false` (Silero VAD opt-in via `--vad --vad-model`, `vad_threshold=0.5`, `min_speech=250 ms`, `min_silence=100 ms`), `max_len=0`. No comments on hallucination or silent-segment handling in the CLI. | https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/examples/cli/cli.cpp | ggml-org/whisper.cpp (master) | n/a | accessed 2026-09-21 | confidence high (CLI defaults) / medium (library `whisper_full_default_params` not read) | class quality
- faster-whisper: Silero VAD is opt-in (`vad_filter=True`) for standard `transcribe`, enabled by default for batched transcription; default VAD is "conservative and only removes silence longer than 2 seconds"; other thresholds live in `WhisperModel` and were not in the README. | https://raw.githubusercontent.com/SYSTRAN/faster-whisper/master/README.md | SYSTRAN/faster-whisper (master) | n/a | accessed 2026-09-21 | confidence medium | class quality
- WhisperKit issue #528 (open, no maintainer reply as of read): user running large-v2 via MacWhisper reports omitted content segments, generated text not in the audio, and wrong language ID versus whisper-diarization on the same audio; asks whether it is "model conversion, segmentation/VAD, or decoding settings". No audio details, no WhisperKit version. | https://github.com/argmaxinc/WhisperKit/issues/528 | GitHub (argmaxinc) | 2026-08-23 | accessed 2026-09-21 | confidence low (single unreplied user report) | class quality
- The WhisperKit issue tracker page rendered under the repository name "argmax-oss-swift" at read time, suggesting the repo was renamed/merged; issue search there surfaced no closed issue titled around skipped/missing segments. | https://github.com/argmaxinc/WhisperKit/issues?q=is%3Aissue+skipped+OR+missing+OR+dropped+OR+silence | GitHub | n/a | accessed 2026-09-21 | confidence low (page summary, not verified by direct listing) | class landscape
- Open ASR Leaderboard paper (v3): no discussion of hallucination, deletions, insertions or content dropping for any model; no per-model AMI breakdown in the main tables; batching used batch size 64 reduced adaptively. Reported: Whisper large v3 7.44 WER and Canary Qwen 2.5B 5.63 WER (the fetch labelled 7.44 as "AMI" but the same paper says WER is averaged over datasets — treat 7.44 as the leaderboard average, unconfirmed as AMI). | https://arxiv.org/html/2510.06961v3 | arXiv (hf-audio et al.) | 2025-12-10 | accessed 2026-09-21 | confidence medium | class performance
- Open ASR Leaderboard long-form track (blog): Whisper large v3 6.43 WER (RTFx 68.56) vs NVIDIA Parakeet CTC 1.1B 6.68 WER (RTFx 2793.75); "closed-source systems still edge out open ones" on long-form; long-form datasets and chunking method not stated in the post; no hallucination/deletion analysis. | https://huggingface.co/blog/open-asr-leaderboard | Hugging Face | 2025-11-21 | accessed 2026-09-21 | confidence medium (stale >3 months; large-v3-turbo and Parakeet-TDT not reported in the fetched text) | class performance
- Parakeet-TDT-0.6B-v3 model card: AMI 11.31, Earnings-22 11.42, TED-LIUM v3 2.75, GigaSpeech 9.59, LibriSpeech other 3.59, average 6.34 (Open ASR Leaderboard style, per card). Long audio: "up to 24 minutes with full attention (on A100 80GB) or up to 3 hours with local attention" (attention left/right context 256, `rel_pos_local_attn`); "at least 2GB RAM for model to load. The bigger the RAM, the larger audio input it supports"; ~83% relative WER increase at SNR -5 dB vs clean; no hallucination mitigation documented. | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 | NVIDIA / Hugging Face | 2025-08-14 | accessed 2026-09-21 | confidence high for card contents; stale >1 month for "current version" | class performance / version-compat
- CrisperWhisper (fine-tuned Whisper large-v3 with cross-attention retraining for verbatim + pauses): AMI 8.72 vs Whisper large v3 16.01; TED-LIUM 3.35 vs 3.9; Earnings22 12.37 vs 11.3 (Whisper better); average 6.66 vs 7.7. The transcription table does not say IHM vs SDM; the segmentation table uses AMI IHM (F1 0.79 vs 0.66). No insertion/deletion breakdown in the README. | https://huggingface.co/nyralabs/CrisperWhisper/blob/main/README.md | nyralabs (Hugging Face) | paper 2024-08-29 (Interspeech 2024) | accessed 2026-09-21 | confidence medium (stale; the AMI 16.01 for large-v3 is far worse than leaderboard-style numbers for other models — normalization/condition likely differs, do not compare across sources) | class performance
- Apple SpeechAnalyzer (macOS 26) benchmark via Inscribe: LibriSpeech, clean 2.12% WER, noisy 4.56% WER, vs legacy SFSpeechRecognizer 9.02% / 16.25%; beat every Whisper model tested including Whisper Small; ~3x faster than Whisper Small on M2 Pro. Single-speaker read speech; no large-v3/turbo comparison; a linked note (Yuki) says SpeechAnalyzer "can't distinguish between the various participants" when several people share one input. | https://mjtsai.com/blog/2026/07/22/whisper-and-speechanalyzer/ (aggregating https://get-inscribe.com/blog/apple-speech-api-benchmark.html) | Michael Tsai (aggregator) / Inscribe (vendor) | 2026-07-22 | accessed 2026-09-21 | confidence low-medium (vendor benchmark, small Whisper baseline, not meeting audio) | class performance
- IraVoice benchmark: LibriSpeech test-clean, 40 single-speaker clips (20F/20M, 4-10 s), M5 Max, macOS 26.5 (25F71): SpeechAnalyzer WER 1.98% / CER 1.02% / 12 word edits of 607 vs whisper.cpp 1.8.4 `ggml-small.en` WER 4.28% / CER 1.79% / 26 edits; latency medians ~125-132 ms (Apple) vs ~122-125 ms (whisper.cpp). Substitution/insertion/deletion were recorded but only aggregate edits published. | https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4 | IraVoice founder (vendor) on dev.to | 2026-08-01 (year inferred from macOS 26.5) | accessed 2026-09-21 | confidence low-medium (vendor, small.en baseline, short single-speaker clips) | class performance
- Consumer-GPU note for Parakeet-TDT full attention: O(N^2) memory means 2-3 min of audio already OOMs an 8 GB card; switching to local attention (+/-256 frames, ~+/-20 s context) costs "about 1-3% WER". | https://dosmoon.com/aistack/research/parakeet-on-consumer-gpu/ (surfaced by search, not read) | aistack blog (aggregator) | n/a | accessed 2026-09-21 | confidence low (unread, unsourced numbers) | class performance

## Benchmark table

| model+version | dataset+condition | WER | deletions/insertions | source |
|---|---|---|---|---|
| Whisper large-v3 (per CrisperWhisper README eval) | AMI (condition unstated; likely IHM given segmentation table) | 16.01 | not given | huggingface.co/nyralabs/CrisperWhisper README |
| CrisperWhisper (large-v3 fine-tune) | AMI (same eval) | 8.72 | not given | same |
| Whisper large-v3 | TED-LIUM | 3.9 | not given | same |
| CrisperWhisper | TED-LIUM | 3.35 | not given | same |
| Whisper large-v3 | Earnings22 | 11.3 | not given | same |
| CrisperWhisper | Earnings22 | 12.37 | not given | same |
| Parakeet-TDT-0.6B-v3 (2025-08-14) | AMI (Open ASR Leaderboard eval, condition per leaderboard = IHM mix per dataset card, not confirmed here) | 11.31 | not given | huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Parakeet-TDT-0.6B-v3 | Earnings-22 | 11.42 | not given | same |
| Parakeet-TDT-0.6B-v3 | TED-LIUM v3 | 2.75 | not given | same |
| Parakeet-TDT-0.6B-v3 | leaderboard average (7 sets) | 6.34 | not given | same |
| Whisper large v3 | Open ASR long-form track (datasets not named in fetched text) | 6.43 (RTFx 68.56) | not given | huggingface.co/blog/open-asr-leaderboard (2025-11-21) |
| Parakeet CTC 1.1B | Open ASR long-form track | 6.68 (RTFx 2793.75) | not given | same |
| Whisper large v3 | Open ASR Leaderboard, average (fetch labelled "AMI"; unconfirmed) | 7.44 | not given | arxiv.org/html/2510.06961v3 |
| Canary Qwen 2.5B | Open ASR Leaderboard average | 5.63 | not given | same |
| Apple SpeechAnalyzer (macOS 26) | LibriSpeech clean, single speaker (Inscribe) | 2.12 | not given | mjtsai.com 2026-07-22 -> get-inscribe.com |
| Apple SpeechAnalyzer | LibriSpeech "noisy" (Inscribe's noise condition, not far-field) | 4.56 | not given | same |
| Apple SpeechAnalyzer | LibriSpeech test-clean, 40 clips, macOS 26.5 | 1.98 (CER 1.02) | 12 edits / 607 words, breakdown withheld | dev.to/iravoice 2026-08-01 |
| whisper.cpp 1.8.4 small.en | same | 4.28 (CER 1.79) | 26 edits / 607 words | same |

No source read reports Whisper large-v3-turbo, distil-whisper, Canary (per-dataset), Voxtral, or Kyutai STT on AMI, and none reports AMI SDM for any model. No source read gives a deletion/insertion/substitution breakdown.

## Failure-mode table

| runtime | mechanism | default setting | mitigation available | source |
|---|---|---|---|---|
| OpenAI reference (`whisper/transcribe.py`, main) | 30 s window skipped entirely when `no_speech_prob > no_speech_threshold` unless `avg_logprob > logprob_threshold` | `no_speech_threshold=0.6`, `logprob_threshold=-1.0` -> skip fires when the window is both "probably silent" and "low confidence" | raise `no_speech_threshold`, set `logprob_threshold=None` (disables the override, making skips MORE likely) or `no_speech_threshold=None` (never skip) | raw.githubusercontent.com/openai/whisper/main/whisper/transcribe.py |
| OpenAI reference | temperature fallback on compression-ratio / logprob failure | `(0.0,0.2,0.4,0.6,0.8,1.0)`, `compression_ratio_threshold=2.4` | disable by passing a single temperature; this removes the loop-breaker | same |
| OpenAI reference | previous-text conditioning (repetition-loop carrier) | `condition_on_previous_text=True` | set False | same |
| OpenAI reference | hallucination-on-silence gap detection | `hallucination_silence_threshold=None` (off) | set a seconds value (requires word timestamps) | same |
| WhisperKit (Configurations.swift, main) | same no-speech AND low-logprob window skip | `noSpeechThreshold=0.6`, `logProbThreshold=-1.0` | callers can change both | raw.githubusercontent.com/argmaxinc/WhisperKit/main/Sources/WhisperKit/Core/Configurations.swift |
| WhisperKit | first-token log-prob failure (WhisperKit-specific) | `firstTokenLogProbThreshold=-1.5` -> window "treated as failed" and enters fallback | raise/disable threshold; what the window yields after fallbacks are exhausted is NOT documented in the file read | same |
| WhisperKit | temperature fallback | ON: `temperatureFallbackCount=5`, `+0.2` per step, `compressionRatioThreshold=2.4` | callers can set count 0 (disables) | same |
| WhisperKit | VAD-based chunking | `chunkingStrategy=nil` (no VAD chunking) | `.vad` chunking strategy exists as an option (enum member name not verified in this read) | same |
| WhisperKit | concurrency | `concurrentWorkerCount=16` on macOS | n/a | same |
| whisper.cpp CLI | temperature fallback | ON (`no_fallback=false`, `temperature_inc=0.2`) | `-nf` disables | raw.githubusercontent.com/ggml-org/whisper.cpp/master/examples/cli/cli.cpp |
| whisper.cpp CLI | repetition detection via entropy (not compression ratio) | `entropy_thold=2.40`, `logprob_thold=-1.0`, `no_speech_thold=0.6` | tunable flags | same |
| whisper.cpp CLI | Silero VAD pre-segmentation | OFF (`vad=false`); when on: threshold 0.5, min speech 250 ms, min silence 100 ms | `--vad --vad-model <path>` | same |
| whisper.cpp CLI | non-speech-token suppression | `suppress_nst=false` | `-sns` | same |
| faster-whisper | Silero VAD filter | OFF for `transcribe`, ON for batched; drops only silence > 2 s by default | `vad_filter=True`, `vad_parameters` | raw.githubusercontent.com/SYSTRAN/faster-whisper/master/README.md |
| Parakeet-TDT-0.6B-v3 | full-attention memory ceiling (O(N^2)); long inputs must be chunked or run with local attention | full attention up to 24 min on A100 80GB | local attention (context 256) up to 3 h; streaming `left_context_secs=10, right_context_secs=2` | huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |

## Leads

- WhisperKit downstream issue titles surfaced by search but not read: uttrflow/uttrflow-swift #871 ("Recognition discards WhisperKit's fallback count and never records its empty-result retry, so up to six decodes per piece are invisible") suggests WhisperKit performs an empty-result retry after fallbacks; saurabhav88/EnviousWispr #2919 (WhisperKit yields no speaker turns on a two-speaker file where Parakeet yields 338); TypeWhisper/typewhisper-mac #1352 (large-v3 via Groq returns half the audio with no segment-coverage check). Each is a single downstream project; verify against WhisperKit source before citing.
- openai/whisper discussion #29 "Stops working after long gap with no speech?" — canonical thread on the silence-skip failure; not read.
- Full CrisperWhisper paper HTML (arxiv.org/html/2408.16589) for the mechanism claim that Whisper's cross-attention drifts on pauses and for any deletion breakdown; only the abstract was read.
- WhisperKit `TextDecoder` / `TranscribeTask` source for what a window returns after `temperatureFallbackCount` is exhausted, and the exact `chunkingStrategy` enum; also the WhisperKit release notes for when `firstTokenLogProbThreshold` and VAD chunking landed.
- Open ASR Leaderboard dataset repo `hf-audio/open-asr-leaderboard/tree/main/ami` holds per-model AMI result files; parsing them would give large-v3-turbo, Canary, Voxtral, Kyutai AMI numbers under one normalizer.
- A retention metric the leaderboard does not publish: fraction of reference words in stretches with zero hypothesis output. None of the sources read measures it; the AMI SDM split is the right place to measure it locally.

## Looked for and could not find

- Any AMI SDM (single distant mic) WER for any model in the sources read; all AMI numbers are IHM-style or unlabelled.
- Whisper large-v3-turbo, distil-whisper, Canary (per-dataset), Voxtral, Kyutai STT AMI or long-form numbers with version named.
- Any deletion/insertion/substitution breakdown for any model on AMI, Earnings-22 or TED-LIUM.
- A WhisperKit issue or release note that names skipped/missing segments and a fixing release (GitHub API search returned 422; the HTML issue search surfaced only #528, open and unreplied).
- Evidence that TDT/CTC models skip or hallucinate less than attention-decoder models on long inputs; the only comparison found is aggregate long-form WER parity (Whisper large v3 6.43 vs Parakeet CTC 1.1B 6.68), which does not separate deletions from other errors.
- Any Apple SpeechAnalyzer measurement on multi-speaker, overlapping, or far-field audio; both benchmarks found use short single-speaker LibriSpeech clips and a Whisper Small baseline.
- faster-whisper defaults for `hallucination_silence_threshold`, `no_speech_threshold` (README does not list them).

## Sources read

1. https://raw.githubusercontent.com/openai/whisper/main/whisper/transcribe.py (accessed 2026-09-21)
2. https://raw.githubusercontent.com/argmaxinc/WhisperKit/main/Sources/WhisperKit/Core/Configurations.swift (accessed 2026-09-21)
3. https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/examples/cli/cli.cpp (accessed 2026-09-21)
4. https://raw.githubusercontent.com/SYSTRAN/faster-whisper/master/README.md (accessed 2026-09-21)
5. https://github.com/argmaxinc/WhisperKit/issues/528 (2026-08-23, accessed 2026-09-21)
6. https://github.com/argmaxinc/WhisperKit/issues?q=is%3Aissue+skipped+OR+missing+OR+dropped+OR+silence (accessed 2026-09-21)
7. https://arxiv.org/html/2510.06961v3 (2025-12-10, accessed 2026-09-21)
8. https://huggingface.co/blog/open-asr-leaderboard (2025-11-21, accessed 2026-09-21)
9. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (2025-08-14, accessed 2026-09-21)
10. https://huggingface.co/nyralabs/CrisperWhisper/blob/main/README.md (accessed 2026-09-21)
11. https://arxiv.org/abs/2408.16589 (abstract only; 2024-08-29, accessed 2026-09-21)
12. https://mjtsai.com/blog/2026/07/22/whisper-and-speechanalyzer/ (2026-07-22, accessed 2026-09-21)
13. https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4 (2026-08-01, accessed 2026-09-21)

Failed fetch: https://api.github.com/search/issues?q=repo:argmaxinc/WhisperKit+... (HTTP 422).
