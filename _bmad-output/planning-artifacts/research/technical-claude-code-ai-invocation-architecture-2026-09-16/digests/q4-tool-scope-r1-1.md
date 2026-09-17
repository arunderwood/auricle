# Q4: Tool and filesystem scope — digest

**Inquiry date:** 2026-09-16  
**Claude Code version observed:** 2.1.220  
**Research question:** Can Claude Code / Agent SDK constrain sessions to specific tools and filesystem, and is that ENFORCED or ADVISORY?

---

## Verdicts

| Sub-question | Verdict | Mechanism | Evidence |
|---|---|---|---|
| 1. Tool allow/deny | CONFIRMED ENFORCED | CLI flags (`--allowed-tools`, `--disallowed-tools`), settings keys (`permissions.allow`, `permissions.deny`), SDK options (`allowedTools`, `disallowedTools`) | https://code.claude.com/docs/en/permissions.md line 68; `claude --help` 2.1.220 |
| 2. Filesystem scope | CONFIRMED NOT CONFINED BY DEFAULT | Read-only tools can read anywhere user can; writes limited to working dirs + `additionalDirectories` | https://code.claude.com/docs/en/permissions.md line 16; line 261 references `blockReadsOutsideWorkingDirectories` |
| 3. Permission modes | CONFIRMED ENFORCED | Six modes: `default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`, `auto` | https://code.claude.com/docs/en/permission-modes.md; Agent SDK docs confirm same modes |
| 4. Override precedence | CONFIRMED MANAGED SETTINGS PREVENT OVERRIDE | Managed settings have highest precedence; subagents inherit parent; some deny rules unbypassable | https://code.claude.com/docs/en/managed-settings.md; Agent SDK permissions flow doc |
| 5. Programmatic interception | CONFIRMED ENFORCED | PreToolUse hook fires before execution, sees all args, can deny via exit code 2 | https://code.claude.com/docs/en/hooks.md |
| 6. OS-level sandboxing | UNVERIFIABLE FROM DOCS | Docs mention "OS-level sandboxing" in permission overview but no details on impl or platforms | https://code.claude.com/docs/en/claude_code_docs_map.md fetch result |
| 7. Network egress | CONFIRMED ADVISORY FOR BASH, ENFORCED FOR WEBFETCH/WEBSEARCH | WebFetch/WebSearch can be denied; Bash network commands can be patterned but rules don't block alternative forms (e.g., `/bin/curl` bypasses `Bash(curl *)`) | https://code.claude.com/docs/en/permissions.md line 290-295 |

---

## Enforcement table (the load-bearing artifact)

