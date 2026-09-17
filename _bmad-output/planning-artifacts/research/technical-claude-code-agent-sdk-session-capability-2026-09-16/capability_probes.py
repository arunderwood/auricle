#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "typer>=0.12",
#   "loguru>=0.7",
#   "reportlab>=4.0",
# ]
# ///
"""The remaining doc-silent questions that a live session can actually answer.

Closes open questions 4, 5 and 8 from research.md. Each is a case where the documentation says
nothing in either direction and the behavior is observable, so the honest move is to measure it
rather than reason about it.

  E1  Does a session's ``outputFormat`` hit the same citations 400 as ``output_config.format``?
      The Messages API documents citations and structured outputs as mutually exclusive, with a
      400. But a session implements schema output as an END-TURN TOOL, not as
      ``output_config.format`` (per the shipped .d.ts), so the documented constraint does not
      obviously transfer. If it does not, a host can have schema-constrained output AND
      grounded citations in one call — which the direct API forbids.

  E2  Do PDF (``page_location``) and custom content (``content_block_location``) traverse a
      session the way plain text (``char_location``) does? Only plain text was exercised by
      [P1]/[P2].

  E3  Does the session's end-turn-tool structured output inherit the Messages API's documented
      schema limitations (no ``minLength``, no recursive ``$ref``, ...)? Three outcomes per
      limitation: rejected up front, accepted and enforced, or accepted and silently ignored.
      The third is the dangerous one, because it looks like it works.

Everything here is measured behavior, not documented contract. Same caveat as [P1]-[P4]:
undocumented behavior can change without a release note.

Exit codes:
  0  all experiments produced a reading
  1  could not run (no CLI, session error)
  3  at least one experiment was inconclusive
"""

from __future__ import annotations

import base64
import io
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import typer
from loguru import logger

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_common as pc  # noqa: E402

app = typer.Typer(add_completion=False)
EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3

SCHEMA_OK = {
    "type": "object",
    "properties": {"frequency_hz": {"type": "integer"}, "source_quote": {"type": "string"}},
    "required": ["frequency_hz", "source_quote"],
    "additionalProperties": False,
}


def _doc_block(doc: str) -> dict:
    return {
        "type": "document",
        "source": {"type": "text", "media_type": "text/plain", "data": doc},
        "title": "Beacon field log",
        "citations": {"enabled": True},
    }


def _make_pdf(text: str) -> str:
    """A one-page PDF with extractable text, base64-encoded."""
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=letter)
    y = 720
    for line in text.split(". "):
        if line.strip():
            c.drawString(72, y, line.strip() + ".")
            y -= 24
    c.showPage()
    c.save()
    return base64.b64encode(buf.getvalue()).decode()


# --------------------------------------------------------------------------- experiments


def e1_structured_plus_citations(cwd: str, timeout: int) -> dict:
    """E1 — schema-constrained output together with an enabled-citations document."""
    typer.echo(f"\n{'=' * 78}\nE1 — outputFormat + citations in one session\n{'=' * 78}")
    doc = pc.document(pc.PREFIX_NFC)

    run = pc.run_claude_session(
        [_doc_block(doc), {"type": "text", "text": pc.QUESTION}],
        cwd=cwd,
        extra_args=["--json-schema", json.dumps(SCHEMA_OK)],
        timeout=timeout,
    )
    if run["timeout"]:
        return {"verdict": "TIMEOUT"}

    err = pc.session_error(run["messages"])
    res = pc.result_message(run["messages"]) or {}
    cits = pc.citations_from_stream(run["messages"])
    structured = res.get("structured_output")

    typer.echo(f"  session error     : {err}")
    typer.echo(f"  structured_output : {json.dumps(structured)}")
    typer.echo(f"  citations in stream: {len(cits)}")
    for c in cits:
        typer.echo(f"    type={c.get('type')} start={c.get('start_char_index')} end={c.get('end_char_index')}")

    blob = json.dumps(res).lower()
    if err and ("400" in blob or "citation" in blob):
        verdict = "SAME CONSTRAINT APPLIES — the session surfaced the incompatibility"
    elif err:
        verdict = f"ERRORED, but not obviously the citations constraint: {err}"
    elif structured and cits:
        verdict = "SESSION SIDESTEPS IT — schema-constrained output AND citations in one call"
    elif structured and not cits:
        verdict = "STRUCTURED OK, CITATIONS SUPPRESSED — no 400, but no citation deltas either"
    else:
        verdict = "INCONCLUSIVE — no error and no structured output"

    typer.echo(f"\n  VERDICT: {verdict}")
    return {"verdict": verdict, "error": err, "structured_output": structured,
            "citation_count": len(cits), "citations": cits}


