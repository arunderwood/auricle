# Eval fixture sources

Each directory here is one meeting: `transcript.json` (a `CanonicalTranscript`) and `expected.json` (the hand-curated action items and decisions, with their quote spans). Every fixture must be listed below.

## AMI Meeting Corpus

Fixtures: `ami-es2002a`, `ami-es2002b`, `ami-es2003a`, `ami-es2003b`.

Meetings ES2002a, ES2002b, ES2003a and ES2003b of the AMI Meeting Corpus, https://groups.inf.ed.ac.uk/ami/corpus/. Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/. Obtained through the QMSum dataset, https://github.com/Yale-LILY/QMSum (MIT license).

Changes made here: the transcripts were converted to the `CanonicalTranscript` format. Roles became `Speaker_N` labels. The AMI markup tags `{vocalsound}`, `{disfmarker}` and `{gap}` were removed, the space before punctuation was closed, and utterances left empty by that were dropped. The wording is otherwise unchanged. The `expected.json` files are new work for this repository. The material is provided as is, without warranty.

## Movie scenes

Fixtures: `office-space-interview`, `margin-call-boardroom`.

Short scenes from Office Space (1999) and Margin Call (2011). The maintainer supplied them and confirmed they may be committed. This repository does not verify their license independently; remove them if that changes. Stage directions were removed and each character became a `Speaker_N` label. The dialogue is otherwise unchanged, typos included.
