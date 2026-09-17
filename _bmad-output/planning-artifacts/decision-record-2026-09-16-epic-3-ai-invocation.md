---
title: 'Decision record: Epic 3 AI invocation architecture'
date: '2026-09-16'
type: 'decision-record'
status: 'revised 2026-09-16 — (b) narrowed to the summarize stage after the author rebutted two of its three premises'
forum: 'four-agent roundtable (Winston, Amelia, John, Mary) — same cast as the Decision Group 3 roundtable, architecture.md:1306'
inputs:
  - '_bmad-output/planning-artifacts/research/technical-claude-code-agent-sdk-session-capability-2026-09-16/research.md'
  - '_bmad-output/planning-artifacts/research/technical-claude-code-ai-invocation-architecture-2026-09-16/research.md'
constrains:
  - 'architecture.md:1306-1470 (Decision Group 3)'
  - 'architecture.md:365-372 (Decision 1.1)'
  - 'prd.md:448, 577 (FR58), 596 (FR69), 658 (NFR-Pr1), 673 (NFR-I6), 705 (NFR-C1)'
  - 'epics.md Stories 3.2, 3.3, 3.5, 3.7, 3.8, 3.9'
version_anchor: 'Claude Code 2.1.220; @anthropic-ai/claude-agent-sdk 0.3.274'
---

# Decision record: Epic 3 AI invocation architecture

Epic 3 is backlog. `Sources/SummarizerInterface`, `Sources/Summarize`, and
`Sources/ClaudeSummarizer` contain only `ManifestPlaceholder.swift`. No code in the
repository calls the Anthropic API. Nothing here is a migration; all of it is a choice
made before the first line is written.

**This record does not edit `prd.md`, `epics.md`, or `architecture.md`.** It rules, and it
names the edits a later `bmad-correct-course` would make. That course correction is
explicitly out of scope here and should only be run if these rulings survive review.

---

## The two decisions, stated separately

### (a) PROMPT STORAGE — **files on disk, in two tiers**

Prompts move out of `SummarizationPromptBuilder`'s Swift string assembly and into markdown
files. Two tiers, and the tiering is the decision, not a detail:

| Tier | Location | Under test? | Who edits it |
|---|---|---|---|
| **Shipped default** | in-repo, bundled into the app | Yes — snapshot-tested, CI-covered | the maintainer, via a commit |
| **User override** | `~/.auricle/prompts/` (see the file-layout ruling below) | No — the test suite never reads it | the user, live, no rebuild |

`SummarizationPromptBuilder` survives as a *composer*: it resolves the prompt directory,
reads `system.md` plus the mode fragment, interpolates glossary and attendee context, and
hands the assembled bytes to the strategy. It stops being the place prompt *text* lives.

#### Discriminating evidence for (a)

The fact that separates files from Swift-in-code is not a capability fact. It is
**prd.md:448's own rationale**: templates "earn their way in only after the user has
captured enough meetings to feel which categorical splits actually matter."

That sentence presumes an instrument for feeling it. With prompts in Swift, there is no
such instrument — discovering that 1:1s want commitments and design reviews want open
questions requires editing `Sources/Summarize/SummarizationPromptBuilder.swift`,
rebuilding, and replacing the installed binary, per experiment. The deferral's rationale
is not wrong; it is *unfunded*. Decision (a) funds it, at the cost of one config key.

The strongest alternative — keep prompts in Swift, get provenance free from git SHA plus
build version — was checked and does not hold as stated. Nothing in the frontmatter
schema (architecture.md:848-897) or the `telemetry` table (architecture.md:742-767)
records the build that produced a note today. "Provenance is free" is true of the
*mechanism* and false of the *implementation*: under either option, provenance is a
column somebody has to add. Once that is true for both, it stops being an argument for
either.

### (b) INVOCATION — **the summarize stage calls the Anthropic Messages API directly from Swift. Scope is the summarize stage, not the product.**

Option 1 and option 4 differ only on (a), which is ruled above. Option 2 is rejected **for
this stage**. Option 3 is struck rather than deferred — see below.

**The scope qualifier is the substance of the 2026-09-16 revision, not a hedge.** As first
ruled, (b) read "no managed Claude Code session, in production or in development" — one
decision covering every stage. That over-reached. Summarize is a one-shot grounded
extraction; the correction family (Group 5) and the vault-aware direction below are
different shapes, and this room examined neither. A ruling about a transcript-in,
structured-items-out call does not bind a stage whose job is open-ended lookup.

#### Discriminating evidence for (b)

> **This section originally argued a closed loop between three constraints. The loop does
> not hold. It is corrected below rather than deleted, because the corrected version is
> narrower and the original is what the rest of the record was built on.**

**The retracted argument.** As first written: NFR-Pr1 forces `--bare`; NFR-C1 forces
`--bare`; `--bare` skips skill discovery; therefore the two constraints that make a session
safe and affordable are the same flag that deletes its entire proposition. Three premises,
and two of them fail.

**Premise 1 fails on scope.** NFR-Pr1 is a PRD line the author is willing to rescope, and
"a requirement its author will move" is not a constraint. It also overstated the concrete
hazard: the untrusted-folder danger is scoped to the subprocess's **cwd**, and auricle
spawns that subprocess and chooses that cwd. Pointing it at a directory auricle created
removes the hazard with no rescope at all.

**Premise 2 fails on fact, and inverts.** The $0.824 figure is `total_cost_usd`, and the
research pack states three pages from it that under a subscription that field
*"represents what the same tokens would have cost at API list price, **not money owed**."*
It is a notional list price, not a bill. Worse for the original argument: **`--bare`
forecloses subscription billing entirely** — *"Bare mode does not read
`CLAUDE_CODE_OAUTH_TOKEN`."* So subscription billing **requires not-bare**, and skill
discovery **requires not-bare**. The two point the same way. There is no loop.

**Premise 3 stands** and is now inert, because nothing forces `--bare`.

**What the discriminating evidence for (b) actually is, restated for the narrowed scope:**
**the summarize stage's shape.** It is a one-shot grounded extraction from a fixed input —
a transcript, a glossary, an output contract — with a validator waiting on the far side.
[P9] measured the direct Messages API doing the entire job in a single call: structured
items, server-constructed citations, block indices, no 400, no residual. Nothing in that
stage is open-ended, multi-step, or exploratory, which is the only thing an agent loop buys.

