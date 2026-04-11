# Plan: Get Roberto Content

**Created**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current Active Issue**: `vas-swarm-jji.5` (in progress)
**Recorded blocker issue**: `vas-swarm-9m7` (blocked)

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

**Goal**: Eliminate known trust-breaking failures in the current literature-centered pipeline.

**Current focus**
- `vas-swarm-9m7`: stabilize verification outcomes for recurring earth-shape direct-evidence papers

**Status note**
- Probe-paper carryover now lands in the merged retrieval set and the live rerun no longer ends `belief_consensus_for`.
- `vas-swarm-942` is complete and closed.
- `vas-swarm-tgf` is complete: repeated traced runs no longer timeout in `:investigate_ledger`.
- `vas-swarm-9m7` is paused after three live attempts failed to prove a stable recurring grounded core.
- The next investigate bottleneck is live verifier determinism on the recurring earth-shape evidence core.
- `vas-swarm-jji.1` is complete: planner mode selection no longer depends on `ClaimFamily`.
- `vas-swarm-jji.2` is complete: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core.
- `vas-swarm-jji.3` is complete: the live `profile`-conditioned grounding branch is gone and cited-claim extraction is now generic on the production investigate path.
- `vas-swarm-jji.4` is complete: the planner can now select a generic non-paper `artifact_reference` path with explicit trace provenance.
- `ClaimFamily.normalize_topic/1` remains wrapper-normalization debt and is now the next narrow generic seam to retire.
- `vas-swarm-jji.5` is active: remove the surviving wrapper-normalization seam without reintroducing topic-family routing.
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
5. `vas-swarm-jji.5` — active: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path

**Validation**
- Diff review shows logic moved toward evidence operations, not added topic lists
- Representative non-caffeine claims still route correctly

## Milestone 4: Broaden Source Coverage

**Goal**: Start closing the gap between a literature-centered investigator and a more general epistemic engine.

### Tasks

1. `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation to the planner
2. Define evidence operations beyond papers
   - docs/specs
   - code/repos
   - benchmarks
   - standards

3. Add at least one non-paper adapter path to the planner
4. Validate on one empirical claim and one docs/code question

**Validation**
- one mixed-source live investigation path exists
- provenance remains explicit

## Milestone 5: Roberto Content Check

**Goal**: Decide whether the remaining work is second-order.

### Acceptance Criteria

- No open P1/P2 first-order integrity bug remains in the empirical `investigate` loop
- Remaining issues are calibration, source breadth, performance, or productization
- A fresh session can resume from `Documentation.md` + Beads without reconstructing the program from chat
