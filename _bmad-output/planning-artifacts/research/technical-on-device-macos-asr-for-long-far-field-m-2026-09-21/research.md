---
title: 'technical research: on-device macOS ASR for long far-field meeting audio'
type: 'technical'
topic: 'on-device macOS ASR for long far-field meeting audio'
decision: 'Which transcription lever Epic 4 exits on: fix WhisperKit decoding, swap the ASR model, or move the recall floor'
source: 'native run (two rounds, seven assistants) plus project measurements over the five AMI meetings'
shape: 'select'
status: complete
preset: 'standard'
validation: 'normal'
created: '2026-09-21'
updated: '2026-09-21'
claims_verified: 21
claims_unverified: 20
---

# technical research: on-device macOS ASR for long far-field meeting audio

**Decision this research serves:** which transcription lever Epic 4 exits on. The three options on the table were: fix the WhisperKit decoding settings, swap to another on-device ASR model, or move Story 4.10's 80% recall floor to what the pipeline achieves.

## Executive summary

**Fix the decoding setting. Do not swap the model. Do not move the floor yet.**

The lost text is not model accuracy. It is a decoding gate. WhisperKit ends a 30-second window with no text when the first sampled token's log-probability is under -1.5, and it relies on a temperature fallback to decode that window again [1][2]. The app turns the fallback off for determinism and inherits the gate, so the seeker advances past the empty window and its speech vanishes without an error [3]. Across the five AMI meetings this drops 14% of the reference content words as whole blocks of 25 to 190 words with zero output, on top of the ordinary word errors (Appendix A).

The fix is one decoding option: leave the first-token gate unset. Run through WhisperKit's own CLI with the app's flags, that gate reproduces the app's cached transcript word for word. Without the gate the same model keeps 90% of the reference content words instead of 78%, drops no block, keeps 18 of 19 expected-item quotes instead of 16, stays deterministic, and runs at the same speed (Appendix A). VAD chunking makes retention worse, and re-enabling the fallback recovers less than unsetting the gate.

Three findings drive the verdict:

1. **The mechanism is in the source and reproduces exactly.** WhisperKit issue #525 describes the same symptom on an 87-minute meeting [4].
2. **No candidate has published evidence on this workload.** The leaderboard's AMI column is headset audio cut under 30 seconds [17][18]; Apple's long-form claim has no independent meeting measurement [19][21]; Parakeet-TDT leads Whisper on headset AMI, WER 11.39 against 15.95 [16], and its Swift runtime dropped whole windows until 2026-09-11 [11].
3. **A swap is not cheap and not free of the same failure class.** Parakeet in Argmax's SDK is a paid Pro tier [7][8]; the open route is 0.x and documents no timestamps [9][10]; Apple's route has no confidence scores [19][20].

**The biggest caveat.** Fuller transcripts did not raise item recall. The full pipeline with the fix scored 14 of 19 (74%) on diarized text, the same 74% Story 4.13 measured without it, and on un-diarized text the fuller transcripts scored lower (Cross-dimension insight 1). The transcription fix is necessary. It is not sufficient for the 80% gate, and the residual is now the summarizer's, not the transcriber's.

## Requirements frame

Set from the project, not the web. Hard gates: fully on-device inference; English; callable from a Swift package target without a Python sidecar on the default path; segment timestamps for the diarization join; 20- to 40-minute files. Weighted preferences, in order: content retention on far-field multi-speaker audio, word error rate, realtime factor, memory, ecosystem health, integration cost, license.

The public-corpus constraint holds: AMI is the gate. It is far-field four-speaker audio and harder than the target workload of a laptop call on a headset. A candidate that only wins on clean close-talk audio has not answered the question.

## D1. Landscape and candidate screen

The field on Apple silicon in September 2026 has five credible finalists and a long tail of Python-only runtimes.

