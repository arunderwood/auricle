# Sprint Change Proposal — user-editable files relocate to `~/.auricle/`

**Date:** 2026-09-16
**Scope classification:** **Minor** — documentation-only; zero code changes
**Source:** `decision-record-2026-09-16-epic-3-ai-invocation.md`, ruling *"user-editable files live under `~/.auricle/`"*
**Mode:** Batch

---

## 1. Issue Summary

**Problem.** FR59 specified `~/Library/Application Support/com.auricle.app/` as the home for
user-editable configuration. That location is Finder-hidden, awkward to keep under version
control, and macOS-specific — which conflicts with the project's standing preference for
portable, greppable data over platform lock-in.

**How it surfaced.** The Epic 3 invocation roundtable ruled that summarization prompts move out
of Swift and into files the user edits directly, and placed the override set in Application
Support by default. The maintainer rejected the location and stated a general rule rather than a
one-off correction:

> Any auricle file the user is expected to edit or extend or place config into should live in
> structure under `~/.auricle/`.

**Why it needed correcting now.** No configuration layer exists yet — `Sources/Core` has no
`Config` type. Every Application Support reference in `Sources/` is the SQLite path, which does
not move. The rule was stated before it cost anything; deferring it would have meant a real
refactor plus a migration path for existing installs.

---

## 2. Impact Analysis

**Epic impact:** none. No epic is added, removed, resequenced, or rescoped. Epic 1 (Story 1.x
`Core/Config`), Epic 5 (onboarding), and Epic 9 (SettingsView) each carry a path string that
changes; their acceptance criteria are otherwise unaffected.

**Story impact:** four acceptance criteria carry the literal path and are updated in place. No
story changes size, dependency, or ordering.

**Artifact conflicts resolved:** PRD, architecture, and epics all stated the old path. One line
(`prd.md:368`) conflated config and database in a single sentence and needed splitting rather
than substituting.

**Technical impact: none today.** Verified before editing:

| Check | Result |
|---|---|
| `Sources/` has a `Config` type | No — `Sources/Core/` has no config file |
| `Sources/` references to Application Support | 3, all in `State/DatabasePoolFactory.swift` and `State/StateStore.swift`, all the SQLite path |
| Does the SQLite path move? | **No** |

**Constraint checked and found not to bind:** an App Sandbox entitlement would put `~/.auricle/`
out of reach without a security-scoped bookmark. auricle distributes self-signed via `spctl`
(NFR-C4, FR65) and is not sandboxed. This would need revisiting only under App Store
distribution, which NFR-C4 explicitly declines.

---

## 3. Recommended Approach

**Direct Adjustment.** No rollback, no MVP scope change. The rule draws a line through the
existing filesystem layout and moves one category across it.

**The line is "expected to edit," not "belongs to the user."** The SQLite database is the user's
own data and stays in Application Support, because its interface is `auricle status`, not a text
editor. This is why the change is a split rather than a rename: of 19 `Application Support`
occurrences across the three documents, **11 move and 8 stay**, and mechanically replacing all
of them would have been wrong.

| Location | Holds | Moved? |
|---|---|---|
| `~/.auricle/` | `config.toml` (FR59); `prompts/` when decision (a) is course-corrected | **new** |
| `~/Library/Application Support/com.auricle.app/` | `auricle.sqlite3`, schema-version markers | unchanged |
| `~/Library/Caches/com.auricle.app/` | per-meeting cache-dir artifacts | unchanged |
| macOS Keychain | secrets (NFR-S1) | unchanged |

**Second-order benefit, load-bearing for another ruling.** The same decision record requires a
`summarization_prompt_set_hash` in telemetry, with the condition that a hash is a fingerprint
with no suspect unless the bytes are recoverable — so the override directory must be under
version control or `auricle doctor` warns. A dotfile directory is one a maintainer plausibly
runs `git init` in; a directory inside `~/Library/Application Support/` is one nobody ever does.
The relocation moves that condition from a warning nobody acts on to the default behaviour.

**Effort:** documentation edits only, already applied. **Risk:** low. **Timeline impact:** none.

---

## 4. Detailed Change Proposals

### PRD — `prd.md`

**FR59 (line 578) — the substantive change**

> **OLD:** auricle can persist configuration in `~/Library/Application Support/com.auricle.app/`
> as a structured file (TOML or JSON), separate from secrets which live in Keychain.

