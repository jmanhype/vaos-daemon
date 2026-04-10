# Roberto Content Program Status

**Last updated**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-dy1`
**Latest functional checkpoint before this doc stack**: `b75a63f`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity bug.

## Current State

The program is back on the right route:
- evidence planning is more generic than it was during the topic-family drift
- administration-style intervention phrasing now routes into `randomized_intervention`
- live traces fail more honestly than before

But Roberto is not content yet because the next bottleneck is still a first-order evidence problem.

## Current Slice In Progress

### Active issue
- `vas-swarm-dy1`

### What landed
- selected probe papers now carry into the merged retrieval corpus before dedupe/rerank/filter
- the selected evidence-plan trace now records `probe.carried_papers`
- targeted tests cover both corpus carryover and trace visibility

### Validation
- Tests:
  - `mix test test/tools/investigate_test.exs` -> `100 tests, 0 failures`
  - `mix test test/investigation/evidence_planner_test.exs` -> pass
  - `mix test test/agent/treasury_alerts_test.exs test/tools/synthesizer_test.exs test/providers/registry_fallback_test.exs test/vault/fact_store_test.exs test/webhooks/dispatcher_test.exs test/channels/http/api/command_palette_test.exs` -> `101 tests, 0 failures`
- Live trace:
  - [vaos-investigate-trace-adafef1959fec23c-vas-swarm-942-live-carryover-1775850306726.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-adafef1959fec23c-vas-swarm-942-live-carryover-1775850306726.json)
- Full suite gate:
  - the earlier unrelated failures were cleared
  - the latest clean rerun is now blocked by late-run verification hang instead of assertion failures
  - `/tmp/vaos-full-3.log` shows no failure entries so far, but `mix test` never reaches `Finished in ...` and stays alive with lingering localhost Ollama and HTTPS connections

## Latest Completed Slice

### Closed issue
- `vas-swarm-s97`

### What landed
- Administration-style performance phrasing like `ingestion/results/outcomes` now routes to `clinical_intervention`
- `randomized_intervention` now adds performance-expanded trial queries when the topic is clearly sport/performance oriented but uses vague words like `results` or `outcomes`

### Validation
- Tests: `117 tests, 0 failures`
- Trace:
  - [vaos-investigate-trace-fe36dcbae502bf57-vas-swarm-s97-live-variant-postfix-1775847290011.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-fe36dcbae502bf57-vas-swarm-s97-live-variant-postfix-1775847290011.json)

### What the trace proved
- `evidence_plan.mode = randomized_intervention`
- probe query upgraded to:
  - `acute caffeine administration cycling time-trial performance cyclists triathletes placebo controlled trial`

## Current Bottleneck

### Active issue
- `vas-swarm-dy1`

### Problem

The direct-trial carryover repair is now in place:
- the latest live rerun stayed on `randomized_intervention`
- the selected probe shows `carried_papers = 1`
- the run ended `asymmetric_evidence_for` with:
  - `grounded_for_count = 1`
  - `grounded_against_count = 0`

That closes the original belief-only collapse, but milestone closure is still blocked at the repo verification layer.

## What Roberto Would Do Next

Hold `vas-swarm-942` until the repo-level verification gate is green:
- the earlier unrelated failures are fixed
- the remaining blocker is a full-suite run that no longer shows assertion failures but still does not terminate cleanly
- once the gate is green, re-run the live trace and decide whether the next bottleneck is thin direct-evidence breadth under source degradation

Shortest version:

`The probe-carryover repair landed, the old unrelated assertion failures were cleared, and milestone closure is now blocked by a full-suite verification hang after the last visible test output.`

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Run `mix osa.roberto.resume`.
3. Open `vas-swarm-dy1` and `/tmp/vaos-full-3.log`.
4. Make `mix test` terminate cleanly again.
5. Re-run `mix test`.
6. Re-open `vas-swarm-942` and re-run the live trace above.
7. If grounding is still thin, open the next retrieval-breadth issue.
8. Update this file, close/open issues, and push.