**Supporting, for the summarize stage only:**

- **[P9] retired the session's one capability advantage.** [P5]'s structured-output-plus-
  citations was never a gap in the direct path; the direct path had not been tested against
  the route that works.
- **The validator is not in a session's loop.** A prompt iterated in a chat window never
  touches `SubstringGroundingValidator`. The measurable quantity is produced by auricle's
  validator.
- **Surface stability (Mary).** Undocumented `citations_delta`, a session ID scraped from
  human-facing stdout, two monthly re-check obligations for one maintainer across ninety
  stories. The recurring cost is attribution: "did my code change, or did the tool?"
- **`cache_control`, weakened.** Under subscription this is no longer a dollar argument —
  it becomes latency and usage-allowance consumption shared with the maintainer's own
  coding work. Real, but much weaker than originally written.
- **NFR-M1 / distribution.** Claude Code is a bun-compiled binary with embedded JS. Soft
  for a single developer-user who already has it installed; real for anything Sparkle ships.

**Supporting, not discriminating** (each would be survivable alone):

- **Fact 1, `cache_control`.** Zero occurrences in 9,368 lines of shipped type
  definitions; no `systemPrompt` shape accepts a content-block array, so no position
  exists at which to attach a breakpoint. Decision 3.5's tiering is the mechanism by
  which NFR-C1 is met at all. Four breakpoints exist at the Messages API layer; zero at
  the session layer.
- **Citations parsing.** Through a session, offsets arrive only as `citations_delta`
  stream events under `--include-partial-messages`; the reassembled assistant message
  carries `citations: []` because Claude Code's own accumulator ships
  `case "citations_delta": break;` — a deliberate no-op, not a bug likely to be fixed by
  accident [P4]. `citations_delta` is undocumented on the Messages API streaming page. On
  the direct path, citations arrive in the response body.
- **NFR-M1.** "Swift / SwiftUI / AppKit only — no Node bridges, no JavaScript runtimes,
  in MVP." Claude Code 2.1.220 is a bun-compiled Mach-O binary with embedded JS. Option 2
  either bundles it (an NFR-M1 exception requiring explicit motivation, per the pyannote
  precedent) or makes it an external prerequisite of a Sparkle-distributed, self-signed
  `.app` (FR65, NFR-C4) — which weakens NFR-M7's "same git SHA + same toolchain →
  identical" at the behavioral level even where the build stays bit-identical.
- **Surface stability (Mary).** Option 2's glue rests on four mechanisms; two have no
  published contract. Session ID scraped from human-facing stdout (no format contract);
  `Stop` hook `last_assistant_message` (documented, fine); `citations_delta`
  (undocumented, actively discarded by the harness); codepoint offsets (undocumented,
  one-month staleness bar). Both research packs carry recurring monthly re-check
  obligations — 2026-10-01 and 2026-10-16 — for one maintainer across ninety stories.
  The recurring cost is not repair; it is **attribution**: every wrong summary begins
  with "did my code change, or did the tool?"

#### NFR-C1 — reconciled, not amended away

`total_cost_usd` is a client-side estimate the docs say explicitly not to base financial
decisions on. NFR-C1 is written as an enforceable ceiling. Both are true; they are about
different numbers.

**Ruling (John, with Winston):** NFR-C1 stands at $0.50 and gains an explicit enforcement
clause. Enforcement is against **auricle's own computation** — `usage` token counts from
the response multiplied by a rate table that lives in auricle's config and that the
maintainer can correct in an afternoon. That is still an estimate, but it is auricle's
estimate, auditable and fixable. A session's `costUSD` comes from "a price table bundled
at SDK build time" inside a binary the maintainer does not control, and can degrade to
`costBasis: "unknown"` — "a guess at the default model's rate" — for a model the bundled
table does not recognize. For a ceiling denominated in dollars on `claude-opus-5`, that is
a materially worse substrate.

The Anthropic Console / Usage and Cost API is named in the clause as the out-of-band
authority, reconciled periodically rather than per-call. NFR-C1 does not become advisory.

#### Option 3 (hybrid) — struck, not deferred

A session as a "development-time affordance for iterating prompts" proposes an
architectural commitment for something that requires none. Two reasons, and the second is
the real one:

1. The loop needs no session. `auricle summarize <id> --prompt-dir <path>` against a
   cached `transcript.json` is the loop, and Decision 1.1 plus FR12 already make every
   stage independently runnable from the terminal. NFR-M6 already commits to config
   taking effect on next invocation without restart.
2. **A session runs a different code path than production.** A prompt iterated in a chat
   window never touches `SubstringGroundingValidator` or `CitationGroundingValidator`.
   The measurable quantity — `quote_validation_drop_count`, false-keeps — is produced by
   auricle's validator. A session yields an impression; `auricle summarize --prompt-dir`
   yields a number.

Using Claude Code interactively to *draft* prompt text is the maintainer using their
editor. It needs no decision, no story, and no record. It is struck from the option set
on that basis, not deferred to a later tier.

#### The one contingency — and what it would reopen

Option 2's single genuine capability advantage is real, was not anticipated when Decision
3.2 was written, and is not dismissed here. See **Spike** below. Decision (b) is final
except in the narrow case the spike defines.

---

## Consequences for Decision Group 3

### Decision 3.4 — the canonicalization invariant does not survive as written, and its replacement is better

architecture.md:1421 specifies "UTF-8 byte offsets into the NFC-normalized
representation." Measured [P2]: **Unicode codepoints, against the text exactly as
submitted, with no server-side normalization.** Wrong on both axes. The invariant's own
escape hatch (a translation step in `CanonicalTranscript`) anticipated this and is
available — and the room declined to use it.

**Replacement (Amelia):** submit the transcript as a **custom content document** —
`{"type": "content", "content": [...]}`, one content block per utterance. Citations then
return `content_block_location` with `start_block_index` / `end_block_index`, zero-indexed
with exclusive end [P6]. No character offsets are involved anywhere in the exchange.
auricle already knows each utterance's character range in its own canonical text, because
auricle performed the segmentation.