| Mechanism | What it constrains | ENFORCED / ADVISORY / UNVERIFIABLE | What establishes that | Can it be overridden from inside session? | Evidence |
|---|---|---|---|---|---|
| Permission rules (deny/ask/allow) | Which tools can be called | **ENFORCED** | "Permission rules are enforced by Claude Code, not by the model" (permissions.md line 68) | NO: deny rules apply even in `bypassPermissions`; managed settings prevent override | https://code.claude.com/docs/en/permissions.md line 68, line 90 |
| Deny rules with specifiers (e.g. `Bash(rm *)`) | Specific tool invocations | **ENFORCED** | Tool-call text matched at execution; violation blocked; examples show predictable coverage/gaps | Partial: text-based match; `/bin/rm` or `sh -c 'rm'` bypass the pattern rule | https://code.claude.com/docs/en/permissions.md lines 243–255 |
| Working directory scope (cwd + additionalDirectories) | File reads in `default` mode | **ENFORCED** for `acceptEdits`/`plan`; **ADVISORY** for `default`/`bypassPermissions` in `default` mode read-only tool can read outside working dirs | Read-only commands auto-approved within working dirs per line 16; outside needs approval in `default` mode unless `blockReadsOutsideWorkingDirectories` is false | YES (in `default`/`bypassPermissions` modes user can approve reads anywhere) | https://code.claude.com/docs/en/permissions.md lines 16, 261 |
| `blockReadsOutsideWorkingDirectories` | File read access | **ENFORCED** (when true) | Setting; when enabled, read tools refuse access outside working dirs in all modes | NO: can be set in managed settings | https://code.claude.com/docs/en/settings-reference.md; https://code.claude.com/docs/en/managed-settings.md |
| Permission mode (`bypassPermissions`, `dontAsk`, etc.) | Tool auto-approval logic | **ENFORCED** | Each mode follows a documented evaluation flow (6 steps in Agent SDK); hooks/rules applied before mode decision | Subagents inherit parent mode; cannot escalate from `default` → `bypassPermissions` inside session | https://code.claude.com/docs/en/agent-sdk/permissions.md flow diagram |
| Managed settings | All permission/auth/telemetry settings | **ENFORCED** (highest precedence) | Delivered via MDM/registry/file; applied above user/project/local; security-sensitive settings not overridable | NO: documented as "apply above every other level" with limited exceptions for stricter values | https://code.claude.com/docs/en/managed-settings.md intro |
| PreToolUse hook | Tool calls (before execution) | **ENFORCED** | Hook spawned before tool runs; exit code 2 blocks unconditionally; tool sees full input JSON | NO: hook is parent-controlled; enforced by harness, not bypassable | https://code.claude.com/docs/en/hooks.md; https://code.claude.com/docs/en/agent-sdk/hooks.md |
| `canUseTool` callback (SDK) | Tool calls (at approval stage) | **ADVISORY** (callback can deny, but only at approval step; auto-approved calls skip it) | Documented as falling through only when hook/deny/ask/mode don't resolve; auto-approved calls bypass callback | YES: a bare allow rule or `bypassPermissions` mode can approve before callback is reached | https://code.claude.com/docs/en/agent-sdk/permissions.md warning box |
| `--dangerously-skip-permissions` / `allowDangerouslySkipPermissions` | All permission checks | **ENFORCED** (when set) | Flag/option disables manual/auto/dontAsk modes in favor of `bypassPermissions`-like behavior | YES (can be enabled at CLI or SDK call) but managed settings can disable the option with `permissions.disableBypassPermissionsMode` | `claude --help` 2.1.220; permissions.md line 90 |
| WebFetch domain allowlist | Network requests via WebFetch | **ENFORCED** | Domain rules in `permissions.allow` / `permissions.deny` matched at request time | NO: deny rules enforced even in `bypassPermissions`; managed settings precedence | https://code.claude.com/docs/en/permissions.md tool-specific rules section |
| Bash pattern rules for network (e.g. `Bash(curl http://github.com *)`) | Network via Bash | **ADVISORY** (fragile text match) | Rule matches command text; doesn't match variations like `-X` before URL, `https://`, redirects, variable expansion, `/usr/bin/curl`, `sh -c 'curl'` | YES (easily bypassed via alternate command form) | https://code.claude.com/docs/en/permissions.md lines 280–295 |

---

## Claims

1. **Default filesystem scope is not confined to cwd** — By default, Claude Code's read-only tools (cat, ls, grep, etc.) can read files anywhere the user can; writes are confined to working directories + `additionalDirectories`. Setting `blockReadsOutsideWorkingDirectories: true` restricts reads. | https://code.claude.com/docs/en/permissions.md line 16 + line 261 | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | HIGH | **mechanism**: documented behavior

2. **Permission rules are enforced by Claude Code's harness, not the model** — Explicit statement: "Permission rules are enforced by Claude Code, not by the model. Instructions in your prompt or `CLAUDE.md` shape what Claude tries to do, but they don't change what Claude Code allows." | https://code.claude.com/docs/en/permissions.md line 68 | Anthropic | undated (documentation) | accessed 2026-09-16 | HIGH | **mechanism**: enforcement architecture

