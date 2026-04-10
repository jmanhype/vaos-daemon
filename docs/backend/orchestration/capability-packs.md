# Capability Packs

Capability Packs are reusable, verified execution assets distilled from successful work. They sit above raw memory and below product packaging: the Orchestrator uses them to execute a known class of work faster, safer, and with less prompt entropy.

The goal is simple: every paid workflow should make the system better at the next similar workflow.

---

## Why They Exist

Daemon already has:

- memory for recall
- an Orchestrator for decomposition and wave execution
- named agents with role-specific prompts
- verification and synthesis phases

What it does not yet have is a durable unit of **reusable operational knowledge**. Raw transcripts, scratchpads, and task results are too noisy. Capability Packs solve that gap by turning verified work into a compact artifact the Orchestrator can route, load, and test.

---

## Definition

A Capability Pack is a versioned bundle that captures:

- the class of problem solved
- the workflow graph that worked
- the minimum context schema required
- the tools, constraints, and verification steps required
- the failure modes and evaluation set

It is **not**:

- a memory dump
- a customer archive
- a transcript log
- a generic prompt template with no evidence

---

## Core Principle

Capability Packs are created **after verification passes**, not before.

That keeps the critical path stable:

```
task accepted
  -> planning
  -> executing
  -> verifying
  -> completed
  -> crystallize reusable capability out-of-band
```

The crystallization step is asynchronous so the Orchestrator does not block task completion on packaging work.

---

## Lifecycle

### 1. Candidate

A task completes successfully and has enough signal to be reusable:

- verification passed
- outputs were material, not trivial
- the work belongs to a repeatable workflow class
- sensitive customer data can be redacted cleanly

The task becomes a **Capability Pack Candidate**.

### 2. Distill

A background crystallizer extracts:

- workflow phases / waves
- files or artifacts that mattered
- structured inputs and outputs
- verification commands
- failure and retry patterns
- reusable prompt fragments

### 3. Redact and Abstract

Client-specific details are removed or normalized:

- names -> roles
- proprietary tables -> schema categories
- raw documents -> source classes
- hard-coded environment details -> compatibility metadata

### 4. Evaluate

The candidate pack is replayed in shadow mode against:

- a golden example
- at least one adversarial or degraded example
- pack-specific verification commands

### 5. Promote

Once replay passes, the pack is promoted from `candidate` to `published`.

### 6. Reuse

Future tasks can match against the pack during planning and either:

- use the pack to constrain decomposition
- instantiate the pack's known workflow directly
- import the pack's evals and runbook into verification

### 7. Revise or Retire

If replay starts failing or the environment changes, the pack is:

- patched with a new version
- demoted to `deprecated`
- or retired entirely

---

## The Capability Pack Contract

Each pack must answer seven questions:

1. What class of work is this for?
2. What minimum context is required?
3. What workflow graph should run?
4. What tools and constraints apply?
5. How do we know it worked?
6. What usually goes wrong?
7. What is safe to reuse across customers?

If a candidate cannot answer all seven, it is not ready to become a pack.

---

## v0 Schema

Suggested on-disk layout:

```text
priv/capability_packs/
  biotech-query-decomposition/
    0.1.0/
      manifest.json
      workflow.json
      context_schema.json
      prompts/
        planner.md
        verifier.md
      evals/
        golden.json
        adversarial.json
      runbook.md
      failure_modes.md
```

### `manifest.json`

```json
{
  "id": "biotech-query-decomposition",
  "version": "0.1.0",
  "status": "candidate",
  "title": "Biotech Query Decomposition",
  "summary": "Decompose large-domain biotech queries into traceable retrieval and reasoning steps.",
  "problem_class": [
    "domain-query-decomposition",
    "regulated-knowledge-retrieval"
  ],
  "owner": "orchestrator",
  "source_tasks": [
    "task_2026_04_01_abc123"
  ],
  "compatibility": {
    "roles": ["lead", "backend", "data", "qa", "services"],
    "tools": ["read", "grep", "shell", "web", "memory"],
    "min_phase": "verifying"
  },
  "promotion": {
    "verification_required": true,
    "human_review_required": true,
    "redaction_complete": true
  },
  "routing_hints": {
    "keywords": ["biotech", "bioactives", "query decomposition", "compound search"],
    "domains": ["life sciences", "regulated knowledge work"],
    "complexity_range": [6, 9]
  }
}
```

### `workflow.json`

Defines the reusable execution graph:

- recommended wave order
- role assignments
- pack-specific constraints
- required predecessor artifacts

The important distinction: this is not a full task plan for one customer. It is a **replayable workflow shape**.

### `context_schema.json`

Defines the minimum viable context required to use the pack:

- source corpus classes
- required metadata fields
- optional enrichments
- forbidden inputs

Example fields:

- `corpus_description`
- `source_types`
- `approved_sources_only`
- `query_taxonomy`
- `output_traceability_level`

### `prompts/`

Only reusable prompt fragments belong here:

- planner prompt
- verifier prompt
- transformation prompt

Do not store raw client transcripts or ad hoc debugging chatter.