> **NEW:** auricle can persist user-editable configuration in `~/.auricle/` as a structured file
> (TOML or JSON), separate from secrets (Keychain, NFR-S1) and from machine-managed operational
> state (the SQLite database, FR66). The governing rule: **any file the user is expected to
> edit, extend, or place config into lives under `~/.auricle/`**; state the user reads only
> through a CLI verb does not. `~/.auricle/` is a plain directory the user may keep under
> version control, which is what makes configuration changes auditable after the fact.

*Rationale: states the rule, not just the path, so the next user-facing file does not have to
re-litigate it. Names the exclusion explicitly so FR66's SQLite location does not read as an
inconsistency.*

**Filesystem overview (line 368) — split, not substituted**

> **OLD:** …Application Support at `…/com.auricle.app/` for the local SQLite database tracking
> meeting state, retention timers, **and config**.

> **NEW:** …Application Support at `…/com.auricle.app/` for the local SQLite database tracking
> meeting state and retention timers. **User-editable configuration at `~/.auricle/` (FR59).**

*Rationale: this sentence conflated the two categories the rule separates.*

### Architecture — `architecture.md`

**Filesystem layout (line 96) — one bullet becomes two**

> **OLD:** `~/Library/Application Support/com.auricle.app/` — config (TOML or JSON), SQLite
> database, schema-version markers.

> **NEW:**
> - `~/.auricle/` — **everything the user is expected to edit**: `config.toml` (FR59). A plain
>   directory, versionable by the user; deliberately not inside `~/Library/`, which is
>   Finder-hidden and awkward to keep under version control.
> - `~/Library/Application Support/com.auricle.app/` — machine-managed operational state only:
>   SQLite database, schema-version markers. Not hand-edited; the interface is `auricle status`.

*Rationale: the filesystem layout is called an "architectural fixture" in this document, so it
is the right place for the rule to be legible rather than inferred.*

**Data-store table, Configuration row (line 2645)** — path only.
**Configuration Files, runtime config (line 2836)** — path only.

### Epics — `epics.md`

| Line | Change |
|---|---|
| 119 | FR59 restatement, matched to the PRD |
| 492 | Traceability row: *"Config persistence in Application Support / TOML"* → *"in `~/.auricle/` / TOML"* |
| 879 | `Core/Config` AC — read/write path |
| 2381 | Onboarding AC — no-prior-config detection path |
| 2397 | Onboarding AC — `OnboardingCoordinator` write path |
| 3560 | SettingsView AC — auto-save write path |

### Deliberately NOT changed

| Location | Why |
|---|---|
| `prd.md:588` (FR66), `epics.md:129` | SQLite telemetry store — machine-managed |
| `architecture.md:687, 1199, 2641`; `epics.md:263, 930, 943` | The SQLite path and the per-Mac canonical-status store |
| `architecture.md:2924` | A hypothetical future relocation of *cache-dir artifacts* to Application Support. Those are machine artifacts; the rule does not reach them |
| `prd.md:660` (NFR-Pr3) | Enumerates where captured audio, transcripts, and intermediate artifacts live. Config was never in that list and is not one of those things |
| `epics.md:2466` | References `config.toml` by filename with no path |

---

## 5. Implementation Handoff

**Scope: Minor.** Documentation-only; the edits are applied.

**Verification performed:**

- All 11 intended edits applied; each matched exactly once (ambiguous matches would have
  aborted the run).
- Every surviving `Application Support` reference across the three documents was re-read and
  confirmed to be SQLite or cache-dir.
- No `config.toml` remains under an Application Support path.

**Carried forward, not done here:**

1. **`Core/Config` must create `~/.auricle/` on first use** and handle its absence, the same way
   `DatabasePoolFactory.productionDatabasePath()` creates its Application Support directory
   today. This is a first-run concern for the Epic 1 config story, not a migration — nothing
   ships at the old path.
2. **No migration path is required** and none should be written. There are no existing installs
   with a config file at the old location; adding migration code would be dead on arrival.
3. **Decision (a) — prompts as files — remains un-course-corrected.** This proposal moved the
   *location* rule only. The larger change (prompts leave `SummarizationPromptBuilder`, shipped
   defaults in-repo, user override in `~/.auricle/prompts/`, `summarization.prompt_dir` added to
   FR58) is a separate and much larger course correction against Stories 3.2 and 3.7. When it
   runs, its override directory is already correctly specified by the rule recorded here.

**Success criteria:** a reader of FR59 can place any future user-facing file without asking, and
a reader of FR66 does not experience the SQLite location as an inconsistency.