3. **Deny rules are enforced even in bypassPermissions mode** — "If a deny rule matches, the tool is blocked, even in `bypassPermissions` mode. Bare-name deny rules like `Bash` remove the tool from Claude's context before this evaluation begins, so only scoped rules like `Bash(rm *)` are checked at this step." | https://code.claude.com/docs/en/agent-sdk/permissions.md | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | HIGH | **mechanism**: permission evaluation order

4. **Managed settings have the highest precedence and cannot be overridden by user/project/local settings** — "Claude Code applies them above every other level, so no user, project, local, or `--settings` value overrides them, apart from a few security-sensitive exceptions where a stricter value from a lower level still counts." | https://code.claude.com/docs/en/managed-settings.md intro | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | HIGH | **mechanism**: settings hierarchy

5. **PreToolUse hooks can deny tool calls and are enforced by the harness** — Hooks fire before tool execution, receive full tool input JSON, can deny with exit code 2 or JSON `permissionDecision: "deny"`. Denial is enforced by Claude Code, not bypassable. | https://code.claude.com/docs/en/hooks.md; https://code.claude.com/docs/en/agent-sdk/hooks.md | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | HIGH | **mechanism**: hook execution

6. **Bash pattern rules for network access are fragile and bypassable** — A rule like `Bash(curl http://github.com *)` doesn't match alternative forms: `/usr/bin/curl`, `curl https://` (protocol change), variables, redirects, `sh -c 'curl'`. For reliable filtering, docs recommend deny + WebFetch domain allowlist + sandbox. | https://code.claude.com/docs/en/permissions.md lines 280–295 | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | MEDIUM | **behavior**: documented limitation

7. **`bypassPermissions` mode auto-approves all tools except critical-path removals (rm/rmdir on .git/.claude)** — "In `bypassPermissions` mode, Claude Code skips permission prompts, including for writes to protected paths such as `.git` and `.claude`. Only use this mode in isolated environments." | https://code.claude.com/docs/en/permission-modes.md warning section | Anthropic | 2026-09-16 docs fetch | accessed 2026-09-16 | HIGH | **mechanism**: permission mode behavior

8. **CLI flags and settings can restrict tools; see tool names in `claude --help`** — Binary provides `--allowed-tools` (whitelist), `--disallowed-tools` (blacklist), `--permission-mode` (mode choice). Tool names include `Bash`, `Edit`, `Write`, `Read`, `Grep`, `WebFetch`, `WebSearch`, `Agent`, `AskUserQuestion`, `mcp__*` (MCP tools by server). | `claude --help 2.1.220` observed 2026-09-16 | Anthropic | undated | accessed 2026-09-16 | HIGH | **mechanism**: CLI interface

---

## Verbatim evidence

### From `claude --help` (2.1.220, observed 2026-09-16):
```
--allowedTools, --allowed-tools <tools...>
    Comma or space-separated list of tool names to allow (e.g. "Bash(git *)
    Edit")

--disallowedTools, --disallowed-tools <tools...>
    Comma or space-separated list of tool names to deny (e.g. "Bash(git *)
    Edit")

--permission-mode <mode>
    Permission mode to use for the session
    (choices: "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")

--add-dir <directories...>
    Additional directories to allow tool access to

--dangerously-skip-permissions
    Bypass all permission checks. Recommended only for sandboxes with no
    internet access.

--allow-dangerously-skip-permissions
    Enable bypassing all permission checks as an option, without it being enabled
    by default. Recommended only for sandboxes with no internet access.
```