### `evals/`

Pack-specific replay cases:

- golden path
- degraded input
- adversarial ambiguity

### `runbook.md`

Human-readable operator notes:

- when to use the pack
- when not to use it
- what to inspect during failures
- escalation rules

### `failure_modes.md`

Known breakpoints and mitigations:

- missing source metadata
- poor query chunking
- citation gaps
- verification command drift

---

## Integration Points

Capability Packs should integrate at four existing seams.

### 1. Planning

After `Complexity.analyze/1` and before `Decomposer.build_execution_waves/1`, the Orchestrator checks a `CapabilityRegistry` for matching packs.

Possible outcomes:

- no match -> normal decomposition
- weak match -> use pack as context only
- strong match -> use pack workflow as the initial execution graph

This preserves current behavior while allowing guided execution when a known workflow exists.

### 2. Goal Dispatch

`GoalDispatch` should be able to inject pack context:

- selected workflow
- pack constraints
- context schema
- prior failure modes

This makes prompts smaller and more stable than reconstructing the same logic from scratch every time.

### 3. Verification

Pack-specific verification augments normal verification:

- required commands
- required assertions
- required traces / citations
- pack-specific eval replay

This is the trust layer. A pack is only useful if it improves confidence, not just speed.

### 4. Learning

When a task reaches `completed`, the Orchestrator emits a new event class for the background crystallizer:

- `:capability_pack_candidate_detected`
- `:capability_pack_promoted`
- `:capability_pack_deprecated`

This keeps pack extraction outside the critical execution loop.

---

## Promotion Gates

No pack should be promoted unless all of the following are true:

- base task verification passed
- no raw secrets or customer-specific sensitive material remain
- workflow can be described independent of one customer
- at least one replay eval passes
- failure modes are documented
- a human or policy gate approves publication

If any gate fails, the pack stays `candidate` or is discarded.

---

## Safety Rules

Capability Packs must never become a covert exfiltration layer.

### Never store

- API keys
- raw customer files
- full meeting transcripts
- prod credentials
- direct database dumps
- person-identifiable internal notes

### Always store

- abstractions
- schemas
- reusable workflow structure
- verification logic
- failure patterns

---

## Edge Cases and Failure Modes

### Overfitting

The pack works for one customer and fails everywhere else.

Mitigation:

- require abstraction fields
- require at least one replay outside the original task artifact set

### Secret Leakage

The pack accidentally contains sensitive source material.

Mitigation:

- mandatory redaction pass
- human or policy promotion gate

### Verification Drift

The pack's test or verification commands become stale.

Mitigation:

- version compatibility metadata
- scheduled replay on published packs

### False Reuse

The registry matches a pack to the wrong task.

Mitigation:

- use confidence thresholds
- keep weak matches advisory only
- allow operator override

### Prompt Bloat

Packs become giant prompt archives instead of compact execution assets.

Mitigation:

- hard size budgets
- separate prompt fragments from runbook prose
- keep only reusable prompt components

---

## Metrics

Capability Packs should be judged on compounding value, not artifact count.

Primary metrics:

- pack reuse rate
- time-to-first-correct-draft reduction
- first-pass verification rate
- replay pass rate
- pack promotion rate

Secondary metrics:

- average prompt size reduction
- average wave count reduction
- incident rate from bad reuse

---

## Recommended v0 Scope

Start with one narrow pack class only:

- a workflow with clear verification
- repeated business value
- low ambiguity around context schema

Good v0 candidates:

- regulated query decomposition
- documentation transformation with traceability
- repo audit and remediation loops
- fixed integration workflows with known provider APIs

Bad v0 candidates:

- open-ended product strategy
- highly creative UX ideation
- one-off rescue debugging with no stable shape

---

## Worked Example

For the biotech wedge:

- **Task class**: decompose a domain query over a large bioactives corpus
- **Reusable elements**:
  - source taxonomy
  - decomposition pattern
  - citation requirements
  - verification checklist
  - ambiguity handling rules
- **Non-reusable elements**:
  - customer names
  - raw datasets
  - internal account context

The pack becomes the reusable operator asset; the customer engagement becomes the source of truth for whether the pack is actually valuable.

---

## Non-Goals for v0

- fully autonomous pack promotion
- cross-pack composition and inheritance
- automatic monetization or packaging logic
- replacing the Orchestrator's existing decomposition path
- treating memory recall as equivalent to capability reuse

v0 should prove one thing only: verified work can become reusable execution structure.

---

## Implementation Sketch

Minimal implementation path:

1. Add a `CapabilityRegistry` that can list and load pack manifests.
2. Add a `CapabilityCrystallizer` background service triggered from task completion events.
3. Add a pack match check in planning before wave construction.
4. Allow `GoalDispatch` to accept optional pack context.
5. Add pack-specific replay in verification.
6. Start with manual promotion and one pack family.

This is intentionally smaller than a new agent framework. It uses Daemon's existing Orchestrator, GoalDispatch, verification, and event bus.

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Agents and Roster](./agents.md)
- [Agent Orchestration & Swarm Guide](../../features/orchestration.md)