The Unicode-unit question is not translated; it is **deleted**. Swift chooses the unit,
because Swift is the only thing counting, and the renderer's unit is the validator's unit
by construction.

The contract test (Decision 3.4 rule 3) becomes three internal assertions, none of which
depend on an unpublished Anthropic convention:

1. the segmentation that builds the content blocks is the same segmentation carried in
   `CanonicalTranscript`;
2. block index *N* round-trips to a stable `[start, end)` in the canonical text;
3. `SubstringGroundingValidator` resolves into that same character space.

**Named cost, to be measured not argued:** custom content is not chunked further — "your
provided content blocks are used as-is." The minimum citable span becomes a whole
utterance rather than a sentence. That is a quality trade in both directions (richer
blockquote context; a long rambling utterance quoted in full) and belongs in Story 3.8's
smoke-test metric table, not in this record.

### Decision 3.5 — prompt caching survives intact

`cache_control` tiering is unaffected by (b) and unaffected by (a): the composer places
the breakpoints on the assembled blocks regardless of whether the text came from a Swift
literal or a file.

### Decision 3.2 — mode fragments become files

`system.md` (shared) + `citations.md` / `substring.md` (mode). Byte-identity of the shared
portion stops being a test result and becomes a fact about the filesystem.

### Decision 3.7 — gains one field

The J1.5 trust-calibration surface is where prompt provenance is read. No new surface.

---

## Ruling: prompt provenance — **in Epic 3 scope**, as ACs on existing stories

**Not frontmatter.** Cross-cutting concern #11 (architecture.md:115) governs and
anticipated this case by name: frontmatter holds what a vault consumer needs to interpret
the note; SQLite holds "cost data, retention timer state, **model identifiers**, telemetry
counters," and proposals to surface operational state in frontmatter "collide with the
principle and the right answer becomes a CLI verb / report rather than a frontmatter
field." A prompt-set hash is a model identifier's sibling. NFR-I4's schema versioning is
not the relevant axis; the relevant axis is which store owns the fact.

**Where it goes:** a `summarization_prompt_set_hash TEXT` column on the existing
`telemetry` table (architecture.md:742-767), beside `summarization_model`,
`summarization_effort_budget`, and `cost_usd`. `ON DELETE CASCADE` from `meetings`, so it
outlives the cache-dir — which `auricle discard <id>` reaps while leaving the vault note
in place (architecture.md:781). Surfaced by `auricle status <id>` per Decision 3.7.

On the direct-API path this is stronger than hashing. Fact 4 — no mechanism returns the
prompt bytes sent — is a fact about *sessions*: a sentinel passed via
`--append-system-prompt` appeared 0 times in the transcript and 0 times in a 311-line
debug log. On option 4 auricle constructs the request body in its own process. Hashing
those bytes is one line; recording them is two. **Files + session is hash-and-trust.
Files + direct API is byte-exact by construction.** That difference is a consequence of
(b), and it is the reason (a) is safe to take.

**Amelia's condition, carried as an AC, not a note:** a hash is a fingerprint with no
suspect unless the corresponding bytes are recoverable. The shipped default set lives in
the repo and git is its history. A user override directory has none by default, and a hash
pointing at prompt text nobody kept is worse than no hash, because it looks like an
answer. The override directory is version-controlled, or `auricle doctor` (Epic 9) warns.

**Story placement:** column and write in **Story 3.7** (summarize stage entry point /
cache-dir handoff, which already owns telemetry writes per Decision 4.5); doctor check in
Epic 9.

---

## Ruling: A/B comparison harness — **Story 3.9 is not extended. Split across 3.8 (now) and a new v1.1 story.**

Story 3.9's own acceptance criteria settle this: the harness "invokes the configured
MVP-default summarizer strategy with **stubbed** Anthropic responses (deterministic — same
fixture → same response shape, NOT live API calls in CI per NFR-M5 + budget hygiene)."

A stubbed harness **cannot detect a prompt regression at all.** Change the prompt however
you like; the stub returns the bytes it always returned and CI passes green. Story 3.9 is a
*pipeline* regression harness. Extending it into live comparison would break NFR-M5 and CI
budget hygiene and destroy the determinism that makes it useful. It stays exactly as
specified.

The comparison instrument already exists in the plan, hard-coded to the wrong axis.
**Decision 3.6 / Story 3.8** is a comparison harness: ≥5 real transcripts, two things
compared on drop rate / recall / precision / cost / qualitative, a written default-flip
rule, results logged to `smoke-test-results.md`. It compares *strategies*, once.

| Piece | Scope | Rationale |
|---|---|---|
| Generalize Story 3.8's comparison axis from **strategy** → **(strategy, prompt-set)** | **Epic 3, added AC on Story 3.8** | Changes a hard-coded constant into an argument while the rig is being built. Nearly free now; a rewrite in v1.1. |
| Record `summarization_prompt_set_hash` in `smoke-test-results.md` rows | **Epic 3, added AC on Story 3.8** | Ties the comparison output to the provenance ruling; otherwise the log says which prompt won without saying which prompt it was. |
| `auricle summarize --prompt-dir <path>` override flag | **Epic 3 / MVP** | One flag. The iteration loop is this flag plus a cached `transcript.json`. |
| User-facing A/B loop: run prompt B over a corpus, diff the results, present them | **New story, v1.1** | Real tooling with a real UI surface. Number to be assigned at course-correct. |
| Story 3.9 itself | **Unchanged** | Regression instrument. Rename its description away from "eval" at course-correct to stop it being mistaken for a quality measure. |

Mary noted for the record that she is the author of the "Epic 3 is the highest-risk epic,
load-bearing slip risk" assessment and is nonetheless adding to it: "I'm adding one
acceptance criterion that changes a parameter from a constant to an argument. If that slips
Epic 3, Epic 3 was already lost."

---

## Ruling: FR69 — **deferral stands, tier unchanged (v2+), rationale rewritten**

FR69 is two capabilities under one number.

- **Can different meetings get different prompts?** Under decision (a) this is a directory
  and a config key. It is not a feature; it is a consequence, and it ships whether or not
  anyone plans it.
