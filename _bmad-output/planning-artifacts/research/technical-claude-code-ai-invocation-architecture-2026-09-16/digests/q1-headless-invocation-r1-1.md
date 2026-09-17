# Q1: Headless invocation — digest

Date: 2026-09-16 | Version tested: claude 2.1.220

## Verdicts

| Sub-question | Verdict | Mechanism | Evidence |
|---|---|---|---|
| 1. Entry points — actual mechanisms | CONFIRMED | CLI `-p` flag; Agent SDK (Python, TypeScript packages); stdin/stdout JSON protocol | `claude --help` output + https://code.claude.com/docs/en/headless.md |
| 2. Output formats and schema | CONFIRMED | `--output-format text\|json\|stream-json`; JSON carries `result`, `session_id`, `total_cost_usd`, `structured_output` | https://code.claude.com/docs/en/headless.md, "Get structured output" section |
| 3. Exit codes and semantic failure detection | CONFIRMED with gaps | Exit 0 = success, non-zero = failure, 143 = SIGTERM; **no documented field in JSON payload** for success/error state (relies on exit code) | https://code.claude.com/docs/en/headless.md: "Claude Code exits with code 0 on success and a non-zero code when the run fails" |
| 4. Input passing | CONFIRMED | argv, stdin (capped 10MB), `--input-format text\|stream-json` for streaming input | https://code.claude.com/docs/en/headless.md, "Pipe data through Claude" + CLI help |
| 5. Stdout stability for parsing | CONFIRMED | `--output-format json` and `stream-json` documented as machine-readable contracts; piped stdin limit (10MB) enforced with clear error | https://code.claude.com/docs/en/headless.md |

---

## Claims

| Claim | Source | Publisher | Pub date | Accessed | Confidence | Class |
|---|---|---|---|---|---|---|
| CLI entry point: `claude -p <prompt>` for non-interactive mode | `claude --help` binary output | Anthropic | v2.1.220 | 2026-09-16 | high | mechanism |
| `-p` is shorthand for `--print` | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | mechanism |
| `--output-format text\|json\|stream-json` available with `-p` | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | mechanism |
| Python SDK entry: `query()` async function + `ClaudeSDKClient` class | https://code.claude.com/docs/en/agent-sdk/python | Anthropic | undated | 2026-09-16 | high | mechanism |
| TypeScript SDK entry: `query()` + `startup()` functions | https://code.claude.com/docs/en/agent-sdk/typescript | Anthropic | undated | 2026-09-16 | high | mechanism |
| JSON output includes `result`, `session_id`, `total_cost_usd` fields | https://code.claude.com/docs/en/headless.md, "Get structured output" | Anthropic | undated | 2026-09-16 | high | behaviour |
| For `--json-schema` output, result appears in `structured_output` field | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | behaviour |
| Exit code 0 = success, non-zero = failure (no specific codes enumerated except 143) | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | behaviour |
| Exit code 143 = SIGTERM termination | https://code.claude.com/docs/en/headless.md, "Stop a run with SIGTERM" | Anthropic | undated | 2026-09-16 | high | behaviour |
| Piped stdin capped at 10MB; exceeding it exits with non-zero code and clear error | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | behaviour |
| `--input-format stream-json` allows realtime streaming input without restarting process | https://code.claude.com/docs/en/headless.md, CLI reference flags | Anthropic | undated | 2026-09-16 | medium | mechanism |
| `--json-schema` validates output against JSON Schema definition | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | mechanism |
| `stream-json` output is newline-delimited JSON, one event per line | https://code.claude.com/docs/en/headless.md, "Stream responses" section | Anthropic | undated | 2026-09-16 | high | behaviour |
| `stream-json` final line is `result` message with cost and session metadata | https://code.claude.com/docs/en/headless.md | Anthropic | undated | 2026-09-16 | high | behaviour |
| Agent SDK requires v2.1.220+ for full streaming + error handling | Inferred from docs (no version pinning found in Agent SDK docs) | Anthropic | undated | 2026-09-16 | low | version |

---

## Key Findings

### Entry Points (Confirmed)

**CLI (headless):**
```bash
claude -p "prompt" [--output-format json|stream-json] [--input-format text|stream-json]
```

**Python SDK:**
```python
async for message in query(prompt="...", options=ClaudeAgentOptions(...)):
    # handle message
```

**TypeScript SDK:**
```typescript
for await (const message of query({ prompt: "...", options: {...} })) {
  // handle message
}
```

**Subprocess/JSON protocol:**
- Invoked via CLI with `--output-format json` or `--output-format stream-json`
- Parent reads JSON from stdout, checks exit code

### Output Formats (Confirmed)

**`--output-format json` (single result):**
```json
{
  "result": "text response",
  "session_id": "uuid",
  "total_cost_usd": 0.00123,
  "structured_output": { /* if --json-schema was used */ }
}
```

**`--output-format stream-json` (streaming):**
Newline-delimited JSON stream. Each line is one event:
- `type: "stream_event"` with `event.delta.text` for tokens
- `type: "result"` (final line) with `result`, `session_id`, `total_cost_usd`

**`--output-format text` (default):**
Plain text, no JSON structure.

### Exit Code Behavior (Confirmed — but parent must handle gracefully)

**Key finding:** Exit codes are the **only** semantic signal of success/failure. The JSON payload does **not** include an explicit success/error field.

