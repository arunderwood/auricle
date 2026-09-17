# Probe set 2 — run with working authentication (2026-09-16, later same day)

Probe set 1 ran while the local OAuth session was expired, so every model call failed at
authentication. After re-authentication these probes re-ran the blocked tests. All observations are
on **Claude Code 2.1.220**.

Raw transcript-level output is deliberately not pasted here: `claude logs` emits a full ANSI terminal
capture that included the account holder's name and email in the session header. Only shapes, field
names, and enum values are recorded.

---

## A — Subprocess authentication: the earlier failure was local, not structural

A plain `claude -p` subprocess now succeeds:

```
is_error       = False
subtype        = 'success'
terminal_reason = 'completed'
result         = 'pong'
num_turns      = 1
total_cost_usd = 0.16458
```

**Conclusion:** probe set 1's repeated `Failed to authenticate: OAuth session expired and could not
be refreshed` was expired local credential state. It is **not** a general property of spawning
`claude` as a subprocess. The earlier `disputed` claim is resolved and must not be reported as a
constraint on subprocess invocation.

---

## B — Transcript IS written during the run (overturns "post-completion only")

A 27-second `-p` run with a parent-assigned `--session-id`, polling the transcript every 2 s:

| t | transcript |
|---|---|
| +0 s | absent |
| +2 s | absent |
| +4 s | absent |
| +6 s | **present, 34,683 bytes** |
| +8 s … +23 s | present, 34,683 bytes (unchanged) |
| +25 s | present, **42,257 bytes** |
| exit | 42,257 bytes, 11 lines, exit code 0 |

**Conclusion:** the `.jsonl` appears roughly 6 s into the run and grows before the run ends, so an
external observer *can* watch a running session's file. Growth is **chunked, not continuous** — two
growth events across ten during-run samples. Real-time observation is therefore possible but
coarse-grained, and no flush-timing contract is documented.

---

## C — Provenance: the system prompt is NOT recorded anywhere reachable

Method: pass a unique sentinel through `--append-system-prompt`, then search every candidate record.

Sentinel: `ZZQQ-SENTINEL-7F3A9B-PROVENANCE`

| Candidate record | Sentinel occurrences | Notes |
|---|---|---|
| Session transcript `.jsonl` (11 lines, 42 KB) | **0** | |
| `--debug-file` log (311 lines, 38,947 bytes of genuine debug output) | **0** | |

Transcript line `type` values observed: `queue-operation` ×2, `user` ×1, `attachment` ×3,
`last-prompt` ×2, `file-history-snapshot` ×1, `assistant` ×2.

Union of transcript line keys — **no system-prompt field exists**:
`attachment, content, cwd, effort, entrypoint, gitBranch, isSidechain, isSnapshotUpdate, lastPrompt,
leafUuid, message, messageId, operation, parentUuid, permissionMode, promptId, promptSource,
requestId, sessionId, snapshot, timestamp, type, userType, uuid, version`

The three prompt-named keys (`promptId`, `promptSource`, `lastPrompt`) all concern the **user** prompt,
not the system prompt.

In the debug log, all 7 matches for "system" are unrelated — CA-certificate store lines and
`Initialized versioned plugins system with 7 plugins`. A targeted search for a prompt hash, length,
or token count found nothing.

**Conclusion:** Q5's provenance verdict upgrades from *UNVERIFIABLE FROM DOCS* to **CONFIRMED NOT
SUPPORTED (observed)**. Neither the transcript nor the debug log records the system prompt text, and
neither records a digest of it.

---

## D — `--bg` runs its prompt, and is better supervised than probe set 1 suggested

`claude --bg "Write the word pong and nothing else."` (no `--session-id`, no `--tools`):

```
Starting background service…
backgrounded · c0cc331d
  claude agents             list sessions
  claude attach c0cc331d    open in this terminal
  claude logs c0cc331d      show recent output
  claude stop c0cc331d      stop this session
