# Orchestrator

The Orchestrator is the autonomous task decomposition and multi-agent execution engine. It transforms complex user requests into coordinated parallel work by analyzing complexity, decomposing tasks into sub-tasks, spawning specialized agents per wave, and synthesizing their results.

---

## Overview

When a task arrives, the Orchestrator decides in real-time whether to run it as a single agent or decompose it into a team. It is a GenServer (`Daemon.Agent.Orchestrator`) that holds all active task state and drives execution through `handle_continue` callbacks — keeping the GenServer non-blocking while agents run in `Task.async` processes.

```
User request
    │
    ▼
Complexity.quick_score/1  →  score ≥ 7? → Ask clarifying questions
    │
    ▼
Decomposer.decompose_task/2  →  LLM produces sub-tasks as JSON
    │
    ▼
ComplexityScaler.optimal_agent_count/3  →  cap agent count to tier/budget
    │
    ▼
Decomposer.build_execution_waves/1  →  group by dependency order
    │
    ▼
WaveExecutor runs wave N in parallel, waits for all to complete,
then starts wave N+1 (via handle_info + handle_continue)
    │
    ▼
WaveExecutor.synthesize_results/4  →  LLM produces unified response
```

---

## Complexity Analysis

### Quick Score (`Complexity.quick_score/1`)

A heuristic pass with no LLM call. Returns an integer 1–10 used to gate clarifying questions.

| Signal | Points |
|--------|--------|
| Word count > 200 | 4 |
| Word count > 100 | 3 |
| Cross-domain keywords (frontend, backend, database, etc.) | 0–4 |
| Multi-step markers (first/then/finally) | 0–3 |
| Complexity words (comprehensive, overhaul, migration) | 0–4 |

Scores ≥ 7 trigger a user survey via `Loop.ask_user_question/4` before decomposition.

### Full Analysis (`Complexity.analyze/1`)

An LLM call that returns either `{:simple, score}` or `{:complex, score, [SubTask.t()]}`. The prompt instructs the model to respond with structured JSON describing the complexity and all sub-tasks.

The nine agent roles available in decomposition:

| Role | Purpose |
|------|---------|
| `lead` | Orchestrator/synthesizer, merges results |
| `backend` | Server-side APIs, handlers, business logic |
| `frontend` | Components, pages, state, styling |
| `data` | Schemas, migrations, queries |
| `design` | Design specs, tokens, accessibility |
| `infra` | Dockerfiles, CI/CD, deployment |
| `qa` | Tests — unit, integration, e2e |
| `red_team` | Adversarial review, security findings |
| `services` | External integrations, workers, AI/ML |

### Quick Check (`Complexity.quick_check/1`)

Returns `:likely_simple` or `:possibly_complex` based on length and multi-task patterns. Used as a pre-filter to avoid unnecessary LLM calls.

---

## Task Decomposition

`Decomposer.decompose_task/2` calls `Complexity.analyze/1` and packages results into a `{:ok, [SubTask.t()], meta}` tuple. Each `SubTask` carries:

```elixir
%SubTask{
  name: "api_handlers",          # snake_case identifier
  description: "Add pagination…",
  role: :backend,
  tools_needed: ["file_read", "file_write"],
  depends_on: ["schema_design"],  # empty = can run in wave 1
  context: nil                    # filled at runtime with prior wave results
}
```

`Decomposer.build_execution_waves/1` groups sub-tasks by dependency order. Tasks with no dependencies run in wave 1, tasks depending only on wave-1 tasks run in wave 2, and so on. This produces the layered parallel schedule.

---

## Wave Execution

The GenServer drives wave execution through a `handle_continue` chain — no blocking calls in GenServer callbacks.

### Phase sequence

```
handle_call :execute
  → {:reply, {:ok, task_id}, state, {:continue, {:start_execution, task_id}}}

handle_continue :start_execution
  → build waves, → {:continue, {:execute_wave, task_id}}

handle_continue :execute_wave  (per wave)
  → AgentRunner.spawn_agent per sub-task (returns Task.async ref)
  → store refs in wave_refs map
  → {:noreply, state}

handle_info {ref, result}  (per agent completion)
  → WaveExecutor.record_agent_result
  → if wave_refs empty: {:continue, {:execute_wave, task_id}}  ← next wave
                   else: {:noreply, state}

handle_continue :synthesize
  → WaveExecutor.synthesize_results
  → task marked :completed
```

### Wave refs

Each spawned `Task.async` ref is stored in `task_state.wave_refs` as:
```elixir
%{task_ref => {agent_name, agent_id, subtask_id}}
```

When the `handle_info {ref, result}` message arrives, the Orchestrator looks up the ref to identify the agent, records its result, and removes the ref. An empty `wave_refs` map means the wave is complete.

