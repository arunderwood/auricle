---
title: 'Technical research: Claude Code / Agent SDK invocation mechanics'
type: 'technical'
topic: 'Driving Claude Code / Agent SDK sessions from a parent process: headless invocation, attach, lifecycle, tool scope, and file-based prompt storage'
decision: 'Whether auricle AI stages should be invoked via a managed Claude Code session with file-based skill prompts, instead of an in-Swift prompt builder plus a direct Anthropic API call'
source: 'native run (bmad-deep-recon), parallel web fan-out + two rounds of local binary probing'
status: complete
claims_verified: 21
claims_disputed: 2
claims_overturned: 4
claims_total: 27
preset: 'standard'
validation: 'high'
red_team: 'Q2, Q4'
version_anchor: 'Claude Code 2.1.220'
created: '2026-09-16'
updated: '2026-09-16'
revision: 'r3 — hook lifecycle probed; --bg result gap closed; six of six r1 open questions now settled'
---

# Technical research: Claude Code / Agent SDK invocation mechanics

**Decision this research serves:** whether auricle's AI stages should be invoked via a managed Claude Code session with prompts stored as skill/markdown files, rather than assembled in Swift and sent to the Anthropic API directly.

Two separable ideas are under evaluation, referred to throughout as:

- **Idea (a) — prompts as files.** Prompt text lives in skill/markdown files on disk instead of being assembled in code by a prompt builder.
- **Idea (b) — invocation via a managed session.** AI stages run as a Claude Code session that is headless by default but can be attached to interactively mid-run.

**This document contains no recommendation.** It establishes mechanics as fact so a later roundtable can argue from evidence. Where the evidence does not settle a question, it says so.

> **Revision r2.** The first probe round ran while the machine's local credentials were expired, so every model call failed at authentication. After re-authentication the blocked probes re-ran. Five of six open questions are now closed and **three earlier findings are corrected** — most importantly, `--bg` is better supervised than r1 reported, and the "documented-vs-observed discrepancy" r1 claimed does not exist. **r3** then probed the hook lifecycle and closed the last substantive gap: a `--bg` session's result *does* have a documented channel. Corrections are marked **[corrected in r2]** / **[corrected in r3]** where they appear. Evidence: `digests/probe-set-2-authenticated-r4.md`.

> **Version anchor and its single most important caveat.** All observed behavior is from **Claude Code 2.1.220**, the locally installed build, probed 2026-09-16. The published documentation gates six features above that build (2.1.221, 2.1.246, 2.1.257, 2.1.259, 2.1.261, and 2.1.265) — and one of them bites here: `--permission-prompts none`, at 2.1.259, is the flag designed for exactly the unattended case (see Q4). **The docs run ahead of this install.** A documented feature is therefore not evidence that the feature is present locally, and at least one documented field could not be observed (see Q2, `state`/`waitingFor`). Treat every doc-only claim below as "true of some version ≥ 2.1.220", not "true of 2.1.220".

---

## Verdict table

The five questions as asked, each with its discriminating evidence.

| # | Question | Verdict | The mechanism, or what establishes the negative |
|---|---|---|---|
| **1** | Headless invocation — interface, return, success/failure detection | **CONFIRMED** | `claude -p` with `--output-format json\|stream-json`; Python/TypeScript Agent SDK `query()`. Failure is signaled two ways: **exit code** (0 success, non-zero failure, 143 on SIGTERM) and an **`is_error` boolean** in the result object. **Trap:** `subtype` read `"success"` on *both* an observed successful and an observed failed run, so it carries no signal — branch on `is_error` or `terminal_reason` (`completed` vs `api_error`), never `subtype` (see Q1). [1][2][22] |
| **2** | Attach to a session already running headless | **CONFIRMED NOT SUPPORTED** for `-p` — **CONFIRMED SUPPORTED** for `--bg` | `-p` + `--bg` is rejected *before any session is created*: "`--print` never starts the interactive session that `claude agents` attaches to" [1][12]. The attachable path is `claude --bg` + `claude attach <id>`; "Detaching never stops a background session" [12]. The two paths cannot be combined. **[corrected in r3]** `--bg` is fully supervisable: poll `claude agents --json` for a documented `state` enum incl. `done`/`failed` [12]; get a **push signal plus the result** from a `Stop` hook's `last_assistant_message`, which the docs recommend for exactly this [23]; kill with `claude stop <id>` [1]. Only rough edge: `--bg` ignores `--session-id`, so the ID must be scraped from stdout [22]. [1][12][22][23] |
| **3** | Hard wall-clock timeout; kill; resume/replay after kill | **Split: timeout CONFIRMED NOT SUPPORTED; kill and resume CONFIRMED** | No wall-clock flag exists in `--help` or the SDK options — the parent must impose it externally [1][2]. Kill is fully specified: SIGTERM → exit 143, `SessionEnd` hooks run, bash process tree terminated [2]. Resume after kill works and is documented to continue the unfinished turn [2]; the parent can pre-assign the ID with `--session-id` [1]. |
| **4** | Tool + filesystem scope; enforced or advisory | **CONFIRMED ENFORCED for tool permissions — but coverage is best-effort and defaults are permissive** | Rules are deny-first harness gates and managed settings outrank even CLI arguments [5][8]. Two documented limits bound the guarantee: a Bash rule "isn't a security boundary around the program" because it misses `/bin/curl` and `sh -c` forms [5], and reads are **not** confined to the working directory unless `blockReadsOutsideWorkingDirectories` is explicitly set [5]. A hard egress guarantee needs the OS sandbox's network allowlist, not deny rules [5][6]. |
| **5** | Skill/prompt-file loading, pinning, and byte-exact provenance | **Split: loading CONFIRMED; deterministic invocation CONFIRMED; byte-exact provenance CONFIRMED NOT SUPPORTED** (observed in r2) | Model-chosen activation is the model's judgment and not guaranteed; `/skill-name` in the prompt string is deterministic and works in `-p` [2][9]. Versioning exists at *plugin* granularity only [10]. **No mechanism returns the prompt bytes sent.** A sentinel passed via `--append-system-prompt` appeared **0 times** in both the session transcript and a 311-line debug log; no hash or length is recorded either [22]. The host must hash the files itself and trust they were used unchanged [9][11][22]. |

