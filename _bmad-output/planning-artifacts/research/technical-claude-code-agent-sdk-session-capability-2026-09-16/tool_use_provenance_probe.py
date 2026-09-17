#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["typer>=0.12", "loguru>=0.7"]
# ///
"""Can a host record which files a session read, from the stream?

The vault-aware direction (decision record 2026-09-16) replaces Story 3.12's `glossary.json`
with a record of what the model actually consulted. That only works if `tool_use` blocks
reach the host with their arguments intact.

The reason this needs measuring rather than assuming is [P1]: `citations_delta` payloads are
recognized by Claude Code's accumulator and deliberately discarded, so the reassembled
assistant message shows an empty array while the raw stream carries the data. Two surfaces,
disagreeing, and only one correct. This probe checks BOTH surfaces for `tool_use` rather than
trusting either:

  assistant messages  -> message.content[] blocks of type tool_use, with a populated `input`
  stream events       -> content_block_start (tool_use) + input_json_delta fragments

A host that can read tool arguments off assistant messages needs no partial-message plumbing.
A host that can only get them from deltas inherits the citations problem a second time.

Runs on the ambient login — do NOT set ANTHROPIC_API_KEY, which wins over OAuth in -p mode.

Exit codes:
  0  a definite verdict on both surfaces
  1  probe could not run
  3  the session made no tool calls at all — inconclusive, retry with a firmer prompt
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import typer
from loguru import logger

app = typer.Typer(add_completion=False)
EXIT_OK, EXIT_ERROR, EXIT_INCONCLUSIVE = 0, 1, 3

NONCE = "1427"
PROMPT = (
    "Search the markdown files in this directory for the beacon frequency. "
    "Use Grep to locate it, then Read the file that contains it. "
    "Report the frequency in one short sentence."
)


def _run(cwd: str, timeout: int, prompt: str, model: str | None) -> tuple[list[dict], int, str]:
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--max-turns", "8",
        # Restrict the AVAILABLE set, then deny the mutating tools outright. Deny rules are
        # deny-first and an allow rule cannot carve an exception out of one, so this holds
        # even against a project settings file in the working directory that allows more.
        "--tools", "Read,Grep,Glob",
        "--allowedTools", "Read", "Grep", "Glob",
        "--disallowedTools", "Write", "Edit", "NotebookEdit", "Bash", "WebFetch", "WebSearch",
    ]
    if model:
        cmd += ["--model", model]
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
    typer.echo(f"  $ {' '.join(cmd)}")
    typer.echo(f"  cwd={cwd}  ANTHROPIC_API_KEY={'unset — subscription path' if 'ANTHROPIC_API_KEY' not in env else 'SET'}")

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
    msgs = []
    for line in proc.stdout.splitlines():
        if line := line.strip():
            try:
                msgs.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return msgs, proc.returncode, proc.stderr[:2000]


def _from_assistant_messages(msgs: list[dict]) -> list[dict]:
    """tool_use blocks as they appear on the reassembled assistant message."""
    out = []
    for m in msgs:
        if m.get("type") != "assistant":
            continue
        for b in m.get("message", {}).get("content") or []:
            if b.get("type") == "tool_use":
                out.append({"id": b.get("id"), "name": b.get("name"), "input": b.get("input")})
    return out


def _from_stream_events(msgs: list[dict]) -> tuple[list[dict], list[str]]:
    """tool_use openings and the input_json_delta fragments that fill them."""
    starts, frags = [], []
    for m in msgs:
        if m.get("type") != "stream_event":
            continue
        ev = m.get("event", {})
        if ev.get("type") == "content_block_start":
            cb = ev.get("content_block", {})
            if cb.get("type") == "tool_use":
                starts.append({"index": ev.get("index"), "name": cb.get("name"), "input": cb.get("input")})
        elif ev.get("type") == "content_block_delta":
            d = ev.get("delta", {})
            if d.get("type") == "input_json_delta":
                frags.append(d.get("partial_json", ""))
    return starts, frags


@app.command()
def main(
    cwd: str = typer.Option(..., "--cwd", help="Directory to run the session in"),
    timeout: int = typer.Option(300, "--timeout"),
    prompt: str = typer.Option(PROMPT, "--prompt", help="Override the fixture prompt"),
    model: str = typer.Option("", "--model", help="Pin the model; empty lets the session choose"),
    out_dir: str = typer.Option("", "--out-dir", help="Where to write raw output. Default: evidence/. "
                                                     "Point this OUTSIDE the repo for runs over private data."),
    redact: str = typer.Option("", "--redact", help="Replace this path prefix with <redacted> in the summary"),
) -> None:
    """Do tool_use blocks reach a host with their arguments, and on which surface?"""
    logger.remove(); logger.add(sys.stderr, level="INFO")

    if os.environ.get("ANTHROPIC_API_KEY"):
        logger.warning("ANTHROPIC_API_KEY is set in this shell; the probe strips it from the child env")

    typer.echo("=" * 78); typer.echo("RUN"); typer.echo("=" * 78)
    try:
        msgs, code, err = _run(cwd, timeout, prompt, model or None)
    except subprocess.TimeoutExpired:
        logger.error("timed out after {}s", timeout); raise typer.Exit(EXIT_ERROR)

    result = next((m for m in msgs if m.get("type") == "result"), None)
    typer.echo(f"\n  exit code   : {code}")
    typer.echo(f"  messages    : {len(msgs)}")
    if result:
        typer.echo(f"  is_error    : {result.get('is_error')}")
        typer.echo(f"  terminal    : {result.get('terminal_reason')}")
        typer.echo(f"  num_turns   : {result.get('num_turns')}")
        typer.echo(f"  cost (est.) : {result.get('total_cost_usd')}")
        typer.echo(f"  result      : {str(result.get('result'))[:180]}")
    if code != 0 or (result and result.get("is_error")):
        logger.error("session failed; stderr: {}", err[:400]); raise typer.Exit(EXIT_ERROR)

    am = _from_assistant_messages(msgs)
    starts, frags = _from_stream_events(msgs)

    typer.echo(f"\n{'=' * 78}\nSURFACE 1 — assistant messages\n{'=' * 78}")
    typer.echo(f"  tool_use blocks : {len(am)}")
    for t in am:
        populated = isinstance(t["input"], dict) and bool(t["input"])
        typer.echo(f"    {'OK  ' if populated else 'EMPTY'} {t['name']:<8} input={json.dumps(t['input'], ensure_ascii=False)[:120]}")

    typer.echo(f"\n{'=' * 78}\nSURFACE 2 — stream events\n{'=' * 78}")
    typer.echo(f"  content_block_start (tool_use) : {len(starts)}")
    for s in starts:
        typer.echo(f"    idx={s['index']} name={s['name']} opening_input={json.dumps(s['input'], ensure_ascii=False)[:80]}")
    typer.echo(f"  input_json_delta fragments     : {len(frags)}")
    if frags:
        typer.echo(f"    reassembled: {''.join(frags)[:200]}")

    typer.echo(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if not am and not starts:
        typer.echo("NO TOOL CALLS — inconclusive. The model answered without reading. Retry.")
        _save(msgs, am, starts, frags, verdict="no_tool_calls", out_dir=out_dir, redact=redact)
        raise typer.Exit(EXIT_INCONCLUSIVE)

    populated = [t for t in am if isinstance(t["input"], dict) and t["input"]]
    read_paths = sorted({
        t["input"].get("file_path") or t["input"].get("path") or t["input"].get("pattern", "")
        for t in populated
    } - {""})

    if len(populated) == len(am) and am:
        typer.echo("ASSISTANT MESSAGES CARRY FULL TOOL ARGUMENTS.")
        typer.echo("  -> A host needs no partial-message plumbing. This does NOT repeat the")
        typer.echo("     citations situation: the simple surface is the correct one.")
        typer.echo(f"  -> files/patterns recoverable: {read_paths}")
        typer.echo("  -> The wedge-validation metric survives vault-reading, on a better record")
        typer.echo("     than glossary.json: what the model consulted, not what auricle offered.")
        verdict = "assistant_surface_complete"
    elif starts or frags:
        typer.echo("*** ASSISTANT MESSAGES ARE INCOMPLETE — arguments only in the deltas. ***")
        typer.echo("  -> This IS the citations situation again. A host must consume")
        typer.echo("     --include-partial-messages and reassemble input_json_delta itself.")
        verdict = "delta_only"
    else:
        typer.echo("INCONCLUSIVE — tool calls present but neither surface carried arguments.")
        verdict = "neither"

    nonce_found = NONCE in json.dumps(msgs)
    typer.echo(f"\n  nonce {NONCE} present in stream: {nonce_found} "
               f"({'model genuinely read the fixture' if nonce_found else 'WARNING: may not have read'})")

    _save(msgs, am, starts, frags, verdict=verdict, out_dir=out_dir, redact=redact)
    raise typer.Exit(EXIT_OK)


def _save(msgs, am, starts, frags, *, verdict: str, out_dir: str = "", redact: str = "") -> None:
    ev = Path(out_dir) if out_dir else Path(__file__).resolve().parent / "evidence"
    ev.mkdir(parents=True, exist_ok=True)
    if redact:
        am = json.loads(json.dumps(am).replace(redact, "<vault>"))
    (ev / "tool_use_provenance_result.json").write_text(json.dumps({
        "verdict": verdict,
        "assistant_surface_tool_use": am,
        "stream_content_block_start": starts,
        "input_json_delta_fragment_count": len(frags),
        "input_json_delta_reassembled": "".join(frags),
    }, indent=2, ensure_ascii=False))
    (ev / "tool_use_provenance_stream.jsonl").write_text("\n".join(json.dumps(m, ensure_ascii=False) for m in msgs))
    logger.success("raw stream → {}", ev / "tool_use_provenance_stream.jsonl")


if __name__ == "__main__":
    app()
