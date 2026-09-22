# D4 integration round 2 digest

Scope: WhisperKit (argmaxinc/WhisperKit, now argmax-oss-swift) decoding behaviour on long PCM WAV meetings; Parakeet-TDT routes from Swift on macOS. All claims are from sources fetched 2026-09-21. Confidence: high = read verbatim on a primary page; medium = read on a primary page via summarised fetch, detail could be lossy; low = search-snippet only, page not opened. Class: evidence (E), lead (L), unverified belief (U).

## Claims

- WhisperKit issue #525 (opened 2026-08-17, open, no maintainer reply) documents windows returning empty text with `avgLogprob == 0.0`, `temperature == 0.0`, affecting "a significant portion" of VAD-detected segments on an ~87-min meeting; root cause named as `TextDecoder.decodeText` checking `sampleResult.completed` at forced-prefix positions, so an EOT predicted right after the forced timestamp token exits the window before any content token is sampled | https://github.com/argmaxinc/WhisperKit/issues/525 | GitHub / argmaxinc | 2026-08-17 | accessed 2026-09-21 | high | E
- #525 links prior issue #372 and PR #497 and says the bug fires "even without `promptTokens`"; workaround reported: re-decode at temperature 0.4–0.8, unreliable | https://github.com/argmaxinc/WhisperKit/issues/525 | GitHub / argmaxinc | 2026-08-17 | accessed 2026-09-21 | high | E
- Issue #372 (2025-10-22) reported `promptTokens` producing empty transcription; PR #438 "skip firstTokenLogProbThreshold when promptTokens are set" is the fix referenced for that case | https://github.com/argmaxinc/WhisperKit/issues/372 | GitHub / argmaxinc | 2025-10-22 | accessed 2026-09-21 | low (search snippet; page not opened) | L
- WhisperKit issue #530 (2026-09-10, open, no maintainer reply) is about `EarlyStopActor` bookkeeping leaking UUID entries after thrown errors/cancellation; reporter explicitly says it is NOT a cross-window stopping failure and not a memory problem with audio/models | https://github.com/argmaxinc/WhisperKit/issues/530 | GitHub / argmaxinc | 2026-09-10 | accessed 2026-09-21 | high | E
- WhisperKit issue #500 (2026-07-07, open, no maintainer reply, no linked PR): AudioProcessor resample corrupts long compressed audio (87-min 44.1 kHz stereo VBR MP3); reporter states 16 kHz mono WAV of any length processes correctly; suspected causes are `AVAudioFile.length` estimates on VBR containers and per-chunk `AVAudioConverter` rebuilds losing filter state | https://github.com/argmaxinc/WhisperKit/issues/500 | GitHub / argmaxinc | 2026-07-07 | accessed 2026-09-21 | high | E
- #500 does not test 48 kHz PCM WAV; the second suspected cause (per-chunk converter rebuild) would apply to any input needing resampling, so 48 kHz WAV is not cleared by this issue | inference from #500 | — | — | accessed 2026-09-21 | medium | U
- Releases page: latest v1.1.0 (06 Aug 2026), v1.0.0 (01 May 2026); v1.1.0 adds an "incremental" audio loading mode that streams from disk in bounded-memory chunks, >70% peak-memory reduction on multi-hour audio; v1.0.0 renames package to argmax-oss-swift, full Swift 6 concurrency, removes deprecated APIs, vendors Hub/Tokenizers into ArgmaxCore | https://github.com/argmaxinc/WhisperKit/releases | GitHub / argmaxinc | 2026-08-06 | accessed 2026-09-21 | high | E
- Neither v1.0.0 nor v1.1.0 notes mention DecodingOptions defaults, `firstTokenLogProbThreshold`, temperature fallback, compression ratio, VAD chunking or chunkingStrategy changes | https://github.com/argmaxinc/WhisperKit/releases | GitHub / argmaxinc | 2026-08-06 | accessed 2026-09-21 | medium (summarised fetch) | E
- FluidAudio README: Parakeet TDT 0.6b v3 (25 European languages) and v2 (English-only, "highest recall") as Core ML; package Apache-2.0; models described as "permissive licenses"; batch file transcription; ~190x realtime on M4 Pro; requires Swift 6.0+, no explicit macOS minimum stated on README | https://github.com/FluidInference/FluidAudio | GitHub / FluidInference | n/d | accessed 2026-09-21 | medium | E
- FluidAudio ASR GettingStarted: result exposes `text` and `confidence`; no chunk length/overlap/merge documented; no timestamps documented; no macOS minimum stated; warns hand-decoded PCM buffers show up as empty transcripts, use `AudioConverter` | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md | GitHub / FluidInference | n/d | accessed 2026-09-21 | medium | E
- FluidAudio #909 (2026-09-11, closed via PR #910): Parakeet v3 Core ML returns whole-window blank (no tokens) on specific 11–13 s spans, batch-reproducible, 4–19 words lost per affected window; reproduces on fp16 MLX port, so model behaviour not quantisation; fix is pipeline-level retry with length perturbation when a speech-energy window returns empty | https://github.com/FluidInference/FluidAudio/issues/909 | GitHub / FluidInference | 2026-09-11 | accessed 2026-09-21 | high | E
- FluidAudio #927 (2026-09-17, open, no reply) is about provenance/licensing of DIARIZATION Core ML artefacts (segmentation, FBank, embedding, PLDA), not Parakeet; asks whether the repo's CC-BY-4.0 covers converted artefacts; motivated by commercial redistribution due diligence | https://github.com/FluidInference/FluidAudio/issues/927 | GitHub / FluidInference | 2026-09-17 | accessed 2026-09-21 | high | E
- FluidAudio seam-artifact history (search snippets only): #708 removed chunk-merge seam artifacts in offline transcription; #759 word-boundary-safe fallbacks for 3 residual seam-merge drop paths; #897/#903 streaming seam duplication/mid-word joins; a CrispASR issue #350 reports a v0.8.24 unified-dispatch regression to 66% coverage on parakeet-tdt-0.6b-v3 | https://github.com/FluidInference/FluidAudio/issues/897 ; https://github.com/CrispStrobe/CrispASR/issues/350 | GitHub | 2026 | accessed 2026-09-21 | low (not opened) | L
- nvidia/parakeet-tdt-0.6b-v3 card: "Use of this model is governed by the CC-BY-4.0 license."; 25 languages; up to 24 min full attention (A100 80GB) or up to 3 h with local attention; word/segment/char timestamps; released 2025-08-14 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 | Hugging Face / NVIDIA | 2025-08-14 | accessed 2026-09-21 | high | E
- nvidia/parakeet-tdt-0.6b-v2 card: "GOVERNING TERMS: Use of this model is governed by the CC-BY-4.0 license."; up to 24 min per pass; word/char/segment timestamps; released 2025-05-01 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 | Hugging Face / NVIDIA | 2025-05-01 | accessed 2026-09-21 | high | E
- whisper.cpp releases: v1.9.0 "parakeet : add support for NVIDIA Parakeet" (#3735) and ruby bindings (#3885); v1.9.2 verifies parakeet hparams (#3950); v1.9.4 (latest, 11 Sep) "parakeet : fix TDT decode by outputting raw logits from the joint graph" (#4017). The TDT-decode fix implies the joint/decoder runs in whisper.cpp, i.e. end-to-end, but no note says so explicitly | https://github.com/ggml-org/whisper.cpp/releases | GitHub / ggml-org | 2026-09-11 (year as inferred from v1.9.x numbering; page shows day-month only) | accessed 2026-09-21 | medium | E
- apple/coreai-models: BSD-3-Clause repo of export recipes + Swift runtime for "Core AI"; requires macOS/iOS 27.0+ and Xcode 27.0+; no Parakeet or ASR model listed on the README; model list only via `uv run coreai.model.registry --list-models`; model artefact license not stated | https://github.com/apple/coreai-models | GitHub / Apple | 2026 | accessed 2026-09-21 | medium | E
- Argmax pricing: Basic free (MIT: WhisperKit, SpeakerKit, TTSKit); Pro $1.33/device/month monthly or $1.00 yearly, 1,000 monthly licences minimum, 14-day trial ($14, 30 devices), licence renews online every 30 days; Enterprise custom. ParakeetKit is not named on the pricing page | https://www.argmaxinc.com/pricing | Argmax | n/d | accessed 2026-09-21 | high | E
- huggingface.co/argmaxinc/parakeetkit-pro: gated; license tag "argmax-fmod-license"; "only compatible with Argmax Pro SDK"; sign up via app.argmaxinc.com; no platform minimums or v2/v3 breakdown visible; ~164,520 downloads last month | https://huggingface.co/argmaxinc/parakeetkit-pro | Hugging Face / Argmax | n/d | accessed 2026-09-21 | medium | E

## WhisperKit decoding findings

1. The empty-window early stop IS documented: issue #525 (2026-08-17). Symptom matches exactly: VAD windows come back with empty text, `avgLogprob == 0.0`, `temperature == 0.0`, no error, on an ~87-minute meeting. Root cause per the reporter: `decodeText` evaluates `sampleResult.completed` unconditionally, including at the forced timestamp position that still goes through the main loop when there are no `promptTokens`; an EOT prediction there ends the window with zero content tokens. Open, no maintainer reply, no PR as of today. Related lineage: #372 (empty result with promptTokens, Oct 2025) -> PR #438 (skip `firstTokenLogProbThreshold` when promptTokens set) -> PR #497 (referenced by #525; not opened this run).
2. Implication for decoding settings: `avgLogprob == 0.0` with `temperature == 0.0` means the temperature-fallback path never triggers (nothing to fail the logprob/compression thresholds when no tokens were sampled), so `temperatureFallbackCount = 0` vs default is irrelevant to this failure and raising `firstTokenLogProbThreshold` cannot help. Fixing it needs a guard on the completion check at forced-prefix positions (a source patch/fork), not a `DecodingOptions` change. This is my inference from #525's mechanism; the issue itself does not discuss fallback settings.
3. #530 (2026-09-10) is unrelated to lost segments: it is retained `EarlyStopActor` bookkeeping after errors/cancellation; reporter states it does not cause cross-window stops.
4. #500 (2026-07-07, open): resample corruption reported only for long compressed VBR audio; reporter states 16 kHz mono WAV of any length is fine. 48 kHz PCM WAV was not tested; one of the two suspected causes (per-chunk `AVAudioConverter` rebuild) would apply to any resampled input, so feed 16 kHz mono WAV to stay in the tested-good path. No fix landed; no maintainer response.
5. v1.1.0 (2026-08-06) and v1.0.0 (2026-05-01) release notes say nothing about decoding defaults, `firstTokenLogProbThreshold`, temperature fallback, or VAD chunking. v1.1.0's change is an incremental (bounded-memory) audio loader; v1.0.0 is the argmax-oss-swift rename + Swift 6 + deprecated-API removal.
6. Not found this run: any issue/PR text about `temperatureFallbackCount = 0` specifically; GitHub search API returned 422 for the combined query.

## Parakeet routes table

| route | long-file handling | timestamps | license | macOS min | status | source |
|---|---|---|---|---|---|---|
| FluidInference/FluidAudio (Core ML, Parakeet v2/v3) | Batch API for whole files; internal chunk length/overlap not documented in ASR docs; seam-merge fixes #708/#759 (snippets) and blank-window retry PR #910 (closed #909, 2026-09-11) show chunking exists and has had drop/dup bugs | `text`, `confidence` only in docs; no word/segment timestamps documented | Package Apache-2.0; Core ML models "permissive"; upstream NVIDIA weights CC-BY-4.0; #927 questions provenance of diarization (not ASR) artefacts | Not stated in README or GettingStarted (Swift 6.0+) | Active, Sept 2026 issues being closed | github.com/FluidInference/FluidAudio ; …/Documentation/ASR/GettingStarted.md ; issues #909, #927 |
| whisper.cpp (ggml) via C bridging | Not examined in notes; whisper.cpp's own segment loop applies | Not examined | MIT (whisper.cpp; not re-verified this run); weights CC-BY-4.0 | Not stated | Parakeet support since v1.9.0; TDT decode fix in v1.9.4 (11 Sep) implies encoder+joint+TDT run; not explicitly stated as end-to-end | github.com/ggml-org/whisper.cpp/releases |
| apple/coreai-models | n/a | n/a | BSD-3-Clause repo; model terms unstated | macOS 27.0+, Xcode 27.0+ | No Parakeet/ASR model visible on README; registry list not run | github.com/apple/coreai-models |
| Argmax ParakeetKit Pro | Not visible (gated) | Not visible (gated) | "argmax-fmod-license" (HF tag); Pro SDK $1.00–1.33/device/month, 1,000-licence minimum; ParakeetKit not named on pricing page | Not stated | Gated, Pro-only, ~164k downloads/month | huggingface.co/argmaxinc/parakeetkit-pro ; argmaxinc.com/pricing |
| NVIDIA weights (reference) | v3: 24 min full attention, 3 h local attention; v2: 24 min per pass | word/segment/char | CC-BY-4.0 (both cards, verbatim) | n/a | v2 2025-05-01, v3 2025-08-14 | huggingface.co/nvidia/parakeet-tdt-0.6b-v2, -v3 |

## Leads

- WhisperKit PR #497 and PR #438: read to see whether the forced-prefix completion guard already exists for the promptTokens case and can be generalised as #525 proposes.
- FluidAudio PR #910 (fix for #909) and PRs #708/#759: read for actual chunk length, overlap, merge and retry logic; docs do not disclose them. FluidAudio Documentation/Models.md#asr-models may state macOS minimums and model licences.
- CrispStrobe/CrispASR #350: 94% -> 66% transcript coverage regression on parakeet-tdt-0.6b-v3 between v0.8.9 and v0.8.24 "unified dispatch" — a user-side long-form account worth reading for (c).
- hyperaudio/hyperaudio-lite-editor #671: Parakeet (local) dropping a sparse-speech stretch inside a long window — another long-form drop report.
- whisper.cpp PR #3735 and #4017: confirm end-to-end TDT decoding and whether timestamps are emitted for Parakeet.
- apple/coreai-models: run `uv run coreai.model.registry --list-models` to check for a Parakeet recipe.
- Argmax: whether ParakeetKit Pro is bundled in the Pro tier or priced separately (pricing page silent).

## Looked for and could not find

- Any WhisperKit issue/PR/release note naming `temperatureFallbackCount` = 0 (GitHub search API call returned 422; did not retry with a different endpoint).
- Maintainer responses or linked fixes on WhisperKit #500, #525, #530 — all three open with no reply as of 2026-09-21.
- FluidAudio's documented chunk length/overlap for batch mode and a stated macOS minimum (README and ASR/GettingStarted.md silent; earlier path Documentation/ASR.md is 404).
- Word/segment timestamps in FluidAudio's ASR result type (docs show only `text`, `confidence`).
- A Parakeet model in apple/coreai-models.
- ParakeetKit Pro price or platform minimums; "argmax-fmod-license" text.
- Any 6+-month production retrospective of Parakeet on long meeting audio from any route. Closest evidence is FluidAudio #909 (LibriSpeech-based, Sept 2026) and the unopened CrispASR #350 / hyperaudio #671 reports.
- An explicit whisper.cpp statement that Parakeet runs end-to-end.

## Sources read

1. https://github.com/argmaxinc/WhisperKit/issues/500
2. https://github.com/argmaxinc/WhisperKit/issues/525
3. https://github.com/argmaxinc/WhisperKit/issues/530
4. https://github.com/argmaxinc/WhisperKit/releases
5. https://github.com/FluidInference/FluidAudio
6. https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md
7. https://github.com/FluidInference/FluidAudio/issues/909
8. https://github.com/FluidInference/FluidAudio/issues/927
9. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
10. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
11. https://github.com/ggml-org/whisper.cpp/releases
12. https://github.com/apple/coreai-models
13. https://www.argmaxinc.com/pricing
14. https://huggingface.co/argmaxinc/parakeetkit-pro

Failed fetches (not read): api.github.com search (422); FluidAudio Documentation/ASR.md (404). Two web searches supplied snippet-only leads (#372/#438, FluidAudio #708/#759/#897/#903, CrispASR #350, hyperaudio #671).
