# Decision 3.6 strategy comparison: results

Records which grounding strategy is the MVP default and why. Metrics only: no item text and no source quotes.

## Outcome

**Substring is the MVP default, with no Citations fallback.**

The flip rule (Story 3.8, Decision 3.6) locks Citations only if it matches or beats substring on every transcript. It flips to substring if substring catches anything Citations missed. Citations returned no items on 5 of 6 transcripts, so the rule flips. Substring returned items on all 6.

Both strategies still ship. Substring is required for the v1.1+ local-LLM path (FR33).

## Run

- Run at: 2026-09-19T00:04:40Z (UTC).
- Model: `claude-opus-5`, default `SummarizerConfig`, empty glossary, no attendee context.
- Code: revision `bba0180dede975336000dc5447395b980107bfce` plus the prompt-contract and `max_tokens` changes made for this run.
- Prompt set hash, citations: `ec6a789d002dbc7dc481a65fce114ba9f5757fa821d9a252c9b7347e532fc5a5`.
- Prompt set hash, substring: `b32698f9fc388e5f06648973ea501b25ac586c9dbac034b64b462737a43bd8cb`.
- Re-run: stage the fixtures flat and run the script.

  ```bash
  d=$(mktemp -d) && for f in Tests/SummarizeTests/Fixtures/eval/*/transcript.json; do cp "$f" "$d/$(basename "$(dirname "$f")").json"; done && AURICLE_COMPARISON_TRANSCRIPTS=$d Tests/scripts/run-strategy-comparison.sh
  ```

## Transcripts

The maintainer accepted the public fixtures in `Tests/SummarizeTests/Fixtures/eval/` as the comparison set in place of personal recordings. `NOTICE.md` there records their provenance. Recall and false-keeps are scored against each fixture's hand-curated `expected.json`.

| Transcript | Speakers | Expected items |
|---|---|---|
| `office-space-interview` | 3 | 0 |
| `margin-call-boardroom` | 5 | 4 |
| `ami-es2002a` | 4 | 3 |
| `ami-es2002b` | 4 | 8 |
| `ami-es2003a` | 4 | 1 |
| `ami-es2003b` | 4 | 4 |

## Computed metrics

`quote_validation_drop_count` is 0 for every arm that returned. Citations fails whole-call instead of dropping items.

| Transcript | Citations | Substring items kept (actions + decisions) | Substring cost (USD) |
|---|---|---|---|
| `office-space-interview` | ok, 0 items, $0.0601 | 3 + 1 | 0.0984 |
| `margin-call-boardroom` | `citationsUnavailable` | 2 + 4 | 0.1759 |
| `ami-es2002a` | `citationsUnavailable` | 3 + 5 | 0.2613 |
| `ami-es2002b` | `citationsUnavailable` | 4 + 10 | 0.5682 |
| `ami-es2003a` | `citationsUnavailable` | 3 + 4 | 0.2669 |
| `ami-es2003b` | `citationsUnavailable` | 5 + 8 | 0.4009 |

Substring total: $1.77 for 6 calls. The rig records no cost for a failed arm, so the 5 Citations failures are billed but unlisted. No thinking tokens are reported separately: the API counts them inside output tokens.

## Scored metrics (substring)

Scored by the assistant that ran the comparison, by comparing each kept item's meaning with `expected.json`. The maintainer has not yet spot-checked these numbers. Citations has no items to score on 5 transcripts, so its recall is 0 there.

| Transcript | Recall | False-keeps |
|---|---|---|
| `office-space-interview` | 0 of 0 | 4 |
| `margin-call-boardroom` | 4 of 4 | 2 |
| `ami-es2002a` | 3 of 3 | 5 |
| `ami-es2002b` | 8 of 8 | 6 |
| `ami-es2003a` | 1 of 1 | 6 |
| `ami-es2003b` | 3 of 4 | 10 |

Recall is 19 of 20 items. `ami-es2003b` missed the marketing follow-up on opinions of the minimalist design.

False-keeps are kept items that match no expected item. They are high: 33 of 52 kept items. The curated files exclude project constraints, floated ideas and one participant's suggestions. The strategies keep them as decisions. Every transcript exceeds its `max_false_keeps` target from `expected.json`. This is a prompt-precision gap, separate from the strategy choice. It belongs to the prompt-tuning work that the rig's comparison axis supports.

Quote quality: quotes are verbatim and read sensibly on the two movie scenes. On the meetings they carry the source's disfluencies, including stutters and spelled-out acronyms. Some quotes support only part of an item ("the team agreed" backed by one speaker's line).

## Rationale

- Citations attaches real citation objects only when the model chooses to cite. With the shared prompt it wrote its own citation-shaped fields or `<cite>` markup into the JSON and attached none. This is the failure Decision 3.2 records as [P12]. Adding a user instruction after the document ("Cite the document for each item") produced 5 real citations on one long meeting but none on another, mixed with markup, so it was not adopted.
- Substring dropped no item and missed one of 20. Its `source_transcript_quote` values validated verbatim on every transcript.
- A Citations fallback under a substring primary would cost a paid call that failed on 5 of 6 transcripts. So the orchestrator has no fallback.
- `office-space-interview` returned 0 items from substring on two earlier runs and 4 on this one. A single run is a sample, not a measurement. Re-run before relying on a false-keep count.

## Run history

1. Original prompts, `max_tokens` 4096: all 12 arm runs failed with `malformedResponse`. The prompt set never asked for JSON.
2. JSON output contract added to `system.md` and `citations.md`: Citations `citationsUnavailable` on 5 of 5 transcripts with items. Substring failed on `ami-es2002b`, where the answer was cut off at 4096 tokens.
3. `max_tokens` raised to 16384: substring succeeds on all 6. This is the run recorded above.

Revisit this outcome if Anthropic changes Citations behavior or the prompt set changes materially.