- **Does auricle select the template automatically from calendar metadata, from a curated
  set of five (1:1, standup, external pitch, interview, brainstorm)?** Still a feature.
  Still v2+.

The deferral holds. Its rationale gets **stronger**, not weaker, and must be rewritten to
say why: prd.md:448 asserts that templates earn their way in after the user "has captured
enough meetings to feel which categorical splits actually matter" — and the only way to
feel that is to run different prompts against real meetings and notice which one gets
reached for. Decision (a) does not undermine the deferral; **it supplies the instrument the
deferral's rationale was already assuming existed.** Left as written, prd.md:448 reads as
"nothing until v2," which will be false the moment (a) lands, and will mislead a future
reader into rebuilding a config surface that shipped in MVP.

**Conversely** — the reframe as posed: had the room chosen option 2, personalization would
have been *expensive* (an external binary in the loop, `--bare` deleting skill discovery,
no byte-exact provenance for what was tried). prd.md:448's rationale would then have
survived only by accident, resting on a cost it never named. That is the shape of the
question worth keeping: **448's deferral is only defensible because the invocation
architecture makes the instrument cheap. The rewrite must say so, so the next person to
reopen it knows what the sentence is standing on.**

**PRD edits a later course-correct would make:**

- **prd.md:596 (FR69)** — split explicitly into the selection feature (v2+, unchanged) and
  a note that per-meeting prompt sets are available from MVP via configuration.
- **prd.md:448** — rewrite the rationale to name the mechanism (`prompt_dir` override,
  `--prompt-dir`, the generalized comparison rig) rather than implying nothing exists.
- **prd.md:577 (FR58)** — add `summarization.prompt_dir` to the configurable list. This is
  the record's smallest edit and arguably its most overdue: FR58 lists vault path,
  retention window, engine choice, API key, OAuth account, and log verbosity. It contains
  no prompts, no templates, no output shape. Personalization currently has **no config
  surface whatsoever**, in a single-user tool whose user will tune summarization for as
  long as they use it.

---

## Ruling: user-editable files live under `~/.auricle/`

**Author's rule, 2026-09-16:** *any auricle file the user is expected to edit, extend, or
place config into lives in a structure under `~/.auricle/`.*

This relocates decision (a)'s override directory and contradicts FR59, which specifies
`~/Library/Application Support/com.auricle.app/` for configuration by name. The rule is general;
it is recorded here because decision (a) is what surfaced it.

| Location | Holds | Rationale |
|---|---|---|
| **`~/.auricle/`** | `config.toml` (FR58), `prompts/` (decision (a)), `templates/` if FR69 lands | The user's surface. Everything here is meant to be opened in an editor |
| `~/Library/Application Support/com.auricle.app/` | `auricle.sqlite3`, schema-version markers | Machine-managed operational state. Nobody hand-edits SQLite, so the rule does not reach it |
| `~/Library/Caches/com.auricle.app/` | per-meeting cache-dir artifacts | Unchanged |
| Keychain | secrets | Unchanged (NFR-S1) |

**The line the rule draws is "expected to edit," not "belongs to the user."** The SQLite
database is the user's data and stays put, because the interface to it is `auricle status`, not
a text editor.

**It makes an existing ruling work in practice.** The prompt-provenance decision carries
Amelia's condition that a hash is a fingerprint with no suspect unless the bytes are
recoverable — so the override directory must be version-controlled or `auricle doctor` warns.
A dotfile directory is one a maintainer plausibly runs `git init` in. A directory inside
`~/Library/Application Support/` is one nobody ever does. The relocation is what moves that
condition from a warning nobody acts on to the default behaviour.

**It is the data-portability principle applied.** macOS-native is a means, not an end: a plain
dotfile directory is greppable, versionable, symlinkable, and survives being carried to another
machine or another OS in a way an Application Support bundle does not.

**Code impact today: none.** No configuration layer exists — `Sources/Core` has no `Config`
type. The only Application Support references in `Sources/` are in
`Sources/State/DatabasePoolFactory.swift` and `Sources/State/StateStore.swift`, both for the
SQLite path, which does not move. The rule was stated before it cost anything.

**The one constraint that would bite, and does not apply:** an App Sandbox entitlement would put
`~/.auricle/` out of reach without a user-granted security-scoped bookmark. auricle distributes
self-signed via `spctl` (NFR-C4, FR65) and is not sandboxed, so the rule is free. It would need
revisiting only if App Store distribution were contemplated — which NFR-C4 explicitly declines.

**PRD and architecture edits a later course-correct would make:**

- **prd.md:578 (FR59)** — replace the Application Support path with `~/.auricle/config.toml`,
  and state the split above so the SQLite location does not read as an inconsistency.
- **architecture.md:96, 2640, 2645, 2836** — the storage-location table and the config rows.
  `architecture.md:687` (the SQLite path) and `architecture.md:1199` (the per-Mac
  canonical-status store) are unaffected and must stay as they are.
- **epics.md** — ten occurrences; only those naming *config* move, not those naming the
  database.

## Ruling: vault-reading does NOT replace FR55-57 — build Story 3.12

**Question:** if a session can read the vault directly, is `VaultGlossaryBuilder` dead weight?

**Answer: no. Build Story 3.12 as specified.** The two solve different problems that happen to
share a data source.

| | FR55-57 (Story 3.12) | Vault-reading |
|---|---|---|
| The failure it addresses | ASR mangled a proper noun; restore the canonical spelling | The transcript used a vague referent, or the summary needs context the transcript does not carry |
| Mechanism | Deterministic injection — the term is in the prompt on every call | The model elects to search |
| What it is | a **guarantee** | a **capability** |

Vault-reading partially subsumes the glossary: a model that reads the vault will probably also
spell the term correctly. "Probably" is the distinction. Model-elected retrieval is the same
class of non-determinism as model-elected skill activation, which this record already
establishes is the model's judgment rather than a contract.

**The dependency asymmetry settles the timing, which is the part with an Epic 3 deadline.**
Story 3.12 is pure Swift and depends on nothing outside Epic 3. Vault-reading depends on two
decisions that are not made (whether to build it; which billing path) and on a session
architecture that decision (b) explicitly declined to rule for the summarize stage. Deleting
3.12 now ships MVP with **no jargon correction at all** — Phase 1 of the stated product wedge,
enabled by default — in order to reserve room for an unscheduled v1.1+ capability.

