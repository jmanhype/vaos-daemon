# Concurrency Patterns

## Audience

Elixir engineers modifying Daemon's hot paths, adding tools, or extending the event pipeline.

## Overview

Daemon uses three concurrency strategies depending on the data access pattern: ETS for concurrent reads with single-writer ownership, `GenServer.cast` for fire-and-forget writes, and `Task.Supervisor` for bounded parallel work. The event bus dispatches via supervised tasks to avoid blocking callers.

## ETS Concurrent Reads + GenServer Writes

The primary pattern for high-frequency data like tool registrations and metric counters:

1. A GenServer owns a named ETS table
2. Any process reads directly from ETS (no message passing overhead)
3. All writes go through the GenServer to serialize mutations

Example from `Tools.Registry`:

```elixir
# Read path — lock-free, any process
def list_tools_direct do
  builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
  mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})
  # ...
end

# Write path — serialized through GenServer
def register(skill_module) do
  GenServer.call(__MODULE__, {:register_module, skill_module})
end
```

`Telemetry.Metrics` uses the same pattern with `:daemon_telemetry`. All metric counters are written inside `handle_cast` callbacks; callers use `get_metrics/0` which reads ETS directly via `build_metrics/0`.

## persistent_term for Hot Read Data

`:persistent_term` provides faster reads than ETS when data is written infrequently and read very often. Daemon uses it for:

| Key | What it stores | Written by |
|-----|---------------|------------|
| `{Soul, :static_base}` | Interpolated system prompt | `Soul.load/0` at boot + `Soul.reload/0` |
| `{Soul, :user}` | USER.md content | `Soul.load/0` |
| `{Soul, :identity}` | IDENTITY.md content | `Soul.load/0` |
| `{Soul, :agent_souls}` | Per-agent soul files map | `Soul.load/0` |
| `{Tools.Registry, :builtin_tools}` | Map of name -> module | `Tools.Registry` GenServer |
| `{Tools.Registry, :mcp_tools}` | MCP tool descriptors | `Tools.Registry` after MCP handshake |
| `{Tools.Registry, :skills}` | SKILL.md definitions | `Tools.Registry` |
| `:daemon_ollama_tiers` | tier -> model mapping | `Agent.Tier.detect_ollama_tiers/0` |
| `:daemon_tier_overrides` | Manual tier overrides | `Agent.Tier` |
| `{Agent.Hooks, cache_key}` | Compiled hook patterns | `Agent.Hooks` |

Writing to `:persistent_term` triggers a global GC scan in all processes; it is only appropriate for data that changes at boot or on explicit reload, not on every request.

## Task.Supervisor for Bounded Parallel Work

Daemon runs two `Task.Supervisor` instances:

- `Daemon.TaskSupervisor` — general fire-and-forget work (HTTP dispatch, background learning)
- `Daemon.Events.TaskSupervisor` — event handler dispatch (max_children: 100 per supervision restart)

Event bus dispatch uses `Task.Supervisor.start_child` so handler crashes do not block the caller:

```elixir
Task.Supervisor.start_child(
  Daemon.Events.TaskSupervisor,
  fn ->
    try do
      :glc.handle(:daemon_event_router, gre_event)
    catch
      :error, reason -> Logger.warning("[Bus] Router dispatch error: #{inspect(reason)}")
      :exit, reason  -> Logger.warning("[Bus] Router dispatch exit: #{inspect(reason)}")
    end
  end,
  max_children: 1000
)
```

Handler dispatch is also supervised via `Task.Supervisor.start_child`, with crashes routed to `Events.DLQ`:

```elixir
Task.Supervisor.start_child(Daemon.Events.TaskSupervisor, fn ->
  try do
    handler.(payload)
  rescue
    e -> Events.DLQ.enqueue(type, payload, handler, Exception.message(e))
  end
end)
```

## Loop Cancellation via ETS

`Agent.Loop` processes their message inside `handle_call` with `:infinity` timeout. This blocks the GenServer mailbox for the duration of an LLM call. Cancellation cannot use a message because it would queue behind the in-progress call.

Solution: ETS flag written by `Loop.cancel/1` and checked by `run_loop` at each iteration:

```elixir
# Cancel — any process, non-blocking
def cancel(session_id) do
  :ets.insert(:daemon_cancel_flags, {session_id, true})
end

# Check inside run_loop — each iteration
defp cancelled?(session_id) do
  case :ets.lookup(:daemon_cancel_flags, session_id) do
    [{_, true}] -> true
    _ -> false
  end
end
```

The ETS table uses `:public` access and `:set` semantics. `{session_id, true}` is inserted at cancellation, checked each iteration, and deleted when the loop exits.

## Back-Pressure via Mailbox Monitoring

Daemon does not implement explicit back-pressure for the event bus because goldrush dispatches handlers asynchronously via `Task.Supervisor`. If the supervisor's `max_children` limit is reached, `start_child` returns `{:error, :max_children}` and the dispatch silently drops.

For LLM request load: the `Providers.HealthChecker` circuit breaker prevents cascading failures. When a provider opens its circuit after 3 consecutive failures, the fallback chain automatically skips it. Rate-limited providers (HTTP 429) are excluded for 60 seconds (or the `Retry-After` duration).

The retry wrapper in `Providers.Registry` sleeps in-process for up to 60 seconds on rate-limit responses:

```elixir
@max_retries 3
@backoff_base_ms 1_000

defp with_retry(fun, attempt \\ 1) do
  case fun.() do
    {:error, {:rate_limited, retry_after}} when attempt <= @max_retries ->
      sleep_ms = if is_integer(retry_after) and retry_after > 0,
        do: min(retry_after, 60) * 1_000,
        else: round(@backoff_base_ms * :math.pow(2, attempt - 1))
      Process.sleep(sleep_ms)
      with_retry(fun, attempt + 1)
    other -> other
  end
end
```

This is intentional: the calling `Agent.Loop` process is already blocked on the LLM call, so sleeping here does not release any scheduler capacity that could otherwise be used.

## SwarmMode Agent Pool

`Daemon.Agent.Orchestrator.SwarmMode.AgentPool` is a `DynamicSupervisor` with a hard cap of 50 children:

```elixir
{DynamicSupervisor,
  name: Daemon.Agent.Orchestrator.SwarmMode.AgentPool,
  strategy: :one_for_one,
  max_children: 50}
```

Attempts to start a 51st sub-agent return `{:error, :max_children}` without crashing the supervisor or any existing agent.

## MCP Integration Concurrency

MCP server processes live under `Daemon.MCP.Supervisor` (a `DynamicSupervisor`). Each MCP server gets its own GenServer. Tool discovery after boot runs in a top-level `Task` to avoid blocking the application start:

```elixir
Task.start(fn ->
  Daemon.MCP.Client.start_servers()
  Daemon.MCP.Client.list_tools()          # blocks on JSON-RPC handshake
  Daemon.Tools.Registry.register_mcp_tools()
end)
```

`MCP.Client.list_tools/0` is a `GenServer.call` that queues behind the `initialize` RPC — no sleep is needed.
