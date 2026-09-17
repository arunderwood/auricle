# Q2: Attach to a running headless session — digest

## Headline verdict
**CONFIRMED NOT SUPPORTED.** Live attach to an in-flight `-p` / `--print` (headless) session is not a supported feature. The `--remote-control` flag is explicitly silently ignored when combined with `-p`. Evidence: Help output (v2.1.220), headless.md documentation stating `--bg` is rejected with `-p`, and GitHub issue #80954 explicitly documenting that `-p --remote-control` is silently ignored.

---

## Verdicts

| Sub-question | Verdict | Mechanism | Evidence |
|---|---|---|---|
| **Is live attach to an in-flight session a supported feature?** | CONFIRMED NOT SUPPORTED | N/A | Headless.md doc + GH #80954: "`-p --remote-control` is silently ignored." Help says "Claude Code rejects `--bg`" with `-p`. No attach mechanism exists for headless. |
| **Distinguish: live attach vs. resume-after-exit vs. streaming input vs. bidirectional client vs. takeover/handoff vs. hooks/permission prompts** | PARTIAL SUPPORT; see confusion table below | See confusion table | Remote Control, agent-view attach, cross-session messaging, and `--resume` each exist but serve different use cases. |
| **Limits of attach mechanism (if exists)** | BACKGROUND SESSIONS ONLY | Agent-view terminal attach; `claude attach <id>` | Attach is **only** for background sessions started with `--bg`. Cannot attach to headless (`-p`) sessions. Headless.md explicitly rejects `--bg` when `-p` is present. |
| **Docs/changelog stating not supported or feature requests?** | CONFIRMED; multiple open requests | Feature requests | GH #80954 ("no path to attach RC to completed headless"), GH #30447 ("Feature Request: remote-control --headless"), GH #24365 ("Expose ACP over network..."). All open. |
| **Does transcript allow external observation of running session?** | NO | N/A | Headless sessions write `.jsonl` transcripts to disk after completion, not in real time. No mechanism for external real-time observation of a still-running headless session. |

---

## The confusion table

| Candidate mechanism | Does it exist? | Is it attach-to-running? | What it actually does | Evidence |
|---|---|---|---|---|
| **Live attach via agent-view (`--bg` sessions)** | YES | YES, but only for background sessions | Start session with `--bg`. Press Enter/→ in agent-view or run `claude attach <id>` to take over terminal and send input mid-run. Session keeps running when you detach (←). | agent-view.md: "Attaching never stops the session." Help: `--bg` flag. Headless.md confirms `--bg` and `-p` are mutually exclusive. |
| **Live attach via `--remote-control` (headless sessions)** | NO | N/A | `--remote-control` can pair with **interactive** sessions (not `-p`). When combined with `-p`, flag is silently ignored; no Remote Control connection is opened. | GH #80954: "no path to attach RC to completed headless (-p) sessions - ... -p --remote-control is silently ignored." Help shows both flags but not combined. |
| **Resume-after-exit (`--continue`, `--resume`)** | YES | NO; resumption-only | Restart a completed session with `--continue` or `--resume <id>`. Adds new turn to transcript. Does not attach to a running session; requires it to be finished. | Headless.md: "Continue conversations" section. Help: `--continue` and `--resume` flags. |
| **Streaming input mode (parent feeds stdin)** | YES, limited | Not for human mid-run steering | `-p` accepts piped stdin as initial prompt. Session processes in one non-interactive run. Parent cannot send additional input mid-turn. Subagents running in foreground can receive output via stream. | Headless.md: "Pipe data through Claude," "Stream responses," "Background tasks at exit." |
| **Cross-session messaging (send text to live session)** | YES | NO; text-only handoff | One session sends plain-text message to another with `SendMessage` tool. Receiving session reads message between tool calls. Message cannot approve permissions, change config, or run commands. Not free-form steering. | cross-session-messaging.md: "It can't approve anything... it can't change configuration... Commands don't run." |
| **Hooks / permission prompts (interruption for approval)** | YES | NO; approval-only | Session pauses for human yes/no decision on a permission prompt (e.g., tool use approval). Cannot send arbitrary input; confined to approve/deny. | permissions.md and tool-reference.md cover permission prompts. Not a steering mechanism. |
| **Bidirectional client object (Agent SDK)** | YES | N/A; within a single parent process | Python/TypeScript Agent SDK parent can hold a session object and call methods to send input, receive output, check state. Requires parent to have spawned the session; not applicable to external observer attaching mid-run. | Agent SDK docs (Python, TypeScript) on `messages.create()`, streaming callbacks, etc. |

