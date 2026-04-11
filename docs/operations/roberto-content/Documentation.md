# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-9m7`
**Latest functional checkpoint before this doc stack**: `9c62110`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity bug.

## Current State

The program is back on the right route:
- evidence planning is more generic than it was during the topic-family drift
- planner mode choice no longer depends on `ClaimFamily`
- retrieval no longer depends on `ClaimFamily.evidence_profile/3` in the investigate core
- the durable epistemic engine now has a generic non-paper `artifact_reference` path for docs/code claims
- runtime traces now preserve explicit non-paper provenance for local artifact evidence
- administration-style intervention phrasing now routes into `randomized_intervention`
- live traces fail more honestly than before
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.8`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings

But Roberto is not content yet because the `vas-swarm-jji.8` content check did not clear the live empirical boundary:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- the intervention lane still grounds direct support
- the fresh live `measurement` trace selected the right direct-evidence corpus and still ended `insufficient_evidence` with every opposing sourced item left belief-only
- the fresh live `observational` trace grounded history / debate fragments as support for `vaccines cause autism`, which is now recorded in `vas-swarm-jji.9`

So the remaining work is still first-order, not second-order.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.8`

### What landed
- the content check reran the focused `investigate` gate plus three traced live `investigate` runs on the representative empirical lanes
- no new code landed in this slice; the audit outcome is that the source-isolation chain is closed but the live empirical loop still has an active first-order boundary
- `vas-swarm-9m7` is reactivated from blocker evidence because the fresh measurement trace did not ground the direct-evidence core

### Validation
- Tests:
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `124 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- planner spot checks still selected the intended generic lanes:
  - `examine claims that the earth is flat` -> `measurement`
  - `vaccines cause autism` -> `observational`
  - `acute caffeine intake enhances endurance time-trial performance in trained cyclists and triathletes` -> `randomized_intervention`
- runtime audit artifact [vaos-jji8-content-check-1775947922.json](/tmp/vaos-jji8-content-check-1775947922.json) captured the representative content check plus the three trace paths
- measurement trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json) selected `measurement` and a geodesy corpus via OpenAlex probe carryover, but the verified outcome stayed `grounded_for_count = 0`, `grounded_against_count = 0`, and `direction = insufficient_evidence` without an explicit timeout/provider-failure completion status
- that same measurement trace shows the opposing sourced core is still live (`paper_ref = 3, 8, 14, 2`), but all five sourced items remained belief-only; this reactivates `vas-swarm-9m7`
- observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json) grounded both sides (`2/4`), but it grounded `"public debate ... persists"` and `"a 1998 report suggested ..."` as support for `vaccines cause autism`; that is now tracked in `vas-swarm-jji.9` rather than treated as the next active bottleneck
- randomized-intervention trace [vaos-investigate-trace-5c090736ecfc44a0-jji8-randomized-intervention-1775947922324.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-5c090736ecfc44a0-jji8-randomized-intervention-1775947922324.json) selected `randomized_intervention` and completed with `direction = asymmetric_evidence_for`, `grounded_for_count = 2`, and `grounded_against_count = 0`

## Recorded Blocker Context

### Active issue
- `vas-swarm-9m7`

### Problem

Earth-shape direct-evidence selection is still stable enough that the remaining instability is downstream:
- recurring direct-evidence refs in the earth-shape family still recur at the advocate-selection layer
- those same recurring items still flip between grounded and belief across reruns
- the `vas-swarm-jji.8` content check reactivated the blocker on the same boundary:
  - fresh trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json) selected `measurement`, carried a direct geodesy corpus, and still ended `insufficient_evidence` with every opposing sourced item belief-only
- earlier live evidence still matters:
  - live trace [vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json) grounded recurring ref `8`, but recurring ref `2` still stayed belief-only, so the overlap was still unstable
  - live trace [vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json) drifted into unrelated black-hole horizon literature, so it is not a valid recurrence check for the earth-shape core
  - live trace [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json) hit verifier timeouts and rate limits and ended with no recurring opposing refs grounded
- this is now an active verifier-determinism / cited-claim-grounding problem, not a ledger-lifecycle problem

## Long-Horizon Queue

- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation with explicit provenance
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only `artifact_reference` investigate runs local by suppressing external paper search bleed
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — completed: the content check reran the representative modes, reactivated `vas-swarm-9m7`, and filed `vas-swarm-jji.9` for the observational claim-alignment follow-up

Why this order:
- planner agnosticism first, so mode choice is no longer boxed by hidden topic priors
- retrieval generalization second, so the same evidence operation works across claim surfaces
- capability-driven verifier / grounding behavior next, so the core path no longer depends on family-like `profile` labels
- broader source types after the core path is no longer family-conditioned

## What Roberto Would Do Next

Continue from the next empirical bottleneck, not the inherited full-suite debt:
- use targeted `investigate`-path tests plus live validation as the milestone gate
- keep `vas-swarm-dy1` open only as background suite debt
- only let repo-wide failures block advancement when they intersect `investigate` or its directly coupled planning/verification path
- when three live attempts fail to prove the same milestone because of provider instability or wrapper drift, write down the blocker and pause instead of advancing
- do not add more family-specific `planetary_shape` salvage as forward architecture; treat `vas-swarm-9m7` as the active boundary now that fresh evidence reactivated it
- spend the next slice on `vas-swarm-9m7`: trace why the live measurement corpus still collapses to belief-only after correct routing, rather than reopening closed source-isolation work

Shortest version:

`Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, and retrieval-ops-only preflight locality are no longer the core bottlenecks. The fresh content check reactivated the live measurement grounding boundary, so the next architectural work is stabilizing that verifier / cited-claim path rather than declaring the remaining work second-order.`

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, even though live grounding on the earth-shape core is still unstable
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-9m7` plus the fresh measurement trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json).
4. Resume from `vas-swarm-9m7`.
5. Use the `vas-swarm-jji.8` content-check artifact [vaos-jji8-content-check-1775947922.json](/tmp/vaos-jji8-content-check-1775947922.json) plus the `jji8-measurement` trace as the current evidence boundary.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
