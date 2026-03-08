# Delegation

Delegation is lightweight sub-agent spawning without full orchestration overhead. A single focused agent runs an autonomous ReAct loop to research or accomplish a scoped task and returns its findings.

---

## When to Use Delegation vs Orchestration

| Concern | Delegation | Orchestration |
|---------|-----------|--------------|
| Overhead | Low (no LLM complexity analysis call) | High (complexity analysis + decomposition) |
| Parallelism | Single agent | Multiple agents in waves |
| Use case | Research, exploration, scoped subtasks | Complex multi-domain tasks |
| Tool access | Read-only by default | All tools |
| Recursive | Never (blocked) | Via `orchestrate` tool |
| Initiated from | Any agent via the `delegate` tool | User request or `orchestrate` tool |

---

## The `delegate` Tool

`OptimalSystemAgent.Tools.Builtins.Delegate` is a registered builtin tool callable by any agent. It spawns a focused sub-agent that autonomously chains tool calls.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task` | string | yes | What the sub-agent should investigate or accomplish |
| `tools` | array of strings | no | Restrict to specific tools (default: read-only set) |
| `tier` | string | no | `utility` (default), `specialist`, or `elite` |

### Default tool set (read-only)

```
file_read, file_grep, file_glob, dir_list,
web_search, web_fetch, memory_recall, session_search
```

The following tools are always blocked to prevent recursion:
```
delegate, orchestrate, create_skill
```

### Example call from an agent

```json
{
  "name": "delegate",
  "arguments": {
    "task": "Find all files that import the Auth module and list what they use from it",
    "tools": ["file_grep", "file_read"],
    "tier": "utility"
  }
}
```

---

## Sub-agent Execution Loop

The delegate tool runs an internal ReAct loop identical to the orchestrator's agent loop, but self-contained within the tool's `execute/1` call:

```
messages = [system_prompt, {user: task}]
loop:
  LLM call → content + tool_calls
  if no tool_calls → return content
  for each tool_call:
    Tools.execute_direct(name, args)  # lock-free, no GenServer
    append tool result to messages
  repeat up to @max_iterations (20)
```

Progress is emitted to the event bus at each iteration:

| Event | When |
|-------|------|
| `:delegate_started` | Sub-agent created |
| `:delegate_progress` | Each tool call executed |
| `:delegate_completed` | Final result ready |

The TUI displays live delegate status:
```
Delegate(explore codebase) — 12 tool uses · 45k tokens
```

---

## Tier and Model Resolution

The `tier` parameter maps to model classes:

| Tier | Model config key |
|------|----------------|
| `elite` | `:elite_model` or `:anthropic_model` |
| `specialist` | `:specialist_model` |
| `utility` | `:utility_model` |

If no model is configured for the tier, the provider's default model is used.

---

## Tool Execution — Lock-free Path

Delegate always uses `Tools.execute_direct/2` (reads from `:persistent_term`, no GenServer call) rather than `Tools.execute/2`. This is essential because the delegate tool is itself called inside a GenServer (the Loop), and a nested GenServer call to the Tools Registry would deadlock.

The same pattern applies to tool list loading: `Tools.list_tools_direct/0` reads from `:persistent_term` without going through the Registry process.

---

## Result Synthesis

The delegate returns the final LLM response as a plain string. No LLM synthesis step is applied — the last assistant message is the result. If the iteration limit is reached before the agent produces a final answer, a truncation notice is returned.

### Iteration limit behavior

At `@max_iterations` (20):
```
"Delegate reached iteration limit (20). Partial results may be available."
```

Tool results are truncated at 10KB per call to prevent context window overflow from large file reads.

---

## Orchestrate Tool

`OptimalSystemAgent.Tools.Builtins.Orchestrate` is the higher-level sibling to `delegate`. It invokes the full Orchestrator with complexity analysis and multi-agent decomposition. It is blocked for sub-agents to prevent infinite recursion.

The `orchestrate` tool is only callable from user-facing contexts (the main agent loop or explicit API calls), not from within orchestrated sub-agents.

---

## Sub-agent Spawning in the Orchestrator

The Orchestrator's `AgentRunner.spawn_agent/5` spawns sub-agents differently from the `delegate` tool:

| Aspect | `delegate` tool | `AgentRunner.spawn_agent` |
|--------|----------------|--------------------------|
| Process type | Sync (blocks caller) in `Task.async` on the call site | `Task.async` owned by Orchestrator GenServer |
| Monitoring | Not separately monitored | GenServer receives `handle_info` on completion |
| Progress reporting | Via event bus | Via `GenServer.cast` to Orchestrator |
| Prompt | Fixed system prompt | Three-tier agent selection |
| Tier override | Per-call parameter | Resolved from Roster scoring |

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Agents and Roster](./agents.md)
- [Tools Overview](../tools/overview.md)