| # | Candidate | Runtime | Swift path | Timestamps | License (code / weights) | Status |
|---|---|---|---|---|---|---|
| 1 | Whisper large-v3-turbo via WhisperKit v1.1.0 | Core ML, Neural Engine | Yes, pinned today | segment and word | MIT / MIT | incumbent [6] |
| 2 | Parakeet-TDT 0.6B v2 or v3 via FluidAudio v0.16.1 | Core ML, Neural Engine | Yes, SPM | none documented on the ASR result [10] | Apache-2.0 / CC-BY-4.0 [9][14][15] | 0.x, active [9] |
| 3 | Apple SpeechAnalyzer and SpeechTranscriber | Apple Speech framework, macOS 26 | Native | per attributed-string run, granularity unstated [19] | Apple SDK / system asset | shipping [19][20] |
| 4 | Qwen3-ASR 0.6B or 1.7B via speech-swift | MLX and Core ML hybrid | Yes, SPM, macOS 15+ | word, via a forced aligner | Apache-2.0 / Apache-2.0 | community, no tag captured [31] |
| 5 | Voxtral Mini via MLX | MLX | partial, via speech-swift | not stated on card [32] | Apache-2.0 / Apache-2.0 | 3 to 5 GB footprint [32] |

Parakeet v2 is the English-only variant NVIDIA describes as the higher-recall one, under the same CC-BY-4.0 terms as v3 [15]. Qwen3-ASR reaches Swift through the community speech-swift package, which also lists Whisper turbo, Parakeet and Voxtral Mini behind one API [31]. Voxtral Mini's own card claims the best long-form English number in the field on TED-LIUM but states no timestamp support [32].

Cut: Canary-Qwen-2.5B and Canary-1B-flash have no Apple silicon runtime on their cards and no timestamp support stated [34]. Granite Speech, Moonshine, distil-whisper and CrisperWhisper are Python-only in the runtimes found [35]. Kyutai STT is streaming-first with a 2.5-second delay and no published WER [33]. Cohere Transcribe 2B appears only through an aggregator and a community listing; it stays provisional.

Three landscape facts changed since the PRD named Parakeet. Argmax renamed WhisperKit to argmax-oss-swift at v1.0.0 in May 2026 and shipped v1.1.0 in August 2026 [6]. Argmax ships Parakeet only as ParakeetKit Pro under its own license, usable only with the paid Pro SDK [8], priced per device per month with a 1,000-license minimum [7]. Apple's own coreai-models repository lists no ASR model and requires macOS 27 [30].

## D2. Content retention on long far-field audio

This is the dimension the decision rests on, and the web has almost nothing on it. No source found reports a deletion rate, an omission rate, or an AMI distant-microphone number for any model [16][17][36][37]. The project measurement in Appendix A is the only direct evidence.

**What the decoders do.** OpenAI's reference decoder skips a 30-second window when the no-speech probability is over 0.6 and the mean log-probability is at or under -1.0 [38]. WhisperKit carries the same rule [3] and adds a gate OpenAI does not have: a first-token log-probability threshold of -1.5, on by default [2]. When the first sampled token falls under it, the decoder ends the window at once with no content tokens [1]. The result requests a temperature fallback [2]. The app sets the fallback count to zero, so the loop runs once, the empty result reaches the seeker, and the seek advances a full window. Neither the v1.0.0 nor the v1.1.0 release notes mention decoding defaults [6].

**Measured on the five AMI meetings** (Appendix A, config F reproduces the app; config A unsets the gate):

| transcript source | reference content words kept | words in dropped blocks of 25+ | expected-item quotes present |
|---|---:|---:|---:|
| app today (gate on, fallback off) | 78% | 14.1% | 16 / 19 |
| gate off, fallback off (config A) | 90% | 0.0% | 18 / 19 |
| gate on, fallback 5 (config G) | 85% | 5.8% | 18 / 19 |
| gate on, fallback 5, VAD chunking (config H, ES2004a only) | 78% | 12.7% | 1 / 3 |

Config G still drops blocks because five fallbacks at rising temperature do not always clear the gate, and on ES2004a it triggered 40 fallbacks in 49 windows. Config A is deterministic and drops nothing. The residual 10% is scattered substitutions and short deletions, the ordinary far-field word error, not missing stretches.

**A second early-stop path exists.** WhisperKit issue #525, opened 2026-08-17 and unanswered, reports VAD windows returning empty text with a mean log-probability of exactly zero on an 87-minute meeting. The reporter traces it to the decoder honoring an end-of-transcript prediction at the forced timestamp position, before any content token is sampled [4]. That path does not depend on the threshold and is not closed by the option fix. Config A produced no hole of 15 seconds or more on ES2004a, so that path did not fire in this measurement, but it is the strongest reason to keep the retention metric in the regression suite.

