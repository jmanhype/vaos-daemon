# Agents and Roster

Daemon maintains a roster of named specialist agents. Each agent has an identity, a tier (model class), and a system prompt stored as a Markdown definition file. The Orchestrator uses multi-factor scoring to select the best agent for each sub-task.

---

## The Roster

`Daemon.Agent.Roster` builds the agent map at runtime from module callbacks, not compile-time. The roster supports:

- `Roster.get/1` — retrieve agent metadata by name
- `Roster.select_for_task_scored/1` — rank all agents against a task description, returns `[{name, score}]`
- `Roster.load_definition/1` — load the full `.md` prompt from `priv/agents/<name>.md`
- `Roster.role_prompt/1` — get the default system prompt for a role atom
- `Roster.max_agents/0` — configured maximum concurrent agents
- `Roster.valid_roles/0` — list of valid role atoms

Agent definitions live in `priv/agents/<name>.md`. Each file contains the agent's identity, domain expertise, approach, and quality standards. These are loaded at runtime when a high-confidence match is found.

---

## Agent Tiers

Daemon uses three tiers that map to model classes:

| Tier | Purpose | Model class |
|------|---------|------------|
| `:elite` | Architecture, orchestration, critical decisions | Highest capability (e.g., Opus) |
| `:specialist` | Domain work — most agents | Balanced (e.g., Sonnet) |
| `:utility` | Simple tasks, fast lookup | Fast/cheap (e.g., Haiku) |

Tier controls:
- Model selected via `Tier.model_for/2`
- Temperature via `Tier.temperature/1`
- Max iterations via `Tier.max_iterations/1`
- Max response tokens via `Tier.max_response_tokens/1`
- Total token budget via `Tier.total_budget/1`

---

## Nine Decomposition Roles

These roles are used during task decomposition (assigned by the LLM) and map to default tiers:

| Role | Default tier | Purpose |
|------|-------------|---------|
| `:lead` | `:elite` | Orchestrator, synthesizer, merge and ship decisions |
| `:backend` | `:specialist` | Server-side code, APIs, handlers, business logic |
| `:frontend` | `:specialist` | Components, pages, state, styling |
| `:data` | `:specialist` | Schemas, migrations, models, queries |
| `:design` | `:specialist` | Design specs, tokens, accessibility |
| `:infra` | `:specialist` | Dockerfiles, CI/CD, build systems |
| `:qa` | `:specialist` | Tests, test infrastructure, security audit |
| `:red_team` | `:specialist` | Adversarial review, security vulnerabilities |
| `:services` | `:specialist` | External integrations, workers, AI/ML |

Legacy aliases (`researcher` → `:data`, `builder` → `:backend`, `tester` → `:qa`, `reviewer` → `:red_team`, `writer` → `:lead`) are accepted in LLM responses for backward compatibility.

---

## Agent Selection — Three Confidence Tiers

`AgentRunner.build_agent_prompt/1` uses `Roster.select_for_task_scored/1` to score every named agent against the sub-task description and selects the prompt strategy based on confidence:

### High confidence (score ≥ 4.0)

The named agent's full `.md` definition leads the prompt. The agent's expertise drives the response. Task description is injected as context.

```
Named agent prompt (full .md)
├── ## Your Specific Task
├── ## Dependencies
├── ## Context from Previous Agents
├── ## Available Tools
├── ## Active Skills
├── ## Environment
└── ## Execution Parameters (agent, tier, max_iterations, token budget)
```

### Medium confidence (2.0–3.9)

A blended prompt: dynamic task framing leads, named agent expertise is injected as a reference block (truncated to ~2000 chars). Task focus is primary; domain knowledge informs approach.

### Low confidence (< 2.0)

Pure dynamic prompt optimized for the exact sub-task. No named agent involved — they would add noise rather than signal.

---

## AgentBehaviour Contract

All named agents and dynamically spawned agents implement `MiosaTools.Behaviour`. The Roster's named agents additionally implement the agent contract providing:

- `name/0` — unique string identifier
- `description/0` — one-line purpose statement
- `tier/0` — `:elite | :specialist | :utility`
- `prompt/0` — base system prompt
- Domain-specific metadata for scoring

---

## Appraiser

Before execution begins, `Appraiser.estimate_task/1` estimates cost and hours for the planned sub-task set. It takes a list of `%{role: atom, complexity: integer}` maps and returns:

```elixir
%{
  total_cost_usd: float,
  total_hours: float
}
```

This estimate is emitted as `:orchestrator_task_appraised` on the event bus. The estimate is best-effort — if the Appraiser is unavailable, execution proceeds without it.

---

## ComplexityScaler

`ComplexityScaler.optimal_agent_count/3` takes the complexity score, tier, and an optional user override to determine how many agents to actually spawn. It respects:

- Configured `max_agents` limit from Roster
- Tier-based scaling (elite tasks get more agents than utility)
- Explicit user intent (e.g., "use 3 agents" detected by `detect_agent_count_intent/1`)

The user intent detector scans the task description for patterns like "use N agents", "spawn X workers", "with Y parallel agents" to honor explicit user preferences.

---

## Sub-agent Spawning

`AgentRunner.spawn_agent/5` creates a `Task.async` process for each sub-task:

1. Generates a unique `agent_id`
2. Calls `build_agent_prompt/1` (three-tier selection above)
3. Resolves tier and model via `resolve_agent_tier/1`
4. Injects relevant memories via `Memory.recall_relevant/2`
5. Loads tools from `:persistent_term` (lock-free — no GenServer deadlock)
6. Blocks `orchestrate` tool to prevent infinite recursion
7. Returns `{agent_id, %AgentState{}, %Task{}}` immediately

The Orchestrator owns the Task monitor. The agent runs `run_sub_agent_iterations/10`, the ReAct loop that interleaves LLM calls and tool executions.

### LLM retry policy

Transient failures (rate limit 429, 500, 502, 503, overloaded) are retried with exponential backoff up to 2 times (`@max_retries 2`). Permanent errors (auth failures, bad requests) fail immediately. A crashed agent's tool call returns an error string back to the LLM so it can adapt.

---

## Environment Context

Every agent prompt includes an environment block:

```
## Environment
- Working directory: /path/to/project
- Git branch: main
```

This is built by `AgentRunner.build_environment_context/0` using `File.cwd!()` and `git rev-parse --abbrev-ref HEAD`.

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Swarm Mode](./swarm.md)
- [Delegation](./delegation.md)
- [Capability Packs](./capability-packs.md)
