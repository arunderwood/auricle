---
date: 2026-09-16
project: auricle
workflow: correct-course
trigger_story: 1-1-project-initialization-xcode-swiftpm-hybrid (review) — closes the unresolved half of that story's own Review Triage Log finding #7
scope_classification: moderate
status: applied
applied: 2026-09-16
artifacts_affected:
  - Package.swift
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md
---

# Sprint Change Proposal — Adopt Swift 6 Language Mode at Story 1.1

## 1. Issue Summary

### Problem statement

`Package.swift` declares `// swift-tools-version: 5.10`; `architecture.md` states "Swift 5.10+" as the
binding language requirement. Neither was revisited since April 2026. Checked against reality:

- Latest Swift release overall: **6.4.0**, published 2026-09-16 (today).
- What this project's own pinned toolchain (Xcode 26.4.1) actually bundles: **Swift 6.3** — usable today,
  no toolchain change required.
- Like the GRDB finding, this isn't drift: **Swift 5.10 was already stale when the architecture was
  written** (6.2.x was current in April 2026). No rationale for 5.10 is recorded anywhere.

More pointedly: Story 1.1's own Dev Agent Record (Completion Notes, point list intro) already states the
installed toolchain used and verified during implementation was "Xcode 26.4.1 / **Swift 6.3.1**" — and
that same story's Review Triage Log (finding #7, verdict `medium`, route `patch`) already flagged that
"the Xcode/Swift toolchain version itself... exists only as Debug Log prose, unpinned in any repo file."
`.xcode-version` was added to close half of that finding. `Package.swift`'s tools-version was not updated
to match — it still says 5.10 despite the story that wrote it having already built and verified against
6.3.1. This proposal closes the other half.

### How it was discovered

You asked directly: "are we targeting the latest swift version? If not, why?" — the third finding from
today's dependency-staleness audit.

### Evidence

- `gh api repos/swiftlang/swift/releases` → latest `swift-6.4.0-RELEASE`, published 2026-09-16.
- Apple's Xcode 26.4 release notes: bundles Swift 6.3.
- `1-1-project-initialization-xcode-swiftpm-hybrid.md` Completion Notes: "the installed toolchain (Xcode
  26.4.1 / Swift 6.3.1 / Tuist 4.208.0)."
- Same file, Review Triage Log #7: toolchain version "unpinned in any repo file" — medium/patch, only
  partially closed.
- `swift build` run against `Package.swift` with `swift-tools-version: 6.3` (this project's actual
  toolchain): **succeeds cleanly** across all 25 library targets, `TestSupport`, and every external
  dependency (WhisperKit, GRDB, swift-argument-parser, TOMLKit) with zero errors and zero new warnings.
  `Package.resolved` unaffected — only the tools-version line changed.

### Why now, specifically

`Sources/` currently holds nothing but `ManifestPlaceholder.swift` files — no real implementation code
exists yet anywhere in the package. This is the cheapest point this project will ever be at to turn on
Swift 6's strict concurrency checking: every story written after this point is written under Swift 6 rules
from the start; every story written before it would need retrofitting later. This isn't hypothetical
upside — the two highest-coupling dependencies already touched today independently corroborate it:
`argmax-oss-swift` (WhisperKit's successor, PR #6) "adopts Swift 6 strict concurrency," and GRDB 7 (PR #7)
"requires... a Swift 6 compiler."

### Explicitly NOT part of this issue

- `swift-tools-version: 6.3`, not `6.4` — matches what this project's pinned Xcode 26.4.1 actually bundles
  and what was empirically verified building. Chasing the open-source-only 6.4.0 release (not yet in any
  Xcode) is out of scope; `mise.toml`/`.xcode-version` govern the Xcode upgrade path separately.
- No PRD conflict — NFR-M1 names "Swift / SwiftUI / AppKit only," not a specific version.
- No target-level `swiftLanguageMode` overrides added — every target adopts Swift 6 mode via the
  tools-version default, uniformly, per the "adopt everywhere, now, while it's free" rationale above.

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact | Detail |
|---|---|---|
| Epic 1 | **Story 1.1 amendment** (already `review`, code already merged) — closes Review Triage Log #7 | `Package.swift` tools-version bump, verified building |
| Epic 2–10 | **None directly** — but every future story now writes code under Swift 6 strict concurrency by default instead of Swift 5 | No epic scope, sequencing, or story count changes |

This is the most cross-cutting of today's three corrections — it changes the default language mode for
every target in the package — but because no real implementation code exists yet, there is nothing to
migrate and nothing to roll back.

### Artifact conflicts

- **PRD** — no conflict (NFR-M1 doesn't pin a version).
- **Architecture** — "Language & Runtime" line (`architecture.md`, Architectural Decisions Provided by
  This Approach) updated from "Swift 5.10+" to "Swift 6.3+ (language mode 6, strict concurrency checking
  on)," with rationale.
- **Epics** — new `AR-INIT-7` recorded (existing pattern: AR-INIT-1 through AR-INIT-6 already exist).
- **Story 1.1 file** — Post-Review Amendments entry closing Review Triage Log #7.
- **UX spec / CI / deployment** — no conflict; `ci.yml` already runs plain `swift build`/`swift test`,
  which already exercises whatever tools-version `Package.swift` declares — no CI file edit needed.

### Technical impact

`Package.swift`'s tools-version line changes (1 line). Verified via `swift build`: clean, zero errors,
across every target and every external dependency currently declared. `Package.resolved` unchanged.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1) — applied now, not deferred