**When vault-reading ships they compose rather than compete:** the glossary guarantees the
spellings, vault-reading supplies the semantics.

### A defect in FR56 to fix while building, not after

The scoping rule as specified is *"≥1 attendee match → keep; ≥1 mention in transcript → keep;
otherwise drop."*

**A mangled transcription does not exact-match.** If the ASR wrote "mesh core", the term
`meshcore` has no transcript mention and scoping drops it — and `meshcore` is exactly the term
the feature exists to correct. **The scoping rule discards the population that jargon correction
targets.** The fix is a fuzzy or phonetic match, or keeping People and Projects unconditionally
and scoping only Concepts; which one is a Story 3.12 design choice. The defect is recorded here
because it is invisible until the feature underperforms for a reason nobody looks for.

**Keep the scoping itself.** At measured rates it is not free to drop: an unscoped glossary of
~5,000 tokens costs roughly **$0.05 per meeting** on a cold cache (the 2x write multiplier
confirmed by [P10]/[P11]), against ~$0.001 scoped — about 10% of the NFR-C1 ceiling.

### A tension Story 3.12 should resolve deliberately

A **scoped** glossary varies per meeting and can therefore never be a prompt-cache hit. An
**unscoped** glossary is byte-identical until the vault changes and is an ideal cache candidate.
Decision 3.5 lists the glossary as "cached when stable" and assumes both. Those assumptions are
in tension, and the implementer should choose between them on measurement rather than discover
the conflict at runtime — the comparison belongs in Story 3.8's metric table, whose axis this
record already generalizes.

## The vault-aware direction — opened, not decided

The author's product call, recorded because it reframes what a session is *for*: let the
model read the vault, kept on task by a skill. Not a prompt-storage mechanism — a
**capability**.

**The case (Sally).** FR55-57 hands the model a flat list of wikilink page names scraped
from the vault. It gets the correct spelling of `[[meshcore]]` and no idea what meshcore
**is** — so when an attendee says "the mesh thing is blocked on the repeater," the summary
says "the mesh thing," because a word list cannot tell you that is the same project. A
session with Read and Grep can go look. The notes stop being transcript-shaped and start
being vault-shaped. Three siblings share that shape: the correction family as an iterative
loop rather than a one-shot suggestion file; personalization as a conversation that edits
its own prompt file rather than a config key; and FR70 series-overview notes, which are
inherently multi-file and have no single-call formulation at all.

**NFR-Pr1 is rescoped to permit this.** Author's call, 2026-09-16. The rescope is the large
one — a model reading the user's whole second brain, which contains notes about people who
were never asked — not the small one (a subprocess running in a directory auricle controls).

### A skill supplies the task. It does not supply the fence.

This is the load-bearing correction on the design, and it is a fact, not a preference.
Permission rules and `PreToolUse` hooks are *"gates in the harness that a call must pass,
**not instructions the model is asked to honor**."* A skill is the second kind. Separately,
model-chosen activation *"is the model's judgment, so a host cannot guarantee a given skill
fired on a given run."* A design that relies on a skill to bound filesystem access has no
bound.

**The fence, assembled from non-default settings:**

| Layer | Mechanism | Note |
|---|---|---|
| Read scope | `permissions.blockReadsOutsideWorkingDirectories: true` | **Off by default.** Without it, a vault cwd confines nothing |
| Working dir | the vault; transcript passed inline as a document block | The model never needs the cache-dir |
| Write | deny `Write`, `Edit` | Deny-first; an allow rule cannot carve an exception. DP4 is absolute |
| Shell | deny `Bash` as a tool | The docs are explicit a Bash *pattern* deny "isn't a security boundary." Denying the tool is a stronger and different claim |
| Egress | OS sandbox network allowlist | Deny rules alone are insufficient; the docs prescribe the combination |
| Prompting | `--permission-mode dontAsk` | "Denies every call that would otherwise prompt." `--permission-prompts none` requires 2.1.259; the anchor build is 2.1.220 |
| Delivery | **a managed settings file** | See below — this is not interchangeable with CLI flags |
| Task | `/auricle-summarize` explicit in the prompt string | Deterministic in `-p`; model-chosen activation is not |

**Why managed settings specifically — checked against a real vault, not assumed.** A vault that
is itself edited with Claude Code will generally carry its own `CLAUDE.md` and
`.claude/settings.*`. Subscription billing forbids `--bare`, so with the vault as cwd both load
into every summarize run: the settings file contributes whatever permissions it grants for the
user's *authoring* work, and the `CLAUDE.md` contributes instructions on **how to write to the
vault** — injected into the one stage that must never write. Neither is hostile. Both are wrong,
silently, and neither is visible from inside auricle's own configuration.

And the precedence trap: **project settings outrank user settings.** With the vault as cwd,
that `settings.local.json` *is* a project settings file. The only level that outranks it is
managed settings — *"no other level, including command line arguments, can override a managed
permission rule."* A fence delivered by CLI flag is outranked by the vault's own config.

### Spike: does the stream expose which vault files were read?

**What it measures.** Whether `--output-format stream-json` emits `tool_use` content blocks
carrying their arguments, so a host can record the Read and Grep calls a session made.

**Why it decides something.** Story 3.12 writes `glossary.json` to the cache-dir, and the
AI-correction wedge-validation metric — *"≥40% of meetings show ≥1 applied jargon correction,"*
the measurement the whole product thesis rests on — is computable *"post-hoc from cache-dir
summary.json + transcript.json + **glossary.json**."* A model that reads the vault itself
produces no `glossary.json`. **The vault-aware feature deletes the instrument that measures
whether the vault-aware feature is working** (Mary).

- **Blocks visible** → a strictly better record replaces it: not "terms auricle offered" but
  "vault notes the model actually consulted." The metric survives and improves.
- **Not visible** → vault-reading costs the wedge-validation instrument, and Story 3.12 would
  have to keep running as a parallel shadow pass purely to produce a measurement file. That is
  absurd on its face and is itself an argument against the vault path.

