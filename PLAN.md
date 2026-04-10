# PLAN

**Canonical plan**: [docs/operations/roberto-content/Plan.md](docs/operations/roberto-content/Plan.md)

## Current Milestone

Close the current first-order integrity bottleneck before moving on.

## Active Issue

`vas-swarm-942` — Recover direct trial corpus for clinical intervention runs when a good performance/placebo probe exists but the full retrieval stack degrades.
Blocked by `vas-swarm-dy1` — restore the repo-level full test gate now that the earlier unrelated assertion failures are fixed.

## Verification Status

- Targeted tests pass for the carryover fix.
- Live validation now carries 1 probe paper into the selected `randomized_intervention` run and produces `grounded_for_count = 1`.
- The earlier unrelated suite failures were cleared and the focused regression pack now passes.
- The milestone is still not cleared for advancement because the latest clean `mix test` run now exposes a remaining blocker in `Daemon.Agent.Orchestrator.SwarmModeTest` and still does not yield a clean final summary.

## Operating Rule

After each slice:
1. run targeted tests
2. run a live validation
3. update Beads and status docs
4. ask what Roberto would do next
5. continue if the next bottleneck is already clear
