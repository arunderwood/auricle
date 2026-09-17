#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["anthropic>=0.40", "typer>=0.12", "loguru>=0.7"]
# ///
"""With several grounded items in one response, which citation belongs to which item?

[P9] showed the direct Messages API returns prompt-instructed JSON and citations together. It
used a single-item document, so the association was trivial and the question never arose.

Decision 3.2 (architecture.md) says each item "must include a `citations` array referencing the
document". That sentence was written for ``output_config.format``, where a schema could carry a
per-item array — and that combination returns 400. On the prompt-instruction route citations
attach to **text blocks of the response**, not to fields inside the JSON the model writes. So
the call returns both halves and says nothing about how to join them.

This probe measures whether the join is recoverable, and how.

  ARM A   JSON by prompt instruction + citations. The shipping shape. Association is
          attempted positionally: find which response text block contains each item, and read
          that block's citations.
  ARM B   Same, plus the model is asked to emit `source_block_index` per item. Tests whether a
          model-asserted pointer agrees with the server-constructed one — if it does, the join
          is explicit and free; if it does not, that disagreement is the reason the
          server-constructed citation is worth the positional plumbing.

**How correctness is checked mechanically.** Each source utterance carries a unique nonce. An
item about utterance K must mention nonce K. So: find the response block holding an item's
nonce, read that block's citation, and check whether the cited SOURCE block is the one whose
nonce it is. That is a true/false per item, not a judgement call.

Requires ANTHROPIC_API_KEY. Two calls on claude-opus-5; a few cents.

Exit codes:
  0  both arms returned a definite verdict
  1  probe could not run
  3  a model refused to emit parseable JSON, or returned no citations — inconclusive, not a
     finding about the API
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

import typer
from loguru import logger

app = typer.Typer(add_completion=False)
EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3

#: One commitment per utterance, each with a unique nonce. Block index == position here.
UTTERANCES = [
    "<Speaker_1>: Morning. Before anything else — ticket 4413 is the antenna order, and I'll place it Friday.",
    "<Speaker_2>: Fine. I'm taking ticket 7250, the repeater siting survey, and I'll have it done by the 9th.",
    "<Speaker_1>: We also agreed ticket 1902 gets dropped entirely. Nobody is picking that up.",
    "<Speaker_3>: I'll own ticket 6688 — the firmware migration — and report back at the next standup.",
]
NONCES = ["4413", "7250", "1902", "6688"]

BASE = (
    "This is a meeting transcript. Extract every action item or decision.\n\n"
    "Respond with a single JSON object and nothing else — no prose, no markdown fence:\n"
    '  {"items": [ ... ]}\n'
    "Each element of items has:\n"
    '  "text"     — one sentence describing the commitment, including its ticket number\n'
    '  "assignee" — the speaker label who owns it, or null for a decision with no owner\n'
)
ARM_A_PROMPT = BASE + "\nCite the document for each item."
ARM_B_PROMPT = (
    BASE
    + '  "source_block_index" — the 0-based index of the transcript block supporting this item\n'
    + "\nCite the document for each item."
)


def _document() -> dict:
    return {
        "type": "document",
        "source": {"type": "content", "content": [{"type": "text", "text": u} for u in UTTERANCES]},
        "title": "Standup transcript",
        "citations": {"enabled": True},
    }


def _blocks(resp) -> list[dict]:
    """Response text blocks in order, each with its citations and its span in the concatenation."""
    out, cursor = [], 0
    for b in resp.content:
        if getattr(b, "type", None) != "text":
            continue
        text = b.text
        cits = []
        for c in getattr(b, "citations", None) or []:
            cits.append({k: v for k, v in vars(c).items() if not k.startswith("_")})
        out.append({"start": cursor, "end": cursor + len(text), "text": text, "citations": cits})
        cursor += len(text)
    return out


def _parse_json(text: str) -> dict | None:
    t = text.strip()
    if m := re.search(r"```(?:json)?\s*(.*?)```", t, re.S):
        t = m.group(1).strip()
    try:
        v = json.loads(t)
    except json.JSONDecodeError:
        return None
    return v if isinstance(v, dict) else None


def _run_arm(client, *, label: str, prompt: str, model: str, max_tokens: int) -> dict:
    typer.echo(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    try:
        resp = client.messages.create(
            model=model, max_tokens=max_tokens,
            messages=[{"role": "user", "content": [_document(), {"type": "text", "text": prompt}]}],
        )
    except Exception as exc:  # noqa: BLE001 — a 400 is a measurement here
        typer.echo(f"  ERROR: {str(exc)[:300]}")
        return {"label": label, "error": str(exc)[:300], "ok": False}

    blocks = _blocks(resp)
    whole = "".join(b["text"] for b in blocks)
    parsed = _parse_json(whole)
    total_cits = sum(len(b["citations"]) for b in blocks)

    typer.echo(f"  stop_reason     : {resp.stop_reason}")
    typer.echo(f"  text blocks     : {len(blocks)}   (blocks carrying citations: "
               f"{sum(1 for b in blocks if b['citations'])})")
    typer.echo(f"  citations total : {total_cits}")
    typer.echo(f"  JSON parsed     : {'yes' if parsed else 'NO'}")

    if not parsed or not isinstance(parsed.get("items"), list):
        typer.echo(f"  raw (truncated) : {whole[:300]!r}")
        return {"label": label, "ok": False, "blocks": blocks, "reason": "unparseable"}

    items = parsed["items"]
    typer.echo(f"  items returned  : {len(items)} (expected {len(UTTERANCES)})")

    # --- the association test -------------------------------------------------
    typer.echo(f"\n  {'nonce':<7}{'in blk':<8}{'cited src blk':<15}{'expected':<10}{'model said':<12}verdict")
    typer.echo(f"  {'-' * 68}")
    rows = []
    for item in items:
        blob = json.dumps(item, ensure_ascii=False)
        nonce = next((n for n in NONCES if n in blob), None)
        if nonce is None:
            rows.append({"nonce": None, "verdict": "no-nonce"})
            typer.echo(f"  {'?':<7}{'-':<8}{'-':<15}{'-':<10}{'-':<12}item names no ticket")
            continue

        expected = NONCES.index(nonce)
        pos = whole.find(nonce)
        holder = next((i for i, b in enumerate(blocks) if b["start"] <= pos < b["end"]), None)
        cited = None
        if holder is not None and blocks[holder]["citations"]:
            cited = blocks[holder]["citations"][0].get("start_block_index")
        asserted = item.get("source_block_index")

        if cited is None:
            verdict = "NO CITATION on the block holding this item"
        elif cited == expected:
            verdict = "CORRECT"
        else:
            verdict = f"WRONG (cited {cited})"

        rows.append({"nonce": nonce, "expected": expected, "holder_block": holder,
                     "cited_source_block": cited, "model_asserted": asserted, "verdict": verdict})
        typer.echo(f"  {nonce:<7}{str(holder):<8}{str(cited):<15}{str(expected):<10}"
                   f"{str(asserted):<12}{verdict}")

    return {"label": label, "ok": True, "item_count": len(items), "citation_count": total_cits,
            "block_count": len(blocks), "rows": rows, "blocks": blocks, "json": parsed}


def _report(a: dict, b: dict) -> int:
    typer.echo(f"\n{'=' * 78}\nVERDICT — how does a host join citations to items?\n{'=' * 78}")
    if not a.get("ok"):
        typer.echo("ARM A did not produce parseable items — inconclusive, rerun.")
        return EXIT_INCONCLUSIVE

    rows = [r for r in a["rows"] if r.get("nonce")]
    correct = sum(1 for r in rows if r["verdict"] == "CORRECT")
    uncited = sum(1 for r in rows if "NO CITATION" in str(r["verdict"]))

    typer.echo(f"ARM A — positional association: {correct}/{len(rows)} items grounded correctly, "
               f"{uncited} with no citation on their block.")
    if correct == len(rows) and rows:
        typer.echo("  -> POSITIONAL ASSOCIATION WORKS. Story 3.5 maps citation->item by finding")
        typer.echo("     which response text block contains each item. No model-asserted pointer")
        typer.echo("     needed; the server-constructed citation stays authoritative.")
    elif a["block_count"] == 1:
        typer.echo("  -> THE RESPONSE WAS ONE TEXT BLOCK. Position cannot discriminate: every item")
        typer.echo("     shares the same block and therefore the same citation set. Positional")
        typer.echo("     association is UNAVAILABLE and Story 3.5 needs another mechanism.")
    else:
        typer.echo("  -> PARTIAL. Some items land on blocks whose citation points elsewhere.")
        typer.echo("     Treat positional association as lossy and decide what a mismatch means.")

    if b.get("ok"):
        brows = [r for r in b["rows"] if r.get("nonce")]
        agree = sum(1 for r in brows if r.get("model_asserted") == r.get("expected"))
        match = sum(1 for r in brows
                    if r.get("model_asserted") is not None
                    and r.get("model_asserted") == r.get("cited_source_block"))
        typer.echo(f"\nARM B — model-asserted source_block_index: {agree}/{len(brows)} correct; "
                   f"{match}/{len(brows)} agree with the server citation.")
        if brows and agree == len(brows):
            typer.echo("  -> The model's own pointer was right every time here. Cheap and explicit,")
            typer.echo("     but it is the model asserting a pointer — the property that makes")
            typer.echo("     Citations worth more than the substring path. Use it as a cross-check")
            typer.echo("     against the server citation, not as the grounding itself.")
        elif brows:
            typer.echo("  -> The model's pointer was wrong at least once. That is the argument for")
            typer.echo("     paying the positional plumbing and keeping the server citation")
            typer.echo("     authoritative.")
    else:
        typer.echo("\nARM B did not produce parseable items.")

    return EXIT_OK


@app.command()
def main(
    model: str = typer.Option("claude-opus-5", "--model", "-m"),
    max_tokens: int = typer.Option(4000, "--max-tokens", help="Headroom for adaptive thinking on Opus 5"),
) -> None:
    """Measure whether citation->item association is recoverable on a multi-item response."""
    logger.remove(); logger.add(sys.stderr, level="INFO")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.error("ANTHROPIC_API_KEY is not set. Export it, then rerun.")
        raise typer.Exit(EXIT_ERROR)
    try:
        import anthropic
    except ModuleNotFoundError:
        logger.error("run this file with `uv run` so PEP 723 deps resolve")
        raise typer.Exit(EXIT_ERROR)

    client = anthropic.Anthropic()
    logger.info("probing {} — two calls", model)

    a = _run_arm(client, label="ARM A — JSON by instruction + citations (the shipping shape)",
                 prompt=ARM_A_PROMPT, model=model, max_tokens=max_tokens)
    b = _run_arm(client, label="ARM B — same, plus model-asserted source_block_index",
                 prompt=ARM_B_PROMPT, model=model, max_tokens=max_tokens)

    code = _report(a, b)

    ev = Path(__file__).resolve().parent / "evidence"
    ev.mkdir(exist_ok=True)

    # Per-run file, so a replication loop accumulates instead of overwriting itself.
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    (ev / f"citation_item_association_{stamp}.json").write_text(
        json.dumps({"run": stamp, "model": model, "arm_a": a, "arm_b": b},
                   indent=2, ensure_ascii=False, default=str))

    # One line per run, appended. This is the file to read after a loop.
    def summarize(arm: dict) -> dict:
        rows = [r for r in arm.get("rows", []) if r.get("nonce")]
        return {
            "blocks": arm.get("block_count"),
            "items": arm.get("item_count"),
            "real_citations": arm.get("citation_count"),
            "correct": sum(1 for r in rows if r.get("verdict") == "CORRECT"),
            "of": len(rows),
        }

    with (ev / "citation_item_association_runs.jsonl").open("a") as fh:
        fh.write(json.dumps({"run": stamp, "model": model,
                             "A": summarize(a), "B": summarize(b)}, default=str) + "\n")

    logger.success("run → {}  ·  rolling log → {}",
                   ev / f"citation_item_association_{stamp}.json",
                   ev / "citation_item_association_runs.jsonl")
    raise typer.Exit(code)


if __name__ == "__main__":
    app()
