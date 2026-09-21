# AMI regression suite

Runs four public AMI meetings (ES2002a/b, ES2003a/b) through the real CLI pipeline and scores the result. It uses the real models and spends Anthropic credit, so it is run by hand, never in CI.

```bash
Tests/regression/ami/run.sh                      # all four
Tests/regression/ami/run.sh ES2003a              # one
AURICLE_AMI_RECORD=1 Tests/regression/ami/run.sh # also append to history.jsonl
```

Setup is the same as `Tests/scripts/run-epic4-exit-criteria.sh`: launch the app once, set `vault_path` in `~/.auricle/config.toml` (use a scratch vault; every run publishes notes), and keep an Anthropic key in the Keychain.

## What it measures

- Word error rate against the reference transcript in `Tests/SummarizeTests/Fixtures/eval/`.
- Transcription time over audio length (realtime factor).
- Speakers the diarizer found, against 4.
- Grounded items kept, dropped items, and cost.
- How many expected items the note recalls. Recall is coarse: 16 expected items in total, matched by word overlap with the model's quote.

`thresholds.json` holds the limits. They guard against a regression from the recorded baseline in `history.jsonl`. They are not quality targets. Change a limit only with a reason in the commit message.

## Comparing models

The transcriber, diarizer and summarizer models are the ones the CLI ships with. Each row in `history.jsonl` records them, so a model change appears as a new row next to the old ones. Selecting a model at run time is not supported.

## Not covered

- No 1:1 recording: every AMI scenario meeting has four speakers.
- Speaker names are not scored, only the speaker count.

The audio is not in the repository. `fetch.sh` downloads it into `~/Library/Caches/auricle-ami` and checks each file against `manifest.json`. See `NOTICE.md` for the licence.
