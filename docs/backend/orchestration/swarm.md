# Swarm Mode

Swarm mode is a higher-level coordination layer for multi-agent work. Where the Orchestrator uses dependency-wave execution for sequential/parallel task decomposition, swarms apply explicit coordination patterns (parallel, pipeline, debate, review) and enable inter-agent communication through a shared mailbox.

---

## Overview

```
SwarmMode.launch/2
    │
    ▼
SwarmPlanner.decompose/2  →  LLM produces plan: pattern + agents + strategy
    │
    ▼
DynamicSupervisor starts SwarmWorker per agent
    │
    ▼
Mailbox.create/1  →  ETS partition for inter-agent messages
    │
    ▼
Patterns.parallel | pipeline | debate | review_loop
    │
    ▼
SwarmMode synthesises all agent results  →  {:ok, swarm_id}
```

`SwarmMode` is a GenServer (`Daemon.Agent.Orchestrator.SwarmMode`) with limits:
- Maximum 10 concurrent swarms
- Maximum 5 agents per swarm (configurable via `:max_agents`)
- Default timeout 5 minutes per swarm

---

## Swarm Lifecycle

```
:running → :synthesizing → :completed
         ↓
       :failed | :cancelled | :timeout
```

All state transitions emit events on the event bus:

| Event | Trigger |
|-------|---------|
| `:swarm_started` | Launch accepted |
| `:swarm_completed` | Synthesis finished |
| `:swarm_failed` | Pattern execution crashed |
| `:swarm_cancelled` | Explicit cancel call |
| `:swarm_timeout` | Timeout elapsed |

---

## SwarmPlanner

`SwarmPlanner` uses an LLM call to produce a structured execution plan. It never fails silently — if the LLM is unavailable or returns bad JSON, it falls back to a safe two-agent parallel plan (researcher + writer).

### Plan structure

```elixir
%{
  pattern: :parallel | :pipeline | :debate | :review,
  agents: [
    %{role: :researcher, task: "Research the best approaches for X"},
    %{role: :coder, task: "Implement the chosen approach"},
    %{role: :reviewer, task: "Review the implementation"}
  ],
  synthesis_strategy: :merge | :vote | :chain,
  rationale: "Short explanation of why this plan fits the task"
}
```

### Pattern selection

The LLM selects the pattern based on task characteristics:

| Pattern | Best for | Synthesis |
|---------|---------|-----------|
| `parallel` | Independent aspects (research + implement + review) | `:merge` |
| `pipeline` | Sequential refinement (research → implement → polish) | `:chain` |
| `debate` | Design decisions (multiple proposals → critic selects best) | `:vote` |
| `review` | Quality assurance (worker produces → reviewer approves/rejects) | `:chain` |

### Validation

The planner validates every field before accepting the plan:
- `pattern` must be one of the four valid atoms
- `agents` must be a non-empty list; each entry needs valid `role` and non-empty `task`
- `synthesis_strategy` must match the pattern (default applied when missing)
- Invalid agent specs are skipped with a warning; if all are invalid, the plan fails

---

## Execution Patterns

### Parallel (`Patterns.parallel/3`)

All agents work independently on their assigned sub-task. Uses `Task.async_stream` with `max_concurrency` equal to the agent count. Results are collected in agent order.

```
Agent A ──────────────────→ result_A
Agent B ──────────────────→ result_B  →  synthesize
Agent C ──────────────────→ result_C
```

### Pipeline (`Patterns.pipeline/3`)

Agents execute sequentially. Each agent receives the previous agent's output prepended to its task, enabling iterative refinement.

```
Agent A → result_A → Agent B (with result_A) → result_B → Agent C (with result_B) → result_C
```

If an agent fails, `nil` is propagated so the next agent receives no context from the failed step.

### Debate (`Patterns.debate/3`)

The first N-1 agents work in parallel as proposers. The last agent acts as the critic/evaluator and receives all proposals. The critic's output is the final result.

```
Agent A ──────┐
Agent B ──────┼→ proposals → Evaluator (last agent) → final answer
Agent C ──────┘
```

Falls back to parallel execution if fewer than 2 agents are provided.

### Review Loop (`Patterns.review_loop/4`)

A two-agent loop: worker produces or revises, reviewer critiques. Iterates up to `max_iterations` (default: 3) or until the reviewer approves.

```
Worker → output → Reviewer → "APPROVED: ..." → done
                           → feedback → Worker (revised) → Reviewer → ...
```

Approval signal: the reviewer's response starts with `APPROVED` (case-insensitive). At max iterations, the last worker output is returned with a note that iterations were exhausted.

