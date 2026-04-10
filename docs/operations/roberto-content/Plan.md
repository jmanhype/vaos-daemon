# Plan: Get Roberto Content

**Created**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current Active Issue**: `vas-swarm-942`

## Overview

This is a long-horizon hardening program for `investigate`. The work is not “ship one feature”; it is “keep resolving the current first-order bottleneck until the system stops failing in trust-breaking ways.”

The rule for progress is simple:
- identify the first real bottleneck from a live trace
- fix the narrowest generic layer that explains it
- validate with tests and a live rerun
- derive the next bottleneck from evidence

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
- `vas-swarm-942`: recover direct trial corpus when a good probe exists but full retrieval degrades

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
- Beads update naming the next bottleneck

## Milestone 2: Reduce Heuristic Debt

**Goal**: Remove or shrink topic-shaped special cases that do not generalize.

### Tasks

1. Audit remaining family- or topic-shaped logic
2. Delete heuristics that duplicate evidence-mode behavior
3. Convert surviving heuristics into generic evidence-operation rules where possible
4. Open explicit debt issues for anything that must remain temporarily

**Validation**
- Diff review shows logic moved toward evidence operations, not added topic lists
- Representative non-caffeine claims still route correctly

## Milestone 3: Broaden Source Coverage

**Goal**: Start closing the gap between a literature-centered investigator and a more general epistemic engine.

### Tasks

1. Define evidence operations beyond papers
   - docs/specs
   - code/repos
   - benchmarks
   - standards

2. Add at least one non-paper adapter path to the planner
3. Validate on one empirical claim and one docs/code question

**Validation**
- one mixed-source live investigation path exists
- provenance remains explicit

## Milestone 4: Roberto Content Check

**Goal**: Decide whether the remaining work is second-order.

### Acceptance Criteria

- No open P1/P2 first-order integrity bug remains in the empirical `investigate` loop
- Remaining issues are calibration, source breadth, performance, or productization
- A fresh session can resume from `Documentation.md` + Beads without reconstructing the program from chat