### From permissions.md (https://code.claude.com/docs/en/permissions.md):
```
Line 68: "Permission rules are enforced by Claude Code, not by the model. 
Instructions in your prompt or CLAUDE.md shape what Claude tries to do, but 
they don't change what Claude Code allows."

Line 16: "No, within the [working directory and additional directories]"
[for read-only tools in default mode]

Line 261: "Claude Code recognizes a built-in set of Bash commands as read-only 
and runs them without a permission prompt in every mode, except for a path that 
[`permissions.blockReadsOutsideWorkingDirectories`] fences."

Line 290-295: "For more reliable URL filtering, consider:
- Restrict Bash network tools: use deny rules to stop curl, wget, and similar 
  commands, then use the WebFetch tool with WebFetch(domain:github.com) 
  permission for allowed domains. A deny rule doesn't match the same program 
  by path or inside sh -c, so pair it with the [sandbox network allowlist] 
  when the restriction must hold"
```

### From agent-sdk/permissions.md (Agent SDK enforcement flow):
```
Step 1 (Hooks): Run hooks first. A hook can deny outright or pass it on.
Step 2 (Deny rules): Check deny rules. If a deny rule matches, the tool is 
  blocked, even in bypassPermissions mode.
Step 3 (Ask rules): Check ask rules. If matched, falls through to canUseTool 
  callback for confirmation.
Step 4 (Permission mode): Apply permission mode. In bypassPermissions, approves 
  everything that reaches this step except rm/rmdir on critical paths.
Step 5 (Allow rules): Check allow rules. If matched, tool is approved.
Step 6 (canUseTool callback): If not resolved by above, call callback.
```

---

## Leads worth chasing

1. **OS-level sandbox details** — Docs mention "OS-level sandboxing" restricting file system and network on Linux/WSL2, but no platform matrix or enforcement specifics. Query: "Claude Code sandbox Linux Windows macOS implementation details" + GitHub issues about seccomp/seatbelt/AppArmor.

2. **Managed settings—security-sensitive exceptions** — Docs state "a few security-sensitive exceptions where a stricter value from a lower level still counts." Which settings qualify? Unresolved.

3. **Agent SDK vs. CLI parity** — Agent SDK docs confirm same permission modes and rules, but does it share the same underlying enforcement harness or implement its own? (Implication: is there a surface where SDK can deviate?)

4. **Subagent permission escalation** — Docs say subagent can't escape `bypassPermissions` from parent, but can a subagent _in plan mode_ be spawned with higher permissions mid-parent-session? Untested.

5. **MCP tool permissions** — MCP tools can be filtered via `mcp__server__tool` deny rules. Are those enforced the same way as built-in tools, or does a buggy MCP server implementation bypass them?

---

## Searched for and could not find

1. **Exact filesystem confinement enforcement mechanism** — How does Claude Code prevent file tool calls outside working directories at the OS level vs. at the model/API layer? Is it a sandbox syscall check or a client-side path validation?

2. **Network egress sandbox matrix** — On which platforms is network traffic actually blocked at the OS level? (Docs mention Linux/WSL2, but is it enforced on macOS or via application-level rules only?)

3. **Rate of permission bypass reports** — GitHub issues closed as security/wontfix that document actual bypasses. (Docs reference them as possibilities, e.g., shell wrappers, but no public CVE or disclosure tracker found.)

4. **Subagent permission inheritance in detail** — Full spec of which permission settings subagents inherit vs. can override, and whether this differs between CLI and SDK.

5. **Compliance/audit trail** — Does Claude Code log permission denials or hook invocations for audit? Docs don't mention it.

---

## Bottom line

**Tool constraints are ENFORCED at the application level.** Deny rules, permission modes, and PreToolUse hooks are all implemented in Claude Code's harness before the model makes decisions. The model cannot override them. Managed settings have the highest precedence and can enforce organization policy without bypass.

**Filesystem scope is NOT confined by default.** Read-only tools can read anywhere the user can; use `blockReadsOutsideWorkingDirectories: true` to restrict. File writes are confined to working directories by default.

**Network access via Bash is ADVISORY** (pattern-based, bypassable). Network access via WebFetch/WebSearch is ENFORCED (deny rules apply even in `bypassPermissions`).

**OS-level sandboxing exists but is not documented in detail.** Docs mention it for Linux/WSL2; platform coverage and implementation details are unverified.

