# ADR-001: Structural Pattern Improvements
## Status: Implemented (Decisions 1, 2, 4, 5, 6) / Proposed (Decision 3)
## Date: 2026-03-06
## Updated: 2026-03-08

## Context

A systematic architecture review identified six structural gaps in OSA's codebase.
These improvements are based on established OTP/Elixir patterns: agent/runtime separation,
CloudEvents envelopes, NimbleOptions validation, ETS-based concurrent dispatch, and
supervisor topology best practices.

OSA's model: monolith OTP, opinionated product, Signal Theory quality framework, 22+ agents,
wave execution, SICA learning loop, goldrush event routing.

Six architectural gaps were identified. This ADR documents the decisions for each.

---

## Decisions

### Decision 1: Hooks — Move from GenServer serialization to ETS + in-process execution

**Status: Implemented**

**Context:** `Agent.Hooks` is a single named GenServer. All hook executions for all concurrent
sessions serialize through one process. Under load (multiple concurrent sessions), hook execution
for one session blocks all others.

**Decision:** Keep the GenServer only for hook registration. At registration, write entries
to a named ETS table (`:osa_hooks`, `{event, priority, name, handler_fn}`). Execution reads from
ETS and runs in the caller's process — zero serialization.

**Consequences:**
- Positive: O(1) concurrent scaling — hook execution cost is per-session, not global
- Positive: Mirrors how Plug pipelines work (static definition, per-request execution)
- Negative: Hook handler functions must be pure / process-safe (no GenServer calls that could deadlock)
- Neutral: `run_async/2` becomes a simple `Task.async` call instead of a GenServer cast

---

### Decision 2: Tool Schema Validation at Registry Boundary

**Status: Implemented**

**Context:** Tools receive raw JSON maps from LLM tool calls. Each tool implements its own
argument checking inconsistently. LLM hallucinations in tool arguments fail cryptically
inside tool implementations.

**Decision:** Require every tool module to declare an `@schema` NimbleOptions spec. `Tools.Registry`
validates params before dispatch. On validation failure, return a structured error to the LLM
(not an exception) so the LLM can self-correct.

```elixir
# Every tool module declares:
@schema [
  path: [type: :string, required: true],
  encoding: [type: {:in, [:utf8, :binary]}, default: :utf8]
]

# Registry validates before dispatch:
with {:ok, validated} <- NimbleOptions.validate(params, module.schema()) do
  module.run(validated, opts)
end
```

**Consequences:**
- Positive: Eliminates cryptic runtime errors from LLM arg hallucinations
- Positive: Schema doubles as documentation — `/help tool_name` can auto-generate from schema
- Positive: `pre_tool_use` hooks get validated params, not raw JSON
- Negative: All existing tool modules need a `@schema` attribute added (one-time migration)

---

### Decision 3: Per-Session DynamicSupervisor for Crash Recovery

**Status: Proposed — requires explicit approval before implementation**

**Context:** When `Agent.Loop` crashes mid-reasoning, it restarts under `SessionRegistry` from
scratch. Conversation context, tool results, and partial reasoning are lost. Users see a
silent reset.

**Decision:** Move session `Agent.Loop` processes under a dedicated `DynamicSupervisor`
(`OSA.Sessions.Supervisor`) with `:transient` restart strategy and `max_restarts: 3, max_seconds: 30`.
On restart, `Loop.init/1` reads the last checkpoint from `Agent.Memory` and resumes from the
last persisted message boundary.

Checkpoint protocol: `Agent.Memory` writes a checkpoint after each complete user-assistant turn
(not mid-tool-call). On restart, the loop restores messages up to the last checkpoint.

**Consequences:**
- Positive: Crash-tolerant conversations — users do not lose context on transient failures
- Positive: Aligns with OTP "let it crash, recover" philosophy
- Negative: Requires `Agent.Memory` checkpoint writes on every turn (small latency addition ~5-10ms)
- Negative: More complex `init/1` logic (conditional checkpoint restore)
- Neutral: `:transient` means only crash restarts; clean exits (session end) do not restart

---

### Decision 4: OSA.Signal Struct with CloudEvents-Compatible Envelope

**Status: Implemented**

**Context:** `Events.Bus` events are proplist-based, unstructured, and have no identity (no id,
no timestamp at emission). Events cannot be journaled, replayed, or traced across agent boundaries.
CloudEvents v1.0.2 is the industry standard for event envelopes.

