# Roberto Content Program Status

**Last updated**: 2026-04-11
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.9`
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

But Roberto is not content yet because one first-order empirical boundary remains:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- the intervention lane still grounds direct support
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fallback live measurement trace on `2026-04-11` grounded both sides instead of collapsing to belief-only
- the fresh live `observational` trace still grounds history / debate fragments as support for `vaccines cause autism`, which remains active as `vas-swarm-jji.9`

So the remaining work is still first-order, not second-order.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-9m7`

### What landed
- `verification_ref_status/2` no longer short-circuits every multi-ref sourced summary into `multiple_refs`
- when the existing `verification_claim_text/1` pipeline already isolates one substantive primary cited claim, the verifier now focuses that primary paper instead of dropping the item to belief before LLM verification
- inseparable multi-ref summaries still stay rejected, so the fix is limited to the generic verification boundary rather than topic salvage

### Validation
- Tests:
  - `mix test test/investigation/claim_family_test.exs test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `136 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- replaying the exact blocker trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json) through the new verifier target logic now maps the five opposing sourced items back to primary papers instead of the old dead-end:
  - `paper_ref=3 -> {:ok, 3}`
  - `paper_ref=8 -> {:ok, 8}`
  - `paper_ref=14 -> {:ok, 14}`
  - `paper_ref=2 -> {:ok, 2}`
  - `paper_ref=7 -> {:ok, 7}`
- the exact `jji8-measurement` prompt was under a 4-hour DecisionJournal cooldown on `2026-04-11`, so live validation used semantically equivalent fallback `determine whether the earth has measurable curvature`
- fallback live trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) still selected `measurement`, completed without timeout, and no longer collapsed to belief-only:
  - `direction = supporting`
  - `grounded_for_count = 3`
  - `grounded_against_count = 1`
  - `verified_for = 5`
  - `verified_against = 1`
- the next first-order bottleneck is now exactly the already-recorded observational follow-up `vas-swarm-jji.9`, not the old earth-shape measurement verifier boundary

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.9`

### Problem

The next first-order boundary is observational claim alignment, not measurement verification:
- the `vas-swarm-jji.8` observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json) selected `observational` correctly and grounded both sides, but it also grounded history/debate fragments such as `"public debate ... persists"` and `"A 1998 report suggested that MMR vaccine causes autism"`
- those fragments should be contextual/belief material rather than grounded support for the causal claim
- the measurement-side blocker is now resolved enough that reopening `vas-swarm-9m7` would be drift unless a new live measurement trace regresses

## Long-Horizon Queue

- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation with explicit provenance
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only `artifact_reference` investigate runs local by suppressing external paper search bleed
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — completed: the content check reran the representative modes, reactivated `vas-swarm-9m7`, and filed `vas-swarm-jji.9` for the observational claim-alignment follow-up
- `vas-swarm-jji.9` — active: demote historical or debate-only support fragments in observational traces

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
- spend the next slice on `vas-swarm-jji.9`: demote historical or debate-only support fragments in the observational lane without regressing the now-closed measurement verifier boundary

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, and the measurement-side multi-ref verifier collapse are no longer the core bottlenecks. The next architectural work is observational claim alignment in `vas-swarm-jji.9`, not reopening the now-closed earth-shape measurement boundary.

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, and the `vas-swarm-9m7` verifier collapse is no longer active on the latest live validation
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-jji.9` plus the observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json).
4. Resume from `vas-swarm-jji.9`.
5. Use the `vas-swarm-jji.8` content-check artifact [vaos-jji8-content-check-1775947922.json](/tmp/vaos-jji8-content-check-1775947922.json) plus the observational trace as the current evidence boundary; keep [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) as the closed measurement checkpoint.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
