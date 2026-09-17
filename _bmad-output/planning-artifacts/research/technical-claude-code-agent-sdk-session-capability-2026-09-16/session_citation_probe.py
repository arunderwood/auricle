#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "typer>=0.12",
#   "loguru>=0.7",
# ]
# ///
"""Does a Claude Code session forward a citations-enabled document block, and return citations?

Answers open question #1 from research.md (same directory).

What the research established, and why this probe exists:

  - ``SDKUserMessage.message`` is typed as an Anthropic ``MessageParam``, whose shipped JSDoc
    names ``document`` among permitted block types. The input type PERMITS a citations-enabled
    document.
  - But the SDK's own type surface contains no citations feature: zero genuine ``citation``
    identifiers in ``sdk.d.ts``, and the single hit in ``sdk-tools.d.ts`` is an untyped
    ``unknown[]`` on the Agent tool's report.
  - No documentation states the end-to-end behavior in either direction.

Type-permitted is not the same as supported. Only a live session settles it.

This drives the CLI rather than the TypeScript SDK deliberately: a Swift host cannot import the
TS or Python SDK, so ``claude --input-format stream-json`` is the surface it would actually use.

FOUR OUTCOMES, not two. The control run is what makes them distinguishable:

  run 1 (document block, citations on)      run 2 (control: same text, plain text block)
  ----------------------------------------  --------------------------------------------
  answers with nonce + citations present -> FULL PASS-THROUGH
  answers with nonce, no citations       -> DOCUMENT FORWARDED, CITATIONS NOT SURFACED
  no nonce, control answers              -> DOCUMENT BLOCK DROPPED BY THE HARNESS
  no nonce, control also fails           -> PROBE INVALID (not a finding about citations)

Exit codes:
  0  conclusive verdict reached
  1  probe could not run (no CLI, timeout, session error)
  3  probe ran but the control failed, so no conclusion is warranted
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import typer
from loguru import logger

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_common as pc  # noqa: E402

app = typer.Typer(add_completion=False)

EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3


def _user_message(content: list[dict]) -> str:
    return json.dumps(
        {"type": "user", "message": {"role": "user", "content": content}, "parent_tool_use_id": None}
    )


def _doc_block_content(doc: str) -> list[dict]:
    return [
        {
            "type": "document",
            "source": {"type": "text", "media_type": "text/plain", "data": doc},
            "title": "Beacon field log",
            "citations": {"enabled": True},
        },
        {"type": "text", "text": pc.QUESTION},
    ]


def _control_content(doc: str) -> list[dict]:
    return [{"type": "text", "text": f"<document>\n{doc}\n</document>\n\n{pc.QUESTION}"}]


def _run_session(label: str, content: list[dict], cwd: Path, timeout: int) -> dict:
    """Drive one ``claude -p`` session over stream-json and collect every emitted message."""
    cmd = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--max-turns", "1",
    ]
    logger.info("{} — $ {}", label, " ".join(cmd))

    try:
        proc = subprocess.run(
            cmd,
            input=_user_message(content) + "\n",
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        logger.error("{} timed out after {}s", label, timeout)
        return {"label": label, "timeout": True, "messages": [], "unparsed": []}

    messages, unparsed = [], []
    for line in proc.stdout.splitlines():
        if not (line := line.strip()):
            continue
        try:
            messages.append(json.loads(line))
        except json.JSONDecodeError:
            unparsed.append(line)

    logger.info("{} — exit={} messages={} unparsed={}", label, proc.returncode, len(messages), len(unparsed))
    if proc.returncode != 0:
        logger.warning("stderr: {}", proc.stderr.strip()[:600])
    for u in unparsed[:3]:
        logger.warning("unparsed line: {}", u[:200])

    return {
        "label": label,
        "exit_code": proc.returncode,
        "stderr": proc.stderr[:4000],
        "messages": messages,
        "unparsed": unparsed,
    }


def _analyze(run: dict) -> dict:
    """Extract the three signals: did it answer, did citations arrive, what usage came back."""
    answer_text: list[str] = []
    citations: list[dict] = []
    errors: list[str] = []
    usage_report: dict = {}

    for msg in run.get("messages", []):
        mtype = msg.get("type")

        if mtype == "assistant":
            inner = msg.get("message", {})
            for block in inner.get("content") or []:
                if block.get("type") == "text":
                    answer_text.append(block.get("text", ""))
                    citations.extend(block.get("citations") or [])
            if inner.get("usage"):
                usage_report.setdefault("assistant_usage_seen", inner["usage"])

        elif mtype == "result":
            usage_report |= {
                "subtype": msg.get("subtype"),
                "total_cost_usd": msg.get("total_cost_usd"),
                "usage": msg.get("usage"),
                "modelUsage": msg.get("modelUsage"),
            }
            if msg.get("subtype") not in (None, "success"):
                errors.append(f"result subtype={msg.get('subtype')}")
            if msg.get("is_error"):
                errors.append(f"result is_error stop_reason={msg.get('stop_reason')}")

        elif mtype == "system" and msg.get("subtype") == "api_retry":
            errors.append(f"api_retry attempt={msg.get('attempt')} error={msg.get('error')}")

    joined = "\n".join(answer_text)
    return {
        "answered_with_nonce": pc.NONCE in joined,
        "answer_excerpt": joined.strip()[:400],
        "citation_count": len(citations),
        "citations": citations,
        "errors": errors,
        "usage_report": usage_report,
    }


def _report_verdict(a_doc: dict, a_ctl: dict, doc: str) -> int:
    typer.echo("\n" + "=" * 78)
    typer.echo("VERDICT — open question #1: does a session pass citations through?")
    typer.echo("=" * 78)

    if not a_ctl["answered_with_nonce"] and not a_doc["answered_with_nonce"]:
        typer.echo("PROBE INVALID — the control also failed to answer.")
        typer.echo("  Not a finding about citations. Check the model, prompt, or credential first.")
        return EXIT_INCONCLUSIVE

    if a_doc["citation_count"] > 0:
        typer.echo("FULL PASS-THROUGH — the session forwarded the citations-enabled document")
        typer.echo("  AND surfaced citation objects to the host.")
        for cit in a_doc["citations"]:
            start, end = cit.get("start_char_index"), cit.get("end_char_index")
            typer.echo(f"    type={cit.get('type')} start={start} end={end}")
            typer.echo(f"    cited_text={str(cit.get('cited_text'))[:70]!r}")
            if cit.get("type") == "char_location" and start is not None and end is not None:
                units = pc.matching_units(doc, start, end, cit.get("cited_text", ""))
                typer.echo(f"    encoding unit whose slice reproduces cited_text: {units or 'NONE'}")
        typer.echo(f"\n  prefix candidate offsets: {pc.counts(pc.PREFIX_NFC)}")
        typer.echo("  (same document as citation_offset_probe.py — offsets directly comparable)")
        return EXIT_OK

    if a_doc["answered_with_nonce"]:
        typer.echo("DOCUMENT FORWARDED, CITATIONS NOT SURFACED — the model answered from the")
        typer.echo("  document's content, so the block reached it, but no citation object reached")
        typer.echo("  the host. Citations are either not enabled downstream or stripped on output.")
        return EXIT_OK

    typer.echo("DOCUMENT BLOCK DROPPED — the control answered but this run did not, so the")
    typer.echo("  document block's content never reached the model.")
    return EXIT_OK


@app.command()
def main(
    timeout: int = typer.Option(180, "--timeout", "-t", help="Per-session timeout in seconds"),
    keep_cwd: Path = typer.Option(
        None, "--cwd", help="Run sessions here instead of a clean temp dir (loads that project's config)"
    ),
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Show debug logging"),
) -> None:
    """Probe whether a Claude Code session passes citations end to end."""
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")

    if not shutil.which("claude"):
        logger.error("`claude` not found on PATH")
        raise typer.Exit(EXIT_ERROR)

    version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    doc = pc.document(pc.PREFIX_NFC)

    logger.info("CLI: {}", version)
    logger.info("document: {} codepoints, nonce={!r}", len(doc), pc.NONCE)
    logger.info("prefix candidate offsets: {}", pc.counts(pc.PREFIX_NFC))
    logger.info(
        "credential comes from whatever Claude Code already uses; --bare is deliberately NOT "
        "passed, since bare mode refuses OAuth and would force an API key"
    )

    import tempfile

    if keep_cwd:
        run_doc = _run_session("RUN 1 document-block", _doc_block_content(doc), keep_cwd, timeout)
        run_ctl = _run_session("RUN 2 control", _control_content(doc), keep_cwd, timeout)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp)
            logger.info("running in a clean temp cwd — no project CLAUDE.md, .mcp.json or .claude/")
            run_doc = _run_session("RUN 1 document-block", _doc_block_content(doc), cwd, timeout)
            run_ctl = _run_session("RUN 2 control", _control_content(doc), cwd, timeout)

    if run_doc.get("timeout") or run_ctl.get("timeout"):
        logger.error("a session timed out; no verdict")
        raise typer.Exit(EXIT_ERROR)

    a_doc, a_ctl = _analyze(run_doc), _analyze(run_ctl)

    for name, a in (("RUN 1 (document block)", a_doc), ("RUN 2 (control)", a_ctl)):
        typer.echo(f"\n--- {name} ---")
        typer.echo(f"  answered with nonce : {a['answered_with_nonce']}")
        typer.echo(f"  citations returned  : {a['citation_count']}")
        if a["errors"]:
            typer.echo(f"  errors              : {a['errors']}")
        typer.echo(f"  answer              : {a['answer_excerpt'][:200]!r}")

    code = _report_verdict(a_doc, a_ctl, doc)

    # Bonus: this CLI may predate fields the research documented as version-gated.
    mu = a_doc["usage_report"].get("modelUsage") or {}
    typer.echo(f"\n--- version-gated field check (CLI {version}) ---")
    if mu:
        for model, u in mu.items():
            typer.echo(
                f"  {model}: thinkingTokens={'thinkingTokens' in u} "
                f"costBasis={'costBasis' in u}"
            )
            typer.echo(f"    keys: {sorted(u)}")
    else:
        typer.echo("  no modelUsage on the result message")

    out = Path(__file__).resolve().parent / "evidence" / "session_citation_probe_result.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "cli_version": version,
                "runs": [run_doc, run_ctl],
                "analysis": {"document_block": a_doc, "control": a_ctl},
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    logger.success("raw result → {}", out)
    raise typer.Exit(code)


if __name__ == "__main__":
    app()
