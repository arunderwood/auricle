# AMI audio notice

The regression suite downloads audio from meetings ES2002a, ES2002b, ES2003a and ES2003b of the AMI Meeting Corpus, https://groups.inf.ed.ac.uk/ami/corpus/, licensed under Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/.

The audio is not stored in this repository. `fetch.sh` downloads it into a cache and checks each file against the SHA-256 in `manifest.json`. The reference transcripts and expected items are the Epic 3 eval fixtures; their notice is `Tests/SummarizeTests/Fixtures/eval/NOTICE.md`.