**RUN 2026-09-16 — PASSED [P10].** Both `tool_use` blocks arrived on the reassembled
assistant message with **complete** arguments: `Grep {"pattern":"beacon","glob":"*.md",...}`
and `Read {"file_path":"<absolute path>"}`. No `--include-partial-messages` plumbing needed.

The record is better than `glossary.json` on three counts: it is what the model *consulted*
rather than what auricle *offered*; `file_path` is fully qualified so there is no ambiguity
about which note; and Grep arguments carry the pattern and glob, so the record shows what was
searched for, not only what was opened. **The wedge-validation metric survives vault-reading
and improves.**

It also sharpens [P4] rather than contradicting it. The stream opens a `tool_use` block with
`input: {}` and fills it by delta — structurally identical to citations. The difference is
what the accumulator does next: `input_json_delta` is folded in correctly (it must be, or the
tool could not run) while `citations_delta` hits `case "citations_delta": break;`. Same shape,
opposite handling, which is strong corroboration that the citations discard is deliberate and
specific rather than a general accumulator weakness.

### The cost datum the probe produced by accident, which the vault design has to answer

[P10]'s run cost `total_cost_usd: 1.747011` — for three turns, one Grep, one Read, in a
four-file fixture with **no transcript involved at all**. The decomposition, which reconciles
to five decimals against published rates, is what matters:

| | |
|---|---|
| `input_tokens` | 6 |
| `cache_creation_input_tokens` | **84,376**, all at the 1-hour TTL |
| `cache_read_input_tokens` | 41,881 |
| `output_tokens` | 351 |
| model | **`claude-fable-5`** — the session's own default; nothing was pinned |

Three consequences, and they do not point the same way:

1. **Against the session: it chose its own model, at 2x.** NFR-I6 makes the model configurable
   with `claude-opus-5` as the MVP default. The session ran Fable 5 — $10/$50 per MTok against
   Opus 5's $5/$25 — because the host pinned nothing. **A session that does not pass `--model`
   violates NFR-I6 silently and at double the token price.** The same tokens on Opus 5 come to
   roughly $0.87. This is a new requirement on any session design, and nobody in the room
   raised it.
2. **For the author's position: the bill is a cold cache, not generation.** 351 output tokens
   cost under two cents; cache creation is 96.6% of the total. A second run inside the hour
   reads that prefix at 0.1x rather than writing it at 2x. Cold-cache figures are the worst
   case, and the earlier $0.165 / $0.824 observations were almost certainly cold too.
3. **Against Fact 1, again: the session cached automatically at the 1-hour TTL, for free.**
   `ephemeral_1h_input_tokens: 84376`, consistent with the documented subscription default.
   Decision 3.5's manual `cache_control` tiering exists to achieve what happened here with no
   configuration at all. The residual gap between the layers is *control over what is cached
   and at what granularity* — not whether caching happens. Fact 1 as originally argued
   overstated this, and this is the second correction to it in this record.

**[P11] then measured the corrected configuration against the real vault, and the number
changed by 3.8x.** Same probe, `--model claude-opus-5` pinned, `--tools Read,Grep,Glob`
restricting the available set, run in a real vault of a few hundred notes carrying its own `CLAUDE.md` and
`settings.local.json` loading:

| | [P10] fixture, unpinned | [P11] real vault, pinned + restricted |
|---|---|---|
| `cache_creation_input_tokens` | 84,376 | **41,885** |
| `output_tokens` | 351 | 920 |
| turns | 3 | 5 |
| `total_cost_usd` | **1.747011** | **0.456198** |

**More work, on a corpus 85x larger, for a quarter of the cost — and under NFR-C1's $0.50
ceiling.** Two levers moved: pinning the model halves the price of every token, and restricting
the tool set appears to halve the cached context by removing unavailable tools' definitions
from the prefix. Both runs reconcile to five decimals against published rates.

**The confound is named rather than glossed:** both levers moved in one run, so the split is
inferred. A price change cannot alter a token count, so the halving must be context — but a
clean A/B holding the model fixed and toggling `--tools` should run before anyone budgets on
it.

**`--tools` is a cost lever, not only a safety measure.** It was passed here to bound what the
session could reach. It appears to have paid for itself twice. Nobody in the room anticipated
that.

**What is still not in the number.** [P11] performed a lookup, not a summarization: no
transcript was submitted and no summary produced. A real summarize adds the transcript as
uncached input (~6-8K tokens for 30 minutes, at 1x — roughly four cents) plus a longer output.
That lands the full operation at or slightly over $0.50 notional, cold. Under a subscription
that is allowance draw shared with the maintainer's own Claude Code work, not money owed. The
figure is no longer an obstacle to the vault direction; it is a budget the design can be held
to.

### The privacy finding [P11] produced, which the vault design must answer before it ships

[P10] established that tool arguments reach the host complete, and the room proposed that
record as the better replacement for `glossary.json`. [P11] shows what is actually in one.

Resolving a single term across the real vault, the model searched it, globbed for filename
variants, invented a disjunction of related spellings — **and then grepped for the names of
three real people it had discovered in the vault along the way**, in an argument of the literal
form `"pattern": "<Name>|<Name>|<Name>"`. None was a participant in the meeting. They entered
the record because the model followed a reference in a note, which is exactly the behavior that
makes vault-reading worth having.

**This is structural, not incidental.** A provenance trail built from tool arguments can
contain personal data about third parties who are not participants in the thing being recorded.
It then inherits every handling obligation the vault itself carries — retention, redaction,
onward sharing — while looking like operational telemetry.

**It collides with a concern the PRD already had, pointed the other way.** NFR-Pr4 is careful
that "calendar email addresses are stripped before payload assembly" — data flowing *out* to
Anthropic. This is the same class of leak flowing *in*: vault content landing in auricle's own
operational store, retained on a telemetry schedule, in a file the author would reasonably
treat as debug output.

#### RULED — paths by default, arguments on demand

**Decision (author, 2026-09-16).** The consulted-context record defaults to **vault-relative
file paths only**. Full tool arguments are captured only when explicitly requested for a single
run, behind a debug flag.

