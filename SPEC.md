# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current implementation slice is `vas-swarm-jji.7`:
- `vas-swarm-jji.1` is closed: planner mode selection no longer depends on `ClaimFamily`
- `vas-swarm-jji.2` is closed: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core
- `vas-swarm-jji.3` is closed: sourced evidence grounding now runs through generic cited-claim extraction instead of a `profile` switch
- `vas-swarm-jji.4` is closed: non-paper `artifact_reference` planning and provenance are live
- `vas-swarm-jji.5` is closed: production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `vas-swarm-jji.6` is closed: retrieval-ops-only `artifact_reference` runs now stay local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` is active: investigate preflight still touches alphaXiv auth/startup for the representative local-only docs/code preparation
- `vas-swarm-9m7` remains recorded only as blocker evidence that exposed the deeper architectural drift
- the next cut is to keep retrieval-ops-only local artifact preparations fully local without reintroducing topic-family routing or prematurely reactivating blocker-only debt

The strategic long-horizon queue for the durable epistemic engine is now:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add non-paper evidence operations
- `vas-swarm-jji.5` — completed: retire the surviving wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only artifact/reference investigations local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` — active: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations

Read the canonical spec for scope, constraints, and done-when criteria.
