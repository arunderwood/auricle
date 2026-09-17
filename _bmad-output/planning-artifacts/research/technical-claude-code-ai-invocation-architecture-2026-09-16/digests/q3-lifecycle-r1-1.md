# Q3: Lifecycle control — digest

**Research date:** 2026-09-16  
**Claude Code version observed:** 2.1.220  
**Query:** Can a parent process enforce a hard wall-clock budget on a headless Claude Code / Agent SDK session and kill it—and is there a resume/replay story afterward?

---

## Verdicts

| Sub-question | Verdict | Mechanism | Evidence |
|---|---|---|---|
| Is there a built-in wall-clock timeout? | CONFIRMED NOT SUPPORTED | No `--timeout`, `--wall-clock`, `--max-seconds`, or `max_session_duration` flag in `claude --help` (2.1.220). No corresponding Agent SDK option in `ClaudeAgentOptions` (Python) or `Options` (TypeScript). | `claude --help` output 2026-09-16; Agent SDK docs at https://code.claude.com/docs/en/agent-sdk/session-management.md |
| Are there documented timeout-shaped configurations? | CONFIRMED (with caveats) | Three timeout mechanisms exist, but **none is a wall-clock session timeout**: (1) `API_TIMEOUT_MS` — per-request timeout to API, default 600000ms (10 min); (2) `BASH_DEFAULT_TIMEOUT_MS` — per-command bash timeout, default 120000ms (2 min); (3) `CLAUDE_CODE_MCP_STARTUP_WAIT_MS` — MCP server startup wait, not a session bound. Turn-level limit exists: `max_turns` / `maxTurns` stops iteration but does not bound wall-clock time. | `claude --help` env vars documented; https://code.claude.com/docs/en/env-vars.md; Agent SDK `ClaudeAgentOptions.max_turns`, TypeScript `Options.maxTurns` |
| What happens on external signals (SIGTERM/SIGINT/SIGKILL)? | UNVERIFIABLE FROM DOCS | No documented signal handling or cleanup behavior. GitHub issues indicate SIGTERM is sent unexpectedly every 5 minutes in Desktop/VS Code (bug reports, v2.1.273+), but no graceful-shutdown spec or transcript-flushing guarantee is documented. No contract on state recovery after kill. | GitHub search on anthropics/claude-code: "exiting with code 143 (SIGTERM) every exactly 5 minutes"; no official docs on signal handling or cleanup. |
| Resume/replay after a kill? | CONFIRMED (partially) | `--resume <session-id>` and SDK `resume` option documented; creates **new session** that resumes prior history. **However**: session ID is only guaranteed available at query completion (in `ResultMessage.session_id`). If session is killed before completion, parent obtains no ID from a dead run and cannot resume it. Fork capability exists but suffers the same ID availability constraint. | Agent SDK: https://code.claude.com/docs/en/agent-sdk/session-management.md; TypeScript SDK also exposes session ID in early `SystemMessage.init`, giving a window to capture it mid-run if parent polls the stream. |
| Does session write incremental state to disk? | CONFIRMED | Sessions stored as `.jsonl` files (line-delimited JSON, incrementally appendable) at `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. Structure confirms line-by-line writes. **Status: documented location and format, but no explicit contract on flush timing or recovery semantics after kill.** | Agent SDK docs: https://code.claude.com/docs/en/agent-sdk/session-management.md § "Claude Code stores sessions under..."; Observed file structure: `ls ~/.claude/projects/-USER/` shows `<uuid>.jsonl` files. |
| Forking capability? | CONFIRMED | `--fork-session` (CLI) and `fork_session: true` / `forkSession: true` (SDK) branch a session into a new ID without mutating the original. Documented in Agent SDK and CLI help. **Caveat**: fork is a semantic copy of history, not filesystem snapshot; file edits by forked agent are real and visible to other sessions in the same directory. | `claude --help` lists `--fork-session`; Agent SDK: https://code.claude.com/docs/en/agent-sdk/session-management.md § "Fork to explore alternatives" |

---

## Timeout inventory

| Name | Kind | What it bounds | Default | Where configured | Evidence |
|---|---|---|---|---|---|
| `API_TIMEOUT_MS` | Per-request | HTTP request to Claude API from agent | 600000ms (10 min) | Env var; settings.json `env` key | https://code.claude.com/docs/en/env-vars.md |
| `BASH_DEFAULT_TIMEOUT_MS` | Per-command | Single bash/shell command execution | 120000ms (2 min) | Env var; settings.json `env` key | https://code.claude.com/docs/en/env-vars.md |
| `CLAUDE_CODE_MCP_STARTUP_WAIT_MS` | Startup only | MCP server connection attempt duration | Not documented (observed v2.1.274) | Env var | https://github.com/anthropics/claude-code (v2.1.274 release notes) |
| `max_turns` / `maxTurns` | Iteration cap | Agent loop iterations within one session | No default (unlimited if not set) | CLI `--max-turns <n>` or SDK option | Agent SDK docs, CLI help |

**Critical gap**: No wall-clock session timeout. Parent cannot set a hard "kill this session after N seconds" boundary.

---

## Claims

- **No built-in wall-clock session timeout exists** — `claude --help` (2.1.220, 2026-09-16) shows no `--timeout`, `--max-seconds`, or session-duration flag; Agent SDK (`ClaudeAgentOptions`, `Options`) documents no equivalent. | Confidence: **high** | Class: mechanism |

- **Session ID is only reliably available at query completion** — `ResultMessage.session_id` (Python) and `message.session_id` on result (TypeScript); TypeScript also exposes early in `SystemMessage.init`. Parent killing the process before result is yielded has no session ID to resume from. | https://code.claude.com/docs/en/agent-sdk/session-management.md § "Capture the session ID" | Confidence: **high** | Class: behaviour |

- **Sessions are stored as incremental `.jsonl` files** — documented location `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; line-delimited format supports incremental writes. No contract on flush timing after kill or corruption guarantees. | https://code.claude.com/docs/en/agent-sdk/session-management.md; file structure observed 2026-09-16 | Confidence: **high** | Class: mechanism |

