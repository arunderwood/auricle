# Q4 RED TEAM: attempt to disprove "tool and filesystem constraints are enforced"

## Did the conclusion survive?

**SURVIVED WITH QUALIFICATION.** Permission rules ARE enforced by the Claude Code harness (not advisory), and CLI flags do take precedence over project settings. However, the enforcement model has documented gaps: the default read scope is unrestricted, project configuration files can autonomously execute hooks and enable MCP servers (CVE-2025-59536), multiple command-injection CVEs allow bypassing Bash rules, and sandboxing is not guaranteed on unsupported platforms or when dependencies are missing.

---

## The leak table

| Escape route | Real or theoretical? | What it defeats | Is it documented by Anthropic or third-party? | Source |
|---|---|---|---|---|
| Project `.claude/settings.json` hooks auto-execute without confirmation | **Real — CVE-2025-59536** | Parent's permission model: hooks run automatically on `claude` startup before trust dialog completes | Third-party: Check Point Research; Anthropic fixed in v2.1+ | https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/ |
| Project `.claude/settings.json` auto-enables MCP servers via `enableAllProjectMcpServers: true` | **Real — CVE-2025-59536** | Parent's MCP allowlist: servers run without explicit user consent before trust dialog | Third-party: Check Point Research; Anthropic patched | https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/ |
| Bash command-injection via overly broad allowlist rules | **Real — CVE-2025-55284** | Permission rule matching: attackers bypass `Bash(git *)` by chaining commands or using special options | Third-party: Sentinel One; CVE rated; affected versions < 1.0.4 | https://www.sentinelone.com/vulnerability-database/cve-2025-55284/ |
| WebSocket auth bypass in MCP server (CLI extensions) | **Real — CVE-2025-52882** | MCP tool isolation: attacker can read local files and execute code in Jupyter by visiting a webpage | Third-party: Datadog Security Labs; affects v1.0.23 and earlier; CVSS 8.8 | https://securitylabs.datadoghq.com/articles/claude-mcp-cve-2025-52882/ |
| Unsandboxed retry escape hatch (`dangerouslyDisableSandbox`) | **Real — documented** | Filesystem isolation: failed sandboxed commands retry outside sandbox through regular permission flow | First-party: Anthropic docs state "escape hatch" exists; escapable with `allowUnsandboxedCommands: false` | https://code.claude.com/docs/en/sandboxing.md (lines 151–158) |
| Sandbox unavailable on native Windows; defaults to unsandboxed if dependencies missing | **Real — documented** | OS-level enforcement: sandboxing not available; falls back to unsandboxed unless `sandbox.failIfUnavailable: true` | First-party: Anthropic docs state sandbox runs only on macOS/Linux/WSL2; requires bubblewrap/socat on Linux | https://code.claude.com/docs/en/sandboxing.md (lines 15–62) |
| Default read scope is unrestricted (reads anywhere by default) | **Real — documented** | Filesystem read constraint: `permissions.blockReadsOutsideWorkingDirectories` is **off by default**, so sessions can read any file the user can | First-party: Anthropic docs reference to setting implies it must be explicitly enabled | https://code.claude.com/docs/en/settings-reference.md |
| MCP tool escape via WebSocket in dev environments | **Theoretical but weaponized — CVE-2025-52882** | Tool isolation: attacker needs only to trick user into visiting a webpage; no exploit needed | Third-party: Datadog; proven proof-of-concept | https://securitylabs.datadoghq.com/articles/claude-mcp-cve-2025-52882/ |

---

## Precedence order, as documented