---

## Executive summary

**Both ideas are mechanically feasible. The constraints that bind are narrower and more specific than the headline framing suggests: attachability and the `-p` result contract live on different paths, and file-stored prompts buy determinism but forfeit provenance.**

Three findings shape the picture:

1. **Idea (b)'s premise is false as literally stated, but true in an adjacent form.** You cannot attach to a running `-p` (headless) session — not by any flag, hidden subcommand, or supported mechanism. The binary itself rejects the combination, and names the reason: print mode never starts the interactive session that `claude agents` attaches to [1][12]. There *is* a real, supported, human-attachable path — `claude --bg` plus `claude attach <id>`, which `--help` does not list — and detaching genuinely leaves the session running [1][12].

   **[corrected in r3]** That path is also fully supervisable, which r1 badly understated. A parent can poll `claude agents --json` — "the supported way to read session state from outside Claude Code" — for a documented `state` enum distinguishing `working`, `blocked`, `done`, **`failed`**, `stopped`; and kill by ID with `claude stop <id>` [12][22]. **It can also get the result itself.** A `Stop` hook fires at turn completion in a `--bg` session and its payload carries `last_assistant_message`, observed holding the exact model output; the hooks reference explicitly directs callers to it — "Hooks that need the final assistant text of the current turn should use `last_assistant_message` on Stop and SubagentStop instead of reading the transcript" [23]. `SessionEnd`, by contrast, does **not** fire on turn completion — only on termination, with `reason: 'other'` [23].

   One rough edge survives: `--bg` **ignores** a parent-assigned `--session-id`, so the ID must be scraped from human-facing stdout [22]. And architecturally the result arrives as a **push into a hook subprocess**, so the spawning parent must bridge it rather than read a return value.

   So: "headless by default, attach when I want, know whether it succeeded, **and** read its answer through a documented interface" is available. The genuine cost of choosing `--bg` over `-p` is the ID scrape and the push-vs-return plumbing — not observability.

2. **Supervision of `-p` is stronger than commonly reported, and three widely repeated claims about it are false.** The JSON result object does carry explicit failure signaling — `is_error`, `terminal_reason`, `api_error_status`, `permission_denials`, and more [1]. It also carries a trap: `subtype` read `"success"` on an observed **successful** run and on an observed **failed** one, so it discriminates nothing; `is_error` and `terminal_reason` (`completed` vs `api_error`) are the fields that do [1][22]. A parent *can* assign the session ID up front via `--session-id` [1]. And a SIGTERM-killed run *is* resumable: "When you resume the session, Claude Code continues the turn that SIGTERM left unfinished" [2]. What does not exist is a built-in **wall-clock timeout** — that remains the parent's job [1][2].

3. **The privacy constraints that bind are documented, current defaults — not vulnerabilities.** Three, in the docs' own words. A `-p` session "runs the hooks in a project's `.claude/settings.json` and connects the servers in its `.mcp.json`, even in a folder you've never trusted" unless `--bare` is passed [2]. A Bash deny rule "isn't a security boundary around the program" [5]. And reads are not fenced to the working directory unless that fence is explicitly switched on [5]. The permission layer *is* a real enforced gate — deny-first, with managed settings outranking even CLI arguments [5] — but the guarantee has to be assembled deliberately from non-default settings plus the OS sandbox, not assumed from the tool's defaults. (Five CVEs surfaced during the review are all patched below the installed build and are **not** live; see Contrary evidence [13][14][15][16][17].)

**The biggest caveat:** the single most load-bearing negative — "no wall-clock timeout" — rests on *absence* of a flag in `--help` plus absence of a doc statement. Absence is weaker evidence than presence. It is consistent across the binary, the CLI reference, and the SDK options, but it cannot be proven the way a positive claim can. The one negative that *was* provable by experiment — prompt provenance — was tested with a sentinel in r2 and came back absent from every candidate record [22].

---

## Q1 — Headless invocation

**Entry points.** Three, all CONFIRMED: the CLI `claude -p` / `--print`; the Python Agent SDK (`query()`, `ClaudeSDKClient`); the TypeScript Agent SDK (`query()`) [1][2][3][4]. The CLI is documented as "the Agent SDK via the CLI" — same agent loop, different surface [2].

**Output contract.** `--output-format` takes `text` (default), `json` (single result object), or `stream-json` (newline-delimited events, last line a `result` message) [1][2]. With `--json-schema`, the validated payload lands in `structured_output`; an invalid schema makes the run exit with `Error: --json-schema is not a valid JSON Schema` [2].

**The result object, observed directly.** It is commonly stated that the `-p` JSON payload carries no success or error field. **That is false.** A live `-p --output-format json` run on 2.1.220 returned these top-level keys [1]:

```
api_error_status, duration_api_ms, duration_ms, fast_mode_disabled_reason,
fast_mode_state, is_error, modelUsage, num_turns, permission_denials, result,
session_id, stop_reason, subtype, terminal_reason, total_cost_usd, type, usage, uuid
```

**A trap worth naming, now with both cases observed.** r1 saw only the failure case; r2 added the success case, which sharpens the finding considerably [1][22]:

| Field | Successful run | Failed run (auth) |
|---|---|---|
| `is_error` | `False` | `True` |
| `subtype` | `'success'` | `'success'` |
| `terminal_reason` | `'completed'` | `'api_error'` |
| `stop_reason` | `'end_turn'` | `'stop_sequence'` |
| exit code | 0 | 1 |

`subtype` read `'success'` in **both** cases — it carries no failure signal at all, which is worse than r1's framing suggested. **`is_error` and `terminal_reason` are the discriminating fields**, and the exit status corroborates them. A parent branching on `subtype` would read every failure as a success.

