---
date: 2026-09-15
project: auricle
workflow: correct-course
trigger_story: none (Story 1.4 is backlog; discovered via a staleness audit, not implementation)
scope_classification: minor
status: applied
applied: 2026-09-15
artifacts_affected:
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/epics.md
---

# Sprint Change Proposal — GRDB.swift Version Floor Verification

## 1. Issue Summary

### Problem statement

`Package.swift` pins GRDB `from: "6.29.0"`. GRDB **v7.0.0 was released 2025-01-26** — over a year before
this architecture was written (2026-04-28) — and the current latest is v7.11.1. Unlike the WhisperKit
finding earlier today, this isn't post-planning drift: 7.x already existed when the plan was written and
the docs give no rationale for staying on 6.x. The architecture's GRDB/WAL/concurrency rules table
(`architecture.md:781-794`) is written generically enough that most of it survives either version, but two
GRDB 7 changes are directly relevant and unverified against this project's toolchain:

- GRDB 7 requires Xcode 16+ and a Swift 6 compiler (already satisfied — this project pins Xcode 26.4.1).
  Whether a Swift-6-built package integrates cleanly as a dependency of a `swift-tools-version: 5.10`
  target is unverified.
- Writes always use `IMMEDIATE` transactions in GRDB 7 (no longer a configurable default) — this actually
  *strengthens* the table's existing "contention is theoretical, not actual" claim rather than threatening it.

### How it was discovered

The same dependency-staleness audit (2026-09-15) that surfaced the WhisperKit finding, followed up per
your request to look specifically at "the GRDB.swift upgrade."

### Evidence

- `gh api repos/groue/GRDB.swift/releases` → latest `v7.11.1`; `v7.0.0` published `2025-01-26T17:14:54Z`.
- GRDB 7 migration guide (`GRDB7MigrationGuide.md`): "GRDB 7 requires Xcode 16+ and a Swift 6 compiler";
  "transactions are automatically managed... writes use IMMEDIATE transactions"; `ValueObservation`
  callbacks now dispatch on the main actor by default (GRDB 6 required manual main-thread handling —
  nothing in `architecture.md` currently assumes manual dispatch, so this is a simplification, not a break);
  `DatabasePool.concurrentRead` removed in favor of `asyncConcurrentRead` (not cited by name anywhere in
  the docs, so no direct hit found).
- `architecture.md:785` ("Use `DatabasePool`... concurrent reads with own writes") describes baseline
  WAL-mode concurrent-read behavior, not the removed `.concurrentRead` method specifically — checked
  directly, no correction needed there.
- `epics.md:926` (Story 1.4: SQLite Schema, StateStore, and GRDB Migrations) — `backlog`. No code imports
  GRDB yet (`Sources/State/` contains only a placeholder file); Story 1.1 (`review`) only declares the
  dependency in `Package.swift`.

### Explicitly NOT part of this issue

- GRDB is not named anywhere in `prd.md` — this is purely an architecture/epics-level implementation
  detail, not a PRD concern. No PRD edit proposed.
- `Package.swift`'s version floor is **not changed by this proposal** — same pattern as the WhisperKit
  correction: the decision belongs at Story 1.4 implementation time, as a build-verified spike, not a
  speculative edit now.
- `DatabaseMigrator` — no evidence of a breaking change in the 7.0 migration guide; the "Migrations" row
  (`architecture.md:793`) is unchanged.

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact | Detail |
|---|---|---|
| Epic 1 | **Story 1.4 AC amendment only** | Adds a build-verification gate before migration #1 is written |
| Epic 2–10 | **None** | Every other epic reads/writes state exclusively through `StateStore`'s typed API (architecture.md's own encapsulation rule — "direct `db.read{}` outside `StateStore` is a code-review reject") — GRDB's version is invisible past that boundary |

Epic scope, count, sequencing, and priority are **unchanged**. Story 1.4 is `backlog` — nothing built,
nothing to roll back.

### Artifact conflicts

- **PRD** — no conflict; GRDB isn't referenced.
- **Architecture** — one row added to the GRDB/WAL/concurrency rules table (`architecture.md:781-794`)
  documenting the version-floor question and what's actually confirmed vs. unverified.
