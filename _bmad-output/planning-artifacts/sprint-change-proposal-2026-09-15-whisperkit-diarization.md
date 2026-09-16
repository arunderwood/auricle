---
date: 2026-09-15
project: auricle
workflow: correct-course
trigger_story: none (Epic 4 is backlog; discovered via a staleness audit, not implementation)
scope_classification: minor
status: applied
applied: 2026-09-15
artifacts_affected:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/epics.md
---

# Sprint Change Proposal — WhisperKit Rename & SpeakerKit Diarization Candidate

## 1. Issue Summary

### Problem statement

The PRD's Open Resolutions item on WhisperKit diarization quality (verify-before-implementing) and
Architecture's Question #2 (`DiarizerStrategy` abstraction) were both written on 2026-04-26/28 assuming
pyannote-quality diarization would only be reachable via a "v2+ Python-sidecar rewrite" — a cost
significant enough that the architecture explicitly used it to justify stubbing `DiarizerStrategy` down
to `WhisperKitDiarizer` alone, and Story 4.2's acceptance criteria hard-code "no pyannote... in MVP."

Since then, `argmaxinc/WhisperKit` — the package `Package.swift` already depends on — was renamed to
`argmax-oss-swift` and released v1.0.0 (2026-05-01) and v1.1.0 (2026-08-06), crossing a major version.
v1.0.0 bundles **SpeakerKit**, reported as a native Swift, pyannote-based diarizer, in the same package.
If confirmed pure-Swift (not yet empirically verified), the specific cost the architecture used to defer
pyannote — adding Python-sidecar runtime support to a Swift-only build (NFR-M1) — no longer applies.

### How it was discovered

A dependency-staleness audit (2026-09-15) comparing `Package.swift` floors against upstream releases via
the GitHub API, prompted by "it's been a few months since planning, are the software versions still
accurate."

### Evidence

- `gh api repos/argmaxinc/WhisperKit` → `full_name: argmaxinc/argmax-oss-swift`, not archived.
- `gh api repos/argmaxinc/WhisperKit/releases` → v1.1.0 (2026-08-06), v1.0.0 (2026-05-01), v0.18.0
  (2026-04-01 — the version currently resolved in `Package.resolved` against the `from: "0.9.0"` floor).
- PRD Open Resolutions (`prd.md:717`): "WhisperKit diarization current quality... pyannote 3.1 as the
  documented v2+ fallback."
- Architecture Question #2 (`architecture.md:121`): "...adding Python-sidecar runtime support to a
  Swift-only build (NFR-M1) is a double refactor."
- Story 4.2 AC (`epics.md:1842`): "the concrete impl uses WhisperKit's built-in diarization per FR18 (no
  pyannote, no cross-meeting voice-print matching in MVP — those are FR68 v2+)."

**Not independently verified by this proposal:** whether SpeakerKit is actually pure-Swift/CoreML (vs.
shelling out to Python), its resource profile against NFR-P1/P3/P10, and its actual API shape. This
proposal does not assert SpeakerKit should be adopted — it removes a stale assumption that currently
forecloses testing it, and folds that test into the empirical-test mechanism the PRD already has.

### Explicitly NOT part of this issue

- FR68 (cross-meeting voice-print embeddings, v2+) is a **different capability** from single-meeting
  diarization quality (FR18). SpeakerKit's arrival doesn't pull FR68 into MVP scope — see Proposal 3.
- No other epic references WhisperKit's diarization internals. Transcription (Story 4.1, `WhisperKitTranscriber`)
  is unaffected — this proposal is diarization-only.
- The `Package.swift` version floor (`from: "0.9.0"`) is **not changed by this proposal**. Epic 4 is
  `backlog`; the 0.x-vs-1.x decision belongs at Story 4.1/4.2 implementation time, informed by whichever
  engine the widened empirical test favors — not decided speculatively now.

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact | Detail |
|---|---|---|
| Epic 4 | **Story 4.2 AC amendment only** | First Given/When/Then block gains a decision gate instead of a hard foreclosure |
| Epic 1–3, 5–10 | **None** | No other epic touches `DiarizerStrategy` or WhisperKit's diarization API |

Epic scope, count, sequencing, and priority are **unchanged**. Epic 4 is `backlog` — no rework, nothing to
roll back.

### Artifact conflicts

