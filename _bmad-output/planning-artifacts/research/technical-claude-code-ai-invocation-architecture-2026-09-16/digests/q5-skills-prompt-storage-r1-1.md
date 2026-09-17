# Q5: Skills as prompt storage — digest

**Research date:** 2026-09-16  
**Claude Code version:** 2.1.220  
**Researcher:** arunderwood

---

## Verdicts

| Sub-question | Verdict | Evidence |
|---|---|---|
| 1. Loading mechanics — where and how skills are discovered | **CONFIRMED** | `https://code.claude.com/docs/en/skills.md`: Skills load from personal `~/.claude/skills/`, project `./.claude/skills/`, enterprise, nested, and plugin locations. File format: `SKILL.md` with YAML frontmatter (required fields: `name`, `description`). Descriptions load on every turn; full content loads only on invocation. Precedence: nested > project > personal when names collide. |
| 2a. Eager vs lazy loading | **CONFIRMED LAZY** | Skill descriptions (~100-1500 chars) load on every turn; full content (instructions, supporting files, rendered dynamic context) loads only when invoked. Observed in 2.1.220. |
| 2b. Model-decided vs deterministic skill activation | **CONFIRMED MODEL-DECIDED** | Claude's invocation choice is "based on description quality, relevance matching, `disable-model-invocation` flag, `paths` restriction, context preservation" — not deterministic. Documented: `https://code.claude.com/docs/en/skills.md` "How Models Choose Skills" section. |
| 3. Deterministic invocation | **CONFIRMED USER-INVOKABLE, MODEL CANNOT BE FORCED** | User can deterministically invoke via `/skill-name` (slash command). This is the only deterministic path. No API-level "force this skill" flag exists for model-decided invocation. Model invocation is probabilistic, not guaranteeable. |
| 3b. System-prompt alternatives (deterministic) | **CONFIRMED** | `--system-prompt <file>`: replace entire system prompt (deterministic). `--append-system-prompt <prompt>`: append to default (deterministic). Both observed in `claude --help` output, v2.1.220. `--agents <json>`: define custom agents inline (deterministic for structure, not behavior). |
| 4. Pinning and versioning — skills | **CONFIRMED NOT INDEPENDENTLY VERSIONED** | Skills have no independent version field. They are versioned as part of their enclosing plugin. Plugin versioning: `version` field in `plugin.json` + git tag format `{plugin-name}--v{version}` (enforced by `claude plugin tag`). Skills inherit plugin version. Documented: `https://code.claude.com/docs/en/plugin-dependencies.md`. |
| 4b. Version constraints and lockfiles | **CONFIRMED** | Plugins declare dependencies with semver ranges (`~2.1.0`, `^2.0`, `>=1.4`). Constraint resolution is automatic; no lockfile. Version pinning exists for dependencies (e.g., `"version": "~2.1.0"`), not for skills directly. Documented: `https://code.claude.com/docs/en/plugin-dependencies.md`. |
| 5. Provenance — session transcripts | **UNVERIFIABLE FROM DOCS** | No documented statement found on whether session transcript files record full system prompt and skill content text, or only conversation. Searched: Claude Code docs, settings reference, session management pages. Would require inspecting actual session files (`~/.claude/sessions/...`) to confirm format. |
| 5b. Provenance — API request logs | **CONFIRMED NOT AVAILABLE VIA CLAUDE CODE** | No flag or setting documented for Claude Code to log raw API requests (system + skills + messages as sent). The `--debug` flag exists but its output scope is undocumented. Provenance via host inspection of transmitted request is not surfaced. |
| 5c. Provenance — byte-exact record | **UNCONFIRMED** | No documented mechanism surfaces the exact prompt bytes sent to Claude. Host must hash skill files on disk and assume they were read and used unchanged — no checksum or signature mechanism documented. No documented integrity verification for skill content. |
| 6. Validation and linting | **CONFIRMED** | `claude plugin validate <path>` validates plugin/skill manifest structure. `claude doctor` performs health checks (settings, duplicates, collisions, integrity). Neither command includes cryptographic signing or checksum verification. Observed in `claude plugin --help` and `claude doctor --help`, v2.1.220. |

---

## Determinism table

| Way to get prompt into session | Deterministic? | Pinnable/versionable? | Byte-exact provenance after run? | Evidence |
|---|---|---|---|---|
| **User invokes `/skill-name`** | ✓ Yes | Partial (plugin version only) | ✗ No — must hash files self | Slash invocation deterministic; skill content = plugin version + git tag |
| **Model auto-invokes skill** | ✗ No — probabilistic | Partial (plugin version only) | ✗ No — must hash files self | "Claude decides based on description quality, relevance matching" — not guaranteed |
| **`--system-prompt <file>`** | ✓ Yes | ✗ No versioning | ✗ No — must hash file self | CLI flag documented; host controls file path; no version tracking |
| **`--append-system-prompt <prompt>`** | ✓ Yes | ✗ No versioning | ✗ No — host provides literal text | CLI flag; host supplies inline prompt; no version tracking |
| **`--append-system-prompt-file <file>`** | ✓ Yes | ✗ No versioning | ✗ No — must hash file self | CLI flag (implied by `--help` pattern); deterministic read; no versioning |
| **`--agents <json>` (custom agent)** | ✓ Yes (structure) | ✗ No versioning | ✗ No — must hash JSON self | CLI flag; inline JSON; structure is deterministic, behavior may not be |
| **Plugin dependency constraint** | ✗ Partial — resolves to range | ✓ Yes — semver range pinned | ✗ Partial — resolved tag recorded locally | `plugin.json` `version: "~2.1.0"` pins range; actual resolved version stored in cache dir with SHA suffix |

