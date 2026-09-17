#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "anthropic>=0.40",
#   "typer>=0.12",
#   "loguru>=0.7",
# ]
# ///
"""What unit are Anthropic Messages API citation character offsets?

Answers open question #2 from research.md (same directory).

The docs state that ``start_char_index`` / ``end_char_index`` are "0-indexed with exclusive end
indices" and never state what a "character" is. The candidates diverge on non-ASCII text, and
for a Swift host the difference between UTF-8 bytes, UTF-16 code units and codepoints is the
difference between a correct and a silently wrong transcript offset.

Two requests:

  A  prefix holds non-BMP emoji plus PRECOMPOSED accents. Already NFC, so no normalization
     confound. Isolates the encoding unit.
  B  prefix holds DECOMPOSED sequences. Read under the unit A establishes, this reveals whether
     the server indexes the bytes as submitted or an NFC-normalized copy — the two predict
     different offsets.

The decisive test is not arithmetic. For each candidate encoding the probe slices the exact
string it submitted at ``[start:end)`` and compares against the returned ``cited_text``. The
encoding whose slice reproduces ``cited_text`` is the answer, and it self-validates: arithmetic
can coincide, but a slice that reproduces the server's own quoted text cannot.

Requires ANTHROPIC_API_KEY. Costs well under a cent.

Exit codes:
  0  conclusive verdict reached
  1  probe could not run (no credential, API error)
  3  probe ran but no candidate matched, or several did — inconclusive
"""

from __future__ import annotations

import json
import os
import sys
import unicodedata
from pathlib import Path

import typer
from loguru import logger

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_common as pc  # noqa: E402

app = typer.Typer(add_completion=False)

EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3


def _probe_once(client, label: str, prefix: str, model: str, max_tokens: int) -> dict:
    doc = pc.document(prefix)

    typer.echo(f"\n{'=' * 78}\nREQUEST {label}\n{'=' * 78}")
    typer.echo(f"  document (truncated) : {doc[:64]!r}...")
    typer.echo(f"  prefix candidates    : {pc.counts(prefix)}")
    typer.echo(f"  prefix is NFC-stable : {unicodedata.is_normalized('NFC', prefix)}")

    resp = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "document",
                        "source": {"type": "text", "media_type": "text/plain", "data": doc},
                        "title": "Beacon field log",
                        "citations": {"enabled": True},
                    },
                    {"type": "text", "text": pc.QUESTION},
                ],
            }
        ],
    )

    typer.echo(f"  stop_reason          : {resp.stop_reason}")
    typer.echo(f"  usage                : in={resp.usage.input_tokens} out={resp.usage.output_tokens}")

    findings = []
    for block in resp.content:
        if getattr(block, "type", None) != "text":
            continue
        for cit in getattr(block, "citations", None) or []:
            ctype = getattr(cit, "type", None)
            if ctype != "char_location":
                typer.echo(f"\n  non-char_location citation: {ctype} — document source type differed")
                findings.append({"unexpected_type": ctype})
                continue

            start, end, cited = cit.start_char_index, cit.end_char_index, cit.cited_text
            typer.echo(f"\n  cited_text : {cited!r}")
            typer.echo(f"  start/end  : {start} / {end}")

            matches = []
            for unit in pc.UNITS:
                got = pc.slice_as(doc, start, end, unit)
                ok = got == cited
                shown = (got[:56] + "...") if got and len(got) > 56 else got
                typer.echo(f"    {'MATCH  ' if ok else '       '}{unit:<12} -> {shown!r}")
                if ok:
                    matches.append(unit)

            findings.append(
                {
                    "cited_text": cited,
                    "start_char_index": start,
                    "end_char_index": end,
                    "matching_units": matches,
                    "cited_text_verbatim_in_submitted_doc": cited in doc,
                }
            )

    return {"label": label, "prefix_counts": pc.counts(prefix), "citations": findings}


def _report(results: list[dict]) -> int:
    typer.echo(f"\n{'=' * 78}\nVERDICT — open question #2: what unit are citation offsets?\n{'=' * 78}")

    res_a, res_b = results
    units_a = {u for c in res_a["citations"] for u in c.get("matching_units", [])}
    units_b = {u for c in res_b["citations"] for u in c.get("matching_units", [])}

    if not res_a["citations"]:
        typer.echo("INCONCLUSIVE — request A returned no citation. Rerun or adjust the prompt.")
        return EXIT_INCONCLUSIVE

    if not units_a:
        typer.echo("NO CANDIDATE MATCHED — the server indexes something other than the text as")
        typer.echo("  submitted. Inspect the raw JSON: this is a finding, not a failure.")
        return EXIT_INCONCLUSIVE

    if len(units_a) > 1:
        typer.echo(f"AMBIGUOUS — several units matched ({sorted(units_a)}).")
        typer.echo("  Widen the prefix divergence and rerun.")
        return EXIT_INCONCLUSIVE

    unit = units_a.pop()
    typer.echo(f"ENCODING UNIT: {unit}")
    typer.echo("  (request A's slice reproduced cited_text exactly under this unit alone)")

    if units_b == {unit}:
        typer.echo("\nNORMALIZATION: offsets index the text AS SUBMITTED.")
        typer.echo(f"  Request B's decomposed prefix scored identically under {unit}, so the")
        typer.echo("  server did not re-normalize before indexing.")
    elif not units_b:
        typer.echo("\nNORMALIZATION: SERVER LIKELY NORMALIZES BEFORE INDEXING.")
        typer.echo("  No candidate reproduced cited_text for the decomposed prefix, so the text")
        typer.echo("  being indexed differs from what was submitted. Compare B's raw offsets")
        typer.echo(f"  against the NFC prediction: {pc.counts(unicodedata.normalize('NFC', pc.PREFIX_NFD))}")
    else:
        typer.echo(f"\nNORMALIZATION: ambiguous — A matched {{{unit}}}, B matched {sorted(units_b)}.")

    return EXIT_OK


@app.command()
def main(
    model: str = typer.Option("claude-opus-5", "--model", "-m", help="Model to probe"),
    max_tokens: int = typer.Option(1000, "--max-tokens"),
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Show debug logging"),
) -> None:
    """Determine empirically what unit Anthropic citation character offsets count."""
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")

    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.error("ANTHROPIC_API_KEY is not set. Export it in your shell, then rerun.")
        raise typer.Exit(EXIT_ERROR)

    try:
        import anthropic
    except ModuleNotFoundError:
        logger.error("anthropic SDK missing — run this file with `uv run` so PEP 723 deps resolve")
        raise typer.Exit(EXIT_ERROR)

    client = anthropic.Anthropic()
    logger.info("probing {} — two requests, well under a cent", model)

    try:
        results = [
            _probe_once(client, "A (precomposed / already NFC)", pc.PREFIX_NFC, model, max_tokens),
            _probe_once(client, "B (decomposed / NFD sequences)", pc.PREFIX_NFD, model, max_tokens),
        ]
    except Exception:
        logger.exception("API call failed")
        raise typer.Exit(EXIT_ERROR)

    code = _report(results)

    out = Path(__file__).resolve().parent / "evidence" / "citation_offset_probe_result.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    logger.success("raw result → {}", out)
    raise typer.Exit(code)


if __name__ == "__main__":
    app()