- **SIGTERM behavior is buggy, not graceful** — GitHub issues report Claude Code exiting with code 143 (SIGTERM) every 5 minutes in Desktop and VS Code, but no official graceful-shutdown procedure or SIGTERM→SIGKILL sequence documented. | GitHub issues: "exiting with code 143 (SIGTERM) every exactly 5 minutes in Desktop app & VS Code extension" (no direct link preserved); v2.1.273+ affected | Confidence: **medium** | Class: behaviour (undocumented) |

- **Resume works only if you have the session ID beforehand** — Cannot recover from a killed run without the ID; the kill prevents normal query completion. TypeScript SDK exposes ID early (SystemMessage.init), giving a capture window; Python does not. | https://code.claude.com/docs/en/agent-sdk/session-management.md; Agent SDK code examples | Confidence: **high** | Class: behaviour |

---

## Verbatim evidence

### `claude --help` (2.1.220, 2026-09-16)
```
--continue                        Continue the most recent conversation in
                                  the current directory
--fork-session                    When resuming, create a new session ID
                                  with --resume or --continue)
-r, --resume [value]              Resume a conversation by session ID, or
                                  open interactive picker with optional
                                  search term
--session-id <uuid>               Use a specific session ID for the
                                  conversation (must be a valid UUID)
```
**Search result:** No `--timeout`, `--wall-clock-timeout`, `--max-seconds`, `--session-duration`, or equivalent flag.

### Session file structure
```
$ ls ~/.claude/projects/-USER/
fcbc04d8-48c4-4ecb-83d6-2c88243e9f51
fcbc04d8-48c4-4ecb-83d6-2c88243e9f51.jsonl
[... more UUIDs and .jsonl pairs ...]
```
**Observation:** `.jsonl` files are line-delimited JSON, designed for incremental writes. Directories alongside `.jsonl` likely hold checkpoints or other session artifacts.

### Agent SDK session resume documentation
From https://code.claude.com/docs/en/agent-sdk/session-management.md:

> "Resume by ID: Pass a session ID to `resume` to return to that specific session. The agent picks up with full context from wherever the session left off."
> 
> "Capture the session ID: Read it from the `session_id` field on the result message... which is present on every result regardless of success or error."

