# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.5`
**Latest functional checkpoint before this doc stack**: `d0bc837`

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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.4`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- `ClaimFamily.normalize_topic/1` remains live as wrapper-normalization debt
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`

But Roberto is not content yet because the next bottleneck is now the surviving wrapper-normalization seam, not more source-family routing.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Current Slice In Progress

### Active issue
- `vas-swarm-jji.5`

### Why this is active
- `vas-swarm-jji.4` landed the first generic non-paper evidence path without reintroducing topic-family routing
- docs/code and empirical live runs now both complete with the new planning shape intact
- `ClaimFamily.normalize_topic/1` is still live on the production investigate path, making it the next narrow generic seam to retire
- `vas-swarm-9m7` remains recorded only as blocker evidence and is not the active implementation scope

### Validation
- Tests:
  - next gate: production investigate flow no longer depends on `ClaimFamily.normalize_topic/1`, while wrapped empirical and docs/code claims still route correctly on the generic path
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or the new non-paper path

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.4`

### What landed
- `EvidencePlanner` now infers a generic `artifact_reference_signature` for docs/specs/code-style claims and can select `artifact_reference` without `ClaimFamily`
- selected plans now carry explicit `retrieval_ops`, and `investigate` executes `local_artifact_search` against `local_repo` docs/code artifacts before literature retrieval
- non-paper sources now survive normalization with explicit `source_kind` and `provenance` in traces
- the planner/provenance changes did not add any new topic-family routing; `vas-swarm-9m7` remains blocker evidence only

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `131 tests, 0 failures`
- Live traces:
  - docs/code: [vaos-investigate-trace-d3720298d454cb3c-vas-swarm-jji-4-docs-testenv-1775942835911.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-d3720298d454cb3c-vas-swarm-jji-4-docs-testenv-1775942835911.json)
  - empirical: [vaos-investigate-trace-e5e4f891f0c3d92b-vas-swarm-jji-4-empirical-1775942606636.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-e5e4f891f0c3d92b-vas-swarm-jji-4-empirical-1775942606636.json)

### What the trace proved
- the docs/code run completed end to end under `MIX_ENV=test` to avoid a local `8089` port collision, selected `artifact_reference`, and emitted `retrieval_ops = [%{operation: :local_artifact_search, source: :local_repo, scope: ["docs"]}]`
- the docs/code trace records explicit non-paper provenance in `trace.sources`, including `source = local_repo`, `source_kind = artifact_doc`, and `provenance = %{operation: "local_artifact_search", path: "docs/operations/roberto-content/Documentation.md", scope: ["docs"]}`
- the docs/code run finished with `direction = asymmetric_evidence_for`, `grounded_for_count = 1`, and `grounded_against_count = 0`
- the empirical run still selected `measurement` and completed with `direction = supporting`, `grounded_for_count = 1`, and `grounded_against_count = 1`
- together the two traces show that non-paper evidence selection is now generic, explicit, and does not require new topic-family routing

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
- `vas-swarm-jji.5` — active: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path

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
- do not add more family-specific `planetary_shape` salvage as forward architecture; use `vas-swarm-9m7` as the blocker record and continue from `vas-swarm-jji.5`
- spend the next slice on the remaining generic wrapper-normalization seam rather than adding new source-family salvage; `vas-swarm-jji.4` already proved the first non-paper path

Shortest version:

`Planner-family, retrieval-family, profile-conditioned grounding, and paper-only retrieval are no longer the core bottleneck. The next architectural work is retiring the remaining ClaimFamily wrapper-normalization seam while the recorded empirical blocker remains live verifier determinism on the recurring earth-shape evidence core.`

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
4. Resume from `vas-swarm-jji.5` with the current understanding that the live investigate core no longer depends on planner/retrieval/grounding family or profile routing and now has one generic non-paper artifact path.
5. Use the `vas-swarm-jji.4` docs/code and empirical traces plus the three blocker traces above as evidence for why the next step is wrapper-normalization cleanup rather than more family/profile salvage.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