```

Exit code 0. **The prompt ran and produced `pong`.** Probe set 1's "started idle without running the
prompt" was an artifact of passing `--session-id` (which `--bg` ignores) and/or `--tools ""`.

### D1 — `state` exists; probe set 1's "documented-vs-observed discrepancy" was a false alarm

Probe set 1 reported that `state` and `waitingFor` were absent from `claude agents --json`. That was a
degenerate sample: the only background session at the time never ran, and interactive sessions do not
carry `state`. With a genuinely running background session the fields split cleanly by `kind`:

| `kind` | fields | observed values |
|---|---|---|
| `background` | `cwd, id, kind, name, sessionId, startedAt, state` (+`pid`, `status` while live) | `state` ∈ {`done`, `stopped`} |
| `interactive` | `cwd, kind, name, pid, sessionId, startedAt, status, waitingFor` | `status` ∈ {`busy`, `idle`, `waiting`} |

The documentation's instruction to read `state`, `status`, and `waitingFor` is accurate across the
union of session kinds. **The discrepancy claim was wrong and is withdrawn.**

Documented `state` enum (agent-view.md): `working`, `blocked`, `done`, **`failed`**, `stopped`.
Documented `waitingFor` values: `permission prompt`, `input needed`, `sandbox request`,
`worker request`, `dialog open`.

`claude agents --json` is described as "the supported way to read session state from outside Claude
Code, for example from a status bar, a scheduler, or another Claude session that supervises background
work."

### D2 — `claude logs <id>` is an ANSI terminal capture, not parseable output

Output is a literal terminal screen dump: cursor-positioning escapes, 24-bit colour codes, box-drawing
borders, the welcome banner, and spinner frames (`Marinating…`, `Brewed for 2s`). The answer text
`pong` is present but embedded among control sequences. Usable only by stripping ANSI and scraping.

### D3 — `~/.claude/jobs/<id>/` holds a structured result, which the docs disclaim

Directory contents: `state.json` (1,202 B), `timeline.jsonl` (85 B), `tmp/`.

`state.json` keys, with the decision-relevant values:

```
state        = 'done'          <- completion signal
detail       = 'wrote pong'
output.result = 'pong'         <- THE FINAL MODEL OUTPUT, machine-readable
tokens       = 4
sessionId, resumeSessionId     (equal in this run)
cliVersion   = '2.1.220'
backend      = 'daemon'
createdAt, updatedAt, firstTerminalAt
inFlight     = {tasks:int, queued:int, kinds:list}
intent, template, respawnFlags[2], children, linkScanOffset, linkScanPath, providerEnv, cwd
```

`timeline.jsonl` is one JSON object per state transition: keys `at, detail, state, text`.

**But the documentation explicitly disclaims this directory:**

> "The files under `~/.claude/jobs/<id>/` are not a stable interface. Values that a session or another
> program writes to `state`, `detail`, `tempo`, or `needs` are replaced on the next update."

**Conclusion:** a `--bg` session's final result *is* available as structured JSON today, in
`state.json` → `output.result`, but that location is explicitly not a supported contract.
**Superseded by section G:** there IS a documented route to the result — a `Stop` hook's
`last_assistant_message` — so `state.json` is not the only option and need not be relied on.

### D4 — Corrected supervision picture for `--bg`

| What a parent needs | `-p` | `--bg` |
|---|---|---|
| Assign session ID up front | yes (`--session-id`) | **no** — `--bg` ignores it |
| Learn session ID | in result JSON | scrape human-facing stdout |
| Detect completion | process exit | **yes, supported** — `state: done` |
| Detect failure | `is_error` / `terminal_reason` | **yes, supported** — `state: failed` |
| Read final result payload | **yes, documented** (`result`) | **yes, documented** — `Stop` hook `last_assistant_message` (section G); also disclaimed `state.json`, or ANSI scraping |
| Enforce wall clock | parent's job | parent's job |
| Kill by ID without a TTY | signal the PID | **yes** — `claude stop <id>` |
| Human attach mid-run | **no** | **yes** — `claude attach <id>` |
| Push signal on turn completion | n/a (process exit) | **yes** — `Stop` hook (section G) |

---

## E — Observed cost, without `--bare`

| Run | Output | `total_cost_usd` |
|---|---|---|
| "Reply with exactly: pong" | one word | **0.16458** |
| 50-line numbered trivia list | 3,816 chars | **0.82382** |

Both single-turn (`num_turns: 1`). The floor is context loading, not generation — a `-p` run without
`--bare` loads the same context an interactive session would. The docs note these figures are
client-side estimates that "can differ from your actual bill."

---

## F — Result-object error signalling, both cases now observed

| Field | Successful run | Failed run (auth) |
|---|---|---|
| `is_error` | `False` | `True` |
| `subtype` | `'success'` | `'success'` |
| `terminal_reason` | `'completed'` | `'api_error'` |
| `stop_reason` | `'end_turn'` | `'stop_sequence'` |
| exit code | 0 | 1 |

**`subtype` read `'success'` in both cases** — it carries no failure signal whatsoever. `is_error` and
`terminal_reason` are the discriminating fields. Parent-assigned `--session-id` was echoed back
exactly in the result (`session_id_matches_assigned = True`).

---

## G — Hook lifecycle on a `--bg` session (r3 addition; closes r2 open question 2)

Method: a `Stop` hook and a `SessionEnd` hook, both recording their stdin JSON to a file, injected
via `--settings <file>` on a `claude --bg` invocation. Observed state transitions: `working` → `done`.

| Phase | Event fired | When |
|---|---|---|
| Turn completed (`state: done`), before any stop | **`Stop` only** | 18:40:02 |
| After `claude stop <id>` | **`SessionEnd`** | 18:40:06 |

**`SessionEnd` does NOT fire on `--bg` turn completion.** It fires on session *termination*, matching the
documented semantics ("When a session terminates"). Its payload: `reason: 'other'`, plus `cwd`,
`hook_event_name`, `prompt_id`, `session_id`, `transcript_path`.

**`Stop` DOES fire on turn completion, and carries the result.** Payload keys:
`background_tasks, cwd, effort, hook_event_name, last_assistant_message, permission_mode, prompt_id,
session_crons, session_id, stop_hook_active, transcript_path`.

`last_assistant_message` held exactly `'ping'` — the prompted output — as a plain string.
`transcript_path` pointed at a real file. `stop_hook_active` was `False`.

**This is a documented contract, not an accident.** The hooks reference states:

> "Hooks that need the final assistant text of the current turn should use `last_assistant_message` on
> Stop and SubagentStop instead of reading the transcript"

with the rationale that "The transcript file is written asynchronously and may lag the in-memory
conversation" — which independently corroborates the chunked transcript growth measured in section B.

Hooks are documented to fire "wherever it runs: sessions in the terminal, IDE extensions, the Desktop
app, and cloud sessions."

**Caveat on the injection route:** supplying hooks through the `--settings` CLI flag is *observed* to
work with `--bg` but is not listed among the documented hook locations (`~/.claude/settings.json`,
`.claude/settings.json`, `.claude/settings.local.json`, managed policy, plugin `hooks/hooks.json`,
skill frontmatter, subagent frontmatter). A host wanting a documented route would use a settings file.

**Consequence:** a `--bg` session's result *does* have a supported channel. The remaining rough edges
on that path are (a) the session ID must be scraped from human-facing stdout, and (b) the result
arrives as a **push into a hook subprocess**, so the spawning parent must bridge it — write it where
the parent is watching — rather than reading it as a return value.