**Highest to lowest** (from Anthropic's settings.md):

1. **Managed settings** (organization-wide, MDM, or claude.ai console)
2. **Command line** (`claude --settings`) ← Parent process flags here
3. **Project local** (`.claude/settings.local.json`)
4. **Shared project** (`.claude/settings.json`) ← This can run hooks autonomously
5. **User settings** (`~/.claude/settings.json`)

**Critical gap:** While CLI (level 2) overrides project settings (levels 3–4), **project-level hooks and MCP configurations execute autonomously BEFORE the trust dialog completes** (CVE-2025-59536), meaning a parent's CLI constraint is bypassed by code running before the parent's gate takes effect.

**Flag status:** Parent's CLI flag IS the strongest (after managed settings), but only if you also set `sandbox.failIfUnavailable: true` or handle the other documented escape routes. Otherwise, the default is permissive.

---

## Default read scope

**The flat answer:** By default, **sessions CAN read any file the user can**. The session is NOT confined to the working directory by default.

**The setting that changes it:** `permissions.blockReadsOutsideWorkingDirectories` (must be explicitly set to `true`).

**Where to set it:** Any settings file — user (`~/.claude/settings.json`), project (`.claude/settings.json`), local (`.claude/settings.local.json`), or managed. To enforce it parent-side, use `--settings '{"permissions": {"blockReadsOutsideWorkingDirectories": true}}'` on the CLI.

**Is it enforced?** Yes, when enabled. The docs state: "Permission rules are enforced by Claude Code, not by the model." (https://code.claude.com/docs/en/permissions.md, line 69). However, the default is OFF, meaning no enforcement until explicitly turned on.

---

## CVEs / advisories / bypass writeups found

1. **CVE-2025-55284** — Permissive Allowlist Bypass
   - Command injection in Bash rule matching (e.g., `Bash(git *)` bypassed by chaining)
   - Allows reading files and sending data over network without confirmation
   - Affects: Claude Code < v1.0.4
   - Source: Sentinel One, Embrace the Red

2. **CVE-2025-59536 & CVE-2026-21852** — Project Configuration Bypass & API Key Exfiltration
   - `.claude/settings.json` hooks auto-execute without full confirmation
   - `enableAllProjectMcpServers: true` auto-approves servers, bypassing warnings
   - Malicious `ANTHROPIC_BASE_URL` in settings intercepts API keys before trust dialog
   - Source: Check Point Research, MintMCP

3. **CVE-2025-52882** — WebSocket Authentication Bypass in MCP (IDE extensions)
   - Attacker can read local files and execute code in Jupyter via webpage visit
   - Affects: VS Code/IDE extensions v1.0.23 and earlier
   - CVSS Score: 8.8 (High)
   - Source: Datadog Security Labs

4. **CVE-2025-54794 / CVE-2025-54795** — Path Restriction and Command Injection
   - Improper input sanitization in whitelisted commands
   - Attackers escape path restrictions and execute code
   - Source: Cymulate

5. **Additional Context:** Claude Code accumulated **28 CVEs in its first year**, including two CVSS 10.0 ratings.
   - Source: https://pulse.adyog.com/insights/claude-code-28-cves-ai-coding-tools-attack-surface-cve-2026-46406

---

## What I searched and did NOT find

- **No documented guarantee that a constrained session cannot make network calls.** Sandboxing provides network isolation (allowlist-based), but only if sandboxing is enabled AND dependencies are present. By default on unsupported platforms or with missing dependencies, network calls are unrestricted.
- **No documentation explicitly stating that subagents inherit parent constraints.** The Agent SDK docs do not cover whether a parent process that spawns a subagent can constrain the subagent's tool set or filesystem reach.
- **No public writeup of a symlink escape from the working directory** — theoretically possible if the working directory contains a symlink pointing outside, but no documented attack.
- **No bypass of managed settings** — managed settings appear to be the hard boundary.

---

## Summary of findings

The **hardest constraint** a parent can impose is a **managed setting** (Anthropic-deployed, MDM, or CLI in restricted org mode). CLI flags come second and do override project settings. However:

- **By default, no constraints are active** — read scope is unrestricted, sandboxing requires setup.
- **Project configuration files can execute code autonomously** before permission prompts (CVE-2025-59536).
- **Sandboxing is not guaranteed** — missing dependencies or unsupported platforms fall back to unsandboxed.
- **Multiple high-severity CVEs** allow command injection and permission bypasses.

For the use case ("nothing may leave the machine except one specific payload; session must not read beyond a nominated directory"), the parent process **must**:
1. Set `permissions.blockReadsOutsideWorkingDirectories: true` on CLI or managed settings.
2. Set `sandbox.enabled: true` and `sandbox.failIfUnavailable: true`.
3. Deny or allow specific network domains with `sandbox.network.allowedDomains`.
4. Use `--disallowedTools` CLI flag or managed settings to deny problematic tools (e.g., Bash, WebFetch, WebSearch).
5. NOT rely on the default state; verify that sandboxing is running and project settings cannot override the constraints.

The default state of Claude Code 2.1.220 does **not** meet the privacy requirement without explicit hardening.