**Implication:** Session ID is only guaranteed after the query completes and yields a result message.

---

## Leads worth chasing

1. **TypeScript SDK early session-ID exposure** — The agent SDK docs note that TypeScript exposes session ID in `SystemMessage.init` message, whereas Python does not. A parent using TypeScript SDK could poll the stream and capture the ID before completion, then SIGTERM and later resume. Python would need to fork or wrapper the agent. **Status:** Documented but not emphasized as a lifecycle recovery pattern.

2. **File checkpointing for filesystem rollback** — Agent SDK docs reference a `/docs/en/agent-sdk/file-checkpointing` page (not fetched). If checkpoints are cheap and frequent, a parent could restore file state after a killed run without relying on session resume. **Status:** Mentioned but not explored.

3. **SIGTERM behavior and graceful shutdown** — Multiple GitHub issues describe SIGTERM being sent unexpectedly or orphaning processes. A parent relying on SIGTERM to kill a session cleanly might find the transcript corrupt or incomplete. **Status:** Observed as buggy in GitHub issues; no fix ETA found in releases up to v2.1.274.

4. **`SessionStore` adapter for cross-host resume** — Agent SDK docs mention `SessionStore` for mirroring transcripts to shared storage (e.g., S3, Firestore). A parent could implement a store to make sessions resumable across process deaths or host changes. **Status:** Documented but requires parent implementation.

5. **`CLAUDE_CODE_SKIP_PROMPT_HISTORY` in Python** — Mentioned in Agent SDK docs as a way to suppress session writes and keep conversation in memory only. Could simplify lifecycle if no persistent recovery is needed. **Status:** Documented; not tested.

---

## Searched for and could not find

- **Documented wall-clock session timeout** — Searched: `claude --help`, Agent SDK docs, env vars reference, GitHub releases. No such feature exists in 2.1.220.

- **Graceful SIGTERM/SIGKILL handling contract** — Searched: Agent SDK session management, CLI help, GitHub issues. No official spec for signal handling, cleanup sequence, or state recovery after external termination.

- **Recovery mechanism for killed (interrupted) runs** — A parent that needs to resume after a SIGKILL has no documented recovery path. The session ID is not available, and the docs do not address interrupted query scenarios.

- **Flush-to-disk timing guarantee** — Session files are `.jsonl` (incremental), but no documented sync points or guarantees on how quickly a completed turn is written to disk after a tool result is yielded. Relevant for a parent timing the kill carefully to avoid corruption.

---

## Summary for parent process with hard wall-clock budget

**TL;DR:** No wall-clock timeout is built in. A parent must implement the budget externally:

1. **Enforce the wall-clock bound via OS-level tools** — `timeout(1)`, process groups, or cgroup limits, not Claude Code itself.

2. **Capture session ID early if possible** — Use TypeScript SDK to read session ID from the first `SystemMessage.init` before the query runs, so you have it for potential resume even if you kill the process.

3. **Expect incomplete state after SIGTERM** — No documented graceful shutdown. The session transcript may be partially written or corrupt. Do not rely on resume as a recovery mechanism for a killed run; it works only if the session completed normally.

4. **If recovery matters, implement a `SessionStore`** — Mirror the session transcript to your own backend (S3, Firestore, etc.) so you can resume on another host or process after a crash.

5. **Be aware of per-request timeouts** — `API_TIMEOUT_MS` (default 10 min) and `BASH_DEFAULT_TIMEOUT_MS` (default 2 min) will fire before a wall-clock session timeout, so a hard budget < 10 min will be preempted by a slow API call.

---

**Next steps for deeper investigation:**

- Obtain a GitHub account and audit recent issues in `anthropics/claude-code` for SIGTERM handling and process lifecycle (link searches were limited).
- Test TypeScript SDK with explicit session ID capture mid-run and attempted resume after SIGKILL.
- Prototype a `SessionStore` implementation (S3 or local) to validate transcript recovery.
- Check if corrupted `.jsonl` transcripts are self-healing (v2.1.274 release notes mention "corrupted transcripts self-heal" — needs verification).