### Crash handling

`:DOWN` messages from crashed agent tasks are handled alongside normal completion. A crashed agent is recorded as `FAILED: Agent crashed: <reason>` and the wave proceeds. The synthesis step receives all results — successful and failed — and produces a status of `PARTIAL` or `FAILED` accordingly.

---

## State Machine

Each task has an associated `StateMachine.t()` that enforces the task lifecycle:

```
idle → planning → executing → verifying → completed
                    ↘                  ↘
                  error_recovery ←──────┘
```

### Phases and tool permissions

| Phase | Permission tier | Allowed tools |
|-------|----------------|--------------|
| `idle` | `:none` | None |
| `planning` | `:read_only` | grep, read, glob |
| `executing` | `:full` | All tools |
| `verifying` | `:read_and_test` | Read + test commands |
| `error_recovery` | `:read_only` | grep, read, glob |
| `completed` | `:none` | None |

### Events

| Event | Transition |
|-------|-----------|
| `:start_planning` | idle → planning |
| `:approve_plan` | planning → executing |
| `:reject_plan` | planning → idle |
| `:waves_complete` | executing → verifying |
| `:wave_failure` | executing → error_recovery |
| `:verification_passed` | verifying → completed |
| `:verification_failed` | verifying → error_recovery |
| `:replan` | error_recovery → planning |
| `:manual_override` | error_recovery → completed |

The state machine is a pure functional module — zero side effects. All transitions return `{:ok, new_state}` or `{:error, :invalid_transition}`. The Orchestrator GenServer applies transitions with `update_machine/3`, which is best-effort (invalid transitions are silently ignored to prevent crashes from state machine edge cases).

---

## Goal Dispatch

`GoalDispatch` builds structured prompt packets for agents using Pattern #4: pass WHAT to achieve plus context; let the agent's system prompt handle HOW.

```elixir
goal = GoalDispatch.build_goal(:backend, "Add pagination to /api/users", %{
  files: ["lib/api/users.ex"],
  constraints: ["must be backward-compatible"],
  prior_results: %{"explorer" => "Found 3 list endpoints without pagination"}
})

prompt = GoalDispatch.dispatch(goal, agent_config)
```

The resulting prompt contains:
- `## Goal` — role + objective
- `## Context` — relevant files and prior agent results
- `## Available Tools` — tool names
- `## Constraints` — constraint list
- `## Execution` — agent name and tier

`GoalDispatch.merge_results/1` collapses a list of agent results into a `{status, synthesis, succeeded, failed}` map.

---

## Result Synthesis

`WaveExecutor.synthesize_results/4` uses an LLM call at temperature 0.3 to produce a unified response from all agent outputs. The prompt asks for:

1. A summary of what was accomplished
2. Files created or modified
3. Any issues or follow-up items
4. A final status: COMPLETE, PARTIAL, or FAILED

If the LLM call fails, it falls back to joining all results with `---` separators.

---

## Event Bus Emissions

The Orchestrator emits events at every lifecycle step. Subscribers (TUI, HTTP SSE, platform) receive:

| Event | When |
|-------|------|
| `:orchestrator_task_started` | Task accepted |
| `:orchestrator_task_decomposed` | Sub-tasks generated |
| `:orchestrator_task_appraised` | Cost and hours estimated |
| `:orchestrator_agents_spawning` | About to spawn agents |
| `:orchestrator_wave_started` | Wave N beginning |
| `:orchestrator_agent_started` | Single agent spawned |
| `:orchestrator_agent_progress` | Tool use or token update |
| `:orchestrator_agent_completed` | Agent finished |
| `:orchestrator_synthesizing` | About to synthesize |
| `:orchestrator_task_completed` | Task done |
| `:orchestrator_task_failed` | Decomposition failed |

---

## Public API

```elixir
# Start a task — returns immediately with task_id
{:ok, task_id} = Orchestrator.execute("Build a REST API with auth", session_id)

# Poll progress
{:ok, progress} = Orchestrator.progress(task_id)
# progress.agents — list of agent statuses with tool_uses, tokens_used

# List all tasks
tasks = Orchestrator.list_tasks()

# Dynamic skill management
{:ok, name} = Orchestrator.create_skill("name", "desc", "instructions", ["file_read"])
{:existing_matches, matches} | {:created, name} = Orchestrator.suggest_or_create_skill(...)
{:matches, matches} | :no_matches = Orchestrator.find_matching_skills("task description")
```

---

## See Also

- [Agents and Roster](./agents.md)
- [Swarm Mode](./swarm.md)
- [Delegation](./delegation.md)
- [Capability Packs](./capability-packs.md)