Unlike the WhisperKit and GRDB findings (both deferred to a future story's build-verification spike,
because the affected code didn't exist yet), this one is applied directly: `Package.swift` already exists
and is merged, the change is one line, and it's been empirically verified rather than just asserted.

**Effort: Low** — one manifest line, two doc edits, one story-file note. **Risk: Low** — verified via a
real build; nothing to migrate since no real code exists yet. **Timeline impact: None.**

### Rationale

You chose this over deferring to a spike (the pattern used for WhisperKit/GRDB) specifically because
`Package.swift` isn't a not-yet-started story's future artifact — it's already-shipped code, and the
codebase being empty right now is a closing window, not a standing one.

---

## 4. Detailed Change Proposals

### 4.1 Package.swift — tools-version (line 1)

```
OLD:  // swift-tools-version: 5.10
NEW:  // swift-tools-version: 6.3
```

Verified: `swift build` succeeds cleanly (66.77s, 0 errors) across all 25 library targets, `TestSupport`,
and WhisperKit/GRDB/swift-argument-parser/TOMLKit. `Package.resolved` unaffected.

### 4.2 architecture.md — Language & Runtime (Architectural Decisions Provided by This Approach)

```
OLD:  **Language & Runtime:** Swift 5.10+ targeting macOS 14+; no other runtimes.

NEW:  **Language & Runtime:** Swift 6.3+ (language mode 6, strict concurrency checking on) targeting
      macOS 14+; no other runtimes. Adopted at Story 1.1's scaffold, before any real implementation code
      exists, per AR-INIT-7 — the cheapest point this project will ever be at to take on strict
      concurrency checking. Corroborated by the two highest-coupling external dependencies: WhisperKit's
      successor (`argmax-oss-swift`) adopts Swift 6 strict concurrency in its own v1.0+, and GRDB 7
      requires a Swift 6 compiler.
```

### 4.3 epics.md — new AR-INIT-7 (after AR-INIT-6)

```
ADD:  - **AR-INIT-7:** `Package.swift` declares `swift-tools-version: 6.3` (matching the Xcode 26.4.1 /
        `mise.toml`-pinned toolchain), putting every target under Swift 6 language mode with strict
        concurrency checking by default. Adopted at Story 1.1's scaffold — before `Sources/` holds
        anything but placeholder files — because retrofitting strict concurrency onto code written under
        Swift 5 assumptions is expensive, and adopting it now, while there is no code to retrofit, is not.
        Verified: `swift build` succeeds cleanly across all 25 library targets and their dependencies
        under this tools-version.
```

### 4.4 1-1-project-initialization-xcode-swiftpm-hybrid.md — Post-Review Amendments (new section, end of file)

```
ADD:
## Post-Review Amendments

| Date | Change | Trigger |
|---|---|---|
| 2026-09-16 | `Package.swift` `swift-tools-version` bumped `5.10` → `6.3`, matching the Xcode 26.4.1 /
  Swift 6.3.1 toolchain this story's own Debug Log already verified against. Closes the remaining half of
  Review Triage Log #7 (`.xcode-version` pinned Xcode; the SwiftPM manifest itself still said 5.10).
  Verified: `swift build` succeeds cleanly across all 25 library targets and dependencies under Swift 6
  language mode. | sprint-change-proposal-2026-09-16-swift-version.md |
```

---

## 5. Implementation Handoff

### Scope classification: Moderate

Changes an existing AR-tagged architectural decision (Language & Runtime) and adds a new one (AR-INIT-7)
— architect-level authority, matching the precedent set by today's Tuist/GUI correction. Not Major: no
epic, story, or FR added/removed/rescoped; no code beyond a merged manifest's single version line touched;
verified by an actual build rather than asserted.

### Handoff

| Recipient | Responsibility |
|---|---|
| **This workflow** | Applies §4.1–§4.4 directly — `Package.swift` (already verified), `architecture.md`, `epics.md`, and the Story 1.1 file's Post-Review Amendments. |
| **Dev (all future stories)** | Write code under Swift 6 strict concurrency from here forward; no migration needed since none exists yet. |

### Success criteria

1. `swift build` succeeds cleanly with `swift-tools-version: 6.3` — already verified.
2. `architecture.md` and `epics.md` (AR-INIT-7) state the decision and its rationale explicitly.
3. Review Triage Log finding #7 (Story 1.1) is fully closed, not half-closed.
4. `sprint-status.yaml` — no change. No epic or story added, removed, or renumbered.

### `sprint-status.yaml` impact

None.