**How the parent knows the run failed.** Two independent signals, both documented: "Claude Code exits with code 0 on success and a non-zero code when the run fails, so your scripts can branch on the exit status" [2]; and, crucially, "**When a failure happens inside the run, such as missing authentication, Claude Code prints the failure as the result on stdout**" [2]. This was observed exactly: the run's `result` field contained `Failed to authenticate: OAuth session expired and could not be refreshed` [1]. So a semantic failure is *not* silent — it surfaces in `result`, `is_error`, and the exit code together.

**Input.** A positional argv argument, piped stdin (**capped at 10 MB**; exceeding the cap exits non-zero with a clear error), or `--input-format stream-json` for real-time streaming input [1][2].

**[corrected in r2] The subprocess authentication failure was local, not structural.** r1 observed two `claude -p` subprocess runs failing with `Failed to authenticate: OAuth session expired and could not be refreshed` and could not tell whether this was general to subprocess invocation. It was not: after re-authenticating the machine, an identical subprocess invocation returned `is_error: False`, `terminal_reason: 'completed'` [22]. **Spawning `claude -p` as a subprocess inherits the ambient login normally.** The separate, documented point still stands on its own: `--bare` "doesn't use your subscription login" and requires `ANTHROPIC_API_KEY` or an `apiKeyHelper` [2], and `claude setup-token` exists for long-lived tokens [1] — so a host that wants reproducible, machine-independent auth has a path, but it is not forced into one.

**Observed cost, without `--bare`.** A single-turn reply of one word cost `total_cost_usd` **0.165**; a single-turn 50-line list cost **0.824** [22]. The floor is context loading rather than generation, because a `-p` run without `--bare` "loads the same context an interactive session would" [2]. The docs note both figures are client-side estimates that "can differ from your actual bill" [2]. Relevant to any per-invocation cost ceiling.

**`--bare` matters more than its name suggests.** It skips auto-discovery of hooks, skills, custom commands, subagents, plugins, MCP servers, auto memory, and `CLAUDE.md`, and the docs call it "the recommended mode for scripted and SDK calls, and will become the default for `-p` in a future release" [2].

---

## Q2 — Attach to a running session

**The headline, stated flatly: you cannot attach to a running `-p` session.** This is not an inference from missing documentation. The binary refuses the combination and explains why, exiting with code 1 [1]:

```
--bg and --print conflict: --print never starts the interactive session that
`claude agents` attaches to, so the job would be unattachable. The prompt is the
positional — drop --print: `claude --bg '<task>'`.
```

The documentation says the same thing independently: "Claude Code rejects `--bg` combined with `-p` or `--print` **before any session is created**, because `--print` never starts the interactive session that `claude agents` attaches to" [12]. Two different surfaces — the binary and the docs — agree. **The unattachability of `-p` is architectural and deliberate, not a gap.**

**But an attachable path does exist.** `claude --bg "<task>"` starts a background session; `claude attach <id>` opens it in your terminal; and "**Detaching never stops a background session**: `←`, `Ctrl+Z`, `/exit`, and double `Ctrl+C` or double `Ctrl+D` all leave it running" [12]. That is exactly the interaction idea (b) describes. Note that `claude attach` is **not listed** in the command table of `claude --help` — it was found only by probing names directly [1].

**Hidden subcommands found by direct probing** (each returns usage text despite absence from `claude --help`) [1]:

| Command | Verbatim purpose |
|---|---|
| `claude attach <id>` | "Open the background session in this terminal. ← returns to agent view, Ctrl+Z drops back to your shell. The session keeps running either way." |
| `claude stop <id>` (alias `claude kill`) | "Stop a background session. Its conversation is kept; resume it later with `claude attach <id>`." |
| `claude logs <id>` | "Print the background session's recent terminal output." |
| `claude daemon` | Supervisor lifecycle: `run`, `status`, `logs`, `stop` (`--keep-workers` leaves detached sessions running). "Service install is disabled in this version — the daemon runs on demand and exits when the last client disconnects." |
| `claude remote-control` | Exists; gated on a claude.ai subscription login. |

Probed and confirmed **not** to be commands: `resume`, `sessions`, `session`, `connect`, `join`, `tail`, `watch`, `send`, `teleport`, `serve`, `bg`, `background`, `dispatch`, `run`, `exec`, `task`, `jobs`, `ps` [1].

**Why `--bg` does not simply replace `-p` — observed directly.** Starting a background session with a pre-assigned ID produced [1]:

```
warning: --bg manages the session id; ignoring --session-id
         (use --resume <id> to continue an existing session)
```

A plain invocation (`claude --bg "<task>"`, no `--session-id`, no `--tools`) exits 0 and prints [22]:

```
Starting background service…
backgrounded · c0cc331d
  claude agents             list sessions
  claude attach c0cc331d    open in this terminal
  claude logs c0cc331d      show recent output
  claude stop c0cc331d      stop this session
```

**[corrected in r2]** r1 additionally reported that the session "started `idle` and did not run the passed prompt", cause unresolved. That was an artifact of the ignored `--session-id` and/or `--tools ""`. A plain `--bg` invocation **does run its prompt** — the run above produced its answer normally [22].

What genuinely constrains a supervising parent, after r2, is two things rather than three:

- **The ID cannot be pre-assigned.** `--bg` overrides `--session-id`, and the short ID arrives only inside human-facing stdout that a parent must scrape. (`-p` has no such problem: a parent-assigned `--session-id` is echoed back exactly [1].)
- **The result payload has no supported channel.** See below. Completion and failure *state* are supported; the answer text is not.

**[corrected in r2] Completion detection is supported, and r1's reported discrepancy does not exist.** r1 claimed the docs promised `state` and `waitingFor` fields that 2.1.220 did not emit. That was a degenerate sample — the only background session at the time never ran, and interactive sessions do not carry `state` at all. With a genuinely running background session the fields split cleanly by `kind` [22]:

