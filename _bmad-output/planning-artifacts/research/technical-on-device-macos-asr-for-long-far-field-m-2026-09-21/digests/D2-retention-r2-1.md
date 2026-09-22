# D2 retention round 2 digest

Scope: AMI WER for candidate on-device ASR models under one normalizer, plus the state of long-form evaluation. All numbers below were retrieved this run (2026-09-21). Nothing is averaged across sources. Where a number came from a PDF parsed locally, the PDF was fetched this run from the URL given.

Headline finding: the Open ASR Leaderboard's AMI column is not a far-field, long-form workload. It is AMI-IHM (individual headset microphones), Kaldi-segmented into utterances shorter than 30 s, scored with a Whisper-style English normalizer that strips fillers. The leaderboard's separate Long-form track does not include AMI at all (it uses CORAAL, Earnings21, Earnings22, TED-LIUM v3). So the AMI column measures close-talk, pre-segmented meeting speech; it says nothing about SDM distant-mic capture or about whole-recording omission behaviour.

## Claims

- The Open ASR Leaderboard evaluates AMI as part of the short-form English "Leaderboard" task, defined as audio under 30 s ("the receptive field of Whisper"); the Long-form task is a separate track for audio longer than 30 s | https://arxiv.org/pdf/2510.06961v4 | arXiv (HF/NVIDIA/etc. authors) | v4, snapshot stated as 27 March 2026 | accessed 2026-09-21 | high | primary
- Leaderboard normalizer: removes punctuation and casing, then "an English text normalization pipeline closely following that of Whisper" incl. number normalization, spelling standardization, removal of filler words | https://arxiv.org/pdf/2510.06961v4 | arXiv | 2026-03 snapshot | accessed 2026-09-21 | high | primary
- Leaderboard AMI test split is 9 h, "Punctuated, cased, disfluencies" transcript style, CC-BY-4.0 | https://arxiv.org/pdf/2510.06961v4 (Table 1) | arXiv | 2026-03 | accessed 2026-09-21 | high | primary
- Long-form datasets per Table 1: CORAAL (159 h, sociolinguistic interviews), Earnings21 (39 h); AMI is tagged "Leaderboard" (short-form) only | https://arxiv.org/pdf/2510.06961v4 | arXiv | 2026-03 | accessed 2026-09-21 | high | primary
- Long-form track (Table 5, avg WER over long-form datasets, open models): Cohere Labs Transcribe 9.73 (RTFx 418); Parakeet TDT 0.6B v3 10.7 (1000); Whisper Large v3 Turbo 11.0 (148); Canary Qwen 2.5B 11.2 (16.1); Whisper Large v3 11.2 (68.6); Distil-Whisper Large v3.5 11.7 (156); Parakeet CTC 1.1B 12.9 (2790); Parakeet CTC 0.6B 13.7 (4383). Closed: ElevenLabs Scribe v2 7.32, AssemblyAI Universal 3 Pro 8.34, Speechmatics Enhanced 8.80, RevAI Fusion 9.54, Google Chirp 13.0 | https://arxiv.org/pdf/2510.06961v4 | arXiv | 2026-03 snapshot | accessed 2026-09-21 | high | primary
- Short-form English avg WER (Table 3, 27 March 2026 snapshot): Cohere Labs Transcribe 5.42; IBM Granite Speech 4.0 1B 5.52; Canary Qwen 2.5B 5.63; Granite Speech 3.3 8B 5.76; Qwen3 ASR 1.7B 5.76; Granite Speech 3.3 2B 6.00; Phi 4 Multimodal Instruct 6.02; Parakeet TDT 0.6B v2 6.05; Parakeet TDT 0.6B v3 6.32; Canary 1B 6.50; Voxtral Small 24B 6.62; CrisperWhisper 6.67; Canary 1B v2 7.15; Distil-Whisper Large v3.5 7.21; Parakeet CTC 1.1B 7.40; Whisper Large v3 7.44; Whisper Large v3 Turbo 7.83 | https://arxiv.org/pdf/2510.06961v4 | arXiv | 2026-03 | accessed 2026-09-21 | high | primary
- The paper attributes the short-form/long-form gap to "model context size, audio chunking strategies, and the handling of disfluencies", and gives no deletion/insertion/substitution breakdown | https://arxiv.org/pdf/2510.06961v4 | arXiv | 2026-03 | accessed 2026-09-21 | high | primary
- ESB (the leaderboard's dataset lineage) uses the AMI-IHM (individual headset microphones) version, segmented per the Kaldi AMI s5b recipe, splitting samples longer than 30 words at punctuation timestamps; junk token <unk> removed, orthography otherwise retained; AMI test 9 h, 12,643 utterances | https://arxiv.org/pdf/2210.13352 | arXiv (Hugging Face) | 2022-10 | accessed 2026-09-21 | high | primary
- ESB test-only-sorted dataset card: AMI test = 9 h, "Punctuated & Cased"; configs ami and ami_cleaned exist; card does not state IHM/SDM (inherited from ESB paper above) | https://huggingface.co/datasets/hf-audio/esb-datasets-test-only-sorted | Hugging Face | undated | accessed 2026-09-21 | medium | primary
- Per-dataset AMI WER computed "with the official repository and reported on the Hugging Face Open ASR Leaderboard" (Table 5 of the Canary-1B-v2/Parakeet-v3 paper): Whisper-large-v3 15.95; Voxtral-Mini-3B-2507 16.31; Phi-4-multimodal-instruct 11.45; Parakeet-TDT-0.6B-v3 11.39; Canary-1B-v2 16.01 | https://arxiv.org/pdf/2509.14128 | arXiv (NVIDIA) | v2 2025-09-26 | accessed 2026-09-21 | high | primary
- Same paper: NVIDIA long-form inference uses dynamic parallel chunking of 30-40 s overlapping chunks merged afterwards; on Earnings22 WER 13.93 (parallel) vs 15.61 (sequential 30 s chunks), on TAL(10h) 10.12 vs 16.62 | https://arxiv.org/pdf/2509.14128 | arXiv (NVIDIA) | 2025-09 | accessed 2026-09-21 | high | primary
- CrisperWhisper: Whisper's BPE tokenizer prefixes tokens with spaces so "only 13% of spaces in the original transcripts are mapped to the explicit space token", which prevents DTW from localizing pauses; non-distinct cross-attention makes DTW overestimate pause durations; fix splits pause duration between neighbouring words capped at 160 ms | https://arxiv.org/html/2408.16589 | arXiv (Nyra Health) | 2024-08 | accessed 2026-09-21 | medium (fetch summary, not verbatim) | primary
- CrisperWhisper AMI numbers (own verbatim evaluation, NOT the leaderboard normalizer): Whisper large-v2 WER 16.82 / IER 11.77; CrisperWhisper WER 9.72 / IER 2.26. TED-LIUM: large-v2 4.01 / 3.08; CrisperWhisper 3.26 / 0.75 | https://arxiv.org/html/2408.16589 | arXiv | 2024-08 | accessed 2026-09-21 | medium | primary
- CrisperWhisper on AphasiaBank problem recordings: no harmful hallucinations but repetition loops on 10 recordings | https://arxiv.org/html/2408.16589 | arXiv | 2024-08 | accessed 2026-09-21 | medium | primary
- Whisper-CD (2026) names three long-form failure patterns for Whisper-class encoder-decoders: silence-region hallucination, repetition loops, content omission ("parts of the spoken content are dropped"); no omission rate is measured, no D/I/S breakdown, no non-Whisper comparators | https://arxiv.org/html/2603.06193 | arXiv | v2 2026-06-22 | accessed 2026-09-21 | medium | primary
- Whisper-CD Table 1 long-form WER, baseline vs +CD: Large-v3 baseline CORAAL 208.76 / VoxPopuli 44.95 / Earnings22 520.94 / TED-LIUM 66.42 / REV-16 173.69, +CD 45.77 / 19.86 / 57.08 / 25.62 / 21.38; Large-v3-Turbo baseline 38.75 / 30.63 / 33.25 / 12.93 / 19.82, +CD 14.43 / 25.71 / 16.16 / 10.11 / 14.81. Baseline decoding configuration not captured by the fetch; the >100% large-v3 figures imply a hallucination-heavy sequential baseline, so treat as an upper bound, not a leaderboard-comparable number | https://arxiv.org/html/2603.06193 | arXiv | 2026-06 | accessed 2026-09-21 | low-medium | primary
- Per-model leaderboard results live as `.eval_results/open_asr_leaderboard.yaml` in model repos linked from the leaderboard; the results dataset viewer showed AMI 4.76 for Edge0/ARK-ASR-3B and 4.87 for OpenMOSS MOSS-Transcribe-preview-2B at the top | https://huggingface.co/datasets/hf-audio/open-asr-leaderboard | Hugging Face | undated | accessed 2026-09-21 | low (small-model summary of a dynamic viewer) | primary
- HF blog announcing multilingual and long-form tracks is dated 2025-11-21; states closed-source systems "still edge out open ones" on long-form; gives no AMI numbers | https://huggingface.co/blog/open-asr-leaderboard | Hugging Face | 2025-11-21 | accessed 2026-09-21 | high | primary
- Leaderboard GitHub README: long-form benchmark "includes earnings21 and earnings22" plus separate CORAAL evaluation; no AMI methodology or normalizer text in README | https://github.com/huggingface/open_asr_leaderboard | GitHub | undated (474 commits) | accessed 2026-09-21 | medium | primary

## AMI table

All rows: AMI-IHM headset, Kaldi-segmented utterances <30 s, leaderboard English normalizer (fillers removed) unless marked otherwise.

| model + version | AMI WER | condition | leaderboard snapshot date | source |
|---|---|---|---|---|
| openai/whisper-large-v3 | 15.95 | IHM, short-form, leaderboard normalizer, run via official repo | paper v2 2025-09-26 | https://arxiv.org/pdf/2509.14128 Table 5 |
| nvidia/parakeet-tdt-0.6b-v3 | 11.39 | same | 2025-09-26 | https://arxiv.org/pdf/2509.14128 Table 5 |
| nvidia/canary-1b-v2 | 16.01 | same | 2025-09-26 | https://arxiv.org/pdf/2509.14128 Table 5 |
| mistralai/Voxtral-Mini-3B-2507 | 16.31 | same | 2025-09-26 | https://arxiv.org/pdf/2509.14128 Table 5 |
| microsoft/Phi-4-multimodal-instruct | 11.45 | same | 2025-09-26 | https://arxiv.org/pdf/2509.14128 Table 5 |
| Whisper large-v2 (CrisperWhisper eval) | 16.82 (IER 11.77) | IHM segments, CrisperWhisper's own verbatim scoring; NOT leaderboard normalizer | paper 2024-08 | https://arxiv.org/html/2408.16589 |
| nyrahealth/CrisperWhisper | 9.72 (IER 2.26) | same as row above | 2024-08 | https://arxiv.org/html/2408.16589 |
| Edge0/ARK-ASR-3B | 4.76 | leaderboard viewer, low confidence | dynamic (accessed 2026-09-21) | https://huggingface.co/datasets/hf-audio/open-asr-leaderboard |
| OpenMOSS MOSS-Transcribe-preview-2B | 4.87 | leaderboard viewer, low confidence | dynamic (accessed 2026-09-21) | https://huggingface.co/datasets/hf-audio/open-asr-leaderboard |
| openai/whisper-large-v3-turbo | not retrieved (avg 7.83 short-form; 11.0 long-form) | – | 2026-03-27 | https://arxiv.org/pdf/2510.06961v4 |
| distil-whisper large-v3.5 | not retrieved (avg 7.21; long-form 11.7) | – | 2026-03-27 | same |
| nvidia/parakeet-tdt-0.6b-v2 | not retrieved (avg 6.05) | – | 2026-03-27 | same |
| nvidia/canary-qwen-2.5b | not retrieved (avg 5.63; long-form 11.2) | – | 2026-03-27 | same |
| nvidia/canary-1b-flash | not retrieved (paper lists "Canary 1B" 6.50 avg; flash not shown) | – | 2026-03-27 | same |
| Qwen3 ASR 1.7B | not retrieved (avg 5.76) | – | 2026-03-27 | same |
| Cohere Labs Transcribe | not retrieved (avg 5.42; long-form 9.73) | – | 2026-03-27 | same |
| IBM Granite Speech 4.0 1B / 3.3 8B / 3.3 2B | not retrieved (avg 5.52 / 5.76 / 6.00) | – | 2026-03-27 | same |
| Kyutai STT | not retrieved (listed as a contributor org only) | – | 2026-03-27 | same |

## Leads

1. Full AMI column: each model's `.eval_results/open_asr_leaderboard.yaml` (per the results dataset card) or the leaderboard Space's Files tab (https://huggingface.co/spaces/hf-audio/open_asr_leaderboard/tree/main) — the Space itself renders client-side and returned only a shell. Fetch the raw YAML for whisper-large-v3-turbo, canary-qwen-2.5b, parakeet-tdt-0.6b-v2, qwen3-asr, cohere transcribe, granite.
2. Long-form per-dataset numbers: paper Table 5 is averages only; the Space long-form tab or `hf-audio/open-asr-leaderboard-longform` dataset (referenced at line 149 of the paper text) should hold per-dataset (CORAAL/Earnings21/Earnings22/TED-LIUM) values.
3. AMI SDM is absent from every leaderboard artifact read; a far-field number would have to come from CHiME/AMI-SDM papers, not the leaderboard.
4. Whisper-CD baseline configuration (sequential vs HF chunked, temperature fallback) needs the paper's Section 4 text before its WERs are quoted against anyone.
5. "Do LLM Decoders Listen Fairly?" (https://arxiv.org/html/2604.21276v1) covers Qwen3-ASR and Canary-Qwen-2.5B vs Whisper and may carry error-type breakdowns; not read this run.
6. "From Text Metrics to Model Internals: Whisper hallucination detection" (https://arxiv.org/abs/2606.23060) — Whisper large-v3 hallucination on real human-annotated speech; not read this run.

## Looked for and could not find

- A per-model AMI column for whisper-large-v3-turbo, distil-whisper, parakeet-tdt-0.6b-v2, canary-qwen-2.5b, canary-1b-flash, Qwen3-ASR, Cohere Transcribe, Granite Speech, Kyutai STT under the leaderboard normalizer: the paper (v4) prints only averages, the Space is a JS shell, the GitHub README has no tables.
- Any leaderboard artifact stating AMI SDM; every source that names a condition says IHM.
- Any deletion/insertion/substitution breakdown on AMI or long-form data from the leaderboard repo or paper.
- A 2026 paper measuring "dropped stretches" / content-omission rate for Whisper vs TDT/CTC/LLM-decoder ASR. Whisper-CD names the failure mode but does not quantify it and has no non-Whisper baseline.
- A Voxtral Realtime, Kyutai STT, or Cohere Transcribe AMI number anywhere.

## Sources read

1. https://arxiv.org/html/2408.16589 — CrisperWhisper (fetched, summarized)
2. https://huggingface.co/spaces/hf-audio/open_asr_leaderboard — Space (shell only, no data)
3. https://arxiv.org/html/2510.06961v4 and https://arxiv.org/pdf/2510.06961v4 — Open ASR Leaderboard paper (PDF parsed locally with pdftotext)
4. https://huggingface.co/blog/open-asr-leaderboard — HF blog 2025-11-21
5. https://huggingface.co/datasets/hf-audio/open-asr-leaderboard — results/datasets repo card
6. https://github.com/huggingface/open_asr_leaderboard — README
7. https://huggingface.co/datasets/hf-audio/esb-datasets-test-only-sorted — dataset card
8. https://arxiv.org/pdf/2509.14128 — Canary-1B-v2 & Parakeet-TDT-0.6B-v3 paper (PDF parsed locally)
9. https://arxiv.org/pdf/2210.13352 — ESB benchmark paper (PDF parsed locally)
10. https://arxiv.org/html/2603.06193 — Whisper-CD (fetched, summarized)