**What the benchmarks say about the candidates.**

| model | AMI-IHM WER, one normalizer [16] | long-form track WER, no AMI [17] |
|---|---:|---:|
| Parakeet-TDT-0.6B-v3 | 11.39 | 10.7 |
| Phi-4-multimodal | 11.45 | not listed |
| Whisper large-v3 | 15.95 | 11.2 |
| Whisper large-v3-turbo | not retrieved | 11.0 |
| Canary-1B-v2 / Canary-Qwen | 16.01 | 11.2 |
| Voxtral-Mini-3B | 16.31 | not listed |

That AMI is the individual-headset mix, Kaldi-segmented under 30 seconds, with fillers stripped [17][18]; it measures close-talk short-form accuracy, not retention on a 40-minute room recording. NVIDIA's own long-form path chunks 30- to 40-second overlapping windows and merges them; sequential 30-second chunking costs it 1.7 to 6.5 WER points on long sets [16]. Parakeet-TDT holds 24 minutes in full attention on an A100 and needs local attention beyond that [14]. Whisper-CD names content omission as a Whisper long-form failure mode and does not quantify it [37]. CrisperWhisper's AMI gain comes with verbatim scoring that no other row shares [36].

**Apple.** Apple says SpeechAnalyzer is "good for long-form and distant audio, such as lectures, meetings, and conversations" and runs entirely on device [19]. Every independent accuracy comparison found uses LibriSpeech read speech or earnings calls, and compares against Whisper small, base, or tiny, never large-v3 or turbo [21][22][23]. On earnings calls it scored 14.0 WER against WhisperKit small.en at 12.8 [22]. No English meeting-audio measurement exists.

## D3. Performance on Apple silicon

No source found measures a single 20- to 40-minute file, and none gives peak memory with a stated method. What exists:

| candidate | machine | measure | source |
|---|---|---|---|
| WhisperKit large-v3-turbo, app path today (gate on) | Apple M5, 32 GB | 0.034 realtime factor on 17.5 min; skipped windows cost nothing | project, Appendix A |
| WhisperKit large-v3-turbo, gate off (config A) | Apple M5, 32 GB | 0.040 realtime factor on 17.5 min | project, Appendix A |
| WhisperKit large-v3-turbo, gate on, fallback 5 (config G) | Apple M5, 32 GB | 0.049 realtime factor | project, Appendix A |
| WhisperKit large-v3-turbo, gate on, fallback 5, VAD (config H) | Apple M5, 32 GB | 0.051 realtime factor | project, Appendix A |
| FluidAudio Parakeet v3 | M4 Pro 48 GB, macOS 26.0 | 155.6x realtime on LibriSpeech short files; encoder compile 3.4 s on iPhone 16 Pro Max | [13] |
| same harness, same clip, M4 24 GB | FluidAudio Parakeet v2 0.19 s, parakeet-mlx 0.50 s, mlx-whisper turbo 1.02 s, whisper.cpp turbo q5 1.23 s, WhisperKit large-v3 (not turbo) 2.22 s | undated, clip length unstated | [26] |
| MLX on M5 Max | Parakeet v3 "100x and up", large-v3-turbo "20 to 30x", clean English | ranges, unversioned | [27] |
| WhisperKit large-v3-turbo | M3 Max Neural Engine | encoder 218 ms per window, decoder 4.6 ms per token, 0.6 GB on disk compressed | [28], stale |
| SpeechAnalyzer | M2 Pro | about 3x faster than Whisper small, 12 to 40x realtime | [21] |

Parakeet is two to five times faster than turbo Whisper on the one same-machine harness [26]. None of that matters to the decision: the pipeline already transcribes at 4% of realtime, well under the 20% threshold in the regression suite, and the recall gate is not a speed problem.

## D4. Integration reality and ecosystem health

