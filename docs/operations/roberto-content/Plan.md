# Plan: Get Roberto Content

**Created**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current Active Issue**: `vas-swarm-jji.18` (open)
**Recently closed measurement issue**: `vas-swarm-9m7`

## Overview

This is a long-horizon hardening program for `investigate`. The work is not “ship one feature”; it is “keep resolving the current first-order bottleneck until the system stops failing in trust-breaking ways.”

The rule for progress is simple:
- identify the first real bottleneck from a live trace
- fix the narrowest generic layer that explains it
- validate with tests and a live rerun
- derive the next bottleneck from evidence

Strategic correction:
- `ClaimFamily` is now treated as transitional heuristic debt, not target architecture
- no more extending family-shaped planner/retrieval/verifier logic unless it is explicitly temporary and tracked for deletion

## Milestone 0: Durable Memory

**Goal**: Make the program resumable across sessions without relying on chat history.

**Status**: In progress

### Tasks

1. Create the long-horizon control files
   - **Location**: `docs/operations/roberto-content/`
   - **Acceptance**:
     - `Prompt.md`, `Plan.md`, `Implement.md`, `Documentation.md` exist
     - they describe objective, milestones, operating rules, and current status

2. Track the program in Beads
   - **Acceptance**:
     - one epic exists for the Roberto-content program
     - the current first-order bottleneck is visible as an active issue

3. Make the stack discoverable
   - **Acceptance**:
     - operations docs link to the current status file

**Validation**
- Read the docs stack end to end
- Confirm the current issue and latest trace are written down

## Milestone 1: Close First-Order Empirical Integrity Bugs

**Goal**: Eliminate known trust-breaking failures in the current literature-centered pipeline, then reduce second-order instability without regressing honesty.

**Current focus**
- `vas-swarm-jji.18`: harden investigate against malformed non-empty verifier replies poisoning the citation cache

**Status note**
- Probe-paper carryover now lands in the merged retrieval set and the live rerun no longer ends `belief_consensus_for`.
- `vas-swarm-942` is complete and closed.
- `vas-swarm-tgf` is complete: repeated traced runs no longer timeout in `:investigate_ledger`.
- `vas-swarm-9m7` is now closed after the verifier stopped dead-ending separable multi-ref sourced summaries as `multiple_refs`.
- `vas-swarm-jji.9` is complete: observational history/debate/discourse support fragments now stay belief/contextual.
- `vas-swarm-jji.10` is complete: the saved live observational fallback trace now reclassifies to `grounded_against_count = 1`, `grounded_for_count = 0`, and `direction = asymmetric_evidence_against` via [vaos-jji10-live-fallback-reclass-1775953735.json](/tmp/vaos-jji10-live-fallback-reclass-1775953735.json).
- `vas-swarm-jji.1` is complete: planner mode selection no longer depends on `ClaimFamily`.
- `vas-swarm-jji.2` is complete: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core.
- `vas-swarm-jji.3` is complete: the live `profile`-conditioned grounding branch is gone and cited-claim extraction is now generic on the production investigate path.
- `vas-swarm-jji.4` is complete: the planner can now select a generic non-paper `artifact_reference` path with explicit trace provenance.
- `vas-swarm-jji.5` is complete: production investigate no longer depends on `ClaimFamily.normalize_topic/1`.
- `vas-swarm-jji.6` is complete: retrieval-ops-only `artifact_reference` runs stay local by suppressing external paper-search bleed exposed by the wrapped docs/code trace.
- `vas-swarm-jji.7` is complete: retrieval-ops-only local artifact preparations no longer trigger alphaXiv auth/startup noise during preflight.
- `vas-swarm-jji.8` is complete: the content check reran the representative empirical lanes and exposed the remaining first-order follow-ups that are now closed.
- `vas-swarm-jji.11` is complete: the representative content-check artifact [vaos-jji11-content-check-1775955446.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji11-content-check-1775955446.json) confirms measurement now grounds and exposed the shared grounding boundary that `vas-swarm-jji.12` then closed.
- `vas-swarm-jji.12` is complete: observational fallback grounds direct null-association evidence again, and the old empty-claim / cross-supplement review caveat no longer grounds against the representative randomized support claim.
- `vas-swarm-jji.13` is complete: live verifier/provider timeout collapse now surfaces explicitly in `runtime_failures` metadata and trace outcome instead of disappearing into belief-only or plain `unverified` output.
- `vas-swarm-jji.14` is complete: the focused crossover query restored direct standalone-caffeine support on the representative randomized trace.
- `vas-swarm-jji.15` is complete: the saved nitric-oxide-plus-caffeine contradiction now replays as `indirect/belief` instead of grounded direct opposition via [vaos-jji15-grounding-replay-1775979139.json](/tmp/vaos-jji15-grounding-replay-1775979139.json).
- `vas-swarm-jji.16` is complete: the exact representative content check [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json) exposed the remaining belief-only verdict seam, the runtime-equivalent replay [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json) proves the exact bad observational trace now downgrades to `runtime_failure`, and the fallback live artifact [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json) shows representative lanes now end grounded or explicit partial/runtime-honest under provider noise.
- `vas-swarm-jji.17` is complete: transient verifier timeout / provider-error / empty / unexpected outcomes no longer persist in the ETS citation cache, and runtime artifact [vaos-jji17-verifier-cache-recovery-1776006215.json](/tmp/vaos-jji17-verifier-cache-recovery-1776006215.json) proves representative caffeine verification now recovers after provider stabilization.
- the next slice is `vas-swarm-jji.18`: harden malformed non-empty verifier replies without reopening a first-order integrity bug.
- Repo-history audit shows the remaining full-suite failures live in pre-takeover Roberto/PAMF2-era surfaces outside the `investigate` tool path.
- Those inherited repo-wide failures are tracked as background debt in `vas-swarm-dy1` and are non-blocking unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code touched by this milestone.

