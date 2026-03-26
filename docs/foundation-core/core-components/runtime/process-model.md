# Process Model

## Audience

Elixir/OTP engineers working on Daemon internals. Assumes familiarity with GenServer, Supervisor, and ETS.

## Overview

Daemon is structured as a four-tier OTP supervision tree rooted at `Daemon.Supervisor` with `:rest_for_one` strategy. A crash in the infrastructure layer restarts everything above it; crashes within a tier's children are isolated by each tier's own strategy.

## Supervision Tree

```
Daemon.Supervisor  (rest_for_one)
├── Daemon.TaskSupervisor          Task.Supervisor  (fire-and-forget async)
├── Daemon.Supervisors.Infrastructure  (rest_for_one)
│   ├── Daemon.SessionRegistry     Registry :unique
│   ├── Daemon.Events.TaskSupervisor  Task.Supervisor (max 100)
│   ├── Phoenix.PubSub
│   ├── Daemon.Events.Bus          GenServer
│   ├── Daemon.Events.DLQ          GenServer
│   ├── Daemon.Bridge.PubSub       GenServer
│   ├── Daemon.Store.Repo          Ecto SQLite3
│   ├── Daemon.EventStream         GenServer
│   ├── Daemon.Telemetry.Metrics   GenServer
│   ├── MiosaLLM.HealthChecker                 GenServer
│   ├── MiosaProviders.Registry                GenServer
│   ├── Daemon.Tools.Registry      GenServer
│   ├── Daemon.Tools.Cache         GenServer
│   ├── Daemon.Machines            GenServer
│   ├── Daemon.Commands            GenServer
│   ├── Daemon.OS.Registry         GenServer
│   ├── Daemon.MCP.Registry        Registry :unique
│   └── Daemon.MCP.Supervisor      DynamicSupervisor
├── Daemon.Supervisors.Sessions    (one_for_one)
│   ├── Daemon.Channels.Supervisor DynamicSupervisor
│   ├── Daemon.EventStreamRegistry Registry :unique
│   └── Daemon.SessionSupervisor   DynamicSupervisor
├── Daemon.Supervisors.AgentServices  (one_for_one)
│   ├── Daemon.Agent.Memory
│   ├── Daemon.Agent.HeartbeatState
│   ├── Daemon.Agent.Tasks
│   ├── MiosaBudget.Budget
│   ├── Daemon.Agent.Orchestrator
│   ├── Daemon.Agent.Progress
│   ├── Daemon.Agent.Hooks
│   ├── Daemon.Agent.Learning
│   ├── MiosaKnowledge.Store
│   ├── Daemon.Agent.Memory.KnowledgeBridge
│   ├── Daemon.Vault.Supervisor
│   ├── Daemon.Agent.Scheduler
│   ├── Daemon.Agent.Compactor
│   ├── Daemon.Agent.Cortex
│   ├── Daemon.Agent.ProactiveMode
│   └── Daemon.Webhooks.Dispatcher
├── Daemon.Supervisors.Extensions  (one_for_one, conditionally populated)
├── Daemon.Channels.Starter
└── Bandit  (HTTP, port 8089, started last)
```

## Per-Session Agent Processes

Each active session runs one `Daemon.Agent.Loop` process, a GenServer started inside `Daemon.SessionSupervisor` (a `DynamicSupervisor`).

Sessions are registered in `Daemon.SessionRegistry` (a `Registry` with `:unique` keys) using the via-tuple pattern:

```elixir
{:via, Registry, {Daemon.SessionRegistry, session_id, user_id}}
```

The loop uses `:transient` restart strategy so it restarts only on crash, not on normal exit. The child spec is:

```elixir
%{
  id: {Daemon.Agent.Loop, session_id},
  start: {Daemon.Agent.Loop, :start_link, [opts]},
  restart: :transient,
  type: :worker
}
```

Looking up an existing session:

```elixir
Registry.lookup(Daemon.SessionRegistry, session_id)
# => [{pid, user_id}] | []
```

## GenServer Patterns

Most singleton services follow a standard pattern:

```elixir
use GenServer
def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
```

Session-scoped processes use via-tuple registration:

```elixir
def start_link(session_id) do
  GenServer.start_link(__MODULE__, session_id, name: via(session_id))
end

defp via(session_id) do
  {:via, Registry, {Daemon.EventStreamRegistry, session_id}}
end
```

The `Agent.Loop` intentionally blocks its mailbox during LLM calls by using `GenServer.call` with `:infinity` timeout. Cancellation is handled out-of-band via ETS (see Concurrency Patterns).

## ETS Tables Created at Boot

Daemon creates seven named ETS tables in `Application.start/2` before the supervision tree starts:

| Table | Access | Purpose |
|-------|--------|---------|
| `:daemon_cancel_flags` | public set | Per-session cancellation flags; read by Loop each iteration |
| `:daemon_files_read` | public set | Read-before-write tracking for pre_tool_use hook |
| `:daemon_survey_answers` | public set | HTTP endpoint writes; Loop polls for ask_user_question |
| `:daemon_context_cache` | public set | Ollama model context window sizes (avoids repeated HTTP calls) |
| `:daemon_survey_responses` | public bag | Survey/waitlist data when platform DB is disabled |
| `:daemon_session_provider_overrides` | public set | Hot-swap provider/model per session via API |
| `:daemon_pending_questions` | public set | Tracks blocked ask_user_question calls for `/pending_questions` endpoint |

Additional ETS tables created by specific services:

| Table | Owner | Purpose |
|-------|-------|---------|
| `:daemon_event_handlers` | `Events.Bus` | Registered handler functions by event type |
| `:daemon_dlq` | `Events.DLQ` | Failed event retry queue |
| `:daemon_telemetry` | `Telemetry.Metrics` | Runtime metrics snapshot |
| `:daemon_rate_limits` | `HTTP.RateLimiter` | Per-IP token bucket state |

## Process Linking and Monitoring

`Events.Stream` monitors its subscribers with `Process.monitor/1`. When a monitored subscriber process exits, the stream automatically removes it from the subscriber list via `handle_info({:DOWN, ...})`.

The `Bridge.PubSub` registers handlers with `Events.Bus` after a short delay (`Process.send_after(self(), :register_bridge, 100)`) to avoid a race with the bus initialization.

## Mailbox Patterns

`Agent.Loop` uses `handle_call` for message processing with `:infinity` timeout. Since the GenServer mailbox is blocked during LLM calls, cancellation uses ETS:

```elixir
# Cancel side — any process
:ets.insert(:daemon_cancel_flags, {session_id, true})

# Loop side — checked each iteration
case :ets.lookup(:daemon_cancel_flags, session_id) do
  [{_, true}] -> :cancelled
  _ -> :continue
end
```

`Telemetry.Metrics` uses `handle_cast` for all write operations to avoid blocking callers on metric updates, and `handle_info` to forward events it receives from its own Bus subscriptions.

## Boot Sequence

1. ETS tables created (before any process starts)
2. `Soul.load/0` and `PromptLoader.load/0` populate `:persistent_term` (before LLM calls)
3. Supervision tree starts in `:rest_for_one` order
4. After `{:ok, pid}`: Ollama model auto-detection runs synchronously (so banner shows correct model)
5. MCP server startup runs in a `Task` (asynchronous, registers tools when complete)