| runtime | release cadence | tracker | backing | long-file handling | pain points |
|---|---|---|---|---|---|
| WhisperKit / argmax-oss-swift | v0.14.0 2025-09-20 to v1.1.0 2026-08-06, one breaking release [6] | 97 open issues, recent ones unanswered [4][5] | Argmax, free MIT tier plus paid Pro [7] | takes a file, sequential windows, v1.1.0 adds bounded-memory loading [6] | #525 empty windows [4]; #500 corrupts long compressed audio, 16 kHz PCM WAV stated fine [5] |
| FluidAudio | five tags 2026-07-07 to 2026-09-21 [9] | 11 open, fast turnaround [11] | FluidInference, business model unstated [9] | batch API, chunking undocumented [10] | blank windows fixed 2026-09-11 [11]; breaking ModelHub rename [9]; provenance question on diarization artifacts [12] |
| Apple Speech framework | OS cadence | Feedback Assistant only | Apple | whole AVAudioFile, no caller chunking [19] | assets managed by the OS, a cap on reserved assets [19]; no custom vocabulary [22]; no confidence attribute found [20] |
| whisper.cpp | v1.9.4 2026-09-11 [29] | not measured | ggml.ai | own window loop | Parakeet support since v1.9.0, TDT decode fixed in v1.9.4, end-to-end not stated [29] |
| swift-parakeet-mlx | archived 2025-07-18 in favor of FluidAudio [39] | none | FluidInference | none | archived |

Apple's route has two further practical notes. Finalized results on short utterances take 1.4 to 2.2 seconds unless the analyzer is preheated [24], and the one open-source CLI built on it carries unresolved reports of hangs on real-world files and failed asset downloads [25].

The app feeds 16 kHz mono PCM WAV, which issue #500 states is the tested-good path [5]. The app's transcriber seam is a protocol with one method, so a second strategy is a new module and a router case, not a rewrite. The diarization join needs per-utterance timing, which the current strategy supplies and FluidAudio's documented ASR result does not [10].

## Cross-dimension insights

1. **The dropped text was masking the summarizer, not only starving it.** On un-diarized text the fuller transcripts scored lower with the shipped prompt, 10 of 19 in both runs against 13 of 19 on the app's cached transcripts (Appendix A). Story 4.13 inferred a two- to three-item transcription cost by comparing reference transcripts against WhisperKit text. Reference transcripts also carry four real speaker labels and verbatim disfluencies, so that comparison changed three variables, not one. The single-variable comparison here says completeness alone does not move the item count. That points back at the summarizer's flat output volume, which the 2026-09-20 sprint change proposal already named.
2. **Every candidate has a whole-window failure mode, and none publishes it.** The regression suite needs a retention metric, because word error rate against a verbatim reference hides it: the app's WER of 0.28 to 0.38 in history mixes fillers, substitutions and vanished windows into one number.

## Decision matrix

Weights sum to 10. Retention carries the most weight because it is the only criterion that separates the finalists: speed, memory and license all favor or tolerate every one of them, and only the project can measure retention. Scores are 0 to 3. Cells marked * decide between the top two and rest on project evidence, since no public source measures them.

| criterion | weight | WhisperKit turbo + option fix | Parakeet-TDT via FluidAudio | Apple SpeechAnalyzer |
|---|---:|---:|---:|---:|
| retention on far-field meetings | 4 | 3* measured, 0 dropped blocks | 1* unmeasured; blank-window bug fixed 2026-09-11 [11] | 0* unmeasured; vendor claim only [19] |
| accuracy on meeting speech | 2 | 1 (AMI-IHM WER 15.95 for large-v3 [16]) | 2 (AMI-IHM WER 11.39 [16]) | 1 (no large-model comparison [21][22]) |
| timestamps for the diarization join | 1 | 3 | 0 documented [10] | 1 per run, granularity unstated [19] |
| integration cost | 1 | 3, one option | 1, new module, 0.x API [9] | 1, new module, OS asset lifecycle [19] |
| ecosystem and five-year risk | 1 | 1, unanswered issues [4][5], Pro split [7] | 1, single company, 0.x [9] | 2, platform |
| license and cost | 1 | 3 | 2, CC-BY attribution [14] | 3 |
| **weighted total** | | **23** | **12** | **7** |

Re-weighting retention to 2 and accuracy to 4 still leaves the fix ahead, 21 to 16, because the accuracy gap is measured on headset audio and the retention gap is measured on this corpus.

## Verdict