---

## SwarmWorker

Each `SwarmWorker` is a `GenServer` with `restart: :temporary` — it exits after completing its assigned task and is never restarted by the supervisor.

Lifecycle:
1. Started by `DynamicSupervisor` under `SwarmMode.AgentPool`
2. Receives `assign/2` call with the task description
3. Calls LLM with: role system prompt + mailbox context + task
4. Posts result to the swarm Mailbox
5. Returns `{:ok, result_text}` or `{:error, reason}` to caller
6. Exits normally

Model selection is tier-aware: `lead` and `architect` roles use `:elite`; most roles use `:specialist`; `design` and `writer` use `:utility`.

---

## Mailbox

The Mailbox is the shared communication channel for swarm agents. It uses ETS for lock-free concurrent reads. The GenServer only coordinates table creation; all reads go directly to ETS.

### Message schema

```
{swarm_id, seq, from_agent_id, message, posted_at_ms}
```

`seq` is a monotonically-increasing integer per swarm using `:ets.update_counter` for atomic increments.

### API

```elixir
Mailbox.create(swarm_id)                    # initialize ETS partition
Mailbox.post(swarm_id, agent_id, message)  # post a message (atomic seq increment)
Mailbox.read_all(swarm_id)                 # all messages, sorted by seq
Mailbox.read_from(swarm_id, agent_id)      # messages from specific agent
Mailbox.build_context(swarm_id)            # formatted string for LLM injection
Mailbox.clear(swarm_id)                    # cleanup on completion/cancellation
```

`build_context/1` returns a formatted block injected into every worker's system prompt so agents can see what peers have produced:

```
## Swarm Mailbox (peer messages)
[agent_id_1]: (output from agent 1)
[agent_id_2]: (output from agent 2)
```

---

## Synthesis

After all pattern agents complete, `SwarmMode` fires an async `Task` to call the LLM for synthesis. The synthesis prompt asks to combine the best elements, eliminate redundancy, resolve contradictions, and produce a final answer without mentioning the swarm structure.

Falls back to joining agent outputs with `---` separators if the LLM call fails.

---

## PACT Framework

`Negotiation` implements the PACT (Planning, Action, Coordination, Testing) workflow — a four-phase structured execution with quality gates between phases.

### Phases

| Phase | Role | Quality gate criteria |
|-------|------|----------------------|
| Planning | `:planner` | Subtasks identified, roles assigned |
| Action | Multiple parallel | At least one agent succeeded |
| Coordination | `:lead` | Conflicts resolved, output synthesized |
| Testing | `:tester` | Quality score above threshold (`QUALITY_SCORE: 0.85` parsed from output) |

### Quality gates

Each gate computes a score 0.0–1.0. If the score falls below `quality_threshold` (default: 0.7), the gate fails. With `rollback_on_failure: true`, the Mailbox is cleared and a `pact_rollback` event is emitted.

```elixir
{:ok, result} = Negotiation.execute_pact("Build a REST API", [
  quality_threshold: 0.7,
  timeout_ms: 300_000,
  max_action_agents: 5
])
```

---

## Named Pattern Configurations

`Patterns.list_patterns/0` returns named patterns loaded from `priv/swarms/patterns.json`:

| Pattern name | Description |
|-------------|-------------|
| `code-analysis` | Comprehensive code analysis |
| `full-stack` | Full-stack feature implementation |
| `debug-swarm` | Multi-agent debugging |
| `performance-audit` | Performance profiling and recommendations |
| `security-audit` | OWASP-based security review |
| `documentation` | Documentation generation |
| `adaptive-debug` | Adaptive debugging with self-correction |
| `adaptive-feature` | Adaptive feature development |
| `concurrent-migration` | Parallel migration execution |
| `ai-pipeline` | AI/ML pipeline orchestration |

```elixir
{:ok, config} = Patterns.get_pattern("code-analysis")
# config["agents"] => ["@security-auditor", "@code-reviewer", "@test-automator"]
# config["mode"]   => "parallel"
```

---

## Public API

```elixir
# Launch a swarm
{:ok, swarm_id} = SwarmMode.launch(task, [
  pattern: :parallel,       # optional override
  timeout_ms: 300_000,
  max_agents: 5,
  session_id: session_id
])

# Poll status
{:ok, status} = SwarmMode.status(swarm_id)

# Cancel
:ok = SwarmMode.cancel(swarm_id)

# List all
{:ok, swarms} = SwarmMode.list_swarms()
```

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Agents and Roster](./agents.md)
- [Delegation](./delegation.md)
