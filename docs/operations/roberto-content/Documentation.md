# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.6`
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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.6`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans still launch external paper search, which is now the next active bottleneck

But Roberto is not content yet because the next bottleneck is now external-search bleed on retrieval-ops-only `artifact_reference` runs, not more source-family routing.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Current Slice In Progress

### Active issue
- `vas-swarm-jji.6`

### Why this is active
- `vas-swarm-jji.5` removed the last production `ClaimFamily.normalize_topic/1` dependency from the investigate path
- the wrapped docs/code live trace still consulted HuggingFace/external papers even though the selected plan was `artifact_reference` with retrieval-ops-only `local_artifact_search`
- `search_all_papers/4` remains the narrow generic layer that explains that bleed
- `vas-swarm-9m7` remains recorded only as blocker evidence and is not the active implementation scope

### Validation
- Tests:
  - next gate: retrieval-ops-only `artifact_reference` investigate runs stay local while wrapped empirical and docs/code claims continue to route correctly on the generic path
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or the new non-paper path

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.5`

### What landed
- generic wrapper stripping now lives in `Daemon.Tools.Builtins.Investigate.normalized_search_topic/1`
- production investigate no longer aliases or calls `ClaimFamily.normalize_topic/1`
- the obsolete `ClaimFamily.normalize_topic/1` seam was removed instead of being replaced by another family-shaped abstraction
- wrapped docs/code planning coverage now explicitly exercises the generic `artifact_reference` path
- no new topic-family routing was introduced; `vas-swarm-9m7` remains blocker evidence only

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `131 tests, 0 failures`
- Live trace:
  - wrapped docs/code: [vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json)

### What the trace proved
- the wrapped docs/code run completed end to end under `MIX_ENV=test` to avoid a local `8089` port collision
- the selected plan stayed on `artifact_reference` and emitted `retrieval_ops = [%{operation: :local_artifact_search, source: :local_repo, scope: ["docs", "code"], query: "the repository documentation says Documentation.md is the canonical Roberto status file"}]`, proving the wrapper normalized onto the generic local-artifact query
- the trace records explicit local provenance in `trace.sources`, including `source = local_repo`, `source_kind = artifact_doc` for `STATUS.md` and `docs/operations/roberto-content/Documentation.md`, plus `source_kind = artifact_code` for `lib/daemon/operations/roberto_loop.ex`
- the run still finished `direction = opposing` because `retrieval_ops`-only `artifact_reference` planning does not yet suppress HuggingFace/external paper search; that leakage is now the first-order follow-up captured as `vas-swarm-jji.6`

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
- `vas-swarm-jji.6` — active: keep retrieval-ops-only `artifact_reference` investigate runs local by suppressing external paper search bleed

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
- do not add more family-specific `planetary_shape` salvage as forward architecture; use `vas-swarm-9m7` as the blocker record and continue from `vas-swarm-jji.6`
- spend the next slice on containing external paper-search bleed for retrieval-ops-only artifact plans rather than adding new source-family salvage; `vas-swarm-jji.5` already proved the wrapper-normalization seam is gone

Shortest version:

`Planner-family, retrieval-family, profile-conditioned grounding, and wrapper-normalization seams are no longer the core bottleneck. The next architectural work is keeping retrieval-ops-only artifact-reference runs local while the recorded empirical blocker remains live verifier determinism on the recurring earth-shape evidence core.`

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
4. Resume from `vas-swarm-jji.6` with the current understanding that the live investigate core no longer depends on planner/retrieval/grounding/wrapper family seams and now has one generic non-paper artifact path.
5. Use the `vas-swarm-jji.5` wrapped docs/code trace plus the `vas-swarm-jji.4` docs/code and empirical traces as evidence for why the next step is external-search containment on retrieval-ops-only artifact plans rather than more family/profile salvage.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
