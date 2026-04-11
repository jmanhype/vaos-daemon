# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current tactical blocker is `vas-swarm-9m7`:
- live verification still flips recurring earth-shape refs between grounded and belief under provider noise
- that blocker exposed a deeper architectural drift: `investigate` still depends on `ClaimFamily` in the planner, retrieval, and verifier path

The strategic long-horizon queue for the durable epistemic engine is now:
- `vas-swarm-jji.1` — remove `ClaimFamily` from planner selection
- `vas-swarm-jji.2` — replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — replace family-specific verifier salvage with generic cited-claim extraction
- `vas-swarm-jji.4` — add non-paper evidence operations

Read the canonical spec for scope, constraints, and done-when criteria.