**Why this is not a compromise — the default loses nothing that matters.** The wedge-validation
metric is computed from the *terms* the model had, and in an Obsidian vault a note's path **is**
its wikilink target: `projects/<page>.md` is `[[<page>]]`. A path list is therefore
isomorphic to the term list `glossary.json` carries — restricted to the notes that actually
informed the summary rather than every term auricle offered. **That is a strictly better input
to the metric than `glossary.json`, not a degraded one.**

What the default gives up is the model's *search path* — the invented spelling disjunctions,
the follow-up greps. That is debugging colour, not metric input, and it is exactly what the
flag exists to recover.

**Shape:**

| | Default | `--record-tool-args` |
|---|---|---|
| Artifact | `consulted.json` — vault-relative paths | adds `consulted.debug.json` — full arguments |
| Data class | operational; safe beside timings and token counts | **vault-class**; inherits the vault's retention and sharing rules |
| Exists when | every run | only when the flag was passed for that run |

**Two implementation requirements this creates:**

1. **Relativize before recording.** [P11] returned `file_path` as a fully-qualified absolute
   path. Recording that verbatim puts the maintainer's home directory into an artifact, which
   the project's own PII rules forbid in anything that could become public. Paths are stored
   relative to `vault_path`.
2. **The debug artifact is named and located so its data class is obvious.** A file that looks
   like debug output but carries third parties' personal data is the failure mode this ruling
   exists to prevent; a distinct name and a stated handling rule is the cheapest guard against
   someone later attaching it to a bug report.

**What made this decidable was seeing the record rather than specifying it.** The room proposed
the richer artifact over the narrower one on the reasoning that more provenance is better
provenance. [P11] showed that "richer" meant an invented regex over three real people's names.
The narrower record turned out to also be the better one for the measurement it exists to serve.

**Also observed, recorded because it is the first direct evidence on the product hypothesis:**
the session returned a two-sentence answer identifying the term as specific firmware, naming
the radio band, the system it replaced, the migration date, and a related in-progress project —
all from notes it located itself. An FR55-57 wikilink glossary would have supplied the spelling
and nothing else. One term, one run: not an evaluation, but it points where the feature's
advocates said it would.

### What is NOT decided here

The vault-aware path is opened, not ruled. Unexamined: latency against NFR-P1; usage-allowance
consumption shared with the maintainer's own Claude Code work; whether subscription and API
terms differ on data usage in a way that matters for recordings of other people's voices
(NFR-Pr5 defers to "Anthropic's data-usage policy" without naming which one); the
`ANTHROPIC_API_KEY` footgun — in `-p` mode a present key **always** wins, and FR58 configures
one for the reviewer stages, so a key in the subprocess environment silently bills to the API
and the subscription reasoning evaporates without an error; and the allowance question [P10]
opened above.

**Two silent-failure modes, both of which produce a working run with wrong economics and no
error output:** an inherited `ANTHROPIC_API_KEY` (bills per-token instead of the subscription)
and an unpinned `--model` ([P10] ran Fable 5 at 2x Opus, violating NFR-I6). A vault-path design
that does not pin both explicitly is wrong in a way no test will catch, because the run
succeeds. [P11] pinned both and the cost fell by 3.8x, which is the measurement of what those
two defaults cost.

## Dissent

Recorded by name. Not resolved.

### Mary — against shipping the user-facing prompt override unflagged in MVP

> "File-based storage: yes, unreserved. What I object to is shipping the *user-facing
> override* in MVP, on day one, unflagged."

J1's success criterion is that the user defaults to auricle's notes by month two. Months
one and two are the trust window — the period during which the user decides whether the
validator is worth believing. An editable prompt available on day one means the instrument
being calibrated moves during calibration: the user edits `system.md`, the drop rate jumps,
and cannot distinguish an unreliable Citations path from a sentence they wrote on Tuesday.
Mary identifies this as the same trust-poison mechanism she argued in Group 3, and more
dangerous here because the contamination is self-inflicted and invisible.

**Her proposal:** Path C discipline, exactly as applied to diarization review (FR74). Build
every slot in MVP — `prompt_dir` resolution, override path, hash recording — so the flip is
a config change and not a refactor. Default the user-facing override **off** for the first
thirty days; flip after the trust window closes.

**John, against:** a flag on a single-user tool whose single user wrote the flag is
theater. He will flip it on day two.

**Mary, on that:** "Then he'll flip it on day two *deliberately*, and he'll know that's
what he did when the drop rate moves. I'm not trying to stop him. I'm trying to make it an
event he remembers."

**RESOLVED BY THE AUTHOR, AGAINST MARY, 2026-09-16.** The user-editable prompt override ships
in MVP, unflagged, on day one. Author's words: *"don't restrict me."*

The dissent is kept in full above rather than deleted, because Mary's reasoning is sound and
the failure mode she names is real — it was simply outranked by a principle she was not
weighing: **this is a single-user tool and the single user is its author.** A flag that gates
the maintainer's access to his own tool spends real autonomy to buy legibility.

**What replaces the flag.** Mary's concern is that a moving prompt contaminates trust
calibration during the very window when trust is being formed — the user cannot tell an
unreliable validator from a sentence he wrote on Tuesday. The flag addressed that by holding
the prompt still. `summarization_prompt_set_hash`, already ruled into the `telemetry` table and
surfaced by `auricle status <id>`, addresses the same thing by making the prompt's identity
*visible* instead: when the drop rate moves, the hash says whether the prompt moved with it.

That is the better instrument on its own merits. It answers the question at the moment the
question is asked, per meeting, forever — rather than for thirty days, by preventing the change
that would have raised it. **The flag bought legibility by removing a capability; the hash buys
it by adding a record.** Prefer the record.

**A general principle, extracted because it outranks more than this one item:** proposals that
restrict the maintainer's access to his own single-user tool need to clear a much higher bar
than proposals that add observability. Path C flag-default-off is right for an *unproven AI
feature* whose quality is in question (FR74, diarization review). It is wrong for the author's
own editing surface. The two cases look alike and are not.

### Amelia — conceded on frontmatter, holding on recoverability

Amelia argued for an eight-character prompt-set hash in vault frontmatter on the grounds
that "why did last Tuesday's note come out badly?" is asked in Obsidian while looking at
the note. She conceded to cross-cutting concern #11 on the merits, and on Winston's
correction that the `telemetry` row cascades from `meetings`, not from the cache-dir, so it
outlives `auricle discard`.

