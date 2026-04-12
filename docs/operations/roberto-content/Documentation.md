# Roberto Content Program Status

**Last updated**: 2026-04-12
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.17`
**Latest functional checkpoint before this doc stack**: `c8ce3b6`

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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.16`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings
- verifier/provider runtime failures now survive citation verification as explicit `runtime_failures` metadata in both the final JSON payload and trace outcome

The fresh representative content check in `vas-swarm-jji.16` closed the last known first-order empirical integrity seam:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fresh representative measurement trace now grounds opposing evidence instead of collapsing to belief-only
- `vas-swarm-jji.9` is now closed: observational sourced support no longer grounds history / debate / discourse-only fragments for `vaccines cause autism`, and replay of the exact blocker trace preserves grounded contradictory epidemiology
- `vas-swarm-jji.10` is now closed: review-typed observational summaries with direct epidemiology result clauses can now ground as synthesis when topic-aligned under paraphrase/provider drift, while caveat/history/debate fragments remain belief-only
- `vas-swarm-jji.12` is now closed: empty extracted claims no longer ground through paper-only topic fallback, direct observational studies can satisfy topic alignment from split claim-plus-paper anchors, and cross-supplement interaction reviews are classified as indirect combination evidence before synthesis
- the observational lane now grounds direct null-association evidence again, and the randomized lane no longer grounds the old empty-claim / beetroot-caveat leak as grounded-against evidence
- `vas-swarm-jji.13` is now closed: live randomized traces surface verifier/provider timeout collapse explicitly instead of hiding it behind belief-only or plain `unverified` evidence
- `vas-swarm-jji.14` is now closed: a focused randomized-performance crossover query now carries direct caffeine trial papers into the representative live corpus, and direct support grounds again on the caffeine time-trial claim family
- `vas-swarm-jji.15` is now closed: co-formulated randomized contradictions now demote to `indirect/belief` when the cited wording shows mixed-agent or attribution-confound intervention evidence rather than an isolated standalone intervention
- `vas-swarm-jji.16` is now closed: belief-only directional verdicts no longer silently resolve when citation verification/runtime failures remove all grounded evidence; the exact representative observational failure now downgrades to explicit partial `runtime_failure`
- there is no open P1/P2 first-order integrity bug across the representative `measurement`, `observational`, and `randomized_intervention` lanes
- the next active question is `vas-swarm-jji.17`: can representative content checks produce fewer partial results under provider instability without weakening the runtime-honesty boundary that `.16` restored?

That means the next step is `vas-swarm-jji.17`: improve second-order provider resilience now that the first-order Roberto-content criteria are met.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.16`

### What landed
- `direction_summary/4` now gates final verdicting on whether any grounded evidence survived citation verification before resolving belief-only directional consensus
- belief-only directional verdicts now degrade to explicit partial `runtime_failure` when citation-verifier runtime failures occur and grounded evidence is absent
- `investigate` returns a partial runtime-failure completion for that seam instead of persisting a misleading directional belief verdict into the normal completion path
- focused regressions now cover the new boundary directly:
  - belief-only verdicts with verifier runtime failures downgrade to `runtime_failure`
  - grounded verdicts stay directional even if unrelated verifier failures occur elsewhere in the run
- the first-order bottleneck moved from investigate integrity to second-order provider-instability frequency, now filed as `vas-swarm-jji.17`

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `154 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- exact representative content-check artifact [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json) exposed the remaining first-order defect instead of hiding it:
  - measurement trace [vaos-investigate-trace-9cee767146dfb20d-jji16-content-check-1-1775980817034.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji16-content-check-1-1775980817034.json) stayed grounded with `direction = asymmetric_evidence_against`
  - observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji16-content-check-2-1775981014919.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji16-content-check-2-1775981014919.json) returned `belief_consensus_for` despite `grounded_for_count = 0`, `grounded_against_count = 0`, and `runtime_failures.count = 5`
  - randomized trace [vaos-investigate-trace-5c090736ecfc44a0-jji16-content-check-3-1775981237441.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-5c090736ecfc44a0-jji16-content-check-3-1775981237441.json) was already explicit `partial/timeout`