| `kind` | fields observed | values observed |
|---|---|---|
| `background` | `cwd, id, kind, name, sessionId, startedAt, state` (plus `pid`, `status` while live) | `state` ∈ {`done`, `stopped`} |
| `interactive` | `cwd, kind, name, pid, sessionId, startedAt, status, waitingFor` | `status` ∈ {`busy`, `idle`, `waiting`} |

The documentation is accurate across the union of kinds, and it names `claude agents --json` as "the supported way to read session state from outside Claude Code, for example from a status bar, a scheduler, or another Claude session that supervises background work" [12]. The documented `state` enum is `working`, `blocked`, `done`, **`failed`**, `stopped` — so a parent can distinguish success from failure, not merely finished from running [12]. `waitingFor` appears when `status` is `waiting`, taking values such as `permission prompt`, `input needed`, `sandbox request`, `worker request`, and `dialog open` [12]. **The discrepancy claim is withdrawn.**

**Reading the result: it exists, and the docs disclaim it.** Two routes, neither supported:

- `claude logs <id>` returns a **raw ANSI terminal capture** — cursor-positioning escapes, 24-bit color, box-drawing borders, the welcome banner, and spinner frames. The answer is in there, embedded among control sequences. Usable only by stripping ANSI and scraping [22].
- `~/.claude/jobs/<id>/` contains `state.json`, `timeline.jsonl`, and `tmp/`. `state.json` is genuinely structured and carries what a parent wants: `state`, `detail`, **`output.result`** (observed holding the exact model output), `tokens`, `sessionId`, `resumeSessionId`, `cliVersion`, `backend`, and timestamps. `timeline.jsonl` is one object per state transition (`at`, `detail`, `state`, `text`) [22].

The second route is the one a parent would reach for, and the documentation forecloses it explicitly:

> "The files under `~/.claude/jobs/<id>/` are not a stable interface. Values that a session or another program writes to `state`, `detail`, `tempo`, or `needs` are replaced on the next update." [12]

**[corrected in r3] But there is a third route, and it is documented.** A `Stop` hook fires when the turn completes in a `--bg` session, and its stdin payload carries the answer directly. Observed keys: `background_tasks`, `cwd`, `effort`, `hook_event_name`, **`last_assistant_message`**, `permission_mode`, `prompt_id`, `session_crons`, `session_id`, `stop_hook_active`, `transcript_path` — with `last_assistant_message` holding exactly the prompted output as a plain string [23].

This is not incidental. The hooks reference directs callers to that field for this purpose:

> "Hooks that need the final assistant text of the current turn should use `last_assistant_message` on Stop and SubagentStop instead of reading the transcript" [23]

— with the rationale that "The transcript file is written asynchronously and may lag the in-memory conversation" [23], which independently corroborates the chunked transcript growth measured for Q3.

**`SessionEnd` is the wrong hook for this** and was tested alongside: it did **not** fire when the `--bg` turn completed. It fired only after `claude stop`, carrying `reason: 'other'` [23]. That matches its documented semantics — "When a session terminates" — because a `--bg` session at `state: done` is idle and awaiting more input, not ended.

So the accurate statement, after r3: **a `--bg` session's result is reachable through a documented, recommended interface.** The `state.json` route is unnecessary. What remains genuinely awkward is plumbing rather than capability — the hook is a separate subprocess, so the parent must have it write somewhere the parent is watching, and the session ID still has to be scraped from stdout.

