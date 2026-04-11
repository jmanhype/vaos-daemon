# Roberto Content Program Status

**Last updated**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-9m7`
**Latest functional checkpoint before this doc stack**: `b75a63f`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity bug.

## Current State

The program is back on the right route:
- evidence planning is more generic than it was during the topic-family drift
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
- `vas-swarm-9m7`

### What landed
- repeated-run ledger writes no longer contend with investigate claim/evidence writes
- `DecisionLedger` and `DecisionJournal` now use a dedicated runtime ledger instead of `:investigate_ledger`
- runtime-ledger isolation is covered by a focused regression test
- verification-claim / claim-family compaction now covers the recurring earth-shape wrappers exposed after the ledger fix:
  - Earth-center quoted reference-frame fragments
  - quoted relation fragments after reporting verbs
  - `subject as "quote"` shape wrappers
  - `connecting it to "quote"` shape wrappers
  - Earth-center clauses with later quoted distractors
  - split spheroid quotes such as `"an oblate spheroid"` plus `"axis of figure coincident ..."`

### Validation
- Tests:
  - `mix test test/intelligence/decision_ledger_test.exs test/intelligence/decision_journal_persistence_test.exs test/intelligence/runtime_ledger_isolation_test.exs test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs --seed 0` -> `160 tests, 0 failures`
- Live traces:
  - [vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json)
  - [vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json)
  - [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json)
- Repo-wide suite audit:
  - the earlier unrelated failures were cleared
  - the remaining failures come from pre-takeover Roberto/PAMF2-era surfaces such as `Explorer`, `SwarmMode`, and older support code
  - those failures are tracked in `vas-swarm-dy1` as inherited non-blocking debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code

## Latest Completed Slice

### Closed issue
- `vas-swarm-tgf`

### What landed
- decision telemetry writes no longer share `:investigate_ledger` with the investigate tool
- `DecisionLedger` now ensures its own runtime ledger is started instead of depending on investigate to boot the shared ledger
- investigate-path regression coverage now proves decision-memory provenance stays off the investigate ledger

### Validation
- Tests:
  - `mix test test/intelligence/decision_ledger_test.exs test/intelligence/decision_journal_persistence_test.exs test/intelligence/runtime_ledger_isolation_test.exs test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs` -> `154 tests, 0 failures`
- Live traces:
  - [vaos-investigate-trace-933bc72a8e647f60-vas-swarm-tgf-live-batch-1-1775864497841.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-933bc72a8e647f60-vas-swarm-tgf-live-batch-1-1775864497841.json)
  - [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-tgf-live-batch-2-1775864610783.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-tgf-live-batch-2-1775864610783.json)
  - [vaos-investigate-trace-ae47836c2550010b-vas-swarm-tgf-live-batch-3-1775864721930.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-ae47836c2550010b-vas-swarm-tgf-live-batch-3-1775864721930.json)
  - [vaos-investigate-trace-ced8169044ad7a49-vas-swarm-tgf-live-batch-4-1775864863691.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-ced8169044ad7a49-vas-swarm-tgf-live-batch-4-1775864863691.json)

### What the trace proved
- repeated traced investigate executions now finish normally instead of timing out in `:investigate_ledger`
- run 4 completed with ordinary provider/verifier degradation instead of the old ledger crash
- the remaining instability in earth-shape runs is downstream of retrieval selection, not runtime ledger contention

## Current Bottleneck

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

- `vas-swarm-jji.1` — remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — replace family-shaped retrieval hints with generic evidence signatures
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
- do not add more family-specific `planetary_shape` salvage as forward architecture; use `vas-swarm-9m7` as the blocker record and resume from `vas-swarm-jji.1`

Shortest version:

`The ledger timeout is closed and the claim-shaping boundary is tighter. The current blocker is live verifier determinism on the recurring earth-shape evidence core, not runtime ledger contention or inherited full-suite debt.`

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
4. Resume from `vas-swarm-jji.1`.
5. Use the three blocker traces above as evidence for why the family-conditioned path needs to be removed.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.