**Pick: keep Whisper large-v3-turbo on WhisperKit and unset the first-token log-probability gate.** Confidence high, on project measurement (Appendix A).

**Runner-up: Parakeet-TDT 0.6B v2 via FluidAudio.** It wins if, after the fix lands and Story 4.10 Part B is rerun, item recall still sits under the gate and the residual is shown to be transcription, meaning expected-item quotes are absent from the transcript rather than present and unextracted. It also wins if battery or speed becomes a requirement. Before it can win it must expose utterance timing, which its documentation does not show today [10], and the project must measure its retention on the same five files. Confidence medium: its headset AMI lead is real [16]; its long-form behavior is not published.

**Not now: Apple SpeechAnalyzer.** Zero download cost and an explicit long-form positioning [19], but no independent meeting measurement, no confidence scores, and timestamp granularity unstated [19][20]. It is a one-day spike through the same bench, not a decision. Confidence low.

**Strongest argument against the pick.** Whisper-family decoders have structural omission paths that a decoding option does not close. Issue #525 documents one that fires regardless of the threshold [4]. Whisper-CD names omission as a class [37]. A TDT decoder does not seek by timestamp tokens and cannot fail this way, though its runtime found a different way to blank a window [11]. The answer is to measure retention in the suite, not to assume the fix is the last one.

**Cheapest reversibility hedge.** The transcriber seam already exists, and the recall bench accepts any directory of transcripts (Appendix A shows the method). A Parakeet spike is: transcribe the five cached AMI files with FluidAudio's CLI, convert to the transcript format, run the bench. That is a day and under a dollar, not weeks. Do it only if the full-pipeline rerun says transcription is still the residual.

## Recommendations

1. **Land the option fix as its own story** (feeds: epics.md Epic 4, architecture.md transcription decision). Pin the option in the decoding-options unit test so a dependency bump cannot restore it silently. Confidence high.
2. **Add a retention metric to the AMI regression suite**: reference content words that fall in a run of 25 or more with no hypothesis text, reported per meeting next to WER (feeds: Tests/regression/ami thresholds). This is what would have caught the gate, and it is the guard against the second early-stop path in issue #525. Confidence high.
3. **Rerun Story 4.10 Part B under the fix and the promoted prompt, and record it.** It ran here unrecorded: 14 of 19 (74%), false keeps 3, WER 0.20 to 0.25 against 0.28 to 0.38 in history. Confidence high.
4. **Retire the PRD's Parakeet line as "the designed response"** and replace it with a conditional spike as described in the verdict (feeds: prd.md open resolutions, epics.md Story 4.13 gate). Confidence high on the landscape facts [6][7][8][9][11].
5. **Do not move the 80% floor on this evidence.** The floor is reachable on clean text. Whether it is reachable on the pipeline's own text is now a summarizer question again, and the bench in Appendix A shows item recall does not track completeness. Confidence medium.

## Open questions

- Why does the summarizer emit zero items for ES2004a on every transcript source, including the human reference, when all three expected-item quotes are present in the fixed transcript? To answer: the next summarizer story, not a transcription one.
- Why does a fuller un-diarized transcript lower item recall? To answer: a per-meeting diff of kept items between the cached and fixed transcripts, which the bench output directories hold.

## Appendix A. Project measurements

All numbers here come from this machine on 2026-09-21: Apple M5, 32 GB, macOS 26.6.2, WhisperKit 1.1.0 at revision 1e2a163, model openai_whisper-large-v3-v20240930_turbo from the app's own model store, the five AMI Mix-Headset files the regression suite fetches. Nothing here is a web claim.

**Method.** WhisperKit's own CLI was built from the resolved 1.1.0 checkout and run over each file with the app's flags: English, temperature 0, prefill prompt, special tokens skipped, no chunking. Configs vary three options. Output text was aligned to each meeting's reference transcript with a longest-common-subsequence matcher over content words (fillers and immediate repeats removed from both sides). A dropped block is a run of 25 or more reference content words with at most a quarter as many hypothesis words against it. Quote presence is the best word-set overlap of an expected item's reference quote over a sliding window of the hypothesis, counted at 0.7 or better.