- **PRD** — Open Resolutions bullet (`prd.md:717`) widened to test SpeakerKit alongside WhisperKit-built-in
  diarization, using the same "5+ real captured meetings" protocol already committed to. FR18 and FR68
  text is **unchanged** — the resolution stays open until the empirical test runs, per the PRD's own
  "Verify Before Implementing" framing.
- **Architecture** — Question #2 rationale (`architecture.md:121`) corrected: the cost premise ("Python
  sidecar") that justified stubbing `DiarizerStrategy` to one impl is now conditional on verifying
  SpeakerKit's runtime, not assumed. The decision itself (stub now, `WhisperKitDiarizer` only) is
  unchanged — only the stated cost of reversing it later.
- **Epics** — Story 4.2's first AC block (`epics.md:1839-1843`) amended: removes the "no pyannote... in
  MVP" foreclosure, replaces it with an engine decision gated on the widened empirical test, and decouples
  FR68 (cross-meeting matching, unaffected) from the diarization-engine choice.
- **UX spec, CI/CD, deployment scripts** — no conflict. Nothing here is user-facing or build-tooling.

### Technical impact

None yet — Epic 4 hasn't started. The only forward effect: whoever implements Story 4.1/4.2 now has an
explicit instruction to decide the WhisperKit package version (stay 0.x vs. adopt 1.x) as part of running
the widened empirical test, rather than inheriting whatever `Package.resolved` happens to have drifted to.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1)

Modify the existing PRD/architecture/epics text. No rollback (Epic 4 not started). No MVP review (no scope
or goal change — this changes *what gets tested*, not *what ships*).

**Effort: Low** — three prose edits, no code, no new epics or stories.
**Risk: Low** — Epic 4 is backlog; worst case, the empirical test still concludes WhisperKit-built-in wins
and nothing else changes.
**Timeline impact: None.**

### Rationale

The PRD already has a mechanism for exactly this situation — the Open Resolutions section, built to hold
decisions open until real data is available. The problem wasn't the mechanism; it was that the surrounding
text (architecture's cost rationale, Story 4.2's AC) had hardened around an assumption before the resolution
ran, in a way that would have silently excluded a candidate the empirical test should be evaluating.

---

## 4. Detailed Change Proposals

### 4.1 prd.md — Open Resolutions, WhisperKit diarization quality (line 717)

```
OLD:  - **WhisperKit diarization current quality + whether it exposes embeddings.** Diarization quality
        directly affects the attribution UX. If diarization is poor, the UI's snippet-playback affordance
        compensates partially, but persistent under-segmentation hurts. Embeddings exposure matters for
        v2+ cross-meeting voice-print matching. Resolution: empirical test on 5+ real captured meetings
        during early MVP build.

NEW:  - **WhisperKit diarization current quality + whether it exposes embeddings, evaluated alongside
        SpeakerKit (argmaxinc/argmax-oss-swift v1.0+, pyannote-based, native Swift — confirm it's not a
        Python sidecar before relying on this).** Diarization quality directly affects the attribution UX.
        If diarization is poor, the UI's snippet-playback affordance compensates partially, but persistent
        under-segmentation hurts. Embeddings exposure matters for v2+ cross-meeting voice-print matching.
        Resolution: empirical test on 5+ real captured meetings during early MVP build, run against both
        WhisperKit-built-in diarization and SpeakerKit; pyannote-quality diarization is no longer assumed
        to require a v2+ Python-sidecar rewrite — verify and drop that framing if SpeakerKit is confirmed
        pure-Swift.
```

### 4.2 architecture.md — Architectural Question #2, `DiarizerStrategy` abstraction (line 121)