def e2_location_types(cwd: str, timeout: int) -> dict:
    """E2 — do PDF and custom-content documents yield their documented location types?"""
    typer.echo(f"\n{'=' * 78}\nE2 — location types: PDF and custom content\n{'=' * 78}")
    plain = pc.document(pc.PREFIX_NFC)
    out: dict[str, dict] = {}

    cases = {
        "pdf (expect page_location)": {
            "type": "document",
            "source": {"type": "base64", "media_type": "application/pdf", "data": _make_pdf(plain)},
            "title": "Beacon field log (PDF)",
            "citations": {"enabled": True},
        },
        "custom content (expect content_block_location)": {
            "type": "document",
            "source": {
                "type": "content",
                "content": [
                    {"type": "text", "text": pc.PREFIX_NFC},
                    {"type": "text", "text": pc.TARGET},
                    {"type": "text", "text": pc.TAIL},
                ],
            },
            "title": "Beacon field log (blocks)",
            "citations": {"enabled": True},
        },
    }

    for label, block in cases.items():
        typer.echo(f"\n  --- {label} ---")
        run = pc.run_claude_session(
            [block, {"type": "text", "text": pc.QUESTION}], cwd=cwd, timeout=timeout
        )
        if run["timeout"]:
            out[label] = {"verdict": "TIMEOUT"}
            continue

        err = pc.session_error(run["messages"])
        cits = pc.citations_from_stream(run["messages"])
        answered = pc.NONCE in pc.assistant_text(run["messages"])

        typer.echo(f"    error       : {err}")
        typer.echo(f"    answered    : {answered}")
        typer.echo(f"    citations   : {len(cits)}")
        for c in cits:
            keys = {k: v for k, v in c.items() if k != "cited_text"}
            typer.echo(f"      {json.dumps(keys)}")
            typer.echo(f"      cited_text={str(c.get('cited_text'))[:70]!r}")

        types = sorted({c.get("type") for c in cits})
        if err:
            verdict = f"ERRORED: {err[:120]}"
        elif cits:
            verdict = f"citations returned, location type(s): {types}"
        elif answered:
            verdict = "document reached the model, but no citation deltas"
        else:
            verdict = "INCONCLUSIVE — no answer and no citations"
        typer.echo(f"    VERDICT: {verdict}")
        out[label] = {"verdict": verdict, "types": types, "citations": cits,
                      "answered": answered, "error": err}

    return out


def e3_schema_limits(cwd: str, timeout: int) -> dict:
    """E3 — are the Messages API's documented schema limitations enforced by a session?"""
    typer.echo(f"\n{'=' * 78}\nE3 — schema limitations\n{'=' * 78}")

    cases = {
        "minLength (documented unsupported)": {
            "schema": {
                "type": "object",
                "properties": {"code": {"type": "string", "minLength": 40}},
                "required": ["code"],
                "additionalProperties": False,
            },
            "prompt": "Return a field `code` set to the single letter 'x'. Nothing else.",
            "check": lambda v: (
                "ENFORCED (value respects minLength)" if isinstance(v, dict)
                and isinstance(v.get("code"), str) and len(v["code"]) >= 40
                else "ACCEPTED BUT NOT ENFORCED (short value came back)"
            ),
        },
        "recursive $ref (documented unsupported)": {
            "schema": {
                "type": "object",
                "properties": {"node": {"$ref": "#/$defs/node"}},
                "required": ["node"],
                "additionalProperties": False,
                "$defs": {
                    "node": {
                        "type": "object",
                        "properties": {"name": {"type": "string"},
                                       "child": {"$ref": "#/$defs/node"}},
                        "required": ["name"],
                        "additionalProperties": False,
                    }
                },
            },
            "prompt": "Return a node named 'root' with a child named 'leaf'.",
            "check": lambda v: "ACCEPTED (recursive schema produced output)",
        },
    }

    out: dict[str, dict] = {}
    for label, case in cases.items():
        typer.echo(f"\n  --- {label} ---")
        run = pc.run_claude_session(
            [{"type": "text", "text": case["prompt"]}],
            cwd=cwd,
            extra_args=["--json-schema", json.dumps(case["schema"])],
            timeout=timeout,
            # Schema retries consume turns; 1 turn misreads a retry loop as error_max_turns.
            max_turns=5,
        )
        if run["timeout"]:
            out[label] = {"verdict": "TIMEOUT"}
            continue

        err = pc.session_error(run["messages"])
        res = pc.result_message(run["messages"]) or {}
        structured = res.get("structured_output")

        typer.echo(f"    exit_code        : {run['exit_code']}")
        typer.echo(f"    stderr           : {run['stderr'].strip()[:200]!r}")
        typer.echo(f"    error            : {err}")
        typer.echo(f"    structured_output: {json.dumps(structured)}")

        if run["exit_code"] != 0 and "json-schema" in (run["stderr"] or "").lower():
            verdict = "REJECTED UP FRONT by the CLI schema validator"
        elif err:
            verdict = f"SESSION ERROR: {err[:140]}"
        elif structured is not None:
            verdict = case["check"](structured)
        else:
            verdict = "INCONCLUSIVE — no error, no structured output"

        typer.echo(f"    VERDICT: {verdict}")
        out[label] = {"verdict": verdict, "structured_output": structured,
                      "error": err, "stderr": run["stderr"][:500]}

    return out


@app.command()
def main(
    timeout: int = typer.Option(240, "--timeout", "-t"),
    only: str = typer.Option(None, "--only", help="Run one experiment: e1, e2 or e3"),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
) -> None:
    """Measure the remaining doc-silent session behaviors."""
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")

    if not shutil.which("claude"):
        logger.error("`claude` not found on PATH")
        raise typer.Exit(EXIT_ERROR)

    version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    logger.info("CLI: {}", version)
    logger.info("all output below is MEASURED BEHAVIOR, not documented contract")

    results: dict = {"cli_version": version}
    with tempfile.TemporaryDirectory() as tmp:
        if only in (None, "e1"):
            results["e1_structured_plus_citations"] = e1_structured_plus_citations(tmp, timeout)
        if only in (None, "e2"):
            results["e2_location_types"] = e2_location_types(tmp, timeout)
        if only in (None, "e3"):
            results["e3_schema_limits"] = e3_schema_limits(tmp, timeout)

    out = Path(__file__).resolve().parent / "evidence" / "capability_probes_result.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    logger.success("raw result → {}", out)

    blob = json.dumps(results)
    raise typer.Exit(EXIT_INCONCLUSIVE if ("INCONCLUSIVE" in blob or "TIMEOUT" in blob) else EXIT_OK)


if __name__ == "__main__":
    app()
