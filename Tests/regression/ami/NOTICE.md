# AMI audio notice

The regression suite downloads audio from meetings ES2002a, ES2002b, ES2003a, ES2003b and ES2004a of the AMI Meeting Corpus, https://groups.inf.ed.ac.uk/ami/corpus/, licensed under Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/.

The audio is not stored in this repository. `fetch.sh` downloads it into a cache and checks each file against the SHA-256 in `manifest.json`.

## Reference transcripts and expected items

ES2002a, ES2002b, ES2003a and ES2003b use the Epic 3 eval fixtures; their notice is `Tests/SummarizeTests/Fixtures/eval/NOTICE.md`.

`reference/es2004a` is meeting ES2004a of the same corpus, under the same CC BY 4.0 licence, obtained through the QMSum dataset, https://github.com/Yale-LILY/QMSum (MIT license).

Changes made here: `transcript.json` was produced from the QMSum meeting by `Tests/scripts/eval_fixture_tool.py qmsum`, which converts it to the `CanonicalTranscript` format. Roles became `Speaker_N` labels. The AMI markup tags `{vocalsound}`, `{disfmarker}` and `{gap}` were removed, the space before punctuation was closed, and utterances left empty by that were dropped. The wording is otherwise unchanged. `expected.json` is new work for this repository. The material is provided as is, without warranty.
