# Roberto Content Program Status

**Last updated**: 2026-04-12
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.14`
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
- the durable epistemic engine route is now explicit in Beads as `vas-swarm-jji.1` through `vas-swarm-jji.14`
- the `profile`-conditioned grounding branch has been removed from the live investigate path
- production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `ClaimFamily.normalize_verification_claim/1` appears to be superseded in the production investigate path by generic `verification_claim_text/1`
- wrapped docs/code claims now normalize onto the generic `artifact_reference` path without a `ClaimFamily` seam
- retrieval-ops-only `artifact_reference` plans now stay local unless mixed-source retrieval is explicit
- the representative local-only runtime artifact now stays `local_repo`-only through preflight and retrieval without alphaXiv auth/startup warnings
- verifier/provider runtime failures now survive citation verification as explicit `runtime_failures` metadata in both the final JSON payload and trace outcome

The fresh representative content check in `vas-swarm-jji.11` and the grounding follow-up in `vas-swarm-jji.12` proved that part of the empirical boundary is now closed:
- representative planner lanes still route generically across `measurement`, `observational`, and `randomized_intervention`
- `vas-swarm-9m7` is now closed: the measurement verifier no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the fresh representative measurement trace now grounds opposing evidence instead of collapsing to belief-only
- `vas-swarm-jji.9` is now closed: observational sourced support no longer grounds history / debate / discourse-only fragments for `vaccines cause autism`, and replay of the exact blocker trace preserves grounded contradictory epidemiology
- `vas-swarm-jji.10` is now closed: review-typed observational summaries with direct epidemiology result clauses can now ground as synthesis when topic-aligned under paraphrase/provider drift, while caveat/history/debate fragments remain belief-only
- `vas-swarm-jji.12` is now closed: empty extracted claims no longer ground through paper-only topic fallback, direct observational studies can satisfy topic alignment from split claim-plus-paper anchors, and cross-supplement interaction reviews are classified as indirect combination evidence before synthesis
- the observational lane now grounds direct null-association evidence again, and the randomized lane no longer grounds the old empty-claim / beetroot-caveat leak as grounded-against evidence
- `vas-swarm-jji.13` is now closed: live randomized traces surface verifier/provider timeout collapse explicitly instead of hiding it behind belief-only or plain `unverified` evidence
- the next active question is `vas-swarm-jji.14`: after the runtime-honesty fix, is the representative randomized support lane genuinely evidence-against, or is support-side grounding still under-calibrated when verifier timeout noise coexists with one grounded-against item?

That means the next step is `vas-swarm-jji.14`: audit the representative randomized_intervention support balance now that runtime-failure surfacing is honest.

Strategic correction:
- `ClaimFamily` is no longer treated as the intended architecture
- the family layer is now tracked as heuristic debt to remove from planner, retrieval, and verifier paths

Repo-wide full-suite debt is no longer the gating concern for this program when that debt is inherited and outside the `investigate` tool path.

## Latest Completed Slice

### Closed issue
- `vas-swarm-jji.13`

### What landed
- `verify_citations/3` now preserves live verifier/provider failures as structured runtime-failure examples instead of collapsing them into plain `unverified`
- merged verification stats now carry runtime-failure counts/examples through the full analysis path
- final investigate metadata now emits `runtime_failures`, and `build_boundary_trace/2` projects the same failures into `trace.outcome.runtime_failures`
- verifier/provider runtime collapse no longer gets mislabeled as fraudulent citation failure just because the verifier transport timed out
- the first-order bottleneck moved from hidden runtime collapse to a narrower calibration audit, now filed as `vas-swarm-jji.14`

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `150 tests, 0 failures`
  - inherited repo-wide warnings and unrelated suite failures remain background debt unless they intersect `investigate`, `evidence_planner`, or directly coupled verification/retrieval code
### What the slice proved
- live validation artifact [vaos-jji13-live-validation-summary-1775960549509.json](/tmp/vaos-jji13-live-validation-summary-1775960549509.json) proves the runtime-honesty boundary moved on the representative caffeine claim family
- live randomized trace [vaos-investigate-trace-671b4de7ec2f4f0d-jji13-live-randomized-caffeine-1775960549509.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-671b4de7ec2f4f0d-jji13-live-randomized-caffeine-1775960549509.json) completed with `direction = asymmetric_evidence_against`, `grounded_for_count = 0`, `grounded_against_count = 1`, `verified_for = 1`, `verified_against = 3`, and `timeout = nil`
- that same trace now records `runtime_failures = [%{phase: "citation_verification", source: "verifier", kind: "timeout", count: 2, model: "glm-4.5-flash", examples: [...]}]`
- the surfaced verifier failures correspond to timed-out checks on paper refs `3` and `6`, so the live run no longer hides verifier collapse even when the verdict does not land on support
- the next step is no longer failure surfacing; it is the follow-up calibration audit now tracked as `vas-swarm-jji.14`

## Recorded Blocker Context

### Active issue
- `vas-swarm-jji.14`

### Problem
The latest post-fix randomized validation has moved the bottleneck again:
- live verifier/provider timeout collapse is now surfaced honestly in `runtime_failures`
- the representative caffeine randomized trace no longer ends belief-only, but it now resolves `asymmetric_evidence_against` with `grounded_for_count = 0`, `grounded_against_count = 1`, and two surfaced verifier timeouts
- the next question is whether that asymmetry is genuinely evidence-driven or still reflects under-calibrated support-side grounding under live timeout noise

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
- `vas-swarm-jji.14` — active: audit randomized_intervention support balance after runtime-honesty fix

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
- spend the next slice on `vas-swarm-jji.14`: determine whether the representative randomized_intervention support asymmetry is a real grounded-against result or a remaining calibration issue now that runtime failures are explicit

Shortest version:

Planner-family, retrieval-family, profile-conditioned grounding, wrapper-normalization, external-search bleed, the measurement-side multi-ref verifier collapse, the observational support-side history/debate leak, the observational paraphrase/provider-noise contradiction leak, the cited-claim / topic-alignment grounding seam from `vas-swarm-jji.12`, and the hidden runtime-collapse seam from `vas-swarm-jji.13` are no longer the known core bottlenecks. The remaining active question is narrower still: after runtime honesty is restored, does the representative randomized support lane still need calibration work, or is the new grounded-against result stable?

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
3. Open `vas-swarm-jji.14`, the representative content-check artifact [vaos-jji11-content-check-1775955446.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji11-content-check-1775955446.json), the grounding replay [vaos-jji12-grounding-replay-1775956794.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji12-grounding-replay-1775956794.json), the live validation summary [vaos-jji13-live-validation-summary-1775960549509.json](/tmp/vaos-jji13-live-validation-summary-1775960549509.json), and the new randomized trace [vaos-investigate-trace-671b4de7ec2f4f0d-jji13-live-randomized-caffeine-1775960549509.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-671b4de7ec2f4f0d-jji13-live-randomized-caffeine-1775960549509.json).
4. Resume from `vas-swarm-jji.14`.
5. Audit whether the representative randomized_intervention support asymmetry is genuinely grounded-against or still under-calibrated now that verifier/provider timeouts are explicit.
6. Record unrelated suite failures under `vas-swarm-dy1` without blocking `investigate` milestone advancement.
7. Update this file, close/open issues, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