```
OLD:  2. **`DiarizerStrategy` abstraction.** The summarization stage has a swappable backend baked in
        (FR33: Claude / Ollama / MLX). Diarization does not — WhisperKit-built-in is hard-coded. The
        PRD's own Open Resolutions appendix flags WhisperKit diarization quality as "verify before
        implementing" with pyannote 3.1 as the documented v2+ fallback. If diarization swaps later,
        retrofitting the strategy slot AND adding Python-sidecar runtime support to a Swift-only build
        (NFR-M1) is a double refactor. Stubbing `DiarizerStrategy` now (with `WhisperKitDiarizer` as the
        only impl) is cheap insurance against a risk the PRD already names.

NEW:  2. **`DiarizerStrategy` abstraction.** The summarization stage has a swappable backend baked in
        (FR33: Claude / Ollama / MLX). Diarization does not — WhisperKit-built-in is hard-coded. The
        PRD's Open Resolutions flags WhisperKit diarization quality as "verify before implementing," now
        evaluated against SpeakerKit (argmaxinc/argmax-oss-swift v1.0+) as well as the original pyannote
        3.1 v2+ fallback. SpeakerKit is reported as a native Swift package, not a Python sidecar — if
        confirmed, the "double refactor to add Python-sidecar runtime support" cost no longer applies, and
        a second `DiarizerStrategy` impl (`SpeakerKitDiarizer`) costs the same as any other Swift target.
        This doesn't change the decision to stub `DiarizerStrategy` now with `WhisperKitDiarizer` as the
        only impl at Story 4.2 — it changes what "swapping later" would cost, which Story 4.2's Dev Notes
        should reflect.
```

### 4.3 epics.md — Story 4.2, first AC block (lines 1839–1843)

```
OLD:  **Given** the `WhisperKitDiarizer` target depending on `DiarizerInterface`
      **When** I declare `WhisperKitDiarizer` conforming to `DiarizerStrategy`
      **Then** the protocol exposes: `func diarize(transcript: CanonicalTranscript, audio: URL, config:
        DiarizerConfig) async throws -> DiarizationArtifact` per AR-PAT-7
      **And** the concrete impl uses WhisperKit's built-in diarization per FR18 (no pyannote, no
        cross-meeting voice-print matching in MVP — those are FR68 v2+)
      **And** the diarization runs in the same subprocess as transcribe (per Decision 1.1 — they share
        WhisperKit model state)

NEW:  **Given** the `WhisperKitDiarizer` target depending on `DiarizerInterface`
      **When** I declare `WhisperKitDiarizer` conforming to `DiarizerStrategy`
      **Then** the protocol exposes: `func diarize(transcript: CanonicalTranscript, audio: URL, config:
        DiarizerConfig) async throws -> DiarizationArtifact` per AR-PAT-7
      **And** before writing the concrete impl, the PRD's Open Resolutions empirical test
        (WhisperKit-built-in vs SpeakerKit, per the widened resolution) runs first and decides the engine
        — default to WhisperKit's built-in diarization per FR18 if the test doesn't clearly favor
        SpeakerKit or if SpeakerKit turns out to need non-Swift runtime support
      **And** cross-meeting voice-print matching (FR68) stays v2+ regardless of which engine wins this
        test — that's a separate capability from single-meeting diarization quality, not a reason to
        exclude SpeakerKit
      **And** the diarization runs in the same subprocess as transcribe (per Decision 1.1 — they share
        WhisperKit model state; if SpeakerKit is adopted, confirm it can share the same process/model-load
        lifecycle before locking this AC)
```

---

## 5. Implementation Handoff

### Scope classification: Minor

No epic added, removed, or resequenced. No story added or removed. No FR added, removed, or reworded
(FR18/FR68 text is untouched — only surrounding prose and one Story AC). No architectural commitment
(AR-tag) added or removed — only the rationale behind an existing one corrected.

### Handoff

| Recipient | Responsibility |
|---|---|
| **This workflow** | Applies §4.1–§4.3 directly to `prd.md`, `architecture.md`, `epics.md` (Minor scope — no separate PO/architect pass needed). |
| **Dev (Story 4.1/4.2, when Epic 4 starts)** | Runs the widened empirical test before writing `WhisperKitDiarizer`'s concrete impl; decides the `Package.swift` WhisperKit floor (stay 0.x vs. adopt 1.x) as part of that spike, mirroring Story 1.1's Task 0 pattern from the 2026-09-15 Tuist correction. |

### Success criteria

1. `prd.md:717`, `architecture.md:121`, and `epics.md:1839-1843` no longer assert "no pyannote in MVP" or
   "pyannote requires a v2+ Python sidecar" as settled fact.
2. FR18, FR68, and all AR-tagged commitments are byte-identical to before this proposal — nothing beyond
   the three cited passages changes.
3. `sprint-status.yaml` — no change. Epic 4 stays `backlog`; no story added, removed, or renumbered.

### `sprint-status.yaml` impact

None. No epic or story added, removed, or renumbered.
