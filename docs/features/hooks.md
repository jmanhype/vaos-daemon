# Hook Pipeline

The hook pipeline intercepts key moments in the agent lifecycle. Hooks can inspect, modify, or block actions. They run in priority order — lower numbers run first.

---

## Architecture

Registration is serialized through a GenServer to prevent race conditions. Execution reads from ETS in the caller's process — no GenServer bottleneck at runtime.

```
Registration: GenServer (serialized write) → ETS :daemon_hooks (bag, read_concurrency)
Execution:    Caller process reads ETS → runs chain → updates ETS :daemon_hooks_metrics
```

ETS tables:
- `:daemon_hooks` — bag table, stores `{event, name, priority, handler_fn}` tuples
- `:daemon_hooks_metrics` — set table with write_concurrency, holds atomic call/block/timing counters

---

## Events

| Event | When | Can Block? | Use Case |
|-------|------|------------|----------|
| `pre_tool_use` | Before a tool executes | Yes | Security checks, budget enforcement |
| `post_tool_use` | After a tool executes | No | Cost tracking, telemetry, MCP caching |
| `pre_compact` | Before context compaction | No | Snapshot state, flush memory |
| `session_start` | New session begins | No | Context injection, memory loading |
| `session_end` | Session ends | No | Cleanup, pattern consolidation |
| `pre_response` | Before sending to user | No | Quality check, formatting |
| `post_response` | After response sent | No | Analytics, learning capture, auto-extract tasks |

---

## Built-in Hooks (9)

| Name | Event | Priority | Description |
|------|-------|----------|-------------|
| `spend_guard` | `pre_tool_use` | 8 | Blocks all tools when the budget period limit is reached |
| `security_check` | `pre_tool_use` | 10 | Blocks dangerous shell commands via `Security.ShellPolicy` |
| `read_before_write` | `pre_tool_use` | 12 | Adds a nudge flag when editing an unread file (max 2 nudges per file per session) |
| `mcp_cache` | `pre_tool_use` | 15 | Injects cached MCP schema if cached within the last hour |
| `mcp_cache_post` | `post_tool_use` | 15 | Populates the MCP schema cache from tool results |
| `track_files_read` | `post_tool_use` | 5 | Records file paths in `:daemon_files_read` ETS after `file_read`, `dir_list`, `glob` |
| `cost_tracker` | `post_tool_use` | 25 | Records provider, model, and token counts in MiosaBudget |
| `telemetry` | `post_tool_use` | 90 | Emits `tool_telemetry` bus event with tool name, duration, and timestamp |
| `session_cleanup` | `session_end` | 90 | Deletes all `:daemon_files_read` ETS entries for the ended session |

---

## Hook Return Values

```elixir
{:ok, payload}      # Continue pipeline with (possibly modified) payload
{:block, reason}    # Stop pipeline, reject the action (pre_tool_use only)
:skip               # Skip this hook, continue to next
```

A crashed hook is caught, logged, and skipped — it does not halt the pipeline.

---

## Registering a Custom Hook

```elixir
alias Daemon.Agent.Hooks

# Logging hook (pass-through)
Hooks.register(:pre_tool_use, "my_logger", fn payload ->
  require Logger
  Logger.info("Tool called: #{payload.tool_name}")
  {:ok, payload}
end, priority: 45)

# Blocking hook
Hooks.register(:pre_tool_use, "block_curl", fn payload ->
  if payload.tool_name == "shell_execute" and
     String.contains?(payload.arguments["command"] || "", "curl") do
    {:block, "curl commands are blocked by policy"}
  else
    {:ok, payload}
  end
end, priority: 15)

# Post-response analytics
Hooks.register(:post_response, "my_analytics", fn payload ->
  MyApp.Analytics.track(:response, %{tokens: payload.token_count})
  {:ok, payload}
end)
```

Hook registrations take effect immediately. No restart required.

---

## Payload Structures

**`pre_tool_use` / `post_tool_use`:**
```elixir
%{
  tool_name:  "shell_execute",
  arguments:  %{"command" => "ls -la"},
  session_id: "cli_abc123",
  # post_tool_use adds:
  result:      {:ok, "file1.ex\nfile2.ex"},
  duration_ms: 45,
  provider:    "anthropic",
  model:       "claude-sonnet-4-6",
  tokens_in:   0,
  tokens_out:  0
}
```

**`session_start` / `session_end`:**
```elixir
%{
  session_id: "cli_abc123",
  channel:    :cli,
  timestamp:  ~U[2026-03-08 10:00:00Z],
  # session_end adds:
  message_count: 42,
  tool_calls:    15
}
```

**`pre_response` / `post_response`:**
```elixir
%{
  content:     "Here's the fix...",
  session_id:  "cli_abc123",
  token_count: 450,
  model:       "claude-sonnet-4-6",
  provider:    :anthropic
}
```

---

## Synchronous vs Asynchronous Execution

```elixir
# Synchronous — use for pre_tool_use (result needed to block or continue)
case Hooks.run(:pre_tool_use, payload) do
  {:ok, updated_payload}  -> proceed(updated_payload)
  {:blocked, reason}      -> reject(reason)
end

# Asynchronous — use for post-event hooks where the result is not needed
Hooks.run_async(:post_tool_use, payload)
```

`run_async/2` spawns a `Task` for the chain. Use it for telemetry and logging hooks that should not add latency to the main agent loop.

---

## Priority Guide

| Range | Purpose |
|-------|---------|
| 1–10 | Critical security and budget enforcement (run first) |
| 11–20 | File safety nudges, cache pre-population |
| 21–50 | Business logic, custom hooks |
| 51–80 | Analytics and learning |
| 81–100 | Low-priority logging and cleanup |

---

## Inspecting Hooks and Metrics

```elixir
# List all registered hooks grouped by event
Hooks.list_hooks()
# Returns: %{pre_tool_use: [%{name: "spend_guard", priority: 8}, ...], ...}

# Get execution metrics
Hooks.metrics()
# Returns:
%{
  pre_tool_use: %{calls: 1240, total_us: 45_200, blocks: 3, avg_us: 36},
  post_tool_use: %{calls: 1237, total_us: 82_100, blocks: 0, avg_us: 66}
}
```

CLI: `/hooks` lists all registered hooks with their priorities.

---

## See Also

- [Tasks](tasks.md) — the `task_auto_extract` hook that populates the tracker from responses
- [Proactive Mode](proactive-mode.md) — uses `spend_guard` as budget gate for autonomous work
- [Skills](skills.md) — skills execute as tools and pass through the hook pipeline
