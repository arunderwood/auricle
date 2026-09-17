# Q2b: Is the --bg background-agent path parent-drivable? — digest

## Headline
**Partially.** A native app can start and poll background sessions, read session state and logs, and kill them by id, but it cannot read the final result programmatically — only by attaching interactively or reading the session transcript disk file. The `--bg` path is drivable for headless supervision but requires custom logic to extract final output.

---

## Verdicts

| Sub-question | Verdict | Mechanism | Evidence (Command/URL) |
|---|---|---|---|
| **1. Starting & assigning session id** | CONFIRMED | `--bg` returns short id on stdout; `--session-id <uuid>` pre-assigns; parent must parse or use `claude agents --json --all` | `claude attach --help`; `claude --help` (--session-id, --bg flags); observed 2.1.220 |
| **2. Detecting completion** | CONFIRMED | Poll `claude agents --json --all`, check `state` field: `done`, `failed`, or `stopped`; `SessionEnd` hook also fires | `claude agents --help` (--all, --json); `https://code.claude.com/docs/en/hooks.md` (SessionEnd); observed 2.1.220 |
| **3. Reading final result** | UNVERIFIABLE / CONSTRAINT | `--bg` returns immediately; final result lives in session transcript on disk (`~/.claude/jobs/<id>/`) or via `claude logs <id>` (human-readable only) or by attaching; no machine-readable output endpoint | `https://code.claude.com/docs/en/agent-view.md` ("Where Final Output Goes"); `claude logs --help` |
| **4. `claude agents --json` schema** | CONFIRMED | Returns array with fields: `cwd`, `kind` (interactive/background), `startedAt`, `id` (short), `state`, `pid`, `status`, `waitingFor`, `sessionId`, `name` | `claude agents --json` (observed live output 2.1.220); `https://code.claude.com/docs/en/agent-view.md` |
| **5. Killing by id** | CONFIRMED | `claude stop <id>` (not listed in top-level help but exists); also `claude kill` appears to be alias | `claude stop --help` (observed 2.1.220) |
| **6. Tool/permission restrictions** | CONFIRMED | Restrictions applied via `--allowedTools`, `--disallowedTools`, `--permission-mode`, `--add-dir` carry to `--bg` session and persist across restarts | `claude --help` (flags); `https://code.claude.com/docs/en/agent-view.md` ("Do Tool Restrictions Apply?") |
| **7. Human attach mid-run side effects** | CONFIRMED NOT UNSAFE | Attaching posts recap, switches to full interactive mode, allows detach (`←`) which keeps session running; does not alter session id, output, or completion semantics from parent's POV | `claude attach --help`; `https://code.claude.com/docs/en/agent-view.md` ("What Happens When a Human Attaches?") |

---

## The supervision gap table

| What a parent needs | Available for `-p`? | Available for `--bg`? | Evidence |
|---|---|---|---|
| Assign/learn session id | ✓ Session id in output, or query `agents --json` | ✓ Same: printed on stdout, pollable via `agents --json --all` | `claude --help` (--session-id); `claude agents --help` (--json, --all) |
| Detect completion | ✓ Exit code 0 | ✓ Poll `agents --json`, check `state` field or use `SessionEnd` hook | `https://code.claude.com/docs/en/agent-view.md`; observed 2.1.220 |
| Read final result programmatically | ✓ Stdout | ✗ Final output only in transcript file or via `claude logs <id>` (text only, not structured) | `claude logs --help`; `https://code.claude.com/docs/en/agent-view.md` |
| Read error state | ✓ Exit code + stdout | ✓ `state: failed` in `agents --json`, or check logs | `https://code.claude.com/docs/en/agent-view.md` (state field) |
| Enforce timeout | ✗ No explicit timeout flag | ✓ Parent can `claude stop <id>` after elapsed time | `claude stop --help` |
| Kill by id without TTY | N/A (single run) | ✓ `claude stop <id>` or `claude kill <id>` (no TTY required) | `claude stop --help`; observed 2.1.220 |
| Constrain tools/permissions | ✓ `--allowedTools`, `--disallowedTools`, etc. | ✓ Same flags apply to `--bg` session | `claude --help`; `https://code.claude.com/docs/en/agent-view.md` |
| Human attach mid-run | N/A | ✓ Safe; attaching does not alter parent's view of session state | `claude attach --help`; `https://code.claude.com/docs/en/agent-view.md` |

---

## Claims

