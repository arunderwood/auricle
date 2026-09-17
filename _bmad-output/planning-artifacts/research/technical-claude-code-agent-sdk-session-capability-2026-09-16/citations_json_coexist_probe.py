#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "anthropic>=0.40",
#   "typer>=0.12",
#   "loguru>=0.7",
# ]
# ///
"""Can the direct Messages API return citations and JSON from one call?

Answers open question #11 from research.md (same directory), which the offset probe beside
this file does not touch. [P5] established that a Claude Code session returns structured
output and citations together. The Messages API documents the combination as a 400 — but the
documented incompatibility names ``output_config.format``, a *parameter*, and says nothing
about asking for JSON in the prompt. Decision 3.2 needs structured items that each carry a
citation, so whether that gap is real decides whether the Citations strategy is implementable
on the direct path at all.

Four arms, run in this order because each reads against the one before it:

  CONTROL  citations + ``output_config.format``. Expected 400. Establishes that the
           documented incompatibility is live on this account and model, so that a 200 from
           any other arm is a finding rather than a quirk of the environment.
  A1       citations + JSON requested BY PROMPT INSTRUCTION ONLY. The decisive arm.
  A2       custom-content document + citations, no JSON. [P6] saw ``content_block_location``
           block indices through a session; this checks the direct path, which is the one
           that would ship.
  A3       custom content + citations + JSON by instruction — the exact shape auricle would
           send if both A1 and A2 pass.

An arm passes only if BOTH halves arrive in the same response: parseable JSON *and* at least
one citation carrying a location. A 200 that quietly dropped the citations is a failure, not
a pass, so each arm asserts both rather than reporting the status code.

Requires ANTHROPIC_API_KEY. Four calls on claude-opus-5; costs a few cents.

Exit codes:
  0  every arm reached a definite verdict (they may be negative verdicts)
  1  probe could not run (no credential, unexpected API error)
  3  an arm was inconclusive — usually the model declined to emit JSON at all
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import typer
from loguru import logger

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_common as pc  # noqa: E402

app = typer.Typer(add_completion=False)

EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3

#: Mirrors the shape Decision 3.1 wants back: an item plus its grounding.
SCHEMA = {
    "type": "object",
    "properties": {
        "frequency_hz": {"type": "integer"},
        "source_quote": {"type": "string"},
    },
    "required": ["frequency_hz", "source_quote"],
    "additionalProperties": False,
}

#: The same contract as SCHEMA, expressed the only other way there is to ask for it.
JSON_INSTRUCTION = (
    "At what frequency does the Auricle beacon transmit?\n\n"
    "Respond with a single JSON object and nothing else — no prose before or after it, no "
    "markdown code fence. The object has exactly two keys:\n"
    '  "frequency_hz"  — integer\n'
    '  "source_quote"  — string, the verbatim sentence from the document that supports it\n'
    "Cite the document."
)

#: One block per utterance — the segmentation auricle already performs on a transcript.
UTTERANCES = [
    "<Speaker_1>: Before we start, is the field log current?",
    "<Speaker_2>: " + pc.TARGET,
    "<Speaker_1>: Good. Maintenance is first Tuesday of each month, right?",
]


def _plain_text_doc() -> dict:
    return {
        "type": "document",
        "source": {"type": "text", "media_type": "text/plain", "data": pc.document()},
        "title": "Beacon field log",
        "citations": {"enabled": True},
    }


def _custom_content_doc() -> dict:
    return {
        "type": "document",
        "source": {
            "type": "content",
            "content": [{"type": "text", "text": u} for u in UTTERANCES],
        },
        "title": "Beacon field log",
        "citations": {"enabled": True},
    }


def _all_text(resp) -> str:
    return "".join(b.text for b in resp.content if getattr(b, "type", None) == "text")


def _all_citations(resp) -> list[dict]:
    out = []
    for block in resp.content:
        if getattr(block, "type", None) != "text":
            continue
        for cit in getattr(block, "citations", None) or []:
            out.append({k: v for k, v in vars(cit).items() if not k.startswith("_")})
    return out


def _parse_json(text: str) -> dict | None:
    """Parse the response as JSON, tolerating a markdown fence the instruction forbade.

    Tolerated deliberately: a fence means the instruction was imperfectly followed, which is a
    prompt-engineering problem for Story 3.2 to solve. It is not evidence about whether the
    API permits the combination, which is the only thing this probe is measuring.
    """
    candidate = text.strip()
    if fenced := re.search(r"```(?:json)?\s*(.*?)```", candidate, re.S):
        candidate = fenced.group(1).strip()
    try:
        parsed = json.loads(candidate)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _run_arm(client, *, label: str, doc: dict, prompt: str, structured: bool, model: str, max_tokens: int) -> dict:
    typer.echo(f"\n{'=' * 78}\n{label}\n{'=' * 78}")

    kwargs = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": [doc, {"type": "text", "text": prompt}]}],
    }
    if structured:
        kwargs["output_config"] = {"format": {"type": "json_schema", "schema": SCHEMA}}

    typer.echo(f"  document source      : {doc['source']['type']}")
    typer.echo(f"  output_config.format : {'yes' if structured else 'no — prompt instruction only'}")

    try:
        resp = client.messages.create(**kwargs)
    except Exception as exc:  # noqa: BLE001 — a 400 here is the measurement, not a crash
        status = getattr(exc, "status_code", None)
        body = str(exc)[:400]
        typer.echo(f"  HTTP                 : {status or 'error'}")
        typer.echo(f"  message              : {body}")
        return {
            "label": label,
            "http_status": status,
            "error": body,
            "json_parsed": False,
            "citation_count": 0,
            "both_together": False,
        }

    text = _all_text(resp)
    cits = _all_citations(resp)
    parsed = _parse_json(text)

    typer.echo(f"  HTTP                 : 200")
    typer.echo(f"  stop_reason          : {resp.stop_reason}")
    typer.echo(f"  usage                : in={resp.usage.input_tokens} out={resp.usage.output_tokens}")
    typer.echo(f"  text blocks          : {sum(1 for b in resp.content if getattr(b, 'type', None) == 'text')}")
    typer.echo(f"  JSON parsed          : {'yes' if parsed else 'NO'}")
    if parsed:
        typer.echo(f"    -> {json.dumps(parsed, ensure_ascii=False)[:160]}")
    typer.echo(f"  citations returned   : {len(cits)}")
    for c in cits:
        loc = c.get("type")
        if loc == "char_location":
            typer.echo(f"    -> {loc}: [{c.get('start_char_index')}, {c.get('end_char_index')})")
        elif loc == "content_block_location":
            typer.echo(f"    -> {loc}: blocks [{c.get('start_block_index')}, {c.get('end_block_index')})")
        else:
            typer.echo(f"    -> {loc}: {json.dumps(c, ensure_ascii=False, default=str)[:140]}")

    both = bool(parsed) and bool(cits)
    typer.echo(f"  BOTH IN ONE CALL     : {'YES' if both else 'no'}")

    return {
        "label": label,
        "http_status": 200,
        "stop_reason": resp.stop_reason,
        "json_parsed": bool(parsed),
        "json": parsed,
        "citation_count": len(cits),
        "citations": cits,
        "citation_types": sorted({c.get("type") for c in cits if c.get("type")}),
        "both_together": both,
    }


def _report(results: dict[str, dict]) -> int:
    control, a1, a2, a3 = (results[k] for k in ("CONTROL", "A1", "A2", "A3"))

    typer.echo(f"\n{'=' * 78}\nVERDICT — open question #11\n{'=' * 78}")

    if control["http_status"] == 400:
        typer.echo("CONTROL: 400 as documented. The incompatibility is live here, so a 200 below is real.")
    elif control["http_status"] == 200:
        typer.echo("CONTROL: *** 200 — output_config.format + citations did NOT 400. ***")
        typer.echo("  The documented incompatibility did not reproduce. That is itself a finding:")
        typer.echo("  re-read the citations guide before trusting either outcome below.")
    else:
        typer.echo(f"CONTROL: inconclusive (status={control['http_status']}). Treat the rest as unanchored.")

    typer.echo("")
    if a1["both_together"]:
        typer.echo("A1: JSON BY INSTRUCTION + CITATIONS COEXIST ON THE DIRECT API.")
        typer.echo("  -> Decision (b) is final with no residual. John's objection is discharged:")
        typer.echo("     Decision 3.2's Citations strategy is implementable on the direct path.")
    elif a1["http_status"] == 400:
        typer.echo("A1: 400 — the incompatibility reaches the prompt-instruction route too.")
        typer.echo("  -> [P5] is load-bearing. Decision (b) REOPENS for the summarize stage.")
    elif a1["http_status"] == 200 and not a1["json_parsed"]:
        typer.echo("A1: 200, citations present, but no parseable JSON.")
        typer.echo("  -> INCONCLUSIVE: a prompting problem, not an API verdict. Retry with a")
        typer.echo("     firmer instruction before concluding anything about the API.")
    elif a1["http_status"] == 200 and not a1["citation_count"]:
        typer.echo("A1: 200 with JSON but ZERO citations — the combination is permitted and useless.")
        typer.echo("  -> Treat as a failure. Grounding is the point; JSON without it is not a win.")

    typer.echo("")
    if "content_block_location" in (a2.get("citation_types") or []):
        typer.echo("A2: custom content returns content_block_location on the DIRECT path.")
        typer.echo("  -> The Decision 3.4 replacement holds. Block indices, no character offsets,")
        typer.echo("     no dependency on the undocumented codepoint convention.")
    elif a2["http_status"] == 200 and a2["citation_count"]:
        typer.echo(f"A2: 200 but returned {a2.get('citation_types')} rather than content_block_location.")
        typer.echo("  -> The Decision 3.4 replacement is UNAVAILABLE. The codepoint translation")
        typer.echo("     layer comes back, with its one-month staleness obligation.")
    else:
        typer.echo("A2: no citations returned — inconclusive, rerun before drawing the negative.")

    typer.echo("")
    if a3["both_together"]:
        typer.echo("A3: the shipping shape works — custom content + citations + JSON, one call.")
    else:
        typer.echo("A3: the combined shape did NOT produce both. Read A1 and A2 to see which half failed.")

    inconclusive = any(
        r["http_status"] == 200 and not r["json_parsed"] and not r["citation_count"]
        for r in (a1, a3)
    )
    return EXIT_INCONCLUSIVE if inconclusive else EXIT_OK


@app.command()
def main(
    model: str = typer.Option("claude-opus-5", "--model", "-m", help="Model to probe"),
    max_tokens: int = typer.Option(4000, "--max-tokens", help="Headroom for adaptive thinking on Opus 5"),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
) -> None:
    """Does the direct Messages API return citations and JSON from a single call?"""
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
    logger.info("probing {} — four calls", model)

    arms = [
        ("CONTROL", "CONTROL — plain text + output_config.format (expected 400)",
         _plain_text_doc(), pc.QUESTION, True),
        ("A1", "A1 — plain text + JSON by prompt instruction (DECISIVE)",
         _plain_text_doc(), JSON_INSTRUCTION, False),
        ("A2", "A2 — custom content + citations, no JSON",
         _custom_content_doc(), pc.QUESTION, False),
        ("A3", "A3 — custom content + citations + JSON by instruction (shipping shape)",
         _custom_content_doc(), JSON_INSTRUCTION, False),
    ]

    results: dict[str, dict] = {}
    for key, label, doc, prompt, structured in arms:
        results[key] = _run_arm(
            client, label=label, doc=doc, prompt=prompt,
            structured=structured, model=model, max_tokens=max_tokens,
        )

    code = _report(results)

    out = Path(__file__).resolve().parent / "evidence" / "citations_json_coexist_result.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=2, ensure_ascii=False, default=str))
    logger.success("raw result → {}", out)
    raise typer.Exit(code)


if __name__ == "__main__":
    app()
