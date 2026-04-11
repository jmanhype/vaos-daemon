# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.8`
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

But Roberto is not content yet because the next step is now a content-check audit: the preflight-locality bottleneck is closed, and the program needs evidence on whether any first-order integrity bug still remains or only blocker/background debt is left.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.7`

### What landed
- `Investigate.preflight_runtime/2` now derives alphaXiv preflight eligibility from the topic's evidence plan before auth/startup
- retrieval-ops-only local artifact preparations skip alphaXiv auth and MCP startup entirely
- mixed-source empirical plans still preserve alphaXiv auth/startup preflight when external paper search remains enabled
- `vas-swarm-9m7` remains recorded only as blocker evidence and is not the active implementation scope

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs test/tools/alphaxiv_client_test.exs` -> `136 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or the new non-paper path
### What the slice proved
- the same wrapped docs/code claim that triggered `vas-swarm-jji.6` still stays on `artifact_reference`
- `prepare_advocate_bakeoff/1` still records `evidence_plan_probe_selection.reason == "retrieval_ops_only"` for that claim
- the consulted source set stays `local_repo`-only with explicit `local_artifact_search` provenance; no HuggingFace / Semantic Scholar / OpenAlex / alphaXiv papers appear in `all_papers`
- the runtime artifact [vaos-jji7-local-artifact-validation-1775946503.txt](/tmp/vaos-jji7-local-artifact-validation-1775946503.txt) confirms `source_counts = %{local_repo: 5}` and `unique_sources = ["local_repo"]`
- that same artifact contains no alphaXiv token-refresh, auth-missing, MCP-startup, or MCP-crash warnings
- the next active step is `vas-swarm-jji.8`: a Roberto content check to determine whether any first-order integrity bug still remains

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
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation with explicit provenance
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only `artifact_reference` investigate runs local by suppressing external paper search bleed
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — active: run the Roberto content check after source-isolation closure

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
- do not add more family-specific `planetary_shape` salvage as forward architecture; use `vas-swarm-9m7` as the blocker record unless fresh evidence makes it active again
- spend the next slice on `vas-swarm-jji.8`: audit whether any first-order integrity bug still remains after the source-isolation chain closed, rather than reopening closed source-isolation work or adding new source-family salvage

Shortest version:

`Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, and retrieval-ops-only preflight locality are no longer the core bottlenecks. The next architectural work is deciding whether any first-order integrity bug still remains while the recorded empirical blocker stays blocker evidence only.`

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-9m7` for blocker context.
4. Resume from `vas-swarm-jji.8`.
5. Use the `vas-swarm-jji.7` runtime artifact plus the `vas-swarm-jji.6` runtime artifact as evidence that retrieval dispatch and preflight are now both local for retrieval-ops-only docs/code claims.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