**Decision:** Created `OptimalSystemAgent.Signal` struct that merges CloudEvents v1.0.2
fields with Signal Theory quality metadata as extensions. Goldrush continues routing on the
`:type` field — the performance benefit is preserved.

Key fields: `id`, `source`, `type`, `time`, `data`, `session_id`, `agent_id`, `parent_id`,
`signal_mode`, `signal_genre`, `signal_sn_ratio`.

**Consequences:**
- Positive: Every event has a UUID — enables dedup, replay, and audit log
- Positive: Parent-child event chains are traceable across agent boundaries
- Positive: Signal Theory metadata travels with every event (mode, genre, S/N)
- Positive: Interoperability path with CloudEvents-compatible tooling (OTel, etc.)

---

### Decision 5: Agent Behaviour Module Separation (Definition vs Runtime)

**Status: Implemented**

**Context:** Agent definitions were static maps in Roster. Loop was both definition and runtime.

**Decision:** Created `AgentBehaviour` with metadata callbacks (name, tier, role, system_prompt)
plus optional `handle/2`, `before_handle/2`, `after_handle/2` for pure agent logic.
Created `Directive` protocol for typed returns (Emit, Spawn, Schedule, Stop, Delegate, Batch).
25 agent modules exist in `lib/agents/`. Roster builds from module callbacks at compile time.

**Consequences:**
- Positive: Each agent module is independently testable
- Positive: Typed directives separate agent intent from runtime execution
- Positive: Backward compatible — `@optional_callbacks` means existing agents work unchanged

---

### Decision 6: Swarm Worker Backpressure

**Status: Implemented**

**Context:** `Swarm.Supervisor` uses `DynamicSupervisor` with no `max_children` limit.
Under a large swarm, OSA can spawn arbitrarily many concurrent LLM-calling workers.

**Decision:** Add `max_children: 10` to the swarm's `DynamicSupervisor` spec (matching the
existing 10-agent cap in `Agent.Orchestrator`). When the limit is reached, excess swarm tasks
wait in `Agent.TaskQueue` until a worker slot opens.

**Consequences:**
- Positive: Prevents resource exhaustion under pathological swarm configs
- Positive: Consistent with documented 10-agent-cap invariant
- Negative: Large swarms queue rather than fail immediately (expected behavior)

---

## What OSA Does NOT Need

| Pattern | Reasoning |
|---|---|
| External agent SDK dependency | OSA is a product, not an SDK. External coupling to third-party release cadence is wrong. |
| DAG workflow engine | Wave execution is simpler and opinionated — the right tradeoff for OSA's use case. |
| Behavior trees | Current SICA learning + roster dispatch is sufficient scope. |
| Harness/adapter pattern | OSA IS the CLI agent. Wrapping other CLIs is N/A. |
| LiveView studio | Rust TUI is the correct UI layer. Web dashboard is out of scope. |
| Evolutionary optimization | SICA learning engine covers this scope sufficiently. |
| Multi-node clustering | Future need (MIOSA multi-tenant deployment), not current. |

## Signal Theory vs CloudEvents — Clarification

These are orthogonal:

- **CloudEvents**: A data envelope format (v1.0.2 struct with routing and dispatch)
- **Signal Theory**: A communication quality framework (S/N optimization via Shannon/Ashby/Beer/Wiener)

The merged approach: `OSA.Signal` uses CloudEvents-compatible envelope fields while carrying
Signal Theory quality metadata (mode, genre, S/N) as extensions. Neither is compromised.

## Implementation Sequence

```
Phase 1 (completed):
  1. Decision 6 — Swarm backpressure
  2. Decision 1 — Hooks ETS refactor
  3. Decision 2 — Tool schema validation
  4. Decision 4 — OSA.Signal struct
  5. Decision 5 — Agent Behaviour + Directive protocol

Phase 2 (pending approval):
  6. Decision 3 — Per-session supervision (architecture topology change)
```

## References

- God-file refactor plan: `tasks/god-file-refactor-plan.md`
- Signal Theory: `docs/architecture/signal-theory.md`
- OSA Agent v3.3: `~/.claude/CLAUDE.md`
- Related: `lib/optimal_system_agent/agent/hooks.ex`, `agent/loop.ex`, `swarm/worker.ex`,
  `agent/orchestrator/wave_executor.ex`, `events/bus.ex`