### Task Classes

1. Planner and routing integrity
   - verify paraphrase robustness
   - ensure evidence mode is correct under wrapped and noisy phrasing

2. Retrieval and rerank integrity
   - keep direct-evidence papers from being crowded out by broad reviews
   - preserve probe signal deeper into the full retrieval phase

3. Verification and classification integrity
   - keep direct sourced support groundable
   - prevent indirect/contextual claims from overpowering direct evidence

4. Runtime honesty
   - explicit timeouts
   - explicit rate-limit degradation
   - trace capture on partial or failed runs

5. Non-paper source isolation
  - keep retrieval-ops-only local artifact plans from automatically launching external paper search
  - keep retrieval-ops-only local artifact plans from triggering alphaXiv auth/startup during preflight
  - preserve explicit provenance for local docs/code evidence without mixed-source contamination

**Validation**
- Focused tests for the changed layer
- One live trace on the exact or semantically equivalent claim
- Record unrelated inherited suite failures as background debt instead of treating them as `investigate` blockers
- Beads update naming the next bottleneck
- If three live attempts still fail to verify the same milestone, record the blocker and pause instead of advancing

## Milestone 2: Remove Family-Conditioned Routing

**Goal**: Re-center `investigate` on a durable epistemic engine by removing family dependence from the core path.

### Tasks

1. `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
2. `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
3. `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
4. Track any surviving family logic as temporary debt with a deletion path

**Validation**
- Planner mode selection no longer depends on family-conditioned scoring
- Retrieval query generation and rerank/directness logic no longer depend on `ClaimFamily`
- Verification / grounding behavior no longer depends on family-like `profile` labels or `ClaimFamily` entry points in the core path
- Diff review shows logic moved toward evidence operations, not added topic lists
- Representative non-earth empirical claims still route correctly

## Milestone 3: Reduce Heuristic Debt

**Goal**: Remove or shrink topic-shaped special cases that do not generalize.

### Tasks

1. Audit remaining family- or topic-shaped logic
2. Delete heuristics that duplicate evidence-mode behavior
3. Convert surviving heuristics into generic evidence-operation rules where possible
4. Open explicit debt issues for anything that must remain temporarily
5. `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path

**Validation**
- Diff review shows logic moved toward evidence operations, not added topic lists
- Representative non-caffeine claims still route correctly

## Milestone 4: Broaden Source Coverage

**Goal**: Start closing the gap between a literature-centered investigator and a more general epistemic engine.

### Tasks

1. `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation to the planner
2. `vas-swarm-jji.6` — completed: keep retrieval-ops-only `artifact_reference` investigations local unless mixed-source retrieval is explicit
3. `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
4. `vas-swarm-jji.8` — completed: run the Roberto content check after source-isolation closure
5. Define evidence operations beyond papers
   - docs/specs
   - code/repos
   - benchmarks
   - standards

6. Add at least one non-paper adapter path to the planner
7. Validate on one empirical claim and one docs/code question

**Validation**
- one mixed-source live investigation path exists
- provenance remains explicit
- retrieval-ops-only docs/code validations do not consult external paper sources unless requested
- retrieval-ops-only docs/code preparations do not trigger alphaXiv auth/startup unless mixed-source retrieval is requested

## Milestone 5: Roberto Content Check

**Goal**: Decide whether the remaining work is second-order.

**Status note**
- `vas-swarm-jji.8` completed the content check and exposed the final first-order follow-ups.
- `vas-swarm-9m7` is now resolved: replaying the exact blocker trace no longer returns `multiple_refs` for the recurring earth-shape core, and the fallback live measurement trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) grounded both sides with no timeout.
- `vas-swarm-jji.9` and `vas-swarm-jji.10` are now resolved, `vas-swarm-jji.11` completed the representative recheck, `vas-swarm-jji.12` closed the grounding follow-up, `vas-swarm-jji.13` closed the runtime-honesty follow-up, `vas-swarm-jji.14` closed the randomized support-balance audit, `vas-swarm-jji.15` closed the co-formulated contradiction seam, `vas-swarm-jji.16` closed the final belief-only verdict seam exposed by verifier runtime failure, and `vas-swarm-jji.17` closed the explicit timeout / provider-error cache-poisoning seam. Milestone 5's first-order acceptance criteria remain met; the remaining open work is the narrower malformed-reply cache seam in `vas-swarm-jji.18`.

### Acceptance Criteria

- No open P1/P2 first-order integrity bug remains in the empirical `investigate` loop
- Remaining issues are calibration, source breadth, performance, productization, or second-order provider resilience
- A fresh session can resume from `Documentation.md` + Beads without reconstructing the program from chat