---

## Claims

| Claim | Source | Publisher | Date | Confidence | Class |
|---|---|---|---|---|---|
| Live attach to headless `-p` is not supported | `--help` output, v2.1.220 + headless.md | Anthropic (docs + CLI) | Observed 2026-09-16 | HIGH | mechanism |
| `--remote-control` flag is silently ignored when combined with `-p` | GH #80954 title & description | GitHub Issues (anthropics/claude-code) | 2024 (open) | HIGH | behaviour |
| `--bg` and `-p` are mutually exclusive | headless.md: "Claude Code rejects `--bg`" | Anthropic (docs) | Accessed 2026-09-16 | HIGH | mechanism |
| Agent-view attach works for `--bg` background sessions only | agent-view.md | Anthropic (docs) | Accessed 2026-09-16 | HIGH | mechanism |
| Transcripts are written to disk post-completion, not in real time | headless.md: "Read session metadata" section discusses streaming output only for live runs | Anthropic (docs) | Accessed 2026-09-16 | MEDIUM | behaviour |
| Multiple open feature requests for headless Remote Control / attach capability | GH #80954, #30447, #24365 (all open) | GitHub Issues (anthropics/claude-code) | Various 2024-2025 | HIGH | version |

---

## Verbatim evidence

### Claude Code v2.1.220 help output (2026-09-16)
```
--bg, --background                    Start the session as a background agent
                                      and return immediately (manage with
                                      `claude agents`)
[...]
--remote-control [name]               Start an interactive session with Remote
                                      Control enabled (optionally named)
-r, --resume [value]                  Resume a conversation by session ID, or
                                      open interactive picker with optional
                                      search term
```

### From headless.md (accessed 2026-09-16)
"Add the `-p` (or `--print`) flag to any `claude` command to run it non-interactively. Not every CLI option combines with `-p`. Claude Code rejects `--bg`, and rejects `--cloud` with a task description..."

### From agent-view.md (accessed 2026-09-16)
"**Attaching** means taking over the terminal to interact with that session directly... When you attach, Claude posts a recap of what happened while you were away... Importantly, **detaching never stops the session**."

### GitHub Issue #80954 title
"Remote Control: no path to attach RC to completed headless (-p) sessions - resume requires a prompt, and -p --remote-control is silently ignored"

---

## Leads worth chasing

1. **Agent SDK with a parent process**: The Python/TypeScript Agent SDK does allow a parent program to hold a session object and send messages to it programmatically. If the parent stays alive, you could message the session through the parent's object — but this is not "external attach", it's bidirectional control from the parent's code.

2. **Workarounds that stitch together tmux/screen**: Third-party workflows (not documented in official Claude Code docs) use tmux session discovery + file-watching on transcripts + external input delivery. These are not supported features and require shell scripting outside Claude Code's harness.

3. **Resume after exit + Remote Control**: A completed headless session can be resumed interactively with `--resume <id>`, and that resumption can include `--remote-control`. This is resume-after-exit (not live attach) and could serve workflows where "joining mid-task" means waiting for current work to finish, then resuming interactively. GH #80954 requests exactly this flow.

4. **Cross-machine messaging via sessions**: If both machines run sessions with cross-session messaging enabled, they can exchange text messages. Not steering, but enables handoff patterns.

---

## Searched for and could not find

- **No official "daemon" mode for headless**: no `--daemon` flag or mode that lets `-p` sessions accept connections after they start.
- **No "attach point" API**: no documented way to connect to a running `-p` process's stdin/stdout from outside its parent.
- **No transcript streaming hook**: no mechanism for an external watcher to observe a still-running session's transcript in real time (transcripts are written post-completion).

All three are open feature requests or known gaps. The design assumption underlying all current tooling is that `-p` is for single-run automation, not long-lived interactive observation or steering mid-run.

