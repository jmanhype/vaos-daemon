# SPEC

**Canonical spec**: [docs/operations/roberto-content/Prompt.md](docs/operations/roberto-content/Prompt.md)

## Working Goal

Get Roberto content by hardening `investigate` into a trustworthy epistemic engine without drifting into topic-specific hacks.

## Current Focus

The current first-order bottleneck is `vas-swarm-942`:
- the planner finds the right direct-trial lane
- the full retrieval still degrades to broad reviews under source failure
- the run ends belief-only instead of grounding direct trial evidence

Read the canonical spec for scope, constraints, and done-when criteria.