**Config F reproduces the app.** The app's cached transcript of ES2004a and config F (first-token gate at -1.5, fallback 0, no chunking) give identical counts: 1,662 content words, 440 in dropped blocks, the same three quote scores. The app's cached transcripts are byte-identical across three runs, so the match is not sampling noise.

**Per meeting, content words kept and dropped blocks:**

| meeting | reference | app today | config A: gate off, fallback 0 | config G: gate on, fallback 5 |
|---|---:|---:|---:|---:|
| ES2002a | 2,286 | 1,878 (82%), 322 dropped | 2,124 (93%), 0 dropped | 2,090 (91%), 94 dropped |
| ES2002b | 6,203 | 4,755 (77%), 850 dropped | 5,558 (90%), 0 dropped | 5,009 (81%), 588 dropped |
| ES2003a | 1,869 | 1,422 (76%), 327 dropped | 1,689 (90%), 0 dropped | 1,635 (87%), 89 dropped |
| ES2003b | 5,222 | 4,206 (81%), 588 dropped | 4,723 (90%), 0 dropped | 4,487 (86%), 275 dropped |
| ES2004a | 2,327 | 1,662 (71%), 440 dropped | 2,044 (88%), 0 dropped | 2,071 (89%), 0 dropped |
| **total** | **17,907** | **13,923 (78%), 2,527 dropped (14.1%)** | **16,138 (90%), 0 dropped** | **15,292 (85%), 1,046 dropped (5.8%)** |

Expected-item quotes present at 0.7 overlap or better: app today 16 of 19, config A 18 of 19, config G 18 of 19. The one quote config A still misses is ES2004a's first action item, at 0.50; the app today has it at 0.70 and misses a different one at 0.39.

**Other configs on ES2004a only:** gate off with fallback 5, and gate off with VAD chunking, both match config A within four words. Gate on with fallback 5 and VAD chunking (config H) keeps 1,817 words, drops 295, and triggers 40 fallbacks in 49 windows. VAD chunking is not the fix. Realtime factors for every config are in the D3 table.

**Offline recall bench, shipped prompt, same session, un-diarized text.** Each set was placed in a shadow repository root so the bench's manifest pointed at it; expected items and scorer unchanged.

| transcript set | item recall | action items | decisions | false keeps | cost |
|---|---:|---:|---:|---:|---:|
| app cached transcripts | 13 / 19 (68%) | 9 / 12 | 4 / 7 | 7 | $0.35 |
| config A, run 1 | 10 / 19 (53%) | 6 / 12 | 4 / 7 | 5 | $0.37 |
| config A, run 2 | 10 / 19 (53%) | 7 / 12 | 3 / 7 | 5 | $0.36 |
| config G | 9 / 19 (47%) | 5 / 12 | 4 / 7 | 10 | $0.34 |

Story 4.13 measured the same prompt at 14 of 19 on the same cached transcripts on 2026-09-20, so run-to-run variance on that set is about one item. The gap between the cached set and config A is three items on two runs and is not variance. All four sets label every utterance Speaker_1, which is not what the pipeline summarizes.

**Full pipeline with the fix** (transcribe, diarize, summarize, score, five meetings, not recorded to history):

| meeting | WER | realtime factor | speakers found | kept | recall | false keeps | cost |
|---|---:|---:|---|---:|---:|---:|---:|
| ES2002a | 0.249 | 0.123 (first load, includes model compile) | 4 of 4 | 3 | 3 / 3 | 0 | $0.058 |
| ES2002b | 0.224 | 0.054 | 4 of 4 | 7 | 6 / 8 | 1 | $0.126 |
| ES2003a | 0.211 | 0.039 | 4 of 4 | 1 | 1 / 1 | 0 | $0.039 |
| ES2003b | 0.197 | 0.050 | 4 of 4 | 6 | 4 / 4 | 2 | $0.117 |
| ES2004a | 0.229 | 0.049 | 5 of 4 | 0 | 0 / 3 | 0 | $0.043 |
| **total** | | | | **17** | **14 / 19 (74%)** (action items 9 of 12, decisions 5 of 7) | **3** | **$0.38** |

The transcript byte counts the stage recorded match config A's exactly on every meeting, and the CLI and app builds share the model, revision and options, so the two measurements describe the same transcripts. WER against the verbatim reference fell from 0.28 to 0.38 in `history.jsonl` to 0.20 to 0.25. Item recall is 74%, the figure Story 4.13 measured on the unfixed transcripts and expected from a rerun. ES2004a still yields zero items, as it does on the human reference transcript. The report file is kept beside this document under `imports/`.

