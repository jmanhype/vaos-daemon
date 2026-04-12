# Roberto Content Program Status

**Last updated**: 2026-04-12
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.13`
**Latest functional checkpoint before this doc stack**: `0f65d52`

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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.13`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings

The fresh representative content check in `vas-swarm-jji.11` and the grounding follow-up in `vas-swarm-jji.12` proved that part of the empirical boundary is now closed:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fresh representative measurement trace now grounds opposing evidence instead of collapsing to belief-only
- `vas-swarm-jji.9` is now closed: observational sourced support no longer grounds history / debate / discourse-only fragments for `vaccines cause autism`, and replay of the exact blocker trace preserves grounded contradictory epidemiology
- `vas-swarm-jji.10` is now closed: review-typed observational summaries with direct epidemiology result clauses can now ground as synthesis when topic-aligned under paraphrase/provider drift, while caveat/history/debate fragments remain belief-only
- `vas-swarm-jji.12` is now closed: empty extracted claims no longer ground through paper-only topic fallback, direct observational studies can satisfy topic alignment from split claim-plus-paper anchors, and cross-supplement interaction reviews are classified as indirect combination evidence before synthesis
- the observational lane now grounds direct null-association evidence again, and the randomized lane no longer grounds the old empty-claim / beetroot-caveat leak as grounded-against evidence
- the remaining first-order problem is no longer grounding integrity; it is runtime honesty when verifier/provider timeouts collapse the live randomized support path without explicit failure metadata
- that boundary is now tracked as `vas-swarm-jji.13`

That means the next step is `vas-swarm-jji.13`: make the live randomized_intervention support path surface verifier/provider failures explicitly instead of ending belief-only with hidden timeout collapse.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.12`

### What landed
- `cited_claim_grounding_role/5` now treats empty extracted claims as non-groundable for paper-only topic fallback, so verification-claim collapse no longer promotes review caveats into grounded evidence
- direct observational grounding can now combine claim and paper anchors for split-anchor cases, but only on the observational evidence profile where that generic rescue is justified
- cross-supplement interaction reviews are classified as indirect combination evidence before synthesis, which keeps the live-shaped beetroot/caffeine caveat out of grounded contradictory evidence
- the first-order bottleneck moved from grounding integrity to runtime honesty, and the follow-up is now filed as `vas-swarm-jji.13`

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `147 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- replay artifact [vaos-jji12-grounding-replay-1775956794.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji12-grounding-replay-1775956794.json) proves the representative saved evidence now lands on the intended side of the grounding boundary:
  - the observational blocker item now classifies `grounding_role = direct` and `evidence_store = grounded`
  - the randomized empty-claim beetroot review now classifies `grounding_role = indirect` and `evidence_store = belief`
- live observational fallback [vaos-investigate-trace-f503fd8c4bf2184c-jji12-live-observational-fallback-port0-1775957319684.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-f503fd8c4bf2184c-jji12-live-observational-fallback-port0-1775957319684.json) selected `observational` and completed with `grounded_for_count = 2`, `grounded_against_count = 3`, `verified_for = 2`, `verified_against = 3`, and `timeout = nil`
- live randomized fallback [vaos-investigate-trace-671b4de7ec2f4f0d-jji12-live-randomized-cycling-postfix-port0-1775958299999.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-671b4de7ec2f4f0d-jji12-live-randomized-cycling-postfix-port0-1775958299999.json) selected `randomized_intervention` and no longer grounded the old empty-claim / cross-supplement caveat leak, but still completed `direction = belief_contested` with `grounded_for_count = 0` and `grounded_against_count = 0`
- terminal-visible runtime failures during that latest randomized run included `Provider zhipu failed, fallback disabled: Connection failed: %Req.TransportError{reason: :timeout}` and `verify_citation failed: "Connection failed: %Req.TransportError{reason: :timeout}"`
- the next step is again a first-order repair, but now on the narrower explicit-failure / runtime-honesty seam tracked as `vas-swarm-jji.13`

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.13`

### Problem
The latest post-fix randomized fallback has isolated a narrower first-order integrity bug:
- grounded support can still collapse to belief-only when live verifier/provider timeouts hit the randomized_intervention lane
- the trace/outcome metadata does not yet surface that failure explicitly, even though the terminal-visible run recorded timeout errors
- this is no longer a cited-claim shaping / topic-alignment / evidence-store classification problem, and it is not a reason to reopen `vas-swarm-9m7` or `vas-swarm-jji.12`

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
- `vas-swarm-jji.13` — active: surface live verifier/provider failures when randomized support stays belief-only

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
- spend the next slice on `vas-swarm-jji.13`: make the live randomized_intervention support path fail explicitly when verifier/provider timeouts prevent grounded evidence

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, the observational support-side history/debate leak, the observational paraphrase/provider-noise contradiction leak, and the cited-claim / topic-alignment grounding seam from `vas-swarm-jji.12` are no longer the known core bottlenecks. The remaining first-order problem is a narrower runtime-honesty seam in `vas-swarm-jji.13`, where live verifier/provider timeouts can still collapse the randomized support lane to belief-only without explicit failure metadata.

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path, and the `vas-swarm-9m7` verifier collapse is no longer active on the latest live validation
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- observational null-association studies now ground again even when extracted claims are mostly numeric and the paper uses ASD/vaccine variants
- empty-claim cross-supplement review caveats no longer ground against the representative caffeine support claim
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-jji.13`, the representative content-check artifact [vaos-jji11-content-check-1775955446.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji11-content-check-1775955446.json), the grounding replay [vaos-jji12-grounding-replay-1775956794.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji12-grounding-replay-1775956794.json), and the post-fix randomized fallback [vaos-investigate-trace-671b4de7ec2f4f0d-jji12-live-randomized-cycling-postfix-port0-1775958299999.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-671b4de7ec2f4f0d-jji12-live-randomized-cycling-postfix-port0-1775958299999.json).
4. Resume from `vas-swarm-jji.13`.
5. Fix the explicit-failure / runtime-honesty seam so the representative randomized_intervention support run either grounds direct evidence or records the verifier/provider timeout in trace/outcome metadata.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