She did not concede the recoverability condition, which is carried above as an AC rather
than a footnote: **a hash whose bytes were never kept is worse than no hash, because it
looks like an answer.**

### John — withdrawal is contingent, not given

John's objection to (b) — that Decision 3.2 as written is not implementable on the direct
API, and that option 2 is the only path without that hole — was withdrawn contingent on the
spike.

**The spike ran on 2026-09-16 and the objection is discharged [P9].** Arm A1 returned
parseable JSON and a `char_location` citation in one 200 response, with the CONTROL arm
confirming the documented 400 is live on the same account and model. The 400 is a property of
the `output_config.format` parameter, not of the combination. Decision 3.2's Citations
strategy is implementable on the direct path; the objection was well-founded when raised and
is answered by measurement rather than by argument.

It also retires [P5] as a reason to prefer a session: the session's advantage was never that
it could do something the direct API could not, only that the direct API had not been tested
against the route that works. See the correction recorded in the research pack.

---

## Spike — run it before Story 3.2 locks the prompt shape

**What it measures.** Whether the direct Anthropic Messages API returns **200 or 400** for
a request that (i) enables `citations: {enabled: true}` on a document block and
(ii) requests JSON **by prompt instruction only**, with no `output_config.format` and no
deprecated `output_format` parameter present. Model: `claude-opus-5`.

This is research open question #11 from the session-capability pack, which remains open
because the documented 400 is scoped to `output_config.format` — a *parameter*, not to
"asking for JSON." The docs are silent on the prompt-instruction route in either direction.

**Second arm, free with the first.** Same request shaped as a **custom content document**
(`{"type": "content", "content": [...]}`), confirming `content_block_location` block
indices arrive on the direct path as they do through a session [P6]. This validates the
Decision 3.4 replacement above on the path that will actually ship, and simultaneously
closes research open question #9 (does the direct API agree with [P2]).

**What flips the decision.**

- **400 on the prompt-instruction arm** → Decision 3.2's Citations strategy cannot produce
  structured items with citations in one direct call. [P5] becomes concretely load-bearing
  rather than interesting, and **(b) reopens for the summarize stage only** — to be
  re-weighed against Fact 1 with the real cost delta, not the hypothetical one. Note the
  fallbacks available *before* reopening (b): two-call (doubles cost, breaks NFR-C1), or
  model-asserted `source_block_index` validated by the substring path (cheaper, but it is
  the model asserting a pointer rather than the server constructing one, which is exactly
  the property that makes Citations worth having).
- **200** → the last capability gap between option 4 and option 2 closes. (b) is final with
  no residual and John's objection is discharged.
- **Block-index arm fails on the direct path** → the Decision 3.4 replacement is unavailable
  and the codepoint translation layer comes back off the bench, with its one-month staleness
  obligation attached. This arm is expected to pass; it is run because an unrun expectation
  is not evidence.

**Which story it attaches to.** *None — run it now, outside the story sequence.* Both
probes live at
`_bmad-output/planning-artifacts/research/technical-claude-code-agent-sdk-session-capability-2026-09-16/`
and need only `ANTHROPIC_API_KEY`.

### Spike status as of 2026-09-16

**COMPLETE — all arms run 2026-09-16 against `claude-opus-5`.**

| Arm | Result | What it settles |
|---|---|---|
| Offset unit, direct path | **[P8]** codepoints, as submitted — identical to the session on both NFC and NFD arms | Closes open question #9. The convention is API behavior, not harness behavior |
| CONTROL — `output_config.format` + citations | **400**: *"Citations cannot be enabled when output format is set."* | The documented incompatibility is live here, so every 200 below is real |
| **A1 — JSON by prompt instruction + citations** | **200, BOTH** — JSON parsed, `char_location` [53, 105) matching [P2]/[P8] | **Closes open question #11. (b) is final with no residual.** |
| A2 — custom content → `content_block_location` | **200**, blocks [1, 2) — exactly the one utterance carrying the target | **The Decision 3.4 replacement holds on the shipping path** |
| A3 — custom content + citations + JSON | **200, BOTH** — JSON plus block indices | The exact shape auricle will send, verified end to end |

**Both flip conditions resolved in the direction that closes the decision.** The 400 case
that would have reopened (b) did not occur; the block-index case that would have restored the
codepoint translation layer did not occur either. Decision (b) is final. Decision 3.4's
replacement is confirmed rather than proposed.

**One finding to carry into Story 3.4, which no arm was designed to produce.** In A3 the
model's `source_quote` read `"The Auricle beacon transmits at exactly 1427 hertz."` while the
citation's `cited_text` read `"<Speaker_2>: The Auricle beacon transmits at exactly 1427
hertz."` — the model dropped the speaker prefix in the text it wrote; the server's citation
carried the whole block. The server-constructed pointer and the model-asserted quote are
different artifacts, and only the first is authoritative about span.

This matters for `ClaudeSubstringSummarizer` and NFR-R7, which requires a `source_transcript_quote`
that survives a literal substring match. A model that silently strips a speaker prefix still
passes that match — the stripped quote remains a substring — but a model that normalizes
punctuation or expands a contraction would not, and would be dropped. Decision 3.5's substring
instruction already anticipates this ("character-for-character including punctuation. Do not
normalize, expand contractions, or remove disfluencies"). **The observation confirms the
instruction is load-bearing rather than defensive, and gives Story 3.8's smoke test a specific
thing to count:** how often the model's quote diverges from the block it cited.

**If it slips:** it becomes a blocking pre-AC on **Story 3.3** (`AnthropicHTTPClient` — the
first story with live Anthropic access), and **Story 3.2 must not merge before it
resolves**, because the prompt builder's citations-mode fragment differs depending on the
answer: an `output_config.format` request carries no JSON-shape instruction, while a
prompt-instruction request must carry the full output contract in the prompt text.

---

## What this record does not do

No sprint change proposal. No edits to `prd.md`, `epics.md`, or `architecture.md`. The
rulings above name their intended edits; running `bmad-correct-course` to apply them is a
separate decision, to be taken only if this record survives review.
