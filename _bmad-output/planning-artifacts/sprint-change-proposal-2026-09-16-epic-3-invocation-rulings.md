# Sprint Change Proposal — Epic 3 invocation rulings into the plan

**Date:** 2026-09-16
**Scope classification:** **Moderate** — no epic is added or resequenced, but one architectural invariant is replaced and four stories change shape
**Source:** `decision-record-2026-09-16-epic-3-ai-invocation.md`
**Mode:** Batch
**Predecessor:** `sprint-change-proposal-2026-09-16-auricle-config-home.md` (the `~/.auricle/` relocation, applied first because this proposal depends on it)

---

## 1. Issue Summary

A four-agent roundtable ruled on how auricle invokes AI for Epic 3, backed by eleven measured
probes. Epic 3 is backlog — `Sources/SummarizerInterface`, `Sources/Summarize`, and
`Sources/ClaudeSummarizer` hold only `ManifestPlaceholder.swift` — so every ruling here is a
choice made before the first line is written, not a migration.

Two of the rulings invalidate text that was already in the plan:

1. **The canonicalization invariant (Decision 3.4) was wrong on both axes.** It specified
   "UTF-8 byte offsets into the NFC-normalized representation," verified against Anthropic's
   spec at implementation time. Measurement found the API returns **Unicode codepoints against
   the text exactly as submitted**, with no server-side normalization and no published contract
   for either [P2][P8]. Decision 3.4 called itself "the single most important architectural
   detail of Group 3"; it would have been implemented against a convention that does not hold.

2. **Decision 3.2's Citations call, as specified, returns a 400.** It asks for structured JSON
   with citations enabled. Confirmed live against `claude-opus-5`: *"Citations cannot be enabled
   when output format is set"* [P9]. The story would have failed on its first real call.

The remaining rulings are additive: prompts move to files, provenance gains a column, the
comparison rig gains an axis, FR69's rationale gains the mechanism it always assumed.

---

## 2. Impact Analysis

**Epic impact:** none added, removed, or resequenced. Epic 3 keeps twelve stories.

