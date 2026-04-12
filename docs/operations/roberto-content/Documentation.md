# Roberto Content Program Status

**Last updated**: 2026-04-12
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.12`
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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.12`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings

The fresh representative content check in `vas-swarm-jji.11` proved that part of the empirical boundary is now closed:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fresh representative measurement trace now grounds opposing evidence instead of collapsing to belief-only
- `vas-swarm-jji.9` is now closed: observational sourced support no longer grounds history / debate / discourse-only fragments for `vaccines cause autism`, and replay of the exact blocker trace preserves grounded contradictory epidemiology
- `vas-swarm-jji.10` is now closed: review-typed observational summaries with direct epidemiology result clauses can now ground as synthesis when topic-aligned under paraphrase/provider drift, while caveat/history/debate fragments remain belief-only
- the observational and randomized_intervention lanes still share one first-order grounding defect: extracted cited claims can lose the topic anchors needed to ground direct empirical evidence, or collapse to empty strings that still let indirect review caveats ground against
- that shared boundary is now tracked as `vas-swarm-jji.12`

That means the next step is `vas-swarm-jji.12`: repair the generic cited-claim / topic-alignment grounding layer that the representative content check just reopened.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.11`

### What landed
- no new code landed in this slice; the work was the representative content recheck itself
- measurement now satisfies the grounded-evidence bar on the original representative topic, so `vas-swarm-9m7` stays closed
- the same content check reopened a shared empirical grounding defect across the observational and randomized_intervention lanes, which is now filed as `vas-swarm-jji.12`

### Validation
- Tests:
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `134 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- fresh artifact [vaos-jji11-content-check-1775955446.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji11-content-check-1775955446.json) reran the representative planner spot checks plus three live traces with no cooldown fallback
- measurement trace [vaos-investigate-trace-9cee767146dfb20d-jji11-measurement-1775955086547.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji11-measurement-1775955086547.json) completed with `direction = asymmetric_evidence_against`, `grounded_against_count = 1`, and `verified_against = 1`
- observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji11-observational-1775955200821.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji11-observational-1775955200821.json) completed with `direction = belief_consensus_against`, `grounded_for_count = 0`, `grounded_against_count = 0`, and `verified_against = 3`; a direct null-risk study (`paper_ref = 2`) remained belief-only because the extracted verification claim lost topic anchors
- randomized trace [vaos-investigate-trace-5c090736ecfc44a0-jji11-randomized-intervention-1775955446334.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-5c090736ecfc44a0-jji11-randomized-intervention-1775955446334.json) completed with `direction = asymmetric_evidence_against`, `grounded_for_count = 0`, `grounded_against_count = 1`, `verified_for = 3`, and `verified_against = 3`; the grounded-against item was an indirect review caveat whose extracted `verification_claim` was empty
- the next step is again a first-order repair, but now on a narrower generic grounding seam tracked as `vas-swarm-jji.12`

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.12`

### Problem
The representative content check has now isolated a narrower first-order integrity bug:
- observational direct null-risk evidence can still stay belief-only when `verification_claim_text/1` strips the topic nouns down to numeric results and the cited paper uses ASD/vaccine variants that miss the current anchor gate
- randomized_intervention review caveats can still ground against the claim when the extracted `verification_claim` collapses to an empty string and grounding falls back too aggressively to paper-context alignment
- this is a generic cited-claim shaping / topic-alignment / evidence-store classification problem, not a planner regression and not a reason to reopen `vas-swarm-9m7`

## Long-Horizon Queue

- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation with explicit provenance
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only `artifact_reference` investigate runs local by suppressing external paper search bleed
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — completed: the content check reran the representative modes, reactivated `vas-swarm-9m7`, and filed `vas-swarm-jji.9` for the observational claim-alignment follow-up
- `vas-swarm-jji.9` — completed: demote historical or debate-only support fragments in observational traces
- `vas-swarm-jji.10` — completed: harden observational contradiction grounding under paraphrase and provider-noise drift
- `vas-swarm-jji.11` — completed: rerun the representative Roberto content check after the observational paraphrase hardening
- `vas-swarm-jji.12` — active: harden empirical grounding when extracted cited claims lose topic anchors

Why this order:
- planner agnosticism first, so mode choice is no longer boxed by hidden topic priors
- retrieval generalization second, so the same evidence operation works across claim surfaces
- capability-driven verifier / grounding behavior next, so the core path no longer depends on family-like `profile` labels
- broader source types after the core path is no longer family-conditioned

## What Roberto Would Do Next

Continue from evidence, not inherited full-suite debt:
- use targeted `investigate`-path tests plus live validation as the milestone gate
- keep `vas-swarm-dy1` open only as background suite debt
- only let repo-wide failures block advancement when they intersect `investigate` or its directly coupled planning/verification path
- when three live attempts fail to prove the same milestone because of provider instability or wrapper drift, write down the blocker and pause instead of advancing
- do not reopen `vas-swarm-9m7` unless a new live measurement trace regresses
- spend the next slice on `vas-swarm-jji.12`: fix the generic cited-claim / topic-alignment grounding seam exposed by the observational and randomized representative traces

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, the observational support-side history/debate leak, and the observational paraphrase/provider-noise contradiction leak are no longer the known core bottlenecks. The remaining first-order problem is a narrower grounding seam in `vas-swarm-jji.12`, where extracted cited claims can lose the anchors needed to ground direct empirical evidence or collapse empty while still allowing indirect caveats to ground.

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, and the `vas-swarm-9m7` verifier collapse is no longer active on the latest live validation
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-jji.12`, the representative content-check artifact [vaos-jji11-content-check-1775955446.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji11-content-check-1775955446.json), and the failing traces [vaos-investigate-trace-6288e6adc2dfd5a5-jji11-observational-1775955200821.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji11-observational-1775955200821.json) and [vaos-investigate-trace-5c090736ecfc44a0-jji11-randomized-intervention-1775955446334.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-5c090736ecfc44a0-jji11-randomized-intervention-1775955446334.json).
4. Resume from `vas-swarm-jji.12`.
5. Fix the cited-claim / topic-alignment grounding seam so the representative observational and randomized_intervention runs either ground direct evidence or fail explicitly.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
