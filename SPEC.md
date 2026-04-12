# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current implementation slice is `vas-swarm-jji.17`:
- `vas-swarm-jji.1` is closed: planner mode selection no longer depends on `ClaimFamily`
- `vas-swarm-jji.2` is closed: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core
- `vas-swarm-jji.3` is closed: sourced evidence grounding now runs through generic cited-claim extraction instead of a `profile` switch
- `vas-swarm-jji.4` is closed: non-paper `artifact_reference` planning and provenance are live
- `vas-swarm-jji.5` is closed: production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `vas-swarm-jji.6` is closed: retrieval-ops-only `artifact_reference` runs now stay local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` is closed: investigate preflight no longer touches alphaXiv auth/startup for the representative local-only docs/code preparation
- `vas-swarm-jji.8` is closed: the content check kept representative route selection intact, reactivated the earth-shape grounding boundary, and filed `vas-swarm-jji.9` for the observational claim-alignment follow-up
- `vas-swarm-jji.9` is closed: historical/debate-only observational support fragments now stay belief/contextual
- `vas-swarm-jji.10` is closed: a semantically equivalent observational fallback trace now reclassifies to grounded contradiction without grounded support leakage
- `vas-swarm-9m7` is now closed: citation verification no longer drops separable multi-ref earth-shape summaries into `multiple_refs`, and the measurement lane no longer collapses to a belief-only corpus on the `2026-04-11` fallback live validation
- `vas-swarm-jji.11` is closed: the representative content recheck confirms measurement now grounds, but observational and randomized_intervention reopened a shared cited-claim / grounding boundary
- `vas-swarm-jji.12` is closed: grounding now stays generic while restoring direct observational null-association grounding and preventing empty-claim / cross-supplement review caveats from grounding against the randomized support claim
- `vas-swarm-jji.13` is closed: live verifier/provider timeout collapse now surfaces explicitly in `runtime_failures` metadata instead of disappearing into belief-only or plain `unverified` output
- `vas-swarm-jji.14` is closed: the representative randomized_intervention support asymmetry audit restored direct standalone-caffeine support on the live trace
- `vas-swarm-jji.15` is closed: co-formulated randomized contradictions no longer ground directly against standalone intervention topics when the cited study does not isolate the same intervention
- `vas-swarm-jji.16` is closed: belief-only directional verdicts no longer silently resolve under citation-verifier runtime failure; the representative content check now returns grounded outcomes or explicit partial/runtime-honest degradation
- the next cut is `vas-swarm-jji.17`: reduce partial-result frequency in representative content checks under provider instability without reopening first-order integrity seams

The strategic long-horizon queue for the durable epistemic engine is now:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add non-paper evidence operations
- `vas-swarm-jji.5` — completed: retire the surviving wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only artifact/reference investigations local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — completed: the content check proved representative routing still works and exposed the final first-order follow-ups
- `vas-swarm-jji.9` — completed: demote historical or debate-only support fragments in observational traces
- `vas-swarm-jji.10` — completed: harden observational contradiction grounding under paraphrase and provider-noise drift
- `vas-swarm-jji.11` — completed: rerun the representative content check after the observational paraphrase hardening
- `vas-swarm-jji.12` — completed: harden empirical grounding when extracted cited claims lose topic anchors
- `vas-swarm-jji.13` — completed: surface live verifier/provider failures when randomized support stays belief-only
- `vas-swarm-jji.14` — completed: audit randomized_intervention support balance after runtime-honesty fix
- `vas-swarm-jji.15` — completed: demote co-formulated randomized contradictions from direct grounding
- `vas-swarm-jji.16` — completed: rerun the final Roberto content check and close the belief-only verdict seam exposed by verifier runtime failure
- `vas-swarm-jji.17` — active: reduce partial-result frequency in representative content checks under provider instability

Read the canonical spec for scope, constraints, and done-when criteria.
