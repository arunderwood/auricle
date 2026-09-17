# Q2 RED TEAM: attempt to disprove "headless sessions cannot be attached to"

## Did the conclusion survive?
**SURVIVED** — The original conclusion is substantively correct: `-p` / `--print` sessions do not create attachable background sessions. However, a workaround path exists through non-`-p` flags that enable unattended operation while remaining attachable, making the practical concern addressable without the explicit `-p` constraint.

---

## Hidden/undocumented subcommands found
| Command probed | Exists? | Verbatim usage text |
|---|---|---|
| `claude attach` | YES | `Usage: claude attach <id> — Open the background session in this terminal. ← returns to agent view, Ctrl+Z drops back to your shell. The session keeps running either way.` |
| `claude connect` | NO | (returns main help) |
| `claude sessions` | NO | (returns main help) |
| `claude session` | NO | (returns main help) |
| `claude join` | NO | (returns main help) |
| `claude tail` | NO | (returns main help) |
| `claude watch` | NO | (returns main help) |
| `claude send` | NO | (returns main help) |
| `claude teleport` | NO | (returns main help) |

---

## Disconfirming evidence found
| Evidence | What it would mean | Source | Strength |
|---|---|---|---|
| **Remote Control + background sessions mechanism** | A session started with `claude --remote-control` or `claude remote-control` (server mode) can be steered mid-run from a phone, browser, or another terminal. While not technically `-p`, this is "unattended by default, attachable when wanted" — precisely the concern behind the conclusion. | https://code.claude.com/docs/en/remote-control.md (v2.1.274) | HIGH — documented and stable feature in v2.1.220+ |
| **`--bg` (background flag)** | Sessions can be started with `claude --bg "<prompt>"` as background tasks, and `claude attach <id>` connects to them. These are not `-p` but achieve similar effect (fire-and-forget from CLI perspective) while remaining stoppable/steerable. | headless.md references `--bg` rejection with `-p`; agent-view implies `--bg` creates attachable sessions | HIGH — explicitly referenced in official docs |
| **Changelog v2.1.269: "headless sessions" with remote attach** | "Fixed Remote Control showing a stale permission mode when a phone, browser, or claude.ai app attaches to a terminal session" + "Fixed remote **and headless sessions** reporting 'waiting for your input'" — the existence of "headless sessions" as a distinct category suggests non-interactive sessions that ARE attachable, separate from `-p`. | https://code.claude.com/docs/en/changelog.md (v2.1.269, Sept 11, 2026) | MEDIUM — implies a session type distinct from terminal and `-p`, but does not explicitly define it or explain how to invoke it |
| **Agent view + attach infrastructure** | `claude attach <id>` exists and is designed to reconnect to background sessions. The infrastructure is mature (error handling, state management in v2.1.261-v2.1.274 fixes). | https://code.claude.com/docs/en/agent-view.md via WebFetch + `claude attach --help` | HIGH — tested live |

---

## Specific finding: `-p` / `--print` sessions CANNOT be attached
**From agent-view.md (fetched via WebFetch):**
> "Claude Code rejects `--bg` combined with `-p` or `--print` before any session is created, because `--print` never starts the interactive session that `claude agents` attaches to."

This is an **explicit, authoritative statement** that print mode does not create an attachable session. The reason given is structural: `-p` is designed as a non-interactive, one-shot mode.

---

## Unsupported workarounds found (labelled as such)
None detected from official channels. No tmux/screen/file-watching patterns needed: the platform provides `--bg` and Remote Control as the supported alternative.

---

## What I searched and probed and did NOT find
- **No mechanism to start a `-p` session and attach to it later.** The docs and CLI make this a hard constraint.
- **No flag like `--print-but-attachable` or `--headless-interactive`.** The word "headless" in the changelog refers to internal session types, not a CLI flag.
- **No hook or permission mechanism that pauses a headless session for human input.** Hooks exist (`PermissionRequest`, `PreToolUse`) but are designed for interactive sessions or those with a permission host; `-p` sessions deny most prompts by design.
- **No hidden subcommand for "teleport," "connect," "session," or "join"** that differs from `attach`. The `--teleport` mentioned in changelog refers to `/teleport` *inside* a session, not a CLI command.
- **No changelog entry suggesting `-p` attach capability was added.** The recent entries (v2.1.260–v2.1.274) mention Remote Control fixes and background session improvements, but never propose `-p` attachment.

---

## Conclusion for architecture decision-making

**The conclusion is correct for the narrow claim: `-p` sessions are not attachable.**

**However, for the use case behind it ("headless by default, steerable when needed"), the platform provides two supported escape routes:**

1. **`claude --bg "<prompt>"`** — fire-and-forget background session in the CLI, stays in your terminal without blocking, can be attached to with `claude attach <id>`.
2. **`claude remote-control`** — server mode that starts sessions and exposes them to claude.ai/code and mobile app for remote steering, explicitly designed for "pick up where I left off" workflows.

Neither uses `-p`, so the claim that `-p` sessions are non-attachable remains unbroken. The architectural concern (fire-and-forget automation that can't be interrupted mid-run) is real but has a supported resolution path outside of `-p`.

