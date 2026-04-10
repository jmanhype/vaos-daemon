# Roberto Content Program Status

**Last updated**: 2026-04-10
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-942`
**Latest functional checkpoint before this doc stack**: `b75a63f`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity bug.

## Current State

The program is back on the right route:
- evidence planning is more generic than it was during the topic-family drift
- administration-style intervention phrasing now routes into `randomized_intervention`
- live traces fail more honestly than before

But Roberto is not content yet because the next bottleneck is still a first-order evidence problem.

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
- `vas-swarm-942`

### Problem

The probe finds the right direct-trial lane, but the full retrieval still degrades:
- OpenAlex timed out during the full search
- alphaXiv and HuggingFace results were noisy and heavily filtered
- the run collapsed to two broad caffeine reviews
- final result was `belief_consensus_for` with:
  - `grounded_for_count = 0`
  - `grounded_against_count = 0`

This means the planner is now ahead of the retrieval stack. The next repair is not routing. It is preserving direct-trial corpus quality when a good probe already exists.

## What Roberto Would Do Next

Work `vas-swarm-942`:
- carry strong probe signal deeper into full retrieval
- preserve direct-trial papers when the probe finds them
- stop broad review papers from becoming the whole corpus when the direct-trial query was already good

Shortest version:

`If the probe found the right trial paper family, the full run should not fall back to generic reviews just because one source degraded.`

## Known Stable Wins

- `measurement` claims no longer rely on the earlier broken flat-earth routing path
- `observational` and `randomized_intervention` mode selection survive more paraphrase noise
- advocate runtime now completes honestly under real budgets
- verification and timeout boundaries are much more explicit than they were earlier in the loop

## Resume Checklist

On the next session:

1. Read this file.
2. Open `vas-swarm-942`.
3. Open the trace above.
4. Inspect how probe success is discarded before full retrieval settles.
5. Fix the narrowest generic layer.
6. Re-run live validation.
7. Update this file, close/open issues, and push.
