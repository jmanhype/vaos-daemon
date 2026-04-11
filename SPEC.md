# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current implementation slice is `vas-swarm-9m7`:
- `vas-swarm-jji.1` is closed: planner mode selection no longer depends on `ClaimFamily`
- `vas-swarm-jji.2` is closed: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core
- `vas-swarm-jji.3` is closed: sourced evidence grounding now runs through generic cited-claim extraction instead of a `profile` switch
- `vas-swarm-jji.4` is closed: non-paper `artifact_reference` planning and provenance are live
- `vas-swarm-jji.5` is closed: production investigate no longer depends on `ClaimFamily.normalize_topic/1`
- `vas-swarm-jji.6` is closed: retrieval-ops-only `artifact_reference` runs now stay local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` is closed: investigate preflight no longer touches alphaXiv auth/startup for the representative local-only docs/code preparation
- `vas-swarm-jji.8` is closed: the content check kept representative route selection intact, but the fresh `jji8-measurement` trace reactivated the live earth-shape grounding boundary and filed `vas-swarm-jji.9` for the observational claim-alignment follow-up
- `vas-swarm-9m7` is active again because the measurement path still selected the right direct-evidence corpus but ended `insufficient_evidence` with all opposing sourced items belief-only
- the next cut is to stabilize that live measurement-side grounding boundary without reopening closed source-isolation work

The strategic long-horizon queue for the durable epistemic engine is now:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add non-paper evidence operations
- `vas-swarm-jji.5` — completed: retire the surviving wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: keep retrieval-ops-only artifact/reference investigations local unless mixed-source retrieval is explicit
- `vas-swarm-jji.7` — completed: skip alphaXiv auth/startup preflight for retrieval-ops-only local artifact preparations
- `vas-swarm-jji.8` — completed: the content check proved representative routing still works, but it did not clear the first-order live grounding boundary

Read the canonical spec for scope, constraints, and done-when criteria.
