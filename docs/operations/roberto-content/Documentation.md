# Roberto Content Program Status

**Last updated**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.2`
**Latest functional checkpoint before this doc stack**: `b75a63f`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity bug.

## Current State

The program is back on the right route:
- evidence planning is more generic than it was during the topic-family drift
- planner mode choice no longer depends on `ClaimFamily`
- administration-style intervention phrasing now routes into `randomized_intervention`
- live traces fail more honestly than before
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.4`

But Roberto is not content yet because the next bottleneck is still a first-order evidence problem.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Current Slice In Progress

### Active issue
- `vas-swarm-jji.2`

### Why this is active
- `vas-swarm-jji.1` removed `ClaimFamily` from planner selection, but retrieval still calls into family-shaped evidence profiles
- `ClaimFamily.evidence_profile/3` is now the main compatibility shim left in the core path
- the next slice is to replace family-shaped retrieval hints with generic evidence signatures without regressing representative empirical claims

### Validation
- Tests:
  - `vas-swarm-jji.2` has not landed yet
  - the active gate remains targeted `investigate`-path tests plus one live trace after the retrieval refactor

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.1`

### What landed
- planner selection no longer uses `ClaimFamily`
- `EvidencePlanner` now infers generic evidence signatures from topic terms and supporting keywords
- planner scoring no longer applies `family_bias`
- `search_query_plan/2` no longer emits planner `claim_family` or `family_profile`
- planning traces now expose generic `signatures`

### Validation
- Tests:
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `114 tests, 0 failures`
- Live trace:
  - [vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json)

### What the trace proved
- the selected evidence mode was `measurement`
- the planning block exposed generic `signatures`
- the planning block no longer contained family-conditioned metadata keys

## Recorded Blocker Context

### Active issue
- `vas-swarm-9m7`

### Problem

Earth-shape direct-evidence selection is now stable enough that the remaining instability is downstream:
- recurring direct-evidence refs in the earth-shape family recur at the advocate-selection layer
- those same recurring items still flip between grounded and belief across reruns
- the new claim compaction rules improved the verifier inputs, but the milestone is now blocked on live verification instability:
  - live trace [vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json) grounded recurring ref `8`, but recurring ref `2` still stayed belief-only, so the overlap was still unstable
  - live trace [vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json) drifted into unrelated black-hole horizon literature, so it is not a valid recurrence check for the earth-shape core
  - live trace [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json) hit verifier timeouts and rate limits and ended with no recurring opposing refs grounded
- this is now a blocked verifier-determinism / live-validation problem, not a ledger-lifecycle problem

## Long-Horizon Queue

- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — active: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — replace family-specific verifier salvage with generic cited-claim extraction
- `vas-swarm-jji.4` — add non-paper evidence operations to the durable epistemic engine

Why this order:
- planner agnosticism first, so mode choice is no longer boxed by hidden topic priors
- retrieval and verification generalization second, so the same evidence operation works across claim surfaces
- broader source types after the core path is no longer family-conditioned

## What Roberto Would Do Next

Continue from the next empirical bottleneck, not the inherited full-suite debt:
- use targeted `investigate`-path tests plus live validation as the milestone gate
- keep `vas-swarm-dy1` open only as background suite debt
- only let repo-wide failures block advancement when they intersect `investigate` or its directly coupled planning/verification path
- when three live attempts fail to prove the same milestone because of provider instability or wrapper drift, write down the blocker and pause instead of advancing
- do not add more family-specific `planetary_shape` salvage as forward architecture; use `vas-swarm-9m7` as the blocker record and continue from `vas-swarm-jji.2`

Shortest version:

`Planner-family decoupling is complete. The active architectural work is retrieval-family decoupling, while the recorded empirical blocker remains live verifier determinism on the recurring earth-shape evidence core.`

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `mix osa.roberto.resume`.
3. Open `vas-swarm-9m7` for blocker context.
4. Resume from `vas-swarm-jji.2`.
5. Use the `vas-swarm-jji.1` trace plus the three blocker traces above as evidence for why the retrieval-family path needs to be removed.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.
