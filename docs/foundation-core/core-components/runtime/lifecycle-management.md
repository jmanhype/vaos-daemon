# Lifecycle Management

## Session Lifecycle

Each user interaction runs inside a session. A session maps one-to-one to an
`Agent.Loop` GenServer process.

### Session Creation

`SessionSupervisor` is a `DynamicSupervisor` under `Supervisors.Sessions`:

```elixir
{DynamicSupervisor, name: Daemon.SessionSupervisor, strategy: :one_for_one}
```

When a channel (CLI, HTTP, Telegram, etc.) receives a new connection, it calls:

```elixir
DynamicSupervisor.start_child(
  Daemon.SessionSupervisor,
  {Daemon.Agent.Loop, [session_id: id, channel: channel, ...]}
)
```

`Agent.Loop` registers itself via `SessionRegistry`:

```elixir
GenServer.start_link(__MODULE__, opts,
  name: {:via, Registry, {Daemon.SessionRegistry, session_id, user_id}})
```

The `child_spec` uses `:transient` restart so the process only restarts on
unexpected crashes, not on normal exit:

```elixir
def child_spec(opts) do
  %{
    id: {__MODULE__, session_id},
    start: {__MODULE__, :start_link, [opts]},
    restart: :transient,
    type: :worker
  }
end
```

### Loop State

`Agent.Loop` holds all conversation state in its GenServer state struct:

```elixir
defstruct [
  :session_id, :user_id, :channel,
  :provider, :model, :working_dir,
  messages: [],          # full conversation history
  iteration: 0,          # current ReAct iteration count
  turn_count: 0,         # number of user turns completed
  status: :idle,         # :idle | :running | :cancelled
  tools: [],             # registered tool specs for this session
  plan_mode: false,      # single-LLM-call mode (no tool iteration)
  strategy: nil,         # pluggable reasoning strategy module
  strategy_state: %{},   # strategy-specific state
  signal_weight: nil,    # per-call weight for tool gating (0.0–1.0)
  permission_tier: :full # :full | :workspace | :read_only
]
```

### Message Processing

All messages are synchronous `GenServer.call/3` with `:infinity` timeout:

```elixir
def process_message(session_id, message, opts \\ []) do
  GenServer.call(via(session_id), {:process, message, opts}, :infinity)
end
```

This serializes processing within a session while allowing multiple sessions to
run fully concurrently on separate BEAM processes.

### Session Cancellation

Because `process_message/3` blocks the GenServer mailbox, a separate
cancellation mechanism is needed. The cancel flag is written to the
`osa_cancel_flags` ETS table, which the ReAct loop checks at each iteration:

```elixir
def cancel(session_id) do
  :ets.insert(:daemon_cancel_flags, {session_id, true})
end
```

Inside the loop:

```elixir
case :ets.lookup(:daemon_cancel_flags, session_id) do
  [{^session_id, true}] ->
    :ets.delete(:daemon_cancel_flags, session_id)
    {:cancelled, "Loop cancelled by user request"}
  [] ->
    continue_loop(state)
end
```

### Session Cleanup

The `telemetry` hook at priority 90 fires on `post_tool_use` events. Session
teardown purges related ETS entries:

```elixir
:ets.delete(:daemon_cancel_flags, session_id)
:ets.delete(:daemon_files_read, session_id)
:ets.delete(:daemon_session_provider_overrides, session_id)
```

The per-session `Events.Stream` GenServer is stopped via the
`EventStreamRegistry`:

```elixir
Events.Stream.stop(session_id)
```

## Vault Session Lifecycle

The Vault provides structured memory across sessions. It implements its own
session lifecycle on top of the agent session lifecycle via
`Vault.SessionLifecycle`.

### Three-Phase Lifecycle

```
wake(session_id)
    ↓ check dirty flags from previous sessions
    ↓ touch dirty flag for this session
    ↓ {:ok, :clean | :recovered}

[session runs — agent processes messages]

checkpoint(session_id)     ← every 10 tool calls (vault_checkpoint_interval)
    ↓ flush observer buffer
    ↓ touch dirty flag (refresh timestamp)

sleep(session_id, context)
    ↓ flush observer buffer
    ↓ create handoff document
    ↓ clear dirty flag
```

### Dirty Death Detection

Flag files in `~/.daemon/.vault/dirty/<session_id>` signal that a session is
currently running. If Daemon crashes, the flag file persists. On the next `wake/1`
call, any flag files from different session IDs are treated as dirty deaths:

```elixir
def wake(session_id) do
  case File.ls(dirty_dir()) do
    {:ok, files} ->
      files
      |> Enum.reject(&(&1 == session_id))
      |> Enum.each(fn dead_session ->
        Logger.warning("[vault/lifecycle] Dirty death detected: #{dead_session}")
        recover(dead_session)
      end)
  end
end
```

Recovery loads the handoff document created at the previous clean sleep, if
one exists.

### Checkpoint Interval

Controlled by `vault_checkpoint_interval` (default: `10`). After every 10 tool
calls, the loop calls `Vault.SessionLifecycle.checkpoint/1` to flush
observations and refresh the dirty flag timestamp.

### Handoff Document

On clean sleep, `Vault.Handoff.create/2` writes a Markdown document to
`~/.daemon/.vault/handoffs/<session_id>.md` summarizing:

- Key decisions made during the session
- Open tasks and next steps
- Important context for the next session

The handoff is injected into the agent's context on the next session start,
giving continuity without requiring the LLM to re-read the full conversation
history.

## Provider Lifecycle

Each LLM provider is a module registered in `MiosaProviders.Registry` at boot.
The `MiosaLLM.HealthChecker` monitors provider availability and implements a
circuit breaker pattern:

| State | Condition | Behavior |
|-------|-----------|----------|
| Closed | Normal | All requests pass through |
| Open | N consecutive failures | Requests rejected immediately |
| Half-open | After backoff period | One probe request allowed |

When a provider enters the open state, `Agent.Loop` consults the
`fallback_chain` (auto-detected from configured API keys at boot) and retries
the request with the next available provider.

## MCP Server Lifecycle

MCP servers start asynchronously after the supervision tree is up:

```elixir
Task.start(fn ->
  Daemon.MCP.Client.start_servers()
  Daemon.MCP.Client.list_tools()
  Daemon.Tools.Registry.register_mcp_tools()
end)
```

Each MCP server runs as a child under `MCP.Supervisor` (a `DynamicSupervisor`).
Servers that fail to start or crash are automatically restarted with exponential
backoff. Tools registered from MCP are available to all subsequent sessions.