One caveat on the injection route used here: hooks were supplied via the `--settings` CLI flag, which worked but is **not** among the documented hook locations (`~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, managed policy, plugin `hooks/hooks.json`, skill frontmatter, subagent frontmatter) [23]. A host wanting a fully documented route would use a settings file. Hooks themselves are documented to fire "wherever it runs" [23].

**Mechanisms adjacent to attach, each checked and excluded:** `--resume`/`--continue` (resume after exit, not mid-run); streaming input mode (the *parent program* feeds turns, not a human); the SDK's client object (in-process control by the parent, not external attach); cross-session messaging (plain text only — "it can't approve anything"); permission prompts (approve/deny, not free-form steering) [12][18].

**The feature request for the missing path was declined.** Issue #80954 asked for `--resume <uuid> --remote-control` to open a *completed* headless session for interaction, and records that "`-p --remote-control` is silently ignored". It was opened 2026-07-24 and is **closed as not planned** [21]. This issue is easy to find described as open, and easy to read as a pending gap. Its actual status matters: a declined request is stronger evidence that the path is not coming than a pending one would be.

**Red team: SURVIVED.** A fresh-context skeptic, given only the conclusion and a search budget but deliberately not the evidence, found no mechanism for attaching to `-p`, and independently located the same doc statement. The skeptic also found no undocumented network or daemon entry point beyond those listed above.

---

## Q3 — Lifecycle control

**Wall-clock timeout: CONFIRMED NOT SUPPORTED.** No `--timeout`, `--max-seconds` or session-duration flag appears in `claude --help` on 2.1.220 [1], and none appears in the SDK options [3][4]. The timeouts that *do* exist bound narrower things:

| Name | Kind | What it actually bounds | Default |
|---|---|---|---|
| `API_TIMEOUT_MS` | per-request | one HTTP request to the API | 600,000 ms (10 min) [19] |
| `BASH_DEFAULT_TIMEOUT_MS` | per-command | one bash command | 120,000 ms (2 min) [19] |
| `MCP_TIMEOUT` | startup | MCP server startup wait | 30 s [2] |
| `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | idle wait | how long `-p` waits for background subagents and workflows | 10 min; `0` = no limit [2] |
| `--max-turns` | iteration cap | agent-loop turns, **not** elapsed time | none [1] |
| `--max-budget-usd` | spend cap | dollars, **not** elapsed time | none [1] |

None is a wall-clock session bound. A turn cap is not a time bound: one turn can block on a slow network call. **The parent must impose the wall clock itself.**

> This negative rests on *absence* — no such flag in `--help`, no such option in the SDK, no doc statement — which is weaker evidence than a positive finding. It is consistent across all three surfaces, but it cannot be proven the way a present flag can.

> `--max-turns` is accepted by the 2.1.220 CLI but is **not listed** in `claude --help`. Established by a control test: an invented flag returns `error: unknown option`, while `--max-turns` does not [1]. Real, but hidden — and therefore without a stability guarantee.

**Kill: CONFIRMED, and unusually well specified.** On SIGTERM the documented sequence is that Claude Code "terminates the process tree of any Bash command that is still running", "then runs `SessionEnd` hooks and exits", with the process "exit[ing] with code 143"; while exiting it "starts no new tool call, sends no new model request, and runs no hook other than `SessionEnd`" [2]. A command in flight is "recorded as killed in the session". SIGINT ends the turn rather than abandoning it, as does the SDK's `interrupt()` [2]. Background sessions are killable by ID without a TTY: `claude stop <id>` [1][12].

**Resume after a kill: CONFIRMED — and this overturns a plausible-sounding negative.** The reasoning to watch for is: the session ID is only available in the final result, therefore a killed run leaves nothing to resume from. Both halves are wrong:

- The parent can **pre-assign** the ID: `--session-id <uuid>` [1]. Observed directly — the returned `session_id` echoed the assigned UUID exactly [1]. (This does **not** hold for `--bg`, which ignores it.)
- The docs state plainly: "**When you resume the session, Claude Code continues the turn that SIGTERM left unfinished**" [2].
- `--resume` also accepts "the absolute path to a session's `.jsonl` transcript file" in place of an ID [2], and since 2.1.223 finds a session by ID "in any project on this machine" [2].

**[corrected in r2] Incremental on-disk state: CONFIRMED, including timing.** Transcripts are written to `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` [1][20]. r1 could not establish whether the file grows mid-run; r2 polled a 27-second run every two seconds and it does [22]:

| t | transcript |
|---|---|
| +0 s to +4 s | absent |
| +6 s | present, 34,683 bytes |
| +8 s to +23 s | unchanged |
| +25 s | 42,257 bytes |

So **an external observer can watch a running session's transcript file** — which is a real, if limited, alternative to attaching. Two caveats: the file appears several seconds *into* the run, not at spawn; and growth is **chunked, not continuous** (two growth events across ten during-run samples), so it is a coarse progress signal rather than a stream. No flush-timing or post-kill integrity contract is documented, so this is observed behavior, not a promise. `--fork-session` branches a resumed session into a new ID [1].

---

## Q4 — Tool and filesystem scope

**Enforcement: CONFIRMED ENFORCED, for the tool-permission layer.** Permission rules, permission modes, and `PreToolUse` hooks are gates in the harness that a call must pass, not instructions the model is asked to honor [5][8]. The precedence is documented and strict, and it is **deny-first**: "A broad deny rule like `Bash(aws *)` blocks every matching call, including calls that also match a narrower allow rule… An allow rule can't carve an exception out of a deny rule" [5]. Hooks cannot loosen it: "Hook decisions don't bypass permission rules… a matching deny rule blocks the call, and a matching ask rule still prompts even when the hook returned `\"allow\"` or `\"ask\"`" [5]. Conversely a hook can tighten it: "A hook that exits with code 2 stops the tool call before permission rules are evaluated" [5]. `--permission-mode` on 2.1.220 accepts `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan` [1]; `dontAsk` "denies every call that would otherwise prompt, which is useful for locked-down CI runs" [2].

**Precedence — and the one inversion worth knowing.** "Permission rules follow the same settings precedence as all other Claude Code settings, with managed settings highest: **no other level, including command line arguments, can override a managed permission rule**" [5]. So a parent's CLI flag is *not* the strongest voice — managed settings outrank it. Read the other way, that is how a restriction becomes unbypassable from inside a session. Note also that project settings outrank user settings, which is why the docs warn that `disableAllHooks` in user settings "isn't enough, because the repository's project settings take precedence over yours and can set it back to `false`" [5].

**But the defaults are permissive, and that is the finding that matters.**

- **Reads are not confined to the working directory by default.** The fence is opt-in: "**Set** `permissions.blockReadsOutsideWorkingDirectories` to make the file tools refuse the paths it fences in every permission mode. In auto mode, Claude Code offers to turn it on the first time Claude reads outside the working directories" [5]. A setting that must be switched on — and that auto mode offers to switch on the first time a read goes outside — is off by default. Otherwise, reads outside the working directory succeed. (The settings reference documents the key and its effect but does not state a default [7]; the sentence above is what settles it.)
- **`-p` executes untrusted project configuration.** Verbatim: "Without `--bare`, a `-p` session runs the hooks in a project's `.claude/settings.json` and connects the servers in its `.mcp.json`, **even in a folder you've never trusted**. A `-p` session shows no workspace trust dialog and no per-server approval prompt" [2]. `claude --help` adds that under `-p`, "Settings files that fail validation are silently ignored in this mode (no error dialog is shown)" [1].
- **Bash rules are explicitly not a security boundary — the docs say so directly.** "A Bash rule matches the command text Claude writes… It doesn't match the same program invoked in a different form, so a deny or ask rule covers the invocation Claude usually produces and **isn't a security boundary around the program**" [5]. A deny rule on `curl` does not match `/bin/curl` or `sh -c 'curl …'`. The gate is enforced; its *coverage* is best-effort pattern matching.
- **Sandboxing can silently degrade.** When platform dependencies are missing, Claude Code falls back to running unsandboxed unless `sandbox.failIfUnavailable: true` is set; native Windows is unsupported [6].

**Network egress: mixed, and the docs prescribe the combination.** `WebFetch`/`WebSearch` domain rules are enforced [5]. For shell egress the guidance is explicit: "use deny rules to stop `curl`, `wget`, and similar commands, then use the WebFetch tool with `WebFetch(domain:github.com)` permission for allowed domains. A deny rule doesn't match the same program by path or inside `sh -c`, so pair it with the sandbox network allowlist **when the restriction must hold**" [5]. In other words: deny rules alone are insufficient for a hard egress guarantee; the OS-level sandbox's `sandbox.network.allowedDomains` is the load-bearing part [6].

**A newer-version note:** `--permission-prompts none`, the flag designed for exactly the unattended case, "requires Claude Code v2.1.259 or later. Earlier versions reject it with an unknown-option error" [2] — so it is **not available on 2.1.220**.

**Red team: SURVIVED WITH QUALIFICATION**, and one of its findings had to be corrected — see Contrary evidence.

---

## Q5 — Skills as prompt storage

**Loading: CONFIRMED.** Skills are markdown files with YAML frontmatter, discovered from personal, project, plugin, and additional-directory locations [9]. Loading is **lazy/progressive**: descriptions sit in context, and full skill text is read only on activation [9].

**Activation determinism — the pivotal distinction:**

- **Model-decided activation is not guaranteed.** The model selects a skill by judging its description against the task. The docs describe this as a relevance judgment rather than a coin flip — but it is the *model's* judgment, so a host cannot guarantee a given skill fired on a given run. [9]
- **Explicit invocation is deterministic and works headlessly.** "User-invoked skills and custom commands work in `-p` mode: include `/skill-name` in the prompt string and Claude Code expands it before running" [2].
- **System-prompt flags are fully deterministic.** `--system-prompt` (replace), `--append-system-prompt` (add), and their `-file` variants, plus `--agents <json>` for inline agent definitions [1][2]. These take literal text the host controls.

So a host that wants file-stored prompts *and* determinism can read the file and pass it via `--append-system-prompt-file`, rather than relying on the model to select a skill.

**Pinning and versioning: partial.** Individual skills carry no version field. Versioning exists at **plugin** granularity — `plugin.json` version plus git tags, with `claude plugin tag` validating that "plugin.json and any enclosing marketplace entry agree" [1][10]. A host can pin a plugin version; it cannot pin a bare skill file except through its own VCS. `claude plugin validate` lints a manifest [1]. **No checksum or signature verification of skill content was found** [9][11].

**[corrected in r2] Byte-exact provenance: CONFIRMED NOT SUPPORTED, now by experiment rather than by absence of documentation.** r1 could only say no mechanism was documented. r2 tested it directly: a unique sentinel was passed through `--append-system-prompt`, then every candidate record was searched [22].

| Candidate record | Sentinel occurrences |
|---|---|
| Session transcript `.jsonl` (11 lines, 42 KB) | **0** |
| `--debug-file` log (311 lines, 38,947 bytes of genuine debug output) | **0** |

The transcript has no system-prompt field at all: the union of line keys across the run contains `promptId`, `promptSource`, and `lastPrompt`, and all three concern the **user** prompt [22]. In the debug log, every one of the seven matches for "system" is unrelated — CA-certificate store lines and `Initialized versioned plugins system with 7 plugins`. A targeted search for a prompt hash, length, or token count found nothing [22].

The one adjacent thing that *is* available is an inventory, not the text: the `system/init` stream event reports the model, **tool names**, MCP servers, and **loaded plugins** (with `plugins`, `plugin_errors`) [2]. That tells a host *which* skill files and plugins loaded — useful for an audit trail — but not what they said.

**The honest statement: a host cannot assert "this exact prompt text was used" from any platform-provided record, and this is now an observed negative rather than an undocumented one. It can hash the files it passes and trust they were used unchanged** — a discipline the host enforces, not a guarantee the platform provides. Passing prompt text explicitly via `--system-prompt` or `--append-system-prompt` narrows that trust: the host controls the bytes at the boundary. Relying on model-selected skill loading widens it, because the host does not control even *whether* the file was read.

---

## Cross-dimension insights

What only the combination shows:

1. **[corrected in r3] The "forced trade" mostly dissolved under probing, and what is left is plumbing, not capability.** Attachability requires an interactive session and `--print` by definition never starts one, so the path split is causal rather than incidental [1][12]. But each successive probe round shrank the cost of choosing `--bg`: completion and failure state are supported [12], kill-by-ID is supported [1], and the result arrives via a documented `Stop` hook field [23]. What actually remains is that `--bg` ignores `--session-id` (so the ID is scraped) and delivers its result by push into a hook subprocess rather than as a return value. **The thing with no channel at all is still `-p` attachment.** Worth noting how this conclusion moved: r1 called the trade forced and total; two rounds of experiment reduced it to two pieces of glue code.

2. **Constraint enforcement is real, but every safe default is off.** Q4 alone reads as reassuring — the gates are genuine. Q4 plus Q1's `--bare` finding reads differently: the enforcement machinery works, and a `-p` run without `--bare` walks straight into untrusted project hooks and MCP servers with no permission prompt [2]. Getting the guarantee means opting in to several non-default settings, not merely choosing the tool.

3. **Version drift is real, but r2 shows it cuts both ways — and that unfalsified doc claims deserve a second look before being called gaps.** Q3's hidden `--max-turns` and Q4's `--permission-prompts none` gated at 2.1.259 are genuine drift [1][2]. Q2's apparently-missing `state`/`waitingFor` fields were **not** drift at all: they were a bad sample, and the docs were right [22]. The lesson for a host is the same either way — **the docs describe a moving target ahead of any pinned install** — For a host that must behave identically across machines, the surface to depend on is the narrow, long-stable one (`-p`, `--output-format json`, exit codes, `--session-id`), not the newer conveniences.

4. **Provenance and determinism are separable, and only one is available.** Q5: a host can achieve *determinism* (it controls the bytes at the boundary via `--system-prompt`) without achieving *provenance* (no record proves what was sent). Any guarantee that currently comes from prompt-drift snapshot tests in code has to be reconstructed on the host side, as file hashing plus a recorded run manifest.

---

## Contrary evidence

Both red-team passes, on Q2 and Q4, ran with fresh context: the skeptic was given only the conclusion and a search budget.

**Q2 — SURVIVED.** No mechanism was found for attaching to a running `-p` session. The skeptic independently located the same `agent-view.md` statement that the binary emits, which is genuine two-surface confirmation rather than an echo. The skeptic's strongest counter-argument is not that `-p` is attachable, but that **the requirement can be met another way** — via `--bg` + `attach`, or `remote-control`. That counter-argument is accepted and is reflected in the Q2 verdict.

**Q4 — SURVIVED WITH QUALIFICATION, and required one correction.** The skeptic surfaced five CVEs as live risks against 2.1.220. **A dedicated verification pass established that all five were patched in versions well below the installed one** [13][14][15][16][17]:

| CVE | What it was | Fixed in | 2.1.220 affected? |
|---|---|---|---|
| CVE-2025-55284 | command injection via permissive allowlist | 1.0.4 | **No** |
| CVE-2025-52882 | WebSocket auth bypass in IDE extensions | 1.0.24 | **No** |
| CVE-2025-59536 | pre-trust hook RCE via `settings.json` | 1.0.111 | **No** |
| CVE-2026-21852 | API key exfiltration via `ANTHROPIC_BASE_URL` | 2.0.65 | **No** |
| CVE-2026-46406 | insecure temp file, symlink escalation | 2.1.128 | **No** |

The highest fix version, 2.1.128, is strictly below 2.1.220. **Stating any of these as current risk would be a false claim** and they are excluded from the findings above. The technical-research pack's rule — check whether a pain point has since been fixed before citing it — is what caught this.

---

## Open questions

**All six questions r1 left open are now closed** by the r2 probes. They are kept below, marked, so the roundtable can see what was settled and how — a closed question with its method recorded is worth more than a deleted one.

| # | Question | Status |
|---|---|---|
| 1 | Does the transcript grow *during* a run? | **CLOSED — yes.** Appears about 6 s into a 27 s run and grows before exit, in chunks rather than continuously [22]. See Q3. |
| 2 | Is the subprocess auth failure general or local? | **CLOSED — local.** Re-authenticating fixed it; subprocess `-p` inherits the ambient login [22]. See Q1. |
| 3 | Do `state` and `waitingFor` exist on 2.1.220? | **CLOSED — yes, and r1 was wrong.** They split by session `kind`; r1's sample had no running background session [22]. See Q2. |
| 4 | Why did the `--bg` session start idle? | **CLOSED — probe artifact.** Caused by the ignored `--session-id` and/or `--tools ""`; a plain `--bg` runs its prompt [22]. See Q2. |
| 5 | Does any record hold the system prompt? | **CLOSED — no.** Sentinel absent from both the transcript and a 311-line debug log [22]. See Q5. |
| 6 | Does `SessionEnd` fire usefully on `--bg` completion? | **CLOSED — no, and `Stop` does instead.** `SessionEnd` fires only on termination (`reason: 'other'`); `Stop` fires at turn completion carrying `last_assistant_message` [23]. See Q2. |

**Still open:**

1. **Is `~/.claude/jobs/<id>/state.json` stable enough to depend on in practice, despite being disclaimed?** It is the only structured route to a `--bg` session's result, and the docs say the directory "is not a stable interface" [12]. The question is empirical: how often does its shape actually change? **To settle:** record the `state.json` key set now, re-record it after each Claude Code upgrade for a few releases, and diff. That turns a written disclaimer into a measured churn rate.
2. **Does the wall-clock-timeout negative survive a version bump?** It rests on absence across `--help`, the CLI reference, and the SDK options [1][2]. **To settle:** re-check on the next release; this is the staleness map's first row.

## Source appendix

| [n] | What it supports | Publisher | Pub date | Accessed | Confidence |
|---|---|---|---|---|---|
| [1] | Installed-binary behavior: all `--help` output, hidden subcommands, observed JSON result shape, `is_error`/`subtype` mismatch, `--session-id` echo, `-p --bg` rejection, `--bg` ID warning, `agents --json` schema, unknown-flag control test, auth failures | Local probe, `claude` 2.1.220 — captured in `digests/local-cli-help-primary-source.md` and `digests/local-behavioural-probe-results.txt` | observed 2026-09-16 | 2026-09-16 | high |
| [2] | Headless mode: exit codes, SIGTERM/143, resume-continues-unfinished-turn, JSON fields, 10 MB stdin cap, `--bare` semantics, untrusted-project-config behavior, `/skill-name` in `-p`, `system/init` fields, `--permission-prompts none` version gate | [code.claude.com — Run Claude Code programmatically](https://code.claude.com/docs/en/headless.md) | undated | 2026-09-16 | high |
| [3] | Python Agent SDK entry points and options | [code.claude.com — Agent SDK (Python)](https://code.claude.com/docs/en/agent-sdk/python) | undated | 2026-09-16 | medium |
| [4] | TypeScript Agent SDK entry points and options | [code.claude.com — Agent SDK (TypeScript)](https://code.claude.com/docs/en/agent-sdk/typescript) | undated | 2026-09-16 | medium |
| [5] | Deny-first rule precedence; managed settings outranking CLI arguments; hook-vs-rule interaction; "isn't a security boundary around the program"; the opt-in read fence; the prescribed deny+WebFetch+sandbox combination for egress | [code.claude.com — Permissions](https://code.claude.com/docs/en/permissions.md) | undated | 2026-09-16 | high (verbatim quotes checked first-hand) |
| [6] | Sandboxing, `failIfUnavailable`, network allowlists, platform limits | [code.claude.com — Sandboxing](https://code.claude.com/docs/en/sandboxing.md) | undated | 2026-09-16 | medium |
| [7] | Existence and effect of `blockReadsOutsideWorkingDirectories` ("Make the file tools refuse reads outside the working directories in every permission mode"). **Does not state a default** — the default is established by [5] instead | [code.claude.com — Settings reference](https://code.claude.com/docs/en/settings-reference.md) · [Managed settings](https://code.claude.com/docs/en/managed-settings.md) | undated | 2026-09-16 | medium |
| [8] | `PreToolUse` hook interception, exit-code-2 block, `SessionEnd` | [code.claude.com — Hooks](https://code.claude.com/docs/en/hooks.md) | undated | 2026-09-16 | high |
| [9] | Skill discovery locations, frontmatter, lazy loading, probabilistic activation | [code.claude.com — Skills](https://code.claude.com/docs/en/skills.md) | undated | 2026-09-16 | high |
| [10] | Plugin-level versioning and dependency resolution | [code.claude.com — Plugin dependencies](https://code.claude.com/docs/en/plugin-dependencies.md) | undated | 2026-09-16 | medium |
| [11] | Absence of a prompt-provenance mechanism (searched, not found) | Q5 digest — negative result across skills, SDK, telemetry docs | n/a | 2026-09-16 | medium |
| [12] | `-p`/`--bg` rejection and its reason; attach/detach semantics; background ID surfacing; `claude agents --json` as "the supported way to read session state"; the documented `state` enum (`working`/`blocked`/`done`/`failed`/`stopped`) and the `waitingFor` values; **"The files under `~/.claude/jobs/<id>/` are not a stable interface"** | [code.claude.com — Agent view](https://code.claude.com/docs/en/agent-view.md) | undated | 2026-09-16 | high |
| [13] | CVE-2025-55284 fixed in 1.0.4 | [GitHub Security Advisories](https://github.com/advisories/GHSA-9f65-56v6-gxw7) | 2025 | 2026-09-16 | high |
| [14] | CVE-2025-52882 fixed in 1.0.24 | [GitHub Security Advisories](https://github.com/advisories/GHSA-4fgq-fpq9-mr3g) · [Datadog Security Labs](https://securitylabs.datadoghq.com/articles/claude-mcp-cve-2025-52882/) | 2025 | 2026-09-16 | high |
| [15] | CVE-2025-59536 fixed in 1.0.111 | [GitHub Security Advisories](https://github.com/advisories/GHSA-jh7p-qr78-84p7) · [Check Point Research](https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/) | 2026 | 2026-09-16 | high |
| [16] | CVE-2026-21852 fixed in 2.0.65 | [GitHub Security Advisories](https://github.com/advisories/GHSA-4vp2-6q8c-pvq2) | 2026 | 2026-09-16 | high |
| [17] | CVE-2026-46406 fixed in 2.1.128 | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-46406) | 2026 | 2026-09-16 | medium |
| [18] | Cross-session messaging limits ("it can't approve anything") | [code.claude.com — Cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging.md) | undated | 2026-09-16 | medium |
| [19] | `API_TIMEOUT_MS`, `BASH_DEFAULT_TIMEOUT_MS` defaults | [code.claude.com — Environment variables](https://code.claude.com/docs/en/env-vars.md) | undated | 2026-09-16 | high |
| [20] | Session storage location and resume-by-id semantics | [code.claude.com — Agent SDK session management](https://code.claude.com/docs/en/agent-sdk/session-management.md) | undated | 2026-09-16 | high |
| [23] | **r3 hook-lifecycle probe + hooks reference:** `Stop` fires on `--bg` turn completion carrying `last_assistant_message` (observed holding the exact output); `SessionEnd` fires only on termination with `reason: 'other'`; the documented recommendation to prefer `last_assistant_message` over the transcript; documented hook locations; hooks fire "wherever it runs" | Local probe, `claude` 2.1.220 (`digests/probe-set-2-authenticated-r4.md` §G) + [code.claude.com — Hooks](https://code.claude.com/docs/en/hooks.md) | undated | 2026-09-16 | high |
| [22] | **r2 authenticated probe set:** transcript growth during a run; sentinel absent from transcript and debug log; success-vs-failure result fields; `--bg` running its prompt; the `state`/`status` field split by session kind; `claude logs` ANSI capture; `state.json` keys including `output.result`; observed costs | Local probe, `claude` 2.1.220 — captured in `digests/probe-set-2-authenticated-r4.md` | observed 2026-09-16 | 2026-09-16 | high |
| [21] | GH issue #80954 — real, opened 2026-07-24, **closed as not planned**; "`-p --remote-control` is silently ignored" | [anthropics/claude-code#80954](https://github.com/anthropics/claude-code/issues/80954) | 2026-07-24 | 2026-09-16 | high |

---

## Staleness map

Based on the technical-research pack's freshness bars. **Version and compatibility claims carry a one-month window and dominate this report** — most findings here are version-pinned CLI behavior, and the docs already describe builds newer than the one probed.

Dates computed with `recon_kit.py staleness`, windows `{version:1, behavior:1, ecosystem:6, landscape:3}` months.

| Claim class | Bar | Re-check by | What specifically to re-check |
|---|---|---|---|
| Version, compatibility, and observed behavior — flags, hidden subcommands, JSON field names, `is_error`/`subtype` mismatch, `--bg` ID handling, `state`/`waitingFor` presence | ≤ 1 month | **2026-10-01** | Re-run the `--help` capture and the recorded probes against the then-current build and diff against `digests/`; the `state`/`waitingFor` gap may close on upgrade |
| Security posture — CVE currency, permissive defaults | ≤ 1 month | **2026-10-01** | Re-check GitHub Security Advisories for Claude Code; confirm `blockReadsOutsideWorkingDirectories` still defaults off |
| Ecosystem — skills/plugin versioning model | ≤ 6 months | 2027-03-01 | Whether per-skill versioning or content signing has landed |
| Landscape (AI-adjacent) — the `-p` vs `--bg` split itself | ≤ 3 months | 2026-12-01 | Whether the attachable path gains a supported result contract |
| Disclaimed interface — `~/.claude/jobs/<id>/state.json` key set | ≤ 1 month | **2026-10-01** | Re-record the key set and diff it; the docs disclaim the directory, so measure its actual churn (open question 1) |

**Earliest re-check: 2026-10-01** — one month, driven by the version/compatibility class; `stale_count` is 0 today. Given that the docs already run ahead of the installed build, re-verifying a specific flag before acting on it is worth more here than in most technical research. A Refresh run against this folder is the mechanism.
