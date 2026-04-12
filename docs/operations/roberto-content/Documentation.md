# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.10`
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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.9`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings

But Roberto is not content yet because one first-order empirical boundary remains:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- the intervention lane still grounds direct support
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fallback live measurement trace on `2026-04-11` grounded both sides instead of collapsing to belief-only
- `vas-swarm-jji.9` is now closed: observational sourced support no longer grounds history / debate / discourse-only fragments for `vaccines cause autism`, and replay of the exact blocker trace preserves grounded contradictory epidemiology
- the remaining first-order boundary is now `vas-swarm-jji.10`: observational contradiction grounding under paraphrase and provider-noise drift

So the remaining work is still first-order, not second-order.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.9`

### What landed
- `cited_claim_grounding_role/5` now demotes discourse-only, historical-reporting, and contextual-example claims before observational sourced evidence can be grounded as direct support
- direct observational grounding now requires stronger anchor overlap when the claim exposes multiple anchors, which keeps partial-topic prevalence/history fragments contextual while preserving direct epidemiology grounding through claim or paper-context alignment
- the change stays in the generic cited-claim grounding layer rather than topic-family salvage

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `142 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- the latest live observational fallback trace [vaos-investigate-trace-f503fd8c4bf2184c-vas-swarm-jji-9-live-autism-fallback-3-1775952052549.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-f503fd8c4bf2184c-vas-swarm-jji-9-live-autism-fallback-3-1775952052549.json) still selected `observational` and removed grounded support:
  - `direction = belief_consensus_against`
  - `grounded_for_count = 0`
  - `grounded_against_count = 0`
  - provider instability included Semantic Scholar `HTTP 429` responses and alphaXiv startup failure, so that live paraphrase alone did not prove preserved grounded-against epidemiology
- replaying the exact blocker trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json) through the landed grounding classifier produces artifact [vaos-jji9-observational-replay-1775952269.json](/tmp/vaos-jji9-observational-replay-1775952269.json), which proves the acceptance boundary on the original bad corpus:
  - replayed supporting sourced items: `grounded = 0/3`
  - replayed opposing sourced items: `grounded = 3/5`
  - `"public debate ... persists"` and `"A 1998 report suggested ..."` now stay belief/contextual
  - three contradictory epidemiology items remain grounded against
- the next first-order bottleneck is now `vas-swarm-jji.10`, not the old earth-shape measurement verifier boundary and not the already-closed support-side leak

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.10`

### Problem

The next first-order boundary is observational contradiction robustness under paraphrase/provider noise, not measurement verification and not the already-fixed support-side leak:
- after `vas-swarm-jji.9`, the original `vas-swarm-jji.8` observational blocker trace now demotes the historical/debate support fragments correctly when replayed through the landed classifier
- a fresh semantically equivalent live observational paraphrase still selected `observational`, but under retrieval/provider instability it degraded to belief-only contradiction instead of grounding at least one direct contradictory epidemiology item
- the measurement-side blocker remains closed enough that reopening `vas-swarm-9m7` would be drift unless a new live measurement trace regresses

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
- `vas-swarm-jji.10` — active: harden observational contradiction grounding under paraphrase and provider-noise drift

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
- do not reopen `vas-swarm-9m7` unless a new live measurement trace regresses
- spend the next slice on `vas-swarm-jji.10`: preserve the `vas-swarm-jji.9` contextual-demotion fix while restoring grounded contradictory epidemiology on semantically equivalent observational paraphrases under provider-noise drift

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, and the observational support-side history/debate leak are no longer the core bottlenecks. The next architectural work is observational contradiction grounding robustness in `vas-swarm-jji.10`, not reopening the now-closed earth-shape measurement boundary.

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, and the `vas-swarm-9m7` verifier collapse is no longer active on the latest live validation
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-jji.10`, the observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json), replay artifact [vaos-jji9-observational-replay-1775952269.json](/tmp/vaos-jji9-observational-replay-1775952269.json), and latest live fallback trace [vaos-investigate-trace-f503fd8c4bf2184c-vas-swarm-jji-9-live-autism-fallback-3-1775952052549.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-f503fd8c4bf2184c-vas-swarm-jji-9-live-autism-fallback-3-1775952052549.json).
4. Resume from `vas-swarm-jji.10`.
5. Use the `vas-swarm-jji.8` content-check artifact [vaos-jji8-content-check-1775947922.json](/tmp/vaos-jji8-content-check-1775947922.json) plus the `vas-swarm-jji.9` replay artifact as the fixed grounding boundary; use the latest live fallback trace as the paraphrase/provider-noise boundary; keep [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) as the closed measurement checkpoint.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
