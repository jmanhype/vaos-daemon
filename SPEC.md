# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current implementation slice is `vas-swarm-jji.4`:
- `vas-swarm-jji.1` is closed: planner mode selection no longer depends on `ClaimFamily`
- `vas-swarm-jji.2` is closed: retrieval no longer depends on family-shaped evidence profiles or query templates in the investigate core
- `vas-swarm-jji.3` is closed: sourced evidence grounding now runs through generic cited-claim extraction instead of a `profile` switch
- `ClaimFamily.normalize_topic/1` remains wrapper-cleanup debt, but it is no longer the first-order bottleneck
- `vas-swarm-9m7` remains recorded only as blocker evidence that exposed the deeper architectural drift
- the next cut is to broaden the durable epistemic engine beyond paper-only retrieval without reintroducing topic-family routing

The strategic long-horizon queue for the durable epistemic engine is now:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — add non-paper evidence operations

Read the canonical spec for scope, constraints, and done-when criteria.