**Story impact:** four change shape (3.2, 3.5, 3.8, 3.9), three gain acceptance criteria
(3.1, 3.4, 3.12), one gains a telemetry column (3.7 / Epic 1's schema story).

**Technical impact:** none today. No Epic 3 source file exists beyond placeholders. This is the
second consecutive correction caught before it cost code.

**Artifact conflicts resolved:** the offset convention appeared in five places across
`architecture.md` and `epics.md` and had to change consistently or the contract test would
assert one thing while the validator did another.

---

## 3. Recommended Approach

**Direct Adjustment.** No rollback; no MVP scope change. Two substitutions and five additions.

The substitution worth understanding is the invariant. The old rule promised to match whatever
unit Anthropic returns, with a translation layer as the escape hatch. **The fix is not a
translation layer — it is a change of document representation.** Submitting the transcript as a
custom content document, one block per utterance, returns `content_block_location` block indices
instead of character offsets. No character index crosses the API boundary in either direction,
so Swift chooses the unit and the renderer's unit is the validator's unit by construction. The
encoding question is deleted rather than translated, and the resulting contract test is stronger
because all three of its assertions are internal.

**Effort:** documentation only, applied. **Risk:** low. **Timeline impact:** none — it removes
a story-time investigation (*"verify against current API docs at implementation time"*) that
would have produced the wrong answer.

---

## 4. Detailed Change Proposals

### PRD — `prd.md` (4 edits)

| Ruling | Change |
|---|---|
| **FR58** | Gains `summarization.prompt_dir`. Personalization previously had **no config surface at all** — FR58 listed vault path, retention, engine, API key, OAuth, and log verbosity, and no prompts, templates, or output shape |
| **FR69** | Split. The *selection* of a meeting-type template stays v2+; *having* per-meeting-type prompts ships from MVP as a consequence of `prompt_dir` |
| **Line 448 rationale** | Rewritten. It claimed templates "earn their way in only after the user has captured enough meetings to feel which categorical splits actually matter" — which presumes an instrument for feeling it. `prompt_dir` is that instrument. Left as written, the line reads as "nothing until v2," which becomes false the moment decision (a) lands |
| **NFR-C1** | Gains an enforcement clause. It stated a dollar ceiling without naming the number it is enforced against. Now: auricle's own token-count × rate-table computation, with Anthropic's Usage and Cost API as the out-of-band authority. Not made advisory |

### Architecture — `architecture.md` (8 edits)

**Decision 3.4, rule 2 — the invariant** (the substantive change; full rationale in the document)

> **OLD:** Character offsets are **UTF-8 byte offsets into the NFC-normalized representation.**
> This is verified against Anthropic's API spec at implementation time — if Anthropic uses a
> different convention… the canonical representation includes a translation step…

> **NEW:** …**and this is now purely auricle's internal convention, with no external contract to
> honour.** [Measurement killed the premise on both axes.] The resolution is not a translation
> layer but a change of document representation… The encoding question is deleted rather than
> translated.

**Decision 3.4, rule 3 — the contract test** becomes three internal assertions: round-trip
stability; block index *N* maps to a stable `[start, end)` under the *same* segmentation
`CanonicalTranscript` carries; the substring validator resolves into that space. Property (b)
replaces "the API-submission representation matches the on-disk representation," which presumed
the API was handed a flat string.

**Decision 3.2 — the Citations call** now submits a custom content document, receives
`content_block_location`, and **requests its JSON by prompt instruction rather than
`output_config.format`** — recorded as a hard constraint with the observed 400 quoted, so nobody
"tidies" it back into the parameter.

**Telemetry schema** gains `summarization_prompt_set_hash TEXT`, beside `summarization_model`
and `cost_usd`. Not frontmatter: cross-cutting concern #11 puts model identifiers in SQLite, and
a prompt-set hash is a model identifier's sibling. Write-authority and data-source tables updated
to match.

**Decision 3.7** — `auricle status <id>` surfaces the hash. This is what makes *"why did last
Tuesday's note come out badly?"* answerable once the user edits prompts.

### Epics — `epics.md` (19 edits)

| Story | Change |
|---|---|
| **3.2** | Retitled. `SummarizationPromptBuilder` becomes a **composer over files**, not an assembler of string literals. Two tiers: shipped default in-repo (snapshot-tested), user override at `~/.auricle/prompts/` (never read by tests). Adds `--prompt-dir` for single-run iteration and the SHA-256 provenance hash. **The mode-equivalence snapshot assertion is removed** — byte-identity of shared portions is now structural (one `system.md`, read twice), not a property two code paths could violate. Adds the `auricle doctor` warning for an unversioned override directory |
| **3.5** | Custom content document; `content_block_location`; bounds checks on block indices instead of char offsets; an out-of-range index is a malformed response, not a clamp. The prompt-instruction JSON constraint is an AC |
| **3.8** | Comparison axis parameterised from "strategy" to "(strategy, prompt-set)" — cheap while the rig is being built, a rewrite afterwards |
| **3.9** | Retitled *Pipeline Regression Harness*. Gains an explicit scope note: **its own ACs specify stubbed responses, so a prompt change cannot move it.** It was named "Eval Harness," which invites exactly the extension that would destroy its CI-safety |
| **3.12** | FR56's scoping rule gets a fuzzy transcript-mention test, plus a fixture asserting a **misspelled** term survives scoping. The exact-match rule as specified drops precisely the terms jargon correction exists to fix |
| 3.1, 3.4, AR-SUM-4 | Offset language updated to the internal-convention framing |
| FR58, FR69 | Restatements matched to the PRD |

---

## 5. Implementation Handoff

**Scope: Moderate.** Documentation-only; applied. No backlog reorganization needed — story count,
sequence, and dependencies are unchanged.

**Verification performed:** every edit matched exactly once (ambiguous matches abort the run);
zero `CitationCharLocation` or `start_char_index` references survive in any planning document;
all surviving "UTF-8 byte offsets" mentions carry the internal-convention qualifier.

**Carried forward, not done here:**

1. **The vault-aware direction remains opened, not ruled.** It is not in Epic 3 and nothing here
   commits to it. Open: whether to build it, subscription vs API-key billing (which also
   determines *which* Anthropic data-usage terms apply to recordings of third parties), latency
   against NFR-P1's 2-minute P50, and allowance draw at real meeting volume.
2. **A new v1.1 story is owed** for the user-facing A/B loop — run prompt B over a corpus, diff
   the results. Story 3.8's axis generalization makes it cheap; it is not itself in Epic 3.
3. **A clean `--tools` A/B** would settle a confound: [P11] moved the model pin and the tool
   restriction in one run, so the 2x context reduction is inferred rather than measured. One run
   settles it. Only matters if the vault path is built.
4. **Two silent-failure modes apply to any future session-based stage:** an inherited
   `ANTHROPIC_API_KEY` wins over subscription billing in `-p` mode, and an unpinned `--model`
   runs Fable 5 at 2x Opus, violating NFR-I6. Both produce a successful run with wrong economics
   and no error output.

**Success criteria:** Story 3.5 can be implemented without a story-time investigation into
offset encodings, and its first real API call succeeds rather than returning 400.