## Source appendix

Of the 41 claims in this report's ledger, 21 were verified against an independent source or the project's own measurement and 20 stand on a single source, flagged in the confidence column. The version claims the pick rests on, WhisperKit v1.1.0 and FluidAudio v0.16.1, were re-verified with the GitHub CLI on the day of writing. Re-check the WhisperKit release page and issue #525 before acting on this report after October 2026; a selection report older than two quarters should be refreshed before anyone acts on it.

| n | supports | publisher | pub date | accessed | confidence |
|---|---|---|---|---|---|
| [1] | first-token gate ends the window with no text | [Argmax, TextDecoder.swift at v1.1.0](https://github.com/argmaxinc/WhisperKit/blob/v1.1.0/Sources/WhisperKit/Core/TextDecoder.swift) | 2026-08 | 2026-09-21 | high, read in the resolved checkout |
| [2] | decoding defaults, fallback request on gate failure | [Argmax, Configurations.swift and Models.swift at v1.1.0](https://github.com/argmaxinc/WhisperKit/blob/v1.1.0/Sources/WhisperKit/Core/Configurations.swift) | 2026-08 | 2026-09-21 | high |
| [3] | no-speech window skip, empty result seeks a full window | [Argmax, SegmentSeeker.swift at v1.1.0](https://github.com/argmaxinc/WhisperKit/blob/v1.1.0/Sources/WhisperKit/Core/Text/SegmentSeeker.swift) | 2026-08 | 2026-09-21 | high |
| [4] | issue #525, empty windows on an 87-minute meeting | [GitHub, argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit/issues/525) | 2026-08-17 | 2026-09-21 | high, open, unanswered |
| [5] | issue #500, long compressed audio corrupted, PCM WAV fine | [GitHub, argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit/issues/500) | 2026-07-07 | 2026-09-21 | high, open |
| [6] | release dates and notes, rename to argmax-oss-swift | [GitHub, argmaxinc/WhisperKit releases](https://github.com/argmaxinc/WhisperKit/releases) | 2026-08-06 | 2026-09-21 | high, dates verified with gh |
| [7] | Pro SDK pricing and minimum | [Argmax pricing](https://www.argmaxinc.com/pricing) | undated | 2026-09-21 | high |
| [8] | ParakeetKit Pro is Pro-only under argmax-fmod-license | [Hugging Face, argmaxinc/parakeetkit-pro](https://huggingface.co/argmaxinc/parakeetkit-pro) | undated | 2026-09-21 | medium, gated card |
| [9] | FluidAudio releases, license, models | [GitHub, FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) | 2026-09-21 | 2026-09-21 | high, tags verified with gh |
| [10] | ASR result exposes text and confidence only | [FluidAudio ASR GettingStarted](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md) | undated | 2026-09-21 | medium |
| [11] | issue #909, whole-window blanks, fixed by PR #910 | [GitHub, FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio/issues/909) | 2026-09-11 | 2026-09-21 | high |
| [12] | issue #927, provenance of diarization artifacts | [GitHub, FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio/issues/927) | 2026-09-17 | 2026-09-21 | high |
| [13] | FluidAudio throughput and compile times | [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) | undated, macOS 26.0 | 2026-09-21 | medium, vendor-run |
| [14] | Parakeet v3 license, 24-minute full-attention limit | [Hugging Face, nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | 2025-08-14 | 2026-09-21 | high |
| [15] | Parakeet v2 license and limits | [Hugging Face, nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) | 2025-05-01 | 2026-09-21 | high |
| [16] | per-model AMI under one normalizer; chunking cost | [arXiv 2509.14128, NVIDIA](https://arxiv.org/pdf/2509.14128) | 2025-09-26 | 2026-09-21 | high |
| [17] | leaderboard tracks, normalizer, long-form table | [arXiv 2510.06961v4, Open ASR Leaderboard](https://arxiv.org/pdf/2510.06961v4) | 2026-03-27 snapshot | 2026-09-21 | high |
| [18] | ESB uses AMI-IHM, Kaldi-segmented | [arXiv 2210.13352, Hugging Face](https://arxiv.org/pdf/2210.13352) | 2022-10 | 2026-09-21 | high |
| [19] | SpeechAnalyzer positioning, on-device, file API, timestamps | [Apple, WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/) | 2025-06 | 2026-09-21 | high, verbatim transcript |
| [20] | SpeechTranscriber abstract and API surface | [Apple, SpeechTranscriber documentation](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json) | current | 2026-09-21 | high |
| [21] | SpeechAnalyzer against Whisper small on LibriSpeech | [Lyonesse](https://lyonesse.app/blog/apple-speech-api-benchmark.html) | 2026-07-13 | 2026-09-21 | medium, vendor-adjacent |
| [22] | SpeechAnalyzer against WhisperKit small on earnings calls; no custom vocabulary | [Argmax blog](https://www.argmaxinc.com/blog/apple-and-argmax) | 2025-06-20 | 2026-09-21 | medium, competitor, stale |
| [23] | SpeechAnalyzer 40-clip LibriSpeech benchmark | [IraVoice on dev.to](https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4) | 2026-08-01 | 2026-09-21 | low, vendor, short clips |
| [24] | SpeechAnalyzer latency and preheat | [Apple Developer Forums thread 794720](https://developer.apple.com/forums/thread/794720) | 2025-07 to 2026-03 | 2026-09-21 | medium |
| [25] | yap CLI failure reports | [GitHub, finnvoor/yap issues](https://github.com/finnvoor/yap/issues) | 2025-06 to 2026-07 | 2026-09-21 | low, titles only |
| [26] | same-machine nine-way speed harness | [GitHub, anvanvan/mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest) | undated | 2026-09-21 | medium |
| [27] | M5 Max MLX throughput ranges | [Contra Collective](https://contracollective.com/blog/local-speech-to-text-whisper-parakeet-mlx-m5-max-2026) | 2026-07-19 | 2026-09-21 | low |
| [28] | WhisperKit per-window latency and disk size | [arXiv 2507.10860, Argmax](https://arxiv.org/html/2507.10860v1) | 2025-07 | 2026-09-21 | medium, stale |
| [29] | whisper.cpp Parakeet support and TDT fix | [GitHub, ggml-org/whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) | 2026-09-11 | 2026-09-21 | medium |
| [30] | apple/coreai-models scope and OS floor | [GitHub, apple/coreai-models](https://github.com/apple/coreai-models) | 2026 | 2026-09-21 | medium |
| [31] | speech-swift model coverage | [GitHub, soniqo/speech-swift](https://github.com/ivan-digital/qwen3-asr-swift) | 2026-09 | 2026-09-21 | medium |
| [32] | Voxtral Mini 4B Realtime card | [Hugging Face, mistralai](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) | 2026-02 | 2026-09-21 | high |
| [33] | Kyutai STT models and delay | [GitHub, kyutai-labs/delayed-streams-modeling](https://github.com/kyutai-labs/delayed-streams-modeling) | undated | 2026-09-21 | high |
| [34] | Canary-Qwen runtime and license | [Hugging Face, nvidia/canary-qwen-2.5b](https://huggingface.co/nvidia/canary-qwen-2.5b) | 2025-07-17 | 2026-09-21 | high |
| [35] | mlx-audio STT model list, Python | [GitHub, Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio) | 2026-09 | 2026-09-21 | high |
| [36] | CrisperWhisper AMI numbers, verbatim scoring | [arXiv 2408.16589, Nyra Health](https://arxiv.org/html/2408.16589) | 2024-08 | 2026-09-21 | medium |
| [37] | Whisper-CD names content omission | [arXiv 2603.06193](https://arxiv.org/html/2603.06193) | 2026-06-22 | 2026-09-21 | medium |
| [38] | OpenAI reference window-skip rule | [openai/whisper, transcribe.py](https://raw.githubusercontent.com/openai/whisper/main/whisper/transcribe.py) | unversioned | 2026-09-21 | high |
| [39] | swift-parakeet-mlx archived | [GitHub, FluidInference/swift-parakeet-mlx](https://github.com/FluidInference/swift-parakeet-mlx) | 2025-07-18 | 2026-09-21 | high |