- **Epics** — Story 1.4 gains one AC block gating migration #1 on a build-verification spike.
- **UX spec / CI / deployment** — no conflict.

### Technical impact

None yet — Story 1.4 hasn't started. Forward effect: whoever implements Story 1.4 verifies GRDB 7
compiles cleanly against this package before writing migration #1, instead of inheriting whatever
`Package.resolved` has drifted to by then.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1)

**Effort: Low** — one table row, one AC block. **Risk: Low** — Story 1.4 not started, and the encapsulation
boundary (`StateStore`) means this can't leak into other epics regardless of outcome. **Timeline impact:
None.**

### Rationale

Same mechanism as the WhisperKit correction: don't pre-decide the version, don't touch `Package.swift`
speculatively — make the decision point explicit and build-verified at the story that actually implements
it, so the choice is made on real toolchain feedback rather than by whatever floor got typed into
`Package.swift` during scaffolding.

---

## 4. Detailed Change Proposals

### 4.1 architecture.md — GRDB/WAL/concurrency model table (after line 794)

```
ADD ROW:
| Package version | `from: "6.29.0"` in `Package.swift`, **unverified against GRDB 7.x** | GRDB 7.0.0
  (released 2025-01-26, predates this architecture) requires Xcode 16+/Swift 6 compiler — already
  satisfied by this project's Xcode 26.4.1 pin. GRDB 7 also makes writes always `IMMEDIATE` (strengthens
  the "contention is theoretical" row above) and moves `ValueObservation` callbacks to the main actor by
  default (simplification — nothing here assumes manual dispatch). Unverified: whether GRDB 7 integrates
  cleanly as a dependency of this package's `swift-tools-version: 5.10` target. Confirm with a build spike
  before Story 1.4 writes migration #1; prefer `from: "7.0.0"` over the current 6.x floor if the build is
  clean, since 7.x's default-IMMEDIATE-writes behavior is the better match for this table's own
  concurrency assumptions. |
```

Rationale: the table is explicitly "each row a binding implementation rule" — the version floor is exactly
that kind of rule, and it's currently unstated rather than deliberately chosen.

### 4.2 epics.md — Story 1.4, new leading AC block (before line 934)

```
ADD (as the first Given/When/Then block, before "Given the `State` target / When I call
StateStore.production()..."):

**Given** the `Package.swift` GRDB dependency floor (`from: "6.29.0"`, predating GRDB 7.0.0 which requires
  Xcode 16+/Swift 6 compiler — already satisfied by this project's Xcode 26.4.1 pin)
**When** this story begins
**Then** confirm GRDB 7.x builds cleanly against this package's `swift-tools-version: 5.10` target before
  writing migration #1
**And** if the build is clean, bump the floor to `from: "7.0.0"` — its default-IMMEDIATE-writes behavior is
  a better match for this story's WAL/cross-process assumptions (per architecture.md's GRDB/WAL/concurrency
  table) than 6.x's configurable default
**And** if the build is not clean, stay on `from: "6.29.0"` and record why in this story's Dev Agent Record
```

Rationale: mirrors the build-verified spike pattern already used for Story 1.1 (Tuist local-package spike)
and Story 4.2 (WhisperKit/SpeakerKit empirical test) — a decision point made on real toolchain feedback,
not asserted here.

---

## 5. Implementation Handoff

### Scope classification: Minor

No epic, story, or FR added, removed, or resequenced. No architectural commitment (AR-tag) added or
removed — one table row and one AC block, both scoped to a single not-yet-started story.

### Handoff

| Recipient | Responsibility |
|---|---|
| **This workflow** | Applies §4.1–§4.2 directly to `architecture.md` and `epics.md`. |
| **Dev (Story 1.4, when it starts)** | Runs the build-verification spike, decides the `Package.swift` GRDB floor, records the outcome in the Dev Agent Record. |

### Success criteria

1. `architecture.md`'s GRDB/WAL/concurrency table documents the version-floor question instead of leaving
   it unstated.
2. Story 1.4 cannot write migration #1 without first confirming which GRDB major version it's building
   against.
3. `sprint-status.yaml` — no change. Story 1.4 stays `backlog`; no story added, removed, or renumbered.

### `sprint-status.yaml` impact

None.
