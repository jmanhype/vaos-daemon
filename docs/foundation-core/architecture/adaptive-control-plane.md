# Adaptive Control Plane Architecture

**Status:** Proposed  
**Scope:** VAOS daemon runtime  
**Applies to:** supervision boundaries, adaptive services, durable adaptation state

## Purpose

VAOS started from OSA's simpler substrate-oriented architecture and has since
grown a real adaptive runtime: research selection, strategy tuning, failure
diagnosis, tool reliability learning, and autonomous background monitoring.

Those additions are valuable and coherent, but they are currently spread across
multiple supervision domains and coordinated mostly through the event bus. This
document defines the target architecture for that adaptive layer.

The goal is not to turn VAOS into a single meta-agent. The goal is to give the
existing adaptive loops an explicit home, clear authority boundaries, and a
durable shared rationale model.

---

## Problem Statement

Current VAOS has several strong adaptive services:

- `ActiveLearner`
- `Retrospector`
- `SelfDiagnosis`
- `DecisionLedger`
- `DecisionJournal`
- `CrashLearner`
- `ProactiveMonitor`
- `ProactiveMode`
- `SkillEvolution`

The current issues are structural, not functional:

1. Core adaptive loops are split across `AgentServices` and `Extensions`.
2. Multiple loops react to the same signals without a clear arbitration point.
3. Durable state exists, but it is fragmented across several stores with no
   single place that records why adaptation decisions were made.
4. OSA's original supervision frame is still visible, but VAOS has outgrown the
   assumptions behind that simpler layout.

---

## Design Goals

The target architecture must optimize for:

- **Scalability**: more adaptive loops can be added without turning the tree
  into a flat service bucket.
- **Maintainability**: ownership boundaries are obvious from the supervision
  tree.
- **Extensibility**: new domain-specific coordinators can be added without
  rewriting the whole control plane.
- **Fault isolation**: one adaptive worker crashing should not restart the
  whole adaptive stack.
- **Auditability**: adaptation decisions must have a durable rationale trail.
- **Future readiness**: the design must support more research loops, more
  runtime monitors, multi-agent coordination, and human-in-the-loop governance.

---

## Proposed Architecture

### Top-Level Rule

Keep the existing four top-level subsystem supervisors:

- `Infrastructure`
- `Sessions`
- `AgentServices`
- `Extensions`

Do **not** add a new top-level supervisor for adaptation. Adaptation is now a
core runtime concern, not an optional extension.

### AgentServices Structure

`AgentServices` should explicitly separate core runtime support from adaptive
control:

```text
Daemon.Supervisors.AgentServices
  CoreRuntime
    Agent.Memory
    Agent.HeartbeatState
    Agent.Tasks
    Budget
    Agent.Orchestrator
    Agent.Progress
    Agent.Hooks
    Agent.Learning
    Knowledge subtree
    Vault.Supervisor
    Agent.Scheduler
    Agent.Compactor
    Agent.Cortex
    Agent.ProactiveMode
    Webhooks.Dispatcher
    Signal.Persistence

  Adaptation
    ActiveLearner
    Retrospector
    SelfDiagnosis
    CrashLearner
    DecisionLedger
    DecisionJournal
    ProactiveMonitor
    SkillEvolution
```

### Extensions Structure

`Extensions` should be reserved for:

- optional subsystems
- externally-dependent features
- dormant or product-surface intelligence
- swarm/fleet/sidecar/sandbox/wallet/updater integrations

Communication intelligence that is not required for the adaptive control plane
can remain here:

- `CommProfiler`
- `CommCoach`
- `ConversationTracker`

---

## Control Model

### Chosen Model: Federated Adaptation

VAOS should use:

- **domain-specific coordinators** for local adaptation
- **thin shared arbitration** for cross-domain conflicts

This means:

- research adaptation remains local to the research lane
- reliability adaptation remains local to the runtime reliability lane
- a thin control layer decides which lane currently has authority when signals
  conflict

### Domains

#### Research Domain

Primary responsibilities:

- topic selection
- chained investigations
- prompt evolution
- strategy tuning
- synthesis and gap discovery

Primary modules:

- `ActiveLearner`
- `Retrospector`
- `PromptSelector`
- `Investigate`

#### Reliability Domain

Primary responsibilities:

- tool reliability learning
- recurring failure escalation
- diagnosis and corrective-action proposals
- proactive runtime alerts

Primary modules:

- `DecisionLedger`
- `SelfDiagnosis`
- `CrashLearner`
- `ProactiveMonitor`
- `ProactiveMode`

#### Coordination Domain

Primary responsibilities:

- conflict detection for autonomous actions
- provenance
- reward routing
- tracking in-flight decisions

Primary module:

- `DecisionJournal`

### Thin Arbitration Layer

Do **not** build an all-powerful meta-agent.

If a shared arbiter is added, it should only answer:

- which domain currently has adaptation authority
- whether an experiment is already in progress
- whether a pivot should be suppressed, delayed, or promoted
- whether the system is currently optimizing for quality, reliability, or flow

It should **not** directly own:

- paper search tactics
- tool reliability scoring
- prompt generation
- diagnosis generation
- strategy parameter math

Those belong to the domain-specific workers.

---

## Durable State Model

### Decision

Use **append-only durable journals plus derived snapshots**, not one giant
shared store.

### Sources of Truth

- `DecisionLedger`: tool/runtime reliability observations
- knowledge graph: semantic facts, evidence, and investigation outputs
- prompt/strategy stores: local domain-specific optimization state
- `DecisionJournal`: cross-module decision provenance and in-flight conflict
  state

### New Shared Adaptation State

Extend the current journal model into an **adaptation journal**.

This journal should record:

- active bottleneck
- pivot reason
- failed adaptation attempts
- active steering hypothesis
- experiment start/stop
- which domain currently has authority
- cross-domain suppression decisions

From that journal, derive a lightweight `MetaState` snapshot for fast reads.

### Snapshot Rules

`MetaState` is:

- cached
- replaceable
- reconstructable from the journal

`MetaState` is **not** the source of truth.

This avoids state drift and keeps the system auditable.

---

## Key Decisions

### D1. Adaptation is Core, Not Optional

**Decision:** place the adaptive control plane under `AgentServices`, not
`Extensions`.

**Why:** these services are now part of VAOS's core behavior, not optional
product extras.

### D2. Keep Workers Separate

**Decision:** do not collapse adaptive services into one monolithic process.

**Why:** each service has a different cadence, failure mode, and state shape.
Separate workers preserve OTP fault isolation and local reasoning.

### D3. Prefer Domain Coordinators Over a God Coordinator

**Decision:** keep research and reliability adaptation local, add only thin
arbitration for conflicts.

**Why:** this matches VAOS's current organic structure and avoids replacing a
distributed adaptive system with a fragile central brain.

### D4. Use Journals, Not a Giant Shared Database

**Decision:** preserve specialized stores and add an adaptation journal for
cross-domain rationale.

**Why:** the current stores already have clear semantics. The missing piece is
shared rationale, not another universal state backend.

### D5. `DecisionJournal` Becomes the Spine

**Decision:** evolve `DecisionJournal` into the cross-domain adaptation spine.

**Why:** it already owns provenance, conflict detection, and autonomous action
tracking. Extending it is lower risk than creating a parallel governance system.

---

## Alternatives Evaluated

### Option A: Leave the Current Structure As-Is

**Pros**

- zero churn
- no migration risk
- preserves current behavior exactly

**Cons**

- supervision tree does not reflect actual ownership
- cross-domain adaptation remains implicit
- future adaptive additions will further blur boundaries

**Verdict:** rejected

### Option B: Flatten Everything Into AgentServices

**Pros**

- easy to implement
- superficially resembles OSA's simpler structure

**Cons**

- hides subsystem ownership
- recreates a broad service bucket
- makes future growth harder to reason about

**Verdict:** rejected

### Option C: One Unified Adaptation Coordinator

**Pros**

- one explicit place for control logic
- easy to explain conceptually

**Cons**

- high risk of god-object growth
- weaker fault isolation
- harder to evolve safely
- likely to absorb domain logic that should stay local

**Verdict:** rejected

### Option D: Federated Domain Coordinators + Thin Arbitration

**Pros**

- preserves working local loops
- makes ownership explicit
- scales to more adaptive domains
- keeps coordination bounded

**Cons**

- slightly more architectural complexity
- requires a durable rationale model to stay coherent

**Verdict:** chosen

---

## Scalability and Future Requirements

This architecture is designed to support:

- more adaptive domains beyond research and reliability
- multiple proactive monitors
- multi-agent adaptation and negotiation
- team-level or tenant-level adaptation authority
- explicit governance hooks for human approvals
- future VSM-style `S4` observability without central monolithization

Likely future additions:

- an explicit `AdaptationCoordinator`
- a derived `MetaState`
- team-scoped or tenant-scoped adaptation snapshots
- richer algedonic escalation routes

---

## Recommended Implementation Sequence

1. Create `Daemon.Supervisors.Adaptation` under `AgentServices`.
2. Move the adaptive workers into that subtree.
3. Move `ProactiveMonitor` out of the optional communication-intelligence lane.
4. Extend `DecisionJournal` into an adaptation journal.
5. Add a thin arbitration layer only after journal semantics are stable.

This sequence separates **ownership cleanup** from **control-plane evolution**.

---

## Summary

VAOS should not revert to OSA's simpler broad colocation model.

The right forward move is:

- **core adaptive ownership under `AgentServices`**
- **separate domain-specific adaptive workers**
- **an adaptation journal as shared durable rationale**
- **thin arbitration instead of a god-meta-agent**

In short:

**VAOS should become a federated adaptive control plane, not a flat service
bucket and not a single all-powerful coordinator.**