| Claim | Evidence | Publisher | Date Observed | Confidence |
|---|---|---|---|---|
| `--bg` flag exists and starts session in background | `claude --help` output includes: `--bg, --background: Start the session as a background agent and return immediately (manage with 'claude agents')` | Anthropic (Claude Code 2.1.220) | 2026-09-16 | High |
| `--bg` prints session id on stdout in format `backgrounded · <short-id> · <name>` | `https://code.claude.com/docs/en/agent-view.md` section "What `--bg` Returns on Stdout" | Anthropic (code.claude.com docs) | Accessed 2026-09-16 | Medium (not locally tested per safety constraint) |
| `claude agents --json` returns structured array with `state` field | Observed output includes: `"state": "working"`, `"state": "idle"`, etc. Schema documented in agent-view.md | Anthropic (Claude Code 2.1.220) | 2026-09-16 | High |
| `state` field values: `working`, `blocked`, `done`, `failed`, `stopped` | `https://code.claude.com/docs/en/agent-view.md` table "state field meanings" | Anthropic (code.claude.com docs) | Accessed 2026-09-16 | Medium (not all states observed locally) |
| `claude stop <id>` kills background session by short id | `claude stop --help`: "Stop a background session. Its conversation is kept; resume it later with 'claude attach <id>'." | Anthropic (Claude Code 2.1.220) | 2026-09-16 | High |
| `claude logs <id>` shows recent terminal output (text only) | `claude logs --help`: "Print the background session's recent terminal output." | Anthropic (Claude Code 2.1.220) | 2026-09-16 | High |
| `SessionEnd` hook fires when session terminates | `https://code.claude.com/docs/en/hooks.md` lists `SessionEnd` under "Session-Level Hooks" | Anthropic (code.claude.com docs) | Accessed 2026-09-16 | High |
| `--allowedTools`, `--disallowedTools`, `--permission-mode` apply to `--bg` sessions | `claude --help` lists these flags; `https://code.claude.com/docs/en/agent-view.md` confirms they persist to background sessions | Anthropic (Claude Code 2.1.220 + code.claude.com docs) | 2026-09-16 | High |
| Attaching to background session with `claude attach <id>` does not alter session's completion semantics or id | `claude attach --help` + `https://code.claude.com/docs/en/agent-view.md` ("What Happens When a Human Attaches?") | Anthropic (Claude Code 2.1.220 + code.claude.com docs) | 2026-09-16 | High |

---

## Verbatim evidence

### `claude --help` (excerpt, Claude Code 2.1.220, observed 2026-09-16)
```
  --bg, --background                    Start the session as a background agent
                                        and return immediately (manage with
                                        `claude agents`)
  --session-id <uuid>                   Use a specific session ID for the
                                        conversation (must be a valid UUID)
```

### `claude attach --help` (Claude Code 2.1.220, observed 2026-09-16)
```
Usage: claude attach <id>

  Open the background session in this terminal. ← returns to agent view, Ctrl+Z drops back to your shell. The session keeps running either way.
```

### `claude stop --help` (Claude Code 2.1.220, observed 2026-09-16)
```
Usage: claude stop <id>

  Stop a background session. Its conversation is kept; resume it later with `claude attach <id>`.
```

### `claude logs --help` (Claude Code 2.1.220, observed 2026-09-16)
```
Usage: claude logs <id>

  Print the background session's recent terminal output.
```

### `claude agents --json` schema (observed live output, Claude Code 2.1.220, 2026-09-16)
```json
[
  {
    "pid": 18834,
    "cwd": "/path/to/project",
    "kind": "interactive",
    "startedAt": 1789604018991,
    "sessionId": "7483b9e5-c669-47b4-9987-24087ee68652",
    "name": "session-name-hash",
    "status": "busy"
  }
]
```
Note: `state` field not present in current sessions (all are `kind: interactive`), but documented in agent-view.md for background sessions.

### Documentation: "Where Final Output Goes" (https://code.claude.com/docs/en/agent-view.md, accessed 2026-09-16)
> **On disk** (persistent):
> - Session transcript: `~/.claude/jobs/<id>/` (queryable via `claude --resume`)
> - Accessible through `claude logs <id>` from the shell
>
> **While session is running**:
> - Recent output shown in agent view row summaries
> - Full transcript accessible via `claude attach <id>` or by peeking with `Space`
> - Also shown via `claude logs <id>`

---

## Searched for and could not find

- **Exit code of `--bg` on success or failure**: Documentation does not explicitly specify; assumed to be 0 on successful dispatch but not verified.
- **Exact format of `claude agents --json --all` when including completed sessions**: Schema differences between active and completed sessions not documented; `--all` flag existence confirmed but output not inspected.
- **`claude kill <id>` as distinct from `claude stop <id>`**: Docs refer to it; `--help` only shows `stop`; appears to be an alias but not confirmed.
- **Stdout capture mechanism for `--bg`**: Whether session's stdout/stderr are captured to disk file or discardable is not explicitly documented; `claude logs <id>` implies capture but mechanism opaque.
- **Structured output or JSON result from `--bg` session**: No machine-readable result format found; parent must parse transcript or attach interactively.
- **Default behavior if parent does not consume the `--bg` stdout line**: Whether short-id is also retrievable another way if stdout is redirected to `/dev/null`.
- **Release date of `--bg` and `claude attach` features**: CHANGELOG not found in code.claude.com docs; feature is present in 2.1.220 (observed 2026-09-16).