---

## Claims

- **Skills are lazy-loaded; descriptions (not full content) load on every turn.** | `https://code.claude.com/docs/en/skills.md` | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: high | class: behaviour

- **Skill activation is model-decided, based on description quality and relevance matching, not deterministic.** | `https://code.claude.com/docs/en/skills.md` "How Models Choose Skills" | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: high | class: mechanism

- **Skills are discovered in five locations: personal, project, enterprise, nested, plugin.** | `https://code.claude.com/docs/en/skills.md` "Where Skills Live" | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: high | class: mechanism

- **Skills have no independent version field; they are versioned with their enclosing plugin via `plugin.json` version + git tag.** | `https://code.claude.com/docs/en/plugin-dependencies.md` | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: high | class: version

- **Plugins declare version constraints using semver ranges (e.g., `~2.1.0`, `^2.0`); constraints are resolved via git tags and enforced at install/load.** | `https://code.claude.com/docs/en/plugin-dependencies.md` | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: high | class: version

- **`--system-prompt`, `--append-system-prompt`, `--agents` are deterministic CLI flags; they control what prompt text is sent.** | `claude --help` output, v2.1.220 (2026-09-16) | Anthropic (built-in CLI) | 2026-09-16 | accessed 2026-09-16 | confidence: high | class: mechanism

- **No documented mechanism exists to retrieve the exact system prompt + skill content that was sent to Claude after a run.** | Negative result: searched `https://code.claude.com/docs/en/skills.md`, settings reference, session management. No logging, telemetry export, or API-level request inspection documented. | Anthropic (code.claude.com) | undated | accessed 2026-09-16 | confidence: medium | class: behaviour

- **`claude plugin validate` checks manifest structure; `claude doctor` performs health checks. Neither includes cryptographic signing or checksum verification.** | `claude plugin validate --help`, `claude doctor --help`, v2.1.220 (2026-09-16) | Anthropic (built-in CLI) | 2026-09-16 | accessed 2026-09-16 | confidence: high | class: mechanism

---

## Verbatim evidence

### Claude Code CLI flags (v2.1.220, 2026-09-16)

```
--system-prompt <file>
  Set the system prompt for the session (replaces default).

--append-system-prompt <prompt>
  Append a system prompt to the default system prompt.

--disable-slash-commands
  Disable all skills.

--agents <json>
  JSON object defining custom agents (e.g. '{"reviewer": {"description": 
  "Reviews code", "prompt": "You are a code reviewer"}}')

-d, --debug [filter]
  Enable debug mode with optional category filtering (e.g., "api,hooks" or "!1p,!file")
```

### Skill frontmatter (required fields, from docs)

```yaml
---
name: my-skill
description: What this skill does and when to use it
---
```

Optional: `disable-model-invocation`, `user-invocable`, `allowed-tools`, `context`, `agent`, `model`, `arguments`, `paths`.

### Plugin dependency version constraint (from docs example)

```json
{
  "name": "deploy-kit",
  "version": "3.1.0",
  "dependencies": [
    "audit-logger",
    { "name": "secrets-vault", "version": "~2.1.0" }
  ]
}
```

### Git tag convention for plugin release

```
Tag name format: {plugin-name}--v{version}
Example: secrets-vault--v2.1.0
Command: claude plugin tag --push
```

---

## Leads worth chasing

1. **Session transcript format and contents** — Locate `~/.claude/sessions/` directory structure and inspect whether transcript files record system prompt, assembled skills, or only user-assistant messages. Run `find ~/.claude/sessions -name "*.json" -o -name "*.md" | head -5` to sample format. Docs do not specify.

2. **Debug flag verbosity** — Run `claude -d api --print "test" 2>&1 | grep -i "system\|prompt"` to see whether `--debug api` surfaces the system prompt or request body. Docs do not describe debug output scope.

3. **Skill manifest schema enforcement** — Whether SKILL.md frontmatter validation prevents skill name collisions across locations, or relies on discovery precedence. Run `claude plugin validate` on a test SKILL.md with missing required fields.

4. **Model invocation confidence** — Whether skill descriptions longer or with explicit `when_to_use` field increase invocation probability. Requires A/B testing against consistent task set; docs only state "description quality" matters.

5. **Cross-session provenance** — Whether `--continue` or `--fork-session` preserves/diverges the system prompt and skill set used in the original session. Affects reproducibility of runs.

---

## Searched for and could not find

- **Whether skills have a `version` frontmatter field** — Searched skill frontmatter docs, plugins reference. Only `plugin.json` has `version`; no skill-level versioning field documented. Skills are versioned with their plugin.

- **Whether session transcripts record full system prompt and skill text** — Searched settings reference, session management, debug documentation. Format undocumented; no statement on whether provenance is recorded.

- **Whether any API-level request logging is available** — Searched Claude API docs, monitoring/telemetry pages, OpenTelemetry integration docs. No request body logging surface documented. Anthropic-hosted Managed Agents may have logging, but Claude Code agent SDK does not.

- **Whether skill content is checksummed or signed** — Searched plugin validation, security, integrity pages. `claude plugin validate` checks structure only, not cryptographic integrity.

- **Whether `--debug` output includes system prompt or assembled context** — Debug documentation scope undocumented; would require testing.