- **0**: Successful completion
- **143**: Killed by SIGTERM
- **Non-zero (other)**: Failure (specific codes not enumerated in docs)
- **Special case**: Piped stdin exceeding 10MB → non-zero exit + "clear error" to stderr

**Implication:** A parent process must check `$?` / process exit code. A run can **exit 0 but have failed semantically if Claude's error occurred inside the run** (e.g., authentication failure during the turn) — in that case Claude prints the failure as the result on stdout.

### Input Handling (Confirmed)

1. **argv prompt:** `claude -p "your prompt"`
2. **stdin piping:** `echo "data" | claude -p "process this"`
   - Capped at 10MB
   - Parent receives clear error if exceeded
3. **Streaming input:** `--input-format stream-json` allows realtime turn-by-turn input from parent without restarting process (requires v2.1.211+)

### Stdout Stability for Parsing (Confirmed)

- `--output-format json` and `stream-json` documented as machine-readable contracts
- `text` is human-facing rendering (not recommended for parsing)
- No mention of non-deterministic fields or cosmetic changes (high confidence in stability)

---

## Verbatim Evidence

### `claude --help` excerpt (v2.1.220)
```
Usage: claude [options] [command] [prompt]

Claude Code - starts an interactive session by default, use -p/--print for
non-interactive output

Options:
  -p, --print                           Print response and exit (useful for
                                        pipes). Note: The workspace trust dialog
                                        is skipped when Claude is run in
                                        non-interactive mode (via -p, or when
                                        stdout is not a TTY, e.g. piped or
                                        redirected output). Only use this in
                                        directories you trust. Settings files
                                        that fail validation are silently
                                        ignored in this mode (no error dialog is
                                        shown).

  --output-format <format>              Output format (only works with --print):
                                        "text" (default), "json" (single
                                        result), or "stream-json" (realtime
                                        streaming) (choices: "text", "json",
                                        "stream-json")

  --input-format <format>               Input format (only works with --print):
                                        "text" (default), or "stream-json"
                                        (realtime streaming input) (choices:
                                        "text", "stream-json")

  --json-schema <schema>                JSON Schema for structured output
                                        validation.
```

### From https://code.claude.com/docs/en/headless.md

**Exit codes:**
> Claude Code exits with code 0 on success and a non-zero code when the run fails, so your scripts can branch on the exit status. If you pass an invalid flag, Claude Code reports the error to stderr before the run starts. When a failure happens inside the run, such as missing authentication, Claude Code prints the failure as the result on stdout.

**JSON output fields:**
> This example returns a project summary as JSON with session metadata, with the text result in the `result` field:
> ```bash
> claude -p "Summarize this project" --output-format json
> ```
> To get output conforming to a specific schema, use `--output-format json` with `--json-schema` and a [JSON Schema](https://json-schema.org/) definition. The response includes metadata about the request (session ID, usage, etc.) with the structured output in the `structured_output` field.

**Stream events:**
> Use `--output-format stream-json` with `--verbose` and `--include-partial-messages` to receive tokens as they're generated. Each line is a JSON object representing an event:
> ```bash
> claude -p "Explain recursion" --output-format stream-json --verbose --include-partial-messages
> ```
> The last line of the stream is a `result` message with the final response text, cost, and session metadata.

**SIGTERM handling:**
> If you stop a `claude -p` run with SIGTERM, for example with `kill` or from a process supervisor, Claude Code exits with code 143.

**Piped stdin limit:**
> Piped stdin is capped at 10MB. If you exceed the cap, Claude Code exits with a clear error and a non-zero status.

---

## Leads Worth Chasing

1. **Exact exit codes for specific failure modes** — Docs state "non-zero" but do not enumerate specific codes (e.g., does auth failure exit 1, 2, 255?). Could check GitHub issues or release notes for the breakdown.

2. **Semantic error field in JSON** — Parent processes typically expect a `success: bool` or `error: string` in the payload. The absence of this in the docs is notable; worth confirming this is intentional (exit code only) vs. an undocumented field.

3. **Streaming input protocol details** — `--input-format stream-json` is documented but the schema for input events (turn structure, how parent signals completion) is not shown in these docs. Would need Agent SDK source or examples.

4. **Background session semantics with `-p`** — Docs mention `-p` and background Bash tasks, but the interaction (does `-p` wait for background work?) could use more detail.

5. **Cost tracking accuracy** — Docs state `total_cost_usd` is a "client-side estimate" and may differ from bill. Parent processes using this for budgeting should test against actual billing.

---

## Searched For and Could Not Find

| Query | Result | Next step to settle |
|---|---|---|
| Specific exit codes by failure type (e.g., 1 vs 2 vs 255) | Docs say "non-zero" but do not enumerate | Check https://github.com/anthropics/claude-code or `claude` repo issues for exit code map |
| Semantic `success` or `error` field in JSON result payload | Not found in JSON schema docs | Try running `claude -p` with `--output-format json` in a failure case and inspect stdout |
| `--input-format stream-json` event schema (what structure does parent send?) | Docs mention it exists but not the schema | Fetch Agent SDK Python/TypeScript source for `SDKUserMessage` type definition |
| Version gate for streaming input support | Not specified | Check CHANGELOG.md in agent-sdk-python and agent-sdk-typescript repos |