- runtime-equivalent replay artifact [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json) proves the exact bad observational trace now resolves to `replay_direction = runtime_failure` with `replay_partial = true`
- cooldown-safe fallback live validation artifact [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json) shows the representative lanes now end either grounded or explicit partial/runtime-honest under provider noise:
  - fallback measurement trace [vaos-investigate-trace-a7be5c1d943e2844-jji16-content-check-fallback-1-1775982111972.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-jji16-content-check-fallback-1-1775982111972.json) returned `partial_supporting_only`
  - fallback observational trace [vaos-investigate-trace-f503fd8c4bf2184c-jji16-content-check-fallback-2-1775982335765.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-f503fd8c4bf2184c-jji16-content-check-fallback-2-1775982335765.json) grounded contradiction with `direction = asymmetric_evidence_against`
  - fallback randomized trace [vaos-investigate-trace-671b4de7ec2f4f0d-jji16-content-check-fallback-3-1775982502646.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-671b4de7ec2f4f0d-jji16-content-check-fallback-3-1775982502646.json) returned `partial_opposing_only`
- Roberto-content criteria are now met for first-order integrity; the remaining open work is second-order provider-instability reduction in `vas-swarm-jji.17`

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.17`

### Problem
The empirical `investigate` loop no longer has an open first-order integrity bug across the representative lanes, but the live checks still degrade to partial results too often under provider instability:
- fallback measurement returned `partial_supporting_only` under verifier/provider failures
- fallback randomized returned `partial_opposing_only` under verifier/provider failures
- the current question is no longer whether the system lies; it is whether representative checks can complete with fewer partials without weakening truthfulness

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
- `vas-swarm-jji.12` — completed: harden empirical grounding when extracted cited claims lose topic anchors
- `vas-swarm-jji.13` — completed: surface live verifier/provider failures when randomized support stays belief-only
- `vas-swarm-jji.14` — completed: audit randomized_intervention support balance after runtime-honesty fix
- `vas-swarm-jji.15` — completed: demote co-formulated randomized contradictions from direct grounding
- `vas-swarm-jji.16` — completed: rerun the final Roberto content check and close the belief-only verdict seam exposed by verifier runtime failure
- `vas-swarm-jji.17` — active: reduce partial-result frequency in representative content checks under provider instability

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
- spend the next slice on `vas-swarm-jji.17`: reduce partial-result frequency on representative empirical content checks while preserving the explicit runtime-honesty boundary from `.16`

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, the observational support-side history/debate leak, the observational paraphrase/provider-noise contradiction leak, the cited-claim / topic-alignment grounding seam from `vas-swarm-jji.12`, the hidden runtime-collapse seam from `vas-swarm-jji.13`, the representative randomized support-balance audit from `vas-swarm-jji.14`, the co-formulated randomized contradiction seam from `vas-swarm-jji.15`, and the belief-only verdict seam from `vas-swarm-jji.16` are no longer the known core bottlenecks. The remaining active question is second-order: can representative empirical checks complete more often under provider instability without sacrificing honesty?

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, and the `vas-swarm-9m7` verifier collapse is no longer active on the latest live validation
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- observational null-association studies now ground again even when extracted claims are mostly numeric and the paper uses ASD/vaccine variants
- empty-claim cross-supplement review caveats no longer ground against the representative caffeine support claim
- the representative caffeine randomized trace now grounds direct support again through a focused crossover query instead of resolving as grounded-against under verifier noise
- the co-formulated nitric-oxide-plus-caffeine contradiction now replays as `indirect/belief` instead of grounded direct opposition
- belief-only verdicts no longer resolve directionally when verifier/runtime failures remove all grounded evidence
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-jji.17`, the exact content-check artifact [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json), the exact observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji16-content-check-2-1775981014919.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji16-content-check-2-1775981014919.json), the runtime-equivalent replay artifact [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json), and the fallback live artifact [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json).
4. Resume from `vas-swarm-jji.17`.
5. Reduce representative partial-result frequency under provider instability without weakening the runtime-failure honesty boundary from `vas-swarm-jji.16`.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
