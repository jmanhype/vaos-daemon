# Prompt: Get Roberto Content

**Created**: 2026-04-10
**Epic**: `vas-swarm-jji`

## Objective

Make `investigate` trustworthy and generic enough that Roberto's next objection is not a first-order integrity failure.

In practical terms, this means:
- the planner chooses evidence operations instead of boxing the question into topic hacks
- retrieval stays anchored to direct evidence when the question is empirical
- grounded vs belief separation remains honest
- live runs fail explicitly when sources or providers fail instead of silently drifting

## North Star

`investigate` should evolve from a literature-centered adversarial checker into a durable epistemic engine:
- choose the right evidence operation for the question
- gather evidence from the right source types
- verify support and contradiction with provenance
- return a grounded answer when possible
- return uncertainty honestly when not

## In Scope

- Evidence planning, retrieval, rerank, verification, and evidence-store integrity
- Removal or containment of topic-shaped heuristics
- Durable task memory across sessions
- Live trace validation after every meaningful fix

## Out Of Scope

- Pretending the system is already a universal truth oracle
- Shipping topic-specific hacks without an explicit deletion path
- Declaring success from unit tests alone
- Stopping after a local fix when the next bottleneck is already visible

## Hard Constraints

- Prefer generic evidence-mode fixes over topic-specific patches
- Any new heuristic must either:
  - generalize across a real claim family, or
  - be called out as temporary debt with a follow-up issue
- Every slice must end with:
  - tests
  - a live trace or concrete runtime validation
  - Beads issue updates
  - commit and push
- Evaluation conclusions must match the budget class actually tested
- Reasoning-only evidence must never masquerade as grounded evidence

## Roberto Content Means

Roberto is content when all of the following are true:
- No open first-order integrity bug is known in the empirical `investigate` loop
- Representative claims in the main evidence modes route correctly under paraphrase noise:
  - `measurement`
  - `observational`
  - `randomized_intervention`
- Live traces for those modes produce either:
  - grounded evidence, or
  - an explicit, honest source/provider failure
- The next work item is a second-order improvement, not a trust-breaking repair

## Done When

- `investigate` chooses evidence operations, not topic boxes, across representative empirical claims
- Retrieval keeps a stable direct-evidence core under paraphrase variation
- Grounded evidence contains only direct or legitimately synthesizing support
- Remaining topic-shaped logic is either deleted or isolated with clear debt tracking
- The repo contains enough durable memory that a fresh session can resume the program without reconstructing context from chat
