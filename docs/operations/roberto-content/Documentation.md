# Roberto Content Program Status

**Last updated**: 2026-04-12
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.18`
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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.17`
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
- `vas-swarm-jji.17` is now closed: transient verifier timeout / provider-error / empty / unexpected citation outcomes no longer persist in the ETS verifier cache, so later representative reruns can retry once the provider stabilizes
- runtime artifact [vaos-jji17-verifier-cache-recovery-1776006215.json](/tmp/vaos-jji17-verifier-cache-recovery-1776006215.json) proves the same representative caffeine citation now moves from `timeout` on run 1 to `verified/trial` on run 2 after provider recovery with no cached failure reuse
- the next active question is `vas-swarm-jji.18`: can malformed non-empty verifier replies be kept out of the stable cache without regressing legitimate negative reasoning?

That means the next step is `vas-swarm-jji.18`: close the remaining non-empty verifier-reply cache seam now that the explicit runtime-failure poisoning path is shut.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.17`

### What landed
- `cached_verify/3` now writes ETS citation-verification cache entries only for stable `VERIFIED` / `PARTIAL` / `UNVERIFIED` results with no explicit `runtime_failure`
- transient verifier timeout / provider-error / empty-response / unexpected-response outcomes no longer poison later reruns in the same runtime
- focused regressions now cover the recovery boundary directly:
  - a verifier timeout remains visible as a runtime failure on the first pass
  - the same representative citation re-verifies cleanly after provider recovery instead of reusing the earlier timeout result
- the bottleneck moved from provider-timeout cache poisoning to malformed non-empty verifier replies, now filed as `vas-swarm-jji.18`

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `155 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- runtime artifact [vaos-jji17-verifier-cache-recovery-1776006215.json](/tmp/vaos-jji17-verifier-cache-recovery-1776006215.json) exercises the real `Investigate.verify_citations/3` path twice in one runtime against representative randomized-intervention evidence:
  - run 1 used a timeouting verifier and returned `verification = timeout`, `runtime_failure_count = 1`, `cache_hits = 0`, `cache_misses = 1`
  - run 2 switched to a healthy verifier and returned `verification = verified`, `paper_type = trial`, `runtime_failure_count = 0`, `cache_hits = 0`, `cache_misses = 1`, `success_provider_calls = 1`
- representative reruns are no longer forced to stay partial just because an earlier verifier call timed out
- the remaining open work is the adjacent malformed-reply seam in `vas-swarm-jji.18`, not the explicit timeout / rate-limit poisoning path from `.17`

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.18`

### Problem
The explicit verifier runtime-failure poisoning path is closed, but one adjacent cache seam remains in the investigate core:
- a non-empty malformed verifier reply can still be parsed as ordinary `unverified` evidence
- that malformed reply can then persist in the stable ETS cache across reruns
- the next question is whether investigate can treat malformed non-classification replies as runtime-failure-shaped outcomes without regressing legitimate negative reasoning

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
- `vas-swarm-jji.17` — completed: transient verifier runtime failures no longer poison investigate citation-verification cache across reruns
- `vas-swarm-jji.18` — active: harden investigate against malformed non-empty verifier replies poisoning the citation cache

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
- spend the next slice on `vas-swarm-jji.18`: harden malformed non-empty verifier replies so transient provider garbage cannot persist as stable cached `unverified` evidence

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, the observational support-side history/debate leak, the observational paraphrase/provider-noise contradiction leak, the cited-claim / topic-alignment grounding seam from `vas-swarm-jji.12`, the hidden runtime-collapse seam from `vas-swarm-jji.13`, the representative randomized support-balance audit from `vas-swarm-jji.14`, the co-formulated randomized contradiction seam from `vas-swarm-jji.15`, the belief-only verdict seam from `vas-swarm-jji.16`, and the explicit verifier-timeout cache-poisoning seam from `vas-swarm-jji.17` are no longer the known core bottlenecks. The remaining active question is narrower: can malformed non-empty verifier replies be kept out of the stable cache without sacrificing legitimate negative verification reasoning?

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
3. Open `vas-swarm-jji.18`, the runtime artifact [vaos-jji17-verifier-cache-recovery-1776006215.json](/tmp/vaos-jji17-verifier-cache-recovery-1776006215.json), the exact representative content-check artifact [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json), the runtime-equivalent replay artifact [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json), and the fallback live artifact [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json).
4. Resume from `vas-swarm-jji.18`.
5. Harden malformed non-empty verifier replies without reopening the runtime-failure honesty boundary from `vas-swarm-jji.16` or the timeout-recovery improvement from `vas-swarm-jji.17`.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
